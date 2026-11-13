import Foundation

/// A Markdown document's blocks: enough to lay out a plan. Inline markup —
/// bold, code, links — is left in the text for the view to style.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A bullet or numbered item. `marker` is "•" or the item's number with its dot.
    case listItem(marker: String, indent: Int, text: String)
    case code(language: String?, text: String)
    case quote(String)
    /// Table rows, cells already split; the `|---|` line is dropped.
    case table([[String]])
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var fence: (marker: String, language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))) }
            if !table.isEmpty { blocks.append(.table(table)) }
            paragraph = []; quote = []; table = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(trimmed.first!) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) {
                    table.append(cells)
                }
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !table.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            // A line carrying on from a list item belongs to it.
            if paragraph.isEmpty, quote.isEmpty, table.isEmpty, line.hasPrefix("  "), case let .listItem(marker, indent, text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, indent: indent, text: text + " " + trimmed)
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(trimmed)
        }
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(spaces)
        let indent = spaces / 2
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // A task list's box, as a box.
            if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + text.dropFirst(4) }
            return .listItem(marker: "•", indent: indent, text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " {
                return .listItem(marker: digits + ".", indent: indent, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
