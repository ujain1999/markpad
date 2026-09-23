import AppKit

/// Puts the `markpad` command on the user's PATH, so dragging the app to
/// Applications is all the installation there is.
///
/// Nothing here ever replaces a command it did not create: an existing
/// `markpad` is only relinked when it already points into a Markpad bundle.
enum CommandLineTool {

    private static let pathNoticeShown = "cliPathNoticeShown"

    /// Conventional homes for a user-installed command, best first. Homebrew's
    /// directory comes last because it belongs to Homebrew.
    private static let candidates = ["~/.local/bin", "~/bin", "/usr/local/bin", "/opt/homebrew/bin"]

    static func installIfNeeded() {
        guard let source = Bundle.main.url(forResource: "markpad", withExtension: nil) else { return }

        // Running from a disk image or any other read-only volume: a link would
        // dangle the moment it is ejected.
        if let readOnly = try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           readOnly.volumeIsReadOnly == true {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let searchPath = loginShellPath()
            guard let directory = destination(on: searchPath) else { return }
            link(source, into: directory, onPath: searchPath.contains(directory.path))
        }
    }

    /// A GUI app inherits a bare PATH, so ask the login shell for the real one.
    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: ":").map(String.init)
    }

    private static func destination(on searchPath: [String]) -> URL? {
        let manager = FileManager.default
        let expanded = candidates.map { ($0 as NSString).expandingTildeInPath }

        // Somewhere already on PATH that we can write to needs no explaining.
        for directory in expanded
        where searchPath.contains(directory) && manager.isWritableFile(atPath: directory) {
            return URL(fileURLWithPath: directory)
        }

        // Otherwise use the conventional user location and say so afterwards.
        let fallback = expanded[0]
        try? manager.createDirectory(atPath: fallback, withIntermediateDirectories: true)
        return manager.isWritableFile(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }

    private static func link(_ source: URL, into directory: URL, onPath: Bool) {
        let manager = FileManager.default
        let link = directory.appendingPathComponent("markpad")
        let wanted = source.resolvingSymlinksInPath().path

        if let current = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            let absolute = current.hasPrefix("/")
                ? current : directory.appendingPathComponent(current).path
            if URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path == wanted { return }
            // Only ever repoint a link of our own — say, one left by an older
            // copy of the app somewhere else.
            guard absolute.contains("/Markpad.app/Contents/Resources/markpad") else { return }
            try? manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            return   // somebody else's command; leave it alone
        }

        guard (try? manager.createSymbolicLink(at: link, withDestinationURL: source)) != nil else { return }
        if !onPath { explainPath(directory) }
    }

    /// Only reached when the command had to go somewhere off PATH, and only
    /// said once.
    private static func explainPath(_ directory: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: pathNoticeShown) else { return }
        defaults.set(true, forKey: pathNoticeShown)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "The markpad command is installed"
            alert.informativeText = """
                It was put in \(directory.path), which is not on your PATH yet. \
                Add this line to your shell profile to use it:

                export PATH="\(directory.path):$PATH"
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
