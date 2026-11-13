import Foundation
import ReeveKit

/// Each card's own git worktree: made when the card starts, removed with it,
/// so cards working on one repo never trip over each other's changes.
enum Worktrees {
    /// A worktree made for a card.
    struct Made {
        let repo: String
        let path: String
        let branch: String
        /// The commit the branch starts from.
        let baseCommit: String?
        /// Where the card works in it: the same subfolder the person chose.
        let cwd: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Makes the card a worktree on a new branch from the folder's HEAD. Nil
    /// when the folder isn't in a git repo, so the card works in it directly.
    static func make(for cardId: UUID, in folder: String, env: ShellEnvironment?) async throws -> Made? {
        let info = try? await git(["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel", "--show-prefix"], in: folder, env: env)
        let lines = (info ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        let commonDir = lines[0], topLevel = lines[1], prefix = lines.count > 2 ? lines[2] : ""
        let repo = Worktree.mainCheckout(commonDir: commonDir, topLevel: topLevel)
        let path = Worktree.path(repo: repo, cardId: cardId)
        let branch = Worktree.branch(for: cardId)
        exclude(commonDir: commonDir)
        _ = try await git(["worktree", "add", "-b", branch, path, "HEAD"], in: folder, env: env)
        let base = try? await git(["rev-parse", "HEAD"], in: path, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        return Made(repo: repo, path: path, branch: branch, baseCommit: base, cwd: Worktree.workingDirectory(worktree: path, prefix: prefix))
    }

    /// Removes a card's worktree, uncommitted changes and all. Its branch goes
    /// too unless it has commits nothing else has, which stay safe in the repo.
    /// False when the worktree is still there.
    static func remove(path: String, branch: String?, repo: String, env: ShellEnvironment?) async -> Bool {
        do {
            _ = try await git(["worktree", "remove", "--force", path], in: repo, env: env)
        } catch {
            NSLog("Reeve: removing worktree \(path) failed: \(error.localizedDescription)")
            // Gone already, or git couldn't; either way forget it.
            try? FileManager.default.removeItem(atPath: path)
            _ = try? await git(["worktree", "prune"], in: repo, env: env)
        }
        if let branch {
            _ = try? await git(["branch", "-d", branch], in: repo, env: env)
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// How many files in the worktree have changes that aren't committed.
    static func uncommittedChanges(at path: String, env: ShellEnvironment?) async -> Int {
        guard let status = try? await git(["status", "--porcelain"], in: path, env: env) else { return 0 }
        return status.split(separator: "\n").count
    }

    /// How many commits the worktree at `path` has made since `base`.
    static func commits(at path: String, since base: String, env: ShellEnvironment?) async -> Int {
        guard let count = try? await git(["rev-list", "--count", "\(base)..HEAD"], in: path, env: env) else { return 0 }
        return Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The pull request for the branch checked out at `path`, from `gh`. Nil
    /// when the branch has none; throws when `gh` couldn't say (not installed,
    /// not logged in, offline, not a GitHub repo), so what's known isn't lost.
    static func pullRequest(at path: String, env: ShellEnvironment?) async throws -> PullRequestState? {
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        let result = try await Subprocess.run("/usr/bin/env", ["gh", "pr", "view", "--json", "state", "--jq", ".state"], environment: environment, currentDirectory: path, timeout: 20)
        let out = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            let err = String(decoding: result.stderr, as: UTF8.self)
            if err.contains("no pull requests found") { return nil }
            throw Failure(message: err.isEmpty ? "gh pr view exited \(result.status)" : err)
        }
        return PullRequestState(rawValue: out)
    }

    /// Keeps the worktrees out of `git status` in the repo, without touching
    /// its `.gitignore`.
    private static func exclude(commonDir: String) {
        let url = URL(fileURLWithPath: commonDir).appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let updated = Worktree.excluding(current) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func git(_ args: [String], in directory: String, env: ShellEnvironment?) async throws -> String {
        // The person's PATH finds their git; launchd's still finds /usr/bin/git.
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        let result = try await Subprocess.run("/usr/bin/env", ["git", "-C", directory] + args, environment: environment, timeout: 60)
        guard result.status == 0 else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: err.isEmpty ? "git \(args.first ?? "") exited \(result.status)" : err)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
