import Foundation

/// A pull request opened from one of a card's branches. The card wears the one
/// from the branch it is on as a badge, and lists them all in its PRs tab.
public struct PullRequest: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    /// How the pull request's checks stand, counted from gh's status rollup.
    public struct Checks: Codable, Equatable, Sendable {
        public enum Overall: Sendable { case passing, pending, failing }

        public var passed: Int
        public var failed: Int
        public var pending: Int

        public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
        }

        public var total: Int { passed + failed + pending }

        /// Any failure fails the lot; otherwise anything still running holds it.
        public var overall: Overall {
            failed > 0 ? .failing : pending > 0 ? .pending : .passing
        }
    }

    /// Where the pull request's review stands, as GitHub decides it.
    public enum Review: String, Codable, Sendable {
        case approved, changesRequested, required
    }

    public var number: Int
    public var state: State
    public var url: String
    public var title: String
    /// The branch the pull request was opened from.
    public var branch: String
    /// Nil when the pull request has no checks.
    public var checks: Checks?
    /// Nil when the repo asks for no review.
    public var review: Review?
    /// When it was opened, which tells one the card's session opened from one
    /// it only came across by checking a branch out.
    public var createdAt: Date?

    public init(number: Int, state: State, url: String, title: String = "", branch: String = "", checks: Checks? = nil, review: Review? = nil, createdAt: Date? = nil) {
        self.number = number
        self.state = state
        self.url = url
        self.title = title
        self.branch = branch
        self.checks = checks
        self.review = review
        self.createdAt = createdAt
    }

    /// `gh`'s arguments for the pull requests opened from `branch`, in any
    /// state. By head branch rather than `gh pr view`, because a card's
    /// branch usually has no upstream for gh to follow.
    public static func listArguments(branch: String) -> [String] {
        ["pr", "list", "--head", branch, "--state", "all",
         "--json", "number,state,isDraft,url,title,headRefName,statusCheckRollup,reviewDecision,createdAt", "--limit", "10"]
    }

    /// Every pull request in `gh pr list --json` output, newest first.
    public static func parseAll(_ data: Data) throws -> [PullRequest] {
        /// A check run (GitHub Actions and other apps) or a commit status
        /// (older CI): gh mixes both in one rollup, with different fields.
        struct Check: Decodable {
            var __typename: String?
            var status: String?
            var conclusion: String?
            var state: String?
        }
        struct Listed: Decodable {
            var number: Int
            var state: String
            var isDraft: Bool?
            var url: String
            var title: String?
            var headRefName: String?
            var statusCheckRollup: [Check]?
            var reviewDecision: String?
            var createdAt: String?
        }
        let failures: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
        func checks(_ rollup: [Check]?) -> Checks? {
            guard let rollup, !rollup.isEmpty else { return nil }
            var checks = Checks()
            for check in rollup {
                if check.__typename == "StatusContext" || (check.status == nil && check.state != nil) {
                    // A commit status has a state and nothing else.
                    switch check.state {
                    case "PENDING", "EXPECTED": checks.pending += 1
                    case let state? where failures.contains(state): checks.failed += 1
                    default: checks.passed += 1
                    }
                } else if check.status != "COMPLETED" {
                    checks.pending += 1
                } else if let conclusion = check.conclusion, failures.contains(conclusion) {
                    checks.failed += 1
                } else {
                    checks.passed += 1
                }
            }
            return checks
        }
        return try JSONDecoder().decode([Listed].self, from: data)
            .sorted { $0.number > $1.number }
            .map { listed in
                let state: State = switch listed.state {
                case "OPEN": listed.isDraft == true ? .draft : .open
                case "MERGED": .merged
                default: .closed
                }
                let review: Review? = switch listed.reviewDecision {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "REVIEW_REQUIRED": .required
                default: nil
                }
                return PullRequest(number: listed.number, state: state, url: listed.url, title: listed.title ?? "",
                                   branch: listed.headRefName ?? "", checks: checks(listed.statusCheckRollup), review: review,
                                   createdAt: listed.createdAt.flatMap { try? Date($0, strategy: .iso8601) })
            }
    }

    /// The pull request a card on `branch` stands for: of those opened from
    /// it, the newest open one, else the newest of any. Nil when the branch
    /// has none, even if the card's earlier branches do.
    public static func primary(of pullRequests: [PullRequest], on branch: String?) -> PullRequest? {
        guard let branch else { return nil }
        let mine = pullRequests.filter { $0.branch == branch }.sorted { $0.number > $1.number }
        return mine.first(where: { $0.state == .open || $0.state == .draft }) ?? mine.first
    }

    /// Of the pull requests gh `found`, the ones that are the card's: any from
    /// the branches it `owns` (the one it is on and the one Reeve made), any
    /// it already tracks, and any opened `since` it was made. A colleague's
    /// pull request, met by checking their branch out, is left alone.
    public static func belonging(_ found: [PullRequest], owns: Set<String>, tracked: [PullRequest], since: Date) -> [PullRequest] {
        let numbers = Set(tracked.map(\.number))
        return found.filter { pr in
            owns.contains(pr.branch) || numbers.contains(pr.number) || (pr.createdAt.map { $0 >= since } ?? false)
        }
    }

    /// `tracked` with what gh just `found`: a pull request found again is
    /// replaced, one not asked about this time is kept. Newest first.
    public static func merge(_ tracked: [PullRequest], _ found: [PullRequest]) -> [PullRequest] {
        var byNumber = Dictionary(tracked.map { ($0.number, $0) }, uniquingKeysWith: { _, last in last })
        for pr in found { byNumber[pr.number] = pr }
        return byNumber.values.sorted { $0.number > $1.number }
    }

    /// The branches a worktree has been on, newest first, from
    /// `git reflog show HEAD --format=%gs`: both ends of each
    /// `checkout: moving from X to Y`. So a pull request opened from a branch
    /// Claude left before its turn ended is still found. Detached commits are
    /// left out, and only the latest `limit` are kept.
    public static func checkedOutBranches(reflog: String, limit: Int = 10) -> [String] {
        let prefix = "checkout: moving from "
        var branches: [String] = []
        func add(_ name: Substring) {
            let name = String(name)
            guard !name.isEmpty, !isCommit(name), !branches.contains(name) else { return }
            branches.append(name)
        }
        for line in reflog.split(separator: "\n") where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            guard let to = rest.range(of: " to ", options: .backwards) else { continue }
            add(rest[to.upperBound...])
            add(rest[..<to.lowerBound])
        }
        return Array(branches.prefix(limit))
    }

    private static func isCommit(_ name: String) -> Bool {
        name.count >= 7 && name.count <= 40 && name.allSatisfy(\.isHexDigit)
    }
}
