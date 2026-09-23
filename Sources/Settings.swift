import AppKit

extension Notification.Name {
    static let markpadSettingsChanged = Notification.Name("MarkpadSettingsChanged")
}

enum MarkpadFormat: String {
    case markdown = "md"
    case plainText = "txt"

    static let markdownUTI = "net.daringfireball.markdown"
    static let plainTextUTI = "public.plain-text"

    var uti: String { self == .markdown ? Self.markdownUTI : Self.plainTextUTI }
    var displayName: String { self == .markdown ? "Markdown" : "Plain Text" }
    var fileExtension: String { rawValue }

    static func from(uti: String?) -> MarkpadFormat {
        guard let uti else { return .plainText }
        if uti == markdownUTI || uti.hasSuffix(".markdown") { return .markdown }
        return .plainText
    }
}

enum MarkpadAppearance: String {
    case system, light, dark
}

/// Typeface choices offered in Settings. An empty family means "use the system face".
struct FontChoice {
    let title: String
    let key: String
    func make(size: CGFloat) -> NSFont {
        switch key {
        case "": return .systemFont(ofSize: size)
        case "__serif__":
            let d = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return d.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case "__mono__": return .monospacedSystemFont(ofSize: size, weight: .regular)
        default: return NSFont(name: key, size: size) ?? .systemFont(ofSize: size)
        }
    }
}

final class Settings {
    static let shared = Settings()

    private enum K {
        static let defaultFormat = "defaultFormat"
        static let fontKey = "fontKey"
        static let fontSize = "fontSize"
        static let appearance = "appearance"
        static let lineWidth = "lineWidth"
        static let lineHeight = "lineHeight"
        static let showStatusBar = "showStatusBar"
        static let highlight = "syntaxHighlighting"
        static let smartLists = "smartLists"
        static let spellCheck = "spellCheck"
        static let smartSubstitutions = "smartSubstitutions"
        static let livePreview = "livePreview"
        static let restoresSession = "restoresSession"
        static let showLineNumbers = "showLineNumbers"
    }

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            K.defaultFormat: MarkpadFormat.markdown.rawValue,
            K.fontKey: "__mono__",
            K.fontSize: 15.0,
            K.appearance: MarkpadAppearance.system.rawValue,
            K.lineWidth: 700.0,
            K.lineHeight: 1.45,
            K.showStatusBar: true,
            K.highlight: true,
            K.smartLists: true,
            K.spellCheck: false,
            K.smartSubstitutions: false,
            K.livePreview: true,
            K.restoresSession: true,
            K.showLineNumbers: false,
        ])
    }

    /// Curated list, filtered to faces actually installed on this Mac.
    static let fontChoices: [FontChoice] = {
        var list = [FontChoice(title: "Monospaced", key: "__mono__"),
                    FontChoice(title: "System", key: ""),
                    FontChoice(title: "Serif", key: "__serif__")]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for family in ["SF Mono", "Menlo", "Monaco", "Courier New", "Helvetica Neue",
                       "Avenir Next", "Iowan Old Style", "Georgia", "Palatino", "Times New Roman"]
        where installed.contains(family) {
            list.append(FontChoice(title: family, key: family))
        }
        return list
    }()

    var defaultFormat: MarkpadFormat {
        get { MarkpadFormat(rawValue: d.string(forKey: K.defaultFormat) ?? "md") ?? .markdown }
        set { d.set(newValue.rawValue, forKey: K.defaultFormat); changed() }
    }
    var fontKey: String {
        get { d.string(forKey: K.fontKey) ?? "" }
        set { d.set(newValue, forKey: K.fontKey); changed() }
    }
    var fontSize: CGFloat {
        get { max(9, min(48, CGFloat(d.double(forKey: K.fontSize)))) }
        set { d.set(Double(max(9, min(48, newValue))), forKey: K.fontSize); changed() }
    }
    var appearance: MarkpadAppearance {
        get { MarkpadAppearance(rawValue: d.string(forKey: K.appearance) ?? "system") ?? .system }
        set { d.set(newValue.rawValue, forKey: K.appearance); applyAppearance(); changed() }
    }
    var lineWidth: CGFloat {
        get { CGFloat(d.double(forKey: K.lineWidth)) }
        set { d.set(Double(newValue), forKey: K.lineWidth); changed() }
    }
    var lineHeight: CGFloat {
        get { CGFloat(d.double(forKey: K.lineHeight)) }
        set { d.set(Double(newValue), forKey: K.lineHeight); changed() }
    }
    var showStatusBar: Bool {
        get { d.bool(forKey: K.showStatusBar) }
        set { d.set(newValue, forKey: K.showStatusBar); changed() }
    }
    var syntaxHighlighting: Bool {
        get { d.bool(forKey: K.highlight) }
        set { d.set(newValue, forKey: K.highlight); changed() }
    }
    var smartLists: Bool {
        get { d.bool(forKey: K.smartLists) }
        set { d.set(newValue, forKey: K.smartLists); changed() }
    }
    var spellCheck: Bool {
        get { d.bool(forKey: K.spellCheck) }
        set { d.set(newValue, forKey: K.spellCheck); changed() }
    }
    var smartSubstitutions: Bool {
        get { d.bool(forKey: K.smartSubstitutions) }
        set { d.set(newValue, forKey: K.smartSubstitutions); changed() }
    }
    /// Draw line numbers in the margin beside the text column.
    var showLineNumbers: Bool {
        get { d.bool(forKey: K.showLineNumbers) }
        set { d.set(newValue, forKey: K.showLineNumbers); changed() }
    }
    /// Reopen last session's documents, keeping unsaved work between launches.
    var restoresSession: Bool {
        get { d.bool(forKey: K.restoresSession) }
        set { d.set(newValue, forKey: K.restoresSession); changed() }
    }
    /// Hide Markdown syntax on every line but the one being edited.
    var livePreview: Bool {
        get { d.bool(forKey: K.livePreview) }
        set { d.set(newValue, forKey: K.livePreview); changed() }
    }

    var editorFont: NSFont {
        let size = fontSize
        let key = fontKey
        return (Self.fontChoices.first { $0.key == key } ?? Self.fontChoices[0]).make(size: size)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .markpadSettingsChanged, object: nil)
    }
}
