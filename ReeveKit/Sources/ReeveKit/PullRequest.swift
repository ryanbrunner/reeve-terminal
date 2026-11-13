import Foundation

/// The pull request opened from a card's branch, which the card wears as a badge.
public struct PullRequest: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    public var number: Int
    public var state: State
    public var url: String

    public init(number: Int, state: State, url: String) {
        self.number = number
        self.state = state
        self.url = url
    }

    /// `gh`'s arguments for the pull requests opened from `branch`, in any
    /// state. By head branch rather than `gh pr view`, because a card's
    /// branch usually has no upstream for gh to follow.
    public static func listArguments(branch: String) -> [String] {
        ["pr", "list", "--head", branch, "--state", "all", "--json", "number,state,isDraft,url", "--limit", "10"]
    }

    /// The branch's pull request from `gh pr list --json` output: the newest
    /// open one, else the newest of any. Nil when there is none.
    public static func parse(_ data: Data) throws -> PullRequest? {
        struct Listed: Decodable {
            var number: Int
            var state: String
            var isDraft: Bool?
            var url: String
        }
        let listed = try JSONDecoder().decode([Listed].self, from: data).sorted { $0.number > $1.number }
        guard let pick = listed.first(where: { $0.state == "OPEN" }) ?? listed.first else { return nil }
        let state: State = switch pick.state {
        case "OPEN": pick.isDraft == true ? .draft : .open
        case "MERGED": .merged
        default: .closed
        }
        return PullRequest(number: pick.number, state: state, url: pick.url)
    }
}
