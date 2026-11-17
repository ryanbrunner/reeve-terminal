import Foundation
import ReeveKit

/// Where `claude` and `gloss` are, and the PATH a person's own terminal would have.
///
/// An app opened from the Finder gets launchd's bare environment, not the one
/// a person's shell builds, so both are read once from a login, interactive
/// shell — the same kind of shell a terminal window starts.
struct ShellEnvironment: Sendable {
    let shell: String
    let claudePath: String?
    /// Gloss, for the Preview tab. Nil when it isn't installed.
    let glossPath: String?
    let path: String?

    static func load() async -> ShellEnvironment {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__REEVE_ENV__"
        let script = "printf '\\n\(marker)\\n'; command -v claude; command -v gloss; printf '%s\\n' \"$PATH\""
        let output = await run(shell, ["-l", "-i", "-c", script], timeout: 15)
        var claude: String?
        var gloss: String?
        var path: String?
        if let output, let range = output.range(of: marker + "\n") {
            let lines = output[range.upperBound...].split(separator: "\n").map(String.init)
            claude = lines.first(where: { $0.hasPrefix("/") && $0.hasSuffix("/claude") })
            gloss = lines.first(where: { $0.hasPrefix("/") && $0.hasSuffix("/gloss") })
            path = lines.last(where: { $0.contains(":") })
        }
        // A gloss of your own choosing, such as a checkout's bin/gloss.js.
        if let chosen = ProcessInfo.processInfo.environment["REEVE_GLOSS"], !chosen.isEmpty {
            gloss = chosen
        }
        if claude == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            claude = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return ShellEnvironment(shell: shell, claudePath: claude, glossPath: gloss, path: path)
    }

    /// Reeve's environment with the person's PATH, for the processes it starts.
    var baseEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path { env["PATH"] = path }
        return env
    }

    private static func run(_ executable: String, _ args: [String], timeout: TimeInterval) async -> String? {
        let result = try? await Subprocess.run(executable, args, environment: ProcessInfo.processInfo.environment, timeout: timeout)
        return result.map { String(decoding: $0.stdout, as: UTF8.self) }
    }
}

/// Asks Claude where a card is, from its session's transcript.
enum StageClassifier {
    static func classify(card: Card, transcriptPath: String, lastMessage: String?, env: ShellEnvironment) async throws -> Classification {
        guard let claude = env.claudePath else { throw ClassifierError.failed("Couldn't find claude on your PATH") }
        var digest = TranscriptDigest.digest(fileAt: transcriptPath) ?? ""
        // The Stop hook can beat the transcript's last line to disk.
        if let lastMessage, !lastMessage.isEmpty {
            let line = "CLAUDE: " + lastMessage.prefix(1_500)
            if !digest.hasSuffix(line) { digest += "\n" + line }
        }
        guard !digest.isEmpty else { throw ClassifierError.failed("The session has no transcript yet") }
        let result = try await Subprocess.run(
            claude,
            Classifier.arguments(prompt: Classifier.prompt(for: card)),
            environment: Launch.environment(base: env.baseEnvironment, hookPort: 0, cardId: card.id)
                .filter { $0.key != "REEVE_HOOK_PORT" && $0.key != "REEVE_CARD_ID" && $0.key != "GLOSS_HOST" },
            // Out of the project, so no CLAUDE.md or project settings come with it.
            currentDirectory: FileManager.default.temporaryDirectory.path,
            stdin: Data(digest.utf8),
            timeout: 120
        )
        if result.status != 0, result.stdout.isEmpty {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClassifierError.failed(err.isEmpty ? "claude -p exited \(result.status)" : err)
        }
        return try Classifier.parse(result.stdout)
    }
}

/// Asks Claude what a repo should build next, from inside it. See `Ideas`.
enum IdeaGenerator {
    static func think(prompt: String, in directory: String, env: ShellEnvironment) async throws -> [Ideas.Idea] {
        guard let claude = env.claudePath else { throw ClassifierError.failed("Couldn't find claude on your PATH") }
        // No card's hook port or id: its hooks would report on a real card.
        let environment = Launch.environment(base: env.baseEnvironment, hookPort: 0, cardId: UUID())
            .filter { $0.key != "REEVE_HOOK_PORT" && $0.key != "REEVE_CARD_ID" && $0.key != "GLOSS_HOST" }
        let result = try await Subprocess.run(
            claude,
            Ideas.arguments(prompt: prompt),
            environment: environment,
            currentDirectory: directory,
            // Reading a repo takes a while; this is a ceiling, not a guess.
            timeout: 600
        )
        if result.status != 0, result.stdout.isEmpty {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClassifierError.failed(err.isEmpty ? "claude -p exited \(result.status)" : err)
        }
        return try Ideas.parse(result.stdout)
    }
}

/// Runs a process to completion off the main thread.
enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    struct Timeout: Error {}

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    static func run(
        _ executable: String,
        _ args: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.environment = environment
                if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
                let out = Pipe(), err = Pipe(), input = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timedOut = Flag()
                let timer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Read both pipes while the process runs, so neither fills and stalls it.
                var stdoutData = Data(), stderrData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { stdoutData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderrData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if let stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                group.wait()
                timer.cancel()
                if timedOut.isSet {
                    continuation.resume(throwing: Timeout())
                    return
                }
                continuation.resume(returning: Result(status: process.terminationStatus, stdout: stdoutData, stderr: stderrData))
            }
        }
    }
}
