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

    var onStateChange: ((_ cardId: UUID, _ running: Bool, _ exitCode: Int32?) -> Void)?
    var onTitle: ((_ cardId: UUID, _ title: String) -> Void)?

    func view(for cardId: UUID) -> CardTerminalView {
        if let view = views[cardId] { return view }
        let view = CardTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.cardId = cardId
        view.processDelegate = self
        TerminalStyle.apply(to: view)
        views[cardId] = view
        return view
    }

    func isRunning(_ cardId: UUID) -> Bool { live.contains(cardId) }

    /// Starts `claude` for the card in a login shell in its folder: the same
    /// environment a terminal window would give it.
    func start(_ card: Card, prompt: String? = nil, env: ShellEnvironment, hookPort: UInt16) {
        let view = view(for: card.id)
        guard !live.contains(card.id) else { return }
        let claude = env.claudePath ?? "claude"
        let command = "exec " + Launch.commandLine(claude, Launch.claudeArguments(for: card, prompt: prompt))
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
        onStateChange?(card.id, true, nil)
    }

    func stop(_ cardId: UUID) {
        guard let view = views[cardId], live.contains(cardId) else { return }
        view.terminate()
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
        live.remove(id)
        view.feed(text: "\r\n\u{1b}[2m─── session ended\(exitCode.map { $0 == 0 ? "" : " (exit \($0))" } ?? "") ───\u{1b}[0m\r\n")
        onStateChange?(id, false, exitCode)
    }
}

/// A card's terminal. Knows which card it belongs to and whether it has ever
/// started a process, so a restart can say so in the scrollback.
final class CardTerminalView: LocalProcessTerminalView {
    var cardId: UUID?
    var hasRun = false
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
