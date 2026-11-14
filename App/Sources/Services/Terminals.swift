import AppKit
import ReeveKit
import SwiftTerm

/// Every card's terminal, kept alive whether it is on screen or not.
///
/// Switching cards swaps which view the terminal pane holds; the views
/// themselves, with their scrollback and their running `claude`, stay here
/// until the card is closed.
@MainActor
final class Terminals: NSObject, LocalProcessTerminalViewDelegate {
    private var views: [UUID: CardTerminalView] = [:]
    /// Cards whose process is running now.
    private(set) var live: Set<UUID> = []
    /// Cards whose process has been asked to end and hasn't yet.
    private var stopping: Set<UUID> = []
    /// Our own watch on each card's process. SwiftTerm's misses an exit when
    /// the terminal's output ends before the exit is seen.
    private var exitWatches: [UUID: DispatchSourceProcess] = [:]

    var onStateChange: ((_ cardId: UUID, _ running: Bool, _ exitCode: Int32?) -> Void)?
    var onTitle: ((_ cardId: UUID, _ title: String) -> Void)?

    func view(for cardId: UUID) -> CardTerminalView {
        if let view = views[cardId] { return view }
        let view = CardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.cardId = cardId
        view.processDelegate = self
        TerminalStyle.apply(to: view)
        view.terminal.changeHistorySize(10_000)
        views[cardId] = view
        return view
    }

    func isRunning(_ cardId: UUID) -> Bool { live.contains(cardId) }

    /// Starts `claude` for the card in a login shell in its folder: the same
    /// environment a terminal window would give it.
    func start(_ card: Card, prompt: String? = nil, env: ShellEnvironment, hookPort: UInt16, reviewsDir: String) {
        let view = view(for: card.id)
        guard !live.contains(card.id) else { return }
        let claude = env.claudePath ?? "claude"
        let command = Launch.shellCommand(claude, Launch.claudeArguments(for: card, prompt: prompt, reviewsDir: reviewsDir), cliDirectory: Self.cliDirectory)
        let environment = Launch.environment(base: env.baseEnvironment, hookPort: hookPort, cardId: card.id)
        if view.hasRun {
            view.feed(text: "\r\n\u{1b}[2m─── resuming session ───\u{1b}[0m\r\n")
        }
        view.hasRun = true
        live.insert(card.id)
        view.startProcess(
            executable: env.shell,
            args: ["-l", "-i", "-c", command],
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-" + URL(fileURLWithPath: env.shell).lastPathComponent,
            currentDirectory: card.cwd
        )
        watchExit(of: view.process.shellPid, card: card.id)
        onStateChange?(card.id, true, nil)
    }

    private func watchExit(of pid: pid_t, card id: UUID) {
        exitWatches[id]?.cancel()
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            // Reaped here whoever else hears of it, so no exit is left a zombie.
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG) == pid
            MainActor.assumeIsolated {
                self?.exited(id, pid: pid, exitCode: reaped && status & 0x7f == 0 ? (status >> 8) & 0xff : nil)
            }
        }
        exitWatches[id] = source
        source.resume()
    }

    /// The card's process has gone, by whichever route heard first.
    private func exited(_ id: UUID, pid: pid_t?, exitCode: Int32?) {
        guard let view = views[id] else {
            // The card was closed.
            exitWatches.removeValue(forKey: id)?.cancel()
            return
        }
        // A process from before a restart, whose successor is running now.
        if let pid, view.process.shellPid != pid { return }
        exitWatches.removeValue(forKey: id)?.cancel()
        guard live.remove(id) != nil else { return }
        view.feed(text: "\r\n\u{1b}[2m─── session ended\(exitCode.map { $0 == 0 ? "" : " (exit \($0))" } ?? "") ───\u{1b}[0m\r\n")
        onStateChange?(id, false, exitCode)
    }

    /// Where the app keeps `reeve`, which every card's shell finds first on
    /// its PATH. Nil in a build without it.
    static let cliDirectory: String? = {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        return FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("reeve").path) ? helpers.path : nil
    }()

    /// Types a prompt into the card's running `claude` and submits it, as a
    /// person would. Pasted, so nothing in it is taken for a keystroke; the
    /// return comes after, so it isn't taken for part of the paste.
    func send(_ text: String, to cardId: UUID) {
        guard let view = views[cardId], live.contains(cardId) else { return }
        let paste = view.getTerminal().bracketedPasteMode
        if paste { view.send(data: EscapeSequences.bracketedPasteStart[0...]) }
        view.send(txt: text)
        if paste { view.send(data: EscapeSequences.bracketedPasteEnd[0...]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak view] in
            view?.send(txt: "\r")
        }
    }

    /// The rows the card's terminal shows at the bottom of its buffer, top to
    /// bottom, wherever the view is scrolled to.
    func screen(_ cardId: UUID) -> [String] {
        guard let view = views[cardId] else { return [] }
        let terminal = view.getTerminal()
        let lines = String(decoding: terminal.getBufferAsData(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(terminal.rows + 1).map(String.init)
    }

    /// Ends the card's `claude`. SwiftTerm stops watching a process it is
    /// asked to end, so it never says the process exited; this waits for that
    /// itself, and kills it if it hasn't gone after a few seconds.
    func stop(_ cardId: UUID) {
        guard let view = views[cardId], live.contains(cardId), !stopping.contains(cardId) else { return }
        let pid = view.process.shellPid
        stopping.insert(cardId)
        view.terminate()
        Task { [weak self, weak view] in
            var status: Int32 = 0
            for tick in 0... {
                if pid <= 0 || waitpid(pid, &status, WNOHANG) != 0 { break }
                if tick == 50 { kill(pid, SIGKILL) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self else { return }
            self.stopping.remove(cardId)
            // Closed meanwhile, or started again.
            guard let view, self.views[cardId] === view, self.live.contains(cardId) else { return }
            // For this process only: the exit watch may have seen it go and a
            // restart begun its successor.
            self.exited(cardId, pid: pid, exitCode: nil)
        }
    }

    func close(_ cardId: UUID) {
        stop(cardId)
        views[cardId]?.removeFromSuperview()
        views[cardId] = nil
        live.remove(cardId)
    }

    func stopAll() {
        for id in live { views[id]?.terminate() }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let id = (source as? CardTerminalView)?.cardId else { return }
        onTitle?(id, title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? CardTerminalView, let id = view.cardId else { return }
        exited(id, pid: nil, exitCode: exitCode)
    }
}

/// A card's terminal. Knows which card it belongs to and whether it has ever
/// started a process, so a restart can say so in the scrollback.
///
/// SwiftTerm's own `scrollWheel` only scrolls the view's history, and can't be
/// overridden from here, so a wheel event meant for a program that turned
/// mouse tracking on (as `claude`'s fullscreen mode does) is reported to it by
/// a monitor instead. Everything else is left to SwiftTerm.
final class CardTerminalView: LocalProcessTerminalView {
    var cardId: UUID?
    var hasRun = false
    private var wheelMonitor: Any?
    /// Scroll distance, in lines, not yet sent: a trackpad drag moves a fraction
    /// of a line per event, and sending a whole line for each made it race.
    private var wheelRemainder: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        guard window != nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.reportWheel(event) ?? event }
        }
    }

    /// Sends the wheel event to the program as mouse button 4 or 5 and returns
    /// nil, or returns the event if SwiftTerm should handle it: the program
    /// isn't tracking the mouse, Shift or Option asks for the local behaviour,
    /// or something drawn over the terminal (the Plan and Changes tabs) is under
    /// the pointer.
    private func reportWheel(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !isHidden, let terminal,
              allowMouseReporting, terminal.mouseMode != .off,
              event.modifierFlags.isDisjoint(with: [.shift, .option]),
              window?.contentView?.hitTest(event.locationInWindow)?.isDescendant(of: self) == true
        else { return event }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return event }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { wheelRemainder = 0 }
        let cellHeight = bounds.height / CGFloat(terminal.rows)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.deltaY
        // Reverse direction drops what was left over from the last one.
        if delta * wheelRemainder < 0 { wheelRemainder = 0 }
        wheelRemainder += delta
        let lines = Int(wheelRemainder.magnitude.rounded(.down))
        guard lines > 0 else { return nil }
        wheelRemainder -= CGFloat(lines) * (wheelRemainder < 0 ? -1 : 1)

        let col = min(max(Int(point.x / bounds.width * CGFloat(terminal.cols)), 0), terminal.cols - 1)
        let row = min(max(Int((bounds.height - point.y) / bounds.height * CGFloat(terminal.rows)), 0), terminal.rows - 1)
        let flags = event.modifierFlags
        let buttonFlags = terminal.encodeButton(
            button: delta > 0 ? 4 : 5, release: false,
            shift: false, meta: false, control: flags.contains(.control)
        )
        for _ in 0..<min(lines, terminal.rows) {
            terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
        }
        return nil
    }
}

/// The terminal in Reeve's colours: the board's ink behind GitHub-dark ANSI
/// colours, which the board's own greys come from.
enum TerminalStyle {
    static func apply(to view: TerminalView) {
        view.font = NSFont(name: "Geist Mono", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x0E1116)
        view.nativeForegroundColor = NSColor(hex: 0xE6EDF3)
        view.caretColor = NSColor(hex: 0x38BDF8)
        view.selectedTextBackgroundColor = NSColor(hex: 0x00A6F4, alpha: 0.35)
        view.optionAsMetaKey = true
        view.installColors(ansi.map(color))
    }

    private static let ansi: [UInt32] = [
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
    ]

    private static func color(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257, green: UInt16((hex >> 8) & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
    }
}
