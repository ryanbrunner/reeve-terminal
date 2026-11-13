import ReeveKit
import SwiftUI

/// The open card, over the board: the real Claude Code, where the work happens.
///
/// Esc belongs to Claude Code (it interrupts a turn), so nothing here takes it.
/// The close button, ⌘B or a click outside goes back to the board.
struct CardModal: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        ZStack {
            // Swallows clicks, drags and right-clicks meant for the cards behind.
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { board.dismissOpenCard() }
            VStack(spacing: 0) {
                TerminalHeader(card: card)
                TerminalHost(cardId: card.id)
                    .padding(.leading, 10)
                    .padding(.top, 6)
                    .background(Theme.ink)
                    .overlay {
                        if !board.live.contains(card.id) {
                            SleepingOverlay(card: card)
                        }
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
            if let waiting = card.waitingOn {
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

/// Over an empty board: how to start.
struct EmptyState: View {
    @EnvironmentObject var board: Board

    var body: some View {
        VStack(spacing: 12) {
            Glyph(height: 36).opacity(0.5)
            Text("No cards yet")
                .font(.geist(14, .medium))
                .foregroundStyle(Theme.muted)
            Button("New card") { board.showingNewCard = true }
                .buttonStyle(PrimaryButtonStyle())
            Text("Each card is a Claude Code session in a folder. It finds its own column as the work moves on. Click one to open its terminal.")
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
struct TerminalHost: NSViewRepresentable {
    @EnvironmentObject var board: Board
    let cardId: UUID

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x0E1116).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = board.terminals.view(for: cardId)
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}
