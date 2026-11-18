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
    /// The session's permission mode: `plan`, `auto`, `default`…
    public let permissionMode: String?
    /// `PreToolUse` and `PostToolUse`.
    public let toolName: String?
    public let toolInput: ToolInput?
    /// `Notification`.
    public let message: String?
    public let notificationType: String?
    /// `Stop`.
    public let lastAssistantMessage: String?
    /// `Stop`: the background work still in flight, which will wake Claude
    /// when it finishes. Empty, or missing from older Claude Codes, when
    /// there is none.
    public let backgroundTasks: [BackgroundWork]?
    /// `UserPromptSubmit`.
    public let prompt: String?
    /// Tool events: set when a subagent made the call, not the main thread.
    public let agentId: String?
    /// The whole payload, as it came. A tool's response is read from here
    /// for the design links in it, whatever its shape.
    public internal(set) var raw: String = ""

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case notificationType = "notification_type"
        case lastAssistantMessage = "last_assistant_message"
        case backgroundTasks = "background_tasks"
        case prompt
        case agentId = "agent_id"
    }

    /// The background work a card shows as waiting on after the turn ends:
    /// shells, like a build or a test run Claude will pick up when it exits.
    /// Background agents, workflows and monitors don't count.
    public static let wakingTaskTypes: Set<String> = ["shell"]

    public var wakingTasks: [BackgroundWork] {
        (backgroundTasks ?? []).filter { Self.wakingTaskTypes.contains($0.type) }
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
        var event = try JSONDecoder().decode(HookEvent.self, from: data)
        event.raw = String(decoding: data, as: UTF8.self)
        return event
    }

    /// The Claude Design projects and artifacts this event shows the main
    /// thread sharing: in the response of a tool that makes them, or in what
    /// Claude said at the end of its turn. Other tools' responses don't
    /// count: reading a file with a link in it makes no design. Nil when
    /// there are none.
    public var designs: [DesignArtifact]? {
        let text: String
        switch hookEventName {
        case "PostToolUse" where agentId == nil && designTools.contains(toolName ?? ""): text = raw.replacingOccurrences(of: "\\/", with: "/")
        case "Stop": text = lastAssistantMessage ?? ""
        default: return nil
        }
        let links = DesignSighting.links(in: text)
        return links.isEmpty ? nil : links.map { DesignArtifact(url: $0) }
    }
}

/// A piece of background work Claude launched, as the `Stop` hook lists it.
public struct BackgroundWork: Codable, Equatable, Sendable {
    public var id: String
    /// `subagent`, `workflow`, `shell`, `monitor`…
    public var type: String
    public var description: String?
    /// Subagents: which kind, like `Explore`.
    public var agentType: String?

    enum CodingKeys: String, CodingKey {
        case id, type, description
        case agentType = "agent_type"
    }

    public init(id: String, type: String, description: String? = nil, agentType: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.agentType = agentType
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
    /// Claude is mid-turn, so the card is wherever its mode says work happens.
    public var working = false
    /// Claude changed a file.
    public var editsFiles = false
    /// Claude's turn is over: time to work out where the card is.
    public var classify = false
    /// Claude wrote a plan, or asked for one to be approved.
    public var plan: PlanSighting?
    /// Claude shared Claude Design projects or artifacts.
    public var designs: [DesignArtifact]?
    /// Set to replace the background work the card is waiting on.
    public var background: [BackgroundWork]?
    /// A subagent used a tool: it is getting on with its work.
    public var bySubagent = false

    public init(activity: Activity? = nil, waitingOn: String?? = nil, startsConversation: Bool = false, unpinsStage: Bool = false, working: Bool = false, editsFiles: Bool = false, classify: Bool = false, plan: PlanSighting? = nil, background: [BackgroundWork]? = nil) {
        self.activity = activity
        self.waitingOn = waitingOn
        self.startsConversation = startsConversation
        self.unpinsStage = unpinsStage
        self.working = working
        self.editsFiles = editsFiles
        self.classify = classify
        self.plan = plan
        self.background = background
    }
}

/// Tools that stop the turn to ask a person something.
private let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

/// Tools that make designs: `/design`'s Claude Design projects, and artifacts.
private let designTools: Set<String> = ["DesignSync", "Artifact"]

/// Tools that change files.
private let editingTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

/// Notifications that mean Claude, or one of its agents, is blocked on a
/// person. The rest (an agent finishing, the idle reminder, sign-ins) aren't.
private let blockingNotifications: Set<String> = ["permission_prompt", "worker_permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

extension HookEvent {
    /// The activity a card goes back to when a subagent carries on working
    /// after a notification stopped for a person: they must have answered
    /// it. Nil leaves the card as it is, as it does for a question Claude
    /// itself asked, which a subagent's work says nothing about.
    public static func activityAfterSubagentWork(_ activity: Activity, askedByNotification: Bool, waitingOnBackground: Bool) -> Activity? {
        guard activity == .needsInput, askedByNotification else { return nil }
        return waitingOnBackground ? .waiting : .running
    }

    /// Claude Code ran `ExitPlanMode`: someone said yes to the plan.
    public var approvesPlan: Bool {
        hookEventName == "PostToolUse" && toolName == "ExitPlanMode" && agentId == nil
    }

    /// Claude drafted a plan in plan mode, or put one up for approval: one
    /// nobody has approved yet. A plan file edited out of plan mode is the
    /// approved plan, kept up to date.
    public var putsUpNewPlan: Bool {
        guard (permissionMode ?? "plan") == "plan", agentId == nil else { return false }
        if hookEventName == "PreToolUse", toolName == "ExitPlanMode" { return true }
        return hookEventName == "PostToolUse" && (toolName == "Write" || toolName == "Edit")
            && toolInput?.filePath.map(PlanSighting.isPlanFile) == true
    }

    /// The plan dialog, if it was open, has closed: once it opens, anything
    /// the main thread does means it was answered, one way or the other.
    public var closesPlanDialog: Bool {
        switch hookEventName {
        case "UserPromptSubmit", "Stop", "SessionEnd": true
        case "PreToolUse", "PostToolUse": agentId == nil
        default: false
        }
    }

    /// The card's new activity, and what else changes, for this event.
    public var effect: HookEffect {
        var effect = sessionEffect
        effect.designs = designs
        return effect
    }

    private var sessionEffect: HookEffect {
        switch hookEventName {
        case "UserPromptSubmit":
            return HookEffect(activity: .running, waitingOn: .some(nil), startsConversation: true, unpinsStage: true, working: true, background: [])
        case "PreToolUse":
            if let toolName, askingTools.contains(toolName) {
                let question = toolInput?.questions?.compactMap(\.question).first
                var effect = HookEffect(activity: .needsInput, waitingOn: .some(question ?? (toolName == "ExitPlanMode" ? "Approve the plan?" : nil)), working: true)
                if toolName == "ExitPlanMode" {
                    effect.plan = PlanSighting(text: toolInput?.plan, path: toolInput?.planFilePath)
                }
                return effect
            }
            // A subagent at work says nothing about the main thread, which
            // may be running or waiting on it.
            if agentId != nil {
                var effect = HookEffect(working: true)
                effect.bySubagent = true
                return effect
            }
            return HookEffect(activity: .running, waitingOn: .some(nil), working: true, background: [])
        case "PostToolUse":
            var effect = HookEffect(working: true, editsFiles: toolName.map(editingTools.contains) ?? false)
            if agentId == nil {
                effect.activity = .running
                effect.waitingOn = .some(nil)
                effect.background = []
            } else {
                effect.bySubagent = true
            }
            // Plan mode drafts the plan in a file before asking for approval.
            if toolName == "Write" || toolName == "Edit", let path = toolInput?.filePath, PlanSighting.isPlanFile(path) {
                effect.plan = PlanSighting(text: nil, path: path)
            }
            return effect
        case "Notification":
            // Older Claude Codes send no type; their idle reminder is told by its words.
            let blocking = notificationType.map(blockingNotifications.contains) ?? (message?.contains("waiting for your input") != true)
            return blocking ? HookEffect(activity: .needsInput, waitingOn: .some(message)) : HookEffect()
        case "Stop":
            // A background shell will wake Claude when it exits: the turn is
            // over, but the work isn't.
            let waking = wakingTasks
            if !waking.isEmpty {
                return HookEffect(activity: .waiting, waitingOn: .some(nil), classify: true, background: waking)
            }
            return HookEffect(activity: .needsReview, classify: true, background: [])
        case "SessionEnd":
            return HookEffect(activity: .idle, background: [])
        default:
            return HookEffect()
        }
    }
}
