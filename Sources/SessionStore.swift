import AppKit


/// Keeps unsaved work on disk so quitting never has to ask a question.
///
/// Documents that live in a file are already written by autosave-in-place.
/// Untitled documents have nowhere to go, so their text is stashed as a draft
/// and handed back at the next launch. In "start fresh" mode nothing is kept.
final class SessionStore {
    static let shared = SessionStore()

    struct Draft {
        let id: String
        let text: String
        let format: MarkpadFormat
    }

    private let fileManager = FileManager.default
    private var hasRestored = false
    /// While quitting, closing documents must not rewrite the session we just took.
    private(set) var isTerminating = false

    private lazy var root: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Markpad", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
    }()
    private var draftsDirectory: URL { root.appendingPathComponent("Drafts", isDirectory: true) }
    private var openFilesURL: URL { root.appendingPathComponent("OpenFiles.json") }

    /// Where unsaved work is kept, for the Settings window to name out loud.
    var storageDescription: String {
        root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func makeDirectories() {
        try? fileManager.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Drafts

    func saveDraft(id: String, text: String, format: MarkpadFormat) {
        makeDirectories()
        removeDraft(id: id)
        let url = draftsDirectory.appendingPathComponent("\(id).\(format.fileExtension)")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func removeDraft(id: String) {
        for url in draftFiles() where url.deletingPathExtension().lastPathComponent == id {
            try? fileManager.removeItem(at: url)
        }
    }

    private func draftFiles() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: draftsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    func drafts() -> [Draft] {
        draftFiles()
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Draft(id: url.deletingPathExtension().lastPathComponent,
                             text: text,
                             format: url.pathExtension == "txt" ? .plainText : .markdown)
            }
    }

    // MARK: - Open files

    /// Records which files are open, unless we are in the middle of quitting.
    func rememberOpenFiles() {
        guard !isTerminating else { return }
        writeOpenFiles()
    }

    private func writeOpenFiles() {
        makeDirectories()
        let paths = NSDocumentController.shared.documents.compactMap { $0.fileURL?.path }
        guard let data = try? JSONSerialization.data(withJSONObject: paths) else { return }
        try? data.write(to: openFilesURL, options: .atomic)
    }

    private func openFiles() -> [URL] {
        guard let data = try? Data(contentsOf: openFilesURL),
              let paths = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Quitting

    func prepareForTermination() {
        isTerminating = true
        guard Settings.shared.restoresSession else {
            clear()
            return
        }
        writeOpenFiles()   // before anything closes and the list empties
    }

    func clear() {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Launching

    /// Reopens last session's documents, or a blank one when there is nothing
    /// to reopen. Only the first call in a launch restores; later ones (the
    /// Dock icon with no windows open) just make a new document.
    func openSessionOrBlankDocument() {
        let controller = NSDocumentController.shared
        guard !hasRestored else {
            controller.newDocument(nil)
            return
        }
        hasRestored = true

        guard Settings.shared.restoresSession else {
            clear()
            controller.newDocument(nil)
            return
        }

        var restored = false
        for url in openFiles() where fileManager.fileExists(atPath: url.path) {
            controller.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            restored = true
        }
        for draft in drafts() {
            guard let document = try? controller.openUntitledDocumentAndDisplay(false) as? MarkpadDocument
            else { continue }
            document.adopt(draft)
            document.makeWindowControllers()
            document.showWindows()
            restored = true
        }
        if !restored { controller.newDocument(nil) }
    }
}
