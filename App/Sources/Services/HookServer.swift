import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that the cards' Claude Code hooks post to.
///
/// Each hook runs `curl --data-binary @- http://127.0.0.1:<port>/hook/<card>`
/// with its payload on stdin, so all this has to understand is one POST with a
/// Content-Length. It answers 204 and closes, and hands the card id and body
/// to `onEvent` on the main queue.
final class HookServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "reeve.hooks")
    private(set) var port: UInt16?
    var onReady: ((UInt16) -> Void)?
    var onEvent: ((_ cardId: UUID, _ body: Data) -> Void)?

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
            let ok = request.method == "POST" && request.path.hasPrefix("/hook/")
            let response = ok ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if ok, let id = UUID(uuidString: String(request.path.dropFirst("/hook/".count))) {
                let body = request.body
                DispatchQueue.main.async { self.onEvent?(id, body) }
            }
        }
    }
}

/// Just enough HTTP/1.1 request parsing for the hooks: nil until the headers
/// have all arrived.
private struct HTTPRequest {
    let method: String
    let path: String
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
        path = String(requestLine[1])
        var length = 0
        var expects = false
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": length = Int(parts[1]) ?? 0
            case "expect": expects = parts[1].lowercased() == "100-continue"
            default: break
            }
        }
        contentLength = length
        expectsContinue = expects
        body = data[end.upperBound...].prefix(length)
    }
}
