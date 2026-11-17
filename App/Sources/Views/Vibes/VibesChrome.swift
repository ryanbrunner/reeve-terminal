import ReeveKit
import SwiftUI

/// The switch.
///
/// Off it is the quietest control in the header — a mono label and a grey
/// diamond. Hover is the only warning: the label takes the rainbow before
/// anything else does. On, it is the loudest thing on the screen, because
/// everything it turns off is a thing that was protecting you.
///
/// Also a card's own switch, which is why the words can be handed in.
struct VibesSwitch: View {
    let on: Bool
    var label = "Vibes mode"
    var help: String?
    let toggle: () -> Void
    @State private var hovering = false
    @Environment(\.vibesStill) private var still
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                track
                Text(label.uppercased())
                    .font(.mono(11, .medium))
                    .tracking(on ? 1.32 : 0.66)
                    .foregroundStyle(on ? .white : hovering ? Theme.text : Theme.muted)
                    .modifier(RainbowIf(on: on || (hovering && enabled), period: on ? 1 : 2.4))
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background {
                if on {
                    TimelineView(.animation(paused: still)) { context in
                        let p = still ? 0 : Vibe.swing(context.date, 1.1)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: 0x0B0B12))
                            .shadow(color: (p < 0.5 ? Vibe.r1 : Vibe.r5).opacity(0.8), radius: 8 + 2 * p)
                    }
                }
            }
            .overlay {
                if on {
                    FlowingRainbow(period: 1.1).mask(RoundedRectangle(cornerRadius: 6).strokeBorder(lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(hovering && enabled ? Color(hex: 0x45556C) : Theme.edge)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? (on ? "Put the human back in the loop" : "Turn off every guardrail. Claude plans, answers and ships without you"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var track: some View {
        ZStack(alignment: .leading) {
            if on {
                FlowingRainbow(period: 0.8)
            } else {
                Theme.ink
            }
            TimelineView(.animation(paused: still || !on)) { context in
                Rectangle()
                    .fill(on || hovering ? Color.white : Theme.muted)
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45 + (on && !still ? 360 * Vibe.phase(context.date, 0.8) : 0)))
                    .shadow(color: on ? .white : .clear, radius: 3)
                    .shadow(color: on ? Vibe.r1 : .clear, radius: 5)
            }
            .frame(width: 10, height: 10)
            .offset(x: on ? 16.5 : 2.5)
            .animation(.spring(duration: 0.3, bounce: 0.5), value: on)
        }
        .frame(width: 30, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .clear : Theme.edge))
    }
}

private struct RainbowIf: ViewModifier {
    let on: Bool
    let period: Double

    func body(content: Content) -> some View {
        if on { content.rainbow(period) } else { content }
    }
}

/// The strip under the header: what VIBES MODE is doing, and what it has
/// crossed out. A list of things that are on would read as a feature list; a
/// list with "planning", "code review" and "guardrails" scored out in magenta
/// reads as what it is.
struct VibesTicker: View {
    let options: VibesOptions
    @Environment(\.vibesStill) private var still
    @State private var runWidth: CGFloat = 1
    @State private var arrived = false

    private var words: [(String, Bool)] {
        var list: [(String, Bool)] = [("No human in the loop", false)]
        list.append(options.autoMerge ? ("Auto-merging to main", false) : ("Merging", true))
        list += options.skipPlanning ? [("Planning", true), ("Plan: none. Vibes: immaculate", false)] : [("Plans approved unread", false)]
        list.append(("Code review", true))
        list.append(options.skipTesting ? ("Testing", true) : ("Tests: vibes", false))
        list += [
            ("Backlog → Release, no stops", false),
            ("Claude answered its own question", false),
            ("Guardrails", true),
            ("You are a spectator now", false),
            ("Staging", true),
            ("Ship it ship it ship it", false),
        ]
        return list
    }

    var body: some View {
        // An overlay on a strip of its own, so the run, many screens wide,
        // never widens what it sits in.
        Color.black
            .frame(height: 30)
            .overlay(alignment: .leading) {
                TimelineView(.animation(paused: still)) { context in
                    // Twice, because the run scrolls by exactly half its own
                    // width: at the wrap the second copy is where the first was.
                    HStack(spacing: 0) {
                        // Measured again when the options change the words.
                        run.background(GeometryReader { geo in
                            Color.clear
                                .onAppear { runWidth = geo.size.width }
                                .onChange(of: geo.size.width) { runWidth = geo.size.width }
                        })
                        run
                    }
                    .fixedSize()
                    .offset(x: still ? 0 : -runWidth * Vibe.phase(context.date, 20))
                }
            }
            .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }
        .offset(y: arrived ? 0 : -30)
        .opacity(arrived ? 1 : 0)
        .onAppear { withAnimation(still ? nil : .spring(duration: 0.4, bounce: 0.4)) { arrived = true } }
        .accessibilityHidden(true)
    }

    private var run: some View {
        HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                HStack(spacing: 14) {
                    SpinningDiamond(size: 7)
                    Text(word.0.uppercased())
                        .font(.mono(11, .medium))
                        .tracking(1.76)
                        .foregroundStyle(word.1 ? Theme.muted : .white)
                        .strikethrough(word.1, color: Vibe.r1)
                }
                .padding(.trailing, 28)
            }
        }
    }
}

/// Two seconds of arming, spent naming every guardrail that is coming off.
///
/// The only confirmation VIBES MODE has, and deliberately not a dialog: the
/// switch is its own undo, and an "are you sure?" would be a safeguard, which
/// is the one thing this is against. It says what you just did, in words,
/// while it is happening.
struct VibesArming: View {
    let options: VibesOptions
    @State private var shown = 0
    @State private var slam = false
    @Environment(\.vibesStill) private var still

    private var rows: [(String, String)] {
        [
            ("Human review", "off"),
            ("Stage gates", "off"),
            ("Planning", options.skipPlanning ? "skipped" : "approved unread"),
            ("Testing", options.skipTesting ? "skipped" : "approved unread"),
            ("Merge to main", options.autoMerge ? "automatic" : "yours (left open)"),
            ("Merge conflicts", "Claude resolves"),
            ("Questions", "Claude answers"),
            ("New ideas", "run on arrival"),
            ("Tool permissions", "still yours"),
            ("You", "watching"),
        ]
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(max(64, geo.size.width * 0.12), 176)
            VStack(spacing: 22) {
                title(size: size)
                Text("Taking the human out of the loop…".uppercased())
                    .font(.mono(13))
                    .tracking(3.12)
                    .foregroundStyle(.white)
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.0).foregroundStyle(Theme.muted)
                            Line()
                                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                                .frame(height: 1)
                            Text(row.1.uppercased()).fontWeight(.medium).tracking(1.3).rainbow(1)
                        }
                        .font(.mono(13))
                        .opacity(i < shown ? 1 : 0)
                        .offset(x: i < shown ? 0 : -24)
                    }
                }
                .frame(width: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RadialGradient(colors: [Vibe.ground.opacity(0.6), Vibe.ground.opacity(0.95)], center: .center, startRadius: 0, endRadius: 700))
        .allowsHitTesting(false)
        .transition(.opacity)
        .onAppear(perform: play)
        .accessibilityElement(children: .combine)
    }

    /// Three copies of the same words, stacked and offset: white, magenta, cyan.
    private func title(size: CGFloat) -> some View {
        TimelineView(.animation(paused: still)) { context in
            let a = still ? 0 : Int(Vibe.phase(context.date, 0.24) * 2)
            let b = still ? 0 : Int(Vibe.phase(context.date, 0.3) * 2)
            ZStack {
                word(size).foregroundStyle(Vibe.r1).blendMode(.screen).offset(x: a == 0 ? -7 : -3, y: a == 0 ? 2 : -3)
                word(size).foregroundStyle(Vibe.r5).blendMode(.screen).offset(x: b == 0 ? 7 : 4, y: b == 0 ? -2 : 3)
                word(size).foregroundStyle(.white)
            }
            .compositingGroup()
        }
        .skewX(-8, height: size)
        .scaleEffect(slam ? 1 : 3.2)
        .blur(radius: slam ? 0 : 12)
        .opacity(slam ? 1 : 0)
    }

    private func word(_ size: CGFloat) -> some View {
        Text("VIBES MODE")
            .font(.geist(size, .heavy))
            .tracking(-0.05 * size)
            .lineLimit(1)
            .fixedSize()
    }

    private func play() {
        guard !still else {
            slam = true
            shown = rows.count
            return
        }
        withAnimation(.spring(duration: 0.7, bounce: 0.45)) { slam = true }
        for i in rows.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 + 0.14 * Double(i)) {
                withAnimation(.easeOut(duration: 0.25)) { shown = i + 1 }
            }
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// The scoreboard along the bottom: six numbers and a running log of what
/// Claude has done to your repositories since you stopped being asked.
///
/// Human input is the one that matters, and it is the only still number here:
/// a plain white nought while every other figure churns through the rainbow.
struct VibesHud: View {
    let ledger: VibesLedger
    let beat: Int
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Stat(label: "Merged to main", value: ledger.merged, beat: beat)
            Stat(label: "Human input", value: ledger.humanApprovals)
            Stat(label: "Reviews skipped", value: ledger.reviewsSkipped)
            Stat(label: "Questions self-answered", value: ledger.questionsSelfAnswered)
            Stat(label: "Moves", value: ledger.moves)
            Stat(label: "Ideas of its own", value: ledger.ideas ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                // Two deep: the newest in white, the one before it faded.
                ForEach(Array(ledger.log.prefix(2).enumerated()), id: \.offset) { i, line in
                    (Text("◆ ").foregroundColor(Vibe.r1) + Text(line).foregroundColor(i == 0 ? .white : Theme.muted))
                        .font(.mono(11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 60)
        .background(Vibe.ground.opacity(0.88))
        .overlay(alignment: .top) { FlowingRainbow(period: 1.4).frame(height: 2) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.14)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .offset(y: arrived ? 0 : 80)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.45)) { arrived = true } }
    }

    private struct Stat: View {
        let label: String
        let value: Int
        var beat = 0
        @State private var popped = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.mono(10, .medium))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                Group {
                    if value == 0 {
                        // Nothing to celebrate: a plain white nought.
                        Text("0").foregroundStyle(.white)
                    } else {
                        Text("\(value)").rainbow(2.2)
                    }
                }
                .font(.geist(24, .semibold))
                .monospacedDigit()
                .scaleEffect(popped ? 1.5 : 1, anchor: .leading)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: beat) {
                guard !reduceMotion else { return }
                popped = true
                withAnimation(.spring(duration: 0.45, bounce: 0.5)) { popped = false }
            }
        }
    }
}
