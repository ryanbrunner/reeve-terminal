import ReeveKit
import SwiftUI
import UniformTypeIdentifiers

/// The five columns, crossed by the swimlanes. Cards move between columns on
/// their own as their sessions move on, and can be dragged between columns
/// and lanes. New cards are named in place, in Backlog, Design, Planning or In Progress.
struct BoardView: View {
    @EnvironmentObject var board: Board

    var body: some View {
        if board.vibes != nil {
            VibesBoardView()
        } else {
            VStack(spacing: 6) {
                // Each column's heading, once, over every lane.
                Columns {
                    ForEach(Stage.allCases) { ColumnHeading(stage: $0) }
                }
                .padding(.horizontal, 10)
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        VStack(spacing: 10) {
                            ForEach(board.lanes) { lane in
                                LaneView(lane: lane, titled: board.lanes.count > 1, minHeight: laneHeight(geo.size.height))
                            }
                            AddLaneButton()
                        }
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: board.cards.map { "\($0.id)\($0.stage.rawValue)\(board.lane(of: $0).id)" })
        }
    }

    /// Lanes share the board's height between them, so one lane fills it as
    /// the columns used to, and a lane never gets too short to drop into.
    private func laneHeight(_ height: CGFloat) -> CGFloat {
        let count = CGFloat(board.lanes.count)
        let titles: CGFloat = board.lanes.count > 1 ? 26 * count : 0
        let addButton: CGFloat = 28
        return max(140, (height - titles - addButton - 10 * count) / count)
    }
}

/// The board's columns, side by side and all the same width whatever is in
/// them, so a long title or the new card field never widens its column.
/// Every column is as tall as the tallest, so a lane's row reads as one.
private struct Columns: Layout {
    var spacing: CGFloat = 10

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(max(count, 1)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let column = columnWidth(width, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width, count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (column + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: column, height: bounds.height))
        }
    }
}

/// A column's name, its count across every lane, and its tools.
private struct ColumnHeading: View {
    @EnvironmentObject var board: Board
    let stage: Stage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SectionLabel(text: stage.label)
            Text("\(board.cards(in: stage).count)")
                .font(.mono(11, .medium))
                .tracking(0.66)
                .foregroundStyle(Theme.muted.opacity(0.6))
            Spacer()
            if stage == .release { CleanupButton() }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
    }
}

/// One swimlane: its name (once there is more than one) and a cell for each column.
private struct LaneView: View {
    @EnvironmentObject var board: Board
    let lane: Lane
    let titled: Bool
    let minHeight: CGFloat
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if titled { LaneTitle(lane: lane, collapsed: $collapsed) }
            if !titled || !collapsed {
                Columns {
                    ForEach(Stage.allCases) { stage in
                        CellView(spot: NewCardSpot(lane: lane.id, stage: stage), minHeight: minHeight)
                    }
                }
            }
        }
    }
}

private struct LaneTitle: View {
    @EnvironmentObject var board: Board
    let lane: Lane
    @Binding var collapsed: Bool

    /// What is in the lane, by column: "2 Backlog · 1 In Progress".
    private var summary: String {
        Stage.allCases
            .compactMap { stage -> String? in
                let count = board.cards(in: stage, lane: lane.id).count
                return count > 0 ? "\(count) \(stage.label)" : nil
            }
            .joined(separator: " · ")
    }

    var body: some View {
        let index = board.lanes.firstIndex(of: lane) ?? 0
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help(collapsed ? "Expand swimlane" : "Collapse swimlane")
            Text(lane.name)
                .font(.geist(13, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("\(board.cards(inLane: lane.id).count)")
                .font(.mono(11, .medium))
                .foregroundStyle(Theme.muted.opacity(0.6))
            LaneBar(lane: lane)
            Text(summary.isEmpty ? "No cards" : summary)
                .font(.geist(12))
                .foregroundStyle(Theme.muted.opacity(0.7))
                .lineLimit(1)
            Menu {
                Button("Rename…") { LaneName.ask(renaming: lane, board: board) }
                Button("Move Up") { board.moveLane(lane.id, by: -1) }
                    .disabled(index == 0)
                Button("Move Down") { board.moveLane(lane.id, by: 1) }
                    .disabled(index == board.lanes.count - 1)
                Divider()
                Button("Delete Lane…") { LaneName.confirmDelete(lane, board: board) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } }
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse") { collapsed.toggle() }
            Button("Rename…") { LaneName.ask(renaming: lane, board: board) }
        }
    }
}

/// A lane's cards by column, as one thin bar: each column's share of the
/// lane in its own colour, left to right as on the board.
private struct LaneBar: View {
    @EnvironmentObject var board: Board
    let lane: Lane

    var body: some View {
        let counts = Stage.allCases.map { (stage: $0, count: board.cards(in: $0, lane: lane.id).count) }
        let total = counts.reduce(0) { $0 + $1.count }
        GeometryReader { geo in
            let filled = counts.filter { $0.count > 0 }
            let gaps = CGFloat(max(filled.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(filled, id: \.stage) { part in
                    Capsule()
                        .fill(part.stage.tint)
                        .frame(width: max(2, (geo.size.width - gaps) * CGFloat(part.count) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 72, height: 4)
        .background(Capsule().fill(Theme.edge.opacity(total == 0 ? 0.6 : 0)))
        .animation(.easeInOut(duration: 0.25), value: counts.map(\.count))
        .help(counts.map { "\($0.count) \($0.stage.label)" }.joined(separator: " · "))
    }
}

extension Stage {
    /// Cool to warm to done, as a card travels the board.
    var tint: Color {
        switch self {
        case .backlog: Theme.slate500
        case .design: Theme.pink400
        case .planning: Theme.indigo400
        case .inProgress: Theme.sky400
        case .testing: Color(hex: 0xFBBF24)
        case .release: Color(hex: 0x10B981)
        }
    }
}

/// Where a lane and a column cross: the cards in both, somewhere to drop
/// one, and in the columns a card can start in, somewhere to name one.
private struct CellView: View {
    @EnvironmentObject var board: Board
    let spot: NewCardSpot
    let minHeight: CGFloat
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(board.cards(in: spot.stage, lane: spot.lane)) { card in
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
            if NewCardSpot.stages.contains(spot.stage) {
                if board.composing == spot {
                    NewCardField(spot: spot)
                } else {
                    AddCardButton(spot: spot)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.sky950.opacity(0.2) : Theme.panel.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Theme.sky600 : Theme.edge))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { board.move(id, to: spot.stage, lane: spot.lane) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// Opens the new card field in its cell. Quiet until hovered.
private struct AddCardButton: View {
    @EnvironmentObject var board: Board
    let spot: NewCardSpot
    @State private var hovering = false

    var body: some View {
        Button {
            board.compose(in: spot.stage, lane: spot.lane)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("New card").font(.geist(12))
                Spacer()
            }
            .foregroundStyle(hovering ? Theme.text : Theme.muted.opacity(0.7))
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.edge.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(spot.stage == .backlog && spot.lane == board.lanes.first?.id ? "New card (⌘N)" : "New card")
    }
}

/// Below the lanes: another one.
private struct AddLaneButton: View {
    @EnvironmentObject var board: Board
    @State private var hovering = false

    var body: some View {
        Button {
            LaneName.ask(renaming: nil, board: board)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text("Add swimlane").font(.geist(12))
            }
            .foregroundStyle(hovering ? Theme.text : Theme.muted.opacity(0.6))
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

/// Naming a lane, new or old, and deleting one.
enum LaneName {
    @MainActor
    static func ask(renaming lane: Lane?, board: Board) {
        let alert = NSAlert()
        alert.messageText = lane == nil ? "New swimlane" : "Rename swimlane"
        alert.informativeText = lane == nil ? "A row across the board. Drag cards into it." : ""
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = lane?.name ?? ""
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: lane == nil ? "Add" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let name = field.stringValue
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let given = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty, given != name else { return }
        if let lane {
            board.renameLane(lane.id, to: given)
        } else {
            board.addLane(named: given)
        }
    }

    @MainActor
    static func confirmDelete(_ lane: Lane, board: Board) {
        let count = board.cards(inLane: lane.id).count
        let index = board.lanes.firstIndex(of: lane) ?? 0
        guard count > 0, let heir = board.lanes[safe: index == 0 ? 1 : index - 1] else {
            board.deleteLane(lane.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(lane.name)”?"
        alert.informativeText = "Its \(count == 1 ? "card moves" : "\(count) cards move") to “\(heir.name)”. Nothing else happens to \(count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Delete Lane")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { board.deleteLane(lane.id) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
        if board.lanes.count > 1 {
            LaneMenu(card: card)
        }
        WaitMenu(card: card)
        Button("Rename…") { Rename.ask(card: card, board: board) }
        Button("Sort Now") { board.classifyNow(card.id) }
            .disabled(card.transcriptPath == nil)
        Divider()
        VibesToggle(card: card)
        Divider()
        if card.queued == true {
            let held = board.launching.contains(card.id) || board.blocker(of: card.id) != nil
            Button("Start Design") { board.startQueued(card.id, mode: .design) }
                .disabled(held)
            Button("Start Planning") { board.startQueued(card.id, mode: .plan) }
                .disabled(held)
            Button("Start Building") { board.startQueued(card.id, mode: .build) }
                .disabled(held)
        } else {
            Button(board.live.contains(card.id) ? "Restart Session" : "Resume Session") { board.restart(card.id) }
        }
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

/// The swimlanes a card can move to.
struct LaneMenu: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        Menu("Move to Lane") {
            ForEach(board.lanes) { lane in
                Button(lane.name) { board.move(card.id, lane: lane.id) }
                    .disabled(lane.id == board.lane(of: card).id)
            }
        }
    }
}

/// The card another waits on: in the backlog it can't start until that one
/// has merged.
struct WaitMenu: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        Menu("Wait On") {
            ForEach(board.ordered.filter { $0.id != card.id }) { other in
                Toggle(board.displayTitle(other), isOn: Binding(
                    get: { card.dependsOnId == other.id },
                    set: { wait($0 ? other.id : nil) }
                ))
            }
            if card.dependsOnId != nil {
                Divider()
                Button("Stop Waiting") { wait(nil) }
            }
        }
        .disabled(board.cards.count < 2 && card.dependsOnId == nil)
    }

    private func wait(_ target: UUID?) {
        do {
            try board.waitOn(card.id, target)
        } catch {
            board.refuse(error as? APIError ?? APIError(error.localizedDescription))
        }
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
