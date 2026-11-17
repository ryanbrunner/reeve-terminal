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

    /// The card it waits on, while that one hasn't merged.
    private var blocker: Card? {
        board.blocker(of: card.id)
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
            } else if card.queued == true, board.launching.contains(card.id) || card.stage != .backlog {
                // The footer already says it hasn't started.
                Text(board.launching.contains(card.id) ? "Making its worktree…" : "Move to Planning or In Progress to start")
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted.opacity(0.8))
                    .lineLimit(2)
            } else if let line = card.backgroundLine {
                // Waiting on its own shells: nothing for you to do yet.
                Text(line)
                    .font(.geist(12))
                    .foregroundStyle(Theme.indigo200.opacity(0.85))
                    .lineLimit(1)
                if let tasks = card.background, !tasks.isEmpty {
                    backgroundChips(tasks)
                }
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
            if !vibes, let blocker {
                // What it waits on, so a card that won't start says why without being opened.
                Label("Waits on “\(board.displayTitle(blocker))” · \(Dependency.status(of: blocker))", systemImage: "arrow.turn.down.right")
                    .font(.geist(12))
                    .foregroundStyle(Theme.amber100.opacity(0.85))
                    .lineLimit(2)
            }
            footer
            if !vibes, card.pullRequest?.state == .open, let error = board.mergeErrors[card.id] {
                Text(error)
                    .font(.mono(10))
                    .foregroundStyle(Color(hex: 0xFCA5A5))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .help(error)
            }
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
        .accessibilityLabel([board.displayTitle(card), label, waitsOnSpoken, card.pullRequest?.spoken, card.morePullRequestsSpoken].compactMap { $0 }.joined(separator: ", "))
        .accessibilityActions {
            // Combined into one element, the card would otherwise hide its button.
            if !vibes, card.canMergePullRequest, blocker == nil, let pr = card.pullRequest {
                Button("Merge pull request #\(pr.number)") { Task { try? await board.mergePullRequest(card.id) } }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if vibes {
            HStack(spacing: 6) {
                Text(Vibes.chip(stage: card.stage, activity: card.activity, shipped: card.shippedAt != nil, merged: card.merged == true,
                                waitingOn: blocker.map { "“\(board.displayTitle($0))”" }, options: board.vibesOptions))
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
            if let pr = card.pullRequest {
                Chip(text: "#\(pr.number)", color: pr.state.color, fill: pr.state.color.opacity(0.18))
            }
            if let more = card.morePullRequests {
                Chip(text: card.pullRequest == nil ? "\(more) PRs" : "+\(more)", color: Theme.muted)
            }
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
            if (card.canMergePullRequest && blocker == nil) || board.merging.contains(card.id) {
                MergeButton(card: card)
            }
        }
    }

    /// One chip per agent the card waits on, three at most.
    private func backgroundChips(_ tasks: [BackgroundWork]) -> some View {
        HStack(spacing: 4) {
            ForEach(tasks.prefix(3), id: \.id) { task in
                Chip(text: task.agentType ?? task.description ?? task.type, color: Theme.indigo200, fill: Theme.indigo400.opacity(0.15))
            }
            if tasks.count > 3 {
                Chip(text: "+\(tasks.count - 3)", color: Theme.indigo200, fill: Theme.indigo400.opacity(0.15))
            }
        }
        .help(tasks.compactMap(\.description).joined(separator: "\n"))
    }

    private var label: String {
        if shipped { return "shipped by VIBES MODE" }
        return switch card.activity {
        case .idle: "idle"
        case .running: "Claude running"
        case .needsReview: "ready for review"
        case .needsInput: "needs your answer"
        case .waiting: card.backgroundLine?.lowercased() ?? "waiting"
        case .error: "error"
        }
    }

    /// What it waits on, in words, for its tooltip and VoiceOver.
    private var waitsOnSpoken: String? {
        blocker.map { "waits on “\(board.displayTitle($0))”, \(Dependency.status(of: $0))" }
    }

    private var help: String {
        var lines = [board.displayTitle(card), card.cwd]
        if let waits = waitsOnSpoken { lines.append(waits.prefix(1).uppercased() + waits.dropFirst()) }
        if let pr = card.pullRequest { lines.append(pr.spoken) }
        if let more = card.morePullRequestsSpoken { lines.append(more) }
        if let error = board.classifyErrors[card.id] { lines.append("Couldn't sort: \(error)") }
        return lines.joined(separator: "\n")
    }
}

/// Merges a Release card's pull request on GitHub, offered only once GitHub
/// has said it merges cleanly. It sits on the card because it is the one
/// thing left to do with it.
///
/// The first press arms it and the second merges. A card can be dragged
/// back, but a merge can't be taken back from the board, and a stray click
/// on a card should not land anything. It disarms on its own after three
/// seconds, so a first press left standing isn't waiting on the next click.
/// Emerald, the open badge's colour, rather than Claude's sky: this is not
/// Claude's work.
private struct MergeButton: View {
    @EnvironmentObject var board: Board
    let card: Card
    @State private var armed = false

    private static let emerald = Color(hex: 0x34D399)

    var body: some View {
        let merging = board.merging.contains(card.id)
        let number = card.pullRequest.map { "#\($0.number)" } ?? ""
        Button {
            if armed {
                armed = false
                Task { try? await board.mergePullRequest(card.id) }
            } else {
                board.clearMergeError(card.id)
                armed = true
            }
        } label: {
            Text(merging ? "Merging…" : armed ? "Confirm" : "Merge")
                .font(.mono(10))
                .foregroundStyle(armed ? Color(hex: 0xA7F3D0) : Color(hex: 0x6EE7B7))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Self.emerald.opacity(armed ? 0.2 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.emerald.opacity(armed ? 0.8 : 0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(merging)
        .opacity(merging ? 0.5 : 1)
        .help(armed ? "Press again to merge the pull request on GitHub" : "Merge PR \(number): GitHub says it merges cleanly")
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { armed = false }
        }
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

extension PullRequest {
    /// The badge said in words, for its tooltip and VoiceOver.
    var spoken: String {
        let state = switch state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        }
        return "pull request #\(number), \(state)"
    }
}

extension Card {
    /// How many of the card's pull requests are not the one on its badge,
    /// when there are any.
    var morePullRequests: Int? {
        let others = (pullRequests?.count ?? 0) - (pullRequest == nil ? 0 : 1)
        return others > 0 ? others : nil
    }

    var morePullRequestsSpoken: String? {
        morePullRequests.map { more in
            let noun = more == 1 ? "pull request" : "pull requests"
            return pullRequest == nil ? "\(more) \(noun) from other branches" : "\(more) more \(noun)"
        }
    }
}

extension PullRequest.State {
    /// GitHub's own colours for a pull request's state, in the board's hues.
    var color: Color {
        switch self {
        case .open: Color(hex: 0x34D399)
        case .draft: Theme.muted
        case .merged: Color(hex: 0xA78BFA)
        case .closed: Color(hex: 0xF87171)
        }
    }
}
