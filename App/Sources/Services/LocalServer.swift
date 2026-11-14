import Foundation
import Network
import ReeveKit

/// A tiny HTTP server on 127.0.0.1, for the cards' Claude Code hooks, their
/// `gloss open`, and `reeve`, the command line.
///
/// Each hook runs `curl --data-binary @- http://127.0.0.1:<port>/hook/<card>`
/// with its payload on stdin. It is answered at once, and the card id, body
/// and answer go to `onEvent` on the main queue.
///
/// The answer is the hook's output. It is empty (204) unless the card is in
/// VIBES MODE and Claude is asking something VIBES MODE answers; then it is the
/// JSON that answers it. Decided here, on the server's own queue, from
/// `vibesCards`: a hook waits on this reply, and the main thread may be busy.
///
/// A card's `gloss open` posts to `/gloss/<card>` (its `GLOSS_HOST`) to have
/// the page shown in the card's Preview tab. That one waits for `onGloss` to
/// answer, once the session is up, since `gloss open` reports it right after.
///
/// `/api/` requests go to `onRequest` on the main actor, and their answer is
/// sent back when it is ready. They must carry the token from `server.json`,
/// which only the person can read, and no `Origin`: a web page can reach
/// 127.0.0.1 too, and a card started with its prompt would run it.
final class LocalServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "reeve.server")
    let token = ServerInfo.newToken()
    private(set) var port: UInt16?
    var onReady: ((UInt16) -> Void)?
    var onEvent: ((_ cardId: UUID, _ body: Data, _ reply: VibesReply?) -> Void)?
    /// The cards VIBES MODE answers for. The board keeps it up to date.
    let vibesCards = LockedSet()
    /// Answers with an error to say why not, or nil once the session is up.
    var onGloss: ((_ cardId: UUID, _ body: Data, _ respond: @escaping (_ error: String?) -> Void) -> Void)?
    var onRequest: (@MainActor (HTTPRequest) async -> HTTPResponse)?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port?.rawValue else { return }
            DispatchQueue.main.async {
                self.port = port
                self.onReady?(port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data(), continued: false)
    }

    private func read(_ connection: NWConnection, buffer: Data, continued: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 16 << 20 {
                connection.cancel()
                return
            }
            guard let request = HTTPRequest(buffer) else {
                if complete { connection.cancel() } else { self.read(connection, buffer: buffer, continued: continued) }
                return
            }
            // curl holds a large body back until it hears this.
            if !continued, request.expectsContinue, request.body.count < request.contentLength {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.read(connection, buffer: buffer, continued: true)
                return
            }
            if request.body.count < request.contentLength && !complete {
                self.read(connection, buffer: buffer, continued: continued)
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        if request.method == "POST", request.path.hasPrefix("/hook/") {
            let id = UUID(uuidString: String(request.path.dropFirst("/hook/".count)))
            let body = request.body
            let reply = id.flatMap { id in
                self.vibesCards.contains(id) ? (try? HookEvent.decode(body)).flatMap(Vibes.reply(to:)) : nil
            }
            send(reply.map { HTTPResponse(status: 200, body: $0.json) } ?? HTTPResponse(status: 204), on: connection)
            if let id {
                DispatchQueue.main.async { self.onEvent?(id, body, reply) }
            }
            return
        }
        if request.method == "POST", request.path.hasPrefix("/gloss/") {
            answerGloss(connection, request)
            return
        }
        guard request.path.hasPrefix("/api/") else {
            send(.error(404, APIError("not found", detail: "\(request.method) \(request.path)")), on: connection)
            return
        }
        guard request.headers["origin"] == nil else {
            send(.error(403, APIError("refused", detail: "requests from web pages aren't accepted")), on: connection)
            return
        }
        guard let given = request.headers["authorization"], Self.same(given, "Bearer \(token)") else {
            send(.error(401, APIError("unauthorized", detail: "the token in server.json is needed")), on: connection)
            return
        }
        guard let onRequest else {
            send(.error(503, APIError("not ready")), on: connection)
            return
        }
        Task { @MainActor in
            let response = await onRequest(request)
            self.send(response, on: connection)
        }
    }

    private func answerGloss(_ connection: NWConnection, _ request: HTTPRequest) {
        let queue = queue
        let respond: (String?) -> Void = { error in
            let body = Data((error ?? "").utf8)
            let status = error == nil ? "200 OK" : "409 Conflict"
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            queue.async { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
        }
        guard let id = UUID(uuidString: String(request.path.dropFirst("/gloss/".count))) else {
            respond("no such card")
            return
        }
        let body = request.body
        DispatchQueue.main.async {
            guard let onGloss = self.onGloss else { return respond("Reeve has no preview to show it in") }
            // Answered once, however the preview gets there.
            var answered = false
            onGloss(id, body) { error in
                guard !answered else { return }
                answered = true
                respond(error)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Compares every byte, so how long a wrong token took doesn't say how much of it was right.
    private static func same(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Just enough HTTP/1.1 request parsing for the hooks and the API: nil until
/// the headers have all arrived.
struct HTTPRequest {
    let method: String
    /// Without the query.
    let path: String
    let query: [String: String]
    /// Lower-cased names.
    let headers: [String: String]
    let contentLength: Int
    let expectsContinue: Bool
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])
        let target = URLComponents(string: String(requestLine[1]))
        path = target?.percentEncodedPath ?? String(requestLine[1])
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        self.query = query
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1]
        }
        self.headers = headers
        contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        expectsContinue = headers["expect"]?.lowercased() == "100-continue"
        body = data[end.upperBound...].prefix(contentLength)
    }
}

struct HTTPResponse {
    var status: Int
    var body = Data()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            return HTTPResponse(status: status, body: try API.encoder().encode(value) + Data("\n".utf8))
        } catch {
            return .error(500, APIError("couldn't encode the answer", detail: error.localizedDescription))
        }
    }

    static func error(_ status: Int, _ error: APIError) -> HTTPResponse {
        let body = (try? API.encoder().encode(error)) ?? Data()
        return HTTPResponse(status: status, body: body + Data("\n".utf8))
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// A set of card ids the main thread writes and the hook queue reads.
final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func set(_ ids: Set<UUID>) { lock.withLock { self.ids = ids } }
    func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
}
