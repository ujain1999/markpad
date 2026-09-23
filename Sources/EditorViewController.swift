import AppKit

final class EditorViewController: NSViewController, NSTextViewDelegate,
                                  NSLayoutManagerDelegate, NSTextStorageDelegate {

    private(set) var textView: MarkpadTextView!
    private let scrollView = NSScrollView()
    private let statusBar = NSView()
    private let statusLeft = NSTextField(labelWithString: "")
    private let statusRight = NSTextField(labelWithString: "")
    private var statusHeight: NSLayoutConstraint!

    private let renderer = MarkdownRenderer()
    /// Paragraph holding the selection — the one line that shows its syntax.
    private var activeRange = NSRange(location: NSNotFound, length: 0)
    private var pendingEdit: NSRange?
    private var pendingReparse: [NSRange] = []
    private var reparseScheduled = false
    private var countTimer: Timer?

    /// Live preview is dropped for documents too large to reparse comfortably.
    private static let livePreviewLimit = 400_000

    weak var document: MarkpadDocument?

    init(document: MarkpadDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        countTimer?.invalidate()
    }

    // MARK: - Construction

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))

        // TextKit 1, built by hand so the layout manager is always available.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        layout.delegate = self
        storage.delegate = self

        textView = MarkpadTextView(frame: view.bounds, textContainer: container)
        textView.delegate = self
        textView.renderer = renderer
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        buildStatusBar()

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .markpadSettingsChanged, object: nil)
    }

    private func buildStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        for label in [statusLeft, statusRight] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(label)
        }
        statusRight.alignment = .right
        statusHeight = statusBar.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            statusHeight,
            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 14),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusRight.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -14),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        view.addSubview(statusBar)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadFromDocument()
        applySettings()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    /// Keeps the text in a centred column of comfortable measure.
    private func updateInsets() {
        let available = scrollView.contentSize.width
        guard available > 0 else { return }
        let target = min(Settings.shared.lineWidth, max(280, available - 48))
        let horizontal = max(24, ((available - target) / 2).rounded())
        if abs(textView.textContainerInset.width - horizontal) > 0.5 {
            textView.textContainerInset = NSSize(width: horizontal, height: 28)
        }
    }

    // MARK: - Document sync

    func reloadFromDocument() {
        guard let document, isViewLoaded else { return }
        textView.isMarkdown = document.format == .markdown
        textView.string = document.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        reparseAll()
        updateStatus()
    }

    func formatDidChange() {
        guard isViewLoaded else { return }
        textView.isMarkdown = document?.format == .markdown
        reparseAll()
        updateStatus()
    }

    func textDidChange(_ notification: Notification) {
        document?.text = textView.string
        let text = textView.string as NSString
        let edited = clamp(pendingEdit ?? textView.selectedRange(), in: text)
        pendingEdit = nil

        renderer.livePreview = Settings.shared.livePreview && text.length <= Self.livePreviewLimit
        let fencesMoved = renderer.rescanFences(in: text)
        let previousActive = moveActiveRange()

        if fencesMoved {
            reparseAll()
        } else {
            reparse([text.paragraphRange(for: edited), activeRange, previousActive])
        }
        scheduleCount()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let previousActive = moveActiveRange()
        if previousActive.location != NSNotFound {
            scheduleReparse([activeRange, previousActive])
        }
        updateStatus()
    }

    // MARK: - Rendering

    private func clamp(_ range: NSRange, in text: NSString) -> NSRange {
        let location = min(max(0, range.location), text.length)
        return NSRange(location: location, length: min(range.length, text.length - location))
    }

    /// Moves the revealed paragraph to wherever the selection now is, returning
    /// the paragraph it left (or a null range if it did not move).
    private func moveActiveRange() -> NSRange {
        let text = textView.string as NSString
        let new = text.paragraphRange(for: clamp(textView.selectedRange(), in: text))
        guard !NSEqualRanges(new, activeRange) else { return NSRange(location: NSNotFound, length: 0) }
        let previous = activeRange
        activeRange = new
        renderer.activeRange = new
        return previous
    }

    /// AppKit moves the selection while the text storage is still processing an
    /// edit — undo and redo both do it — and restyling from inside that pass
    /// mutates the storage underneath the layout manager. Selection-driven work
    /// therefore waits for the next turn of the run loop, coalesced.
    private func scheduleReparse(_ ranges: [NSRange]) {
        pendingReparse.append(contentsOf: ranges)
        guard !reparseScheduled else { return }
        reparseScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reparseScheduled = false
            let ranges = self.pendingReparse
            self.pendingReparse = []
            self.reparse(ranges)
        }
    }

    private func reparse(_ ranges: [NSRange]) {
        guard let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        let whole = NSRange(location: 0, length: storage.length)
        for range in ranges {
            let clamped = NSIntersectionRange(range, whole)
            guard range.location != NSNotFound, clamped.length > 0 else { continue }
            let paragraphs = (storage.string as NSString).paragraphRange(for: clamped)
            renderer.parse(storage, range: paragraphs)
            layout.invalidateGlyphs(forCharacterRange: paragraphs, changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: paragraphs, actualCharacterRange: nil)
        }
        textView.typingAttributes = renderer.baseAttributes
        textView.needsDisplay = true
    }

    private func reparseAll() {
        guard let storage = textView.textStorage, let layout = textView.layoutManager else { return }
        pendingReparse = []
        renderer.rebuildBaseAttributes()
        renderer.isMarkdown = textView.isMarkdown
        renderer.livePreview = Settings.shared.livePreview && storage.length <= Self.livePreviewLimit
        renderer.reset()
        renderer.rescanFences(in: storage.string as NSString)
        activeRange = NSRange(location: NSNotFound, length: 0)
        _ = moveActiveRange()

        let whole = NSRange(location: 0, length: storage.length)
        renderer.parse(storage, range: whole)
        layout.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        textView.typingAttributes = renderer.baseAttributes
        textView.needsDisplay = true
    }

    // MARK: - Hiding syntax

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Concealed ranges are absolute, so they have to move with the text.
        renderer.shift(after: editedRange, by: delta)
        pendingEdit = editedRange
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        let hidden = renderer.hidden
        guard !hidden.isEmpty else { return 0 }

        var properties = [NSLayoutManager.GlyphProperty]()
        properties.reserveCapacity(glyphRange.length)
        var conceals = false
        for i in 0..<glyphRange.length {
            if hidden.contains(charIndexes[i]) {
                properties.append(.null)
                conceals = true
            } else {
                properties.append(props[i])
            }
        }
        guard conceals else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: charIndexes,
                                font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: - Settings

    @objc private func settingsChanged() { applySettings() }

    private func applySettings() {
        let s = Settings.shared
        textView.isContinuousSpellCheckingEnabled = s.spellCheck
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = s.smartSubstitutions
        textView.isAutomaticDashSubstitutionEnabled = s.smartSubstitutions
        statusBar.isHidden = !s.showStatusBar
        statusHeight.constant = s.showStatusBar ? 24 : 0
        reparseAll()
        updateInsets()
        updateStatus()
    }

    // MARK: - Status bar

    private func scheduleCount() {
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        guard Settings.shared.showStatusBar else { return }
        let text = textView.string
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let chars = text.count
        let lines = max(1, text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } } - (text.hasSuffix("\n") ? 1 : 0))

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func n(_ v: Int) -> String { formatter.string(from: NSNumber(value: v)) ?? "\(v)" }

        statusLeft.stringValue = document?.format.displayName ?? ""
        statusRight.stringValue = "\(n(words)) words · \(n(chars)) characters · line \(n(currentLineNumber())) of \(n(lines))"
    }

    private func currentLineNumber() -> Int {
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        var index = 0, line = 1
        while index < location {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(range) > location { break }
            index = NSMaxRange(range)
            if index <= location { line += 1 }
        }
        return line
    }
}
