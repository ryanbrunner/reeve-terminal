import AppKit
import ReeveKit
import SwiftUI
import WebKit

/// The app the card is building, under review in Gloss: its feedback bar
/// across the top of the page, with comments going to the card's Claude as
/// rounds through `gloss wait`. Claude's `gloss open` lands here, or type the
/// URL of the dev server in.
struct PreviewView: View {
    @EnvironmentObject var board: Board
    let card: Card
    @ObservedObject var preview: Preview

    var body: some View {
        VStack(spacing: 0) {
            PreviewBar(card: card, preview: preview)
            ZStack {
                if preview.url == nil, preview.session != .starting {
                    TabEmptyState(
                        title: "Nothing to preview yet",
                        detail: board.environment?.glossPath == nil
                            ? "Type the URL of the app above to see it here. Install Gloss (brew install ryanbrunner/tap/gloss) to comment on it for Claude."
                            : "Type the URL of the app above, or ask Claude to run /gloss with it. Comments you write in the Gloss bar go to Claude as a round."
                    )
                } else {
                    WebViewHost(webView: preview.webView)
                    if let error = preview.loadError {
                        TabEmptyState(title: "Couldn't load the page", detail: error)
                            .background(Theme.ink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }
}

/// Where the preview is, how its review stands, and what to do with it.
private struct PreviewBar: View {
    @EnvironmentObject var board: Board
    let card: Card
    @ObservedObject var preview: Preview
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            GlossStatus(session: preview.session)
            TextField("http://localhost:3000", text: $text)
                .textFieldStyle(.plain)
                .font(.mono(11.5))
                .foregroundStyle(Theme.text)
                .focused($editing)
                .onSubmit(go)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(editing ? Theme.sky700 : Theme.edge))
            if preview.url != nil {
                Button {
                    preview.reload()
                } label: {
                    Image(systemName: preview.loading ? "xmark" : "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .help("Reload")
            }
            if let url = preview.url, board.environment?.glossPath != nil, preview.session != .live, preview.session != .starting {
                Button("Review in Gloss") { board.openPreview(card.id, url: url) }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("Start a Gloss session on this page, for Claude's `gloss wait`")
            }
            if preview.session == .live {
                Button("End review") { preview.stop() }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("End the Gloss session. Claude's `gloss wait` hears that it ended.")
            }
            if let url = preview.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("Open the page in your browser")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
        .onAppear { text = preview.url?.absoluteString ?? "" }
        .onChange(of: preview.url) { _, url in
            if !editing { text = url?.absoluteString ?? "" }
        }
    }


    /// A bare `localhost:3000` is taken to mean http, as `gloss open` takes it.
    private func go() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let withScheme = raw.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) == nil ? "http://" + raw : raw
        guard let url = URL(string: withScheme), url.scheme == "http" || url.scheme == "https" else { return }
        text = url.absoluteString
        editing = false
        board.openPreview(card.id, url: url)
    }
}

/// How the page's Gloss session stands.
struct GlossStatus: View {
    let session: Preview.Session
    /// What Claude runs to take the rounds.
    var wait = "gloss wait"

    var body: some View {
        let (label, color, help): (String, Color, String) = switch session {
        case .none: ("Gloss", Theme.edgeStrong, "No Gloss session")
        case .starting: ("Starting", Theme.sky400, "Starting a Gloss session")
        case .live: ("Gloss", Color(hex: 0x10B981), "Under review: Claude's `\(wait)` gets the rounds you submit")
        case .ended: ("Ended", Theme.edgeStrong, "The Gloss session has ended")
        case let .failed(why): ("Gloss failed", Color(hex: 0xF87171), why)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.geist(12, .medium)).foregroundStyle(Theme.muted)
        }
        .fixedSize()
        .help(help)
    }
}

/// Holds the card's web view. It lives in `Previews`, so switching tabs and
/// cards keeps the page as it was.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x0E1116).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
