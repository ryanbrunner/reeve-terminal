import Foundation

/// A Claude Code hook payload, as the session's hooks post it to Reeve.
///
/// Only the fields Reeve reads. Every payload carries the session and the
/// event; the rest depend on which event it is.
public struct HookEvent: Decodable, Sendable {
    public let sessionId: String
    public let hookEventName: String
    public let transcriptPath: String?
    public let cwd: String?
    /// `PreToolUse`.
    public let toolName: String?
    public let toolInput: ToolInput?
    /// `Notification`.
    public let message: String?
    public let notificationType: String?
    /// `Stop`.
    public let lastAssistantMessage: String?
    /// `UserPromptSubmit`.
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case notificationType = "notification_type"
        case lastAssistantMessage = "last_assistant_message"
        case prompt
    }

    /// The parts of a tool's input that say what Claude is asking a person,
    /// or where it is writing its plan.
    public struct ToolInput: Decodable, Sendable {
        public let questions: [Question]?
        /// `ExitPlanMode`: the plan, and the file Claude Code keeps it in.
        public let plan: String?
        public let planFilePath: String?
        /// `Write` and `Edit`.
        public let filePath: String?

        enum CodingKeys: String, CodingKey {
            case questions, plan, planFilePath
            case filePath = "file_path"
        }

        public struct Question: Decodable, Sendable {
            public let question: String?
        }
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: data)
    }
}

/// What a hook event does to its card.
public struct HookEffect: Equatable, Sendable {
    public var activity: Activity?
    /// Set to replace the card's waiting line; `.some(nil)` clears it.
    public var waitingOn: String??
    /// The session has a prompt in it now.
    public var startsConversation = false
    /// A person spoke, so a pinned stage is theirs to have again.
    public var unpinsStage = false
    /// Claude's turn is over: time to work out where the card is.
    public var classify = false
    /// Claude wrote a plan, or asked for one to be approved.
    public var plan: PlanSighting?

    public init(activity: Activity? = nil, waitingOn: String?? = nil, startsConversation: Bool = false, unpinsStage: Bool = false, classify: Bool = false, plan: PlanSighting? = nil) {
        self.activity = activity
        self.waitingOn = waitingOn
        self.startsConversation = startsConversation
        self.unpinsStage = unpinsStage
        self.classify = classify
        self.plan = plan
    }
}

/// Tools that stop the turn to ask a person something.
private let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

extension HookEvent {
    /// The card's new activity, and what else changes, for this event.
    public var effect: HookEffect {
        switch hookEventName {
        case "UserPromptSubmit":
            return HookEffect(activity: .running, waitingOn: .some(nil), startsConversation: true, unpinsStage: true)
        case "PreToolUse":
            if let toolName, askingTools.contains(toolName) {
                let question = toolInput?.questions?.compactMap(\.question).first
                var effect = HookEffect(activity: .needsInput, waitingOn: .some(question ?? (toolName == "ExitPlanMode" ? "Approve the plan?" : nil)))
                if toolName == "ExitPlanMode" {
                    effect.plan = PlanSighting(text: toolInput?.plan, path: toolInput?.planFilePath)
                }
                return effect
            }
            return HookEffect(activity: .running, waitingOn: .some(nil))
        case "PostToolUse":
            var effect = HookEffect(activity: .running, waitingOn: .some(nil))
            // Plan mode drafts the plan in a file before asking for approval.
            if toolName == "Write" || toolName == "Edit", let path = toolInput?.filePath, PlanSighting.isPlanFile(path) {
                effect.plan = PlanSighting(text: nil, path: path)
            }
            return effect
        case "Notification":
            // The idle reminder comes a minute after a turn ends; the card has
            // already said so. Anything else is Claude blocked on a person.
            if notificationType == "idle_prompt" || (notificationType == nil && message?.contains("waiting for your input") == true) {
                return HookEffect()
            }
            return HookEffect(activity: .needsInput, waitingOn: .some(message))
        case "Stop":
            return HookEffect(activity: .needsReview, classify: true)
        case "SessionEnd":
            return HookEffect(activity: .idle)
        default:
            return HookEffect()
        }
    }
}
