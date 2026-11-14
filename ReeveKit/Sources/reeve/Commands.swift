import Foundation
import ReeveKit

/// One command: what it takes, its help, and what it does. `run` returns the
/// exit code; most commands succeed with `.ok` or throw.
struct Verb {
    var name: String
    var usage: String
    var valued: Set<String> = []
    var flags: Set<String> = []
    var short: [Character: String] = [:]
    var run: (Arguments) async throws -> ExitCode
}

/// `reeve <name>`.
let topVerbs: [Verb] = [boardVerb, statusVerb, openVerb, vibesVerb, modelsVerb, doctorVerb]

/// `reeve card <name>`.
let cardVerbs: [Verb] = [
    addVerb, showVerb, planVerb, editVerb, moveVerb, runVerb, replyVerb,
    waitVerb, closeVerb, worktreeVerb, prVerb, diffVerb,
]

/// The card a verb names as its only positional, or none for the current card.
private func onlyCard(_ args: Arguments) throws -> String? {
    guard args.positionals.count <= 1 else { throw UsageError("one card at a time") }
    return args.positionals.first
}

private func path(_ id: UUID) -> String {
    "/api/cards/\(id.uuidString)"
}

// MARK: Reading

let boardVerb = Verb(
    name: "board",
    usage: """
    reeve board [--stage STAGE] [--repo PATH] [--json]

    Every card, column by column: id, status, folder, title.
      --stage   just one column
      --repo    just the cards from the repo or folder at PATH
    """,
    valued: ["stage", "repo"], flags: ["json"]
) { args in
    let client = try Client.connect()
    var board = try await client.board()
    var stages = Stage.allCases
    if let name = args.value("stage") {
        guard let stage = StageName.parse(name) else { throw UsageError("unknown stage “\(name)”: \(StageName.accepted)") }
        stages = [stage]
        board.cards = board.cards.filter { $0.card.stage == stage }
    }
    if let repo = args.value("repo") {
        let wanted = realpath((repo as NSString).expandingTildeInPath)
        board.cards = board.cards.filter { realpath($0.card.repoPath ?? $0.card.cwd) == wanted }
    }
    if args.has("json") {
        try printJSON(board)
        return .ok
    }
    var sections: [String] = []
    if let ledger = board.vibes {
        sections.append("VIBES MODE since \(when(ledger.since))")
    }
    for stage in stages {
        let cards = board.cards.filter { $0.card.stage == stage }
        var section = "\(stage.label) (\(cards.count))"
        if !cards.isEmpty {
            section += "\n" + Table.format(cards.map { [$0.short, $0.status, $0.card.folderName, $0.displayTitle] }, indent: "  ")
        }
        sections.append(section)
    }
    out(sections.joined(separator: "\n\n"))
    return .ok
}

let showVerb = Verb(
    name: "show",
    usage: """
    reeve card show [<card>] [--json]

    One card: where it is, what it's doing, its summary and its plan.
    """,
    flags: ["json"]
) { args in
    let client = try Client.connect()
    let api = try await client.card(try onlyCard(args))
    if args.has("json") {
        try printJSON(api)
        return .ok
    }
    let card = api.card
    var facts: [[String]] = [
        ["Id", card.id.uuidString.lowercased()],
        ["Stage", "\(card.stage.label) · \(api.status)" + (card.stagePinned ? " (moved by hand)" : "")],
    ]
    if let waiting = card.waitingOn { facts.append(["Waiting on", waiting]) }
    facts.append(["Folder", card.cwd])
    if let repo = card.repoPath { facts.append(["Repo", repo]) }
    if let branch = card.branch { facts.append(["Branch", branch]) }
    if let worktree = card.worktreePath { facts.append(["Worktree", worktree]) }
    if let pr = card.pullRequest { facts.append(["PR", "#\(pr.number) \(pr.state.rawValue)  \(pr.url)"]) }
    let model = [card.model, card.effort].compactMap { $0 }.joined(separator: " · ")
    if !model.isEmpty { facts.append(["Model", model]) }
    if let mode = card.permissionMode ?? card.startMode?.permissionMode { facts.append(["Mode", mode]) }
    if card.vibes == true { facts.append(["Vibes", card.shippedAt == nil ? "on, for this card" : "shipped \(when(card.shippedAt!))"]) }
    if let line = card.backgroundLine { facts.append(["Background", line]) }
    facts.append(["Created", when(card.createdAt)])
    facts.append(["Updated", when(card.updatedAt)])
    var text = api.displayTitle + "\n" + Table.format(facts, indent: "  ")
    if let summary = card.summary, !summary.isEmpty {
        text += "\n\nSummary\n  " + summary
    }
    let plan: PlanResponse = try await client.get(path(card.id) + "/plan")
    if let plan = plan.text, !plan.isEmpty {
        text += "\n\nPlan\n" + plan.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
    }
    out(text)
    return .ok
}

let planVerb = Verb(
    name: "plan",
    usage: """
    reeve card plan [<card>] [--json]

    The plan Claude wrote in plan mode, as Markdown. Exits 1 when there is none.
    """,
    flags: ["json"]
) { args in
    let client = try Client.connect()
    let api = try await client.card(try onlyCard(args))
    let plan: PlanResponse = try await client.get(path(api.card.id) + "/plan")
    if args.has("json") {
        try printJSON(plan)
        return .ok
    }
    guard let text = plan.text, !text.isEmpty else { throw CLIError("\(api.short) has no plan yet") }
    out(text)
    return .ok
}

let diffVerb = Verb(
    name: "diff",
    usage: """
    reeve card diff [<card>] [--stat] [--json]

    Everything the card has changed since it started: its commits, what isn't
    committed yet, and new files.
      --stat   files and line counts only
    """,
    flags: ["stat", "json"]
) { args in
    let client = try Client.connect()
    let api = try await client.card(try onlyCard(args))
    let changes: ChangesResponse = try await client.get(path(api.card.id) + "/diff")
    if args.has("json") {
        try printJSON(changes)
        return .ok
    }
    if changes.files.isEmpty {
        note("No changes" + (changes.base.map { " since \($0)" } ?? ""))
        return .ok
    }
    if args.has("stat") {
        var rows = changes.files.map { [$0.path, $0.isBinary ? "binary" : "+\($0.additions) -\($0.deletions)"] }
        let added = changes.files.reduce(0) { $0 + $1.additions }, removed = changes.files.reduce(0) { $0 + $1.deletions }
        rows.append(["\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")", "+\(added) -\(removed)"])
        out(Table.format(rows))
    } else {
        FileHandle.standardOutput.write(Data(DiffParser.render(changes.files).utf8))
    }
    if changes.untrackedLeftOut > 0 { note("\(changes.untrackedLeftOut) new file(s) left out: too many or too big") }
    if changes.truncated { note("The diff was cut short.") }
    return .ok
}

let worktreeVerb = Verb(
    name: "worktree",
    usage: """
    reeve card worktree [<card>]

    The path of the card's worktree, for `cd "$(reeve card worktree <card>)"`.
    """
) { args in
    let api = try await Client.connect().card(try onlyCard(args))
    guard let worktree = api.card.worktreePath else {
        throw CLIError("\(api.short) has no worktree; it works in \(api.card.cwd)")
    }
    out(worktree)
    return .ok
}

let prVerb = Verb(
    name: "pr",
    usage: """
    reeve card pr [<card>] [--json]

    The URL of the pull request from the card's branch, looked up again with
    gh. Exits 1 when there is none. Claude opens pull requests; this doesn't.
    """,
    flags: ["json"]
) { args in
    let client = try Client.connect()
    let api = try await client.card(try onlyCard(args))
    let found: APICard = try await client.call("POST", path(api.card.id) + "/pull-request", body: [String: String]())
    if args.has("json") {
        try printJSON(found.card.pullRequest)
        return found.card.pullRequest == nil ? .error : .ok
    }
    guard let pr = found.card.pullRequest else {
        throw CLIError("\(api.short) has no pull request" + (api.card.branch.map { " from \($0)" } ?? ""))
    }
    out(pr.url)
    return .ok
}

let modelsVerb = Verb(
    name: "models",
    usage: """
    reeve models [--json]

    The models and effort levels a card can start with (`card add --model/--effort`).
    """,
    flags: ["json"]
) { args in
    if args.has("json") {
        try printJSON(["models": Launch.models, "efforts": Launch.efforts])
        return .ok
    }
    out(Table.format([["Models", Launch.models.joined(separator: ", ")], ["Efforts", Launch.efforts.joined(separator: ", ")]]))
    return .ok
}

let statusVerb = Verb(
    name: "status",
    usage: """
    reeve status [--json]

    Whether Reeve Terminal is running. Exits 0 if it is, 1 if not.
    """,
    flags: ["json"]
) { args in
    struct Status: Encodable {
        var running: Bool
        var port: UInt16?
        var cards: Int?
    }
    do {
        let client = try Client.connect()
        let board = try await client.board()
        if args.has("json") {
            try printJSON(Status(running: true, port: client.info.port, cards: board.cards.count))
        } else {
            out("Reeve Terminal is running on 127.0.0.1:\(client.info.port) with \(board.cards.count) card\(board.cards.count == 1 ? "" : "s")")
        }
        return .ok
    } catch let error as CLIError {
        if args.has("json") { try printJSON(Status(running: false)) }
        note(error.message)
        return .error
    }
}

let doctorVerb = Verb(
    name: "doctor",
    usage: """
    reeve doctor [--json]

    Checks what Reeve Terminal needs: git and claude (required), gh (for pull
    request badges), and whether the app is running. Exits 1 only when
    something required is missing.
    """,
    flags: ["json"]
) { args in
    struct Check: Encodable {
        var name: String
        var level: String
        var status: String
        var detail: String
    }
    func version(_ tool: String, _ flag: String = "--version") -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool, flag]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
    }
    var checks: [Check] = []
    for (tool, required) in [("git", true), ("claude", true), ("gh", false)] {
        if let found = version(tool) {
            checks.append(Check(name: tool, level: required ? "required" : "optional", status: "ok", detail: found))
        } else {
            checks.append(Check(name: tool, level: required ? "required" : "optional", status: required ? "fail" : "warn",
                                detail: "not found on PATH"))
        }
    }
    let app: Check
    do {
        let client = try Client.connect()
        _ = try await client.board()
        app = Check(name: "app", level: "info", status: "ok", detail: "running on 127.0.0.1:\(client.info.port)")
    } catch let error as CLIError {
        app = Check(name: "app", level: "info", status: "info", detail: error.message)
    }
    checks.append(app)
    checks.append(Check(name: "data", level: "info", status: "info", detail: DataDirectory.url().path))
    let ok = !checks.contains { $0.status == "fail" }
    if args.has("json") {
        struct Report: Encodable { var ok: Bool; var checks: [Check] }
        try printJSON(Report(ok: ok, checks: checks))
    } else {
        out(Table.format(checks.map { [$0.status == "fail" ? "FAIL" : $0.status, $0.name, $0.detail] }))
    }
    return ok ? .ok : .error
}

// MARK: Driving

let addVerb = Verb(
    name: "add",
    usage: """
    reeve card add [<title…>] [options]

    Starts a card: a worktree on a new branch when the folder is in git, and
    claude in it. With no title, Claude names it.
      --cwd DIR                  the folder to start in (default: here)
      --prompt TEXT              the first message to Claude
      --prompt-file PATH|-       … read from a file, or stdin
      --mode plan|build          plan mode first (default), or straight to work in auto mode
      --model MODEL              see `reeve models`
      --effort EFFORT            see `reeve models`
      --in-folder                work in the folder itself if git can't make a worktree
      --open                     open the card in the app
      --vibes                    VIBES MODE drives this card, whatever the board's switch says
      --json | --quiet           the card as JSON | just its id
    """,
    valued: ["cwd", "prompt", "prompt-file", "mode", "model", "effort"],
    flags: ["in-folder", "open", "vibes", "json", "quiet"]
) { args in
    let title = args.positionals.joined(separator: " ")
    var prompt = args.value("prompt")
    if let file = args.value("prompt-file") {
        guard prompt == nil else { throw UsageError("--prompt or --prompt-file, not both") }
        prompt = try readText(file)
    }
    let mode: StartMode
    switch args.value("mode") ?? "plan" {
    case "plan": mode = .plan
    case "build", "auto": mode = .build
    case let other: throw UsageError("unknown mode “\(other)”: plan or build")
    }
    if let effort = args.value("effort"), !Launch.efforts.contains(effort) {
        throw UsageError("unknown effort “\(effort)”: \(Launch.efforts.joined(separator: ", "))")
    }
    let here = FileManager.default.currentDirectoryPath
    let cwd = URL(fileURLWithPath: (args.value("cwd").map { ($0 as NSString).expandingTildeInPath }) ?? here,
                  relativeTo: URL(fileURLWithPath: here, isDirectory: true)).standardizedFileURL.path
    let body = CreateCardBody(cwd: cwd, title: title, prompt: prompt, mode: mode, model: args.value("model"),
                              effort: args.value("effort"), inFolder: args.has("in-folder"), open: args.has("open"),
                              vibes: args.has("vibes"))
    let client = try Client.connect()
    let card: APICard = try await client.call("POST", "/api/cards", body: body)
    if args.has("json") {
        try printJSON(card)
    } else if args.has("quiet") {
        out(card.card.id.uuidString.lowercased())
    } else {
        out("Created \(card.short) in \(card.card.stage.label): \(title.isEmpty ? "(Claude will name it)" : title)")
        out(Table.format([["id", card.card.id.uuidString.lowercased()], [card.card.worktreePath == nil ? "folder" : "worktree", card.card.cwd]], indent: "  "))
    }
    return .ok
}

let editVerb = Verb(
    name: "edit",
    usage: """
    reeve card edit <card> [--title TITLE | --no-title] [--vibes | --no-vibes] [--json]

    Renames the card, or puts it in VIBES MODE on its own or takes it out.
      --no-title   hand naming back to Claude
    """,
    valued: ["title"], flags: ["no-title", "vibes", "no-vibes", "json"]
) { args in
    guard args.positionals.count == 1 else { throw UsageError("which card?") }
    var body = EditCardBody()
    switch (args.value("title"), args.has("no-title")) {
    case let (given?, false): body.title = given
    case (nil, true): body.title = ""
    case (nil, false): break
    default: throw UsageError("--title or --no-title, not both")
    }
    switch (args.has("vibes"), args.has("no-vibes")) {
    case (true, true): throw UsageError("--vibes or --no-vibes, not both")
    case (true, false): body.vibes = true
    case (false, true): body.vibes = false
    case (false, false): break
    }
    guard body.title != nil || body.vibes != nil else { throw UsageError("nothing to change: --title, --no-title, --vibes or --no-vibes") }
    let client = try Client.connect()
    let api = try await client.card(args.positionals[0])
    let edited: APICard = try await client.call("PATCH", path(api.card.id), body: body)
    if args.has("json") {
        try printJSON(edited)
        return .ok
    }
    if let title = body.title {
        out(title.isEmpty ? "\(edited.short) will be named by Claude" : "Renamed \(edited.short): \(edited.card.title)")
    }
    if let vibes = body.vibes {
        out(vibes ? "VIBES MODE drives \(edited.short)" : "\(edited.short) is out of VIBES MODE")
    }
    return .ok
}

let moveVerb = Verb(
    name: "move",
    usage: """
    reeve card move <card> <stage> [--json]

    Puts the card in a column, as dragging it does: it stays there until your
    next prompt to its Claude.
    Stages: \(StageName.accepted).
    """,
    flags: ["json"]
) { args in
    guard args.positionals.count == 2 else { throw UsageError("a card and a stage") }
    guard let stage = StageName.parse(args.positionals[1]) else {
        throw UsageError("unknown stage “\(args.positionals[1])”: \(StageName.accepted)")
    }
    let client = try Client.connect()
    let api = try await client.card(args.positionals[0])
    let moved: APICard = try await client.call("POST", path(api.card.id) + "/move", body: MoveBody(stage: stage))
    if args.has("json") {
        try printJSON(moved)
    } else {
        out("Moved \(moved.short) to \(moved.card.stage.label)")
    }
    return .ok
}

let runVerb = Verb(
    name: "run",
    usage: """
    reeve card run <card> [--restart] [--json]

    Starts the card's session if it isn't running, resuming its conversation.
      --restart   stop a running session and start it again
    """,
    flags: ["restart", "json"]
) { args in
    guard args.positionals.count == 1 else { throw UsageError("which card?") }
    let client = try Client.connect()
    let api = try await client.card(args.positionals[0])
    let restart = args.has("restart")
    let after: APICard = try await client.call("POST", path(api.card.id) + "/run", body: RunBody(restart: restart))
    if args.has("json") {
        try printJSON(after)
    } else if api.live && !restart {
        out("\(api.short) is already running")
    } else {
        out((api.live ? "Restarting " : "Started ") + api.short)
    }
    return .ok
}

let replyVerb = Verb(
    name: "reply",
    usage: """
    reeve card reply <card> <text…> [--file PATH|-] [--force] [--json]

    Sends Claude a message: typed into the card's terminal when its session is
    running, else the message its session starts with. Refused while Claude
    Code shows a dialog (a permission prompt, a question, a plan to approve),
    since the text would answer it; answer those in the app.
      --file    read the message from a file, or stdin
      --force   type it into the dialog anyway
    """,
    valued: ["file"], flags: ["force", "json"]
) { args in
    guard let ref = args.positionals.first else { throw UsageError("which card?") }
    var text = args.positionals.dropFirst().joined(separator: " ")
    if let file = args.value("file") {
        guard text.isEmpty else { throw UsageError("the text or --file, not both") }
        text = try readText(file)
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw UsageError("nothing to send") }
    let client = try Client.connect()
    let api = try await client.card(ref)
    let reply: ReplyResponse = try await client.call("POST", path(api.card.id) + "/reply", body: ReplyBody(text: text, force: args.has("force")))
    if args.has("json") {
        try printJSON(reply)
    } else {
        switch reply.delivered {
        case .typed: out("Sent to \(api.short)")
        case .started: out("Started \(api.short) with your message")
        }
    }
    return .ok
}

let waitVerb = Verb(
    name: "wait",
    usage: """
    reeve card wait [<card>] [--timeout SECONDS] [--json]

    Waits while the card's Claude works, then exits with what it is doing:
    Background work Claude started (subagents, workflows) is waited for too.
      0  finished its turn; ready for review
      3  waiting on you: a question, a permission, a plan to approve
      4  its session failed
      5  nothing running
      6  --timeout ran out
    """,
    valued: ["timeout"], flags: ["json"]
) { args in
    var deadline: Date?
    if let timeout = args.value("timeout") {
        guard let seconds = Double(timeout), seconds >= 0 else { throw UsageError("--timeout takes seconds") }
        deadline = Date().addingTimeInterval(seconds)
    }
    let client = try Client.connect()
    var api = try await client.card(try onlyCard(args))
    let id = api.card.id
    while true {
        if let outcome = WaitOutcome.of(api) {
            if args.has("json") {
                try printJSON(api)
            } else {
                var line = "\(api.short)  \(api.card.activity.label)  \(api.displayTitle)"
                if outcome == .needsInput, let waiting = api.card.waitingOn { line += "\n  " + waiting }
                if outcome == .idle, !api.live { line = "\(api.short)  not running  \(api.displayTitle)" }
                out(line)
            }
            return outcome
        }
        if let deadline, Date() >= deadline {
            if args.has("json") { try printJSON(api) }
            note("Timed out; \(api.short) is still \(api.status)")
            return .timeout
        }
        try await Task.sleep(for: .seconds(1))
        do {
            api = try await client.get("/api/cards/\(id.uuidString)")
        } catch let error as CLIError where error.message.hasPrefix("no such card") {
            throw CLIError("\(CardRef.short(id)) was closed")
        }
    }
}

let closeVerb = Verb(
    name: "close",
    usage: """
    reeve card close <card> [--force] [--json]

    Ends the card's session and deletes its worktree, uncommitted changes and
    all. The branch goes too unless it has commits. This can't be undone, so
    a live session or uncommitted work is refused without --force.
    """,
    flags: ["force", "json"]
) { args in
    guard args.positionals.count == 1 else { throw UsageError("which card?") }
    let client = try Client.connect()
    let api = try await client.card(args.positionals[0])
    let force = args.has("force") ? "?force=1" : ""
    let closed: APICard = try await client.call("DELETE", path(api.card.id) + force, body: Optional<String>.none)
    if args.has("json") {
        try printJSON(closed)
    } else {
        out("Closed \(closed.short)" + (closed.card.worktreePath.map { "; removing \($0)" } ?? ""))
    }
    return .ok
}

let openVerb = Verb(
    name: "open",
    usage: """
    reeve open [<card>]

    Brings Reeve Terminal forward, launching it if need be, and opens the card
    when one is named (which starts its session).
    """
) { args in
    guard args.positionals.count <= 1 else { throw UsageError("one card at a time") }
    var client = try? Client.connect()
    if client == nil {
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // The app this `reeve` came in, else whichever one Launch Services knows.
        let helpers = URL(fileURLWithPath: realpath(Bundle.main.executablePath ?? CommandLine.arguments[0])).deletingLastPathComponent()
        let app = helpers.deletingLastPathComponent().deletingLastPathComponent()
        var launchArgs = helpers.path.hasSuffix(".app/Contents/Helpers") ? [app.path] : ["-b", "com.ryanbrunner.reeve-terminal"]
        if let dir = ProcessInfo.processInfo.environment["REEVE_DATA_DIR"] { launchArgs += ["--env", "REEVE_DATA_DIR=\(dir)"] }
        launch.arguments = launchArgs
        try launch.run()
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else { throw CLIError("couldn't launch Reeve Terminal") }
        for _ in 0..<60 where client == nil {
            try await Task.sleep(for: .milliseconds(250))
            client = try? Client.connect()
        }
        guard client != nil else {
            throw CLIError("Reeve Terminal didn't answer in time; if a build from before `reeve` is open, quit it and try again")
        }
    }
    guard let client else { return .error }
    if let ref = args.positionals.first {
        let api = try await client.card(ref)
        let _: APICard = try await client.call("POST", path(api.card.id) + "/open", body: [String: String]())
    } else {
        try await client.send("POST", "/api/open", body: [String: String]())
    }
    return .ok
}

let vibesVerb = Verb(
    name: "vibes",
    usage: """
    reeve vibes [on | off] [--json]

    The board's VIBES MODE switch. On, Claude plans, answers and ships every
    card with nobody watching: it approves plans unread, answers Claude's
    questions for you, and moves cards along. It waits two seconds before
    acting, in which `reeve vibes off` undoes it. With neither, says whether
    it is on and what it has done.
    """,
    flags: ["json"]
) { args in
    guard args.positionals.count <= 1 else { throw UsageError("on or off") }
    let client = try Client.connect()
    let state: VibesResponse
    switch args.positionals.first {
    case nil:
        state = try await client.get("/api/vibes")
    case "on"?:
        let before: VibesResponse = try await client.get("/api/vibes")
        if !before.on {
            let o = before.options
            note("VIBES MODE: plans approved unread\(o.skipPlanning ? " (Planning skipped)" : ""), questions answered for you, "
                 + "\(o.skipTesting ? "Testing skipped, " : "")\(o.autoMerge ? "pull requests merged" : "cards stop at Release"). "
                 + "`reeve vibes off` to stop.")
        }
        state = try await client.call("POST", "/api/vibes", body: VibesBody(on: true))
    case "off"?:
        state = try await client.call("POST", "/api/vibes", body: VibesBody(on: false))
    case let other?:
        throw UsageError("on or off, not “\(other)”")
    }
    if args.has("json") {
        try printJSON(state)
        return .ok
    }
    guard state.on, let ledger = state.ledger else {
        out("VIBES MODE is off")
        return .ok
    }
    var text = "VIBES MODE is on since \(when(ledger.since))" + (state.arming ? " (arming)" : "")
    text += "\n" + Table.format([
        ["moves", String(ledger.moves)], ["merged", String(ledger.merged)],
        ["plans and reviews skipped", String(ledger.reviewsSkipped)],
        ["questions answered", String(ledger.questionsSelfAnswered)],
        ["prompts from you", String(ledger.humanApprovals)],
    ], indent: "  ")
    if !ledger.log.isEmpty { text += "\n\n" + ledger.log.map { "  " + $0 }.joined(separator: "\n") }
    out(text)
    return .ok
}
