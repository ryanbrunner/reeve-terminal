import Foundation

/// One card waiting on another, and the rule that comes with it: a card in
/// Backlog does not start until the card it waits on has merged.
///
/// One place, because every way a backlog card starts — a drag, Plan it and
/// Start building, `reeve card move` — has to refuse the same cards for the
/// same reason, VIBES MODE has to hold back from the same ones, and the card's
/// face has to say so. A second copy of "merged" would drift the first time
/// either grew a case.
///
/// Repos are no boundary: a card can wait on one in another repo, and nothing
/// about either card's worktree changes when it does.
public enum Dependency {
    /// Whether a card waited on still stands in the way: it hasn't merged.
    /// Merged is its pull request merged, or its branch found on main, and a
    /// card in the archive merged to get there.
    public static func stillBlocking(_ card: Card) -> Bool {
        card.archivedAt == nil && card.pullRequest?.state != .merged && card.merged != true
    }

    /// The card `card` waits on while it still stands in the way, else nil.
    /// `board` is the cards on the board: one closed since has nothing left to
    /// wait for, and one archived has merged.
    public static func blocker(of card: Card, in board: [Card]) -> Card? {
        guard let id = card.dependsOnId, let target = board.first(where: { $0.id == id }) else { return nil }
        return stillBlocking(target) ? target : nil
    }

    /// How far a card waited on has got, in words: its column, and in Release
    /// what it is still waiting for there.
    public static func status(of card: Card) -> String {
        if !stillBlocking(card) { return card.archivedAt == nil ? "merged" : "merged, archived" }
        if card.queued == true { return "\(card.stage.label), not started" }
        guard card.stage == .release else { return card.stage.label }
        return card.hasLivePullRequest ? "Release, PR not merged" : "Release, no pull request yet"
    }

    /// Why `card` may not start yet, naming the card it waits on, else nil.
    public static func refusal(_ card: Card, in board: [Card], name: (Card) -> String) -> APIError? {
        guard let blocker = blocker(of: card, in: board) else { return nil }
        return APIError("waits on “\(name(blocker))”, which hasn't merged",
                        detail: "\(CardRef.short(blocker.id)) is in \(status(of: blocker)); \(name(card)) can start once it merges")
    }

    /// Why `card` may not wait on `target`, else nil. Never on itself, and
    /// never a link that closes a loop: cards each waiting on the next, which
    /// nothing could ever start. `cards` is every card, archived ones too,
    /// since a loop through a card nobody can see is still a loop.
    public static func linkRefusal(_ card: Card, waitingOn target: Card, in cards: [Card], name: (Card) -> String) -> APIError? {
        if target.id == card.id { return APIError("a card can't wait on itself") }
        var path = [target]
        var seen: Set<UUID> = [target.id]
        while let next = path.last?.dependsOnId, let found = cards.first(where: { $0.id == next }), seen.insert(next).inserted {
            path.append(found)
            guard found.id == card.id else { continue }
            let between = path.dropFirst().dropLast().map { "“\(name($0))”" }
            return APIError("that would make a loop",
                            detail: "“\(name(target))” already waits on “\(name(card))”" + (between.isEmpty ? "" : ", through " + between.joined(separator: " → ")))
        }
        return nil
    }
}

/// The card another waits on, as the API shows it.
public struct DependencyLink: Codable, Equatable, Sendable {
    public var id: UUID
    /// Its name on the board, or empty for a card closed since.
    public var title: String
    /// Merged, archived or closed: nothing stands in the way any more.
    public var done: Bool
    /// Where it has got to, in words: "Testing", "Release, PR not merged", "merged".
    public var status: String

    public init(id: UUID, title: String, done: Bool, status: String) {
        self.id = id
        self.title = title
        self.done = done
        self.status = status
    }
}
