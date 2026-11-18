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
        /// Where the card works in it: the same subfolder the person chose.
        let cwd: String
        /// The commit it started from.
        let base: String?
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
        return Made(repo: repo, path: path, branch: branch, cwd: Worktree.workingDirectory(worktree: path, prefix: prefix), base: base)
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

    /// Whether a card's branch really landed: its pull request says MERGED,
    /// or it has commits of its own and they are in the repo's checked-out
    /// branch. A branch nobody committed to is in HEAD's history too, which
    /// is why the commits are asked about.
    static func isMerged(branch: String, repo: String, env: ShellEnvironment?) async -> Bool {
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        if let pr = try? await Subprocess.run("/usr/bin/env", ["gh", "pr", "view", branch, "--json", "state", "-q", ".state"], environment: environment, currentDirectory: repo, timeout: 20),
           String(decoding: pr.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "MERGED" {
            return true
        }
        guard let reflog = try? await git(["reflog", "show", "--format=%H", branch], in: repo, env: env),
              reflog.split(separator: "\n").count > 1 else { return false }
        return (try? await git(["merge-base", "--is-ancestor", branch, "HEAD"], in: repo, env: env)) != nil
    }

    /// How many commits the worktree at `path` has made since `base`.
    static func commits(at path: String, since base: String, env: ShellEnvironment?) async -> Int {
        guard let count = try? await git(["rev-list", "--count", "\(base)..HEAD"], in: path, env: env) else { return 0 }
        return Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// How many commits the worktree at `path` has that the repo's checked-out
    /// branch doesn't. A squash merge leaves them out too, so ask the pull
    /// request first.
    static func unmergedCommits(at path: String, repo: String, env: ShellEnvironment?) async -> Int {
        guard let head = try? await git(["rev-parse", "HEAD"], in: repo, env: env).trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty,
              let count = try? await git(["rev-list", "--count", "HEAD", "^\(head)"], in: path, env: env) else { return 0 }
        return Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The branch checked out at `path` now, which Claude may have switched
    /// from the one Reeve made. Nil when HEAD is detached.
    static func currentBranch(at path: String, env: ShellEnvironment?) async -> String? {
        let branch = (try? await git(["symbolic-ref", "--short", "-q", "HEAD"], in: path, env: env))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return branch?.isEmpty == false ? branch : nil
    }

    /// The branches the worktree at `path` has been on, newest first, from
    /// its HEAD reflog. Empty when git can't say.
    static func reflogBranches(at path: String, env: ShellEnvironment?) async -> [String] {
        guard let reflog = try? await git(["reflog", "show", "HEAD", "--format=%gs"], in: path, env: env) else { return [] }
        return PullRequest.checkedOutBranches(reflog: reflog)
    }

    /// Everything a card has changed: its commits since `base` and what isn't
    /// committed yet, new files included. Nil outside a git repo.
    static func changes(in folder: String, base: String?, env: ShellEnvironment?) async throws -> Changes? {
        guard let top = try? await git(["rev-parse", "--show-toplevel"], in: folder, env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty else { return nil }
        // A base git no longer has (a rewritten branch) falls back to HEAD:
        // what isn't committed, at least.
        var against = "HEAD"
        if let base, (try? await git(["rev-parse", "--verify", "--quiet", base + "^{commit}"], in: top, env: env)) != nil {
            against = base
        }
        let pinned = ["-c", "core.quotePath=false", "diff"] + DiffParser.arguments
        var text = try await git(pinned + [against, "--"], in: top, env: env)
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"], in: top, env: env)
            .split(separator: "\0").map(String.init)
        // A folder nobody ignored (a build, node_modules) shouldn't mean a
        // process per file.
        var leftOut = max(0, untracked.count - Changes.untrackedLimit)
        for file in untracked.prefix(Changes.untrackedLimit) {
            // A stray log or dump would be read whole before the cap below.
            let size = (try? FileManager.default.attributesOfItem(atPath: top + "/" + file)[.size] as? Int) ?? 0
            if size > Changes.untrackedByteLimit || text.utf8.count > Changes.byteLimit {
                leftOut += 1
                continue
            }
            // `--no-index` exits 1 when there is a difference, which there
            // always is. A nested repo, listed as its folder, it refuses.
            if let diff = try? await git(pinned + ["--no-index", "--", "/dev/null", file], in: top, env: env, allowing: [1]) {
                text += diff
            }
        }
        var truncated = false
        if text.utf8.count > Changes.byteLimit {
            text = String(decoding: text.utf8.prefix(Changes.byteLimit), as: UTF8.self)
            if let end = text.lastIndex(of: "\n") { text = String(text[...end]) }
            truncated = true
        }
        return Changes(
            files: DiffParser.parse(text),
            base: against == "HEAD" ? nil : String(against.prefix(7)),
            untrackedLeftOut: leftOut,
            truncated: truncated
        )
    }

    struct Changes {
        static let untrackedLimit = 100
        static let byteLimit = 4_000_000
        static let untrackedByteLimit = 1_000_000

        let files: [FileDiff]
        /// The short commit they are shown against; nil when it is HEAD.
        let base: String?
        /// New files not shown: past `untrackedLimit`, too big, or past `byteLimit`.
        let untrackedLeftOut: Int
        /// The diff ran past `byteLimit` and was cut there.
        let truncated: Bool
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

    private static func git(_ args: [String], in directory: String, env: ShellEnvironment?, allowing ok: Set<Int32> = []) async throws -> String {
        // The person's PATH finds their git; launchd's still finds /usr/bin/git.
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        let result = try await Subprocess.run("/usr/bin/env", ["git", "-C", directory] + args, environment: environment, timeout: 60)
        guard result.status == 0 || ok.contains(result.status) else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: err.isEmpty ? "git \(args.first ?? "") exited \(result.status)" : err)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// Finds the pull requests opened from a card's branches, with the person's
/// own `gh` and its login.
enum PullRequests {
    /// Every pull request opened from `branch`, empty when it has none, or nil
    /// when gh couldn't say: not installed, not logged in, or not a GitHub repo.
    static func find(branch: String, in directory: String, env: ShellEnvironment?) async -> [PullRequest]? {
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        guard let result = try? await Subprocess.run(
            "/usr/bin/env", ["gh"] + PullRequest.listArguments(branch: branch),
            environment: environment, currentDirectory: directory, timeout: 15
        ), result.status == 0 else { return nil }
        return try? PullRequest.parseAll(result.stdout)
    }

    /// gh's refusal, in its own words.
    struct Refusal: Error {
        let message: String
    }

    /// Where the pull request at `url` stands now, asked fresh.
    static func view(url: String, in directory: String, env: ShellEnvironment?) async throws -> (state: PullRequest.State, mergeable: PullRequest.Mergeable) {
        try PullRequest.parseView(try await gh(PullRequest.viewArguments(url: url), in: directory, env: env, timeout: 20))
    }

    /// Lands the pull request at `url`, or throws why GitHub wouldn't:
    /// branch protection, a required review, a token without `workflow`.
    static func merge(url: String, in directory: String, env: ShellEnvironment?) async throws {
        _ = try await gh(PullRequest.mergeArguments(url: url), in: directory, env: env, timeout: 90)
    }

    private static func gh(_ args: [String], in directory: String, env: ShellEnvironment?, timeout: TimeInterval) async throws -> Data {
        let environment = (env?.baseEnvironment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("GIT_") }
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run("/usr/bin/env", ["gh"] + args, environment: environment, currentDirectory: directory, timeout: timeout)
        } catch is Subprocess.Timeout {
            throw Refusal(message: "gh \(args.prefix(2).joined(separator: " ")) took longer than \(Int(timeout))s")
        }
        guard result.status == 0 else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let out = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let said = err.isEmpty ? out : err
            throw Refusal(message: result.status == 127 ? "gh isn't installed, or isn't on the app's PATH"
                          : said.isEmpty ? "gh \(args.prefix(2).joined(separator: " ")) exited \(result.status)" : said)
        }
        return result.stdout
    }
}
