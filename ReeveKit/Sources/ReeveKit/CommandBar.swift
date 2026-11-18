import Foundation

/// The command bar above the board: a request in plain words — add a card,
/// how are things going, move this one — that Claude carries out with
/// `reeve`, the command line a card's Claude already has.
///
/// One `claude -p` per request, on the person's own Claude login. Bash is its
/// only tool and `reeve` the only command it may run. Anything with `--force`
/// is refused, since it throws work away or answers a session's dialog for it.
/// A plain `card close` may run: the app refuses one that would lose work.
public enum CommandBar {
    public static let model = "sonnet"
    static let allowed = ["Bash(reeve *)"]
    static let denied = ["Bash(reeve *--force*)"]

    /// Arguments after the `claude` executable. The request goes on stdin.
    public static func arguments(repos: [String], startRepo: String?) -> [String] {
        ["-p",
         "--model", model,
         "--effort", "low",
         "--output-format", "json",
         "--system-prompt", systemPrompt(repos: repos, startRepo: startRepo),
         "--tools", "Bash",
         "--allowedTools"] + allowed + ["--disallowedTools"] + denied + [
         // Anything else is refused rather than put to a person nobody is asking.
         "--permission-mode", "dontAsk",
         // A side call, not a session, and none of the person's hooks or MCP servers.
         "--no-session-persistence",
         "--setting-sources", "",
         "--strict-mcp-config"]
    }

    public static func systemPrompt(repos: [String], startRepo: String?) -> String {
        let start = startRepo ?? repos.first
        let repoLines = repos.isEmpty
            ? "There are no repos on the list yet, so a new card needs the person to say which folder it starts in."
            : "The repos a new card can start in:\n" + repos.map { "- \($0)" }.joined(separator: "\n")
                + (start.map { "\nUse \($0) unless the person names another." } ?? "")
        return """
        You are the command bar of Reeve, a macOS kanban board of Claude Code sessions. Each card is a Claude Code session working in a worktree of a repo, and its column follows the session: backlog, design, planning, in_progress, testing, release. The person types one request at a time: add cards, ask how things stand, move, rename, run, reply to or close cards, or switch VIBES MODE on or off.

        Carry it out with the `reeve` command line, through the Bash tool. It is the only command you can run: one `reeve` command per call, with no pipes, `&&` or other programs. `--force` is refused; if asked for it, say it needs doing in Reeve itself.

        \(CLIUsage.text)

        - Read the board with `reeve board --json`, or `reeve card show <card> --json`, before answering about it or changing a card. Never guess what is on it.
        - You are not in any card, so always name the card, by its id's first characters or its title. If more than one card could be meant, ask which instead of changing any.
        - A new card: `reeve card add "<2 to 6 word title>" --prompt "<the request>" --cwd <repo>`. Always pass --cwd. The card's Claude starts on the prompt straight away, so give it what the person asked for, in their words, and nothing they didn't. Add --mode plan only if they ask for a plan first, --mode design only if they ask for a design or mockups first (Claude runs /design), or --mode backlog if they want it kept for later rather than started. Add --lane only if they name a swimlane.
        \(repoLines)
        - Close a card only when the person asks for that card to be closed. `reeve card close <card>` refuses a card with uncommitted changes, unmerged commits or an open pull request; then say what it would lose and that closing it anyway needs doing in Reeve. Never retry with --force.

        Reply in one to three short plain sentences, without Markdown: what you did, or the answer. Name cards by title.
        """
    }

    /// Reads `claude -p --output-format json` output.
    public static func parse(_ data: Data) throws -> CommandBarAnswer {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassifierError.unreadable
        }
        let result = (envelope["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if envelope["is_error"] as? Bool == true {
            throw ClassifierError.failed(result.isEmpty ? "claude -p failed" : result)
        }
        let refused = (envelope["permission_denials"] as? [[String: Any]] ?? []).compactMap {
            ($0["tool_input"] as? [String: Any])?["command"] as? String
        }
        return CommandBarAnswer(reply: result, refused: refused)
    }
}

/// What the command bar's Claude said, and the commands it was refused.
public struct CommandBarAnswer: Equatable, Sendable {
    public var reply: String
    public var refused: [String]

    public init(reply: String, refused: [String]) {
        self.reply = reply
        self.refused = refused
    }
}
