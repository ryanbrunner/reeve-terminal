import Foundation
import ReeveKit

/// Runs what's typed in the command bar: `claude -p` in the repo new cards
/// start in, with this app's `reeve` first on its PATH. The board changes as
/// `reeve` changes it, through the app's own API, so nothing here touches it.
@MainActor
final class CommandBarRunner: ObservableObject {
    enum State: Equatable {
        case idle
        case running(prompt: String)
        case answered(prompt: String, reply: String, refused: [String])
        case failed(prompt: String, message: String)
    }

    @Published private(set) var state = State.idle
    /// Raised to put the cursor in the bar (⌘K).
    @Published private(set) var focusTick = 0
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func focus() { focusTick += 1 }

    func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    func run(_ text: String, board: Board) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        state = .running(prompt: prompt)
        task = Task { [weak self] in
            let state: State
            do {
                let answer = try await Self.ask(prompt, board: board)
                state = .answered(prompt: prompt, reply: answer.reply.isEmpty ? "Done." : answer.reply, refused: answer.refused)
            } catch is Subprocess.Timeout {
                state = .failed(prompt: prompt, message: "Claude didn't finish within three minutes.")
            } catch {
                state = .failed(prompt: prompt, message: error.localizedDescription)
            }
            self?.state = state
        }
    }

    private static func ask(_ prompt: String, board: Board) async throws -> CommandBarAnswer {
        guard let env = board.environment else { throw ClassifierError.failed("Reeve is still reading your shell's PATH. Try again in a moment.") }
        guard let claude = env.claudePath else { throw ClassifierError.failed("Couldn't find claude on your PATH") }
        guard let cli = Terminals.cliDirectory else { throw ClassifierError.failed("This build of Reeve has no reeve command line to drive the board with") }
        let repos = board.availableRepos.map(\.path)
        let start = board.pickedRepo?.path
        var environment = Launch.environment(base: env.baseEnvironment, hookPort: 0, cardId: UUID())
            .filter { $0.key != "REEVE_HOOK_PORT" && $0.key != "REEVE_CARD_ID" && $0.key != "GLOSS_HOST" }
        // This app's `reeve`, not another of that name, and this app's board.
        environment["PATH"] = cli + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["REEVE_DATA_DIR"] = board.dataDirectory.path
        let result = try await Subprocess.run(
            claude,
            CommandBar.arguments(repos: repos, startRepo: start),
            environment: environment,
            // In the repo new cards start in, so even a `reeve card add`
            // without --cwd lands there rather than in a scratch folder.
            currentDirectory: start ?? FileManager.default.temporaryDirectory.path,
            stdin: Data(prompt.utf8),
            timeout: 180
        )
        if result.status != 0, result.stdout.isEmpty {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClassifierError.failed(err.isEmpty ? "claude -p exited \(result.status)" : err)
        }
        return try CommandBar.parse(result.stdout)
    }
}
