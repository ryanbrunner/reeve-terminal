import ReeveKit
import SwiftUI

/// A card on the board: its title, what it is waiting on or where it stands,
/// and its folder, wearing its activity as light.
struct CardFace: View {
    @EnvironmentObject var board: Board
    let card: Card
    var selected = false
    var dragging = false
    /// The card as VIBES MODE wears it: a fixed size so it can fly between
    /// columns, and one chip naming the guardrail its column is not applying.
    var vibes = false
    /// Just shipped. The stamp slams on for a couple of seconds and goes.
    var stamped = false

    /// In VIBES MODE on its own, on the calm board. Not once shipped: after
    /// that there is nothing left for it to do.
    private var solo: Bool {
        !vibes && card.vibes == true && card.shippedAt == nil
    }

    /// Landed, louder than any other state: nobody put it there.
    private var shipped: Bool {
        vibes && card.shippedAt != nil
    }

    var body: some View {
        let tone = shipped ? nil : GlowTone(card.activity)
        VStack(alignment: .leading, spacing: 6) {
            Text(board.displayTitle(card))
                .font(.geist(13, .medium))
                .tracking(-0.13)
                .foregroundStyle(card.title.isEmpty ? Theme.text.opacity(0.7) : Theme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: vibes ? 38.5 : nil, alignment: .topLeading)
            if vibes {
                Spacer(minLength: 0)
            } else if let waiting = card.waitingOn {
                // What Claude is waiting on, so a waiting card says why without being opened.
                Text(waiting)
                    .font(.geist(12))
                    .foregroundStyle(Theme.amber100.opacity(0.85))
                    .lineLimit(2)
            } else if let summary = card.summary {
                Text(summary)
                    .font(.mono(11))
                    .foregroundStyle(card.activity == .running ? Theme.sky200.opacity(0.7) : Theme.muted)
                    .lineLimit(2)
            }
            footer
        }
        .padding(10)
        .frame(height: vibes ? VibesBoardView.cardHeight : nil)
        .background {
            ZStack {
                if shipped {
                    ShippedBackground()
                } else {
                    GlowBackground(tone: tone)
                }
                if let tone { ActivityMark(tone: tone, spins: vibes) }
            }
        }
        .overlay(alignment: .bottom) {
            if card.activity == .running {
                RunningRail(vibes: vibes).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .overlay {
            // The ring dresses the card, just inside its border, so the
            // activity's own colours still say what it is doing.
            if solo {
                FlowingRainbow(period: 2.4).mask(RoundedRectangle(cornerRadius: 6).strokeBorder(lineWidth: 2))
            }
        }
        .overlay(alignment: .topTrailing) {
            if stamped { ShippedStamp(merged: card.merged == true) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // The open card is ringed, the way the web board rings a traced
        // dependency: an outline, so the activity's border keeps its colour.
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.sky400, lineWidth: 1.5).padding(-3)
            }
        }
        .rotationEffect(.degrees(dragging ? 2 : 0))
        .shadow(color: .black.opacity(dragging ? 0.4 : 0), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(board.displayTitle(card)), \(label)")
    }

    @ViewBuilder
    private var footer: some View {
        if vibes {
            HStack(spacing: 6) {
                Text(Vibes.chip(stage: card.stage, activity: card.activity, shipped: card.shippedAt != nil, merged: card.merged == true, options: board.vibesOptions))
                    .font(.mono(10))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.25)))
                Text(card.folderName).font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
            }
        } else {
            calmFooter
        }
    }

    private var calmFooter: some View {
        HStack(spacing: 6) {
            if solo { SoloChip() }
            Chip(text: card.folderName, color: Theme.folderColor(card.folderName), fill: Theme.folderColor(card.folderName).opacity(0.2))
            if board.classifying.contains(card.id) {
                Chip(text: "sorting…", color: Theme.sky300, fill: Theme.sky500.opacity(0.15))
            } else if board.classifyErrors[card.id] != nil {
                Chip(text: "unsorted", color: Theme.muted)
            }
            if !board.live.contains(card.id) {
                Chip(text: card.hasConversation ? "asleep" : "not started")
            }
            if card.stagePinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.muted)
                    .help("You put this card here. It stays until you next prompt Claude.")
            }
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        if shipped { return "shipped by VIBES MODE" }
        return switch card.activity {
        case .idle: "idle"
        case .running: "Claude running"
        case .needsReview: "ready for review"
        case .needsInput: "needs your answer"
        case .error: "error"
        }
    }

    private var help: String {
        var lines = [board.displayTitle(card), card.cwd]
        if let error = board.classifyErrors[card.id] { lines.append("Couldn't sort: \(error)") }
        return lines.joined(separator: "\n")
    }
}

/// Names why a card wears the rainbow ring, so it is not left to colour alone.
struct SoloChip: View {
    var body: some View {
        Text("vibes")
            .font(.mono(10, .semibold))
            .rainbow(2.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
            .overlay(FlowingRainbow(period: 2.4).mask(RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1)))
            .help("In VIBES MODE: Claude approves, answers and ships this card with nobody reviewing it")
    }
}

/// Landed with nobody watching: built like the calm glows, in magenta, and
/// without their mark.
private struct ShippedBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        ZStack {
            shape.fill(Theme.cardCore)
            shape.fill(Vibe.r1.opacity(0.15))
            GeometryReader { geo in
                shape.fill(EllipticalGradient(colors: [Theme.cardCore, Theme.cardCore.opacity(0)], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.8))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            shape.strokeBorder(Vibe.r1.opacity(0.4), lineWidth: 8).blur(radius: 7).clipShape(shape)
            shape.strokeBorder(Vibe.r1.opacity(0.47), lineWidth: 2).blur(radius: 2).clipShape(shape)
            shape.strokeBorder(Vibe.r1.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: Vibe.r1.opacity(0.6), radius: 10)
    }
}

/// Slammed on when the card ships, and gone a few seconds later.
private struct ShippedStamp: View {
    let merged: Bool
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(merged ? "MERGED" : "SHIPPED")
            .font(.mono(13, .medium))
            .tracking(2.34)
            .foregroundStyle(.white)
            .shadow(color: Vibe.r1, radius: 4)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2))
            .shadow(color: Vibe.r1, radius: 7)
            .rotationEffect(.degrees(-14))
            .scaleEffect(landed ? 1 : 3)
            .opacity(landed ? 1 : 0)
            .padding(.top, 30)
            .padding(.trailing, 10)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.5)) { landed = true } }
            .allowsHitTesting(false)
    }
}
