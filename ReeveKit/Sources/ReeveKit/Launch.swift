import Foundation

/// How a card's terminal starts Claude Code.
public enum Launch {
    /// The events whose hooks report back to Reeve.
    public static let hookedEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    /// Settings layered over the person's own with `--settings`: one hook per
    /// event, posting its payload to Reeve. The port and card come from the
    /// environment, so the settings never change and a resumed session posts
    /// to whichever Reeve started it. The card rides in the URL rather than
    /// being looked up by session, because `/clear` starts a new session in
    /// the same terminal. `-m 1` and `|| true` keep a Reeve that has gone away
    /// from holding Claude up or showing it an error.
    public static func hookSettings() -> String {
        let hook: [String: Any] = [
            "type": "command",
            "command": "[ -n \"$REEVE_HOOK_PORT\" ] && curl -s -m 1 --data-binary @- \"http://127.0.0.1:$REEVE_HOOK_PORT/hook/$REEVE_CARD_ID\" >/dev/null 2>&1 || true",
        ]
        var hooks: [String: Any] = [:]
        for event in hookedEvents {
            var matcher: [String: Any] = ["hooks": [hook]]
            if event == "PreToolUse" || event == "PostToolUse" { matcher["matcher"] = "*" }
            hooks[event] = [matcher]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The models a card can be started on, as `--model` aliases.
    public static let models = ["fable", "opus", "sonnet", "haiku"]
    /// The effort levels a card can be started at, as `--effort` takes them.
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// `claude`'s arguments for a card: a new session under the card's id, in
    /// the mode the card was started in, or the card's session picked up again.
    /// The card's model and effort come along on a resume too, so a card woken
    /// after a restart keeps them. A prompt is the session's next message,
    /// whether it is new or resumed.
    public static func claudeArguments(for card: Card, prompt: String? = nil) -> [String] {
        var args = card.hasConversation
            ? ["--resume", card.sessionId.uuidString.lowercased()]
            : ["--session-id", card.sessionId.uuidString.lowercased()]
        args += ["--settings", hookSettings()]
        if let model = card.model { args += ["--model", model] }
        if let effort = card.effort { args += ["--effort", effort] }
        // Only a fresh session: a resumed one is wherever the person left it,
        // and plan mode again would undo an approved plan.
        if let mode = card.startMode, !card.hasConversation {
            args += ["--permission-mode", mode.permissionMode]
        }
        if let prompt, !prompt.isEmpty {
            args.append(prompt)
        }
        return args
    }

    /// A shell command line that runs `executable` with `args`, each quoted.
    public static func commandLine(_ executable: String, _ args: [String]) -> String {
        ([executable] + args).map(shellQuote).joined(separator: " ")
    }

    /// What a card's login shell runs: `claude`, with `cliDirectory` (where the
    /// app keeps `reeve`) put first on PATH. Done here rather than in the
    /// environment, so the person's profile, which runs first, can't put
    /// another `reeve` ahead of it.
    public static func shellCommand(_ claude: String, _ args: [String], cliDirectory: String?) -> String {
        let exec = "exec " + commandLine(claude, args)
        guard let cliDirectory else { return exec }
        return "export PATH=\(shellQuote(cliDirectory)):\"$PATH\"; " + exec
    }

    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment a card's shell starts with: Reeve's own, minus what
    /// would make `claude` think it is running inside another Claude Code
    /// session, plus what the hooks need.
    public static func environment(base: [String: String], hookPort: UInt16, cardId: UUID) -> [String: String] {
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Reeve"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["REEVE_HOOK_PORT"] = String(hookPort)
        env["REEVE_CARD_ID"] = cardId.uuidString
        return env
    }
}
