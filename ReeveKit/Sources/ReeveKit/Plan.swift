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

/// Claude Code's plan dialog, read off the terminal's screen: its options, in
/// order, and the one that is selected.
///
/// The dialog's first options approve the plan, each into a different mode
/// (auto mode, auto-accept edits, manual edits, optionally clearing the
/// context first); the last is "No, keep planning". Only some show, depending
/// on the model and settings, so the option is picked by what it says.
public struct PlanDialog: Equatable, Sendable {
    public var options: [String]
    /// Index into `options`.
    public var selected: Int

    public init(options: [String], selected: Int) {
        self.options = options
        self.selected = selected
    }

    /// The dialog on `lines`, the screen's rows top to bottom: the last list
    /// numbered from a "1. Yes…", with a pointer on the selected option. With
    /// no pointer to be seen, there is no telling where Enter would land, so
    /// there is no dialog to answer.
    public static func find(onScreen lines: [String]) -> PlanDialog? {
        let rows = lines.map(option)
        guard let start = rows.lastIndex(where: { $0?.number == 1 && $0?.label.hasPrefix("Yes") == true }) else { return nil }
        var options: [String] = []
        var selected: Int?
        // Wrapped labels and descriptions sit between options; skip them.
        for row in rows[start...] {
            guard let row else { continue }
            guard row.number == options.count + 1 else { break }
            if row.pointed { selected = options.count }
            options.append(row.label)
        }
        guard options.count >= 2, let selected else { return nil }
        return PlanDialog(options: options, selected: selected)
    }

    /// The option that approves the plan into auto mode, keeping the context.
    /// Without one (a model with no auto mode), the first that approves it
    /// keeping the context and stopping short of bypassing permissions.
    public var approval: Int {
        let keeping = options.indices.filter { options[$0].hasPrefix("Yes") && !options[$0].contains("clear context") }
        return keeping.first { options[$0].contains("auto mode") }
            ?? keeping.first { !options[$0].contains("bypass") }
            ?? 0
    }

    /// The arrow keys that move the selection to `index`, one a keystroke.
    public func moves(to index: Int) -> [String] {
        Array(repeating: index > selected ? "\u{1b}[B" : "\u{1b}[A", count: abs(index - selected))
    }

    /// One row as an option: `❯ 2. Yes, and use auto mode`, perhaps inside the
    /// dialog's box. Claude Code moves the cursor over gaps rather than
    /// writing spaces, so the terminal's cells there are empty: NULs, read as
    /// the blanks they look like.
    private static func option(_ line: String) -> (number: Int, label: String, pointed: Bool)? {
        var text = line.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|")))[...]
        let pointed = text.first.map { "❯›>▸".contains($0) } ?? false
        if pointed { text = text.dropFirst().drop(while: \.isWhitespace) }
        let digits = text.prefix(while: \.isNumber)
        guard let number = Int(digits), text.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        let label = text.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (number, label, pointed)
    }
}
