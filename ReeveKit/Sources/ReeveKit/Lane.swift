import Foundation

/// A swimlane: a row across the board's columns, named whatever a person
/// likes. Every card is in one; a card whose lane has gone is in the first.
public struct Lane: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// The lane a board starts with, and the one it falls back to.
    public static func starter() -> Lane {
        Lane(name: "Cards")
    }

    /// The lane `ref` names, by id, by id prefix as `reeve` shows it, or by
    /// name, whatever its case.
    public static func find(_ ref: String, in lanes: [Lane]) -> Lane? {
        let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let lane = lanes.first(where: { $0.id.uuidString.lowercased() == key || $0.name.lowercased() == key }) { return lane }
        let prefixed = lanes.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        return key.count >= 4 && prefixed.count == 1 ? prefixed[0] : nil
    }
}

extension Card {
    /// The lane the card is in: its own while it is still on the board, else the first.
    public func lane(in lanes: [Lane]) -> Lane? {
        lanes.first { $0.id == laneId } ?? lanes.first
    }

    /// The start a backlog card gets from being moved to `stage`: planning
    /// designs, planning plans, in progress builds, and anywhere else leaves
    /// it waiting.
    public static func launch(movingTo stage: Stage) -> StartMode? {
        switch stage {
        case .design: .design
        case .planning: .plan
        case .inProgress: .build
        default: nil
        }
    }
}
