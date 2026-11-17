import ReeveKit
import SwiftUI

// What a review is written and read with, on the diff and on the plan: a
// thread of comments, and the composer a comment is written in.

/// What's being written: a new comment on a line, or a reply to a thread.
enum Editing: Equatable {
    case line(ReviewAnchor)
    case reply(UUID)

    var draftKey: String {
        switch self {
        case let .line(anchor): "line:" + anchor.key
        case let .reply(id): "reply:" + id.uuidString
        }
    }
}

/// Composer text by `Editing.draftKey`. Not published: typing redraws only
/// the composer, not the diff.
final class Drafts: ObservableObject {
    var texts: [String: String] = [:]
}

struct ReviewActions {
    /// Opens a composer, or closes it with nil.
    let edit: (Editing?) -> Void
    /// Posts what the open composer holds: sent now, or kept for the review.
    let post: (_ text: String, _ send: Bool) -> Void
    /// Sends one thread's drafts.
    let send: (UUID) -> Void
    let discard: (UUID) -> Void
    let resolve: (UUID, Bool) -> Void
}

/// Everything the diff's comments need. Equal when what they show is.
struct ReviewContext: Equatable {
    let threads: [ReviewThread]
    let editing: Editing?
    let blocker: String?
    /// Claude is in a turn, so a reply may still come in it.
    let working: Bool
    let drafts: Drafts
    let actions: ReviewActions

    static func == (a: ReviewContext, b: ReviewContext) -> Bool {
        a.threads == b.threads && a.editing == b.editing && a.blocker == b.blocker && a.working == b.working
    }
}

/// Lines a comment up under what it's on: in the diff, under the code past
/// the line numbers.
struct ReviewInset: ViewModifier {
    var leading: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: 760, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
            .padding(.leading, leading)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A comment and the conversation under it.
struct ThreadView: View {
    let thread: ReviewThread
    /// Its line has changed or gone, so it shows where the line was.
    let outdated: Bool
    let review: ReviewContext
    var inset: CGFloat = 120
    @State private var showResolved = false

    var body: some View {
        Group {
            if thread.resolved, !showResolved {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(DiffColors.addedText)
                    Text("Resolved").font(.geist(12, .medium)).foregroundStyle(Theme.textSoft)
                    Text(thread.messages.first?.body ?? "").font(.geist(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Show") { showResolved = true }.buttonStyle(.plain).font(.geist(12)).foregroundStyle(Theme.sky300)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if outdated { lineItWasOn }
                    ForEach(Array(thread.messages.enumerated()), id: \.offset) { _, message in
                        MessageView(message: message)
                    }
                    if thread.awaitingReply, !thread.resolved {
                        // A turn that ended without one (interrupted, or
                        // answered only in the terminal) isn't still coming.
                        HStack(spacing: 6) {
                            if review.working { ProgressView().controlSize(.mini) }
                            Text(review.working ? "Waiting for Claude's reply" : "No reply yet")
                                .font(.geist(12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    footer
                }
            }
        }
        .modifier(ReviewInset(leading: inset))
    }

    /// The line it was left on, for a thread that's no longer beside it.
    private var lineItWasOn: some View {
        HStack(spacing: 8) {
            Chip(text: "Outdated", color: Theme.amber100, fill: Color(hex: 0xD29922, opacity: 0.15))
            Text("\(thread.path):\(thread.line)").font(.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
            Text(thread.code.trimmingCharacters(in: .whitespaces)).font(.mono(11)).foregroundStyle(Theme.muted.opacity(0.7)).lineLimit(1)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if review.editing == .reply(thread.id) {
            Composer(draftKey: Editing.reply(thread.id).draftKey, drafts: review.drafts, placeholder: "Reply", sendLabel: "Reply now", blocker: review.blocker, post: review.actions.post, cancel: { review.actions.edit(nil) })
        } else {
            HStack(spacing: 8) {
                if thread.hasPending {
                    Button("Send now") { review.actions.send(thread.id) }
                        .buttonStyle(PrimaryButtonStyle(height: 24))
                        .disabled(review.blocker != nil)
                        .opacity(review.blocker == nil ? 1 : 0.5)
                        .help(review.blocker ?? "Send this comment to Claude now, without the rest of the review")
                    Button("Discard draft") { review.actions.discard(thread.id) }
                        .buttonStyle(SecondaryButtonStyle(height: 24))
                }
                Button("Reply") { review.actions.edit(.reply(thread.id)) }
                    .buttonStyle(SecondaryButtonStyle(height: 24))
                Spacer()
                Button(thread.resolved ? "Unresolve" : "Resolve") {
                    showResolved = false
                    review.actions.resolve(thread.id, !thread.resolved)
                }
                .buttonStyle(SecondaryButtonStyle(height: 24))
            }
        }
    }
}

struct MessageView: View {
    let message: ReviewMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.author == .person ? "You" : "Claude")
                    .font(.geist(12, .medium))
                    .foregroundStyle(message.author == .person ? Theme.text : Theme.sky300)
                if message.pending { Chip(text: "Pending") }
            }
            Text(rendered(message.body))
                .font(.geist(13))
                .foregroundStyle(Theme.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Claude writes Markdown; inline styles and code spans read better rendered.
    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Where a comment or reply is written. Keeps its own text, saved to
/// `drafts` as it changes, so a diff read mid-sentence loses nothing.
struct Composer: View {
    let draftKey: String
    let drafts: Drafts
    let placeholder: String
    let sendLabel: String
    let blocker: String?
    let post: (_ text: String, _ send: Bool) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(draftKey: String, drafts: Drafts, placeholder: String, sendLabel: String, blocker: String?, post: @escaping (String, Bool) -> Void, cancel: @escaping () -> Void) {
        self.draftKey = draftKey
        self.drafts = drafts
        self.placeholder = placeholder
        self.sendLabel = sendLabel
        self.blocker = blocker
        self.post = post
        self.cancel = cancel
        _text = State(initialValue: drafts.texts[draftKey] ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.geist(13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.sky700 : Theme.edge))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(.geist(13)).foregroundStyle(Theme.muted.opacity(0.6)).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .focused($focused)
                .onChange(of: text) { _, new in drafts.texts[draftKey] = new }
            HStack(spacing: 8) {
                if let blocker {
                    Text(blocker).font(.geist(11)).foregroundStyle(Theme.amber100.opacity(0.85)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .keyboardShortcut(.cancelAction)
                Button("Add to review") { post(trimmed, false) }
                    .buttonStyle(SecondaryButtonStyle(height: 26))
                    .disabled(trimmed.isEmpty)
                    .help("Keep it with your other comments, and send them together")
                Button(sendLabel) { post(trimmed, true) }
                    .buttonStyle(PrimaryButtonStyle(height: 26))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty || blocker != nil)
                    .opacity(trimmed.isEmpty || blocker != nil ? 0.5 : 1)
                    .help(blocker ?? "Send to Claude now (⌘↩)")
            }
        }
        .onAppear { focused = true }
    }
}
