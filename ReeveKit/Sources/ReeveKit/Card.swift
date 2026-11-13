import Foundation

/// The board's five columns, left to right. A card's column is where its work
/// is; the card works that out itself from the session, and a person can drag
/// it somewhere else.
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
