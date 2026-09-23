import AppKit
import UniformTypeIdentifiers

final class MarkpadDocumentController: NSDocumentController {
    /// New documents follow the preferred format from Settings.
    override var defaultType: String? { Settings.shared.defaultFormat.uti }
}

@objc(MarkpadDocument)
final class MarkpadDocument: NSDocument {

    /// The document's contents. Dirty state is driven by the text view's undo manager.
    var text: String = ""
    /// Identifies this document's stashed draft while it has no file of its own.
    private(set) var draftID = UUID().uuidString

    /// What is actually on screen. `text` is a mirror kept up to date by the
    /// editor, but anything that changes the text view without posting a change
    /// notification (accessibility, services) would leave it stale — and a
    /// stale mirror is what would get written to the file. So ask the editor.
    var currentText: String {
        guard let editor, editor.isViewLoaded else { return text }
        let onScreen = editor.textView.string
        text = onScreen
        return onScreen
    }
    fileprivate weak var editor: EditorViewController?

    var format: MarkpadFormat { MarkpadFormat.from(uti: fileType) }

    override init() {
        super.init()
        fileType = Settings.shared.defaultFormat.uti
        hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }
    /// Markpad keeps its own session, so AppKit's draft and window restoration
    /// machinery would only duplicate (and race with) it.
    override class var autosavesDrafts: Bool { false }
    override class var readableTypes: [String] {
        [MarkpadFormat.markdownUTI, MarkpadFormat.plainTextUTI, "public.text", "public.data"]
    }
    override class var writableTypes: [String] {
        [MarkpadFormat.markdownUTI, MarkpadFormat.plainTextUTI]
    }
    override class func isNativeType(_ type: String) -> Bool { true }

    /// Only ever offer the document's own type, so the save panel shows our
    /// accessory format picker instead of AppKit's implicit one.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [format.uti]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        MarkpadFormat.from(uti: typeName).fileExtension
    }

    // MARK: - Windows

    override func makeWindowControllers() {
        let editor = EditorViewController(document: self)
        self.editor = editor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.minSize = NSSize(width: 420, height: 300)
        window.contentViewController = editor
        window.isRestorable = false
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "MarkpadEditor"

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = true
        controller.windowFrameAutosaveName = "MarkpadEditorWindow"
        addWindowController(controller)
        window.makeFirstResponder(editor.textView)
        SessionStore.shared.rememberOpenFiles()
    }

    // MARK: - Session

    /// Adopts a stashed draft. Called before the window exists, so the editor
    /// picks the text up when it loads.
    func adopt(_ draft: SessionStore.Draft) {
        draftID = draft.id
        fileType = draft.format.uti
        text = draft.text
    }

    /// Quitting and closing never ask to save. An untitled document is either
    /// stashed for next launch or deliberately dropped, so by the time AppKit
    /// asks there is nothing left to decide.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        if fileURL == nil {
            let unsaved = currentText
            let worthKeeping = Settings.shared.restoresSession
                && !unsaved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if worthKeeping {
                SessionStore.shared.saveDraft(id: draftID, text: unsaved, format: format)
            } else {
                SessionStore.shared.removeDraft(id: draftID)
            }
            updateChangeCount(.changeCleared)
        }
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector,
                       contextInfo: contextInfo)
    }

    override func close() {
        super.close()
        SessionStore.shared.rememberOpenFiles()
    }

    override func save(to url: URL, ofType typeName: String,
                       for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [self] error in
            if error == nil {
                // It lives in a file now; the draft has done its job.
                SessionStore.shared.removeDraft(id: draftID)
                SessionStore.shared.rememberOpenFiles()
            }
            completionHandler(error)
        }
    }

    // MARK: - Reading & writing

    override func data(ofType typeName: String) throws -> Data {
        guard let data = currentText.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            text = s
        } else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError)
        }
        // A file opened by extension should keep that extension's format.
        if let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty {
            fileType = (ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" || ext == "mdtext")
                ? MarkpadFormat.markdownUTI : MarkpadFormat.plainTextUTI
        }
        editor?.reloadFromDocument()
    }

    // MARK: - Save panel with a format picker

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 25), pullsDown: false)
        popup.addItems(withTitles: ["Markdown (.md)", "Plain Text (.txt)"])
        popup.selectItem(at: format == .markdown ? 0 : 1)
        popup.target = self
        popup.action = #selector(savePanelFormatChanged(_:))

        let label = NSTextField(labelWithString: "Format:")
        label.alignment = .right
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = NSRect(x: 0, y: 0, width: 360, height: 48)

        savePanel.accessoryView = row
        savePanel.allowedContentTypes = contentTypes(for: format)
        activeSavePanel = savePanel
        return true
    }

    private weak var activeSavePanel: NSSavePanel?

    private func contentTypes(for format: MarkpadFormat) -> [UTType] {
        switch format {
        case .markdown:
            return [UTType(filenameExtension: "md") ?? .plainText]
        case .plainText:
            return [UTType(filenameExtension: "txt") ?? .plainText]
        }
    }

    @objc private func savePanelFormatChanged(_ sender: NSPopUpButton) {
        let newFormat: MarkpadFormat = sender.indexOfSelectedItem == 0 ? .markdown : .plainText
        fileType = newFormat.uti
        editor?.formatDidChange()
        guard let panel = activeSavePanel else { return }
        panel.allowedContentTypes = contentTypes(for: newFormat)
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + newFormat.fileExtension
    }

    // MARK: - Format commands

    @objc func mdSetFormatMarkdown(_ sender: Any?) { setFormat(.markdown) }
    @objc func mdSetFormatPlainText(_ sender: Any?) { setFormat(.plainText) }

    private func setFormat(_ newFormat: MarkpadFormat) {
        guard newFormat != format else { return }
        fileType = newFormat.uti
        editor?.formatDidChange()
        for controller in windowControllers { controller.synchronizeWindowTitleWithDocumentName() }

        // An already-saved file needs a new name on disk, so ask where it goes.
        if let url = fileURL, url.pathExtension.lowercased() != newFormat.fileExtension {
            saveAs(nil)
        }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(mdSetFormatMarkdown(_:)):
            item.state = format == .markdown ? .on : .off
            return true
        case #selector(mdSetFormatPlainText(_:)):
            item.state = format == .plainText ? .on : .off
            return true
        default:
            return super.validateMenuItem(item)
        }
    }

    // MARK: - Tabs

    /// Implementing this is what earns the window a + button, ⌘T, and the
    /// Window menu's tab commands. `addTabbedWindow` tabs the new document
    /// explicitly, so it works whatever the system's tabbing preference is.
    @objc func newWindowForTab(_ sender: Any?) {
        let host = windowControllers.first { $0.window?.isKeyWindow == true }?.window
            ?? windowControllers.first?.window
        guard let host else { return }
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            document.makeWindowControllers()
            guard let window = document.windowControllers.first?.window else { return }
            // addTabbedWindow still defers to the system's "Prefer tabs when
            // opening documents" setting, so ask for a tab outright for the
            // duration of the call. ⌘N keeps making a window.
            let mode = host.tabbingMode
            host.tabbingMode = .preferred
            window.tabbingMode = .preferred
            host.addTabbedWindow(window, ordered: .above)
            host.tabbingMode = mode
            window.tabbingMode = mode
            window.makeKeyAndOrderFront(sender)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        info.topMargin = 54; info.bottomMargin = 54
        info.leftMargin = 54; info.rightMargin = 54

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: info.paperSize.height))
        printView.isVerticallyResizable = true
        printView.isHorizontallyResizable = false
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = Settings.shared.lineHeight
        printView.textStorage?.setAttributedString(NSAttributedString(
            string: currentText,
            attributes: [.font: Settings.shared.editorFont,
                         .foregroundColor: NSColor.black,
                         .paragraphStyle: style]))
        return NSPrintOperation(view: printView, printInfo: info)
    }
}
