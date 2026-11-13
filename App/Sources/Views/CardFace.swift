import ReeveKit
import SwiftUI

/// A card on the board: its title, what it is waiting on or where it stands,
/// and its folder, wearing its activity as light.
struct CardFace: View {
    @EnvironmentObject var board: Board
    let card: Card
    var selected = false
    var dragging = false

    var body: some View {
        let tone = GlowTone(card.activity)
        VStack(alignment: .leading, spacing: 6) {
            Text(board.displayTitle(card))
                .font(.geist(13, .medium))
                .tracking(-0.13)
                .foregroundStyle(card.title.isEmpty ? Theme.text.opacity(0.7) : Theme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let line = card.backgroundLine {
                // Waiting on its own agents: nothing for you to do yet.
                Text(line)
                    .font(.geist(12))
                    .foregroundStyle(Theme.indigo200.opacity(0.85))
                    .lineLimit(1)
                if let tasks = card.background, !tasks.isEmpty {
                    backgroundChips(tasks)
                }
            } else if let waiting = card.waitingOn {
                // What Claude is waiting on, so a waiting card says why without being opened.
                Text(waiting)
                    .font(.geist(12))
                    .foregroundStyle(Theme.amber100.opacity(0.85))
                    .lineLimit(2)
            } else if let summary = card.summary {
                Text(summary)
                    .font(.mono(11))
                    .foregroundStyle(card.activity == .running ? Theme.sky200.opacity(0.7) : Theme.muted)
                    .lineLimit(2)
            }
            footer
        }
        .padding(10)
        .background {
            ZStack {
                GlowBackground(tone: tone)
                if let tone { ActivityMark(tone: tone) }
            }
        }
        .overlay(alignment: .bottom) {
            if card.activity == .running {
                RunningRail().clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // The open card is ringed, the way the web board rings a traced
        // dependency: an outline, so the activity's border keeps its colour.
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.sky400, lineWidth: 1.5).padding(-3)
            }
        }
        .rotationEffect(.degrees(dragging ? 2 : 0))
        .shadow(color: .black.opacity(dragging ? 0.4 : 0), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([board.displayTitle(card), label, card.pullRequest?.spoken].compactMap { $0 }.joined(separator: ", "))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Chip(text: card.folderName, color: Theme.folderColor(card.folderName), fill: Theme.folderColor(card.folderName).opacity(0.2))
            if let pr = card.pullRequest {
                Chip(text: "#\(pr.number)", color: pr.state.color, fill: pr.state.color.opacity(0.18))
            }
            if board.classifying.contains(card.id) {
                Chip(text: "sorting…", color: Theme.sky300, fill: Theme.sky500.opacity(0.15))
            } else if board.classifyErrors[card.id] != nil {
                Chip(text: "unsorted", color: Theme.muted)
            }
            if !board.live.contains(card.id) {
                Chip(text: card.hasConversation ? "asleep" : "not started")
            }
            if card.stagePinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.muted)
                    .help("You put this card here. It stays until you next prompt Claude.")
            }
            Spacer(minLength: 0)
        }
    }

    /// One chip per agent the card waits on, three at most.
    private func backgroundChips(_ tasks: [BackgroundWork]) -> some View {
        HStack(spacing: 4) {
            ForEach(tasks.prefix(3), id: \.id) { task in
                Chip(text: task.agentType ?? task.description ?? task.type, color: Theme.indigo200, fill: Theme.indigo400.opacity(0.15))
            }
            if tasks.count > 3 {
                Chip(text: "+\(tasks.count - 3)", color: Theme.indigo200, fill: Theme.indigo400.opacity(0.15))
            }
        }
        .help(tasks.compactMap(\.description).joined(separator: "\n"))
    }

    private var label: String {
        switch card.activity {
        case .idle: "idle"
        case .running: "Claude running"
        case .needsReview: "ready for review"
        case .needsInput: "needs your answer"
        case .waiting: card.backgroundLine?.lowercased() ?? "waiting"
        case .error: "error"
        }
    }

    private var help: String {
        var lines = [board.displayTitle(card), card.cwd]
        if let pr = card.pullRequest { lines.append(pr.spoken) }
        if let error = board.classifyErrors[card.id] { lines.append("Couldn't sort: \(error)") }
        return lines.joined(separator: "\n")
    }
}

extension PullRequest {
    /// The badge said in words, for its tooltip and VoiceOver.
    var spoken: String {
        let state = switch state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        }
        return "pull request #\(number), \(state)"
    }
}

extension PullRequest.State {
    /// GitHub's own colours for a pull request's state, in the board's hues.
    var color: Color {
        switch self {
        case .open: Color(hex: 0x34D399)
        case .draft: Theme.muted
        case .merged: Color(hex: 0xA78BFA)
        case .closed: Color(hex: 0xF87171)
        }
    }
}
