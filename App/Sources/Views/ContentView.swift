import ReeveKit
import SwiftUI

/// The window: the board, filling it. Opening a card lays its terminal over
/// the board; closing it goes back to the board and leaves the session running.
struct ContentView: View {
    @EnvironmentObject var board: Board
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// In VIBES MODE the lights go behind and in front of the stage, which
    /// jolts and shakes. The open card is a sibling of all of it, above the
    /// lights and outside every transform: anything that moved the terminal
    /// would resize its PTY.
    var body: some View {
        let vibes = board.vibes != nil
        ZStack {
            if vibes { VibesLightsBehind() }
            VStack(spacing: 0) {
                Header()
                CommandBarAnswerView()
                if vibes { VibesTicker(options: board.vibesOptions) }
                ZStack {
                    BoardView()
                    if board.cards.isEmpty, board.composing == nil, board.vibes == nil {
                        EmptyState()
                    }
                }
                .overlay(alignment: .bottom) {
                    if let ledger = board.vibes { VibesHud(ledger: ledger, beat: board.shipBeat) }
                }
            }
            .modifier(VibesStage(on: vibes, beat: board.shipBeat))
            if vibes { VibesLightsOver(beat: board.shipBeat) }
            if board.vibesArming { VibesArming(options: board.vibesOptions) }
            ZStack {
                if let card = board.selected {
                    CardModal(card: card)
                        .transition(.opacity)
                }
            }
            // Opacity only: the terminal's frame never animates, since every
            // size change resizes the PTY and makes `claude` redraw.
            .animation(.easeOut(duration: 0.15), value: board.selectedId)
        }
        .animation(.easeOut(duration: 0.2), value: board.vibesArming)
        .animation(.easeOut(duration: 0.15), value: board.commandBar.state)
        .environmentObject(board.commandBar)
        .background(vibes ? Vibe.ground : Theme.ink)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.vibesStill, reduceMotion || board.selectedId != nil)
        .sheet(isPresented: $board.showingArchive) {
            ArchiveView().environmentObject(board)
        }
        .preferredColorScheme(.dark)
    }
}

private struct Header: View {
    @EnvironmentObject var board: Board

    var body: some View {
        let vibes = board.vibes != nil
        HStack(spacing: 10) {
            Glyph(height: 18, vibes: vibes)
            Wordmark(vibes: vibes)
            Tallies()
                .padding(.leading, 8)
            Spacer(minLength: 16)
            CommandBarField()
            Spacer(minLength: 16)
            // What happened while you were not being asked. Said once, on the
            // way out, and then gone.
            if let toast = board.vibesToast {
                Text(toast)
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
            // Quiet until it is hovered: the one control here that changes
            // what Reeve is rather than what it shows.
            VibesSwitch(on: vibes) { board.toggleVibes() }
            Button(board.archive.isEmpty ? "Archive" : "Archive \(board.archive.count)") { board.showingArchive = true }
                .buttonStyle(SecondaryButtonStyle())
            Button("New Card") { board.compose() }
                .buttonStyle(PrimaryButtonStyle())
        }
        // Clear of the traffic lights, which sit over the header.
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 48)
        .background(vibes ? Vibe.ground.opacity(0.85) : .clear)
        .overlay(alignment: .bottom) {
            if vibes {
                FlowingRainbow(period: 1.4).frame(height: 2).shadow(color: Vibe.r1, radius: 7).offset(y: 1)
            } else {
                Rectangle().fill(Theme.edge).frame(height: 1)
            }
        }
        .zIndex(1)
        .animation(.easeOut(duration: 0.35), value: board.vibesToast)
    }
}

/// "Reeve", which in VIBES MODE splits into its colours now and then.
private struct Wordmark: View {
    let vibes: Bool
    @Environment(\.vibesStill) private var still

    var body: some View {
        TimelineView(.animation(paused: !vibes || still)) { context in
            let (pink, cyan) = vibes && !still ? split(Vibe.phase(context.date, 1.3)) : (.zero, .zero)
            ZStack {
                if pink != .zero {
                    text.foregroundStyle(Vibe.r1).offset(pink)
                    text.foregroundStyle(Vibe.r5).offset(cyan)
                }
                text.foregroundStyle(Theme.text)
            }
        }
    }

    private var text: some View {
        Text("Reeve").font(.geist(16, .semibold)).tracking(-0.32)
    }

    /// `sk-rgbsplit`: still most of the time, with two short faults.
    private func split(_ p: Double) -> (CGSize, CGSize) {
        switch p {
        case 0.08..<0.14: (CGSize(width: -2, height: 0), CGSize(width: 2, height: 0))
        case 0.46..<0.52: (CGSize(width: 3, height: 0), CGSize(width: -3, height: 1))
        case 0.52..<0.60: (CGSize(width: -1, height: 0), CGSize(width: 1, height: 0))
        default: (.zero, .zero)
        }
    }
}

/// The stage's two motions: a glitch on its own clock, and a jump each time
/// something ships. Only in VIBES MODE, where the board is a different tree
/// anyway: a repeating animator costs a frame every frame, even at nothing.
private struct VibesStage: ViewModifier {
    let on: Bool
    let beat: Int

    func body(content: Content) -> some View {
        if on {
            content.modifier(VibesMotion(beat: beat))
        } else {
            content
        }
    }
}

private struct VibesMotion: ViewModifier {
    let beat: Int
    @Environment(\.vibesStill) private var still

    func body(content: Content) -> some View {
        // `sk-jolt`: mostly still, with two hard glitches per 3.4 seconds.
        // The stillness is what makes them read as faults. Paused, not just
        // zeroed, behind an open card and under Reduce Motion.
        TimelineView(.animation(paused: still)) { context in
            let j = still ? Jolt() : Jolt(Vibe.phase(context.date, 3.4))
            content
                .modifier(Skew(degrees: j.skew))
                .offset(x: j.x, y: j.y)
                .scaleEffect(x: 1, y: j.stretch)
                .hueRotation(.degrees(j.hue))
        }
        // `sk-shake`: the board jumps when something ships.
        .keyframeAnimator(initialValue: CGSize.zero, trigger: beat) { view, shake in
            view.offset(still ? .zero : shake)
        } keyframes: { _ in
            let s = beat % 2 == 0 ? 1.0 : -1.0
            KeyframeTrack {
                LinearKeyframe(CGSize(width: -7 * s, height: 3 * s), duration: 0.042)
                LinearKeyframe(CGSize(width: 6 * s, height: -4 * s), duration: 0.042)
                LinearKeyframe(CGSize(width: -5 * s, height: -2 * s), duration: 0.042)
                LinearKeyframe(CGSize(width: 4 * s, height: 4 * s), duration: 0.042)
                LinearKeyframe(CGSize(width: -2 * s, height: 1 * s), duration: 0.063)
                LinearKeyframe(CGSize(width: 2 * s, height: -1 * s), duration: 0.063)
                LinearKeyframe(.zero, duration: 0.126)
            }
        }
    }
}

/// Where `sk-jolt` has the stage at `p` through its loop: still, but for the
/// two faults, run through between their keyframes.
private struct Jolt {
    var x = 0.0, y = 0.0, skew = 0.0, hue = 0.0, stretch = 1.0

    init() {}

    init(_ p: Double) {
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        switch p {
        case 0.31..<0.316:
            let t = (p - 0.31) / 0.006
            (x, skew, hue) = (mix(0, -9, t), mix(0, 7, t), mix(0, 90, t))
        case 0.316..<0.326:
            let t = (p - 0.316) / 0.01
            (x, skew, hue) = (mix(-9, 6, t), mix(7, -4, t), mix(90, -40, t))
        case 0.326..<0.335:
            let t = (p - 0.326) / 0.009
            (x, skew, hue) = (mix(6, 0, t), mix(-4, 0, t), mix(-40, 0, t))
        case 0.72..<0.725:
            let t = (p - 0.72) / 0.005
            (y, stretch, hue) = (mix(0, 3, t), mix(1, 1.015, t), mix(0, -70, t))
        case 0.725..<0.735:
            let t = (p - 0.725) / 0.01
            (y, stretch, hue) = (mix(3, 0, t), mix(1.015, 1, t), mix(-70, 0, t))
        default:
            break
        }
    }
}

/// A skew along x about the view's middle, as CSS `skewX`.
private struct Skew: GeometryEffect {
    var degrees: Double

    var animatableData: Double {
        get { degrees }
        set { degrees = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = tan(degrees * .pi / 180)
        return ProjectionTransform(CGAffineTransform(a: 1, b: 0, c: CGFloat(t), d: 1, tx: -CGFloat(t) * size.height / 2, ty: 0))
    }
}

/// A dot and a count for each card waiting on someone or working, most
/// urgent first — what a hidden board would otherwise hide.
private struct Tallies: View {
    @EnvironmentObject var board: Board

    var body: some View {
        HStack(spacing: 12) {
            ForEach([(Activity.needsInput, "Needs your answer"), (.needsReview, "Ready for review"), (.error, "Error"), (.running, "Claude running"), (.waiting, "Waiting on shells")], id: \.0) { activity, label in
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
