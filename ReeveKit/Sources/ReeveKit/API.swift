import Foundation

/// What the app's `/api` answers and accepts, shared by the app and `reeve`.
public enum API {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// A card as the API shows it: everything saved, plus what only the running
/// app knows. Flat, so `jq .stage` and `jq .live` read alike.
public struct APICard: Codable, Equatable, Sendable {
    public var card: Card
    /// Its terminal has a live `claude` in it.
    public var live: Bool
    /// Its session has been asked to start and is waiting on the app.
    public var starting: Bool
    /// Claude Code is showing a dialog (a permission prompt, a question, a
    /// plan to approve), so typing into the terminal would answer it.
    public var dialogOpen: Bool
    /// The name the board shows: the title, else the terminal's, else "New session".
    public var displayTitle: String
    /// The card it waits on (`dependsOnId`), and how far that one has got.
    public var dependsOn: DependencyLink?

    public init(card: Card, live: Bool, starting: Bool, dialogOpen: Bool, displayTitle: String, dependsOn: DependencyLink? = nil) {
        self.card = card
        self.live = live
        self.starting = starting
        self.dialogOpen = dialogOpen
        self.displayTitle = displayTitle
        self.dependsOn = dependsOn
    }

    private enum Extra: String, CodingKey {
        case live, starting, dialogOpen, displayTitle, dependsOn, pullRequest
    }

    public init(from decoder: Decoder) throws {
        card = try Card(from: decoder)
        let extra = try decoder.container(keyedBy: Extra.self)
        live = try extra.decode(Bool.self, forKey: .live)
        starting = try extra.decode(Bool.self, forKey: .starting)
        dialogOpen = try extra.decode(Bool.self, forKey: .dialogOpen)
        displayTitle = try extra.decode(String.self, forKey: .displayTitle)
        dependsOn = try extra.decodeIfPresent(DependencyLink.self, forKey: .dependsOn)
    }

    public func encode(to encoder: Encoder) throws {
        try card.encode(to: encoder)
        var extra = encoder.container(keyedBy: Extra.self)
        try extra.encode(live, forKey: .live)
        try extra.encode(starting, forKey: .starting)
        try extra.encode(dialogOpen, forKey: .dialogOpen)
        try extra.encode(displayTitle, forKey: .displayTitle)
        try extra.encodeIfPresent(dependsOn, forKey: .dependsOn)
        // The one on the badge, worked out from `pullRequests` and not stored,
        // written out for scripts reading the JSON. Worked out again on decode.
        try extra.encodeIfPresent(card.pullRequest, forKey: .pullRequest)
    }
}

/// `GET /api/board`: every card in board order, lane by lane, column by column.
public struct BoardResponse: Codable, Equatable, Sendable {
    public var cards: [APICard]
    /// The swimlanes, top to bottom. Nil from an app older than lanes.
    public var lanes: [Lane]?
    /// The open card, in place of the board, if any.
    public var selectedId: UUID?
    /// What VIBES MODE has done since it went on; nil while it is off.
    public var vibes: VibesLedger?

    public init(cards: [APICard], lanes: [Lane]? = nil, selectedId: UUID?, vibes: VibesLedger? = nil) {
        self.cards = cards
        self.lanes = lanes
        self.selectedId = selectedId
        self.vibes = vibes
    }
}

/// `GET`/`POST /api/vibes`: the board's VIBES MODE switch.
public struct VibesResponse: Codable, Equatable, Sendable {
    public var on: Bool
    /// Just switched on: the two seconds before it acts, in which it can be undone.
    public var arming: Bool
    public var ledger: VibesLedger?
    public var options: VibesOptions

    public init(on: Bool, arming: Bool, ledger: VibesLedger?, options: VibesOptions) {
        self.on = on
        self.arming = arming
        self.ledger = ledger
        self.options = options
    }
}

public struct VibesBody: Codable, Equatable, Sendable {
    public var on: Bool

    public init(on: Bool) {
        self.on = on
    }
}

/// `POST /api/cards`.
public struct CreateCardBody: Codable, Equatable, Sendable {
    /// The folder to start in; a git repo gets the card its own worktree.
    public var cwd: String
    public var title: String
    public var prompt: String?
    public var mode: StartMode
    public var model: String?
    public var effort: String?
    /// Work in `cwd` itself when a worktree can't be made, rather than fail.
    public var inFolder: Bool
    /// Open the card's page, as the new card sheet does.
    public var open: Bool
    /// In VIBES MODE on its own, whatever the board's switch says.
    public var vibes: Bool
    /// Put it in Backlog and start nothing: `mode` is ignored, and the card
    /// starts when it is moved to Design, Planning or In Progress.
    public var backlog: Bool
    /// The swimlane, by id or name. Nil is the first.
    public var lane: String?

    public init(cwd: String, title: String = "", prompt: String? = nil, mode: StartMode = .plan,
                model: String? = nil, effort: String? = nil, inFolder: Bool = false, open: Bool = false, vibes: Bool = false,
                backlog: Bool = false, lane: String? = nil) {
        self.cwd = cwd
        self.title = title
        self.prompt = prompt
        self.mode = mode
        self.model = model
        self.effort = effort
        self.inFolder = inFolder
        self.open = open
        self.vibes = vibes
        self.backlog = backlog
        self.lane = lane
    }

    /// Only `cwd` is needed; the rest default as the initializer's do.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        mode = try c.decodeIfPresent(StartMode.self, forKey: .mode) ?? .plan
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        inFolder = try c.decodeIfPresent(Bool.self, forKey: .inFolder) ?? false
        open = try c.decodeIfPresent(Bool.self, forKey: .open) ?? false
        vibes = try c.decodeIfPresent(Bool.self, forKey: .vibes) ?? false
        backlog = try c.decodeIfPresent(Bool.self, forKey: .backlog) ?? false
        lane = try c.decodeIfPresent(String.self, forKey: .lane)
    }
}

/// `PATCH /api/cards/:id`: what is given changes. An empty title hands
/// naming back to Claude, and an empty `dependsOnId` stops the card waiting.
public struct EditCardBody: Codable, Equatable, Sendable {
    public var title: String?
    /// The card in VIBES MODE on its own, or back out of it.
    public var vibes: Bool?
    /// The full id of the card it waits on.
    public var dependsOnId: String?

    public init(title: String? = nil, vibes: Bool? = nil, dependsOnId: String? = nil) {
        self.title = title
        self.vibes = vibes
        self.dependsOnId = dependsOnId
    }
}

/// `POST /api/cards/:id/move`: to another column, another swimlane, or both.
public struct MoveBody: Codable, Equatable, Sendable {
    public var stage: Stage?
    /// The swimlane, by id or name.
    public var lane: String?
    /// A backlog card moved on starts; work in its folder itself if git
    /// can't make it a worktree, rather than fail.
    public var inFolder: Bool

    public init(stage: Stage? = nil, lane: String? = nil, inFolder: Bool = false) {
        self.stage = stage
        self.lane = lane
        self.inFolder = inFolder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage)
        lane = try c.decodeIfPresent(String.self, forKey: .lane)
        inFolder = try c.decodeIfPresent(Bool.self, forKey: .inFolder) ?? false
    }
}

/// `POST /api/cards/:id/run`.
public struct RunBody: Codable, Equatable, Sendable {
    /// Stop a live session and start it again, rather than leave it be.
    public var restart: Bool

    public init(restart: Bool = false) {
        self.restart = restart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restart = try c.decodeIfPresent(Bool.self, forKey: .restart) ?? false
    }
}

/// `POST /api/cards/:id/reply`.
public struct ReplyBody: Codable, Equatable, Sendable {
    public var text: String
    /// Type it even while Claude Code shows a dialog, which it may answer.
    public var force: Bool

    public init(text: String, force: Bool = false) {
        self.text = text
        self.force = force
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

public struct ReplyResponse: Codable, Equatable, Sendable {
    public enum Delivery: String, Codable, Sendable {
        /// Typed into the live session.
        case typed
        /// The session wasn't running; it was started with the text as its prompt.
        case started
    }

    public var delivered: Delivery
    public var card: APICard

    public init(delivered: Delivery, card: APICard) {
        self.delivered = delivered
        self.card = card
    }
}

/// `POST /api/cards/:id/merge`: the card's pull request, merged on GitHub.
public struct MergeResponse: Codable, Equatable, Sendable {
    /// Where the pull request stands after gh merged it: `merged`, or `open`
    /// when the repo queued it to land later.
    public var state: PullRequest.State
    public var card: APICard

    public init(state: PullRequest.State, card: APICard) {
        self.state = state
        self.card = card
    }
}

/// `GET /api/cards/:id/plan`.
public struct PlanResponse: Codable, Equatable, Sendable {
    public var text: String?
    public var path: String?

    public init(text: String?, path: String?) {
        self.text = text
        self.path = path
    }
}

/// `GET /api/cards/:id/diff`: what the card has changed since it started.
public struct ChangesResponse: Codable, Equatable, Sendable {
    public var files: [FileDiff]
    /// The short commit they are against; nil when it is HEAD.
    public var base: String?
    /// New files left out: too many, too big, or past the size limit.
    public var untrackedLeftOut: Int
    /// The diff was cut short.
    public var truncated: Bool

    public init(files: [FileDiff], base: String?, untrackedLeftOut: Int, truncated: Bool) {
        self.files = files
        self.base = base
        self.untrackedLeftOut = untrackedLeftOut
        self.truncated = truncated
    }
}

/// Any refusal: a short reason, and more when there is more to say.
public struct APIError: Codable, Equatable, Error, Sendable {
    public var error: String
    public var detail: String?

    public init(_ error: String, detail: String? = nil) {
        self.error = error
        self.detail = detail
    }
}
