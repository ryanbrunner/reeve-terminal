import ReeveKit
import SwiftUI

/// What an open card shows: the session itself, the plan it made, what it
/// has changed, the app it is building, under review in Gloss, or the pull
/// requests it has opened.
enum CardTab: String, CaseIterable, Identifiable {
    case terminal, plan, changes, preview, prs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .plan: "Plan"
        case .changes: "Changes"
        case .preview: "Preview"
        case .prs: "PRs"
        }
    }
}

/// The open card, over the board: the real Claude Code, where the work
/// happens, with its plan, its changes and its preview a tab away.
///
/// Esc belongs to Claude Code (it interrupts a turn), so nothing here takes it.
/// The close button, ⌘B or a click outside goes back to the board.
struct CardModal: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let tab = board.tab(card.id)
        ZStack {
            // Swallows clicks, drags and right-clicks meant for the cards behind.
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { board.dismissOpenCard() }
            VStack(spacing: 0) {
                TerminalHeader(card: card)
                if card.queued == true {
                    // No worktree and no session: no terminal, plan or
                    // changes yet, only a way to start it.
                    BacklogPanel(card: card)
                } else {
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
                        }
                    }
                    CardTabBar(card: card, selected: tab)
                }
            }
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edgeStrong))
            // A card that is going to ship itself wears the rainbow open too.
            // An overlay, so the terminal's frame is untouched.
            .overlay {
                if board.inVibes(card) {
                    FlowingRainbow(period: 2.4)
                        .mask(RoundedRectangle(cornerRadius: 10).strokeBorder(lineWidth: 2))
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            .padding(28)
        }
    }
}

/// A line over the terminal naming the open card and where it is.
private struct TerminalHeader: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let tone = GlowTone(card.activity)
        HStack(spacing: 10) {
            Circle()
                .fill(tone?.mark ?? Theme.edgeStrong)
                .frame(width: 7, height: 7)
                .shadow(color: tone?.mark ?? .clear, radius: 3)
            Text(board.displayTitle(card))
                .font(.geist(13, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            SectionLabel(text: card.stage.label)
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
            Button {
                board.dismissOpenCard()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Back to the board (⌘B). The session keeps running.")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The open card's tabs, along the bottom of the card.
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
                        if tab == .prs, let count = card.pullRequests?.count, count > 1 {
                            Text("\(count)").font(.mono(10)).foregroundStyle(Theme.muted)
                        }
                    }
                    .font(.geist(12, tab == selected ? .medium : .regular))
                    .foregroundStyle(tab == selected ? Theme.text : Theme.muted)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .top) {
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
        .overlay(alignment: .top) { Rectangle().fill(Theme.edge).frame(height: 1) }
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

/// A backlog card that hasn't started: what it will be told, and the two
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
            HStack(spacing: 10) {
                Button("Plan it") { board.startQueued(card.id, mode: .plan) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Start building") { board.startQueued(card.id, mode: .build) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(launching)
            Text("Or drag it to Planning or In Progress.")
                .font(.geist(11))
                .foregroundStyle(Theme.muted.opacity(0.8))
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
            Text("Name a card in Backlog to keep it for later, in Planning to have Claude plan it, or in In Progress to have Claude start on it. It finds its own column as the work moves on.")
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
