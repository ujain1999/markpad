import AppKit

/// A single, quiet reference card — Markpad is meant to be driven from the keyboard.
final class ShortcutsPanelController: NSWindowController {

    private static let groups: [(String, [(String, String)])] = [
        ("File", [
            ("New", "⌘N"), ("New Tab", "⌘T"), ("Open…", "⌘O"), ("Save", "⌘S"),
            ("Save As…", "⇧⌘S"), ("Close", "⌘W"), ("Show All Tabs", "⇧⌘\\"),
            ("Print…", "⌘P"), ("Settings…", "⌘,"),
        ]),
        ("Editing", [
            ("Find…", "⌘F"), ("Find Next", "⌘G"), ("Find Previous", "⇧⌘G"),
            ("Replace…", "⌥⌘F"), ("Go to Line…", "⌘L"), ("Select All", "⌘A"),
        ]),
        ("Markdown", [
            ("Bold", "⌘B"), ("Italic", "⌘I"), ("Strikethrough", "⇧⌘X"),
            ("Inline code", "⇧⌘C"), ("Link", "⌘K"), ("Code block", "⌥⌘C"),
            ("Heading 1–6", "⌘1 … ⌘6"), ("Body text", "⌘0"),
            ("Bullet list", "⇧⌘8"), ("Numbered list", "⇧⌘7"),
            ("Task item", "⇧⌘9"), ("Blockquote", "⇧⌘."),
        ]),
        ("View", [
            ("Zoom in", "⌘+"), ("Zoom out", "⌘−"), ("Actual size", "⌃⌘0"),
            ("Status bar", "⌃⌘S"), ("Markdown highlighting", "⌃⌘H"),
            ("Full screen", "⌃⌘F"), ("This card", "⌘/"),
        ]),
    ]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 36
        columns.distribution = .fillEqually

        var current = NSStackView()
        current.orientation = .vertical
        current.alignment = .leading
        current.spacing = 16

        for (index, group) in Self.groups.enumerated() {
            let title = NSTextField(labelWithString: group.0.uppercased())
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.textColor = .tertiaryLabelColor

            let rows = NSStackView(views: group.1.map { Self.row(name: $0.0, key: $0.1) })
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 5

            let section = NSStackView(views: [title, rows])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 8
            current.addArrangedSubview(section)

            if index == 1 || index == Self.groups.count - 1 {
                columns.addArrangedSubview(current)
                current = NSStackView()
                current.orientation = .vertical
                current.alignment = .leading
                current.spacing = 16
            }
        }

        let content = NSView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            columns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        window.contentView = content
    }

    private static func row(name: String, key: String) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12)
        let shortcut = NSTextField(labelWithString: key)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right

        let stack = NSStackView(views: [label, shortcut])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.distribution = .fill
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        stack.widthAnchor.constraint(equalToConstant: 210).isActive = true
        return stack
    }
}
