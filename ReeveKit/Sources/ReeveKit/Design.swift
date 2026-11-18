import Foundation

/// Something `/design` made: a Claude Design project, or a claude.ai artifact,
/// by its link. The card keeps these so its Design tab can open them.
public struct DesignArtifact: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    /// What it's called, once something has said. Nil shows its id.
    public var title: String?
    /// When the session last shared it.
    public var at: Date

    public var id: String { url }

    public init(url: String, title: String? = nil, at: Date = Date()) {
        self.url = url
        self.title = title
        self.at = at
    }

    /// The last part of the link: the project's or artifact's id.
    public var shortName: String {
        URL(string: url)?.lastPathComponent ?? url
    }
}

/// Signs of the session's designs, read from what Claude Code's tools return
/// and what Claude says. `/design` makes a Claude Design project and shares its
/// link; Reeve doesn't depend on the shape of the tool's response, only on the
/// links in it.
public enum DesignSighting {
    /// The Claude Design project and claude.ai artifact links in `text`, in
    /// order, each once.
    public static func links(in text: String) -> [String] {
        let pattern = #"https://claude\.ai/(?:design/p|code/artifact|artifact)/[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen: Set<String> = []
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            let link = String(text[r])
            return seen.insert(link).inserted ? link : nil
        }
    }

    /// `new` over `old`: one entry a link, the most recently shared first. A
    /// link seen again keeps the title it had, if it still has none.
    public static func merged(_ new: [DesignArtifact], over old: [DesignArtifact]?) -> [DesignArtifact] {
        var byURL: [String: DesignArtifact] = [:]
        for design in old ?? [] { byURL[design.url] = design }
        for design in new {
            var next = design
            if next.title == nil { next.title = byURL[design.url]?.title }
            if let earlier = byURL[design.url], earlier.at > next.at { next.at = earlier.at }
            byURL[design.url] = next
        }
        return byURL.values.sorted { $0.at != $1.at ? $0.at > $1.at : $0.url < $1.url }
    }

    /// A design card's session writing `path` has started building: a file
    /// inside the card's worktree, outside `.claude/` (where plans are kept).
    /// `/design` writes its projects to claude.ai, not to the worktree.
    public static func movesToBuild(path: String, cwd: String) -> Bool {
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let file = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
        guard file.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return false }
        let inside = file.dropFirst(root.count).drop { $0 == "/" }
        return !inside.hasPrefix(".claude/")
    }

    /// Every design link Claude shared in the session's `.jsonl` transcript,
    /// in what the main thread said: what a card that missed the hooks still
    /// has. `/design` shares its project's link; links in files Claude read
    /// are not designs.
    public static func all(inTranscript jsonl: String) -> [String] {
        var found: [String] = []
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            // Most lines have none; skip them before parsing any JSON.
            guard raw.contains("claude.ai") else { continue }
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  entry["isSidechain"] as? Bool != true,
                  let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            for block in blocks where block["type"] as? String == "text" {
                for link in links(in: block["text"] as? String ?? "") where !found.contains(link) {
                    found.append(link)
                }
            }
        }
        return found
    }

    public static func all(inTranscriptAt path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return all(inTranscript: String(decoding: data, as: UTF8.self))
    }
}
