import ReeveKit
import SwiftUI

/// The window: the board, filling it. Opening a card lays its terminal over
/// the board; closing it goes back to the board and leaves the session running.
struct ContentView: View {
    @EnvironmentObject var board: Board

    var body: some View {
        VStack(spacing: 0) {
            Header()
            ZStack {
                BoardView()
                if board.cards.isEmpty {
                    EmptyState()
                }
                if let card = board.selected {
                    CardModal(card: card)
                        .transition(.opacity)
                }
            }
            // Opacity only: the terminal's frame never animates, since every
            // size change resizes the PTY and makes `claude` redraw.
            .animation(.easeOut(duration: 0.15), value: board.selectedId)
        }
        .background(Theme.ink)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $board.showingNewCard) {
            NewCardSheet().environmentObject(board)
        }
        .preferredColorScheme(.dark)
    }
}

private struct Header: View {
    @EnvironmentObject var board: Board

    var body: some View {
        HStack(spacing: 10) {
            Glyph(height: 18)
            Text("Reeve").font(.geist(16, .semibold)).tracking(-0.32).foregroundStyle(Theme.text)
            Tallies()
                .padding(.leading, 8)
            Spacer()
            Button("New Card") { board.showingNewCard = true }
                .buttonStyle(PrimaryButtonStyle())
        }
        // Clear of the traffic lights, which sit over the header.
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
}

/// A dot and a count for each card waiting on someone or working, most
/// urgent first — what a hidden board would otherwise hide.
private struct Tallies: View {
    @EnvironmentObject var board: Board

    var body: some View {
        HStack(spacing: 12) {
            ForEach([(Activity.needsInput, "Needs your answer"), (.needsReview, "Ready for review"), (.error, "Error"), (.running, "Claude running"), (.waiting, "Waiting on agents")], id: \.0) { activity, label in
                let count = board.cards.filter { $0.activity == activity }.count
                if count > 0, let tone = GlowTone(activity) {
                    HStack(spacing: 6) {
                        Circle().fill(tone.mark).frame(width: 6, height: 6)
                        Text("\(count)").font(.mono(11, .medium)).foregroundStyle(Theme.muted)
                    }
                    .help(label)
                }
            }
        }
    }
}
