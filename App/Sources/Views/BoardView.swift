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
                if stage == .release { CleanupButton() }
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

/// The Release column's broom: archives every card whose pull requests have
/// merged. Asks first, since it ends their sessions and deletes their worktrees.
struct CleanupButton: View {
    @EnvironmentObject var board: Board
    var tint: Color = Theme.muted

    var body: some View {
        let count = board.archivable.count
        Button {
            Cleanup.confirm(board: board)
        } label: {
            Image(systemName: "archivebox").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.opacity(count > 0 ? 1 : 0.4))
        .disabled(count == 0)
        .help(count == 0 ? "Clean up: no cards have merged pull requests" : "Clean up \(count) merged card\(count == 1 ? "" : "s") into the archive")
    }
}

enum Cleanup {
    @MainActor
    static func confirm(board: Board) {
        let count = board.archivable.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Archive \(count) merged card\(count == 1 ? "" : "s")?"
        alert.informativeText = "Their pull requests have merged. Each card's session ends and its worktree is deleted, and the card moves to the Archive. A card with uncommitted changes in its worktree stays on the board."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let result = await board.archiveMerged()
            guard result.kept > 0 else { return }
            let note = NSAlert()
            note.messageText = "\(result.kept) card\(result.kept == 1 ? " was" : "s were") left on the board"
            note.informativeText = "\(result.kept == 1 ? "Its" : "Their") worktree\(result.kept == 1 ? " has" : "s have") uncommitted changes. Commit or discard \(result.kept == 1 ? "them" : "those"), then clean up again."
            note.runModal()
        }
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
        if let prs = card.pullRequests, prs.count > 1 {
            Menu("Open Pull Request") {
                ForEach(prs, id: \.number) { pr in
                    Button(String("#\(pr.number) \(pr.title)")) {
                        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        } else if let pr = card.pullRequests?.first, let url = URL(string: pr.url) {
            Button(String("Open Pull Request #\(pr.number)")) { NSWorkspace.shared.open(url) }
        }
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
    /// Closing ends the card's session and deletes its worktree, so one with
    /// code that hasn't landed (uncommitted changes, unmerged commits, an open
    /// pull request) asks first. Anything else just closes.
    @MainActor
    static func confirm(card: Card, board: Board) {
        Task {
            guard let unmerged = await board.closeWouldLose(card.id) else {
                board.close(card.id)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Close “\(board.displayTitle(card))”?"
            alert.informativeText = message(card: card, live: board.live.contains(card.id), unmerged: unmerged)
            alert.addButton(withTitle: "Close Card")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                board.close(card.id)
            }
        }
    }

    private static func message(card: Card, live: Bool, unmerged: Board.Unmerged) -> String {
        var lines: [String] = []
        let changes = unmerged.uncommitted
        if changes > 0 {
            lines.append("Its worktree has \(changes == 1 ? "1 file" : "\(changes) files") with uncommitted changes, which will be lost.")
        }
        if unmerged.commits > 0 {
            lines.append("\(unmerged.commits == 1 ? "1 commit" : "\(unmerged.commits) commits") on \(card.branch ?? "its branch") \(unmerged.commits == 1 ? "isn't" : "aren't") merged.")
        }
        let prs = unmerged.openPullRequests
        if !prs.isEmpty {
            let numbers = prs.map { "#\($0.number)" }.joined(separator: ", ")
            lines.append("Pull request\(prs.count == 1 ? "" : "s") \(numbers) \(prs.count == 1 ? "is" : "are") still open.")
        }
        if live { lines.append("This ends its Claude Code session.") }
        if card.worktreePath != nil {
            lines.append("The worktree is deleted. Anything committed on \(card.branch ?? "its branch") stays in the repo.")
        }
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
