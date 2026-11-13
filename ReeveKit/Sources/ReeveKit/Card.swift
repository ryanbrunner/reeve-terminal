import Foundation

/// The board's five columns, left to right. A card's column is where its work
/// is; the card works that out itself from the session's state (see
/// `Card.stage(running:hasChanges:)`), and a person can drag it somewhere else.
public enum Stage: String, Codable, CaseIterable, Identifiable, Sendable {
    case backlog
    case planning
    case inProgress = "in_progress"
    case testing
    case release

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .backlog: "Backlog"
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
    /// Claude is working on a turn.
    case running
    /// Claude finished its turn and has something to look at.
    case needsReview = "needs_review"
    /// Claude is blocked on a person: a permission prompt, a question, a plan to approve.
    case needsInput = "needs_input"
    /// The session's process died.
    case error
}

/// How a new card's session begins: planning first, or straight to work.
public enum StartMode: String, Codable, CaseIterable, Sendable {
    /// Claude starts in plan mode, and the card in Planning.
    case plan
    /// Claude starts in auto mode, and the card in In Progress.
    case build

    /// The `--permission-mode` the session starts in.
    public var permissionMode: String {
        switch self {
        case .plan: "plan"
        case .build: "auto"
        }
    }

    public var stage: Stage {
        switch self {
        case .plan: .planning
        case .build: .inProgress
        }
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
    /// The commit the card's worktree started from, so commits made since
    /// count as changed code.
    public var baseCommit: String?
    /// The model the card's `claude` runs, as `--model` takes it. Nil leaves
    /// it to the person's own settings.
    public var model: String?
    /// The effort level the card's `claude` runs at, as `--effort` takes it.
    /// Nil leaves it to the person's own settings.
    public var effort: String?
    public var stage: Stage
    public var activity: Activity
    /// How the session starts. Nil for cards made before there was a choice,
    /// which start in the person's own default mode.
    public var startMode: StartMode?
    /// One line on where the work stands, from the classifier.
    public var summary: String?
    /// What Claude is waiting on a person for, when it is.
    public var waitingOn: String?
    /// A person put the card in its column. The classifier leaves the stage
    /// alone until the next prompt, so a drag is never undone behind your back.
    public var stagePinned: Bool
    /// The permission mode the session was last seen in (`plan`, `auto`,
    /// `default`…), from its hooks. Nil until a hook has said.
    public var permissionMode: String?
    /// When Claude last changed a file with one of its editing tools.
    public var lastEditAt: Date?
    /// The pull request for the card's branch, as `gh` last saw it.
    public var pullRequest: PullRequestState?
    /// The session has at least one prompt in it, so it can be resumed.
    public var hasConversation: Bool
    /// Where Claude Code keeps the session's transcript, once a hook has said.
    public var transcriptPath: String?
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

/// Where a pull request stands, as `gh pr view` reports it.
public enum PullRequestState: String, Codable, Sendable {
    case open = "OPEN"
    case merged = "MERGED"
    case closed = "CLOSED"
}

extension Card {
    /// The column the session's state puts the card in. First match wins:
    ///
    /// - a pull request is open or merged: release
    /// - Claude is in plan mode: planning
    /// - Claude is working in any other mode: in progress
    /// - Claude's turn is over and the code has changed: testing (ready to try)
    ///
    /// Otherwise the card stays put, apart from leaving backlog or planning
    /// once the session is out of plan mode. A card a person put somewhere
    /// stays there.
    public func stage(running: Bool, hasChanges: Bool) -> Stage {
        if stagePinned { return stage }
        if pullRequest == .open || pullRequest == .merged { return .release }
        guard let permissionMode else { return stage }
        if permissionMode == "plan" { return .planning }
        if running { return .inProgress }
        if hasChanges { return .testing }
        return stage == .backlog || stage == .planning ? .inProgress : stage
    }
}
