import AppKit

/// One vector master for the template menu-bar icon and every app-icon resolution.
enum BrandIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawMagnifyingGlass(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Askme"
        return image
    }

    static func drawAppIcon(in rect: CGRect) {
        let tile = rect.insetBy(dx: rect.width * 0.055, dy: rect.height * 0.055)
        let radius = tile.width * 0.225
        let background = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.91, alpha: 1))?
            .draw(in: background, angle: -90)
        NSColor(white: 0, alpha: 0.10).setStroke()
        background.lineWidth = max(0.5, rect.width * 0.002)
        background.stroke()
        let glyph = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.20)
        drawMagnifyingGlass(in: glyph, color: NSColor(white: 0.12, alpha: 1))
    }

    private static func drawMagnifyingGlass(in rect: CGRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        let affine = NSAffineTransform(transform: transform)
        affine.scaleX(by: rect.width, yBy: rect.height)
        affine.concat()
        color.setStroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 0.595, y: 0.385))
        handle.line(to: NSPoint(x: 0.84, y: 0.14))
        handle.lineWidth = 0.125
        handle.lineCapStyle = .round
        handle.stroke()
        let lens = NSBezierPath(ovalIn: NSRect(x: 0.12, y: 0.34, width: 0.54, height: 0.54))
        lens.lineWidth = 0.115
        lens.stroke()
    }
}
