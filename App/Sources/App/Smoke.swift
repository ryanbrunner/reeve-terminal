import AppKit
import ReeveKit

/// A scripted run for checking the app end to end without a person at it.
///
/// Off unless `REEVE_SMOKE_OUT` is set. Then it makes one card in
/// `REEVE_SMOKE_DIR` with `REEVE_SMOKE_PROMPT`, saves a picture of the window
/// every few seconds into `REEVE_SMOKE_OUT`, and quits once the card has been
/// sorted after its first turn — or after two and a half minutes. Point
/// `REEVE_DATA_DIR` somewhere else too, so it never touches the real board.
/// Set `REEVE_SMOKE_CLOSE` to close the card at the end, removing its worktree,
/// and `REEVE_SMOKE_START=plan` to start the card planning rather than building.
/// Set `REEVE_SMOKE_TABS` to also stop once a plan arrives, and save a picture
/// of each of the card's tabs before quitting.
/// `REEVE_SMOKE_MODE=review` comments on the first added line once the first
/// turn is sorted (`REEVE_SMOKE_COMMENT`), sends it, and stops once Claude
/// has replied. `REEVE_SMOKE_SLEEP` ends the session first, so the
/// comment has to wake it.
@MainActor
enum Smoke {
    static func runIfAsked(board: Board) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REEVE_SMOKE_OUT"], let dir = env["REEVE_SMOKE_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // new: make a card with the prompt. resume: open the board's first
        // card and type the prompt into it. interrupt: make a card, then press
        // Esc a few seconds into its turn. review: make a card, then comment
        // on what it changed.
        let mode = env["REEVE_SMOKE_MODE"] ?? "new"
        let prompt = env["REEVE_SMOKE_PROMPT"] ?? "Say hello in one word."
        let limit = Double(env["REEVE_SMOKE_SECONDS"] ?? "") ?? 150
        let tabs = env["REEVE_SMOKE_TABS"] != nil
        let started = Date()
        var shot = 0
        var sawClassify = false
        var acceptedTrust = false
        var typed = false
        var interrupted: Date?
        var reviewed = false
        var timeline: [String] = []
        var lastActivity: Activity?
        var lastTitle: String?

        func log(_ line: String) {
            let entry = String(format: "%6.1fs ", Date().timeIntervalSince(started)) + line
            timeline.append(entry)
            FileHandle.standardError.write(Data(("reeve smoke: " + entry + "\n").utf8))
        }

        log("mode \(mode) in \(dir)")
        if mode == "resume", let card = board.cards.first {
            board.select(card.id)
        } else {
            board.create(cwd: dir, title: "", prompt: prompt, mode: env["REEVE_SMOKE_START"] == "plan" ? .plan : .build)
        }

        func showTabs(_ id: UUID, then done: @escaping () -> Void) {
            let order = CardTab.allCases.filter { $0 != .terminal } + [.terminal]
            for (index, tab) in order.enumerated() {
                // The keys a person would press, so the menu's shortcut is
                // what's tested, past a terminal that has the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 3) {
                    let number = CardTab.allCases.firstIndex(of: tab)! + 1
                    guard let window = NSApp.windows.first(where: { $0.isVisible }),
                          let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, characters: String(number),
                                                     charactersIgnoringModifiers: String(number), isARepeat: false, keyCode: [18, 19, 20][number - 1])
                    else { return }
                    NSApp.sendEvent(key)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 3 + 2.5) {
                    let view = board.terminals.view(for: id)
                    log("tab \(tab.rawValue) showing \(board.tab(id).rawValue) terminal focused \(view.window?.firstResponder === view)")
                    snapshot(to: "\(out)/tab-\(tab.rawValue).png")
                    if index == order.count - 1 { done() }
                }
            }
        }

        func finish(_ id: UUID) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(board.cards).write(to: URL(fileURLWithPath: "\(out)/cards.json"))
            let errors = board.classifyErrors.values.joined(separator: "\n")
            try? errors.write(toFile: "\(out)/errors.txt", atomically: true, encoding: .utf8)
            try? timeline.joined(separator: "\n").write(toFile: "\(out)/timeline.txt", atomically: true, encoding: .utf8)
            board.terminals.stopAll()
            // REEVE_SMOKE_CLOSE: close the card too, and give its worktree time to go.
            let closing = env["REEVE_SMOKE_CLOSE"] != nil
            if closing { log("closing card"); board.close(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (closing ? 5 : 1)) { exit(0) }
        }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(started)
                guard let card = board.selected else { return }
                let view = board.terminals.view(for: card.id)
                if Int(elapsed) % 3 == 0 {
                    shot += 1
                    snapshot(to: "\(out)/shot-\(String(format: "%02d", shot)).png")
                }
                if let title = board.terminalTitles[card.id], title != lastTitle {
                    lastTitle = title
                    log("title \(title.unicodeScalars.prefix(3).map { String(format: "U+%04X", $0.value) }.joined(separator: " ")) \(title)")
                }
                if card.activity != lastActivity {
                    lastActivity = card.activity
                    log("activity \(card.activity.rawValue) stage \(card.stage.rawValue) live \(board.live.contains(card.id)) focused \(view.window?.firstResponder === view)")
                }
                // A folder Claude Code has not seen asks whether to trust it.
                // The default is "No, exit", so step down to yes first.
                if mode != "resume", !acceptedTrust, elapsed > 6, !card.hasConversation {
                    acceptedTrust = true
                    log("accepting folder trust")
                    view.send(txt: "\u{1b}[B")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { view.send(txt: "\r") }
                }
                if mode == "resume", !typed, elapsed > 8 {
                    typed = true
                    log("typing prompt")
                    view.send(txt: prompt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { view.send(txt: "\r") }
                }
                if mode == "interrupt", interrupted == nil, card.activity == .running, card.hasConversation {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        log("pressing Esc")
                        view.send(txt: "\u{1b}")
                    }
                    interrupted = Date()
                }
                if board.classifying.contains(card.id) { sawClassify = true }
                var sorted = mode != "interrupt" && sawClassify && !board.classifying.contains(card.id)
                if mode == "review", sorted, !reviewed {
                    reviewed = true
                    board.show(.changes, for: card.id)
                    Task {
                        guard let changes = try? await Worktrees.changes(in: card.worktreePath ?? card.cwd, base: card.baseCommit, env: board.environment),
                              let file = changes.files.first,
                              let line = file.hunks.first?.lines.first(where: { $0.kind == .added }),
                              let anchor = ReviewAnchor(file: file, line: line) else {
                            log("nothing to comment on")
                            return
                        }
                        if env["REEVE_SMOKE_SLEEP"] != nil {
                            log("ending the session")
                            board.terminals.stop(card.id)
                            while board.live.contains(card.id) { try? await Task.sleep(for: .milliseconds(200)) }
                            log("session asleep")
                        }
                        log("commenting on \(anchor.path):\(anchor.line)")
                        board.comment(on: anchor, env["REEVE_SMOKE_COMMENT"] ?? "Make this say hello world instead, and tell me what you changed.", in: card.id, send: true)
                    }
                }
                if mode == "review" {
                    let replied = card.review?.contains { $0.messages.last?.author == .claude } == true
                    sorted = replied && card.activity != .running
                }
                let planned = tabs && (card.plan != nil || card.planPath != nil)
                if sorted || planned || elapsed > limit {
                    timer.invalidate()
                    log("done: activity \(card.activity.rawValue) stage \(card.stage.rawValue) title \(card.title) plan \(card.planPath ?? "-")")
                    snapshot(to: "\(out)/final.png")
                    if tabs { showTabs(card.id) { finish(card.id) } } else { finish(card.id) }
                }
            }
        }
    }

    private static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
