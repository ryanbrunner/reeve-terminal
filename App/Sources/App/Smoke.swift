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
/// `REEVE_SMOKE_VIBES=1` puts the card in VIBES MODE and goes back to the board
/// once it has started, so nobody is watching; it runs until the card ships.
/// `REEVE_SMOKE_VIBES=board` flips the whole board's switch as well.
/// `REEVE_SMOKE_MODEL` and `REEVE_SMOKE_EFFORT` pick the card's model and effort.
/// `REEVE_SMOKE_MODE=preview` checks the Preview tab instead; see `runPreview`.
@MainActor
enum Smoke {
    static func runIfAsked(board: Board) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REEVE_SMOKE_OUT"], let dir = env["REEVE_SMOKE_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        if env["REEVE_SMOKE_MODE"] == "preview" {
            Task { await runPreview(board: board, out: out, dir: dir, url: env["REEVE_SMOKE_URL"] ?? "http://127.0.0.1:4400/") }
            return
        }
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
                                                     charactersIgnoringModifiers: String(number), isARepeat: false, keyCode: [18, 19, 20, 21][number - 1])
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
                if let line = card.vibesNudges.map({ "nudges \($0.stage.rawValue) ×\($0.count) answers \($0.answers) ship \($0.askedToShip)" }), line != lastLog {
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
                var sorted = vibes ? card.shippedAt != nil : mode != "interrupt" && sawClassify && !board.classifying.contains(card.id)
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

    /// A card's Preview, hosted for Gloss, driven as the card's Claude would
    /// drive it: makes a card in the folder with no prompt, then runs
    /// `gloss open <REEVE_SMOKE_URL>` there with the card's GLOSS_HOST, sends a
    /// round from the bar's world (a comment, and one pinned to the first
    /// element matching `REEVE_SMOKE_PIN`, `h2` unless set), and runs `gloss wait`, `working`, `ready` and `close`,
    /// saving the verdict, a log of each command and pictures as it goes.
    /// `REEVE_GLOSS` picks the gloss to run, and `GLOSS_HOME` where its
    /// sessions go.
    private static func runPreview(board: Board, out: String, dir: String, url: String) async {
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
            FileHandle.standardError.write(Data(("reeve smoke: " + line + "\n").utf8))
            try? lines.joined(separator: "\n").write(toFile: "\(out)/timeline.txt", atomically: true, encoding: .utf8)
        }
        func wait(_ what: String, seconds: Double = 20, until: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !until() {
                if Date() > deadline { log("gave up waiting for \(what)"); return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return true
        }
        func done(_ code: Int32) {
            log(code == 0 ? "ok" : "failed")
            board.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(code) }
        }

        board.create(cwd: dir, title: "Preview smoke", prompt: nil, mode: .build)
        guard await wait("the card", until: { board.selected != nil && board.environment != nil && board.glossHost(for: board.selected!.id) != nil }),
              let card = board.selected, let env = board.environment, let host = board.glossHost(for: card.id) else { return done(1) }
        guard let gloss = env.glossPath else { log("no gloss"); return done(1) }
        log("card \(card.id) in \(card.cwd), gloss \(gloss)")

        var glossEnv = env.baseEnvironment
        glossEnv["GLOSS_HOST"] = host
        func run(_ args: String...) async -> Int32 {
            let result = try? await Subprocess.run(gloss, args, environment: glossEnv, currentDirectory: card.cwd, timeout: 60)
            let output = (result.map { String(decoding: $0.stdout + $0.stderr, as: UTF8.self) } ?? "timed out").trimmingCharacters(in: .whitespacesAndNewlines)
            log("gloss \(args.joined(separator: " ")) → \(result?.status ?? -1)\n\(output)")
            if args.first == "wait", let result { try? result.stdout.write(to: URL(fileURLWithPath: "\(out)/verdict.json")) }
            return result?.status ?? -1
        }
        let preview = board.previews.preview(for: card.id)
        func picture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1_500))
            snapshot(to: "\(out)/\(name).png")
            let image: NSImage? = await withCheckedContinuation { done in preview.webView.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) } }
            if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)-page.png"))
            }
            log("picture \(name): session \(preview.session) page \(preview.url?.absoluteString ?? "-")")
        }

        guard await run("open", url) == 0, preview.session == .live, board.tab(card.id) == .preview else { return done(1) }
        await picture("1-opened")

        // The completion-handler form: the async one never comes back on some macOS versions.
        func inBar(_ js: String, _ arguments: [String: Any]) async -> Any? {
            await withCheckedContinuation { done in
                preview.webView.callAsyncJavaScript(js, arguments: arguments, in: nil, in: preview.world) { result in
                    if case let .failure(error) = result { log("script failed: \(error)") }
                    done.resume(returning: try? result.get())
                }
            }
        }

        // A client-side route change, as an app's router makes: the comments' page should follow it.
        _ = try? await preview.webView.evaluateJavaScript("history.pushState(null, '', '/routed'); true")
        // What the bar does when a person adds comments and submits, through the bar's own channel.
        let selector = ProcessInfo.processInfo.environment["REEVE_SMOKE_PIN"] ?? "h2"
        let box = await inBar(
            "const r = document.querySelector(selector).getBoundingClientRect(); return {x: r.x + scrollX, y: r.y + scrollY, width: r.width, height: r.height}",
            ["selector": selector])
        log("pinning \(selector) at \(box ?? "nothing")")
        let pin: [String: Any] = ["url": preview.url?.absoluteString ?? url, "selector": selector, "tag": "h2", "text": "smoke",
                                  "box": box ?? [:], "viewport": ["width": 800, "height": 600]]
        for (id, call) in [(901, ["method": "add", "body": "Make the header bigger"] as [String: Any]),
                           (902, ["method": "add", "body": "This heading", "pin": pin]),
                           (903, ["method": "submit"])] {
            let payload = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": id, "call": call]), as: UTF8.self)
            _ = await inBar("__glossRpc(payload); return true", ["payload": payload])
            try? await Task.sleep(for: .milliseconds(500))
        }
        await picture("2-submitted")
        guard await run("wait") == 0 else { return done(1) }
        // Gloss takes the pinned element's picture away with the session; keep it to look at.
        if let data = FileManager.default.contents(atPath: "\(out)/verdict.json"),
           let verdict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let comments = verdict["comments"] as? [[String: Any]],
           let shot = comments.compactMap({ ($0["target"] as? [String: Any])?["screenshot"] as? String }).first {
            try? FileManager.default.copyItem(atPath: shot, toPath: "\(out)/pin.png")
            log("pin picture \(FileManager.default.fileExists(atPath: "\(out)/pin.png") ? "kept" : "missing")")
        }
        _ = await run("working", "Making the header bigger")
        await picture("3-working")
        _ = await run("ready", "Made the header bigger")
        await picture("4-ready")
        _ = await run("close")
        guard await wait("the session to end", until: { preview.session == .ended }) else { return done(1) }
        await picture("5-closed")
        done(0)
    }

    private static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
