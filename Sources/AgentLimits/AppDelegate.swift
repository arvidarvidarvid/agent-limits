import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var lastUpdated: Date?
    private var lastResults: [ProviderUsage]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The title is built as an attributed string with inline logo images
        // (see updateTitle), so no separate button.image is needed.
        statusItem.button?.title = "…"
        menu.delegate = self
        // Don't let AppKit auto-disable (and grey out) our info rows.
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu(with: nil) // placeholder until first fetch

        refresh()
        // Refresh every 5 minutes in the background so the title stays current.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The title is a baked image, so re-render it when the theme flips.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private nonisolated func appearanceChanged() {
        Task { @MainActor in
            self.updateTitle(with: self.lastResults)
            self.rebuildMenu(with: self.lastResults)
        }
    }

    // MARK: Fetch

    private func refresh() {
        Task { @MainActor in
            let results = await Usage.fetchAll()
            self.lastUpdated = Date()
            self.rebuildMenu(with: results)
            self.updateTitle(with: results)
        }
    }

    // MARK: Rendering

    /// The menu-bar title: per provider, the logo with two stacked numbers, the
    /// 5-hour (session) window on top and the weekly window below, each tinted by
    /// usage. Rendered as an image because a stacked two-row layout beside a
    /// centered logo can't be expressed as a single attributed string.
    private func updateTitle(with results: [ProviderUsage]?) {
        guard let button = statusItem.button else { return }
        lastResults = results
        guard let results, !results.isEmpty else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "…")
            return
        }
        button.attributedTitle = NSAttributedString(string: "")
        button.image = titleImage(results, appearance: button.effectiveAppearance)
        button.imagePosition = .imageOnly
    }

    private func titleImage(_ results: [ProviderUsage], appearance: NSAppearance) -> NSImage {
        let H = NSStatusBar.system.thickness
        let logoSize: CGFloat = 13
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        let gapLogoChip: CGFloat = 4, gapProviders: CGFloat = 9, sidePad: CGFloat = 3
        let hPad: CGFloat = 4 // chip padding around the number
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // Each number becomes a colored chip. The color is the signal; the digits
        // ride on top in black or white, whichever the chip color needs.
        func cell(_ w: RateWindow) -> (text: String, fill: NSColor) {
            ("\(Int(w.usedPercent.rounded()))%", Self.usageChipColor(w.usedPercent, dark: isDark))
        }

        // One chip per window that exists: session (5h) on top, weekly below.
        struct Column { let provider: String; let cells: [(text: String, fill: NSColor)]; let chipW: CGFloat }
        let columns: [Column] = results.map { usage in
            var cells: [(text: String, fill: NSColor)] = []
            if let s = usage.windows.first(where: { $0.kind == .session }) { cells.append(cell(s)) }
            if let wk = usage.windows.first(where: { $0.kind == .weekly }) { cells.append(cell(wk)) }
            if cells.isEmpty { cells.append(("–", NSColor.gray)) }
            let textW = cells.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return Column(provider: usage.provider, cells: cells, chipW: ceil(textW) + hPad * 2)
        }

        var width = sidePad
        for (i, col) in columns.enumerated() {
            if i > 0 { width += gapProviders }
            if Logo.forProvider(col.provider) != nil { width += logoSize + gapLogoChip }
            width += col.chipW
        }
        width += sidePad

        let image = NSImage(size: NSSize(width: ceil(width), height: H), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x = sidePad
                for (i, col) in columns.enumerated() {
                    if i > 0 { x += gapProviders }
                    if let logo = Logo.forProvider(col.provider, size: logoSize) {
                        self.drawLogo(logo, in: CGRect(x: x, y: (H - logoSize) / 2, width: logoSize, height: logoSize))
                        x += logoSize + gapLogoChip
                    }
                    for (cell, rect) in zip(col.cells, self.chipRects(count: col.cells.count, x: x, width: col.chipW, H: H)) {
                        self.drawChip(cell.text, fill: cell.fill, font: font, rect: rect)
                    }
                    x += col.chipW
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Chip frames: one centered chip for a single window, or two stacked
    /// (session on top, weekly on the bottom) when a provider reports both.
    private func chipRects(count: Int, x: CGFloat, width: CGFloat, H: CGFloat) -> [CGRect] {
        if count <= 1 {
            let h: CGFloat = 13
            return [CGRect(x: x, y: (H - h) / 2, width: width, height: h)]
        }
        let h: CGFloat = 9.5, gap: CGFloat = 1.5
        let y0 = (H - (h * 2 + gap)) / 2
        return [CGRect(x: x, y: y0 + h + gap, width: width, height: h),  // top: session
                CGRect(x: x, y: y0, width: width, height: h)]            // bottom: weekly
    }

    private func drawChip(_ text: String, fill: NSColor, font: NSFont, rect: CGRect) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.contrastText(for: fill)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attrs)
    }

    /// Template logos (Codex) are tinted to the label color; colored logos
    /// (Claude's orange) are drawn as-is.
    private func drawLogo(_ image: NSImage, in rect: CGRect) {
        guard image.isTemplate else { image.draw(in: rect); return }
        NSGraphicsContext.saveGraphicsState()
        image.draw(in: rect)
        NSColor.labelColor.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rebuildMenu(with results: [ProviderUsage]?) {
        menu.removeAllItems()

        guard let results else {
            menu.addItem(infoRow("Loading…"))
            addFooter()
            return
        }

        for usage in results {
            let header = NSMenuItem(title: usage.provider, action: nil, keyEquivalent: "")
            let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            // Native menu images preserve template tinting in both appearances.
            header.image = Logo.forProvider(usage.provider, size: 14)
            header.attributedTitle = NSAttributedString(string: usage.provider,
                attributes: [.font: bold, .foregroundColor: NSColor.labelColor])
            menu.addItem(header)

            if let error = usage.error {
                menu.addItem(infoRow("  \(error)"))
            } else if usage.windows.isEmpty {
                menu.addItem(infoRow("  no active limits"))
            } else {
                for window in usage.windows {
                    menu.addItem(windowItem(window))
                }
            }
            menu.addItem(.separator())
        }
        addFooter()
    }

    /// A dropdown row: label in the normal color, then the bar and percentage
    /// tinted by usage (green plenty left, amber mid, red near the limit), then
    /// the reset time. Rendered as a view so it keeps full contrast instead of
    /// the greyed-out look AppKit gives disabled menu items.
    private func windowItem(_ window: RateWindow) -> NSMenuItem {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let color = Self.usageColor(window.usedPercent)
        let pct = Int(window.usedPercent.rounded())
        let bar = Bar.render(percent: window.usedPercent)

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "\(Self.padded(window.label, 13)) ",
            attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: "\(bar) \(pct)%",
            attributes: [.font: mono, .foregroundColor: color]))
        if let reset = window.resetsAt {
            s.append(NSAttributedString(string: "  · resets \(Format.relative(reset))",
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        }
        return staticRow(s)
    }

    /// A non-interactive menu row backed by a plain label view, so its text is
    /// never dimmed the way a disabled NSMenuItem's is.
    private func staticRow(_ attributed: NSAttributedString, indent: CGFloat = 21) -> NSMenuItem {
        let field = NSTextField(labelWithAttributedString: attributed)
        field.drawsBackground = false
        field.isBezeled = false
        field.isEditable = false
        field.lineBreakMode = .byClipping
        field.sizeToFit()

        let vPad: CGFloat = 3
        let size = field.frame.size
        let container = NSView(frame: NSRect(x: 0, y: 0,
            width: indent + size.width + 14, height: size.height + vPad * 2))
        field.setFrameOrigin(NSPoint(x: indent, y: vPad))
        container.addSubview(field)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    /// Right-pad to `width` for column alignment, without ever truncating (model
    /// names like "Week · Fable" run longer than a fixed width).
    private static func padded(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    /// Muted, desaturated usage tones (sage / ochre / dusty rose), as a
    /// (light-background, dark-background) pair.
    private static func usageColorPair(_ percent: Double) -> (light: NSColor, dark: NSColor) {
        switch percent {
        case ..<50:
            return (NSColor(srgbRed: 0.36, green: 0.53, blue: 0.38, alpha: 1),
                    NSColor(srgbRed: 0.53, green: 0.69, blue: 0.54, alpha: 1))
        case ..<80:
            return (NSColor(srgbRed: 0.68, green: 0.51, blue: 0.27, alpha: 1),
                    NSColor(srgbRed: 0.82, green: 0.66, blue: 0.44, alpha: 1))
        default:
            return (NSColor(srgbRed: 0.70, green: 0.38, blue: 0.36, alpha: 1),
                    NSColor(srgbRed: 0.84, green: 0.52, blue: 0.50, alpha: 1))
        }
    }

    /// Opaque, appearance-adaptive text colors. Text needs stronger contrast
    /// than the muted chip fills, especially over a translucent dark menu.
    static func usageColor(_ percent: Double) -> NSColor {
        let light: NSColor
        let dark: NSColor
        switch percent {
        case ..<50:
            light = NSColor(srgbRed: 0.18, green: 0.40, blue: 0.22, alpha: 1)
            dark = NSColor(srgbRed: 0.72, green: 0.92, blue: 0.73, alpha: 1)
        case ..<80:
            light = NSColor(srgbRed: 0.48, green: 0.32, blue: 0.09, alpha: 1)
            dark = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.56, alpha: 1)
        default:
            light = NSColor(srgbRed: 0.62, green: 0.23, blue: 0.21, alpha: 1)
            dark = NSColor(srgbRed: 1.00, green: 0.71, blue: 0.69, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// A concrete usage color for the given background, used as a chip fill.
    static func usageChipColor(_ percent: Double, dark: Bool) -> NSColor {
        let pair = usageColorPair(percent)
        return dark ? pair.dark : pair.light
    }

    /// Black or white, whichever reads better on the given fill.
    static func contrastText(for fill: NSColor) -> NSColor {
        let c = fill.usingColorSpace(.sRGB) ?? fill
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    private func addFooter() {
        if let lastUpdated {
            menu.addItem(infoRow("Updated \(Format.time(lastUpdated))"))
        }
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        if canLaunchAtLogin {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            // The system owns this setting (it can also be flipped in System
            // Settings), so read it fresh rather than keeping our own copy.
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func infoRow(_ title: String) -> NSMenuItem {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // Custom labels retain readable text instead of disabled-menu dimming.
        return staticRow(NSAttributedString(string: title, attributes: [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
        ]))
    }

    @objc private func refreshClicked() { refresh() }

    // MARK: Launch at login

    /// Login-item registration needs a real bundle; a bare `swift run` binary
    /// has none, so the menu item is left out there.
    private var canLaunchAtLogin: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        // Registered but switched off in System Settings: only the user can
        // turn it back on, so take them there.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        rebuildMenu(with: lastResults)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Recompute countdowns even when the cached usage is still fresh.
        rebuildMenu(with: lastResults)
        // Freshen whenever the user opens the menu, unless we just fetched.
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 30 { return }
        refresh()
    }
}

// MARK: - Small formatting helpers

enum Bar {
    static func render(percent: Double, width: Int = 10) -> String {
        let clamped = max(0, min(100, percent))
        let filled = Int((clamped / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

enum Format {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func relative(_ date: Date, relativeTo now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "now" }
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "in \(days)d \(hours % 24)h" }
        if hours > 0 { return "in \(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }
}
