import AppKit
import ReeveKit
import SwiftUI

/// The card's plan, as Claude wrote it in plan mode. Read from its file each
/// time the tab shows, so an edit made since the approval is what you see.
struct PlanView: View {
    @EnvironmentObject var board: Board
    let card: Card
    @State private var text: String?
    @State private var blocks: [MarkdownBlock] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            if let text {
                PlanBar(path: card.planPath, text: text)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            BlockView(block: block)
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
                blocks = latest.map(MarkdownBlock.parse) ?? []
            }
            loaded = true
        }
    }
}

/// Where the plan lives, and what to do with it.
private struct PlanBar: View {
    let path: String?
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(SecondaryButtonStyle(height: 22))
            if let path, FileManager.default.fileExists(atPath: path) {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(SecondaryButtonStyle(height: 22))
                    .help("Open the plan file in its app")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
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
                .padding(.top, level <= 2 ? 10 : 4)
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
