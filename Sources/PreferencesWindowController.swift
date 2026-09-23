import AppKit

final class PreferencesWindowController: NSWindowController {

    private let formatPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let appearanceControl = NSSegmentedControl(labels: ["System", "Light", "Dark"],
                                                       trackingMode: .selectOne, target: nil, action: nil)
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")
    private let heightSlider = NSSlider()
    private let heightLabel = NSTextField(labelWithString: "")
    private let restoreRadio = NSButton(radioButtonWithTitle: "Reopen my last session", target: nil, action: nil)
    private let freshRadio = NSButton(radioButtonWithTitle: "Start fresh every launch", target: nil, action: nil)
    private let quitNote = NSTextField(wrappingLabelWithString: "")
    private let liveCheck = NSButton(checkboxWithTitle: "Hide Markdown syntax except on the current line", target: nil, action: nil)
    private let highlightCheck = NSButton(checkboxWithTitle: "Highlight Markdown syntax", target: nil, action: nil)
    private let listsCheck = NSButton(checkboxWithTitle: "Continue lists and quotes on Return", target: nil, action: nil)
    private let statusCheck = NSButton(checkboxWithTitle: "Show status bar", target: nil, action: nil)
    private let spellCheck = NSButton(checkboxWithTitle: "Check spelling while typing", target: nil, action: nil)
    private let smartCheck = NSButton(checkboxWithTitle: "Smart quotes and dashes", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentView = buildContent()
        load()
    }

    private func row(_ title: String, _ control: NSView) -> (NSView, NSView) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .labelColor
        return (label, control)
    }

    private func buildContent() -> NSView {
        formatPopup.addItems(withTitles: ["Markdown (.md)", "Plain Text (.txt)"])
        formatPopup.target = self; formatPopup.action = #selector(save)

        for choice in Settings.fontChoices { fontPopup.addItem(withTitle: choice.title) }
        fontPopup.target = self; fontPopup.action = #selector(save)

        sizeField.formatter = {
            let f = NumberFormatter(); f.minimum = 9; f.maximum = 48; f.allowsFloats = false; return f
        }()
        sizeField.alignment = .right
        sizeField.target = self; sizeField.action = #selector(save)
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        sizeStepper.minValue = 9; sizeStepper.maxValue = 48; sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self; sizeStepper.action = #selector(stepperChanged)

        appearanceControl.target = self; appearanceControl.action = #selector(save)

        widthSlider.minValue = 420; widthSlider.maxValue = 1100
        widthSlider.target = self; widthSlider.action = #selector(save)
        widthSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        heightSlider.minValue = 1.0; heightSlider.maxValue = 2.2
        heightSlider.target = self; heightSlider.action = #selector(save)
        heightSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for label in [widthLabel, heightLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }

        for check in [liveCheck, highlightCheck, listsCheck, statusCheck, spellCheck, smartCheck] {
            check.target = self; check.action = #selector(save)
        }
        for radio in [restoreRadio, freshRadio] {
            radio.target = self; radio.action = #selector(save)
        }
        quitNote.font = .systemFont(ofSize: 11)
        quitNote.preferredMaxLayoutWidth = 250

        func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = spacing
            s.alignment = .firstBaseline
            return s
        }

        let toggles = NSStackView(views: [highlightCheck, liveCheck, listsCheck, statusCheck, spellCheck, smartCheck])
        toggles.orientation = .vertical
        toggles.alignment = .leading
        toggles.spacing = 7

        let quitOptions = NSStackView(views: [restoreRadio, freshRadio, quitNote])
        quitOptions.orientation = .vertical
        quitOptions.alignment = .leading
        quitOptions.spacing = 6
        quitOptions.setCustomSpacing(9, after: freshRadio)
        quitNote.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let pairs: [(NSView, NSView)] = [
            row("New documents:", formatPopup),
            row("Typeface:", fontPopup),
            row("Size:", hstack([sizeField, sizeStepper], spacing: 2)),
            row("Appearance:", appearanceControl),
            row("Text width:", hstack([widthSlider, widthLabel])),
            row("Line height:", hstack([heightSlider, heightLabel])),
            row("Behaviour:", toggles),
            row("On quit:", quitOptions),
        ]
        let grid = NSGridView(views: pairs.map { [$0.0, $0.1] })
        grid.columnSpacing = 12
        grid.rowSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: pairs.count - 1).yPlacement = .top
        grid.row(at: pairs.count - 2).yPlacement = .top
        grid.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Markpad never asks to save on quit. Files you have opened are written as you "
            + "type, so this choice only affects documents you never saved anywhere.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let content = NSView()
        content.addSubview(grid)
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(note)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            note.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func load() {
        let s = Settings.shared
        formatPopup.selectItem(at: s.defaultFormat == .markdown ? 0 : 1)
        fontPopup.selectItem(at: Settings.fontChoices.firstIndex { $0.key == s.fontKey } ?? 0)
        sizeField.stringValue = "\(Int(s.fontSize))"
        sizeStepper.doubleValue = Double(s.fontSize)
        switch s.appearance {
        case .system: appearanceControl.selectedSegment = 0
        case .light: appearanceControl.selectedSegment = 1
        case .dark: appearanceControl.selectedSegment = 2
        }
        widthSlider.doubleValue = Double(s.lineWidth)
        heightSlider.doubleValue = Double(s.lineHeight)
        highlightCheck.state = s.syntaxHighlighting ? .on : .off
        liveCheck.state = s.livePreview ? .on : .off
        listsCheck.state = s.smartLists ? .on : .off
        statusCheck.state = s.showStatusBar ? .on : .off
        spellCheck.state = s.spellCheck ? .on : .off
        smartCheck.state = s.smartSubstitutions ? .on : .off
        restoreRadio.state = s.restoresSession ? .on : .off
        freshRadio.state = s.restoresSession ? .off : .on
        updateSliderLabels()
        updateQuitNote()
    }

    @objc private func stepperChanged() {
        sizeField.stringValue = "\(Int(sizeStepper.doubleValue))"
        save()
    }

    private func updateQuitNote() {
        if restoreRadio.state == .on {
            quitNote.textColor = .tertiaryLabelColor
            quitNote.stringValue = "Unsaved documents are kept in \(SessionStore.shared.storageDescription) "
                + "and reopened next time. They are plain text on disk, not encrypted."
        } else {
            quitNote.textColor = .systemOrange
            quitNote.stringValue = "⚠ Quitting deletes every unsaved document immediately and without "
                + "asking, and you reopen to a blank page. Work you never saved to a file cannot be recovered."
        }
    }

    private func updateSliderLabels() {
        widthLabel.stringValue = "\(Int(widthSlider.doubleValue)) pt"
        heightLabel.stringValue = String(format: "%.2f×", heightSlider.doubleValue)
    }

    @objc private func save() {
        let s = Settings.shared
        s.defaultFormat = formatPopup.indexOfSelectedItem == 0 ? .markdown : .plainText
        s.fontKey = Settings.fontChoices[max(0, fontPopup.indexOfSelectedItem)].key
        if let size = Int(sizeField.stringValue) {
            s.fontSize = CGFloat(size)
            sizeStepper.doubleValue = Double(size)
        }
        switch appearanceControl.selectedSegment {
        case 1: s.appearance = .light
        case 2: s.appearance = .dark
        default: s.appearance = .system
        }
        s.lineWidth = CGFloat(widthSlider.doubleValue)
        s.lineHeight = CGFloat(heightSlider.doubleValue)
        s.syntaxHighlighting = highlightCheck.state == .on
        s.livePreview = liveCheck.state == .on
        s.smartLists = listsCheck.state == .on
        s.showStatusBar = statusCheck.state == .on
        s.spellCheck = spellCheck.state == .on
        s.smartSubstitutions = smartCheck.state == .on
        s.restoresSession = restoreRadio.state == .on
        updateSliderLabels()
        updateQuitNote()
    }

    func refresh() { load() }
}
