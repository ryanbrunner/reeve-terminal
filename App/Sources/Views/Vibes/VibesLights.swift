import SwiftUI

/// The rig.
///
/// Two layers, and which side of the board they fall on is the whole design.
/// Behind: the word walls and the stage lights, which the columns' own
/// translucent fill lets through. In front: the roaming spots, the scanlines
/// and the glitch bars, which land on the cards, because a light that never
/// touches what it is lighting reads as wallpaper.
///
/// All of it is decorative and inert to the pointer, and holds still under
/// Reduce Motion and behind an open card. The board underneath keeps working.
struct VibesLightsBehind: View {
    @Environment(\.vibesStill) private var still

    private struct Beam {
        let x: Double, colour: UInt32, a: Double, b: Double, period: Double, delay: Double
        var top = false
    }

    private let beams = [
        Beam(x: 0.07, colour: 0xFF2D95, a: -38, b: 22, period: 3.2, delay: 0.4),
        Beam(x: 0.27, colour: 0x00D1FF, a: 30, b: -26, period: 2.6, delay: 1.1),
        Beam(x: 0.50, colour: 0xFFE600, a: -24, b: 26, period: 3.8, delay: 2),
        Beam(x: 0.72, colour: 0x2DFF7A, a: 34, b: -18, period: 2.9, delay: 0.7),
        Beam(x: 0.93, colour: 0x9B5CFF, a: -30, b: 36, period: 3.4, delay: 1.6),
        Beam(x: 0.17, colour: 0xFF8A00, a: -28, b: 18, period: 4.2, delay: 1, top: true),
        Beam(x: 0.83, colour: 0x00D1FF, a: 26, b: -30, period: 3.6, delay: 2.4, top: true),
    ]

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let now = context.date
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Counter-scrolling, at different speeds, so the two never line up.
                    WordWall(text: "VIBES MODE ◆ VIBES MODE ◆ ", opacity: 0.09, p: still ? 0 : Vibe.phase(now, 34))
                        .offset(y: geo.size.height * 0.21)
                    WordWall(text: "NO HUMAN ◆ NO HUMAN ◆ NO HUMAN ◆ ", opacity: 0.063, p: still ? 0 : 1 - Vibe.phase(now, 26))
                        .offset(y: geo.size.height * 0.58)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(beams.enumerated()), id: \.offset) { _, beam in
                            let s = still ? 0.5 : Vibe.swing(now, beam.period, delay: beam.delay)
                            BeamView(colour: Color(hex: beam.colour), top: beam.top)
                                .rotationEffect(.degrees(beam.a + (beam.b - beam.a) * s), anchor: beam.top ? .top : .bottom)
                                .position(x: geo.size.width * beam.x, y: beam.top ? 1150 / 2 - 60 : geo.size.height + 60 - 1150 / 2)
                        }
                    }
                    .compositingGroup()
                    .hueRotation(.degrees(still ? 0 : 360 * Vibe.phase(now, 7)))
                    .blendMode(.screen)
                    roamer(0xFF2D95, from: (-120, 520), to: (760, 380), period: 5.5, delay: 1, now: now)
                    roamer(0x00D1FF, from: (900, 80), to: (120, 300), period: 6.5, delay: 3, now: now)
                    roamer(0xFFE600, from: (400, 600), to: (1000, 560), period: 4.8, delay: 2, now: now)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A soft pool of colour drifting from one place to another.
    private func roamer(_ colour: UInt32, from: (Double, Double), to: (Double, Double), period: Double, delay: Double, now: Date) -> some View {
        let s = still ? 0 : Vibe.swing(now, period, delay: delay)
        return Ellipse()
            .fill(RadialGradient(colors: [Color(hex: colour), .clear], center: .center, startRadius: 0, endRadius: 220))
            .frame(width: 680, height: 440)
            .opacity(0.3)
            .offset(x: from.0 + (to.0 - from.0) * s, y: from.1 + (to.1 - from.1) * s)
    }
}

/// A wall of outlined words, far enough back to read as texture.
private struct WordWall: View {
    let text: String
    let opacity: Double
    let p: Double

    var body: some View {
        let width = OutlinedText.width(text, size: 220)
        HStack(spacing: 0) {
            OutlinedText(text: text, size: 220).stroke(Color.white.opacity(opacity), lineWidth: 1.5).frame(width: width, height: 220)
            OutlinedText(text: text, size: 220).stroke(Color.white.opacity(opacity), lineWidth: 1.5).frame(width: width, height: 220)
        }
        .fixedSize()
        .offset(x: -width * p)
    }
}

/// A stage light: a narrow wedge of colour from a point, fading out along its
/// length, with a hot lens at the root.
private struct BeamView: View {
    let colour: Color
    let top: Bool

    var body: some View {
        // Pointing up from the bottom: a wedge 22° wide around straight up.
        let up = top ? 90.0 : -90.0
        ZStack {
            Rectangle()
                .fill(AngularGradient(
                    colors: [.clear, colour, .clear],
                    center: top ? .top : .bottom,
                    startAngle: .degrees(up - 11),
                    endAngle: .degrees(up + 11)
                ))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.08), .init(color: .clear, location: 0.92)],
                                     startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top))
                .opacity(0.5)
            Ellipse()
                .fill(RadialGradient(stops: [.init(color: .white, location: 0), .init(color: colour, location: 0.45), .init(color: .clear, location: 1)],
                                     center: .center, startRadius: 0, endRadius: 50))
                .frame(width: 140, height: 48)
                .frame(maxHeight: .infinity, alignment: top ? .top : .bottom)
                .padding(top ? .top : .bottom, 36)
                .opacity(0.5)
        }
        .frame(width: 1100, height: 1150)
    }
}

struct VibesLightsOver: View {
    /// Raised on every ship: one frame of blown-out colour.
    let beat: Int
    @Environment(\.vibesStill) private var still
    @State private var flash = 0.0

    private struct Glitch {
        let top: CGFloat, height: CGFloat, colour: UInt32, period: Double, delay: Double
    }

    private let glitches = [
        Glitch(top: 140, height: 14, colour: 0x00D1FF, period: 2.3, delay: 0.3),
        Glitch(top: 420, height: 6, colour: 0xFF2D95, period: 3.1, delay: 1.2),
        Glitch(top: 610, height: 28, colour: 0xFFE600, period: 4.3, delay: 2.1),
        Glitch(top: 300, height: 3, colour: 0xFFFFFF, period: 1.7, delay: 0.9),
    ]

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let now = context.date
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    spot(0xFF2D95, from: (-100, 120), to: (1100, 420), period: 3.8, delay: 1.2, now: now)
                    spot(0x00D1FF, from: (1200, 500), to: (80, 80), period: 4.6, delay: 2.8, now: now)
                    spot(0xFFE600, from: (500, -120), to: (700, 560), period: 3.1, delay: 0.5, now: now)
                    Scanlines()
                    // One bright band rolling down the scanlines.
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.05), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                        .offset(y: -140 + (geo.size.height + 140) * (still ? 0.3 : Vibe.phase(now, 4)))
                    if !still {
                        ForEach(Array(glitches.enumerated()), id: \.offset) { _, g in
                            let (opacity, dx, dy, sx) = glitch(Vibe.phase(now, g.period, delay: g.delay))
                            Rectangle()
                                .fill(Color(hex: g.colour))
                                .frame(width: geo.size.width, height: g.height)
                                .scaleEffect(x: sx, y: 1)
                                .offset(x: dx, y: g.top + dy)
                                .opacity(opacity)
                                .blendMode(.difference)
                        }
                    }
                }
            }
        }
        .overlay {
            RadialGradient(stops: [.init(color: .white, location: 0), .init(color: beat % 2 == 0 ? Vibe.r5 : Vibe.r1, location: 0.35), .init(color: .clear, location: 0.72)],
                           center: UnitPoint(x: 0.5, y: 0.55), startRadius: 0, endRadius: 700)
                .blendMode(.screen)
                .opacity(flash)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: beat) {
            guard !still else { return }
            flash = 0.26
            withAnimation(.easeOut(duration: 0.5)) { flash = 0 }
        }
    }

    private func spot(_ colour: UInt32, from: (Double, Double), to: (Double, Double), period: Double, delay: Double, now: Date) -> some View {
        let s = still ? 0 : Vibe.swing(now, period, delay: delay)
        return Circle()
            .fill(RadialGradient(colors: [Color(hex: colour), .clear], center: .center, startRadius: 0, endRadius: 230))
            .frame(width: 460, height: 460)
            .opacity(0.2)
            .blendMode(.screen)
            .offset(x: from.0 + (to.0 - from.0) * s, y: from.1 + (to.1 - from.1) * s)
    }

    /// `sk-gl`: mostly nothing, with two hard faults per cycle.
    private func glitch(_ p: Double) -> (Double, CGFloat, CGFloat, CGFloat) {
        switch p {
        case 0.21..<0.23: (0.85, -40, 0, 1.1)
        case 0.23..<0.25: (0.5, 30, 60, 1)
        case 0.67..<0.685: (0.7, 20, -90, 1)
        default: (0, 0, 0, 1)
        }
    }
}

/// A dark line every third pixel.
private struct Scanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 2
            var path = Path()
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(path, with: .color(.black.opacity(0.19)))
        }
    }
}
