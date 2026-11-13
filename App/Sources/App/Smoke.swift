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
/// `REEVE_SMOKE_VIBES=1` puts the card in VIBES MODE and goes back to the board
/// once it has started, so nobody is watching; it runs until the card ships.
/// `REEVE_SMOKE_VIBES=board` flips the whole board's switch as well.
/// `REEVE_SMOKE_MODEL` and `REEVE_SMOKE_EFFORT` pick the card's model and effort.
@MainActor
enum Smoke {
    static func runIfAsked(board: Board) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REEVE_SMOKE_OUT"], let dir = env["REEVE_SMOKE_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        // new: make a card with the prompt. resume: open the board's first
        // card and type the prompt into it. interrupt: make a card, then press
        // Esc a few seconds into its turn.
        let mode = env["REEVE_SMOKE_MODE"] ?? "new"
        let prompt = env["REEVE_SMOKE_PROMPT"] ?? "Say hello in one word."
        let limit = Double(env["REEVE_SMOKE_SECONDS"] ?? "") ?? 150
        let started = Date()
        var shot = 0
        var sawClassify = false
        var acceptedTrust = false
        var typed = false
        var interrupted: Date?
        var timeline: [String] = []
        var lastActivity: Activity?
        var lastTitle: String?
        var cardId: UUID?
        var lastLog: String?
        var lastStage: Stage?
        let vibes = env["REEVE_SMOKE_VIBES"] != nil

        func log(_ line: String) {
            let entry = String(format: "%6.1fs ", Date().timeIntervalSince(started)) + line
            timeline.append(entry)
            FileHandle.standardError.write(Data(("reeve smoke: " + entry + "\n").utf8))
        }

        log("mode \(mode) in \(dir)")
        if mode == "resume", let card = board.cards.first {
            board.select(card.id)
        } else {
            if vibes, env["REEVE_SMOKE_START"] == "plan" { board.vibesOptions.skipPlanning = false }
            board.create(
                cwd: dir, title: "", prompt: prompt, mode: env["REEVE_SMOKE_START"] == "plan" ? .plan : .build,
                model: env["REEVE_SMOKE_MODEL"], effort: env["REEVE_SMOKE_EFFORT"], vibes: vibes && env["REEVE_SMOKE_VIBES"] != "board"
            )
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                let elapsed = Date().timeIntervalSince(started)
                if board.vibesArming, !FileManager.default.fileExists(atPath: "\(out)/arming.png") {
                    snapshot(to: "\(out)/arming.png")
                }
                if cardId == nil { cardId = board.selectedId }
                guard let card = cardId.flatMap(board.card) else { return }
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
                if card.stage != lastStage {
                    lastStage = card.stage
                    log("stage \(card.stage.rawValue)")
                }
                if let line = card.vibesNudges.map({ "nudges \($0.stage.rawValue) ×\($0.count) ship \($0.askedToShip)" }), line != lastLog {
                    lastLog = line
                    log(line)
                }
                // Nobody watching: back to the board once the session is going.
                if vibes, board.selectedId == card.id, card.hasConversation {
                    log("back to the board")
                    board.dismissOpenCard()
                    // The board's switch, flipped where it can be seen.
                    if env["REEVE_SMOKE_VIBES"] == "board", board.vibes == nil { board.toggleVibes() }
                }
                if board.classifying.contains(card.id) { sawClassify = true }
                let sorted = vibes ? card.shippedAt != nil : mode != "interrupt" && sawClassify && !board.classifying.contains(card.id)
                if sorted || elapsed > limit {
                    timer.invalidate()
                    log("done: activity \(card.activity.rawValue) stage \(card.stage.rawValue) title \(card.title)")
                    snapshot(to: "\(out)/final.png")
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
                    if closing { log("closing card"); board.close(card.id) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (closing ? 5 : 1)) { exit(0) }
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
