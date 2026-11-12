import Foundation

/// A Claude Code transcript boiled down to what the classifier needs: what the
/// person asked, what Claude said, and which tools it reached for. Tool
/// results, thinking and Claude Code's own bookkeeping lines are left out;
/// they are most of the file and say little about where the work is.
public enum TranscriptDigest {
    /// The digest of a `.jsonl` transcript, keeping its most recent `limit` characters.
    public static func digest(jsonl: String, limit: Int = 12_000) -> String {
        var lines: [String] = []
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any]
            else { continue }
            lines.append(contentsOf: describe(role: type, content: message["content"]))
        }
        var text = lines.joined(separator: "\n")
        if text.count > limit {
            text = "…\n" + String(text.suffix(limit))
        }
        return text
    }

    public static func digest(fileAt path: String, limit: Int = 12_000) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return digest(jsonl: text, limit: limit)
    }

    private static func describe(role: String, content: Any?) -> [String] {
        if let text = content as? String {
            return clean(text).map { ["\(role == "user" ? "USER" : "CLAUDE"): \($0)"] } ?? []
        }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String).flatMap(clean).map { "\(role == "user" ? "USER" : "CLAUDE"): \($0)" }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return "  [\(name)\(toolDetail(block["input"] as? [String: Any]))]"
            default:
                return nil
            }
        }
    }

    /// The one input that says what a tool call was for: the command, the
    /// file, the pattern.
    private static func toolDetail(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "pattern", "description", "url", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return " " + truncate(value.replacingOccurrences(of: "\n", with: " "), 160)
            }
        }
        return ""
    }

    /// Drops Claude Code's own markup — slash command echoes, reminders —
    /// and trims what is left.
    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("<local-command") || trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<system-reminder>") {
            return nil
        }
        return truncate(trimmed, 1_500)
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
    }
}
