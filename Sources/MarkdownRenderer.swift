import AppKit

/// Something drawn behind the text that stands in for hidden syntax.
///
/// `anchor` is a character that is *not* concealed and sits on the decoration's
/// own line. Concealed characters map back to the previous line's last glyph,
/// so positions are always measured from an anchor rather than from `range`.
struct MarkdownDecoration {
    enum Kind: Equatable {
        case quoteBar
        case bullet
        case checkbox(checked: Bool)
        case rule
        case codeBlock(bottomAnchor: Int)
        case codeSpan
        /// One laid-out table row. `columns` holds the boundaries between
        /// columns, measured from the left edge of the text column.
        case tableRow(columns: [CGFloat], isHeader: Bool, isLast: Bool)
    }

    var kind: Kind
    var range: NSRange
    var anchor: Int

    func moved(by delta: Int) -> MarkdownDecoration {
        var moved = self
        moved.range = NSRange(location: range.location + delta, length: range.length)
        moved.anchor = anchor + delta
        if case .codeBlock(let bottom) = kind { moved.kind = .codeBlock(bottomAnchor: bottom + delta) }
        return moved
    }
}

private func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Patterns are literals owned by this file; a bad one is a programmer error.
    return try! NSRegularExpression(pattern: pattern, options: options)
}

/// Styles Markdown in place and records which characters should not be drawn.
///
/// Syntax markers are hidden on every line except the one holding the
/// selection, so the document reads as formatted text but is still exactly the
/// characters on disk. Hiding happens at glyph generation time — see the
/// layout manager delegate in `EditorViewController` — and the marks that would
/// otherwise be lost (bullets, quote bars, rules, code backgrounds) come back
/// as decorations drawn by the text view.
final class MarkdownRenderer {

    // MARK: Output

    private(set) var hidden = IndexSet()
    private(set) var decorations: [MarkdownDecoration] = []
    private(set) var fenceRanges: [NSRange] = []
    private(set) var tables: [MarkdownTable] = []
    /// Width of the text column, which is what a table is stretched to fill.
    var contentWidth: CGFloat = 0
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]

    /// Paragraph range holding the selection; its syntax stays visible.
    var activeRange = NSRange(location: NSNotFound, length: 0)
    var isMarkdown = true
    /// Live preview is switched off for very large documents, where a full
    /// reparse on load would be felt.
    var livePreview = true

    // MARK: Patterns

    private let headingRx = rx("^(#{1,6})([ \t]+)", [.anchorsMatchLines])
    private let quoteRx   = rx("^([ \t]{0,3}(?:>[ \t]?)+)", [.anchorsMatchLines])
    private let listRx    = rx("^([ \t]*)([-*+]|\\d+[.)])([ \t]+)(\\[([ xX])\\][ \t]+)?", [.anchorsMatchLines])
    private let ruleRx    = rx("^[ \t]{0,3}(-[ \t]*){3,}$|^[ \t]{0,3}(\\*[ \t]*){3,}$|^[ \t]{0,3}(_[ \t]*){3,}$", [.anchorsMatchLines])
    private let boldRx    = rx("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)(\\1)")
    private let italicRx  = rx("(?<![\\*_\\w])([*_])(?=[^\\s*_])([^*_]+?)(?<=[^\\s*_])([*_])(?![\\*_\\w])")
    private let strikeRx  = rx("(~~)(?=\\S)(.+?)(?<=\\S)(~~)")
    private let codeRx    = rx("(`+)([^`\n]+)(`+)")
    private let linkRx    = rx("(!?\\[)([^\\]\n]*)(\\]\\()([^)\n]*)(\\))")
    private let autoRx    = rx("(<)((?:https?|mailto):[^>\\s]+)(>)")
    private let fenceEndRx = rx("^[ \t]{0,3}(```|~~~)[ \t]*$")
    private let fenceRx   = rx("^[ \t]{0,3}(```|~~~)[^\n]*(?:\n[\\s\\S]*?)?(?:^[ \t]{0,3}\\1[ \t]*$|\\z)", [.anchorsMatchLines])

    // MARK: Fonts and colours

    private var body: NSFont = .monospacedSystemFont(ofSize: 15, weight: .regular)
    private var mono: NSFont = .monospacedSystemFont(ofSize: 15, weight: .regular)
    private let indentStep: CGFloat = 22

    private var marker: NSColor { .tertiaryLabelColor }
    private var muted: NSColor { .secondaryLabelColor }
    private var accent: NSColor { .controlAccentColor }

    func rebuildBaseAttributes() {
        body = Settings.shared.editorFont
        mono = body.isFixedPitch ? body : .monospacedSystemFont(ofSize: body.pointSize * 0.94, weight: .regular)
        baseAttributes = [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle(),
        ]
    }

    private func paragraphStyle(firstLine: CGFloat = 0, head: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = Settings.shared.lineHeight
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = firstLine
        style.headIndent = head
        return style
    }

    private func variant(_ font: NSFont, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }

    // MARK: Fences

    /// Fenced blocks are the one construct that needs whole-document context.
    /// Returns true when the fence layout changed and everything must reparse.
    @discardableResult
    func rescanFences(in text: NSString) -> Bool {
        let previous = fenceRanges
        if isMarkdown && Settings.shared.syntaxHighlighting {
            fenceRanges = fenceRx.matches(in: text as String,
                                          range: NSRange(location: 0, length: text.length)).map(\.range)
        } else {
            fenceRanges = []
        }
        return previous.count != fenceRanges.count
            || zip(previous, fenceRanges).contains { !NSEqualRanges($0, $1) }
    }

    private func fence(containing range: NSRange) -> NSRange? {
        fenceRanges.first { NSIntersectionRange($0, range).length > 0 }
    }

    // MARK: Tables

    /// Like fences, a table only makes sense whole, so they are found across
    /// the document. Returns true when the set changed and everything must
    /// reparse.
    @discardableResult
    func rescanTables(in text: NSString) -> Bool {
        let previous = tables.map(\.range)
        tables = (isMarkdown && Settings.shared.syntaxHighlighting) ? MarkdownTables.scan(text) : []
        let current = tables.map(\.range)
        return previous.count != current.count
            || zip(previous, current).contains { !NSEqualRanges($0, $1) }
    }

    /// Grows a range to cover any table it touches. A table is laid out as a
    /// whole or not at all, so restyling one of its rows means restyling all.
    func expanded(_ range: NSRange) -> NSRange {
        var result = range
        for table in tables where NSIntersectionRange(table.range, range).length > 0
            || NSLocationInRange(range.location, table.range) {
            result = NSUnionRange(result, table.range)
        }
        return result
    }

    // MARK: Bookkeeping

    func reset() {
        hidden = IndexSet()
        decorations = []
        fenceRanges = []
        tables = []
    }

    /// Slides concealed ranges and decorations past an edit. Anything straddling
    /// the edit is dropped — that paragraph reparses immediately afterwards.
    func shift(after editedRange: NSRange, by delta: Int) {
        guard delta != 0 else { return }
        let pivot = editedRange.location
        let oldEnd = pivot + editedRange.length - delta

        var moved = IndexSet()
        for range in hidden.rangeView {
            if range.upperBound <= pivot {
                moved.insert(integersIn: range)
            } else if range.lowerBound >= oldEnd {
                moved.insert(integersIn: (range.lowerBound + delta)..<(range.upperBound + delta))
            }
        }
        hidden = moved

        decorations = decorations.compactMap { decoration in
            let r = decoration.range
            if NSMaxRange(r) <= pivot { return decoration }
            guard r.location >= oldEnd else { return nil }
            return decoration.moved(by: delta)
        }
    }

    // MARK: Parsing

    func parse(_ storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let text = storage.string as NSString

        hidden.remove(integersIn: range.location..<NSMaxRange(range))
        // Drop only what this parse will emit again. A decoration is emitted
        // while styling the line its range *starts* on — for a code block that
        // is the opening fence — so discarding everything that merely overlaps
        // would lose a block's background whenever a line inside it reparses.
        decorations.removeAll { NSLocationInRange($0.range.location, range) }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        if isMarkdown && Settings.shared.syntaxHighlighting {
            styleLines(storage, text, range)
            styleInline(storage, text, range)
            styleTables(storage, text, range)
        }
        storage.endEditing()
        resolveAnchors(text, range)
    }

    /// Concealment is only fully known once both passes have run, so every
    /// decoration picks its anchor here: the first character on its line that
    /// will actually be drawn, falling back to the line's newline.
    private func resolveAnchors(_ text: NSString, _ range: NSRange) {
        guard text.length > 0 else { return }
        for i in decorations.indices where NSIntersectionRange(decorations[i].range, range).length > 0 {
            let start = min(decorations[i].range.location, text.length - 1)
            let line = contentRange(text, text.lineRange(for: NSRange(location: start, length: 0)))
            var index = start
            while index < NSMaxRange(line), hidden.contains(index) { index += 1 }
            decorations[i].anchor = min(index, text.length - 1)
        }
    }

    private func isActive(_ range: NSRange) -> Bool {
        guard activeRange.location != NSNotFound else { return false }
        return NSIntersectionRange(range, activeRange).length > 0
            || NSLocationInRange(range.location, activeRange)
    }

    /// True when `range` will actually be hidden rather than drawn.
    private func concealed(_ range: NSRange) -> Bool {
        livePreview && range.length > 0 && !isActive(range)
    }

    /// Hides `range` unless live preview is off or its line holds the selection.
    private func conceal(_ range: NSRange) {
        guard concealed(range) else { return }
        hidden.insert(integersIn: range.location..<NSMaxRange(range))
    }

    /// The first character past `range` — the newline at worst — clamped so it
    /// always names a character that exists.
    private func anchor(after range: NSRange, in text: NSString) -> Int {
        min(max(0, text.length - 1), NSMaxRange(range))
    }

    private func contentRange(_ text: NSString, _ line: NSRange) -> NSRange {
        var range = line
        while range.length > 0 {
            let c = text.character(at: NSMaxRange(range) - 1)
            guard c == 10 || c == 13 else { break }
            range.length -= 1
        }
        return range
    }

    // MARK: Block elements

    private func styleLines(_ storage: NSTextStorage, _ text: NSString, _ range: NSRange) {
        var index = range.location
        while index < NSMaxRange(range) {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            styleLine(storage, text, line)
            guard line.length > 0 else { break }
            index = NSMaxRange(line)
        }
    }

    private func styleLine(_ storage: NSTextStorage, _ text: NSString, _ line: NSRange) {
        let content = contentRange(text, line)

        if let fence = fence(containing: line) {
            styleFenceLine(storage, text, line: line, content: content, fence: fence)
            return
        }
        if let m = headingRx.firstMatch(in: text as String, range: content) {
            let level = m.range(at: 1).length
            let scale: [CGFloat] = [1.55, 1.34, 1.20, 1.11, 1.05, 1.0]
            let font = variant(body.withSize((body.pointSize * scale[level - 1]).rounded()), bold: true)
            storage.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: content)
            let marks = NSRange(location: m.range(at: 1).location,
                                length: NSMaxRange(m.range(at: 2)) - m.range(at: 1).location)
            storage.addAttribute(.foregroundColor, value: marker, range: marks)
            conceal(marks)
            return
        }
        if ruleRx.firstMatch(in: text as String, range: content) != nil, content.length > 0 {
            storage.addAttribute(.foregroundColor, value: marker, range: content)
            // The drawn rule stands in for the dashes; never show both.
            if concealed(content) {
                conceal(content)
                decorations.append(MarkdownDecoration(kind: .rule, range: content,
                                                      anchor: anchor(after: content, in: text)))
            }
            return
        }
        if let m = quoteRx.firstMatch(in: text as String, range: content) {
            storage.addAttributes([.font: variant(body, italic: true), .foregroundColor: muted], range: content)
            storage.addAttribute(.paragraphStyle,
                                 value: paragraphStyle(firstLine: indentStep, head: indentStep), range: line)
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
            conceal(m.range(at: 1))
            decorations.append(MarkdownDecoration(kind: .quoteBar, range: content,
                                                  anchor: anchor(after: m.range(at: 1), in: text)))
            return
        }
        if let m = listRx.firstMatch(in: text as String, range: content) {
            styleListLine(storage, text, line: line, content: content, match: m)
        }
    }

    private func styleFenceLine(_ storage: NSTextStorage, _ text: NSString,
                                line: NSRange, content: NSRange, fence: NSRange) {
        storage.addAttributes([.font: mono, .foregroundColor: muted], range: line)
        storage.addAttribute(.paragraphStyle,
                             value: paragraphStyle(firstLine: 12, head: 12), range: line)

        let isOpening = line.location <= fence.location
        // An unterminated fence runs to the end of the file, so position alone
        // would treat the last line of real code as the closing delimiter and
        // hide it. Only conceal a line that is genuinely a fence.
        let isClosing = !isOpening && NSMaxRange(line) >= NSMaxRange(fence)
            && fenceEndRx.firstMatch(in: text as String, range: content) != nil
        if isOpening || isClosing {
            storage.addAttribute(.foregroundColor, value: marker, range: content)
            conceal(content)
        }
        if isOpening {
            let lastIndex = max(fence.location, NSMaxRange(fence) - 1)
            let closing = contentRange(text, text.lineRange(for: NSRange(location: lastIndex, length: 0)))
            decorations.append(MarkdownDecoration(
                kind: .codeBlock(bottomAnchor: anchor(after: closing, in: text)),
                range: fence,
                anchor: anchor(after: content, in: text)))
        }
    }

    private func styleListLine(_ storage: NSTextStorage, _ text: NSString,
                               line: NSRange, content: NSRange, match m: NSTextCheckingResult) {
        let indentText = text.substring(with: m.range(at: 1))
        let columns = indentText.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = min(4, columns / 2)
        let gutter = indentStep * CGFloat(depth)
        let bulletRange = m.range(at: 2)
        let ordered = text.substring(with: bulletRange).count > 1

        // Numbers stay readable, so they live in the gutter; hidden bullets let
        // the text itself start at the content indent.
        let markers = NSRange(location: bulletRange.location,
                              length: NSMaxRange(m.range(at: 3)) - bulletRange.location)
        let revealed = !livePreview || isActive(content)
        let firstLine = (ordered || revealed) ? gutter : gutter + indentStep
        storage.addAttribute(.paragraphStyle,
                             value: paragraphStyle(firstLine: firstLine, head: gutter + indentStep),
                             range: line)

        if ordered {
            storage.addAttribute(.foregroundColor, value: accent, range: bulletRange)
            return
        }
        storage.addAttribute(.foregroundColor, value: marker, range: markers)

        if m.range(at: 4).location != NSNotFound {
            let checked = text.substring(with: m.range(at: 5)).lowercased() == "x"
            let box = NSRange(location: bulletRange.location,
                              length: NSMaxRange(m.range(at: 4)) - bulletRange.location)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 4))
            conceal(box)
            if checked {
                let body = NSRange(location: NSMaxRange(box), length: NSMaxRange(content) - NSMaxRange(box))
                if body.length > 0 {
                    storage.addAttributes([.foregroundColor: muted,
                                           .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: body)
                }
            }
            if !revealed {
                decorations.append(MarkdownDecoration(kind: .checkbox(checked: checked), range: box,
                                                      anchor: anchor(after: box, in: text)))
            }
            return
        }
        conceal(markers)
        if !revealed {
            decorations.append(MarkdownDecoration(kind: .bullet, range: markers,
                                                  anchor: anchor(after: markers, in: text)))
        }
    }

    // MARK: Tables

    private let cellPadding: CGFloat = 10

    private func styleTables(_ storage: NSTextStorage, _ text: NSString, _ range: NSRange) {
        guard livePreview, contentWidth > 80 else { return }
        for table in tables where NSIntersectionRange(table.range, range).length > 0 {
            // The caret anywhere inside puts the whole table back to raw
            // Markdown — markers, pipes and all — not just its own line.
            guard !isActive(table.range) else { continue }
            layOut(table, in: storage, text: text)
        }
    }

    private func layOut(_ table: MarkdownTable, in storage: NSTextStorage, text: NSString) {
        // The header is bold, and bold is wider, so set it before measuring.
        if let header = table.header {
            for cell in header.cells where cell.length > 0 {
                let current = storage.attribute(.font, at: cell.location, effectiveRange: nil) as? NSFont ?? body
                storage.addAttribute(.font, value: variant(current, bold: true), range: cell)
            }
        }

        var measured: [[CGFloat]] = []
        for row in table.rows {
            measured.append((0..<table.columnCount).map { column in
                column < row.cells.count ? width(of: row.cells[column], in: storage, text: text) : 0
            })
        }

        var columns = (0..<table.columnCount).map { column in
            (measured.map { $0[column] }.max() ?? 0) + cellPadding * 2
        }
        let natural = columns.reduce(0, +)
        // A hair under the column, so a row filling it cannot wrap.
        let available = contentWidth - 1
        // Too wide to lay out without squeezing text: leave it as written.
        guard natural > 0, natural <= available else { return }

        // Full width: hand out the slack in proportion to what each column needs.
        let slack = available - natural
        for index in columns.indices { columns[index] += slack * (columns[index] / natural) }

        var edges: [CGFloat] = [0]
        for width in columns { edges.append(edges[edges.count - 1] + width) }

        collapse(table.delimiter, in: storage)
        for (index, row) in table.rows.enumerated() {
            place(row, measured: measured[index], edges: edges, table: table,
                  isHeader: index == 0, isLast: index == table.rows.count - 1,
                  in: storage)
        }
    }

    /// Positions one row's cells by widening the character before each of them.
    /// The text is never touched: the gaps are kerning, and everything that is
    /// not cell text — the pipes and their padding — is concealed.
    private func place(_ row: MarkdownTable.Row, measured: [CGFloat], edges: [CGFloat],
                       table: MarkdownTable, isHeader: Bool, isLast: Bool,
                       in storage: NSTextStorage) {
        // Conceal the pipes and their padding only. Clearing the whole row and
        // reinstating the cells would also un-hide the inline markers inside
        // them, which would then be drawn wider than they were measured.
        var gapStart = row.content.location
        for (column, cell) in row.cells.enumerated() {
            // A row may carry more cells than the header declares columns.
            // There is nowhere to put those, so they go with the pipes.
            guard column < table.columnCount else { break }
            conceal(NSRange(location: gapStart, length: max(0, cell.location - gapStart)))
            gapStart = NSMaxRange(cell)
        }
        conceal(NSRange(location: gapStart, length: max(0, NSMaxRange(row.content) - gapStart)))

        var pen: CGFloat = 0        // where the next glyph lands
        var indent: CGFloat = 0     // used until something has been drawn
        var carrier: Int?           // last drawn character, which holds the gap
        var carried: CGFloat = 0

        for column in 0..<table.columnCount {
            let cell = column < row.cells.count ? row.cells[column] : NSRange(location: 0, length: 0)
            let cellWidth = measured[column]
            let target: CGFloat
            switch table.alignments[column] {
            case .leading:  target = edges[column] + cellPadding
            case .trailing: target = edges[column + 1] - cellPadding - cellWidth
            case .center:   target = edges[column] + (edges[column + 1] - edges[column] - cellWidth) / 2
            }

            let gap = max(0, target - pen)
            if let carrier {
                carried += gap
                storage.addAttribute(.kern, value: carried, range: NSRange(location: carrier, length: 1))
            } else {
                indent = target
            }
            pen = target + cellWidth
            // The gap rides on the last character that is actually drawn: a
            // concealed one is a null glyph with no advance to widen.
            if let last = lastVisible(in: cell) {
                carrier = last
                carried = 0
            }
        }

        storage.addAttribute(.paragraphStyle,
                             value: paragraphStyle(firstLine: indent, head: indent),
                             range: row.content)
        decorations.append(MarkdownDecoration(
            kind: .tableRow(columns: edges, isHeader: isHeader, isLast: isLast),
            range: row.content,
            anchor: row.content.location))
    }

    private func lastVisible(in range: NSRange) -> Int? {
        var index = NSMaxRange(range) - 1
        while index >= range.location {
            if !hidden.contains(index) { return index }
            index -= 1
        }
        return nil
    }

    /// Hides a line and takes its height away, so the delimiter row leaves no
    /// gap between the header and the body.
    private func collapse(_ line: NSRange, in storage: NSTextStorage) {
        guard line.length > 0 else { return }
        conceal(line)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        storage.addAttributes([.font: body.withSize(1), .paragraphStyle: style], range: line)
    }

    /// Width of a cell as it will actually be drawn: concealed characters take
    /// no space, and whatever styling the inline pass applied counts.
    private func width(of range: NSRange, in storage: NSTextStorage, text: NSString) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let piece = NSMutableAttributedString()
        var index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange(location: 0, length: 0)
            var attributes = storage.attributes(at: index, effectiveRange: &effective)
            attributes[.paragraphStyle] = nil
            attributes[.kern] = nil
            let end = min(NSMaxRange(effective), NSMaxRange(range))
            var cursor = index
            while cursor < end {
                let concealed = hidden.contains(cursor)
                var run = cursor
                while run < end, hidden.contains(run) == concealed { run += 1 }
                if !concealed {
                    piece.append(NSAttributedString(
                        string: text.substring(with: NSRange(location: cursor, length: run - cursor)),
                        attributes: attributes))
                }
                cursor = run
            }
            index = end
        }
        return piece.size().width.rounded(.up)
    }

    // MARK: Inline elements

    private func styleInline(_ storage: NSTextStorage, _ text: NSString, _ range: NSRange) {
        let string = text as String

        // Code spans first: nothing inside them is emphasis.
        var spans: [NSRange] = []
        codeRx.enumerateMatches(in: string, range: range) { m, _, _ in
            guard let m, self.fence(containing: m.range) == nil else { return }
            spans.append(m.range)
        }
        func inSpan(_ r: NSRange) -> Bool { spans.contains { NSIntersectionRange($0, r).length > 0 } }

        func emphasis(_ regex: NSRegularExpression, bold: Bool = false, italic: Bool = false, strike: Bool = false) {
            regex.enumerateMatches(in: string, range: range) { m, _, _ in
                guard let m, self.fence(containing: m.range) == nil, !inSpan(m.range) else { return }
                if strike {
                    storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .foregroundColor: self.muted], range: m.range)
                } else {
                    let current = storage.attribute(.font, at: m.range.location, effectiveRange: nil) as? NSFont ?? self.body
                    storage.addAttribute(.font, value: self.variant(current, bold: bold, italic: italic), range: m.range)
                }
                for group in [1, 3] {
                    storage.addAttribute(.foregroundColor, value: self.marker, range: m.range(at: group))
                    self.conceal(m.range(at: group))
                }
            }
        }
        emphasis(boldRx, bold: true)
        emphasis(italicRx, italic: true)
        emphasis(strikeRx, strike: true)

        linkRx.enumerateMatches(in: string, range: range) { m, _, _ in
            guard let m, self.fence(containing: m.range) == nil, !inSpan(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: self.marker, range: m.range)
            storage.addAttributes([.foregroundColor: self.accent], range: m.range(at: 2))
            self.conceal(m.range(at: 1))
            self.conceal(NSRange(location: m.range(at: 3).location,
                                 length: NSMaxRange(m.range) - m.range(at: 3).location))
        }
        autoRx.enumerateMatches(in: string, range: range) { m, _, _ in
            guard let m, self.fence(containing: m.range) == nil, !inSpan(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: self.accent, range: m.range(at: 2))
            for group in [1, 3] {
                storage.addAttribute(.foregroundColor, value: self.marker, range: m.range(at: group))
                self.conceal(m.range(at: group))
            }
        }
        for span in spans {
            let m = codeRx.firstMatch(in: string, range: span)
            storage.addAttributes([.font: mono, .foregroundColor: muted], range: span)
            guard let m else { continue }
            for group in [1, 3] {
                storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: group))
                conceal(m.range(at: group))
            }
            decorations.append(MarkdownDecoration(kind: .codeSpan, range: m.range(at: 2),
                                                  anchor: m.range(at: 2).location))
        }
    }
}
