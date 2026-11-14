import ReeveKit
import SwiftUI

/// Everything the card has changed in its worktree: its commits and what
/// isn't committed yet, new files included, against where the card started.
/// Read again when the tab shows and as Claude works while it does.
///
/// A line can take a comment, as on a GitHub review: sent to Claude at once,
/// or kept with others and sent together. Claude's replies come back under
/// them.
struct ChangesView: View {
    @EnvironmentObject var board: Board
    let card: Card
    @State private var changes: Worktrees.Changes?
    @State private var problem: String?
    @State private var notGit = false
    @State private var loading = false
    @State private var reloads = 0
    /// Raised with each read, so the list knows when `changes` is new.
    @State private var revision = 0
    /// Files a person opened or closed, over the size-based default.
    @State private var expanded: [String: Bool] = [:]
    /// The comment or reply being written, if any.
    @State private var editing: Editing?
    /// What's been typed in composers, kept here because diff rows come and
    /// go with every read.
    @StateObject private var drafts = Drafts()

    var body: some View {
        VStack(spacing: 0) {
            if notGit {
                TabEmptyState(title: "Not a git repository", detail: "This card works in a folder outside git, so there are no changes to show.")
            } else if let changes {
                let threads = card.review ?? []
                let blocker = board.reviewBlocker(card.id)
                SummaryBar(
                    changes: changes, loading: loading,
                    pending: threads.filter(\.hasPending).count, blocker: blocker,
                    submit: { board.submitReview(card.id) },
                    reload: { reloads += 1 }
                )
                if changes.files.isEmpty, threads.isEmpty {
                    TabEmptyState(title: "No changes yet", detail: changes.base == nil ? "Nothing here differs from HEAD." : "Nothing here differs from where the card started.")
                } else {
                    DiffList(
                        changes: changes, revision: revision, expanded: expanded,
                        review: ReviewContext(threads: threads, editing: editing, blocker: blocker, working: card.activity == .running, drafts: drafts, actions: actions)
                    ) { id, open in
                        expanded[id] = !open
                    }
                    .equatable()
                }
            } else if let problem {
                TabEmptyState(title: "Couldn't read the changes", detail: problem)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .task(id: "\(board.changeTicks[card.id] ?? 0)|\(reloads)") {
            // Claude's tool calls come in bursts; read once they settle.
            if changes != nil { try? await Task.sleep(for: .milliseconds(800)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var actions: ReviewActions {
        let id = card.id
        return ReviewActions(
            edit: { editing = $0 },
            post: { text, send in
                switch editing {
                case let .line(anchor):
                    board.comment(on: anchor, text, in: id, send: send)
                case let .reply(thread):
                    board.reply(to: thread, text, in: id, send: send)
                case nil:
                    return
                }
                if let key = editing?.draftKey { drafts.texts[key] = nil }
                editing = nil
            },
            send: { board.submitReview(id, only: $0) },
            discard: { board.discardDrafts($0, in: id) },
            resolve: { board.resolve($0, $1, in: id) }
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            guard let result = try await Worktrees.changes(in: card.worktreePath ?? card.cwd, base: card.baseCommit, env: board.environment) else {
                notGit = true
                return
            }
            guard !Task.isCancelled else { return }
            changes = result
            revision += 1
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

}

/// The diff itself. Equatable on what it shows, so the board's every update —
/// a spinner frame on any card — doesn't lay out thousands of lines again.
private struct DiffList: View, Equatable {
    let changes: Worktrees.Changes
    let revision: Int
    let expanded: [String: Bool]
    let review: ReviewContext
    let toggle: (_ id: String, _ open: Bool) -> Void

    /// Past this many lines a file starts closed; a lockfile would otherwise
    /// bury everything after it.
    private static let openLimit = 300

    static func == (a: DiffList, b: DiffList) -> Bool {
        a.revision == b.revision && a.expanded == b.expanded && a.review == b.review
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows(changes.files)) { row in
                    RowView(row: row, review: review) { file in toggle(file.id, isOpen(file)) }
                }
                notes(changes)
            }
            .textSelection(.enabled)
        }
    }

    private func isOpen(_ file: FileDiff) -> Bool {
        expanded[file.id] ?? (file.lineCount <= Self.openLimit)
    }

    /// The diff as one flat list, so only the rows on screen are laid out.
    /// Comments follow the line they're on, or sit under the file's header
    /// once the line has changed, or at the end once the file has left the diff.
    private func rows(_ files: [FileDiff]) -> [Row] {
        let placed = ReviewPlacement(review.threads, in: files)
        let composing: ReviewAnchor? = if case let .line(anchor) = review.editing { anchor } else { nil }
        func threads(_ threads: [ReviewThread], outdated: Bool) -> [Row] {
            threads.map { Row(id: "t.\($0.id)", kind: .thread($0, outdated: outdated)) }
        }
        var rows: [Row] = []
        for (f, file) in files.enumerated() {
            let open = isOpen(file)
            let comments = review.threads.filter { $0.path == file.path }.count
            rows.append(Row(id: "\(f)", kind: .file(file, open: open, comments: comments)))
            guard open else { continue }
            rows += threads(placed.outdated[file.path] ?? [], outdated: true)
            if file.isBinary {
                rows.append(Row(id: "\(f).b", kind: .notice("Binary file")))
            } else if let mode = file.modeChange, file.hunks.isEmpty {
                rows.append(Row(id: "\(f).m", kind: .notice("Mode changed \(mode)")))
            } else if file.hunks.isEmpty, file.status == .renamed {
                rows.append(Row(id: "\(f).r", kind: .notice("Renamed, contents unchanged")))
            }
            for (h, hunk) in file.hunks.enumerated() {
                rows.append(Row(id: "\(f).\(h)", kind: .hunk(hunk.header)))
                for (l, line) in hunk.lines.enumerated() {
                    let anchor = ReviewAnchor(file: file, line: line)
                    rows.append(Row(id: "\(f).\(h).\(l)", kind: .line(line, anchor: anchor)))
                    guard let anchor else { continue }
                    rows += threads(placed.byLine[anchor.key] ?? [], outdated: false)
                    if composing == anchor {
                        rows.append(Row(id: "c.\(anchor.key)", kind: .composer(anchor)))
                    }
                }
            }
        }
        if !placed.orphaned.isEmpty {
            rows.append(Row(id: "orphaned", kind: .notice("Comments on files that no longer have changes")))
            rows += threads(placed.orphaned, outdated: true)
        }
        return rows
    }

    @ViewBuilder
    private func notes(_ changes: Worktrees.Changes) -> some View {
        let notes = [
            changes.untrackedLeftOut > 0 ? "\(changes.untrackedLeftOut) more new files aren't shown." : nil,
            changes.truncated ? "The diff is too long to show all of it; it stops here." : nil,
        ].compactMap { $0 }
        ForEach(notes, id: \.self) { note in
            Text(note).font(.geist(12)).foregroundStyle(Theme.muted).padding(14)
        }
    }
}

private struct Row: Identifiable {
    enum Kind {
        case file(FileDiff, open: Bool, comments: Int)
        case hunk(String)
        /// The anchor is nil for a line that can't take a comment.
        case line(DiffLine, anchor: ReviewAnchor?)
        case notice(String)
        case thread(ReviewThread, outdated: Bool)
        case composer(ReviewAnchor)
    }

    let id: String
    let kind: Kind
}

private struct RowView: View {
    let row: Row
    let review: ReviewContext
    let toggle: (FileDiff) -> Void

    var body: some View {
        switch row.kind {
        case let .file(file, open, comments):
            FileHeader(file: file, open: open, comments: comments) { toggle(file) }
        case let .hunk(header):
            Text(header)
                .font(.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(Theme.sky950.opacity(0.35))
        case let .line(line, anchor):
            LineView(line: line, comment: anchor.map { anchor in { review.actions.edit(.line(anchor)) } })
        case let .notice(text):
            Text(text)
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        case let .thread(thread, outdated):
            ThreadView(thread: thread, outdated: outdated, review: review)
        case let .composer(anchor):
            Composer(draftKey: Editing.line(anchor).draftKey, drafts: review.drafts, placeholder: "Leave a comment for Claude", sendLabel: "Comment now", blocker: review.blocker, post: review.actions.post, cancel: { review.actions.edit(nil) })
                .modifier(ReviewInset())
        }
    }
}

private struct FileHeader: View {
    let file: FileDiff
    let open: Bool
    let comments: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 10)
                Text(badge.letter)
                    .font(.mono(10, .semibold))
                    .foregroundStyle(badge.color)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(badge.color.opacity(0.15)))
                Text(name)
                    .font(.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble")
                        .font(.geist(11))
                        .foregroundStyle(Theme.muted)
                        .help(comments == 1 ? "1 comment" : "\(comments) comments")
                }
                if file.additions > 0 {
                    Text("+\(file.additions)").font(.mono(11)).foregroundStyle(DiffColors.addedText)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)").font(.mono(11)).foregroundStyle(DiffColors.removedText)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.edge).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }

    private var name: String {
        if file.status == .renamed, let old = file.oldPath, let new = file.newPath { return "\(old) → \(new)" }
        return file.path
    }

    private var badge: (letter: String, color: Color) {
        switch file.status {
        case .added: ("A", DiffColors.addedText)
        case .deleted: ("D", DiffColors.removedText)
        case .renamed: ("R", Theme.sky300)
        case .modified: ("M", Color(hex: 0xE3B341))
        }
    }
}

private struct LineView: View {
    let line: DiffLine
    /// Opens a comment on the line; nil for a line that can't take one.
    let comment: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .foregroundStyle(signColor)
                .frame(width: 20)
                .overlay {
                    if hovering, let comment {
                        Button(action: comment) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.sky600))
                        }
                        .buttonStyle(.plain)
                        .help("Comment on this line")
                    }
                }
            // A blank line still takes a line's height.
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(line.kind == .note ? Theme.muted : Theme.textSoft)
                .italic(line.kind == .note)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.mono(12))
        .padding(.vertical, 1)
        .padding(.trailing, 14)
        .background(background)
        .onHover { hovering = $0 }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(Theme.muted.opacity(0.6))
            .frame(width: 46, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context, .note: ""
        }
    }

    private var signColor: Color {
        line.kind == .added ? DiffColors.addedText : DiffColors.removedText
    }

    private var background: Color {
        switch line.kind {
        case .added: DiffColors.added
        case .removed: DiffColors.removed
        case .context, .note: .clear
        }
    }
}

/// The count of files and lines, what they're against, the review waiting
/// to go, and a way to read again.
private struct SummaryBar: View {
    let changes: Worktrees.Changes
    let loading: Bool
    /// Threads with a draft not yet sent.
    let pending: Int
    let blocker: String?
    let submit: () -> Void
    let reload: () -> Void

    var body: some View {
        let added = changes.files.reduce(0) { $0 + $1.additions }
        let removed = changes.files.reduce(0) { $0 + $1.deletions }
        HStack(spacing: 10) {
            Text(changes.files.count == 1 ? "1 file changed" : "\(changes.files.count) files changed")
                .font(.geist(12, .medium))
                .foregroundStyle(Theme.text)
            if added > 0 { Text("+\(added)").font(.mono(11)).foregroundStyle(DiffColors.addedText) }
            if removed > 0 { Text("−\(removed)").font(.mono(11)).foregroundStyle(DiffColors.removedText) }
            Text(changes.base.map { "since \($0)" } ?? "since HEAD")
                .font(.mono(11))
                .foregroundStyle(Theme.muted)
                .help(changes.base == nil
                    ? "Only what isn't committed: this card doesn't know the commit it started from."
                    : "Commits and uncommitted changes since the card's worktree was made.")
            Spacer()
            if loading { ProgressView().controlSize(.mini) }
            if pending > 0 {
                Button("Submit review (\(pending))", action: submit)
                    .buttonStyle(PrimaryButtonStyle(height: 24))
                    .disabled(blocker != nil)
                    .opacity(blocker == nil ? 1 : 0.5)
                    .help(blocker ?? "Send your comments to Claude")
            }
            Button(action: reload) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help("Read the changes again")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }
}

/// GitHub-dark's diff colours, as the terminal's ANSI greens and reds.
private enum DiffColors {
    static let added = Color(hex: 0x2EA043, opacity: 0.15)
    static let removed = Color(hex: 0xF85149, opacity: 0.15)
    static let addedText = Color(hex: 0x3FB950)
    static let removedText = Color(hex: 0xFF7B72)
}

// MARK: Review

/// What's being written: a new comment on a line, or a reply to a thread.
private enum Editing: Equatable {
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
private final class Drafts: ObservableObject {
    var texts: [String: String] = [:]
}

private struct ReviewActions {
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
private struct ReviewContext: Equatable {
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

/// Lines a comment up under the code, past the line numbers.
private struct ReviewInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: 760, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge))
            .padding(.leading, 120)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A comment and the conversation under it.
private struct ThreadView: View {
    let thread: ReviewThread
    /// Its line has changed or gone, so it shows where the line was.
    let outdated: Bool
    let review: ReviewContext
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
        .modifier(ReviewInset())
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

private struct MessageView: View {
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
private struct Composer: View {
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
