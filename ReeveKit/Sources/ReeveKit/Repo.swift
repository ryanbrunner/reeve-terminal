import Foundation

/// A folder cards are started in, kept so it can be picked rather than
/// browsed for. For now that is all a repo is.
public struct Repo: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String

    public init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = Repo.normalize(path)
    }

    /// The folder's own name, as the card's repo chip shows it.
    public var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// One spelling per folder: `~/code/app/` and `~/code/app` are one repo.
    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// The first list of repos, from folders cards were started in before
    /// there were repos: one each, in the order given.
    public static func seeded(from paths: [String]) -> [Repo] {
        var seen: Set<String> = []
        return paths.map(normalize).filter { seen.insert($0).inserted }.map { Repo(path: $0) }
    }
}
