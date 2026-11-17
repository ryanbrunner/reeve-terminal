import AppKit
import ReeveKit
import SwiftUI

/// The card's plan, as Claude wrote it in plan mode. Read from its file each
/// time the tab shows, so an edit made since the approval is what you see.
///
/// A part of the plan can take a comment, as a line of the diff can: sent to
/// Claude at once, or kept with others and sent together. While the plan
/// dialog is open they go in as its feedback, and Claude revises the plan.
struct PlanView: View {
    @EnvironmentObject var board: Board
    let card: Card
    @State private var text: String?
    @State private var blocks: [MarkdownBlock.Located] = []
    @State private var loaded = false
    /// The comment or reply being written, if any.
    @State private var editing: Editing?
    @StateObject private var drafts = Drafts()

    var body: some View {
        VStack(spacing: 0) {
            if let text {
                let threads = card.planReview ?? []
                let blocker = board.reviewBlocker(card.id, .plan)
                let path = card.planPath ?? "plan"
                let placement = PlanReviewPlacement(threads, plan: path, blocks: blocks)
                let review = ReviewContext(threads: threads, editing: editing, blocker: blocker, working: card.activity == .running, drafts: drafts, actions: actions)
                PlanBar(card: card, text: text, pending: threads.filter(\.hasPending).count, blocker: blocker) {
                    board.submitReview(card.id, .plan)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !placement.outdated.isEmpty {
                            Text("On an earlier draft")
                                .font(.geist(12, .medium))
                                .foregroundStyle(Theme.muted)
                            ForEach(placement.outdated) { thread in
                                ThreadView(thread: thread, outdated: true, review: review, inset: 0)
                            }
                            Rectangle().fill(Theme.edge).frame(height: 1).padding(.vertical, 6)
                        }
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            let anchor = ReviewAnchor(plan: path, block: block)
                            BlockRow(block: block.block) { editing = .line(anchor) }
                            ForEach(placement.byBlock[anchor.key] ?? []) { thread in
                                ThreadView(thread: thread, outdated: false, review: review, inset: 0)
                            }
                            if editing == .line(anchor) {
                                Composer(draftKey: Editing.line(anchor).draftKey, drafts: drafts, placeholder: "Leave a comment on the plan", sendLabel: "Comment now", blocker: blocker, post: actions.post, cancel: { editing = nil })
                                    .modifier(ReviewInset(leading: 0))
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            } else if loaded {
                TabEmptyState(
                    title: "No plan yet",
                    detail: "When Claude writes a plan in plan mode, it shows here. Start a card with Plan, or press ⇧Tab in the terminal to switch modes."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // A new plan, a new draft, or the end of a turn may mean new text.
        .task(id: "\(card.plan?.hashValue ?? 0)|\(card.planPath ?? "")|\(card.activity.rawValue)") {
            let latest = await board.loadPlan(card.id)
            if latest != text {
                text = latest
                blocks = latest.map(MarkdownBlock.locate) ?? []
            }
            loaded = true
        }
    }

    private var actions: ReviewActions {
        let id = card.id
        return ReviewActions(
            edit: { editing = $0 },
            post: { text, send in
                switch editing {
                case let .line(anchor):
                    board.comment(on: anchor, text, in: id, .plan, send: send)
                case let .reply(thread):
                    board.reply(to: thread, text, in: id, .plan, send: send)
                case nil:
                    return
                }
                if let key = editing?.draftKey { drafts.texts[key] = nil }
                editing = nil
            },
            send: { board.submitReview(id, .plan, only: $0) },
            discard: { board.discardDrafts($0, in: id, .plan) },
            resolve: { board.resolve($0, $1, in: id, .plan) }
        )
    }
}

/// Where the plan lives, and what to do with it.
private struct PlanBar: View {
    @EnvironmentObject var board: Board
    let card: Card
    let text: String
    /// Threads with a draft not yet sent.
    let pending: Int
    let blocker: String?
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let path = card.planPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            Spacer()
            if pending > 0 {
                Button("Submit review (\(pending))", action: submit)
                    .buttonStyle(PrimaryButtonStyle(height: 22))
                    .disabled(blocker != nil)
                    .opacity(blocker == nil ? 1 : 0.5)
                    .help(blocker ?? (board.planDialogs.contains(card.id) ? "Send your comments to Claude instead of approving the plan" : "Send your comments to Claude"))
            }
            approval
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(SecondaryButtonStyle(height: 22))
            if let path = card.planPath, FileManager.default.fileExists(atPath: path) {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("Open the plan file in its app")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
    }

    /// Approve while Claude Code's plan dialog is open, and say so once the
    /// plan is approved. Not while VIBES MODE is approving it itself; if that
    /// misses, the button is there.
    @ViewBuilder private var approval: some View {
        if card.planApproved == true {
            Label("Approved", systemImage: "checkmark")
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
        } else if board.answeringPlans.contains(card.id) {
            Text("Sending comments…").font(.geist(12)).foregroundStyle(Theme.muted)
        } else if board.acceptingPlans.contains(card.id) || board.approvingPlans.contains(card.id) {
            Text("Approving…").font(.geist(12)).foregroundStyle(Theme.muted)
        } else if board.planDialogs.contains(card.id), board.live.contains(card.id) {
            Button("Approve") { board.acceptPlan(card.id) }
                .buttonStyle(PrimaryButtonStyle(height: 22))
                .help("Approve the plan and switch Claude to auto mode")
        }
    }
}

/// A block of the plan, with a button in the margin to comment on it.
private struct BlockRow: View {
    let block: MarkdownBlock
    let comment: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: comment) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.sky600))
            }
            .buttonStyle(.plain)
            .help("Comment on this part of the plan")
            .opacity(hovering ? 1 : 0)
            .frame(width: 20)
            BlockView(block: block)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The button sits in the margin, the block where it was.
        .padding(.leading, -28)
        .padding(.top, topSpace)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Room above a heading, outside the row so the button lines up with it.
    private var topSpace: CGFloat {
        guard case let .heading(level, _) = block else { return 0 }
        return level <= 2 ? 10 : 4
    }
}

/// One Markdown block, in the board's type.
private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(.geist(level == 1 ? 20 : level == 2 ? 16 : 14, .semibold))
                .foregroundStyle(Theme.text)
        case let .paragraph(text):
            inline(text).font(.geist(13.5)).foregroundStyle(Theme.textSoft).lineSpacing(3)
        case let .listItem(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.mono(12)).foregroundStyle(Theme.muted).frame(minWidth: 14, alignment: .trailing)
                inline(text).font(.geist(13.5)).foregroundStyle(Theme.textSoft).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .code(_, text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.mono(12)).foregroundStyle(Theme.textSoft).padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
        case let .quote(text):
            HStack(spacing: 10) {
                Rectangle().fill(Theme.edgeStrong).frame(width: 2)
                inline(text).font(.geist(13.5)).foregroundStyle(Theme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                                .font(.geist(12.5, index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? Theme.text : Theme.textSoft)
                        }
                    }
                    if index == 0 { Divider().overlay(Theme.edge) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.edge))
        case .rule:
            Rectangle().fill(Theme.edge).frame(height: 1).padding(.vertical, 6)
        }
    }

    /// Bold, italics, links and `code` within a line.
    private func inline(_ text: String) -> Text {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .mono(12)
                attributed[run.range].foregroundColor = Theme.sky200
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Theme.sky300
            }
        }
        return Text(attributed)
    }
}

/// What a tab shows when it has nothing to show.
struct TabEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.geist(14, .medium)).foregroundStyle(Theme.text)
            Text(detail)
                .font(.geist(12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
