import Foundation
import Security

/// Where Reeve keeps the board, and where the app says how to reach it.
public enum DataDirectory {
    /// `REEVE_DATA_DIR`, else `~/Library/Application Support/Reeve Terminal`.
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["REEVE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reeve Terminal", isDirectory: true)
    }

    /// The preferences domain for a Reeve on other data, or nil for the app's
    /// own. A smoke test runs a second Reeve on a `REEVE_DATA_DIR` of its own;
    /// with the app's preferences too it would leave its scratch repo, model
    /// and effort as yours.
    public static func preferencesSuite(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let dir = environment["REEVE_DATA_DIR"], !dir.isEmpty else { return nil }
        return "com.ryanbrunner.reeve-terminal.other-data"
    }
}

/// How the running app is reached: its loopback port and a token that every
/// API request must carry. The app writes it, readable only by its owner, when
/// its server is ready, and removes it when it quits.
public struct ServerInfo: Codable, Equatable, Sendable {
    public var port: UInt16
    public var pid: Int32
    public var token: String

    public init(port: UInt16, pid: Int32, token: String) {
        self.port = port
        self.pid = pid
        self.token = token
    }

    public static func url(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent("server.json")
    }

    public static func read(dataDir: URL) -> ServerInfo? {
        guard let data = try? Data(contentsOf: url(in: dataDir)) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: data)
    }

    /// Made readable only by the person, written in full, then moved into place.
    public func write(dataDir: URL) throws {
        let target = Self.url(in: dataDir)
        let data = try JSONEncoder().encode(self)
        let temp = dataDir.appendingPathComponent(".server.json.\(pid)")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: temp)
        guard rename(temp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Removes the file, but only if it is still this server's.
    public static func remove(dataDir: URL, pid: Int32) {
        guard read(dataDir: dataDir)?.pid == pid else { return }
        try? FileManager.default.removeItem(at: url(in: dataDir))
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
