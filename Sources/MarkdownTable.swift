import Foundation

/// A GitHub-flavoured Markdown table: a row of cells, a delimiter row saying
/// how each column is aligned, and the rows that follow.
struct MarkdownTable {

    enum Alignment {
        case leading, center, trailing
    }

    struct Row {
        /// The line without its newline.
        var content: NSRange
        /// Each cell's text, trimmed of the padding around it.
        var cells: [NSRange]
    }

    /// First line's start to the last line's end, newline excluded.
    var range: NSRange
    /// The `|---|---|` line, which is never shown once the table is laid out.
    var delimiter: NSRange
    var alignments: [Alignment]
    /// Header first, then the body. The delimiter row is not included.
    var rows: [Row]

    var columnCount: Int { alignments.count }
    var header: Row? { rows.first }
    var body: ArraySlice<Row> { rows.dropFirst() }
}

enum MarkdownTables {

    /// Finds every table in the document. A row only counts as a table when the
    /// line under it is a delimiter with the same number of cells, which is
    /// what keeps a stray sentence containing a pipe from being swallowed.
    static func scan(_ text: NSString) -> [MarkdownTable] {
        var tables: [MarkdownTable] = []
        var index = 0

        while index < text.length {
            let headerLine = text.lineRange(for: NSRange(location: index, length: 0))
            guard headerLine.length > 0 else { break }
            let headerContent = contentRange(text, headerLine)
            let next = NSMaxRange(headerLine)

            guard next < text.length else { break }
            let headerCells = cells(in: text, content: headerContent)

            guard !headerCells.isEmpty else {
                index = next
                continue
            }

            let delimiterLine = text.lineRange(for: NSRange(location: next, length: 0))
            let delimiterCells = cells(in: text, content: contentRange(text, delimiterLine))

            guard delimiterCells.count == headerCells.count,
                  let alignments = alignments(in: text, cells: delimiterCells) else {
                index = next
                continue
            }

            var rows = [MarkdownTable.Row(content: headerContent, cells: headerCells)]
            var end = NSMaxRange(delimiterLine)
            var cursor = end

            // Body rows run until a line that has no cells at all.
            while cursor < text.length {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                guard line.length > 0 else { break }
                let content = contentRange(text, line)
                let rowCells = cells(in: text, content: content)
                guard !rowCells.isEmpty else { break }
                rows.append(MarkdownTable.Row(content: content, cells: rowCells))
                end = NSMaxRange(content)
                cursor = NSMaxRange(line)
            }

            tables.append(MarkdownTable(
                range: NSRange(location: headerContent.location, length: end - headerContent.location),
                delimiter: contentRange(text, delimiterLine),
                alignments: alignments,
                rows: rows))
            index = cursor
        }
        return tables
    }

    // MARK: - Pieces

    static func contentRange(_ text: NSString, _ line: NSRange) -> NSRange {
        var range = line
        while range.length > 0 {
            let c = text.character(at: NSMaxRange(range) - 1)
            guard c == 10 || c == 13 else { break }
            range.length -= 1
        }
        return range
    }

    static func trimmed(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    private static let pipe: unichar = 124
    private static let backslash: unichar = 92

    /// Cell ranges for one row, trimmed, with escaped pipes left alone. Empty
    /// when the line has no unescaped pipe and so is not a table row.
    private static func cells(in text: NSString, content: NSRange) -> [NSRange] {
        guard content.length > 0 else { return [] }

        var pieces: [NSRange] = []
        var start = content.location
        var index = content.location
        var sawPipe = false
        let end = NSMaxRange(content)

        while index < end {
            let c = text.character(at: index)
            if c == backslash, index + 1 < end {
                index += 2
                continue
            }
            if c == pipe {
                sawPipe = true
                pieces.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        pieces.append(NSRange(location: start, length: end - start))
        guard sawPipe else { return [] }

        // A leading or trailing pipe brackets the row rather than separating
        // cells, so the empty piece each one produces is not a column.
        if text.character(at: content.location) == pipe, !pieces.isEmpty {
            pieces.removeFirst()
        }
        let last = NSMaxRange(content) - 1
        if text.character(at: last) == pipe,
           !(last > content.location && text.character(at: last - 1) == backslash),
           !pieces.isEmpty {
            pieces.removeLast()
        }
        guard !pieces.isEmpty else { return [] }
        return pieces.map { trimmed(text, $0) }
    }

    /// Reads `---`, `:---`, `---:` and `:---:` into column alignments, and
    /// refuses anything that is not a delimiter row.
    private static func alignments(in text: NSString, cells: [NSRange]) -> [MarkdownTable.Alignment]? {
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            let piece = text.substring(with: cell)
            guard piece.range(of: "^:?-+:?$", options: .regularExpression) != nil else { return nil }
            let leading = piece.hasPrefix(":")
            let trailing = piece.hasSuffix(":")
            result.append(leading && trailing ? .center : trailing ? .trailing : .leading)
        }
        return result.isEmpty ? nil : result
    }
}
