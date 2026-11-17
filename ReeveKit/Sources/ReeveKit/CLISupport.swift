import Foundation

/// `reeve`'s exit codes, the same as reeve-board's. Scripts and agents branch
/// on them, so they are never renumbered.
public enum ExitCode: Int32, Sendable {
    case ok = 0
    case error = 1
    case usage = 2
    /// `card wait`: Claude is waiting on a person.
    case needsInput = 3
    /// `card wait`: the session's process died.
    case failed = 4
    /// `card wait`: nothing is running.
    case idle = 5
    /// `card wait`: `--timeout` ran out.
    case timeout = 6
}

/// A command line `reeve` was given that it can't make sense of.
public struct UsageError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// A column by the names a person might type it.
public enum StageName {
    public static let accepted = "backlog, planning, in-progress, testing, release (or done)"

    public static func parse(_ text: String) -> Stage? {
        let key = text.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if key == "done" { return .release }
        return Stage(rawValue: key)
    }

    /// How `reeve` writes a stage back: as it accepts it.
    public static func name(_ stage: Stage) -> String {
        stage.rawValue.replacingOccurrences(of: "_", with: "-")
    }
}

/// Finds the card a person meant.
public enum CardRef {
    public enum Failure: Error, Equatable, Sendable {
        case notFound(String)
        case ambiguous(String, [UUID])
        /// No card was named, and neither `REEVE_CARD_ID` nor the folder says which.
        case noDefault
    }

    /// The shortest id prefix accepted, so `card show a` isn't a lottery.
    public static let minimumPrefix = 4

    /// A card's id, or a prefix of it, else its title. Ids are matched
    /// whatever their case, since `REEVE_CARD_ID` is upper case and branches
    /// are lower.
    public static func resolve(_ ref: String, in cards: [Card]) throws -> Card {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        let needle = trimmed.lowercased()
        if let id = UUID(uuidString: trimmed), let card = cards.first(where: { $0.id == id }) {
            return card
        }
        if needle.count >= minimumPrefix, needle.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let matches = cards.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw Failure.ambiguous(ref, matches.map(\.id)) }
        }
        let titled = cards.filter { $0.title.lowercased() == needle && !needle.isEmpty }
        if titled.count == 1 { return titled[0] }
        if titled.count > 1 { throw Failure.ambiguous(ref, titled.map(\.id)) }
        throw Failure.notFound(ref)
    }

    /// The card a command means when it isn't told: the one whose terminal
    /// this is (`REEVE_CARD_ID`), else the one whose worktree holds `cwd`.
    /// `realpath` resolves symlinks, so `/tmp` and `/private/tmp` agree.
    public static func current(in cards: [Card], cwd: String, environment: [String: String],
                               realpath: (String) -> String) throws -> Card {
        if let env = environment["REEVE_CARD_ID"], let id = UUID(uuidString: env),
           let card = cards.first(where: { $0.id == id }) {
            return card
        }
        let here = realpath(cwd)
        let holding = cards.compactMap { card -> (Card, Int)? in
            guard let worktree = card.worktreePath else { return nil }
            let root = realpath(worktree)
            guard here == root || here.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
            return (card, root.count)
        }
        // A worktree inside another card's folder: the deepest one is the card's.
        if let deepest = holding.max(by: { $0.1 < $1.1 }) { return deepest.0 }
        throw Failure.noDefault
    }

    /// `ref` when there is one, else the current card.
    public static func resolve(_ ref: String?, in cards: [Card], cwd: String, environment: [String: String],
                               realpath: (String) -> String) throws -> Card {
        if let ref { return try resolve(ref, in: cards) }
        return try current(in: cards, cwd: cwd, environment: environment, realpath: realpath)
    }

    /// The first characters of an id, as `reeve` prints them and as the
    /// card's branch (`reeve/<id>`) names it.
    public static func short(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}

/// A command line split into positionals, options and flags.
///
/// `--name value`, `--name=value`, `--flag` and `-f` are understood. Which
/// names take a value is said up front, so `--title --json` is an error rather
/// than a title of "--json". Everything after `--` is positional.
public struct Arguments: Equatable, Sendable {
    public private(set) var positionals: [String] = []
    public private(set) var options: [String: [String]] = [:]
    public private(set) var flags: Set<String> = []

    /// - Parameters:
    ///   - valued: long names that take a value.
    ///   - flags: long names that don't.
    ///   - short: single letters, each for one of the long names.
    public init(_ args: [String], valued: Set<String>, flags known: Set<String>, short: [Character: String] = [:]) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            if arg == "--" {
                positionals += rest
                break
            }
            if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var value: String?
                if let eq = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if valued.contains(name) {
                    if value == nil {
                        guard let next = rest.popFirst() else { throw UsageError("--\(name) needs a value") }
                        value = next
                    }
                    options[name, default: []].append(value!)
                } else if known.contains(name) {
                    guard value == nil else { throw UsageError("--\(name) doesn't take a value") }
                    flags.insert(name)
                } else {
                    throw UsageError("unknown option --\(name)")
                }
            } else if arg.count > 1, arg.hasPrefix("-"), !arg.dropFirst().allSatisfy(\.isNumber) {
                for letter in arg.dropFirst() {
                    guard let name = short[letter] else { throw UsageError("unknown option -\(letter)") }
                    guard !valued.contains(name) || arg.count == 2 else { throw UsageError("-\(letter) needs a value of its own") }
                    if valued.contains(name) {
                        guard let next = rest.popFirst() else { throw UsageError("-\(letter) needs a value") }
                        options[name, default: []].append(next)
                    } else {
                        flags.insert(name)
                    }
                }
            } else {
                positionals.append(arg)
            }
        }
    }

    /// The option's last value, when given.
    public func value(_ name: String) -> String? {
        options[name]?.last
    }

    public func has(_ flag: String) -> Bool {
        flags.contains(flag)
    }
}

/// Lines of columns padded to line up, two spaces apart. The last column is
/// left as it is, since it is free text that would only pad the line.
/// What `reeve doctor` reads out of `gh auth status`.
public enum GhAuth {
    /// The token's OAuth scopes, from its "Token scopes: 'repo', 'workflow'"
    /// line. With more than one account logged in, the active one's. Nil when
    /// it names none: a fine-grained token or `GH_TOKEN` says `none` or leaves
    /// the line out, and has no scopes to lack.
    public static func scopes(in status: String) -> [String]? {
        // Each account's lines follow its "Logged in to" line.
        var accounts: [[Substring]] = []
        for line in status.split(separator: "\n") {
            if line.contains("Logged in to") || accounts.isEmpty { accounts.append([]) }
            accounts[accounts.count - 1].append(line)
        }
        let account = accounts.first { $0.contains { $0.contains("Active account: true") } } ?? accounts.first ?? []
        guard let line = account.first(where: { $0.contains("Token scopes:") }),
              let list = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
              !list.isEmpty, list != "none" else { return nil }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
    }

    /// GitHub refuses a push or merge that touches `.github/workflows/`
    /// without this scope, and says so only then.
    public static let workflowFix = "gh auth refresh -h github.com -s workflow"
}

public enum Table {
    public static func format(_ rows: [[String]], indent: String = "") -> String {
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        var widths = [Int](repeating: 0, count: width)
        for row in rows {
            for (i, cell) in row.enumerated() where i < width - 1 {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return rows.map { row in
            let cells = row.enumerated().map { i, cell in
                i < row.count - 1 ? cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) : cell
            }
            return indent + cells.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

/// How `card wait` ends for a card in a given state.
public enum WaitOutcome {
    /// Nil while there is still something to wait for: the session is
    /// starting, Claude is working, or background work it started will wake it.
    public static func of(_ card: APICard) -> ExitCode? {
        if card.starting { return nil }
        switch card.card.activity {
        case .running, .waiting: return card.live ? nil : .idle
        case .needsReview: return .ok
        case .needsInput: return .needsInput
        case .error: return .failed
        case .idle: return .idle
        }
    }
}

/// `reeve --help`. Also what the command bar's Claude is told it can run.
public enum CLIUsage {
    public static let text = """
reeve — Reeve Terminal's board from a shell

Reading
  reeve board [--stage S] [--lane L] [--repo PATH]  every card, column by column
  reeve card show [<card>]                    a card: where it is, what it's doing, its plan
  reeve card plan [<card>]                    the card's plan, as Markdown
  reeve card diff [<card>] [--stat]           what the card has changed since it started
  reeve card worktree [<card>]                the card's worktree path
  reeve card pr [<card>]                      the URL of the card's pull request
  reeve status                                is the app running? (exit 0 or 1)
  reeve models                                models and efforts a card can start with
  reeve doctor                                check git, claude, gh and its workflow scope

Driving
  reeve card add [<title…>] [--prompt TEXT] [--mode plan|build|backlog] [--lane L] [--cwd DIR] …
  reeve card edit <card> [--title TITLE | --no-title] [--vibes | --no-vibes] [--wait-on CARD | --no-wait-on]
  reeve card move <card> [<stage>] [--lane L]
  reeve card run <card> [--restart]
  reeve card reply <card> <text…> [--file PATH|-]
  reeve card wait [<card>] [--timeout SECONDS]
  reeve card merge <card>                     merge a Release card's pull request on GitHub
  reeve card close <card> [--force]
  reeve open [<card>]
  reeve vibes [on | off]                      the board's VIBES MODE switch

<card> is a card's id or its first characters (as in its branch, reeve/<id>),
or its title. Left out, it is the card whose terminal or worktree you're in.
Stages: \(StageName.accepted). Swimlanes (L) are rows across the columns,
named by the person; `reeve board --json` lists them under "lanes".
A backlog card made with --mode backlog starts nothing until it's moved to
planning or in-progress.
--json prints the API's answer and nothing else. `reeve card <command> --help`
says more.

Exit codes: 0 ok, 1 error, 2 bad command line. `card wait`: 0 ready for
review, 3 waiting on you, 4 failed, 5 nothing running, 6 timed out.
"""
}
