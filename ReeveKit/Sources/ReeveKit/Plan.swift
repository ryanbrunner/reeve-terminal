import Foundation

/// A sign of the session's plan: its text, the file Claude Code keeps it in,
/// or both. `ExitPlanMode` carries both; a draft written in plan mode only
/// says where the file is.
public struct PlanSighting: Equatable, Sendable {
    public var text: String?
    public var path: String?

    public init(text: String?, path: String?) {
        self.text = text.flatMap { $0.isEmpty ? nil : $0 }
        self.path = path.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// This sighting, keeping what `earlier` knew about the same plan: a later
    /// draft of the same file shouldn't forget the text an approval carried.
    public func merged(over earlier: PlanSighting?) -> PlanSighting {
        guard let earlier, text == nil, path == nil || path == earlier.path else { return self }
        return PlanSighting(text: earlier.text, path: path ?? earlier.path)
    }

    /// Plan mode keeps its plans as Markdown in `.claude/plans`. Only that
    /// folder counts, so a repo's own `docs/plans` is never taken for one; a
    /// plan kept elsewhere still arrives with `ExitPlanMode`.
    public static func isPlanFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        return url.pathExtension.lowercased() == "md" && folder.lastPathComponent == "plans"
            && folder.deletingLastPathComponent().lastPathComponent == ".claude"
    }

    /// The session's latest plan, from its `.jsonl` transcript: what a card
    /// that missed the hook, or was made before Reeve kept plans, still has.
    public static func latest(inTranscript jsonl: String) -> PlanSighting? {
        var found: PlanSighting?
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            // Most lines are neither; skip them before parsing any JSON.
            guard raw.contains("ExitPlanMode") || raw.contains("/.claude/plans/") else { continue }
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  entry["isSidechain"] as? Bool != true,
                  let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "ExitPlanMode":
                    found = PlanSighting(text: input["plan"] as? String, path: input["planFilePath"] as? String).merged(over: found)
                case "Write", "Edit":
                    if let path = input["file_path"] as? String, isPlanFile(path) {
                        found = PlanSighting(text: nil, path: path).merged(over: found)
                    }
                default:
                    break
                }
            }
        }
        return found
    }

    public static func latest(inTranscriptAt path: String) -> PlanSighting? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return latest(inTranscript: String(decoding: data, as: UTF8.self))
    }
}
