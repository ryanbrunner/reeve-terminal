import Foundation

/// The board's six columns, left to right. A card's column is where its work
/// is; the card works that out itself from the session's state (see
/// `Card.stage(running:hasChanges:)`), and a person can drag it somewhere else.
public enum Stage: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case backlog
    case design
    case planning
    case inProgress = "in_progress"
    case testing
    case release

    public var id: String { rawValue }

    /// Left to right on the board.
    public static func < (a: Stage, b: Stage) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .backlog: "Backlog"
        case .design: "Design"
        case .planning: "Planning"
        case .inProgress: "In Progress"
        case .testing: "Testing"
        case .release: "Release"
        }
    }
}

/// What the session is doing right now, as light on the card. Unlike the
/// stage, this comes straight from Claude Code's hooks, so it changes the
/// moment the session does.
public enum Activity: String, Codable, Sendable {
    /// Nothing has happened, or the session has exited.
    case idle
    /// Claude is working on a turn, or its background subagents are.
    case running
    /// Claude finished its turn and has something to look at.
    case needsReview = "needs_review"
    /// Claude is blocked on a person: a permission prompt, a question, a plan to approve.
    case needsInput = "needs_input"
    /// Claude's turn is over, but a background shell it launched will wake it.
    case waiting
    /// The session's process died.
    case error
}

/// How a new card's session begins: designing first, planning first, or
/// straight to work.
public enum StartMode: String, Codable, CaseIterable, Sendable {
    /// Claude starts with `/design`, in auto mode, and the card in Design.
    case design
    /// Claude starts in plan mode, and the card in Planning.
    case plan
    /// Claude starts in auto mode, and the card in In Progress.
    case build

    /// The `--permission-mode` the session starts in.
    public var permissionMode: String {
        switch self {
        case .plan: "plan"
        case .design, .build: "auto"
        }
    }

    public var stage: Stage {
        switch self {
        case .design: .design
        case .plan: .planning
        case .build: .inProgress
        }
    }

    /// The first prompt a new session in this mode is given for `brief`:
    /// a design session hands it to Claude Code's `/design`.
    public func firstPrompt(_ brief: String) -> String {
        self == .design ? "/design \(brief)" : brief
    }
}

/// One piece of work: a Claude Code session running in a terminal, in a folder.
public struct Card: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The Claude Code session the card's terminal runs. Fixed when the card is
    /// made, so the card can pick the conversation up again after a restart.
    public var sessionId: UUID
    /// Empty until a person names it or the classifier does.
    public var title: String
    /// A person named the card, so the classifier leaves the title alone.
    public var titledByPerson: Bool
    /// Where the terminal runs: the card's worktree when it has one.
    public var cwd: String
    /// The repository the card's worktree was made from.
    public var repoPath: String?
    /// The worktree Reeve made for the card, removed with the card. Nil for a
    /// folder outside git, and for cards made before Reeve made worktrees.
    public var worktreePath: String?
    /// The branch checked out in the card's worktree.
    public var branch: String?
    /// The branch the card's worktree was on when its pull requests were last
    /// looked up, which Claude may have switched to from `branch`. Kept apart
    /// from `branch` because closing the card deletes that one.
    public var headBranch: String?
    /// Every pull request opened from a branch the card's worktree has been
    /// on, newest first. Nil until there is one.
    public var pullRequests: [PullRequest]?
    /// The commit the card's worktree started from, which its changes are
    /// shown against. Nil for cards made before Reeve kept it.
    public var baseCommit: String?
    /// The session's latest plan, as `ExitPlanMode` carried it.
    public var plan: String?
    /// The file Claude Code keeps the plan in, read in place of `plan` while
    /// it is there, since it may have been edited since.
    public var planPath: String?
    /// The plan was approved, by anyone. Nil until then, and again once
    /// Claude writes or asks about a new one.
    public var planApproved: Bool?
    /// The comments a person left on the card's changes, and Claude's replies.
    /// Nil for cards saved before there were any.
    public var review: [ReviewThread]?
    /// The comments a person left on the card's plan, and Claude's replies.
    public var planReview: [ReviewThread]?
    /// The Claude Design projects and artifacts the session has shared,
    /// newest first. Nil until there is one.
    public var designs: [DesignArtifact]?
    /// The model the card's `claude` runs, as `--model` takes it. Nil leaves
    /// it to the person's own settings.
    public var model: String?
    /// The effort level the card's `claude` runs at, as `--effort` takes it.
    /// Nil leaves it to the person's own settings.
    public var effort: String?
    public var stage: Stage
    /// The swimlane the card is in. Nil, or a lane that has gone, is the first.
    public var laneId: UUID?
    /// Made in Backlog and not started: no worktree, no session, nothing runs
    /// until a person moves it to Design, Planning or In Progress. Nil once it starts.
    public var queued: Bool?
    /// What a backlog card says to Claude when it starts, when that is more
    /// than its title. Nil once it has started, or when the title says it.
    public var brief: String?
    /// The card this one waits on. In Backlog it can't start until that one
    /// has merged (see `Dependency`). Nil waits on nothing.
    public var dependsOnId: UUID?
    public var activity: Activity
    /// How the session starts. Nil for cards made before there was a choice,
    /// which start in the person's own default mode.
    public var startMode: StartMode?
    /// One line on where the work stands, from the classifier.
    public var summary: String?
    /// What Claude is waiting on a person for, when it is.
    public var waitingOn: String?
    /// The background shells Claude is waiting on, while it is.
    public var background: [BackgroundWork]?
    /// A person put the card in its column. The classifier leaves the stage
    /// alone until the next prompt, so a drag is never undone behind your back.
    public var stagePinned: Bool
    /// The permission mode the session was last seen in (`plan`, `auto`,
    /// `default`…), from its hooks. Nil until a hook has said.
    public var permissionMode: String?
    /// When Claude last changed a file with one of its editing tools.
    public var lastEditAt: Date?
    /// The session has at least one prompt in it, so it can be resumed.
    public var hasConversation: Bool
    /// Where Claude Code keeps the session's transcript, once a hook has said.
    public var transcriptPath: String?
    /// In VIBES MODE on its own, whatever the board's switch says. Nil is off.
    public var vibes: Bool?
    /// How hard VIBES MODE has pushed the card, so it stops before going round
    /// in circles.
    public var vibesNudges: VibesNudges?
    /// When VIBES MODE saw the card through to the end. Nothing pushes it after.
    public var shippedAt: Date?
    /// Its branch was found on main once it shipped, not just said to be.
    public var merged: Bool?
    /// VIBES MODE has asked what should follow this card, once its repo ran
    /// dry. Asked once, whatever came of it.
    public var ideasAsked: Bool?
    /// The card VIBES MODE thought of this one after, when it did.
    public var ideaFrom: UUID?
    /// The schedule that made the card, whose run it is.
    public var scheduleId: UUID?
    /// When the card was cleaned up into the archive. Nil for a card on the board.
    public var archivedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: UUID = UUID(),
        title: String = "",
        cwd: String,
        stage: Stage = .backlog,
        activity: Activity = .idle,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.titledByPerson = !title.isEmpty
        self.cwd = cwd
        self.stage = stage
        self.activity = activity
        self.stagePinned = false
        self.hasConversation = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// The repo's or folder's own name, which the card wears as its repo chip.
    public var folderName: String {
        URL(fileURLWithPath: repoPath ?? cwd).lastPathComponent
    }
}

extension Card {
    /// The pull request from the branch the card is on now, which it wears
    /// as a badge. Ones from branches it has left are only in its PRs tab.
    public var pullRequest: PullRequest? {
        PullRequest.primary(of: pullRequests ?? [], on: headBranch ?? branch)
    }

    /// The card's branch has a pull request that is open (draft or not) or
    /// merged: the work has gone out for release.
    public var hasLivePullRequest: Bool {
        pullRequest.map { $0.state != .closed } ?? false
    }

    /// The card's pull request has merged and no other one it opened is still
    /// open or draft: nothing is left to release, so cleanup may archive it.
    public var isFullyMerged: Bool {
        guard pullRequest?.state == .merged else { return false }
        return !(pullRequests ?? []).contains { $0.state == .open || $0.state == .draft }
    }

    /// Whether the board offers to merge the card's pull request: a Release
    /// card's open one, not a draft, which GitHub last said merges cleanly.
    /// The Merge button is drawn from this and `reeve card merge` refuses by
    /// it. Mergeable is GitHub's verdict on conflicts alone, so a branch
    /// protection rule still leaves the button there, and gh says no.
    public var canMergePullRequest: Bool {
        guard stage == .release, let pr = pullRequest else { return false }
        return pr.state == .open && pr.mergeable == .mergeable
    }

    /// What a waiting card is waiting on, in a line: "Waiting on 2 shells".
    public var backgroundLine: String? {
        guard activity == .waiting else { return nil }
        guard let tasks = background, !tasks.isEmpty else { return "Waiting on background work" }
        let noun = tasks.allSatisfy { $0.type == "shell" } ? "shell" : "task"
        return "Waiting on \(tasks.count) \(noun)\(tasks.count == 1 ? "" : "s")"
    }

    /// The column the session's state puts the card in. First match wins:
    ///
    /// - a pull request is open, draft or merged: release
    /// - Claude is in plan mode: planning
    /// - the card is in Design: it stays there (see below)
    /// - Claude is working in any other mode: in progress
    /// - Claude's turn is over and the code has changed: testing (ready to try)
    ///
    /// Otherwise the card stays put, apart from leaving backlog or planning
    /// once the session is out of plan mode. A card a person put somewhere
    /// stays there. Design is left only by a person's say: a drag, Claude
    /// put into plan mode, or Claude starting to change the code (see
    /// `DesignSighting.movesToBuild`), never just by Claude working.
    ///
    /// It only ever moves forward: a card in Testing stays there while Claude
    /// works on it again, and only a person moves it back. From the column
    /// they put it in, it moves forward again once they next speak to Claude.
    public func stage(running: Bool, hasChanges: Bool) -> Stage {
        if stagePinned { return stage }
        return max(stage, sessionStage(running: running, hasChanges: hasChanges))
    }

    private func sessionStage(running: Bool, hasChanges: Bool) -> Stage {
        if hasLivePullRequest { return .release }
        guard let permissionMode else { return stage }
        if permissionMode == "plan" { return .planning }
        if stage == .design { return .design }
        if running { return .inProgress }
        if hasChanges { return .testing }
        return stage == .backlog || stage == .planning ? .inProgress : stage
    }
}
