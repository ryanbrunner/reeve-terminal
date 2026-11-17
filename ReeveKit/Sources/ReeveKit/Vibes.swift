import Foundation

/// VIBES MODE: the human taken out of the loop.
///
/// Reeve's own gates come off — the plan nobody approves, the question nobody
/// answers, the turn that ends with nobody to say "go on" — and nothing else.
/// Claude Code's tool permissions stay, because they are a limit on what the
/// session may do, not a person in the loop; a permission prompt still waits
/// for you.
///
/// Two halves. Mid-turn, a question goes back to Claude through its hook —
/// Reeve's reply to the hook's POST is the hook's output — and the plan
/// dialog, which no hook can answer, is approved with the key a person would
/// press. Then, once a turn ends and the card has been sorted, Reeve types
/// the next step into the terminal.
public enum Vibes {
    /// How many times in a row a card is pushed from one column, and how many
    /// of its questions are answered there, before it is left for a person: a
    /// card going round in circles costs a turn each time. Counted apart, so
    /// a closing "want anything else?" read as a question doesn't use up the
    /// pushes.
    public static let maxNudges = 3

    /// What a question gets when Claude asked one and there is no one to ask.
    public static let noOneHome =
        "There is nobody to ask: VIBES MODE is on and you are answering your own questions. " +
        "Make the call yourself, take whichever option keeps the work moving, and say what you chose and why."

    /// What Claude Code is told when it asks a hook, for a card in VIBES MODE.
    /// Nil leaves the hook silent, and Claude Code carries on as it would.
    public static func reply(to event: HookEvent) -> VibesReply? {
        guard event.hookEventName == "PreToolUse", event.toolName == "AskUserQuestion" else { return nil }
        return VibesReply(question: event.toolInput?.questions?.compactMap(\.question).first)
    }

    /// Whether the event is Claude Code about to show its plan dialog.
    ///
    /// Interactive Claude Code puts the plan to a person whatever a hook
    /// answers — `allow` from PreToolUse or PermissionRequest alike — so
    /// VIBES MODE presses Enter on it instead. The first option is always a
    /// yes, and is selected when the dialog opens.
    public static func showsPlanDialog(_ event: HookEvent) -> Bool {
        event.hookEventName == "PermissionRequest" && event.toolName == "ExitPlanMode"
    }

    /// What VIBES MODE does once a card's turn has ended and it has been sorted.
    ///
    /// The column says how far the work got — Planning in plan mode, In
    /// Progress with nothing changed, Testing with changes, Release with a
    /// pull request — but not whether it was tested, so the card remembers
    /// what it was told. Once told to ship, whether it did is git's to say,
    /// not the column's: a branch merged with no remote never reaches Release.
    public static func next(stage: Stage, waitingOn: String?, nudges: VibesNudges?, options: VibesOptions) -> VibesStep {
        let here = nudges?.stage == stage
        if let waitingOn {
            return (here ? nudges?.answers ?? 0 : 0) >= maxNudges ? .giveUp : .answer(waitingOn)
        }
        if (here ? nudges?.count ?? 0 : 0) >= maxNudges { return .giveUp }
        if nudges?.askedToShip == true { return .checkShipped }
        switch stage {
        case .backlog, .inProgress:
            return .nudge(build, step: .build)
        case .planning:
            return .nudge(implement, step: .build)
        case .testing where !options.skipTesting && nudges?.askedToTest != true:
            return .nudge(test, step: .test)
        case .testing, .release:
            return .nudge(ship(options), step: .ship)
        }
    }

    static let build = "VIBES MODE is on and nobody is reviewing. Decide what this should be yourself and build it. Don't ask, keep the work moving."
    static let implement = "The plan is approved. Nobody read it. Implement it now, without stopping to ask."
    static let test = "Now test it: run the tests, check it really works, and fix whatever doesn't. Don't ask, keep going."

    /// The step that ships the work, as one line: a newline would send it
    /// half-written.
    public static func ship(_ options: VibesOptions) -> String {
        let merge = options.autoMerge
            ? "open a pull request and merge it into main, resolving any conflicts yourself. With no remote, merge it into main locally."
            : "and open a pull request. Leave it open for a person to merge."
        return "Ship it: commit everything on this branch, push it, \(merge) Nobody is reviewing."
    }

    /// The one chip a card wears in VIBES MODE: the guardrail its column is
    /// not applying. Or the one it is: a card waiting on another that hasn't
    /// merged is held, VIBES MODE or not.
    public static func chip(stage: Stage, activity: Activity, shipped: Bool, merged: Bool, waitingOn: String? = nil, options: VibesOptions) -> String {
        if activity == .error { return "error ignored" }
        if let waitingOn, !shipped { return "waits on \(waitingOn)" }
        switch stage {
        case .backlog: return "auto-run"
        case .planning: return "self-answered"
        case .inProgress: return options.skipTesting ? "no tests" : "no review"
        case .testing: return "auto-approved"
        case .release:
            if shipped { return merged ? "merged → main" : options.autoMerge ? "not merged" : "PR left open" }
            return options.autoMerge ? "straight to main" : "shipping"
        }
    }
}

/// What VIBES MODE told Claude Code in answer to a hook: an `AskUserQuestion`
/// refused, with an instruction to decide for itself.
public struct VibesReply: Equatable, Sendable {
    /// What Claude asked.
    public var question: String?

    public init(question: String?) {
        self.question = question
    }

    /// The hook's output, as Claude Code reads it from stdout.
    public var json: Data {
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": Vibes.noOneHome,
        ]]
        return try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}

/// What VIBES MODE does with a card whose turn just ended.
public enum VibesStep: Equatable, Sendable {
    /// Claude left a question in its message: tell it to answer it itself.
    case answer(String)
    /// Type the next step into the terminal.
    case nudge(String, step: Kind)
    /// It was told to ship: see whether it landed, and push again if not.
    case checkShipped
    /// Pushed from the same column too many times. Left for a person.
    case giveUp

    public enum Kind: Equatable, Sendable {
        case build, test, ship
    }
}

/// How many times VIBES MODE has pushed a card from its current column and
/// answered it there, and whether it has been told to test and to ship.
public struct VibesNudges: Codable, Equatable, Sendable {
    public var stage: Stage
    public var count: Int
    public var answers: Int
    public var askedToTest: Bool
    public var askedToShip: Bool

    public init(stage: Stage, count: Int = 0, answers: Int = 0, askedToTest: Bool = false, askedToShip: Bool = false) {
        self.stage = stage
        self.count = count
        self.answers = answers
        self.askedToTest = askedToTest
        self.askedToShip = askedToShip
    }

    /// One more push from `stage`; a new column starts the counts again.
    public func adding(from stage: Stage, step: VibesStep.Kind) -> VibesNudges {
        var next = restarted(at: stage)
        next.count += 1
        next.askedToTest = askedToTest || step == .test
        next.askedToShip = askedToShip || step == .ship
        return next
    }

    /// One more question answered in `stage`.
    public func answering(in stage: Stage) -> VibesNudges {
        var next = restarted(at: stage)
        next.answers += 1
        return next
    }

    private func restarted(at stage: Stage) -> VibesNudges {
        self.stage == stage ? self : VibesNudges(stage: stage, askedToTest: askedToTest, askedToShip: askedToShip)
    }
}

/// What VIBES MODE skips and whether it merges. The web board's defaults:
/// Planning skipped, Testing run, every pull request merged.
public struct VibesOptions: Codable, Equatable, Sendable {
    public var skipPlanning: Bool
    public var skipTesting: Bool
    public var autoMerge: Bool

    public init(skipPlanning: Bool = true, skipTesting: Bool = false, autoMerge: Bool = true) {
        self.skipPlanning = skipPlanning
        self.skipTesting = skipTesting
        self.autoMerge = autoMerge
    }

    /// Whether VIBES MODE flies straight over this column.
    public func skips(_ stage: Stage) -> Bool {
        (stage == .planning && skipPlanning) || (stage == .testing && skipTesting)
    }
}

/// The board-wide switch and what has happened since it was flipped. Saved
/// with the board, so a relaunch lands on the same totals.
public struct VibesLedger: Codable, Equatable, Sendable {
    public var since: Date
    public var merged = 0
    /// Prompts a person typed into a card VIBES MODE was driving.
    public var humanApprovals = 0
    /// Plans approved unread, and turns waved on to the next column.
    public var reviewsSkipped = 0
    public var questionsSelfAnswered = 0
    /// Cards that changed column by themselves.
    public var moves = 0
    /// Newest first.
    public var log: [String] = []

    public init(since: Date = Date()) {
        self.since = since
    }

    public mutating func note(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 4 { log.removeLast(log.count - 4) }
    }
}
