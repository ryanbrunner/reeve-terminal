import AppKit
import ReeveKit
import SwiftUI

/// What the card's `/design` made, on show: the Claude Design projects and
/// claude.ai artifacts its session shared, the newest first, in a web view of
/// Reeve's own. It keeps its cookies, so a sign-in to claude.ai lasts.
///
/// Feedback goes to Claude through Gloss, as in the Preview tab, in a session
/// named `design` so the two can run at once: Claude's `gloss open --name
/// design` lands here, and its `gloss wait --name design` gets the rounds.
struct DesignView: View {
    @EnvironmentObject var board: Board
    let card: Card
    @ObservedObject var viewer: Preview

    var body: some View {
        let designs = card.designs ?? []
        VStack(spacing: 0) {
            if designs.isEmpty, viewer.url == nil, viewer.session != .starting {
                TabEmptyState(
                    title: "No designs yet",
                    detail: "Start the card in Design, or run /design in its terminal. When Claude shares a Claude Design project or an artifact, it shows here. If Claude says Design isn't connected, run /design login."
                )
            } else {
                DesignBar(card: card, designs: designs, viewer: viewer)
                ZStack {
                    WebViewHost(webView: viewer.webView)
                    if let error = viewer.loadError {
                        TabEmptyState(title: "Couldn't load the design", detail: error)
                            .background(Theme.ink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // A card that missed the hooks finds its designs in the transcript.
        .task(id: card.transcriptPath) { await board.backfillDesigns(card.id) }
        // The newest, until a person picks another or Claude shares one.
        .onChange(of: designs.first?.url, initial: true) { _, newest in
            guard viewer.requested == nil, let newest, let url = URL(string: newest) else { return }
            board.showDesign(card.id, url: url)
        }
    }
}

/// Which design is on show, how its review stands, and what to do with it.
private struct DesignBar: View {
    @EnvironmentObject var board: Board
    let card: Card
    let designs: [DesignArtifact]
    @ObservedObject var viewer: Preview

    var body: some View {
        let shown = self.shown
        HStack(spacing: 10) {
            GlossStatus(session: viewer.session, wait: "gloss wait --name \(Gloss.designSession)")
            picker(shown)
            Spacer(minLength: 8)
            if viewer.url != nil {
                Button {
                    viewer.reload()
                } label: {
                    Image(systemName: viewer.loading ? "xmark" : "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("Reload")
            }
            if let link = shown.flatMap({ URL(string: $0.url) }) {
                if board.environment?.glossPath != nil, viewer.session != .live, viewer.session != .starting {
                    Button("Review in Gloss") { board.reviewDesign(card.id, url: link) }
                        .buttonStyle(SecondaryButtonStyle(height: 22))
                        .help("Start a Gloss session on this design, for Claude's `gloss wait --name \(Gloss.designSession)`")
                }
            }
            if viewer.session == .live {
                Button("End review") { viewer.stop() }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("End the Gloss session. Claude's `gloss wait` hears that it ended.")
            }
            if let link = shown?.url {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle(height: 22))
                Button("Open") {
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(SecondaryButtonStyle(height: 22))
                .help("Open it in your browser")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }

    /// The design last asked for: what a sign-in or the design's own links
    /// lead away from. Nil for a page Gloss opened that isn't one of them.
    private var shown: DesignArtifact? {
        guard let requested = viewer.requested?.absoluteString else { return nil }
        return designs.first { $0.url == requested } ?? DesignSighting.links(in: requested).first.map { DesignArtifact(url: $0) }
    }

    /// The design on show, and every other to pick from, newest first.
    private func picker(_ shown: DesignArtifact?) -> some View {
        Menu {
            ForEach(designs) { design in
                Button {
                    if let url = URL(string: design.url) { board.showDesign(card.id, url: url) }
                } label: {
                    if design.url == shown?.url {
                        Label(Self.name(design), systemImage: "checkmark")
                    } else {
                        Text(Self.name(design))
                    }
                }
            }
        } label: {
            // A menu's label is one line of text on macOS.
            Text(label(shown))
                .font(.geist(12.5, .medium))
                .foregroundStyle(Theme.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(designs.isEmpty)
        .help("The designs Claude has shared, newest first")
    }

    /// The design on show, or the page if it isn't one, and how many there are.
    private func label(_ shown: DesignArtifact?) -> String {
        let page = shown.map(Self.name) ?? viewer.url.map { ($0.host() ?? "") + $0.path() } ?? ""
        return designs.count > 1 ? "\(page)  ·  \(designs.count) designs" : page
    }

    private static func name(_ design: DesignArtifact) -> String {
        "\(kind(design)): \(design.title ?? design.shortName)"
    }

    /// A Claude Design project, or an artifact.
    private static func kind(_ design: DesignArtifact) -> String {
        design.url.contains("/design/") ? "Project" : "Artifact"
    }
}
