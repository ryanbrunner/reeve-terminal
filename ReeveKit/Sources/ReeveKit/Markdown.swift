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
        locate(markdown).map(\.block)
    }

    /// A block and where it came from: what a comment on it is anchored to.
    public struct Located: Equatable, Sendable {
        public var block: MarkdownBlock
        /// The block's first line in the document, from 1.
        public var line: Int
        /// The block's lines as written.
        public var source: String
    }

    public static func locate(_ markdown: String) -> [Located] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\r", with: "") }
        var located: [Located] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var fence: (marker: String, language: String?, lines: [String])?
        /// The open block's first line and its latest, as indexes into `lines`.
        var span = (start: 0, end: 0)

        func add(_ block: MarkdownBlock, _ start: Int, _ end: Int) {
            located.append(Located(block: block, line: start + 1, source: lines[start...end].joined(separator: "\n")))
        }
        func flush() {
            if !paragraph.isEmpty { add(.paragraph(paragraph.joined(separator: " ")), span.start, span.end) }
            if !quote.isEmpty { add(.quote(quote.joined(separator: " ")), span.start, span.end) }
            if !table.isEmpty { add(.table(table), span.start, span.end) }
            paragraph = []; quote = []; table = []
        }
        /// Starts a paragraph, quote or table at `i`, or carries one on to it.
        func extend(_ i: Int) {
            if paragraph.isEmpty, quote.isEmpty, table.isEmpty { span.start = i }
            span.end = i
        }

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open.marker) {
                    add(.code(language: open.language, text: open.lines.joined(separator: "\n")), span.start, i)
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
                span.start = i
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if let heading = heading(trimmed) {
                flush()
                add(heading, i, i)
                continue
            }
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1, "-*_".contains(trimmed.first!) {
                flush()
                add(.rule, i, i)
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                extend(i)
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
                extend(i)
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flush()
                add(item, i, i)
                continue
            }
            // A line carrying on from a list item belongs to it.
            if paragraph.isEmpty, quote.isEmpty, table.isEmpty, line.hasPrefix("  "), let last = located.last, case let .listItem(marker, indent, text) = last.block {
                located[located.count - 1].block = .listItem(marker: marker, indent: indent, text: text + " " + trimmed)
                located[located.count - 1].source += "\n" + line
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            extend(i)
            paragraph.append(trimmed)
        }
        if let open = fence {
            add(.code(language: open.language, text: open.lines.joined(separator: "\n")), span.start, lines.count - 1)
        }
        flush()
        return located
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
