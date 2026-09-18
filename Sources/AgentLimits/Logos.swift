import AppKit

/// Vector provider marks drawn at runtime, so they stay crisp at any size and
/// need no bundled brand assets. Claude is its orange sunburst; Codex is the
/// OpenAI blossom, drawn as a template image so the menu bar tints it to match
/// the current appearance (dark or light).
enum Logo {
    static func claude(size: CGFloat = 14) -> NSImage {
        image(size: size, template: false) { cg, s in
            cg.setFillColor(NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor)
            let c = CGPoint(x: s / 2, y: s / 2)
            let spokes = 12, inner = s * 0.07, outer = s * 0.46, w = s * 0.10
            for i in 0..<spokes {
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: CGFloat(i) / CGFloat(spokes) * 2 * .pi)
                let rect = CGRect(x: inner, y: -w / 2, width: outer - inner, height: w)
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
                cg.fillPath()
                cg.restoreGState()
            }
        }
    }

    static func codex(size: CGFloat = 14) -> NSImage {
        image(size: size, template: true) { cg, s in
            cg.setStrokeColor(NSColor.black.cgColor) // tinted by the template
            cg.setLineWidth(s * 0.07)
            let c = CGPoint(x: s / 2, y: s / 2)
            for i in 0..<3 {
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y)
                cg.rotate(by: CGFloat(i) * .pi / 3)
                cg.addEllipse(in: CGRect(x: -s * 0.13, y: -s * 0.34, width: s * 0.26, height: s * 0.68))
                cg.restoreGState()
            }
            cg.strokePath()
        }
    }

    static func forProvider(_ provider: String, size: CGFloat = 14) -> NSImage? {
        switch provider {
        case "Claude": return claude(size: size)
        case "Codex": return codex(size: size)
        default: return nil
        }
    }

    private static func image(size: CGFloat, template: Bool,
                              _ draw: @escaping (CGContext, CGFloat) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(cg, size)
            return true
        }
        img.isTemplate = template
        return img
    }
}
