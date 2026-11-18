import AppKit
import ReeveKit
import SwiftUI

/// What the card's `/design` made: the Claude Design projects and claude.ai
/// artifacts its session shared, newest first. They live on claude.ai, so a
/// click opens one in the browser, where the person is signed in.
struct DesignView: View {
    @EnvironmentObject var board: Board
    let card: Card

    var body: some View {
        let designs = card.designs ?? []
        VStack(spacing: 0) {
            if designs.isEmpty {
                TabEmptyState(
                    title: "No designs yet",
                    detail: "Start the card in Design, or run /design in its terminal. When Claude shares a Claude Design project or an artifact, it shows here. If Claude says Design isn't connected, run /design login."
                )
            } else {
                DesignBar(count: designs.count)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(designs) { design in
                            DesignRow(design: design)
                            Rectangle().fill(Theme.edge).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // A card that missed the hooks finds its designs in the transcript.
        .task(id: card.transcriptPath) { await board.backfillDesigns(card.id) }
    }
}

/// How many there are.
private struct DesignBar: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(count == 1 ? "1 design" : "\(count) designs")
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
}

/// One design: what it is, when it was last shared, and its link. A click
/// opens it in the browser.
private struct DesignRow: View {
    let design: DesignArtifact

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let url = URL(string: design.url) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 12) {
                    Chip(text: kind, color: Stage.design.tint, fill: Stage.design.tint.opacity(0.18))
                        .frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(design.title ?? design.shortName)
                            .font(.geist(13, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(design.url)
                            .font(.mono(11))
                            .foregroundStyle(Theme.muted.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(design.at, style: .relative)
                        .font(.geist(11))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open it in the browser")
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(design.url, forType: .string)
            }
            .buttonStyle(SecondaryButtonStyle(height: 22))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A Claude Design project, or an artifact.
    private var kind: String {
        design.url.contains("/design/") ? "Project" : "Artifact"
    }
}
