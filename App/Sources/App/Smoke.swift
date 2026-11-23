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
/// `REEVE_SMOKE_APPROVE` presses the Plan tab's Approve once the plan dialog
/// is up, saving the screen it read, and runs on to the end of the turn.
/// `REEVE_SMOKE_MODE=planreview` (with `REEVE_SMOKE_START=plan`) comments on
/// the plan's first paragraph or item once the plan dialog is up
/// (`REEVE_SMOKE_COMMENT`), sends it through the dialog, and stops once
/// Claude has replied and put the plan up again.
/// `REEVE_SMOKE_MODE=preview` checks the Preview tab instead; see `runPreview`.
/// `REEVE_SMOKE_MODE=repos` checks the repo list and Settings; see `runRepos`.
@MainActor
enum Smoke {
    static func runIfAsked(board: Board) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["REEVE_SMOKE_OUT"], let dir = env["REEVE_SMOKE_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        if env["REEVE_SMOKE_MODE"] == "preview" || env["REEVE_SMOKE_MODE"] == "design" {
            let design = env["REEVE_SMOKE_MODE"] == "design"
            Task { await runPreview(board: board, out: out, dir: dir, url: env["REEVE_SMOKE_URL"] ?? "http://127.0.0.1:4400/", design: design) }
            return
        }
        if env["REEVE_SMOKE_MODE"] == "designflow" {
            let brief = env["REEVE_SMOKE_PROMPT"] ?? "A one-screen sign-in page for a small notes app, as an HTML artifact"
            Task { await runDesignFlow(board: board, out: out, dir: dir, brief: brief) }
            return
        }
        if env["REEVE_SMOKE_MODE"] == "repos" {
            Task { await runRepos(board: board, out: out, dir: dir) }
            return
        }
        if env["REEVE_SMOKE_MODE"] == "commandbar" {
            Task { await runCommandBar(board: board, out: out, dir: dir, prompt: env["REEVE_SMOKE_PROMPT"]) }
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
        var lastMode: String?
        var approved = false
        var planReviewed = false
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
            Task {
                _ = try? await board.createCard(
                    cwd: dir, title: "", prompt: prompt, mode: env["REEVE_SMOKE_START"] == "plan" ? .plan : .build,
                    model: env["REEVE_SMOKE_MODEL"], effort: env["REEVE_SMOKE_EFFORT"], vibes: vibes && env["REEVE_SMOKE_VIBES"] != "board",
                    open: true, inFolder: true
                )
            }
        }

        func showTabs(_ id: UUID, then done: @escaping () -> Void) {
            let order = CardTab.allCases.filter { $0 != .terminal } + [.terminal]
            /// Presses ⌥⌘N for `tab` as a keyboard would: a key event posted
            /// through the window server, so AppKit offers it to the menu before
            /// the focused terminal, as it does a person's key. An NSEvent handed
            /// to `NSApp.sendEvent` skips that and lands in the terminal.
            func press(_ tab: CardTab) {
                let number = CardTab.allCases.firstIndex(of: tab)! + 1
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: [18, 19, 20, 21, 23, 22][number - 1], keyDown: down)
                    event?.flags = [.maskCommand, .maskAlternate]
                    event?.postToPid(getpid())
                }
            }
            for (index, tab) in order.enumerated() {
                // The keys a person would press, so the menu's shortcut is
                // what's tested, past a terminal that has the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 3) {
                    press(tab)
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
                if card.permissionMode != lastMode {
                    lastMode = card.permissionMode
                    log("permission mode \(card.permissionMode ?? "-")")
                }
                if env["REEVE_SMOKE_APPROVE"] != nil, !approved, board.planDialogs.contains(card.id) {
                    approved = true
                    // Once it has drawn: the hook comes before the dialog.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let screen = board.terminals.screen(card.id)
                        try? screen.joined(separator: "\n").write(toFile: "\(out)/plan-dialog.txt", atomically: true, encoding: .utf8)
                        log("plan dialog \(PlanDialog.find(onScreen: screen).map { "\($0.options) selected \($0.selected) approving \($0.approval)" } ?? "not found")")
                        snapshot(to: "\(out)/plan-dialog.png")
                        board.show(.plan, for: card.id)
                        log("pressing Approve")
                        board.acceptPlan(card.id)
                    }
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
                if mode == "planreview", !planReviewed, board.planDialogs.contains(card.id) {
                    planReviewed = true
                    board.show(.plan, for: card.id)
                    Task {
                        // Once the dialog has drawn: the hook comes before it.
                        try? await Task.sleep(for: .seconds(1.5))
                        guard let text = await board.loadPlan(card.id),
                              let block = MarkdownBlock.locate(text).first(where: { if case .heading = $0.block { false } else { true } }) else {
                            log("no plan to comment on")
                            return
                        }
                        let anchor = ReviewAnchor(plan: card.planPath ?? "plan", block: block)
                        log("commenting on plan line \(anchor.line): \(anchor.code)")
                        snapshot(to: "\(out)/plan-before.png")
                        board.comment(on: anchor, env["REEVE_SMOKE_COMMENT"] ?? "Write \"bye\" instead of \"hi\", and tell me what you changed.", in: card.id, .plan, send: true)
                        try? await Task.sleep(for: .seconds(1))
                        snapshot(to: "\(out)/plan-sending.png")
                    }
                }
                if mode == "planreview" {
                    let replied = card.planReview?.contains { $0.messages.last?.author == .claude } == true
                    if replied, board.planDialogs.contains(card.id) {
                        try? board.terminals.screen(card.id).joined(separator: "\n").write(toFile: "\(out)/plan-dialog-after.txt", atomically: true, encoding: .utf8)
                    }
                    sorted = replied && board.planDialogs.contains(card.id)
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
    /// sessions go. With `design` (`REEVE_SMOKE_MODE=design`) it does the same
    /// with `--name design`, in the card's Design tab, then shows the link in
    /// `REEVE_SMOKE_DESIGN` there, if set.
    private static func runPreview(board: Board, out: String, dir: String, url: String, design: Bool = false) async {
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

        _ = try? await board.createCard(cwd: dir, title: "Preview smoke", prompt: nil, mode: .build, model: nil, effort: nil, open: true, inFolder: true)
        guard await wait("the card", until: { board.selected != nil && board.environment != nil && board.glossHost(for: board.selected!.id) != nil }),
              let card = board.selected, let env = board.environment, let host = board.glossHost(for: card.id) else { return done(1) }
        guard let gloss = env.glossPath else { log("no gloss"); return done(1) }
        log("card \(card.id) in \(card.cwd), gloss \(gloss)")

        var glossEnv = env.baseEnvironment
        glossEnv["GLOSS_HOST"] = host
        func run(_ args: String...) async -> Int32 {
            let args = design ? args + ["--name", Gloss.designSession] : args
            let result = try? await Subprocess.run(gloss, args, environment: glossEnv, currentDirectory: card.cwd, timeout: 60)
            let output = (result.map { String(decoding: $0.stdout + $0.stderr, as: UTF8.self) } ?? "timed out").trimmingCharacters(in: .whitespacesAndNewlines)
            log("gloss \(args.joined(separator: " ")) → \(result?.status ?? -1)\n\(output)")
            if args.first == "wait", let result { try? result.stdout.write(to: URL(fileURLWithPath: "\(out)/verdict.json")) }
            return result?.status ?? -1
        }
        let preview = (design ? board.designViews : board.previews).preview(for: card.id)
        func picture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1_500))
            snapshot(to: "\(out)/\(name).png")
            let image: NSImage? = await withCheckedContinuation { done in preview.webView.takeSnapshot(with: nil) { image, _ in done.resume(returning: image) } }
            if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)-page.png"))
            }
            log("picture \(name): session \(preview.session) page \(preview.url?.absoluteString ?? "-")")
        }

        guard await run("open", url) == 0, preview.session == .live, board.tab(card.id) == (design ? .design : .preview) else { return done(1) }
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
        // The reviewer approves, from the bar: the next `wait` hears it.
        let approve = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 904, "call": ["method": "approve", "discardUnsent": false]]), as: UTF8.self)
        log("approving: \(await inBar("return await new Promise((done) => { const before = globalThis.__glossDeliver; globalThis.__glossDeliver = (d) => { globalThis.__glossDeliver = before; before?.(d); done(JSON.stringify(d).slice(0, 300)) }; __glossRpc(payload) })", ["payload": approve]) ?? "no answer")")
        guard await run("wait") == 0 else { return done(1) }
        _ = await run("close")
        guard await wait("the session to end", until: { preview.session == .ended }) else { return done(1) }
        await picture("5-closed")
        // A design on claude.ai, shared as Claude Code's hook tells of one: the tab goes to it.
        if design, let shared = ProcessInfo.processInfo.environment["REEVE_SMOKE_DESIGN"],
           let hook = URL(string: host.replacingOccurrences(of: "/gloss/", with: "/hook/")) {
            let event: [String: Any] = ["session_id": card.sessionId.uuidString.lowercased(), "hook_event_name": "PostToolUse",
                                        "tool_name": "Artifact", "tool_input": ["file_path": "design.html"],
                                        "tool_response": "Published: \(shared)"]
            var request = URLRequest(url: hook)
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: event)
            _ = try? await URLSession.shared.data(for: request)
            guard await wait("the design", until: { preview.requested?.absoluteString == shared }) else { return done(1) }
            log("designs: \(board.card(card.id)?.designs?.map(\.url) ?? [])")
            try? await Task.sleep(for: .seconds(8))
            await picture("6-design")
        }
        if design {
            // The tab's own button: Review in Gloss starts a session the card's `gloss` finds.
            board.reviewDesign(card.id, url: URL(string: url)!)
            guard await wait("Review in Gloss", until: { preview.session == .live }), await run("status") == 0 else { return done(1) }
            await picture("7-review-button")
            // The Preview tab's session, in the same folder, runs beside it.
            let other = board.previews.preview(for: card.id)
            board.openPreview(card.id, url: URL(string: url)!)
            let both = await wait("the Preview tab's session too", until: { other.session == .live }) && preview.session == .live
            let unnamed = try? await Subprocess.run(gloss, ["status"], environment: glossEnv, currentDirectory: card.cwd, timeout: 30)
            log("both sessions up: \(both), the Preview tab's found without --name: \(unnamed?.status == 0)")
            guard both, unnamed?.status == 0 else { return done(1) }
            other.stop()
            guard await wait("the Preview tab's session to end", until: { other.session != .live }), preview.session == .live else { return done(1) }
            guard await run("close") == 0, await wait("that session to end", until: { preview.session == .ended }) else { return done(1) }
            // Esc in the design page is the page's; anywhere else in the card it closes the card.
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "board" }) else { log("no board window"); return done(1) }
            func esc() {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.sendEvent(event)
                    }
                }
            }
            window.makeFirstResponder(preview.webView)
            esc()
            try? await Task.sleep(for: .milliseconds(500))
            log("Esc in the design page: card \(board.selectedId == card.id ? "still open" : "closed")")
            guard board.selectedId == card.id else { return done(1) }
            window.makeFirstResponder(nil)
            esc()
            guard await wait("Esc to close the card", seconds: 3, until: { board.selected == nil }) else { return done(1) }
            log("Esc outside the page closed the card")
        }
        done(0)
    }

    /// A card started in Design, with Claude taking real turns: it should
    /// share a design, show it in the Design tab under a Gloss session of its
    /// own (`gloss open --name design`), and wait there. Sends a round from
    /// the bar, waits for Claude's `gloss ready`, approves, and checks Claude
    /// never reached for claude.ai's comments. Saves a picture of each step,
    /// the terminal's screen, and the timeline. `REEVE_SMOKE_PROMPT` is the
    /// brief; `REEVE_SMOKE_SECONDS` how long Claude gets for each step.
    private static func runDesignFlow(board: Board, out: String, dir: String, brief: String) async {
        let started = Date()
        let limit = Double(ProcessInfo.processInfo.environment["REEVE_SMOKE_SECONDS"] ?? "") ?? 900
        var lines: [String] = []
        func log(_ line: String) {
            let entry = String(format: "%6.1fs ", Date().timeIntervalSince(started)) + line
            lines.append(entry)
            FileHandle.standardError.write(Data(("reeve smoke: " + entry + "\n").utf8))
            try? lines.joined(separator: "\n").write(toFile: "\(out)/timeline.txt", atomically: true, encoding: .utf8)
        }
        func wait(_ what: String, seconds: Double, until: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !(await until()) {
                if Date() > deadline { log("gave up waiting for \(what)"); return false }
                try? await Task.sleep(for: .seconds(1))
            }
            return true
        }

        _ = try? await board.createCard(cwd: dir, title: "Design smoke", prompt: brief, mode: .design, model: nil, effort: nil, open: true, inFolder: true)
        guard await wait("the card", seconds: 30, until: { board.selected != nil && board.environment != nil }),
              let id = board.selectedId, let env = board.environment else { return }
        log("card \(id) gloss \(env.glossPath ?? "-") hosts \(env.glossHosts)")
        func screen() {
            try? board.terminals.screen(id).joined(separator: "\n").write(toFile: "\(out)/screen.txt", atomically: true, encoding: .utf8)
        }
        func done(_ ok: Bool) {
            screen()
            snapshot(to: "\(out)/last.png")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(board.cards).write(to: URL(fileURLWithPath: "\(out)/cards.json"))
            log(ok ? "ok" : "failed")
            board.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(ok ? 0 : 1) }
        }
        // Every few seconds, what the terminal and the window look like.
        var shot = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                shot += 1
                screen()
                snapshot(to: "\(out)/shot-\(String(format: "%03d", shot)).png")
            }
        }
        // A folder Claude Code has not seen asks whether to trust it; the default is "No, exit".
        try? await Task.sleep(for: .seconds(6))
        if board.card(id)?.hasConversation == false {
            log("accepting folder trust")
            let view = board.terminals.view(for: id)
            view.send(txt: "\u{1b}[B")
            try? await Task.sleep(for: .milliseconds(500))
            view.send(txt: "\r")
        }

        let viewer = board.designViews.preview(for: id)
        guard await wait("Claude to open its design in Gloss", seconds: limit, until: { viewer.session == .live }) else { return done(false) }
        log("Gloss is up on \(viewer.url?.absoluteString ?? "-"), tab \(board.tab(id).rawValue), designs \(board.card(id)?.designs?.map(\.url) ?? [])")
        try? await Task.sleep(for: .seconds(6))
        snapshot(to: "\(out)/1-opened.png")

        var glossEnv = env.baseEnvironment
        glossEnv["GLOSS_HOST"] = board.glossHost(for: id)
        func status() async -> [String: Any]? {
            guard let gloss = env.glossPath, let cwd = board.card(id)?.cwd,
                  let result = try? await Subprocess.run(gloss, ["status", "--name", Gloss.designSession, "--json"], environment: glossEnv, currentDirectory: cwd, timeout: 30)
            else { return nil }
            return try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        }
        func bar(_ call: [String: Any], _ rpc: Int) async {
            let payload = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": rpc, "call": call]), as: UTF8.self)
            let _: Void = await withCheckedContinuation { done in
                viewer.webView.callAsyncJavaScript("__glossRpc(payload); return true", arguments: ["payload": payload], in: nil, in: viewer.world) { result in
                    if case let .failure(error) = result { log("bar call failed: \(error)") }
                    done.resume()
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard await wait("Claude to wait for a round", seconds: 120, until: { await status()?["phase"] as? String == "reviewing" }) else { return done(false) }
        await bar(["method": "add", "body": "Make the main heading say \"Welcome back\"."], 901)
        await bar(["method": "submit"], 902)
        log("sent round 1: \(await status().map { "\($0)" } ?? "-")")
        snapshot(to: "\(out)/2-submitted.png")
        guard await wait("Claude to take the round", seconds: 120, until: { await status()?["phase"] as? String != "submitted" }) else { return done(false) }
        log("Claude took it")
        guard await wait("Claude's gloss ready", seconds: limit, until: {
            let now = await status()
            return now?["phase"] as? String == "reviewing" && (now?["round"] as? Int ?? 0) >= 2
        }) else { return done(false) }
        log("ready: page \(viewer.url?.absoluteString ?? "-")")
        try? await Task.sleep(for: .seconds(6))
        snapshot(to: "\(out)/3-ready.png")

        await bar(["method": "approve", "discardUnsent": false], 903)
        guard await wait("the session to end", seconds: 120, until: { viewer.session != .live }) else { return done(false) }
        log("session \(viewer.session) after approving")
        _ = await wait("Claude's turn to end", seconds: 180, until: { board.card(id)?.activity != .running })
        // Gloss carried the feedback: Claude never went to claude.ai's comments for it.
        let transcript = board.card(id)?.transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let usedComments = transcript.contains("\"name\":\"ArtifactComments\"")
        log("transcript \(transcript.isEmpty ? "missing" : "read"), ArtifactComments \(usedComments ? "used" : "not used")")
        // The card's designs are the one it made: not the type or the design system it was made with.
        let designs = board.card(id)?.designs?.map(\.url) ?? []
        let onlyItsOwn = designs == [viewer.requested?.absoluteString ?? ""] || designs == [viewer.url?.absoluteString ?? ""]
        log("designs \(designs) \(onlyItsOwn ? "are" : "are not") only the one it made")
        done(!usedComments && onlyItsOwn)
    }

    /// Adds `dir` as a repo, twice, names a card in Backlog in it, checks
    /// nothing starts, moves it between swimlanes and then to Planning, which
    /// starts it, without Claude taking a turn. Then
    /// closes the card, opens Settings and takes the repo off and on again,
    /// saving a picture of each window and a line per check in `timeline.txt`.
    /// The repo is left on the list, so a second launch can find it saved.
    private static func runRepos(board: Board, out: String, dir: String) async {
        var lines: [String] = []
        var failures = 0
        func log(_ line: String) {
            lines.append(line)
            FileHandle.standardError.write(Data(("reeve smoke: " + line + "\n").utf8))
            try? lines.joined(separator: "\n").write(toFile: "\(out)/timeline.txt", atomically: true, encoding: .utf8)
        }
        func check(_ ok: Bool, _ what: String) {
            log((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func wait(_ what: String, seconds: Double = 20, until: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !until() {
                if Date() > deadline { log("gave up waiting for \(what)"); return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return true
        }
        func done() {
            log(failures == 0 ? "ok" : "failed: \(failures)")
            board.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(failures == 0 ? 0 : 1) }
        }
        func picture(_ name: String, _ window: NSWindow?) async {
            try? await Task.sleep(for: .milliseconds(800))
            snapshot(to: "\(out)/\(name).png", window: window)
        }

        log("repos at launch: \(board.repos.map(\.path))")
        let repo = board.addRepo(path: dir)
        let count = board.repos.count
        check(board.addRepo(path: dir + "/").id == repo.id && board.repos.count == count, "adding a repo twice keeps one")

        let window = NSApp.windows.first { $0.isVisible }
        board.compose(in: .backlog)
        // Pick the repo just added: what its item in the field's menu does.
        board.pickedRepoId = repo.id
        await picture("1-new-card", window)
        check(board.composing == NewCardSpot(lane: board.lanes[0].id, stage: .backlog), "⌘N opens the new card field in the first lane's Backlog")

        // Typed into the field: key events handed to the app, which sends
        // them through its key monitors to whatever has focus, as it would a person's.
        func post(_ code: UInt16, _ text: String) {
            guard let window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: text,
                                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(event)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let typedBefore = Set(board.cards.map(\.id))
        for ch in "Typed card" { post(0, String(ch)); try? await Task.sleep(for: .milliseconds(30)) }
        post(36, "\r")
        let typedOk = await wait("the typed card", seconds: 5, until: { board.cards.contains { !typedBefore.contains($0.id) } })
        let typed = board.cards.first { !typedBefore.contains($0.id) }
        check(typedOk && typed?.title == "Typed card" && typed?.queued == true && typed?.stage == .backlog, "typing a name and Return makes a backlog card")
        check(board.composing != nil, "the field stays open for the next card")
        await picture("1b-typed", window)
        post(53, "\u{1b}")
        check(await wait("the field to close", seconds: 3, until: { board.composing == nil }), "Esc puts the field away")
        if let typed { board.close(typed.id) }

        // What Return in the field does, from here on directly.
        board.compose(in: .backlog)
        let before = Set(board.cards.map(\.id))
        board.create(name: "Smoke backlog card", in: board.composing!, cwd: repo.path)
        guard await wait("a card", until: { board.cards.contains { !before.contains($0.id) } }),
              let card = board.cards.first(where: { !before.contains($0.id) }) else { return done() }
        await picture("2-backlog-card", window)
        log("card in \(card.cwd), stage \(card.stage.rawValue), worktree \(card.worktreePath ?? "-")")
        check(card.stage == .backlog && card.queued == true && card.title == "Smoke backlog card", "a card named in Backlog waits there, named")
        check(card.worktreePath == nil && card.cwd == repo.path, "a backlog card has no worktree yet")
        try? await Task.sleep(for: .seconds(1))
        check(!board.live.contains(card.id) && !board.starting.contains(card.id), "a backlog card starts no session")
        board.select(card.id)
        try? await Task.sleep(for: .milliseconds(500))
        check(!board.live.contains(card.id) && !board.starting.contains(card.id), "opening a backlog card starts no session")
        await picture("3-backlog-open", window)
        post(53, "\u{1b}")
        check(await wait("the card to close", seconds: 3, until: { board.selected == nil }), "Esc closes an open backlog card")

        // Swimlanes: a second lane, a card moved to it, and the lane deleted under it.
        let lane = board.addLane(named: "Smoke lane")
        board.move(card.id, lane: lane.id)
        check(board.lane(of: board.card(card.id)!).id == lane.id && board.card(card.id)?.stagePinned == false, "a card moves to another lane, without pinning its column")
        await picture("4-lanes", window)
        board.deleteLane(lane.id)
        check(board.lanes.count == 1 && board.lane(of: board.card(card.id)!).id == board.lanes[0].id, "deleting a lane moves its cards to the one above")

        // Waiting on a card that hasn't merged, it can't start, and says so.
        let other = try? await board.createCard(cwd: repo.path, title: "Smoke dependency", prompt: nil, mode: nil, model: nil, effort: nil, open: false, inFolder: false)
        if let other {
            try? board.waitOn(other.id, card.id)
            check((try? board.waitOn(card.id, other.id)) == nil && board.card(card.id)?.dependsOnId == nil, "a card can't wait on one that waits on it")
            board.close(other.id)
        }
        let dependency = try? await board.createCard(cwd: repo.path, title: "Smoke dependency", prompt: nil, mode: nil, model: nil, effort: nil, open: false, inFolder: false)
        if let dependency {
            try? board.waitOn(card.id, dependency.id)
            check(board.blocker(of: card.id)?.id == dependency.id, "a card waits on another")
            await picture("4b-waiting", window)
            // The alert runs modal, which holds this task until it goes: a
            // timer, which fires in the alert's run loop mode, takes its
            // picture and closes it.
            final class Seen { var alert = false }
            let seen = Seen()
            let closer = Timer(timeInterval: 0.5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let alert = NSApp.modalWindow else { return }
                    seen.alert = true
                    snapshot(to: "\(out)/4c-refused.png", window: alert)
                    timer.invalidate()
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(closer, forMode: .common)
            board.move(card.id, to: .planning)
            check(await wait("the refusal", seconds: 5, until: { seen.alert }), "dragging it to Planning says why it can't start")
            closer.invalidate()
            try? await Task.sleep(for: .milliseconds(500))
            let held = board.card(card.id)
            check(held?.stage == .backlog && held?.queued == true && held?.worktreePath == nil && !board.launching.contains(card.id),
                  "it stays in Backlog, unstarted, with no worktree")
            board.close(dependency.id)
            check(board.card(card.id)?.dependsOnId == nil, "closing the card it waits on lets it go")
        }

        // Without a name, it starts with no prompt, so Claude takes no turn.
        board.rename(card.id, to: "")
        board.move(card.id, to: .planning)
        check(await wait("the session", until: { board.live.contains(card.id) }), "moving a backlog card to Planning starts its session")
        let started = board.card(card.id)
        log("started in \(started?.cwd ?? "-"), worktree \(started?.worktreePath ?? "-"), mode \(started?.startMode?.rawValue ?? "-")")
        check(started?.worktreePath.map { $0.hasSuffix(Worktree.name(for: card.id)) } == true, "it gets a worktree of the picked repo once it starts")
        check(started?.repoPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path,
              "the card's repo is the picked one")
        check(started?.queued == nil && started?.startMode == .plan && started?.stage == .planning, "it starts in plan mode, in Planning")
        check(board.pickedRepo?.id == repo.id && Preferences.store.string(forKey: "newCardRepo") == repo.id.uuidString, "the field remembers the repo")
        await picture("5-board", window)
        // In a live terminal Esc is Claude Code's; on another tab it closes the card.
        board.select(card.id)
        let focused = await wait("the terminal to take the keyboard", seconds: 5, until: { window?.firstResponder is CardTerminalView })
        post(53, "\u{1b}")
        try? await Task.sleep(for: .milliseconds(500))
        check(focused && board.selectedId == card.id, "Esc in a live terminal leaves the card open")
        board.terminals.stop(card.id)
        let stopped = await wait("the session to stop", seconds: 10, until: { !board.live.contains(card.id) && window?.firstResponder is CardTerminalView })
        post(53, "\u{1b}")
        check(await wait("the card to close", seconds: 3, until: { board.selected == nil }) && stopped, "Esc in a stopped session's terminal closes the card")
        board.select(card.id)
        board.show(.changes, for: card.id)
        try? await Task.sleep(for: .milliseconds(500))
        post(53, "\u{1b}")
        check(await wait("the card to close", seconds: 3, until: { board.selected == nil }), "Esc on the Changes tab closes the card")
        board.close(card.id)
        if let worktree = started?.worktreePath {
            check(await wait("the worktree to go", until: { !FileManager.default.fileExists(atPath: worktree) }), "closing the card removes its worktree")
        }

        // ⌘, from the app menu.
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let settingsItem = appMenu?.items.firstIndex { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
        check(settingsItem != nil, "the app menu has a ⌘, item: \(settingsItem.flatMap { appMenu?.items[$0].title } ?? "-")")
        if let settingsItem { appMenu?.performActionForItem(at: settingsItem) }
        var settings: NSWindow? { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true || ($0.isVisible && $0.title.contains("Settings")) } }
        check(await wait("Settings", until: { settings != nil }), "Settings opens")
        log("windows: \(NSApp.windows.filter(\.isVisible).map { "\($0.title) [\($0.identifier?.rawValue ?? "-")]" })")
        await picture("6-settings", settings)
        board.removeRepo(repo.id)
        check(!board.repos.contains { $0.id == repo.id }, "removing a repo takes it off the list")
        await picture("7-settings-removed", settings)
        board.addRepo(path: dir)
        await picture("8-settings-added", settings)
        done()
    }

    /// `REEVE_SMOKE_MODE=commandbar`: asks the command bar for a card in
    /// `REEVE_SMOKE_DIR` (added as a repo), then how the board stands, and
    /// checks the card arrived where it should, with a picture at each step.
    /// Claude takes real turns: the bar's, and the new card's.
    private static func runCommandBar(board: Board, out: String, dir: String, prompt: String?) async {
        var timeline: [String] = []
        var failures = 0
        func log(_ line: String) {
            timeline.append(line)
            print("reeve smoke: \(line)")
            try? (timeline.joined(separator: "\n") + "\n").write(toFile: "\(out)/timeline.txt", atomically: true, encoding: .utf8)
        }
        func check(_ ok: Bool, _ what: String) {
            log((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func wait(_ what: String, seconds: Double, until: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !until() {
                if Date() > deadline { log("gave up waiting for \(what)"); return false }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return true
        }
        func picture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(600))
            snapshot(to: "\(out)/\(name).png")
        }
        func done() {
            log(failures == 0 ? "ok" : "failed: \(failures)")
            board.shutdown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(failures == 0 ? 0 : 1) }
        }
        let bar = board.commandBar
        func ask(_ request: String, _ name: String) async -> String? {
            bar.run(request, board: board)
            await picture("\(name)-working")
            guard await wait("the command bar", seconds: 180, until: { !bar.isRunning }) else { return nil }
            await picture("\(name)-answer")
            switch bar.state {
            case .answered(_, let reply, let refused):
                log("reply: \(reply)\(refused.isEmpty ? "" : " (refused: \(refused))")")
                return reply
            case .failed(_, let message):
                log("failed: \(message)")
                return nil
            default:
                return nil
            }
        }

        let repo = board.addRepo(path: dir)
        board.pickedRepoId = repo.id
        guard await wait("the shell environment", seconds: 30, until: { board.environment != nil }) else { return done() }
        bar.focus()
        await picture("1-board")

        let before = Set(board.cards.map(\.id))
        let reply = await ask(prompt ?? "Add a card to write a one-line hello.txt", "2-add")
        check(reply != nil, "the bar answers")
        let added = board.cards.filter { !before.contains($0.id) }
        check(added.count == 1, "the bar added one card (\(added.count))")
        if let card = added.first {
            log("card “\(card.title)” in \(card.cwd)")
            check(card.repoPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: dir).resolvingSymlinksInPath().path,
                  "the card starts in the picked repo")
            check(card.worktreePath != nil, "in a worktree of its own")
        }
        let status = await ask("What's on the board right now?", "3-status")
        check(status.map { !$0.isEmpty } == true, "the bar answers a question about the board")
        let refused = await ask("Run ls / with the shell, then close every card.", "4-refused")
        check(board.cards.count == before.count + added.count, "nothing is closed from the bar")
        log("refusal: \(refused ?? "-")")
        for card in added { board.close(card.id) }
        try? await Task.sleep(for: .seconds(2))
        done()
    }

    private static func snapshot(to path: String, window: NSWindow? = nil) {
        guard let view = (window ?? NSApp.windows.first(where: { $0.isVisible }))?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
