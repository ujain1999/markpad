import AppKit

/// The editor surface. Everything it does is a plain text edit — the file on
/// disk is always exactly what you see.
final class MarkpadTextView: NSTextView {

    private static let listPrefix = try! NSRegularExpression(
        pattern: "^([ \t]*)([-*+]|(\\d+)([.)]))([ \t]+)(\\[[ xX]\\][ \t]+)?")
    private static let quotePrefix = try! NSRegularExpression(
        pattern: "^([ \t]*(?:>[ \t]?)+)")

    var isMarkdown: Bool = true
    weak var renderer: MarkdownRenderer?

    /// Total paragraphs in the document, used to size the line number margin so
    /// it does not jump about as you scroll.
    var documentLineCount = 1 {
        didSet { if documentLineCount != oldValue { needsDisplay = true } }
    }
    private var gutterFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var digitWidth: CGFloat = 8

    /// Space the line numbers need, including the gap to the text. Zero when
    /// they are switched off.
    var gutterWidth: CGFloat {
        guard Settings.shared.showLineNumbers else { return 0 }
        let digits = max(2, String(max(1, documentLineCount)).count)
        return (CGFloat(digits) * digitWidth).rounded(.up) + 14
    }

    /// Recomputed whenever the editor font changes.
    func refreshGutterMetrics() {
        let body = Settings.shared.editorFont
        gutterFont = .monospacedDigitSystemFont(ofSize: max(9, body.pointSize * 0.85), weight: .regular)
        digitWidth = ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
        needsDisplay = true
    }

    // MARK: - Caret

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        r.size.width = 2

        // The caret otherwise fills the whole line box, which is much taller
        // than the text once line height is applied. Size it to the text on the
        // caret's own line, and because the extra line height sits above the
        // text, anchor it to the bottom of the box rather than centring it.
        let font = caretFont
        let textHeight = (font.ascender + abs(font.descender)).rounded()
        if rect.height > textHeight {
            r.origin.y = rect.maxY - textHeight
            r.size.height = textHeight
        }
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    /// The font in force where the caret sits, so it matches a heading's size
    /// rather than the body text's.
    private var caretFont: NSFont {
        let fallback = (typingAttributes[.font] as? NSFont) ?? font ?? .systemFont(ofSize: 15)
        guard let storage = textStorage, storage.length > 0 else { return fallback }
        let index = min(max(0, selectedRange().location), storage.length - 1)
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? fallback
    }

    // MARK: - Decorations

    /// Draws what the hidden syntax used to say: bullets, checkboxes, quote
    /// bars, rules and the backgrounds behind code.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage else { return }
        drawLineNumbers(in: rect, layout: layout, container: container, storage: storage)
        guard let renderer, !renderer.decorations.isEmpty, layout.numberOfGlyphs > 0 else { return }

        let origin = textContainerOrigin
        let padding = container.lineFragmentPadding
        let contentWidth = container.size.width - padding * 2
        let pointSize = renderer.baseAttributes[.font] as? NSFont ?? font ?? .systemFont(ofSize: 15)
        let em = pointSize.pointSize

        let visibleGlyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        /// Line fragment holding `character` plus its text baseline, in view
        /// coordinates. Marks sit on the baseline, not in the middle of the
        /// line box, which extra line height would throw off.
        func metrics(at character: Int) -> (line: NSRect, baseline: CGFloat) {
            let index = min(max(0, character), max(0, storage.length - 1))
            let glyph = min(layout.glyphIndexForCharacter(at: index), layout.numberOfGlyphs - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: origin.x, dy: origin.y)
            return (line, line.minY + layout.location(forGlyphAt: glyph).y)
        }
        func lineRect(at character: Int) -> NSRect { metrics(at: character).line }

        func indent(at character: Int) -> CGFloat {
            let index = min(max(0, character), max(0, storage.length - 1))
            guard storage.length > 0 else { return 0 }
            let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            return style?.headIndent ?? 0
        }

        for decoration in renderer.decorations
        where NSIntersectionRange(decoration.range, visible).length > 0 {
            let (line, baseline) = metrics(at: decoration.anchor)
            let gutter = line.minX + padding + indent(at: decoration.anchor)

            switch decoration.kind {
            case .bullet:
                let size = max(4.5, em * 0.30)
                let dot = NSRect(x: gutter - 13 - size / 2, y: baseline - em * 0.28 - size / 2,
                                 width: size, height: size)
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: dot).fill()

            case .checkbox(let checked):
                let side = max(11, em * 0.8)
                let box = NSRect(x: gutter - 14 - side / 2, y: baseline - em * 0.30 - side / 2,
                                 width: side, height: side)
                let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
                if checked {
                    NSColor.controlAccentColor.setFill()
                    path.fill()
                    // The view is flipped, so the tick's low point has the larger y.
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: box.minX + side * 0.25, y: box.midY + side * 0.02))
                    tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.maxY - side * 0.27))
                    tick.line(to: NSPoint(x: box.maxX - side * 0.21, y: box.minY + side * 0.28))
                    tick.lineWidth = max(1.5, side * 0.13)
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    tick.stroke()
                } else {
                    NSColor.tertiaryLabelColor.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()
                }

            case .quoteBar:
                let bar = NSRect(x: gutter - 14, y: line.minY + 1, width: 3, height: line.height - 2)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()

            case .rule:
                NSColor.quaternaryLabelColor.setFill()
                NSRect(x: line.minX + padding, y: (line.midY - 0.5).rounded(),
                       width: contentWidth, height: 1).fill()

            case .codeBlock(let bottomAnchor):
                // A hidden fence leaves a blank row at each end of the block.
                // Those rows are the block's padding, so take a little back as
                // the gap to the text outside — otherwise a block written with
                // no blank line around it sits flush against its neighbours.
                // When a fence is visible, or absent at the end of the file,
                // there is no such row to borrow from, so grow instead.
                func usedMaxY(at character: Int) -> CGFloat {
                    let index = min(max(0, character), max(0, storage.length - 1))
                    let glyph = min(layout.glyphIndexForCharacter(at: index), layout.numberOfGlyphs - 1)
                    return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + origin.y
                }
                let hidden = renderer.hidden
                let topRowIsBlank = hidden.contains(decoration.range.location)
                let bottomRowIsBlank = bottomAnchor > 0 && hidden.contains(bottomAnchor - 1)

                // Never crop the code itself: the last line before the closing
                // fence sets how far the box must reach.
                let string = storage.string as NSString
                let closing = string.lineRange(
                    for: NSRange(location: min(bottomAnchor, max(0, string.length - 1)), length: 0))
                let lastCodeLine = max(decoration.range.location, closing.location - 1)

                let top = line.minY + (topRowIsBlank ? 7 : -3)
                let bottom = max(usedMaxY(at: bottomAnchor) + (bottomRowIsBlank ? -7 : 3),
                                 usedMaxY(at: lastCodeLine) + 4)
                guard bottom > top else { continue }
                NSColor.labelColor.withAlphaComponent(0.055).setFill()
                NSBezierPath(roundedRect: NSRect(x: line.minX + padding, y: top,
                                                 width: contentWidth, height: bottom - top),
                             xRadius: 6, yRadius: 6).fill()

            case .tableRow(let columns, let isHeader, let isLast):
                guard let first = columns.first, let last = columns.last else { continue }
                let left = line.minX + padding
                let grid = NSColor.quaternaryLabelColor
                let edge = NSColor.tertiaryLabelColor

                grid.setFill()
                for column in columns {
                    NSRect(x: (left + column).rounded(), y: line.minY,
                           width: 1, height: line.height).fill()
                }

                let span = last - first
                if isHeader {
                    NSRect(x: left, y: line.minY, width: span, height: 1).fill()
                    edge.setFill()
                    NSRect(x: left, y: line.maxY - 1, width: span, height: 1).fill()
                } else {
                    if isLast { edge.setFill() }
                    NSRect(x: left, y: line.maxY - 1, width: span, height: 1).fill()
                }

            case .codeSpan:
                let inBounds = NSIntersectionRange(decoration.range,
                                                   NSRange(location: 0, length: storage.length))
                guard inBounds.length > 0 else { continue }
                let glyphs = layout.glyphRange(forCharacterRange: inBounds, actualCharacterRange: nil)
                // A table row pads its cells by widening the last character, so
                // discount that or the pill stretches to the column's edge.
                let trailingKern = (storage.attribute(.kern, at: NSMaxRange(inBounds) - 1,
                                                      effectiveRange: nil) as? CGFloat) ?? 0
                var pieces: [NSRect] = []
                layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                               withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                               in: container) { piece, _ in
                    pieces.append(piece)
                }
                NSColor.labelColor.withAlphaComponent(0.075).setFill()
                for (index, piece) in pieces.enumerated() {
                    var rect = piece
                    if index == pieces.count - 1 { rect.size.width -= trailingKern }
                    guard rect.width > 0 else { continue }
                    let pill = rect.offsetBy(dx: origin.x, dy: origin.y)
                        .insetBy(dx: -2.5, dy: rect.height * 0.17)
                    NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                }
            }
        }
    }

    // MARK: - Line numbers

    /// Numbers live in the left margin beside the text column rather than at
    /// the window edge, so they stay next to the words however wide the window
    /// gets. Only the first fragment of a paragraph is numbered, so wrapped
    /// lines share one number.
    private func drawLineNumbers(in rect: NSRect, layout: NSLayoutManager,
                                 container: NSTextContainer, storage: NSTextStorage) {
        guard Settings.shared.showLineNumbers, gutterWidth > 0 else { return }

        let text = storage.string as NSString
        let origin = textContainerOrigin
        let rightEdge = origin.x + container.lineFragmentPadding - 10
        let active = renderer?.activeRange ?? NSRange(location: NSNotFound, length: 0)

        let bodyFont = (renderer?.baseAttributes[.font] as? NSFont) ?? font ?? .systemFont(ofSize: 15)

        /// A line's baseline sits one descender up from the bottom of the space
        /// its text actually occupies, because extra line height is added above
        /// the text. It has to come from the used rect rather than the fragment,
        /// which also carries any trailing paragraph spacing, and cannot come
        /// from the glyph: a blank line's only glyph is the newline, whose
        /// reported position is the bottom of the fragment.
        func baselineOfLine(at index: Int, glyph: Int) -> CGFloat {
            let lineFont = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? bodyFont
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            return used.maxY + origin.y - lineFont.descender.magnitude
        }
        // Where a string's own baseline sits below the point it is drawn at.
        // The font's ascender alone leaves out leading, which is what made the
        // numbers sit slightly off the text they belong to.
        let baselineInset = layout.defaultBaselineOffset(for: gutterFont)

        func draw(_ number: Int, baseline: CGFloat, current: Bool) {
            let string = NSAttributedString(string: "\(number)", attributes: [
                .font: gutterFont,
                .foregroundColor: current ? NSColor.secondaryLabelColor : NSColor.quaternaryLabelColor,
            ])
            string.draw(at: NSPoint(x: rightEdge - string.size().width,
                                    y: baseline - baselineInset))
        }

        // An empty document, or the blank line after a trailing newline, has no
        // glyphs to measure a baseline against. Extra line height sits above the
        // text, so the baseline is one descender up from the bottom of the
        // fragment — the same place typing on that line would put it, which is
        // what stops the number shifting on the first keystroke.
        func drawInExtraFragment(_ number: Int) {
            let fragment = layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            guard !fragment.isEmpty, fragment.maxY >= rect.minY, fragment.minY <= rect.maxY else { return }
            draw(number, baseline: fragment.maxY - bodyFont.descender.magnitude,
                 current: active.location >= text.length)
        }

        guard text.length > 0 else { return drawInExtraFragment(1) }
        guard layout.numberOfGlyphs > 0 else { return }

        /// Concealed glyphs map back to the previous line, so a number must be
        /// placed from the first character on its line that is really drawn.
        func anchor(in line: NSRange) -> Int {
            var index = line.location
            while index < NSMaxRange(line), renderer?.hidden.contains(index) == true { index += 1 }
            return min(index, text.length - 1)
        }

        let visibleGlyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        var paragraph = text.paragraphRange(
            for: NSRange(location: min(visible.location, text.length - 1), length: 0))
        var number = lineNumber(at: paragraph.location, in: text)
        let limit = NSMaxRange(visible)
        // A wholly concealed last line — a closing fence at end of file — has no
        // row of its own and reports the previous line's fragment. Numbering it
        // would stack two numbers on one row.
        var lastRowY = -CGFloat.greatestFiniteMagnitude

        while paragraph.location < text.length {
            let index = anchor(in: paragraph)
            let glyph = min(layout.glyphIndexForCharacter(at: index), layout.numberOfGlyphs - 1)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: origin.x, dy: origin.y)
            if fragment.minY > rect.maxY { break }
            let sharesPreviousRow = abs(fragment.minY - lastRowY) < 0.5
            lastRowY = fragment.minY
            // A collapsed row — a table's delimiter — has no room for a number.
            let collapsed = fragment.height < 5
            if fragment.maxY >= rect.minY, !sharesPreviousRow, !collapsed {
                draw(number,
                     baseline: baselineOfLine(at: index, glyph: glyph),
                     current: NSIntersectionRange(paragraph, active).length > 0
                         || paragraph.location == active.location)
            }
            let next = NSMaxRange(paragraph)
            guard paragraph.length > 0, next < text.length else { break }
            if next > limit { break }
            paragraph = text.paragraphRange(for: NSRange(location: next, length: 0))
            number += 1
        }

        if text.hasSuffix("\n") {
            drawInExtraFragment(lineNumber(at: text.length, in: text))
        }
    }

    /// Counts newlines up to `location` in bulk; walking line by line would
    /// cost a call per line on every redraw.
    private func lineNumber(at location: Int, in text: NSString) -> Int {
        var line = 1
        var index = 0
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        while index < location {
            let length = min(chunk, location - index)
            text.getCharacters(&buffer, range: NSRange(location: index, length: length))
            for i in 0..<length where buffer[i] == 10 { line += 1 }
            index += length
        }
        return line
    }

    // MARK: - Smart lists

    override func insertNewline(_ sender: Any?) {
        guard isMarkdown, Settings.shared.smartLists, selectedRanges.count == 1 else {
            super.insertNewline(sender); return
        }
        let ns = string as NSString
        let caret = selectedRange()
        var lineRange = ns.lineRange(for: NSRange(location: caret.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") {
            line.removeLast()
            lineRange.length -= 1
        }
        let lineNS = line as NSString
        let whole = NSRange(location: 0, length: lineNS.length)

        if let m = Self.listPrefix.firstMatch(in: line, range: whole) {
            let content = lineNS.substring(from: m.range.length)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Second return on an empty item ends the list.
                replace(range: lineRange, with: "")
                return
            }
            var next = lineNS.substring(with: m.range(at: 1))
            if m.range(at: 3).location != NSNotFound {
                let n = Int(lineNS.substring(with: m.range(at: 3))) ?? 1
                next += "\(n + 1)" + lineNS.substring(with: m.range(at: 4))
            } else {
                next += lineNS.substring(with: m.range(at: 2))
            }
            next += lineNS.substring(with: m.range(at: 5))
            if m.range(at: 6).location != NSNotFound { next += "[ ] " }
            insert("\n" + next)
            return
        }

        if let m = Self.quotePrefix.firstMatch(in: line, range: whole) {
            let content = lineNS.substring(from: m.range.length)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                replace(range: lineRange, with: "")
                return
            }
            insert("\n" + lineNS.substring(with: m.range(at: 1)))
            return
        }
        super.insertNewline(sender)
    }

    // MARK: - Edit helpers (all undo-registered)

    private func insert(_ s: String) {
        let r = selectedRange()
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + (s as NSString).length, length: 0))
    }

    private func replace(range: NSRange, with s: String) {
        guard shouldChangeText(in: range, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: range, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
    }

    /// Selection, or the word the caret sits in when the selection is empty.
    private func effectiveRange() -> NSRange {
        let sel = selectedRange()
        guard sel.length == 0 else { return sel }
        let ns = string as NSString
        guard ns.length > 0 else { return sel }
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_'"))
        var start = sel.location, end = sel.location
        while start > 0, let u = Unicode.Scalar(ns.character(at: start - 1)), wordChars.contains(u) { start -= 1 }
        while end < ns.length, let u = Unicode.Scalar(ns.character(at: end)), wordChars.contains(u) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func toggleWrap(_ marker: String) {
        let ns = string as NSString
        let r = effectiveRange()
        let len = (marker as NSString).length
        let inner = ns.substring(with: r)

        // Already wrapped, inside the selection?
        if inner.hasPrefix(marker), inner.hasSuffix(marker), inner.count >= len * 2 {
            let stripped = (inner as NSString).substring(with: NSRange(location: len, length: (inner as NSString).length - len * 2))
            guard shouldChangeText(in: r, replacementString: stripped) else { return }
            textStorage?.replaceCharacters(in: r, with: stripped)
            didChangeText()
            setSelectedRange(NSRange(location: r.location, length: (stripped as NSString).length))
            return
        }
        // Already wrapped, just outside the selection?
        let outer = NSRange(location: r.location - len, length: r.length + len * 2)
        if outer.location >= 0, NSMaxRange(outer) <= ns.length,
           ns.substring(with: NSRange(location: outer.location, length: len)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(r), length: len)) == marker {
            guard shouldChangeText(in: outer, replacementString: inner) else { return }
            textStorage?.replaceCharacters(in: outer, with: inner)
            didChangeText()
            setSelectedRange(NSRange(location: outer.location, length: r.length))
            return
        }
        let wrapped = marker + inner + marker
        guard shouldChangeText(in: r, replacementString: wrapped) else { return }
        textStorage?.replaceCharacters(in: r, with: wrapped)
        didChangeText()
        if r.length == 0 {
            setSelectedRange(NSRange(location: r.location + len, length: 0))
        } else {
            setSelectedRange(NSRange(location: r.location + len, length: r.length))
        }
    }

    /// Rewrites every line touched by the selection.
    private func transformLines(_ body: (String) -> String) {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: selectedRange())
        var lines = ns.substring(with: paragraph).components(separatedBy: "\n")
        let trailingNewline = lines.count > 1 && lines.last == ""
        if trailingNewline { lines.removeLast() }
        let result = lines.map(body).joined(separator: "\n") + (trailingNewline ? "\n" : "")
        guard shouldChangeText(in: paragraph, replacementString: result) else { return }
        textStorage?.replaceCharacters(in: paragraph, with: result)
        didChangeText()
        setSelectedRange(NSRange(location: paragraph.location, length: (result as NSString).length))
    }

    private static func splitIndent(_ line: String) -> (String, String) {
        let idx = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        return (String(line[line.startIndex..<idx]), String(line[idx...]))
    }

    // MARK: - Format actions

    @objc func mdBold(_ sender: Any?) { toggleWrap("**") }
    @objc func mdItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func mdStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func mdInlineCode(_ sender: Any?) { toggleWrap("`") }

    @objc func mdHeading(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 1
        transformLines { line in
            let (indent, rest) = Self.splitIndent(line)
            var bare = rest
            while bare.hasPrefix("#") { bare.removeFirst() }
            bare = String(bare.drop(while: { $0 == " " || $0 == "\t" }))
            guard level > 0 else { return indent + bare }
            return indent + String(repeating: "#", count: level) + " " + bare
        }
    }

    @objc func mdBulletList(_ sender: Any?) {
        transformLines { line in
            let (indent, rest) = Self.splitIndent(line)
            if rest.hasPrefix("- ") { return indent + String(rest.dropFirst(2)) }
            return indent + "- " + rest
        }
    }

    @objc func mdNumberedList(_ sender: Any?) {
        var n = 0
        transformLines { line in
            let (indent, rest) = Self.splitIndent(line)
            if let r = rest.range(of: "^\\d+[.)] ", options: .regularExpression) {
                return indent + String(rest[r.upperBound...])
            }
            n += 1
            return indent + "\(n). " + rest
        }
    }

    @objc func mdTaskItem(_ sender: Any?) {
        transformLines { line in
            let (indent, rest) = Self.splitIndent(line)
            if rest.hasPrefix("- [ ] ") { return indent + "- [x] " + String(rest.dropFirst(6)) }
            if rest.lowercased().hasPrefix("- [x] ") { return indent + String(rest.dropFirst(6)) }
            if rest.hasPrefix("- ") { return indent + "- [ ] " + String(rest.dropFirst(2)) }
            return indent + "- [ ] " + rest
        }
    }

    @objc func mdBlockquote(_ sender: Any?) {
        transformLines { line in
            let (indent, rest) = Self.splitIndent(line)
            if rest.hasPrefix("> ") { return indent + String(rest.dropFirst(2)) }
            if rest.hasPrefix(">") { return indent + String(rest.dropFirst(1)) }
            return indent + "> " + rest
        }
    }

    @objc func mdCodeBlock(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let paragraph = ns.paragraphRange(for: sel)
        var inner = ns.substring(with: paragraph)
        if inner.hasSuffix("\n") { inner.removeLast() }
        let replacement = "```\n" + inner + "\n```\n"
        guard shouldChangeText(in: paragraph, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: paragraph, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: paragraph.location + 3, length: 0))
    }

    @objc func mdHorizontalRule(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let atLineStart = sel.location == line.location
        insert((atLineStart ? "" : "\n") + "---\n")
    }

    @objc func mdLink(_ sender: Any?) {
        let ns = string as NSString
        let r = effectiveRange()
        let selected = ns.substring(with: r)
        let looksLikeURL = selected.hasPrefix("http://") || selected.hasPrefix("https://")
            || selected.hasPrefix("www.") || selected.hasPrefix("mailto:")
        let replacement = looksLikeURL ? "[](\(selected))" : "[\(selected)]()"
        guard shouldChangeText(in: r, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: r, with: replacement)
        didChangeText()
        // Put the caret where the missing half goes.
        let caret = looksLikeURL ? r.location + 1 : r.location + (selected as NSString).length + 3
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    @objc func mdGoToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let target = Int(field.stringValue), target > 0 else { return }

        let ns = string as NSString
        var index = 0, line = 1
        while line < target, index < ns.length {
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
        let range = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Markdown-only commands are disabled in a plain-text document.
        let markdownOnly: Set<Selector> = [
            #selector(mdBold(_:)), #selector(mdItalic(_:)), #selector(mdStrikethrough(_:)),
            #selector(mdInlineCode(_:)), #selector(mdHeading(_:)), #selector(mdBulletList(_:)),
            #selector(mdNumberedList(_:)), #selector(mdTaskItem(_:)), #selector(mdBlockquote(_:)),
            #selector(mdCodeBlock(_:)), #selector(mdHorizontalRule(_:)), #selector(mdLink(_:)),
        ]
        if let action = item.action, markdownOnly.contains(action) { return isMarkdown && isEditable }
        return super.validateUserInterfaceItem(item)
    }
}
