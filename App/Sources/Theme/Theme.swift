import AppKit
import CoreText
import ReeveKit
import SwiftUI

/// Colours and type from the Reeve design system: a dark ink ground, Geist
/// for interface text and Geist Mono for data. The same values as the web
/// board's `index.css` tokens.
enum Theme {
    static let ink = Color(hex: 0x0E1116)
    static let panel = Color(hex: 0x161B22)
    static let cardCore = Color(hex: 0x0F1318)
    static let edge = Color(hex: 0x262D38)
    static let edgeStrong = Color(hex: 0x3F4754)
    static let muted = Color(hex: 0x8B949E)
    static let text = Color(hex: 0xE6EDF3)
    static let textSoft = Color(hex: 0xC9D1D9)

    static let sky200 = Color(hex: 0xB8E6FE)
    static let sky300 = Color(hex: 0x74D4FF)
    static let sky400 = Color(hex: 0x38BDF8)
    static let sky500 = Color(hex: 0x00A6F4)
    static let sky600 = Color(hex: 0x0084D1)
    static let sky700 = Color(hex: 0x0069A8)
    static let sky950 = Color(hex: 0x052F4A)
    static let slate500 = Color(hex: 0x62748E)
    static let slate300 = Color(hex: 0xCAD5E2)
    static let amber100 = Color(hex: 0xFEF3C6)

    /// Registers the bundled Geist fonts (SIL OFL) for this process.
    static func registerFonts() {
        for name in ["Geist", "GeistMono"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// The repo chip's colour: one of the board's lane hues, picked by the
    /// folder's name so a folder always wears the same one.
    static func folderColor(_ name: String) -> Color {
        let hues: [UInt32] = [0x38BDF8, 0xFBBF24, 0xFB923C, 0xA78BFA, 0xF87171, 0x818CF8, 0x34D399, 0xF472B6]
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $0 ^ $1.value }
        return Color(hex: hues[Int(hash % UInt32(hues.count))])
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }
}

/// Reeve's `label` style: Geist Mono, uppercase, tracked out, muted.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.mono(11, .medium))
            .tracking(0.66)
            .foregroundStyle(Theme.muted)
    }
}

// MARK: Activity glow

/// A card's sub-state, as light: colour rising from every border into a dark
/// centre. One tone per activity, as the web board's `.card-glow-*` classes.
enum GlowTone {
    case running, review, input, error

    init?(_ activity: Activity) {
        switch activity {
        case .idle: return nil
        case .running: self = .running
        case .needsReview: self = .review
        case .needsInput: self = .input
        case .error: self = .error
        }
    }

    /// The border, at 60%.
    var border: Color {
        switch self {
        case .running: Color(hex: 0x38BDF8, opacity: 0.6)
        case .review: Color(hex: 0x10B981, opacity: 0.6)
        case .input: Color(hex: 0xFBBF24, opacity: 0.6)
        case .error: Color(hex: 0xF87171, opacity: 0.6)
        }
    }

    /// The light itself: the flat tint and both shadows are made from it.
    var glow: Color {
        switch self {
        case .running: Color(hex: 0x00A6F4)
        case .review: Color(hex: 0x00BC7D)
        case .input: Color(hex: 0xFE9A00)
        case .error: Color(hex: 0xFB2C36)
        }
    }

    /// The mark's stroke, and the dot that stands for the state where there is no card.
    var mark: Color {
        switch self {
        case .running: Color(hex: 0x38BDF8)
        case .review: Color(hex: 0x34D399)
        case .input: Color(hex: 0xFBBF24)
        case .error: Color(hex: 0xF87171)
        }
    }

    var fill: Color { glow.opacity(0.12) }
}

/// The glow as a background: the dark core, the flat tint, a radial of the
/// core darkening the middle, light rising inward from the border, and a
/// little thrown outside it.
struct GlowBackground: View {
    let tone: GlowTone?
    var cornerRadius: CGFloat = 6
    var bloom: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if let tone {
            ZStack {
                shape.fill(Theme.cardCore)
                shape.fill(tone.fill)
                GeometryReader { geo in
                    shape.fill(EllipticalGradient(colors: [Theme.cardCore, Theme.cardCore.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.8))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                shape.strokeBorder(tone.glow.opacity(0.35), lineWidth: 8).blur(radius: 7).clipShape(shape)
                shape.strokeBorder(tone.glow.opacity(0.4), lineWidth: 2).blur(radius: 2).clipShape(shape)
                shape.strokeBorder(tone.border, lineWidth: 1)
            }
            .shadow(color: tone.glow.opacity(bloom ? 0.25 : 0.4), radius: bloom ? 24 : 6)
        } else {
            ZStack {
                shape.fill(Theme.panel)
                shape.strokeBorder(Theme.edge, lineWidth: 1)
            }
        }
    }
}

/// The second signal, so a state never rests on colour alone: a large outline
/// mark behind the card's content, faint enough to read through. Running has
/// none; it carries the rail instead.
struct ActivityMark: View {
    let tone: GlowTone
    var size: CGFloat = 68

    var body: some View {
        if tone != .running {
            MarkShape(tone: tone)
                .stroke(tone.mark, style: StrokeStyle(lineWidth: 2.5 * size / 24, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
                .shadow(color: tone.mark, radius: 1)
                .shadow(color: tone.mark, radius: 6)
                .opacity(0.3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The web board's marks, drawn on its 24-unit grid and scaled to fit.
private struct MarkShape: Shape {
    let tone: GlowTone

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch tone {
        case .review:
            p.move(to: CGPoint(x: 5, y: 12.5))
            p.addLine(to: CGPoint(x: 9.5, y: 17))
            p.addLine(to: CGPoint(x: 19, y: 7.5))
        case .input:
            p.move(to: CGPoint(x: 9, y: 9))
            p.addArc(center: CGPoint(x: 12, y: 9), radius: 3, startAngle: .degrees(180), endAngle: .degrees(60), clockwise: false)
            p.addCurve(to: CGPoint(x: 12, y: 13.8), control1: CGPoint(x: 12.6, y: 12.1), control2: CGPoint(x: 12, y: 12.8))
            p.addLine(to: CGPoint(x: 12, y: 15))
            p.move(to: CGPoint(x: 12, y: 18.5))
            p.addLine(to: CGPoint(x: 12, y: 18.51))
        case .error:
            p.move(to: CGPoint(x: 6.5, y: 6.5))
            p.addLine(to: CGPoint(x: 17.5, y: 17.5))
            p.move(to: CGPoint(x: 17.5, y: 6.5))
            p.addLine(to: CGPoint(x: 6.5, y: 17.5))
        case .running:
            break
        }
        let scale = min(rect.width, rect.height) / 24
        return p.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}

/// The only thing on a card that animates: a light travelling along the
/// bottom edge while Claude works.
struct RunningRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    var body: some View {
        GeometryReader { geo in
            let bar = geo.size.width * 0.4
            ZStack(alignment: .leading) {
                Rectangle().fill(GlowTone.running.glow.opacity(0.12))
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Theme.sky400, location: 0.5),
                        .init(color: Color(hex: 0xE0F2FE), location: 0.6),
                        .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(width: bar)
                    .shadow(color: Theme.sky400, radius: 4)
                    .offset(x: reduceMotion ? bar * 0.75 : (travelling ? bar * 2.5 : -bar))
            }
        }
        .frame(height: 2)
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { travelling = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(13, .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.sky600 : Theme.sky700))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(13))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.edge : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
            .contentShape(Rectangle())
    }
}

/// A 10px mono chip, as the card face's repo and status chips.
struct Chip: View {
    let text: String
    var color: Color = Theme.slate300
    var fill: Color = Theme.slate500.opacity(0.15)

    var body: some View {
        Text(text)
            .font(.mono(10))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
    }
}

/// The Reeve mark: the bar, the bowl and the diamond.
struct Glyph: View {
    var height: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            let s = size.height / 40
            context.scaleBy(x: s, y: s)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 11, height: 40), cornerRadius: 3), with: .color(Theme.text))
            var bowl = Path()
            bowl.move(to: CGPoint(x: 15, y: 0))
            bowl.addLine(to: CGPoint(x: 23, y: 0))
            bowl.addArc(center: CGPoint(x: 23, y: 11), radius: 11, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            bowl.addLine(to: CGPoint(x: 15, y: 22))
            bowl.closeSubpath()
            context.fill(bowl, with: .color(Theme.text))
            var diamond = Path()
            diamond.move(to: CGPoint(x: 26, y: 24))
            diamond.addLine(to: CGPoint(x: 34, y: 32))
            diamond.addLine(to: CGPoint(x: 26, y: 40))
            diamond.addLine(to: CGPoint(x: 18, y: 32))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(Theme.sky500))
        }
        .frame(width: height * 34 / 40, height: height)
        .accessibilityLabel("Reeve")
    }
}
