import Foundation

/// The changed files as folders and files, for finding one in a long diff.
/// Folders come before files, each in name order, and a folder holding only
/// one folder shares its row: `App/Sources/Views`, not three rows.
public struct FileTree: Equatable, Sendable {
    public struct Node: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case folder([Node])
            /// Where the file is in the list it was built from.
            case file(Int)
        }

        /// The folder's path, or the file's `FileDiff.id`, so both last across reads.
        public var id: String
        /// One or more path components.
        public var name: String
        public var kind: Kind
    }

    public var nodes: [Node]

    public init(_ files: [FileDiff]) {
        let root = Folder()
        for (i, file) in files.enumerated() {
            var parts = file.path.split(separator: "/").map(String.init)
            guard let name = parts.popLast() else { continue }
            var folder = root
            for part in parts {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append((name, file.id, i))
        }
        nodes = root.nodes(under: "")
    }

    /// A row for each node whose folders are all open, with its depth.
    public func rows(collapsed: Set<String>) -> [(node: Node, depth: Int)] {
        var rows: [(Node, Int)] = []
        func walk(_ nodes: [Node], _ depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if case let .folder(children) = node.kind, !collapsed.contains(node.id) {
                    walk(children, depth + 1)
                }
            }
        }
        walk(nodes, 0)
        return rows
    }

    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [(name: String, id: String, index: Int)] = []

        func nodes(under path: String) -> [Node] {
            let folders = folders.sorted { order($0.key, $1.key) }.map { name, folder in
                var name = name, folder = folder
                // Fold in a lone folder that holds nothing else.
                while folder.files.isEmpty, folder.folders.count == 1, let (child, next) = folder.folders.first {
                    name += "/" + child
                    folder = next
                }
                let id = path + name + "/"
                return Node(id: id, name: name, kind: .folder(folder.nodes(under: id)))
            }
            let files = files.sorted { order($0.name, $1.name) }.map {
                Node(id: $0.id, name: $0.name, kind: .file($0.index))
            }
            return folders + files
        }

        private func order(_ a: String, _ b: String) -> Bool {
            a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}
