import ReeveKit
import SwiftUI

/// Everything the card has changed in its worktree: its commits and what
/// isn't committed yet, new files included, against where the card started.
/// Read again when the tab shows and as Claude works while it does.
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


    var body: some View {
        VStack(spacing: 0) {
            if notGit {
                TabEmptyState(title: "Not a git repository", detail: "This card works in a folder outside git, so there are no changes to show.")
            } else if let changes {
                SummaryBar(changes: changes, loading: loading, reload: { reloads += 1 })
                if changes.files.isEmpty {
                    TabEmptyState(title: "No changes yet", detail: changes.base == nil ? "Nothing here differs from HEAD." : "Nothing here differs from where the card started.")
                } else {
                    DiffList(changes: changes, revision: revision, expanded: expanded) { id, open in
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
    let toggle: (_ id: String, _ open: Bool) -> Void

    /// Past this many lines a file starts closed; a lockfile would otherwise
    /// bury everything after it.
    private static let openLimit = 300

    static func == (a: DiffList, b: DiffList) -> Bool {
        a.revision == b.revision && a.expanded == b.expanded
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows(changes.files)) { row in
                    RowView(row: row) { file in toggle(file.id, isOpen(file)) }
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
    private func rows(_ files: [FileDiff]) -> [Row] {
        var rows: [Row] = []
        for (f, file) in files.enumerated() {
            let open = isOpen(file)
            rows.append(Row(id: "\(f)", kind: .file(file, open: open)))
            guard open else { continue }
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
                    rows.append(Row(id: "\(f).\(h).\(l)", kind: .line(line)))
                }
            }
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
        case file(FileDiff, open: Bool)
        case hunk(String)
        case line(DiffLine)
        case notice(String)
    }

    let id: String
    let kind: Kind
}

private struct RowView: View {
    let row: Row
    let toggle: (FileDiff) -> Void

    var body: some View {
        switch row.kind {
        case let .file(file, open):
            FileHeader(file: file, open: open) { toggle(file) }
        case let .hunk(header):
            Text(header)
                .font(.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(Theme.sky950.opacity(0.35))
        case let .line(line):
            LineView(line: line)
        case let .notice(text):
            Text(text)
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
    }
}

private struct FileHeader: View {
    let file: FileDiff
    let open: Bool
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign)
                .foregroundStyle(signColor)
                .frame(width: 20)
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

/// The count of files and lines, what they're against, and a way to read again.
private struct SummaryBar: View {
    let changes: Worktrees.Changes
    let loading: Bool
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
