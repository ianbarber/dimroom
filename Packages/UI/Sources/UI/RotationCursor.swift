import AppKit

/// A best-effort "rotate" cursor for the crop rotation handles.
///
/// macOS ships no rotation cursor, so we render an SF Symbol curved-arrow
/// into an image-backed `NSCursor`, tinted white with a soft dark halo so
/// it stays legible over both bright and dark image content. If the symbol
/// can't be loaded we fall back to `.crosshair`, which still signals "this
/// zone behaves differently" when the pointer enters a rotate hit-zone.
enum RotationCursor {
    /// Built once and reused — `NSCursor` is immutable and the image work
    /// is wasted if repeated on every hover event.
    static let shared: NSCursor = make()

    private static func make() -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        guard let symbol = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Rotate crop"
        )?.withSymbolConfiguration(config) else {
            return .crosshair
        }

        let glyph = symbol.tintedForCursor(with: .white)
        let glyphSize = glyph.size
        let pad: CGFloat = 3
        let canvas = NSSize(width: glyphSize.width + pad * 2, height: glyphSize.height + pad * 2)

        let image = NSImage(size: canvas)
        image.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        shadow.set()
        glyph.draw(in: NSRect(x: pad, y: pad, width: glyphSize.width, height: glyphSize.height))
        image.unlockFocus()

        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: canvas.width / 2, y: canvas.height / 2)
        )
    }
}

private extension NSImage {
    /// Flatten a template SF Symbol into a solid-coloured image. Cursor
    /// images aren't auto-tinted by AppKit, so a raw template glyph would
    /// render black and vanish over dark photos.
    func tintedForCursor(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
