import Foundation

/// VIBES MODE deciding what to build next, once a repo has nothing left to do.
///
/// Without this the board's switch runs a board down to empty and stops,
/// waiting for a person to think of something — the one human step it had
/// left. With it, the last card to ship in a repo is asked what should follow
/// it, and the answer lands in Backlog, where VIBES MODE starts it like any
/// card a person typed.
///
/// The board's switch only. A card in VIBES MODE on its own was promised one
/// card taken to a merged pull request, and a chain of cards thinking of more
/// cards, with no scoreboard to count them and no arming screen that said it
/// would, would be breaking that promise.
///
/// "Run dry" counts a card in Release as finished, shipped or not, so with
/// Merge to Main off the next ideas still come while pull requests wait for a
/// person — and are built on the default branch without them. That is the
/// option working as asked: it holds back landing, not building.
public enum Ideas {
    /// However many Claude proposes, no more than this lands on the board from one run.
    public static let max = 3

    /// How much of the repo's history the prompt lists. Enough to stop Claude
    /// proposing last week's work again; not so much that a long-lived repo's
    /// backlog is most of the prompt.
    public static let cardsListed = 60

    /// What one run may spend, and how hard it thinks. Reading a repo and
    /// proposing three cards is not worth more.
    public static let budgetUsd = "2"
    public static let effort = "medium"

    /// The repo a card belongs to, as a path: the checkout its worktree was
    /// made from, else the folder it works in.
    public static func repo(of card: Card) -> String {
        Repo.normalize(card.repoPath ?? card.cwd)
    }

    /// Whether the card is work the repo still has to do: anything on the
    /// board short of Release that hasn't shipped, Backlog included.
    public static func isOpen(_ card: Card) -> Bool {
        card.archivedAt == nil && card.stage != .release && card.shippedAt == nil
    }

    /// The card `repo` should have its next ideas after, or nil while it
    /// should not have any: while it still has work open.
    ///
    /// Only the card that shipped last since the switch went on, and only
    /// once. Not "any shipped card without ideas yet", which would work back
    /// through the repo's history as each newest card was archived. So a repo
    /// that has shipped nothing since then has no ideas, and one whose ideas
    /// came to nothing — the run failed, or thought of nothing worth doing —
    /// stays empty until something else in it ships.
    public static func source(for repo: String, board: [Card], archive: [Card], since: Date) -> Card? {
        let mine = { (card: Card) in Ideas.repo(of: card) == repo }
        guard !board.contains(where: { mine($0) && isOpen($0) }) else { return nil }
        let last = (board + archive)
            .filter { card in mine(card) && (card.shippedAt.map { $0 > since } ?? false) }
            .max { $0.shippedAt! < $1.shippedAt! }
        guard let last, last.ideasAsked != true else { return nil }
        return last
    }

    /// What one idea makes: a card for Backlog.
    public struct Idea: Decodable, Equatable, Sendable {
        public var title: String
        public var body: String
        public var criteria: [String]

        public init(title: String, body: String, criteria: [String] = []) {
            self.title = title
            self.body = body
            self.criteria = criteria
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
            body = try c.decode(String.self, forKey: .body).trimmingCharacters(in: .whitespacesAndNewlines)
            criteria = (try c.decodeIfPresent([String].self, forKey: .criteria) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        enum CodingKeys: String, CodingKey {
            case title, body, criteria
        }

        /// What the card says to Claude when it starts, which is all its
        /// session sees: the title the body was written under, then the body.
        /// A terminal card has nowhere else to keep its acceptance criteria,
        /// so they go in too.
        public var brief: String {
            let brief = title + "\n\n" + body
            guard !criteria.isEmpty else { return brief }
            return brief + "\n\nDone when:\n" + criteria.map { "- \($0)" }.joined(separator: "\n")
        }
    }

    /// The ideas that become cards: at most `max`, best first, and none the
    /// repo has had before. Clamped here as well as asked for in the prompt,
    /// because each one is a card that will be built unread. A title the repo
    /// has already had, archived included, is skipped, and so is one with no
    /// words in it, which would sit in Backlog as a placeholder.
    public static func accepted(_ ideas: [Idea], existingTitles: [String]) -> [Idea] {
        var have = Set(existingTitles.map(key))
        var kept: [Idea] = []
        for idea in ideas where kept.count < max {
            let k = key(idea.title)
            guard !k.isEmpty, have.insert(k).inserted else { continue }
            kept.append(idea)
        }
        return kept
    }

    private static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["ideas"],"properties":{"ideas":{"type":"array","maxItems":\(max),"items":{\
    "type":"object","additionalProperties":false,"required":["title","body","criteria"],"properties":{\
    "title":{"type":"string","description":"A short title, as it would read on a board"},\
    "body":{"type":"string","description":"A brief: what to build and why it is worth doing now"},\
    "criteria":{"type":"array","items":{"type":"string"},"description":"A handful of acceptance criteria a person could observe and check off"}}}}}}
    """

    /// Arguments after the `claude` executable. Told to change nothing, and
    /// given only the tools that read: this may be the person's own checkout,
    /// with their work in it.
    public static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", schema,
            "--effort", effort,
            "--max-budget-usd", budgetUsd,
            // A side call, not a session: keep it out of the session list, and
            // keep the person's own hooks and permissions out of it.
            "--no-session-persistence",
            "--tools", "Read,Grep,Glob",
            "--setting-sources", "",
        ]
    }

    /// The prompt, about the card that shipped last and everything else the
    /// repo has had, newest first.
    public static func prompt(repo: String, directory: String, source: Card, history: [Card]) -> String {
        let listed = history.sorted { $0.createdAt > $1.createdAt }.prefix(cardsListed)
        let cards = listed.isEmpty ? "_None._" : listed.map { card in
            let state = card.archivedAt != nil ? "archived" : card.shippedAt != nil ? "shipped" : card.stage.label
            return "- \(card.title.isEmpty ? "Untitled" : card.title) (\(state))"
        }.joined(separator: "\n")
        let body = [source.summary, source.brief].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return """
        You are deciding what to build next in the repository at `\(directory)`.

        Reeve is in VIBES MODE: every card on the board is being planned, built, \
        tested and merged with nobody reviewing it. This repo, **\(URL(fileURLWithPath: repo).lastPathComponent)**, has just \
        run out of work, and the cards you propose here are what it will build next, \
        starting as soon as you finish. Nobody will read them first.

        ## What was finished last

        **\(source.title.isEmpty ? "Untitled" : source.title)**

        \(body.isEmpty ? "_No summary._" : body)

        ## What this repo already has

        Every card it has had, newest first, open and finished alike:

        \(cards)

        ## What to do

        Look at enough of the code to know what it does and where it is rough: its \
        README, its layout, what the last card changed, the gaps and TODOs a careful \
        reader would find. Then propose what to build next.

        Read and search as you need, but change nothing: do not edit, create or \
        delete files. This may be the person's own checkout rather than a card's \
        worktree, with their work in it. Reeve makes the cards from what you return.

        - Each idea should be a piece of work that could be planned, built and merged \
        on its own, and leave the project better than it found it. Prefer what a \
        person using or maintaining it would actually notice: a missing feature the \
        code is clearly reaching for, a bug, a rough edge, a gap in the tests.
        - Keep each one small enough to finish in one sitting. Nothing that needs a \
        decision only a person could make, a new service or account, a secret, or a \
        change to how the project is deployed.
        - Do not propose anything already listed above, finished or not, or a new \
        wording of one.
        - Give each a short title as it would read on a board, a brief that says what \
        to build and why it is worth doing now, and a handful of acceptance criteria \
        a person could observe and check off.
        - Best first. At most \(max).

        None at all is a good answer when nothing is worth doing. Whatever you propose \
        is built without anyone asking whether it should be, so propose only what you \
        would defend.
        """
    }

    /// Reads `claude -p --output-format json` output.
    public static func parse(_ data: Data) throws -> [Idea] {
        struct Output: Decodable { var ideas: [Idea] }
        return try JSONDecoder().decode(Output.self, from: Classifier.structuredOutput(data)).ideas
    }

    /// The scoreboard's log line once they land.
    public static func summary(_ count: Int, after title: String) -> String {
        count == 0
            ? "Thought of nothing worth doing after “\(title)”"
            : "Claude thought of \(count) thing\(count == 1 ? "" : "s") to build after “\(title)”"
    }
}
