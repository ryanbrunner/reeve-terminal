import AppKit
import ReeveKit
import SwiftUI

/// Every pull request the card has opened, from any branch its worktree has
/// been on, with where each one stands: open or not, its checks, its review.
/// Looked up again each time the tab shows, and every half minute while a
/// check is still running.
struct PullRequestsView: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let prs = card.pullRequests ?? []
        VStack(spacing: 0) {
            if prs.isEmpty {
                if card.worktreePath == nil {
                    TabEmptyState(
                        title: "No worktree",
                        detail: "Reeve finds pull requests from a card's own branch, and this card works in a folder without one."
                    )
                } else {
                    PullRequestsBar(card: card, count: 0)
                    TabEmptyState(
                        title: "No pull requests yet",
                        detail: "When Claude opens one from this card's branch, with gh pr create or on GitHub, it shows here. So does every one after it, from any branch."
                    )
                }
            } else {
                PullRequestsBar(card: card, count: prs.count)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(prs, id: \.number) { pr in
                            PullRequestRow(pr: pr, current: pr.number == card.pullRequest?.number)
                            Rectangle().fill(Theme.edge).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // While a check is running, keep asking until it has finished.
        .task(id: prs.contains { $0.state != .merged && $0.state != .closed && $0.checks?.overall == .pending }) {
            guard prs.contains(where: { $0.state != .merged && $0.state != .closed && $0.checks?.overall == .pending }) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                board.refreshPullRequest(card.id)
            }
        }
    }
}

/// How many there are, and a way to ask again now.
private struct PullRequestsBar: View {
    @EnvironmentObject var board: Board
    let card: Card
    let count: Int

    var body: some View {
        let finding = board.findingPullRequests.contains(card.id)
        HStack(spacing: 10) {
            Text(count == 1 ? "1 pull request" : "\(count) pull requests")
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
            Spacer()
            if finding {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { board.refreshPullRequest(card.id) }
                .buttonStyle(SecondaryButtonStyle(height: 22))
                .disabled(finding)
                .help("Ask GitHub again")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
}

/// One pull request: its state, title and branch, then its checks and
/// review. A click opens it on GitHub.
private struct PullRequestRow: View {
    let pr: PullRequest
    /// From the branch the card is on now, so it is the one on the badge.
    let current: Bool

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 12) {
                Chip(text: pr.state.label, color: pr.state.color, fill: pr.state.color.opacity(0.18))
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)").font(.mono(12)).foregroundStyle(Theme.muted)
                        Text(pr.title.isEmpty ? "Untitled" : pr.title)
                            .font(.geist(13, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 6) {
                        Text(pr.branch).font(.mono(11)).foregroundStyle(Theme.muted.opacity(0.85)).lineLimit(1)
                        if current {
                            Chip(text: "this branch", color: Theme.sky300, fill: Theme.sky500.opacity(0.15))
                        }
                    }
                }
                Spacer(minLength: 8)
                if let checks = pr.checks {
                    ChecksPill(checks: checks)
                }
                if let review = pr.review {
                    Chip(text: review.label, color: review.color, fill: review.color.opacity(0.15))
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "Open #\(pr.number) on GitHub"))
        .accessibilityLabel([pr.spoken, pr.title, pr.checks?.spoken, pr.review?.label].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The checks in a word or two: all passed, how many failed, how many are
/// still running.
private struct ChecksPill: View {
    let checks: PullRequest.Checks

    var body: some View {
        let (symbol, color): (String, Color) = switch checks.overall {
        case .passing: ("checkmark", PullRequest.Checks.green)
        case .pending: ("circle.dotted", PullRequest.Checks.amber)
        case .failing: ("xmark", PullRequest.Checks.red)
        }
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(checks.short).font(.mono(10))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
        .help(checks.spoken)
    }
}

extension PullRequest.State {
    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

extension PullRequest.Checks {
    static let green = Color(hex: 0x34D399)
    static let amber = Color(hex: 0xFBBF24)
    static let red = Color(hex: 0xF87171)

    /// What the pill says: the count that matters most.
    var short: String {
        switch overall {
        case .passing: "\(passed)/\(total)"
        case .pending: "\(pending) running"
        case .failing: "\(failed) failing"
        }
    }

    /// Every count, for the tooltip and VoiceOver.
    var spoken: String {
        [failed > 0 ? "\(failed) failing" : nil,
         pending > 0 ? "\(pending) running" : nil,
         passed > 0 ? "\(passed) passed" : nil]
            .compactMap { $0 }.joined(separator: ", ") + (total == 1 ? " check" : " checks")
    }
}

extension PullRequest.Review {
    var label: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .required: "Review required"
        }
    }

    var color: Color {
        switch self {
        case .approved: PullRequest.Checks.green
        case .changesRequested: PullRequest.Checks.red
        case .required: Theme.muted
        }
    }
}
