import Foundation

/// Where a card's worktree goes and what its branch is called.
///
/// Worktrees live inside the repo, under `.claude/worktrees` as Claude Code's
/// own `--worktree` puts them, so they share the repo's folder trust.
public enum Worktree {
    public static let directory = ".claude/worktrees"

    public static func name(for cardId: UUID) -> String {
        "reeve-" + cardId.uuidString.prefix(8).lowercased()
    }

    public static func branch(for cardId: UUID) -> String {
        "reeve/" + cardId.uuidString.prefix(8).lowercased()
    }

    public static func path(repo: String, cardId: UUID) -> String {
        URL(fileURLWithPath: repo).appendingPathComponent(directory).appendingPathComponent(name(for: cardId)).path
    }

    /// The repo's main checkout, from `git rev-parse --git-common-dir`: the
    /// folder holding `.git`, so a card started from inside another worktree
    /// still gets its worktree in the main one.
    public static func mainCheckout(commonDir: String, topLevel: String) -> String {
        let common = URL(fileURLWithPath: commonDir)
        return common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : topLevel
    }

    /// The folder to work in inside the worktree: the same place in the tree
    /// the person chose, from `git rev-parse --show-prefix`.
    public static func workingDirectory(worktree: String, prefix: String) -> String {
        let prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/\n"))
        return prefix.isEmpty ? worktree : URL(fileURLWithPath: worktree).appendingPathComponent(prefix).path
    }

    /// The line `.git/info/exclude` needs so the worktrees never show as untracked.
    public static let excludeLine = "/\(directory)/"

    /// `exclude` with `excludeLine` added, or nil when it is already there.
    public static func excluding(_ exclude: String) -> String? {
        let lines = exclude.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { [excludeLine, "\(directory)/", "/\(directory)", directory].contains($0) }) { return nil }
        let base = exclude.isEmpty || exclude.hasSuffix("\n") ? exclude : exclude + "\n"
        return base + excludeLine + "\n"
    }
}
