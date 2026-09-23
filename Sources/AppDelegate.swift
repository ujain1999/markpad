import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private lazy var preferences = PreferencesWindowController()
    private lazy var shortcuts = ShortcutsPanelController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.shared.applyAppearance()
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: false)
        CommandLineTool.installIfNeeded()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        SessionStore.shared.openSessionOrBlankDocument()
        return true
    }

    /// Take the session snapshot first, then let AppKit close the documents —
    /// which flushes anything a file-backed document still owes to disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionStore.shared.prepareForTermination()
        NSDocumentController.shared.closeAllDocuments(
            withDelegate: self,
            didCloseAllSelector: #selector(documentController(_:didCloseAll:contextInfo:)),
            contextInfo: nil)
        return .terminateLater
    }

    @objc private func documentController(_ controller: NSDocumentController, didCloseAll: Bool,
                                          contextInfo: UnsafeMutableRawPointer?) {
        NSApp.reply(toApplicationShouldTerminate: didCloseAll)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
    }

    // MARK: - App-level commands

    @objc func showPreferences(_ sender: Any?) {
        preferences.refresh()
        preferences.showWindow(nil)
        preferences.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        shortcuts.showWindow(nil)
        shortcuts.window?.makeKeyAndOrderFront(nil)
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        Settings.shared.appearance = MarkpadAppearance(rawValue: sender.representedObject as? String ?? "system") ?? .system
        preferences.refresh()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        Settings.shared.showLineNumbers.toggle()
        preferences.refresh()
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        Settings.shared.showStatusBar.toggle()
        preferences.refresh()
    }

    @objc func toggleLivePreview(_ sender: Any?) {
        Settings.shared.livePreview.toggle()
        preferences.refresh()
    }

    @objc func toggleHighlighting(_ sender: Any?) {
        Settings.shared.syntaxHighlighting.toggle()
        preferences.refresh()
    }

    @objc func zoomIn(_ sender: Any?) {
        Settings.shared.fontSize += 1
        preferences.refresh()
    }

    @objc func zoomOut(_ sender: Any?) {
        Settings.shared.fontSize -= 1
        preferences.refresh()
    }

    @objc func actualSize(_ sender: Any?) {
        Settings.shared.fontSize = 15
        preferences.refresh()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setAppearance(_:)):
            item.state = (item.representedObject as? String) == Settings.shared.appearance.rawValue ? .on : .off
        case #selector(toggleLivePreview(_:)):
            item.state = Settings.shared.livePreview ? .on : .off
        case #selector(toggleStatusBar(_:)):
            item.state = Settings.shared.showStatusBar ? .on : .off
        case #selector(toggleLineNumbers(_:)):
            item.state = Settings.shared.showLineNumbers ? .on : .off
        case #selector(toggleHighlighting(_:)):
            item.state = Settings.shared.syntaxHighlighting ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil,
                      tag: Int = 0, represented: Any? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        menuItem.target = target
        menuItem.tag = tag
        menuItem.representedObject = represented
        return menuItem
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // App
        let app = NSMenu(title: "Markpad")
        app.addItem(item("About Markpad", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showPreferences(_:)), ",", target: self))
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(servicesItem)
        app.addItem(.separator())
        app.addItem(item("Hide Markpad", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Markpad", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)

        // File
        let openRecent = NSMenu(title: "Open Recent")
        openRecent.addItem(item("Clear Menu", Selector(("clearRecentDocuments:"))))
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecent

        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("New Tab", #selector(MarkpadDocument.newWindowForTab(_:)), "t"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            openRecentItem,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "S", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "P", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        // Edit
        let find = submenu("Find", [
            item("Find…", #selector(NSTextView.performTextFinderAction(_:)), "f", tag: 1),
            item("Find and Replace…", #selector(NSTextView.performTextFinderAction(_:)), "f", [.command, .option], tag: 12),
            item("Find Next", #selector(NSTextView.performTextFinderAction(_:)), "g", tag: 2),
            item("Find Previous", #selector(NSTextView.performTextFinderAction(_:)), "G", [.command, .shift], tag: 3),
            item("Use Selection for Find", #selector(NSTextView.performTextFinderAction(_:)), "e", tag: 7),
        ])
        let spelling = submenu("Spelling", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
        ])
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find,
            spelling,
            .separator(),
            item("Go to Line…", #selector(MarkpadTextView.mdGoToLine(_:)), "l"),
        ]))

        // Format
        let headings = submenu("Heading", (1...6).map {
            item("Heading \($0)", #selector(MarkpadTextView.mdHeading(_:)), "\($0)", tag: $0)
        } + [
            .separator(),
            item("Body Text", #selector(MarkpadTextView.mdHeading(_:)), "0", tag: 0),
        ])
        let documentFormat = submenu("Document Format", [
            item("Markdown (.md)", #selector(MarkpadDocument.mdSetFormatMarkdown(_:))),
            item("Plain Text (.txt)", #selector(MarkpadDocument.mdSetFormatPlainText(_:))),
        ])
        main.addItem(submenu("Format", [
            item("Bold", #selector(MarkpadTextView.mdBold(_:)), "b"),
            item("Italic", #selector(MarkpadTextView.mdItalic(_:)), "i"),
            item("Strikethrough", #selector(MarkpadTextView.mdStrikethrough(_:)), "X", [.command, .shift]),
            item("Inline Code", #selector(MarkpadTextView.mdInlineCode(_:)), "C", [.command, .shift]),
            item("Link", #selector(MarkpadTextView.mdLink(_:)), "k"),
            .separator(),
            headings,
            item("Bullet List", #selector(MarkpadTextView.mdBulletList(_:)), "8", [.command, .shift]),
            item("Numbered List", #selector(MarkpadTextView.mdNumberedList(_:)), "7", [.command, .shift]),
            item("Task Item", #selector(MarkpadTextView.mdTaskItem(_:)), "9", [.command, .shift]),
            item("Blockquote", #selector(MarkpadTextView.mdBlockquote(_:)), ".", [.command, .shift]),
            item("Code Block", #selector(MarkpadTextView.mdCodeBlock(_:)), "c", [.command, .option]),
            item("Horizontal Rule", #selector(MarkpadTextView.mdHorizontalRule(_:))),
            .separator(),
            documentFormat,
        ]))

        // View
        let appearance = submenu("Appearance", [
            item("System", #selector(setAppearance(_:)), target: self, represented: "system"),
            item("Light", #selector(setAppearance(_:)), target: self, represented: "light"),
            item("Dark", #selector(setAppearance(_:)), target: self, represented: "dark"),
        ])
        main.addItem(submenu("View", [
            appearance,
            .separator(),
            item("Hide Markdown Syntax", #selector(toggleLivePreview(_:)), "e", [.command, .control], target: self),
            item("Markdown Highlighting", #selector(toggleHighlighting(_:)), "h", [.command, .control], target: self),
            item("Status Bar", #selector(toggleStatusBar(_:)), "s", [.command, .control], target: self),
            item("Line Numbers", #selector(toggleLineNumbers(_:)), "l", [.command, .control], target: self),
            .separator(),
            item("Zoom In", #selector(zoomIn(_:)), "+", target: self),
            item("Zoom Out", #selector(zoomOut(_:)), "-", target: self),
            item("Actual Size", #selector(actualSize(_:)), "0", [.command, .control], target: self),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        // Window
        let windowMenuItem = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))),
            item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
            item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenuItem.submenu

        // Help
        let helpMenuItem = submenu("Help", [
            item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", target: self),
        ])
        main.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenuItem.submenu

        return main
    }
}
