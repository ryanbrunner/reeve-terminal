import Foundation
import ReeveKit

/// What a command answers with, on stdout.
func out(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

/// What a person should know but a script shouldn't have to read past, on stderr.
func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// `--json`: the API's own answer and nothing else.
func printJSON<T: Encodable>(_ value: T) throws {
    let data = try API.encoder().encode(value)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func when(_ date: Date) -> String {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm"
    return format.string(from: date)
}

extension Activity {
    var label: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .needsReview: "needs review"
        case .needsInput: "needs input"
        case .waiting: "waiting on background work"
        case .error: "error"
        }
    }
}

extension APICard {
    var short: String { CardRef.short(card.id) }

    /// What the card is doing, as one cell: its activity, whether its session
    /// is asleep, and its pull request.
    var status: String {
        var parts = [card.activity.label]
        if card.queued == true {
            parts = ["not started"]
        } else if starting {
            parts = ["starting"]
        } else if !live, card.activity != .error {
            parts.append("(asleep)")
        }
        if let pr = card.pullRequest {
            parts.append("PR #\(pr.number)" + (pr.state == .open ? "" : " \(pr.state.rawValue)"))
        }
        return parts.joined(separator: " ")
    }
}

/// Text from an option, a file, or stdin when the file is `-`.
func readText(_ path: String) throws -> String {
    if path == "-" {
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    do {
        return try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    } catch {
        throw CLIError("couldn't read \(path): \(error.localizedDescription)")
    }
}
