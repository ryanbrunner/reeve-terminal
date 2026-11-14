import Foundation
import ReeveKit

/// A refusal or failure to report: the message goes to stderr, prefixed
/// `reeve:`, and the process exits with `code`.
struct CLIError: Error {
    var message: String
    var code: ExitCode = .error

    init(_ message: String, code: ExitCode = .error) {
        self.message = message
        self.code = code
    }
}

/// Talks to the running app over its loopback API.
///
/// The app is found through `server.json` in its data directory, which also
/// holds the token every request carries. `REEVE_URL` and `REEVE_PORT` are
/// left alone: they are reeve-board's.
struct Client {
    let info: ServerInfo
    private let base: URL
    private let session: URLSession

    static let notRunning = "Reeve Terminal isn't running — start it with `reeve open`"

    /// The app, when it is running.
    static func connect(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Client {
        let dir = DataDirectory.url(environment: environment)
        guard let info = ServerInfo.read(dataDir: dir) else { throw CLIError(notRunning) }
        // Left behind by an app that crashed.
        guard kill(info.pid, 0) == 0 || errno == EPERM else { throw CLIError(notRunning) }
        return Client(info: info)
    }

    init(info: ServerInfo) {
        self.info = info
        base = URL(string: "http://127.0.0.1:\(info.port)")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try await call("GET", path, body: Optional<String>.none)
    }

    func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?, as type: T.Type = T.self) async throws -> T {
        let data = try await raw(method, path, body: body)
        do {
            return try API.decoder().decode(T.self, from: data)
        } catch {
            throw CLIError("\(base) didn't answer as Reeve Terminal does: \(error)")
        }
    }

    /// For answers with no body.
    func send<B: Encodable>(_ method: String, _ path: String, body: B?) async throws {
        _ = try await raw(method, path, body: body)
    }

    private func raw<B: Encodable>(_ method: String, _ path: String, body: B?) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try API.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw CLIError(Self.notRunning)
        } catch {
            throw CLIError("couldn't reach Reeve Terminal at \(base): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let refusal = try? API.decoder().decode(APIError.self, from: data) {
                throw CLIError(refusal.detail.map { "\(refusal.error) — \($0)" } ?? refusal.error)
            }
            throw CLIError("Reeve Terminal answered \(status)")
        }
        return data
    }

    // MARK: The board

    func board() async throws -> BoardResponse {
        try await get("/api/board")
    }

    /// The card a person named, or the one this shell is in when they didn't.
    func card(_ ref: String?) async throws -> APICard {
        let board = try await board()
        let cards = board.cards.map(\.card)
        do {
            let card = try CardRef.resolve(ref, in: cards, cwd: FileManager.default.currentDirectoryPath,
                                           environment: ProcessInfo.processInfo.environment, realpath: realpath)
            return board.cards.first { $0.card.id == card.id }!
        } catch let failure as CardRef.Failure {
            switch failure {
            case .notFound(let ref):
                throw CLIError("no card matches “\(ref)” — see `reeve board`")
            case .ambiguous(let ref, let ids):
                let lines = board.cards.filter { ids.contains($0.card.id) }
                    .map { "  \(CardRef.short($0.card.id))  \($0.displayTitle)" }
                throw CLIError("“\(ref)” matches \(ids.count) cards; say which:\n" + lines.joined(separator: "\n"))
            case .noDefault:
                throw CLIError("which card? Name one, or run this in a card's terminal or worktree", code: .usage)
            }
        }
    }
}

/// The path with every symlink resolved, so `/tmp` and `/private/tmp` agree.
func realpath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
