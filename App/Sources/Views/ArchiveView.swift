import AppKit
import ReeveKit
import SwiftUI

/// The cards cleaned up from Release once their pull requests merged, newest
/// first. Their sessions and worktrees are gone; each row keeps what the card
/// was and a way back to its pull request.
struct ArchiveView: View {
    @EnvironmentObject var board: Board
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Archive").font(.geist(16, .semibold)).foregroundStyle(Theme.text)
                Text("\(board.archive.count)")
                    .font(.mono(11, .medium))
                    .foregroundStyle(Theme.muted.opacity(0.6))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Rectangle().fill(Theme.edge).frame(height: 1)
            if board.archive.isEmpty {
                Text("Nothing archived yet. Clean up in the Release column archives cards whose pull requests have merged.")
                    .font(.geist(13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(board.archive) { card in
                            ArchivedRow(card: card)
                            Rectangle().fill(Theme.edge).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 460)
        .background(Theme.panel)
    }
}

private struct ArchivedRow: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(board.displayTitle(card))
                    .font(.geist(13, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                if let summary = card.summary {
                    Text(summary)
                        .font(.mono(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Chip(text: card.folderName, color: Theme.folderColor(card.folderName), fill: Theme.folderColor(card.folderName).opacity(0.2))
                    if let pr = card.pullRequest {
                        Chip(text: "#\(pr.number)", color: pr.state.color, fill: pr.state.color.opacity(0.18))
                    }
                    if let at = card.archivedAt {
                        Text(at.formatted(.relative(presentation: .named)))
                            .font(.mono(10))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            Spacer(minLength: 8)
            if let pr = card.pullRequest, let url = URL(string: pr.url) {
                Button("Open PR") { NSWorkspace.shared.open(url) }
                    .buttonStyle(SecondaryButtonStyle(height: 24))
            }
            Button {
                board.deleteArchived(card.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Remove from the archive")
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
