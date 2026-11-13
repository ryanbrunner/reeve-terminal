import AppKit
import CoreText
import SwiftUI

/// VIBES MODE's colours and motion, the web board's `vibes.css` in SwiftUI.
///
/// The rainbow is the whole point and it appears nowhere else in the product.
/// Nothing calm may use these.
enum Vibe {
    static let r1 = Color(hex: 0xFF2D95)
    static let r2 = Color(hex: 0xFF8A00)
    static let r3 = Color(hex: 0xFFE600)
    static let r4 = Color(hex: 0x2DFF7A)
    static let r5 = Color(hex: 0x00D1FF)
    static let r6 = Color(hex: 0x9B5CFF)
    static let rainbow = [r1, r2, r3, r4, r5, r6, r1]
    /// Darker than the calm board's ink: the lights need somewhere to be bright against.
    static let ground = Color(hex: 0x06070B)
    static let black = Color(hex: 0x0B0B10)

    /// How far through a loop of `period` seconds `date` is, 0..<1. A CSS
    /// delay of -d is `delay: d`: started d seconds ago.
    static func phase(_ date: Date, _ period: Double, delay: Double = 0) -> Double {
        let t = (date.timeIntervalSinceReferenceDate + delay) / period
        return t - t.rounded(.down)
    }

    /// An `alternate` ease-in-out loop: 0 → 1 → 0 over two periods.
    static func swing(_ date: Date, _ period: Double, delay: Double = 0) -> Double {
        let p = phase(date, period * 2, delay: delay) * 2
        let s = p < 1 ? p : 2 - p
        return s * s * (3 - 2 * s)
    }

    /// The rainbow's colour at `p` through it, as `sk-rainbowtext` steps through it.
    static func cycle(_ p: Double) -> Color {
        let stops: [UInt32] = [0xFF2D95, 0xFF8A00, 0xFFE600, 0x2DFF7A, 0x00D1FF, 0x9B5CFF, 0xFF2D95]
        let x = p * 6
        let i = min(Int(x), 5)
        let f = x - Double(i)
        func c(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
        let a = stops[i], b = stops[i + 1]
        return Color(.sRGB,
                     red: c(a, 16) + (c(b, 16) - c(a, 16)) * f,
                     green: c(a, 8) + (c(b, 8) - c(a, 8)) * f,
                     blue: c(a, 0) + (c(b, 0) - c(a, 0)) * f)
    }

    /// A small stable number for an id, so a card's wobble and tilt are its
    /// own without anything having to remember them.
    static func hash(_ s: String) -> Double {
        let h = s.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        return Double(h % 10_000) / 10_000
    }
}

/// Whether VIBES MODE should hold still: under Reduce Motion, and behind an
/// open card, where a window full of animation would make typing lag.
private struct VibesStillKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var vibesStill: Bool {
        get { self[VibesStillKey.self] }
        set { self[VibesStillKey.self] = newValue }
    }
}

/// The rainbow, flowing sideways: a gradient twice as wide as what it fills,
/// sliding by its own width, as `background-size: 200%` and `sk-flow` do.
struct FlowingRainbow: View {
    var period: Double = 2.4
    @Environment(\.vibesStill) private var still

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            GeometryReader { geo in
                let w = max(geo.size.width, 1) * 2
                let p = still ? 0 : Vibe.phase(context.date, period)
                HStack(spacing: 0) {
                    LinearGradient(colors: Vibe.rainbow, startPoint: .leading, endPoint: .trailing).frame(width: w)
                    LinearGradient(colors: Vibe.rainbow, startPoint: .leading, endPoint: .trailing).frame(width: w)
                }
                .offset(x: -w * p)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

extension View {
    /// Fills the view's own shape — text, most often — with the flowing rainbow.
    func rainbow(_ period: Double = 2.4) -> some View {
        opacity(0).overlay(FlowingRainbow(period: period).mask(self))
    }

    /// The chromatic split the web board gives its loud text: a magenta copy
    /// a pixel left, a cyan one a pixel right.
    func chromatic(_ x: CGFloat = 1, y: CGFloat = 0) -> some View {
        background {
            ZStack {
                // Multiplied rather than restyled: the copies keep whatever
                // colour the text was given, and white times magenta is magenta.
                self.colorMultiply(Vibe.r1).offset(x: -x)
                self.colorMultiply(Vibe.r5).offset(x: x, y: y)
            }
        }
    }

    /// A skew along x, about the view's centre, as CSS `skewX`.
    func skewX(_ degrees: Double, height: CGFloat) -> some View {
        let t = tan(degrees * .pi / 180)
        return transformEffect(CGAffineTransform(a: 1, b: 0, c: CGFloat(-t), d: 1, tx: CGFloat(t) * height / 2, ty: 0))
    }
}

/// The diamond: the board's mark for "Claude runs here", which in VIBES MODE
/// is everywhere.
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// A ◆ spinning through the rainbow, as the ticker and the column headers have it.
struct SpinningDiamond: View {
    var size: CGFloat = 8
    var spin: Double = 1.2
    var colour: Double = 1.4
    @Environment(\.vibesStill) private var still

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            Diamond()
                .fill(still ? Vibe.r1 : Vibe.cycle(Vibe.phase(context.date, colour)))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(still ? 0 : 360 * Vibe.phase(context.date, spin)))
        }
        .frame(width: size * 1.42, height: size * 1.42)
    }
}

/// Text as an outline, for the word walls behind the board: SwiftUI has no
/// text stroke, so the glyphs are turned into a path.
struct OutlinedText: Shape {
    let text: String
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(text, size: size))
    }

    /// The width the text takes, to lay copies end to end.
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        cgPath(text, size: size).boundingBoxOfPath.maxX
    }

    private static var cache: [String: CGPath] = [:]

    private static func cgPath(_ text: String, size: CGFloat) -> CGPath {
        let key = "\(size)|\(text)"
        if let path = cache[key] { return path }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: "Geist", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.heavy]])
        let font = NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: .heavy)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: -0.05 * size]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                // Core Text draws y-up; flip onto a y-down line `size` tall.
                let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: size * 0.82)
                path.addPath(glyphPath, transform: t)
            }
        }
        cache[key] = path
        return path
    }
}
