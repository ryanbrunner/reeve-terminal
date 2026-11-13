import ReeveKit
import SwiftUI
import UniformTypeIdentifiers

/// The five columns. Cards move between them on their own as their sessions
/// move on, and can be dragged.
struct BoardView: View {
    @EnvironmentObject var board: Board

    var body: some View {
        if board.vibes != nil {
            VibesBoardView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Stage.allCases) { stage in
                    ColumnView(stage: stage)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: board.cards.map { "\($0.id)\($0.stage.rawValue)" })
        }
    }
}

struct ColumnView: View {
    @EnvironmentObject var board: Board
    let stage: Stage
    @State private var targeted = false
    @Namespace private var namespace

    var body: some View {
        let cards = board.cards(in: stage)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(text: stage.label)
                Text("\(cards.count)")
                    .font(.mono(11, .medium))
                    .tracking(0.66)
                    .foregroundStyle(Theme.muted.opacity(0.6))
                Spacer()
                if stage == .backlog {
                    Button {
                        board.showingNewCard = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("New card (⌘N)")
                }
            }
            .padding(.horizontal, 4)
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardFace(card: card, selected: card.id == board.selectedId)
                            .onTapGesture { board.select(card.id) }
                            .draggable(card.id.uuidString) {
                                CardFace(card: card, dragging: true)
                                    .frame(width: 220)
                                    .environmentObject(board)
                            }
                            .contextMenu { CardMenu(card: card) }
                            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.never)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.sky950.opacity(0.2) : Theme.panel.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Theme.sky600 : Theme.edge))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { board.move(id, to: stage) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// What a card can be asked to do from its context menu.
struct CardMenu: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        Menu("Move to") {
            ForEach(Stage.allCases) { stage in
                Button(stage.label) { board.move(card.id, to: stage) }
                    .disabled(stage == card.stage)
            }
        }
        Button("Rename…") { Rename.ask(card: card, board: board) }
        Button("Sort Now") { board.classifyNow(card.id) }
            .disabled(card.transcriptPath == nil)
        Divider()
        VibesToggle(card: card)
        Divider()
        Button(board.live.contains(card.id) ? "Restart Session" : "Resume Session") { board.restart(card.id) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: card.cwd)]) }
        Divider()
        Button("Close Card") { CloseCard.confirm(card: card, board: board) }
    }
}

enum Rename {
    @MainActor
    static func ask(card: Card, board: Board) {
        let alert = NSAlert()
        alert.messageText = "Rename card"
        alert.informativeText = "Leave it empty to let Claude name it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = card.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            board.rename(card.id, to: field.stringValue)
        }
    }
}

enum CloseCard {
    /// Closing ends the card's session and deletes its worktree, so a live
    /// one, or one with work not yet committed, asks first.
    @MainActor
    static func confirm(card: Card, board: Board) {
        Task {
            let live = board.live.contains(card.id)
            var changes = 0
            if let path = card.worktreePath {
                changes = await Worktrees.uncommittedChanges(at: path, env: board.environment)
            }
            guard live || changes > 0 else {
                board.close(card.id)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Close “\(board.displayTitle(card))”?"
            alert.informativeText = message(card: card, live: live, changes: changes)
            alert.addButton(withTitle: "Close Card")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                board.close(card.id)
            }
        }
    }

    private static func message(card: Card, live: Bool, changes: Int) -> String {
        guard card.worktreePath != nil else {
            return "This ends its Claude Code session. The conversation stays in Claude Code's history, and claude --resume can still open it."
        }
        var lines: [String] = []
        if changes > 0 {
            lines.append("Its worktree has \(changes == 1 ? "1 file" : "\(changes) files") with uncommitted changes, which will be lost.")
        }
        if live { lines.append("This ends its Claude Code session.") }
        lines.append("The worktree is deleted. Anything committed on \(card.branch ?? "its branch") stays in the repo.")
        return lines.joined(separator: " ")
    }
}

/// A card in VIBES MODE on its own, from a menu. While the whole board is in
/// it, every card is, and this says so rather than offering a switch that
/// does nothing.
struct VibesToggle: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        Toggle("Vibes Mode", isOn: Binding(
            get: { board.vibes != nil || card.vibes == true },
            set: { board.setVibes(card.id, $0) }
        ))
        .disabled(board.vibes != nil)
    }
}
