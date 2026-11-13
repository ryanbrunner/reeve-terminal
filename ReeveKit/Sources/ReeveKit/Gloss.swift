import CoreGraphics
import Foundation

/// Reeve's side of a Gloss session it hosts: Gloss keeps the round, the
/// verdict and the API the card's `gloss wait`, `working` and `ready` talk to,
/// and Reeve shows the page, in the card's Preview tab, with Gloss's bar on it.
///
/// The two talk in JSON lines over the stdin and stdout of
/// `gloss __session --host` (Gloss's src/session/host.ts).
public enum Gloss {
    /// What Gloss asks of Reeve.
    public enum Message: Equatable, Sendable {
        /// The bar's script, and the names of the two functions it talks
        /// through in its world: the one it calls with each request, and the
        /// one Reeve calls with each answer.
        case hello(script: String, binding: String, deliver: String)
        /// An answer to the bar, or the round after a change, as JSON to hand it.
        case deliver(json: String)
        case request(id: Int, Request)
        /// The session is up: the card's `gloss` commands can find it.
        case ready
    }

    public enum Request: Equatable, Sendable {
        case navigate(URL)
        case reload
        /// Where the page is scrolled and how big the view is, in CSS pixels.
        case view
        /// A picture of `clip`, in the view's CSS pixels, saved as a PNG at `path`.
        case snapshot(clip: CGRect, path: String)
    }

    /// One line from Gloss, or nil for one that isn't a message Reeve knows.
    public static func parse(_ line: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello":
            guard let script = object["script"] as? String, let binding = object["binding"] as? String,
                  let deliver = object["deliver"] as? String, isIdentifier(binding), isIdentifier(deliver) else { return nil }
            return .hello(script: script, binding: binding, deliver: deliver)
        case "deliver":
            guard let delivery = object["delivery"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: delivery) else { return nil }
            return .deliver(json: String(decoding: data, as: UTF8.self))
        case "ready":
            return .ready
        case "request":
            guard let id = object["id"] as? Int, let method = object["method"] as? String else { return nil }
            switch method {
            case "navigate":
                guard let url = (object["url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return .request(id: id, .navigate(url))
            case "reload":
                return .request(id: id, .reload)
            case "view":
                return .request(id: id, .view)
            case "snapshot":
                guard let clip = object["clip"] as? [String: Any], let path = object["path"] as? String,
                      let x = clip["x"] as? Double, let y = clip["y"] as? Double,
                      let width = clip["width"] as? Double, let height = clip["height"] as? Double else { return nil }
                return .request(id: id, .snapshot(clip: CGRect(x: x, y: y, width: width, height: height), path: path))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// A call from the bar, with where it came from as WebKit saw it.
    public static func rpc(payload: String, url: String, topFrame: Bool) -> Data {
        line(["type": "rpc", "payload": payload, "url": url, "topFrame": topFrame])
    }

    /// The page the preview shows now.
    public static func page(_ url: String) -> Data {
        line(["type": "page", "url": url])
    }

    /// The answer to a request: a result, or why there is none.
    public static func reply(id: Int, result: Any? = nil, error: String? = nil) -> Data {
        var message: [String: Any] = ["type": "reply", "id": id]
        if let error { message["error"] = error } else { message["result"] = result ?? NSNull() }
        return line(message)
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// The names go into script Reeve writes, so only plain ones are taken.
    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" || first == "$" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
    }

    /// `gloss`'s arguments for a session Reeve hosts, in `cwd`, opened on `url`.
    public static func sessionArguments(cwd: String, url: String, live: Bool) -> [String] {
        ["__session", "--host", "--cwd", cwd, "--url", url] + (live ? ["--live"] : [])
    }

    /// What `gloss open` posts to `GLOSS_HOST` to have Reeve host the session.
    public struct OpenRequest: Decodable, Equatable, Sendable {
        public var cwd: String
        public var name: String
        public var url: String
        public var live: Bool

        public init(cwd: String, name: String = "", url: String, live: Bool = false) {
            self.cwd = cwd
            self.name = name
            self.url = url
            self.live = live
        }
    }

    /// `GLOSS_HOST` for a card: where its `gloss open` asks Reeve to show the page.
    public static func hostURL(port: UInt16, cardId: UUID) -> String {
        "http://127.0.0.1:\(port)/gloss/\(cardId.uuidString)"
    }
}
