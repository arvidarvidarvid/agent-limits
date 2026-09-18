import AppKit

// Menu-bar-only app: no dock icon, no main window. The Info.plist sets
// LSUIElement, and we also set the activation policy here so a plain
// `swift run` during development behaves the same way.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
