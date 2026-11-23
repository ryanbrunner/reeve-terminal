import AppKit
import ReeveKit
import SwiftUI

/// What an open card shows: the session itself, the plan it made, what it
/// has changed, the app it is building, under review in Gloss, the pull
/// requests it has opened, or the designs `/design` made.
enum CardTab: String, CaseIterable, Identifiable {
    case terminal, plan, changes, preview, prs, design

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .plan: "Plan"
        case .changes: "Changes"
        case .preview: "Preview"
        case .prs: "PRs"
        case .design: "Design"
        }
    }
}

/// The open card, in place of the board: the real Claude Code, where the work
/// happens, with its plan, its changes and its preview a tab away.
///
/// Board in its bar, ⌘B or Esc goes back to the board. In a live terminal Esc
/// belongs to Claude Code, where it interrupts a turn.
struct CardPage: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let tab = board.tab(card.id)
        VStack(spacing: 0) {
            CardBar(card: card)
            if card.queued == true {
                // No worktree and no session: no terminal, plan or
                // changes yet, only a way to start it.
                BacklogPanel(card: card)
            } else {
                CardTabBar(card: card, selected: tab)
                ZStack {
                    // Always mounted, so the terminal keeps its size: every
                    // resize makes `claude` redraw. The other tabs cover it.
                    TerminalHost(cardId: card.id, focused: tab == .terminal)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .background(Theme.ink)
                        .overlay {
                            if tab == .terminal, !board.live.contains(card.id) {
                                SleepingOverlay(card: card)
                            }
                        }
                    switch tab {
                    case .terminal:
                        EmptyView()
                    case .plan:
                        PlanView(card: card).id(card.id)
                    case .changes:
                        ChangesView(card: card).id(card.id)
                    case .preview:
                        PreviewView(card: card, preview: board.previews.preview(for: card.id)).id(card.id)
                    case .prs:
                        PullRequestsView(card: card).id(card.id)
                    case .design:
                        DesignView(card: card, viewer: board.designViews.preview(for: card.id)).id(card.id)
                    }
                }
            }
        }
        .background(Theme.ink)
        // Swallows clicks, drags and right-clicks meant for the board behind.
        .contentShape(Rectangle())
        .modifier(EscapeGoesBack())
    }
}

/// Esc goes back to the board, unless what has the keyboard has a use for it:
/// a live terminal, where it interrupts Claude; a field being typed in; or the
/// page in the Preview tab.
private struct EscapeGoesBack: ViewModifier {
    @EnvironmentObject var board: Board
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                // A field on the board, behind the card, has nothing more to
                // be typed into it, and would otherwise take Esc for its own.
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "board" }),
                   window.firstResponder is NSTextView {
                    window.makeFirstResponder(nil)
                }
                let board = board
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { Self.goesBack(event, board: board) ? nil : event }
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    @MainActor
    private static func goesBack(_ event: NSEvent, board: Board) -> Bool {
        // The board's own window: not a sheet, alert or popover over it.
        guard event.keyCode == 53, let card = board.selected,
              event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
              let window = event.window, window.identifier?.rawValue == "board", window.attachedSheet == nil
        else { return false }
        switch window.firstResponder {
        case let terminal as CardTerminalView:
            if let id = terminal.cardId, board.live.contains(id) { return false }
        case is NSTextView:
            return false
        case let view as NSView where [board.previews, board.designViews].contains(where: { $0.existing(card.id).map { view.isDescendant(of: $0.webView) } == true }):
            return false
        default:
            break
        }
        // Offered first to anything in the card bound to Esc.
        if window.performKeyEquivalent(with: event) { return true }
        board.dismissOpenCard()
        return true
    }
}

/// The open card's bar: the way back to the board, where the card is on it,
/// and its neighbours either side.
private struct CardBar: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let tone = GlowTone(card.activity)
        HStack(spacing: 10) {
            Button {
                board.dismissOpenCard()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Board").font(.geist(13, .medium))
                    Text("⌘B").font(.mono(11)).foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.textSoft)
            }
            .buttonStyle(SecondaryButtonStyle())
            .help("Back to the board (⌘B). The session keeps running.")
            // Where it is on the board: its lane, when there is more than
            // one, and its column. Either goes back to the board too.
            if board.lanes.count > 1 {
                crumb(board.lane(of: card).name, dot: nil)
            }
            crumb(card.stage.label, dot: card.stage.tint)
            Circle()
                .fill(tone?.mark ?? Theme.edgeStrong)
                .frame(width: 7, height: 7)
                .shadow(color: tone?.mark ?? .clear, radius: 3)
            Text(board.displayTitle(card))
                .font(.geist(13, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .layoutPriority(1)
            if let line = card.backgroundLine {
                Text(line).font(.geist(12)).foregroundStyle(Theme.indigo200.opacity(0.85)).lineLimit(1)
            } else if let waiting = card.waitingOn {
                Text(waiting).font(.geist(12)).foregroundStyle(Theme.amber100.opacity(0.85)).lineLimit(1)
            } else if let summary = card.summary {
                Text(summary).font(.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            VibesSwitch(
                on: board.vibes != nil || card.vibes == true,
                label: "Vibes",
                help: board.vibes != nil ? "The whole board is in VIBES MODE"
                    : card.vibes == true ? "Put a person back in this card's loop"
                    : "Let Claude approve, answer and ship this card without you"
            ) { board.setVibes(card.id, card.vibes != true) }
            .disabled(board.vibes != nil)
            Text(abbreviate(card.cwd))
                .font(.mono(11))
                .foregroundStyle(Theme.muted.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.head)
            Menu {
                CardMenu(card: card)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Card actions")
            Neighbours(card: card)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Theme.panel)
        // The card's light, now there is no frame round it to wear it: the
        // rainbow if it is going to ship itself, the rail while Claude works.
        .overlay(alignment: .bottom) {
            if board.inVibes(card) {
                FlowingRainbow(period: 2.4).frame(height: 2)
            } else if card.activity == .running {
                RunningRail()
            } else {
                Rectangle().fill(Theme.edge).frame(height: 1)
            }
        }
    }

    /// A step of the bar's trail: a way back to the board, under its name.
    private func crumb(_ name: String, dot: Color?) -> some View {
        HStack(spacing: 8) {
            Button {
                board.dismissOpenCard()
            } label: {
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                    SectionLabel(text: name)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the board (⌘B)")
            Text("/").font(.geist(13)).foregroundStyle(Theme.edgeStrong)
        }
        .fixedSize()
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The cards either side of the open one, in board order, as Next Card and
/// Previous Card go, and where this one falls among them.
private struct Neighbours: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let order = board.ordered
        if order.count > 1, let at = order.firstIndex(where: { $0.id == card.id }) {
            Rectangle().fill(Theme.edge).frame(width: 1, height: 16)
            HStack(spacing: 2) {
                step("chevron.left", label: "Previous card", key: "⇧⌘[", by: -1)
                Text("\(at + 1) of \(order.count)")
                    .font(.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .frame(minWidth: 44)
                step("chevron.right", label: "Next card", key: "⇧⌘]", by: 1)
            }
            .fixedSize()
        }
    }

    private func step(_ symbol: String, label: String, key: String, by offset: Int) -> some View {
        Button {
            board.selectOffset(offset)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.muted)
        .help("\(label) (\(key))")
        .accessibilityLabel(label)
    }
}

/// The open card's tabs, under its bar.
private struct CardTabBar: View {
    @EnvironmentObject var board: Board
    let card: Card
    let selected: CardTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(CardTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    board.show(tab, for: card.id)
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.label)
                        if tab == .plan, board.unseenPlans.contains(card.id) {
                            Circle().fill(Theme.sky400).frame(width: 6, height: 6)
                                .help("A new plan")
                        }
                        if tab == .design, board.unseenDesigns.contains(card.id) {
                            Circle().fill(Stage.design.tint).frame(width: 6, height: 6)
                                .help("A new design")
                        }
                        if tab == .prs, let count = card.pullRequests?.count, count > 1 {
                            Text("\(count)").font(.mono(10)).foregroundStyle(Theme.muted)
                        }
                    }
                    .font(.geist(12, tab == selected ? .medium : .regular))
                    .foregroundStyle(tab == selected ? Theme.text : Theme.muted)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if tab == selected { Rectangle().fill(Theme.sky400).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tab.label) (⌥⌘\(index + 1))")
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
}

/// A card whose session is not running: after a restart, or once `claude` exits.
private struct SleepingOverlay: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        VStack(spacing: 10) {
            Text(card.hasConversation ? "This session is asleep" : "This session hasn't started")
                .font(.geist(14, .medium))
                .foregroundStyle(Theme.text)
            Button(card.hasConversation ? "Resume session" : "Start session") { board.restart(card.id) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edge))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 32)
    }
}

/// A backlog card that hasn't started: what it will be told, and the three
/// ways to start it, which moving it to their columns does too.
private struct BacklogPanel: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let launching = board.launching.contains(card.id)
        VStack(spacing: 14) {
            Text(launching ? "Making its worktree…" : "In the backlog: nothing has started")
                .font(.geist(14, .medium))
                .foregroundStyle(Theme.text)
            Text("When it starts, Claude gets a worktree of \(card.folderName) and is told:")
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
            Text(card.brief ?? (card.title.isEmpty ? "(nothing: you start the conversation)" : card.title))
                .font(.mono(12))
                .foregroundStyle(Theme.textSoft)
                .frame(maxWidth: 460)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
            let blocker = board.blocker(of: card.id)
            HStack(spacing: 10) {
                Button("Design it") { board.startQueued(card.id, mode: .design) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Plan it") { board.startQueued(card.id, mode: .plan) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Start building") { board.startQueued(card.id, mode: .build) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(launching || blocker != nil)
            if let blocker {
                Text("It waits on “\(board.displayTitle(blocker))”, in \(Dependency.status(of: blocker)). It can start once that merges.")
                    .font(.geist(11))
                    .foregroundStyle(Theme.amber100.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else {
                Text("Or go back to the board and drag it to Design, Planning or In Progress.")
                    .font(.geist(11))
                    .foregroundStyle(Theme.muted.opacity(0.8))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }
}

/// Over an empty board: how to start.
struct EmptyState: View {
    @EnvironmentObject var board: Board

    var body: some View {
        VStack(spacing: 12) {
            Glyph(height: 36).opacity(0.5)
            Text("No cards yet")
                .font(.geist(14, .medium))
                .foregroundStyle(Theme.muted)
            Button("New card") { board.compose() }
                .buttonStyle(PrimaryButtonStyle())
            Text("Name a card in Backlog to keep it for later, in Design to have Claude design it with /design, in Planning to have Claude plan it, or in In Progress to have Claude start on it. It finds its own column as the work moves on.")
                .font(.geist(12))
                .foregroundStyle(Theme.muted.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edge))
    }
}

/// Holds the open card's terminal view. The views live in `Terminals`, so
/// switching cards only swaps which one is mounted here.
///
/// The terminal takes the keyboard only while its tab is showing; under the
/// Plan, Changes or Preview tab, keys typed would otherwise go to `claude` unseen.
struct TerminalHost: NSViewRepresentable {
    @EnvironmentObject var board: Board
    let cardId: UUID
    let focused: Bool

    final class Coordinator {
        var focused: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x0E1116).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = board.terminals.view(for: cardId)
        let mounting = view.superview !== container
        if mounting {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        guard mounting || context.coordinator.focused != focused else { return }
        context.coordinator.focused = focused
        let focused = focused
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if focused {
                window.makeFirstResponder(view)
            } else if window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }
}
