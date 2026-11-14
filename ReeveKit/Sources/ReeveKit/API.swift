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

    public init(card: Card, live: Bool, starting: Bool, dialogOpen: Bool, displayTitle: String) {
        self.card = card
        self.live = live
        self.starting = starting
        self.dialogOpen = dialogOpen
        self.displayTitle = displayTitle
    }

    private enum Extra: String, CodingKey {
        case live, starting, dialogOpen, displayTitle
    }

    public init(from decoder: Decoder) throws {
        card = try Card(from: decoder)
        let extra = try decoder.container(keyedBy: Extra.self)
        live = try extra.decode(Bool.self, forKey: .live)
        starting = try extra.decode(Bool.self, forKey: .starting)
        dialogOpen = try extra.decode(Bool.self, forKey: .dialogOpen)
        displayTitle = try extra.decode(String.self, forKey: .displayTitle)
    }

    public func encode(to encoder: Encoder) throws {
        try card.encode(to: encoder)
        var extra = encoder.container(keyedBy: Extra.self)
        try extra.encode(live, forKey: .live)
        try extra.encode(starting, forKey: .starting)
        try extra.encode(dialogOpen, forKey: .dialogOpen)
        try extra.encode(displayTitle, forKey: .displayTitle)
    }
}

/// `GET /api/board`: every card in board order, column by column.
public struct BoardResponse: Codable, Equatable, Sendable {
    public var cards: [APICard]
    /// The card open over the board, if any.
    public var selectedId: UUID?

    public init(cards: [APICard], selectedId: UUID?) {
        self.cards = cards
        self.selectedId = selectedId
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
    /// Open the card over the board, as the new card sheet does.
    public var open: Bool

    public init(cwd: String, title: String = "", prompt: String? = nil, mode: StartMode = .plan,
                model: String? = nil, effort: String? = nil, inFolder: Bool = false, open: Bool = false) {
        self.cwd = cwd
        self.title = title
        self.prompt = prompt
        self.mode = mode
        self.model = model
        self.effort = effort
        self.inFolder = inFolder
        self.open = open
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
    }
}

/// `PATCH /api/cards/:id`. An empty title hands naming back to Claude.
public struct EditCardBody: Codable, Equatable, Sendable {
    public var title: String?

    public init(title: String?) {
        self.title = title
    }
}

/// `POST /api/cards/:id/move`.
public struct MoveBody: Codable, Equatable, Sendable {
    public var stage: Stage

    public init(stage: Stage) {
        self.stage = stage
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
