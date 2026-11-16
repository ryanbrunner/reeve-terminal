import ReeveKit
import SwiftUI

/// The board in VIBES MODE: the columns become empty wells and every card
/// lifts off them into one layer, so a card that moved flies to its new
/// column instead of vanishing from one list and appearing in another.
///
/// Nobody drags anything in here. The geometry is the calm board's own, so
/// the two layouts land in the same places.
struct VibesBoardView: View {
    @EnvironmentObject var board: Board
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Column padding, the header line and its gap, and the list's own inset.
    private static let top: CGFloat = 6 + 16 + 8 + 4
    /// Two clamped title lines plus the footer.
    static let cardHeight: CGFloat = 88
    /// One card below the previous: its height plus the column's 8px gap.
    private static let step: CGFloat = cardHeight + 8
    /// How far apart cards may be squeezed: the top padding and one line of
    /// title, so a deep column still reads as a fanned deck.
    private static let minStep: CGFloat = 30
    private static let spacing: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 28
            let column = (width - Self.spacing * 4) / 5
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(Stage.allCases) { stage in
                        VibesWell(stage: stage, hot: board.hotStages.contains(stage), closed: board.vibesOptions.skips(stage))
                    }
                }
                // Sorted by id, which is to say in no order at all: an order
                // that doesn't depend on the column means a card that changes
                // column keeps its identity and flies rather than being
                // removed and inserted.
                ForEach(board.cards.sorted { $0.id.uuidString < $1.id.uuidString }) { card in
                    let place = placement(card, column: column, height: geo.size.height - 20)
                    VibesCardSlot(card: card, stamped: board.justShipped.contains(card.id))
                        .frame(width: column - 20, height: Self.cardHeight)
                        .rotationEffect(.degrees(tilt(card)))
                        .offset(x: place.x, y: place.y)
                        .zIndex(place.z)
                        // Under Reduce Motion a card still goes where it went, briefly.
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.4), value: card.stage)
                        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.4), value: place.y)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // Room for the HUD, which floats over the bottom of the board.
        .padding(.bottom, 72)
    }

    /// Where a card sits: over its column, stacked, and fanned when the column
    /// is too deep to stack.
    private func placement(_ card: Card, column: CGFloat, height: CGFloat) -> (x: CGFloat, y: CGFloat, z: Double) {
        let index = Stage.allCases.firstIndex(of: card.stage) ?? 0
        let stack = board.cards(in: card.stage)
        let k = stack.firstIndex { $0.id == card.id } ?? 0
        let span = max(192, height - Self.top - Self.cardHeight - 9)
        let step = stack.count <= 1 || CGFloat(stack.count - 1) * Self.step <= span
            ? Self.step
            : max(Self.minStep, span / CGFloat(stack.count - 1))
        return (CGFloat(index) * (column + Self.spacing) + 10, Self.top + CGFloat(k) * step, Double(k + 1))
    }

    /// Each card's own tilt, and a new one each time it lands somewhere new.
    private func tilt(_ card: Card) -> Double {
        (Vibe.hash(card.id.uuidString + card.stage.rawValue) - 0.5) * 8
    }
}

/// A well: in VIBES MODE the cards are an overlay above these.
private struct VibesWell: View {
    @EnvironmentObject var board: Board
    let stage: Stage
    let hot: Bool
    let closed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stage.label.uppercased())
                    .font(.mono(11, .medium))
                    .tracking(0.66)
                    .foregroundStyle(closed ? Theme.muted : .white)
                    .strikethrough(closed, color: Vibe.r1)
                    .modifier(ChromaticIf(on: !closed))
                Text("\(board.cards(in: stage).count)")
                    .font(.mono(11, .medium))
                    .tracking(0.66)
                    .foregroundStyle(Vibe.r3)
                Spacer()
                if stage == .backlog {
                    Button {
                        board.showingNewCard = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help("New card (⌘N)")
                }
                if stage == .release { CleanupButton(tint: .white) }
                if closed {
                    Text("SKIPPED")
                        .font(.mono(10, .bold))
                        .tracking(1)
                        .foregroundStyle(Vibe.black)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Vibe.r3))
                } else {
                    // Claude runs in every column it has not skipped.
                    SpinningDiamond(size: 8, spin: 0.9, colour: 1.2).help("Claude runs here")
                }
            }
            .padding(.horizontal, 4)
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(hot ? Color.white.opacity(0.07) : Color(hex: 0x0A0C12, opacity: 0.7))
                if closed { ClosedWell(stage: stage) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hot ? .white : closed ? Vibe.r3.opacity(0.35) : Color.white.opacity(0.12)))
        .shadow(color: hot ? Vibe.r1 : .clear, radius: 13)
        .animation(.easeOut(duration: 0.2), value: hot)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(closed ? "\(stage.label) is skipped in VIBES MODE" : stage.label)
    }
}

private struct ChromaticIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.chromatic() } else { content }
    }
}

/// A column condemned: Planning, Testing, or both, as the options say. Taped
/// off rather than removed, because a card sailing over a closed column says
/// where it did not stop better than a missing one could. The sign hangs at
/// the bottom, where nothing lands on it.
private struct ClosedWell: View {
    let stage: Stage
    @Environment(\.vibesStill) private var still

    private var copy: (tape: String, title: String, sub: String, est: String) {
        stage == .planning
            ? ("Do not plan · ", "Closed for thinking", "plans are for people with doubts", "est. 0 thoughts")
            : ("Do not test · ", "Closed for checking", "it compiled on someone’s machine", "est. 0 assertions")
    }

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            GeometryReader { geo in
                ZStack {
                    Stripes().fill(Vibe.r3.opacity(0.07))
                    tape(p: still ? 0 : Vibe.phase(context.date, 14), width: geo.size.width * 1.6)
                        .rotationEffect(.degrees(-16))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.38 + 11)
                    tape(p: still ? 0 : 1 - Vibe.phase(context.date, 18), width: geo.size.width * 1.6)
                        .rotationEffect(.degrees(12))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.38 + 29)
                    sign
                        .frame(width: min(208, geo.size.width - 24))
                        .rotationEffect(.degrees(-3 + 5 * (still ? 0.5 : Vibe.swing(context.date, 2.6))), anchor: UnitPoint(x: 0.5, y: -0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tape(p: Double, width: CGFloat) -> some View {
        let run = String(repeating: copy.tape, count: 8).uppercased()
        return ZStack(alignment: .leading) {
            Vibe.r3
            HStack(spacing: 0) {
                Text(run).fixedSize()
                Text(run).fixedSize()
            }
            .font(.mono(11, .bold))
            .tracking(1.54)
            .foregroundStyle(Vibe.black)
            .offset(x: -CGFloat(p) * 8 * 120)
        }
        .frame(width: width, height: 22)
        .clipped()
        .overlay(alignment: .top) { Rectangle().fill(Vibe.black).frame(height: 2) }
        .overlay(alignment: .bottom) { Rectangle().fill(Vibe.black).frame(height: 2) }
        .shadow(color: .black.opacity(0.6), radius: 7, y: 4)
    }

    private var sign: some View {
        VStack(spacing: 1) {
            Text(copy.title.uppercased())
                .font(.geist(15, .heavy))
                .foregroundStyle(.white)
                .chromatic()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(copy.sub).font(.geist(11).italic()).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            Text(copy.est).font(.mono(10)).tracking(0.6).foregroundStyle(Vibe.r3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0B0B12, opacity: 0.95)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Vibe.r1, lineWidth: 2))
        .shadow(color: Vibe.r1.opacity(0.8), radius: 9)
    }
}

private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width + rect.height {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + 14, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + 14 + rect.height, y: rect.minY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            p.closeSubpath()
            x += 28
        }
        return p
    }
}

/// One card, parked over its column: it slams down when it lands, idles with
/// a wobble on its own clock, and cycles through the rainbow.
private struct VibesCardSlot: View {
    @EnvironmentObject var board: Board
    let card: Card
    let stamped: Bool
    @Environment(\.vibesStill) private var still

    var body: some View {
        let delay = Vibe.hash(card.id.uuidString) * 2
        let left = Vibe.hash(card.id.uuidString + card.stage.rawValue) < 0.5
        TimelineView(.animation(paused: still)) { context in
            let w = still ? 0.5 : Vibe.swing(context.date, 1.1, delay: delay)
            CardFace(card: card, selected: card.id == board.selectedId, vibes: true, stamped: stamped)
                .hueRotation(.degrees(still || card.shippedAt != nil ? 0 : 360 * Vibe.phase(context.date, 1.8, delay: delay)))
                .rotationEffect(.degrees(-1.2 + 2.4 * w))
                .offset(y: -2 + 4 * w)
        }
        .keyframeAnimator(initialValue: Slam(), trigger: card.stage) { content, slam in
            content
                .scaleEffect(still ? 1 : slam.scale)
                .rotationEffect(.degrees(still ? 0 : left ? -slam.turn : slam.turn))
                .brightness(still ? 0 : slam.bright)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.45, duration: 0.01)
                SpringKeyframe(0.93, duration: 0.27)
                SpringKeyframe(1, duration: 0.22)
            }
            KeyframeTrack(\.turn) {
                CubicKeyframe(8, duration: 0.01)
                SpringKeyframe(-2, duration: 0.27)
                SpringKeyframe(0, duration: 0.22)
            }
            KeyframeTrack(\.bright) {
                CubicKeyframe(0.5, duration: 0.01)
                LinearKeyframe(0, duration: 0.27)
            }
        }
        .onTapGesture { board.select(card.id) }
        .contextMenu { CardMenu(card: card) }
    }

    private struct Slam {
        var scale = 1.0
        var turn = 0.0
        var bright = 0.0
    }
}
