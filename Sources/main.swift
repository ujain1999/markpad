import AppKit

// The document controller must exist before AppKit asks for the shared one.
_ = MarkpadDocumentController()

let delegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
