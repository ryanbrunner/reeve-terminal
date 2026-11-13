import Foundation

/// One file's changes, from `git diff`.
public struct FileDiff: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable {
        case added, deleted, modified, renamed
    }

    /// Nil when the file is new.
    public var oldPath: String?
    /// Nil when the file was deleted.
    public var newPath: String?
    public var status: Status = .modified
    public var isBinary = false
    /// Only the mode changed: `old mode` and `new mode` and no hunks.
    public var modeChange: String?
    public var hunks: [DiffHunk] = []

    public var id: String { (oldPath ?? "") + "\u{0}" + (newPath ?? "") }
    public var path: String { newPath ?? oldPath ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

public struct DiffHunk: Equatable, Sendable {
    /// The `@@ -a,b +c,d @@` line, as git wrote it.
    public var header: String
    public var lines: [DiffLine] = []
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable {
        case context, added, removed
        /// `\ No newline at end of file`.
        case note
    }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
}

/// Reads `git diff` output. Expects the prefixes `a/` and `b/` and no colour,
/// which `arguments` asks git for whatever the person's config says.
public enum DiffParser {
    /// Flags that pin `git diff`'s output to what `parse` reads.
    public static let arguments = ["--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]

    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0, oldLeft = 0, newLeft = 0

        func closeHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let f = file { files.append(f) }
            file = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // Inside a hunk, its counts say how many lines are its own, so a
            // removed line that reads "--- x" is never taken for a header.
            if hunk != nil, oldLeft > 0 || newLeft > 0 {
                if line.hasPrefix("+") {
                    hunk?.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                    newLine += 1; newLeft -= 1
                    continue
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine))
                    oldLine += 1; oldLeft -= 1
                    continue
                } else if line.hasPrefix(" ") || line.isEmpty {
                    hunk?.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                    continue
                }
            }
            if line.hasPrefix("\\") {
                hunk?.lines.append(DiffLine(kind: .note, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("diff --git ") {
                closeFile()
                var f = FileDiff()
                if let (a, b) = headerPaths(String(line.dropFirst("diff --git ".count))) {
                    f.oldPath = a
                    f.newPath = b
                }
                file = f
            } else if file == nil {
                continue
            } else if line.hasPrefix("@@") {
                closeHunk()
                let (o, oc, n, nc) = hunkRange(line)
                oldLine = o; newLine = n; oldLeft = oc; newLeft = nc
                hunk = DiffHunk(header: line)
            } else if line.hasPrefix("new file mode") {
                file?.status = .added
                file?.oldPath = nil
            } else if line.hasPrefix("deleted file mode") {
                file?.status = .deleted
                file?.newPath = nil
            } else if line.hasPrefix("old mode ") {
                file?.modeChange = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode "), let old = file?.modeChange {
                file?.modeChange = "\(old) → \(line.dropFirst("new mode ".count))"
            } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                file?.status = .renamed
                file?.oldPath = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
            } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                file?.status = .renamed
                file?.newPath = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst()))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file?.isBinary = true
            } else if line.hasPrefix("--- ") {
                let path = filePath(line)
                if path != "/dev/null" { file?.oldPath = stripPrefix(unquote(path), "a/") }
            } else if line.hasPrefix("+++ ") {
                let path = filePath(line)
                if path != "/dev/null" { file?.newPath = stripPrefix(unquote(path), "b/") }
            }
        }
        closeFile()
        return files
    }

    /// The path on a `---` or `+++` line. Git ends one with a space in it with a tab.
    private static func filePath(_ line: String) -> String {
        var path = line.dropFirst(4)
        if path.hasSuffix("\t") { path = path.dropLast() }
        return String(path)
    }

    /// `-a,b +c,d`; a count left out is 1.
    private static func hunkRange(_ header: String) -> (Int, Int, Int, Int) {
        let parts = header.split(separator: " ")
        func range(_ s: Substring?) -> (Int, Int) {
            guard let s else { return (0, 0) }
            let nums = s.dropFirst().split(separator: ",").map { Int($0) ?? 0 }
            return (nums.first ?? 0, nums.count > 1 ? nums[1] : 1)
        }
        let old = range(parts.first { $0.hasPrefix("-") })
        let new = range(parts.first { $0.hasPrefix("+") })
        return (old.0, old.1, new.0, new.1)
    }

    /// The two paths in `a/x b/x`. Only certain when they are the same file,
    /// as they are unless the file was renamed, which says so on its own lines.
    private static func headerPaths(_ rest: String) -> (String, String)? {
        if rest.hasPrefix("\"") {
            let parts = rest.components(separatedBy: "\" \"")
            guard parts.count == 2 else { return nil }
            return (stripPrefix(unquote(parts[0] + "\""), "a/"), stripPrefix(unquote("\"" + parts[1]), "b/"))
        }
        // `a/<p> b/<p>`: both halves are the same length.
        let chars = Array(rest)
        guard chars.count % 2 == 1 else { return nil }
        let half = (chars.count - 1) / 2
        let a = String(chars[..<half]), b = String(chars[(half + 1)...])
        guard a.hasPrefix("a/"), b.hasPrefix("b/") else { return nil }
        return (String(a.dropFirst(2)), String(b.dropFirst(2)))
    }

    private static func stripPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Git quotes a path with a tab, newline, quote or backslash in it.
    private static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var out = ""
        var escaping = false
        for c in path.dropFirst().dropLast() {
            if escaping {
                switch c {
                case "t": out.append("\t")
                case "n": out.append("\n")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}
