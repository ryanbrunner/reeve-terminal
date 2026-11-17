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
    /// Folders closed in the file tree, by path.
    @State private var collapsed: Set<String> = []
    /// The file last picked in the tree, for the diff to scroll to.
    @State private var jump: Jump?
    @AppStorage("changesTree", store: Preferences.store) private var showTree = true
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
                    reload: { reloads += 1 },
                    tree: changes.files.isEmpty ? nil : $showTree
                )
                if changes.files.isEmpty, threads.isEmpty {
                    TabEmptyState(title: "No changes yet", detail: changes.base == nil ? "Nothing here differs from HEAD." : "Nothing here differs from where the card started.")
                } else {
                    HStack(spacing: 0) {
                        if showTree, !changes.files.isEmpty {
                            FileNavigator(
                                files: changes.files, revision: revision, collapsed: collapsed, selected: jump?.file,
                                comments: Dictionary(threads.map { ($0.path, 1) }, uniquingKeysWith: +),
                                toggle: { collapsed.formSymmetricDifference([$0]) },
                                pick: reveal
                            )
                            .equatable()
                            .frame(width: 260)
                            Rectangle().fill(Theme.edge).frame(width: 1)
                        }
                        DiffList(
                            changes: changes, revision: revision, expanded: expanded, jump: jump,
                            review: ReviewContext(threads: threads, editing: editing, blocker: blocker, working: card.activity == .running, drafts: drafts, actions: actions)
                        ) { id, open in
                            expanded[id] = !open
                        }
                        .equatable()
                    }
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

    /// Opens the file if it's closed, and scrolls the diff to it.
    private func reveal(_ file: FileDiff) {
        if !DiffList.isOpen(file, expanded) { expanded[file.id] = true }
        jump = Jump(file: file.id, count: (jump?.count ?? 0) + 1)
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
    let jump: Jump?
    let review: ReviewContext
    let toggle: (_ id: String, _ open: Bool) -> Void

    /// Past this many lines a file starts closed; a lockfile would otherwise
    /// bury everything after it.
    private static let openLimit = 300

    static func == (a: DiffList, b: DiffList) -> Bool {
        a.revision == b.revision && a.expanded == b.expanded && a.jump == b.jump && a.review == b.review
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(changes.files)) { row in
                        RowView(row: row, review: review) { file in toggle(file.id, isOpen(file)) }
                    }
                    notes(changes)
                }
                .textSelection(.enabled)
            }
            .onChange(of: jump) { _, jump in
                guard let jump else { return }
                let id = Self.headerId(jump.file)
                proxy.scrollTo(id, anchor: .top)
                // Rows far off haven't been laid out, so the first scroll
                // goes by estimated heights and can stop short.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    static func isOpen(_ file: FileDiff, _ expanded: [String: Bool]) -> Bool {
        expanded[file.id] ?? (file.lineCount <= openLimit)
    }

    private func isOpen(_ file: FileDiff) -> Bool {
        Self.isOpen(file, expanded)
    }

    /// By the file, not its place, so a jump finds it after a read reorders them.
    static func headerId(_ file: String) -> String { "f." + file }

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
            rows.append(Row(id: Self.headerId(file.id), kind: .file(file, open: open, comments: comments)))
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
                .modifier(ReviewInset(leading: 120))
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
                StatusBadge(status: file.status)
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

}

/// A, M, D or R, in the colour of what happened to the file.
private struct StatusBadge: View {
    let status: FileDiff.Status

    var body: some View {
        Text(letter)
            .font(.mono(10, .semibold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
    }

    private var letter: String {
        switch status {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .modified: "M"
        }
    }

    private var color: Color {
        switch status {
        case .added: DiffColors.addedText
        case .deleted: DiffColors.removedText
        case .renamed: Theme.sky300
        case .modified: Color(hex: 0xE3B341)
        }
    }
}

/// A file picked in the tree. Counted, so picking the same one again still
/// scrolls back to it.
private struct Jump: Equatable {
    let file: String
    let count: Int
}

/// The changed files as folders, beside the diff. Picking one scrolls to it.
/// Equatable on what it shows, as `DiffList` is.
private struct FileNavigator: View, Equatable {
    let files: [FileDiff]
    let revision: Int
    let collapsed: Set<String>
    let selected: String?
    /// Comments by path.
    let comments: [String: Int]
    let toggle: (_ folder: String) -> Void
    let pick: (FileDiff) -> Void

    static func == (a: FileNavigator, b: FileNavigator) -> Bool {
        a.revision == b.revision && a.collapsed == b.collapsed && a.selected == b.selected && a.comments == b.comments
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(FileTree(files).rows(collapsed: collapsed), id: \.node.id) { row in
                    switch row.node.kind {
                    case .folder:
                        NavigatorRow(depth: row.depth, selected: false, help: String(row.node.id.dropLast()), action: { toggle(row.node.id) }) {
                            Image(systemName: collapsed.contains(row.node.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 10)
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                            Text(row.node.name)
                                .font(.mono(12))
                                .foregroundStyle(Theme.textSoft)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    case let .file(i):
                        let file = files[i]
                        NavigatorRow(depth: row.depth, selected: selected == file.id, help: file.path, action: { pick(file) }) {
                            // Under its folder's name, past the chevron.
                            Color.clear.frame(width: 10, height: 1)
                            StatusBadge(status: file.status)
                            Text(row.node.name)
                                .font(.mono(12))
                                .foregroundStyle(selected == file.id ? Theme.text : Theme.textSoft)
                                .strikethrough(file.status == .deleted, color: Theme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let count = comments[file.path] {
                                Label("\(count)", systemImage: "text.bubble")
                                    .font(.geist(10))
                                    .foregroundStyle(Theme.muted)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Theme.panel)
    }
}

private struct NavigatorRow<Content: View>: View {
    let depth: Int
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { content }
                .padding(.leading, 10 + CGFloat(depth) * 14)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.sky950 : hovering ? Theme.edge.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
        .help(help)
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
    /// Whether the file tree shows; nil when there are no files for one.
    let tree: Binding<Bool>?

    var body: some View {
        let added = changes.files.reduce(0) { $0 + $1.additions }
        let removed = changes.files.reduce(0) { $0 + $1.deletions }
        HStack(spacing: 10) {
            if let tree {
                Button { tree.wrappedValue.toggle() } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tree.wrappedValue ? Theme.sky300 : Theme.muted)
                .help(tree.wrappedValue ? "Hide the file tree" : "Show the file tree")
            }
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
enum DiffColors {
    static let added = Color(hex: 0x2EA043, opacity: 0.15)
    static let removed = Color(hex: 0xF85149, opacity: 0.15)
    static let addedText = Color(hex: 0x3FB950)
    static let removedText = Color(hex: 0xFF7B72)
}
