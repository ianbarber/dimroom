import CoreGraphics
import Foundation

public enum AppIconRenderer {

    // MARK: - Palette

    static let backgroundBlack = CGColor(red: 0.04, green: 0.03, blue: 0.03, alpha: 1.0)
    static let amberCore = CGColor(red: 0.92, green: 0.62, blue: 0.20, alpha: 1.0)
    static let amberGlow = CGColor(red: 0.85, green: 0.45, blue: 0.10, alpha: 0.0)
    static let printShadow = CGColor(red: 0.15, green: 0.12, blue: 0.10, alpha: 1.0)
    static let printHighlight = CGColor(red: 0.65, green: 0.48, blue: 0.28, alpha: 1.0)

    // MARK: - Geometry ratios (relative to icon size)

    static let cornerRadiusRatio: CGFloat = 0.185
    static let safelightCenterYRatio: CGFloat = 0.32
    static let safelightRadiusRatio: CGFloat = 0.14
    static let glowRadiusRatio: CGFloat = 0.55
    static let printTopRatio: CGFloat = 0.54
    static let printBottomRatio: CGFloat = 0.84
    static let printHorizontalInsetRatio: CGFloat = 0.20
    static let printCornerRadiusRatio: CGFloat = 0.03

    // MARK: - Public API

    public static func render(pixelSize: Int) -> CGImage {
        let s = CGFloat(pixelSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to create CGContext for \(pixelSize)x\(pixelSize) icon")
        }

        drawBackground(ctx: ctx, size: s)
        drawGlow(ctx: ctx, size: s)
        drawSafelight(ctx: ctx, size: s)
        drawPrint(ctx: ctx, size: s)

        guard let image = ctx.makeImage() else {
            fatalError("Failed to create CGImage from context")
        }
        return image
    }

    // MARK: - Drawing

    private static func drawBackground(ctx: CGContext, size: CGFloat) {
        let r = cornerRadiusRatio * size
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(backgroundBlack)
        ctx.fillPath()
    }

    private static func drawGlow(ctx: CGContext, size: CGFloat) {
        let cx = size / 2
        // CG origin is bottom-left; safelight near top means high Y
        let cy = size * (1.0 - safelightCenterYRatio)
        let glowRadius = size * glowRadiusRatio

        let colors = [
            CGColor(red: 0.92, green: 0.62, blue: 0.20, alpha: 0.35),
            CGColor(red: 0.85, green: 0.45, blue: 0.10, alpha: 0.08),
            CGColor(red: 0.04, green: 0.03, blue: 0.03, alpha: 0.0),
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.4, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }

        ctx.saveGState()
        // Clip to the rounded rect so glow doesn't bleed outside
        let r = cornerRadiusRatio * size
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let clipPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: cx, y: cy),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: glowRadius,
            options: []
        )
        ctx.restoreGState()
    }

    private static func drawSafelight(ctx: CGContext, size: CGFloat) {
        let cx = size / 2
        let cy = size * (1.0 - safelightCenterYRatio)
        let radius = size * safelightRadiusRatio

        let colors = [
            amberCore,
            CGColor(red: 0.88, green: 0.52, blue: 0.15, alpha: 0.7),
        ] as CFArray
        let locations: [CGFloat] = [0.0, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(
            x: cx - radius, y: cy - radius,
            width: radius * 2, height: radius * 2
        ))
        ctx.clip()
        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: cx, y: cy),
            startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy),
            endRadius: radius,
            options: []
        )
        ctx.restoreGState()
    }

    private static func drawPrint(ctx: CGContext, size: CGFloat) {
        let inset = size * printHorizontalInsetRatio
        // CG origin is bottom-left: "top" in visual space = higher Y in CG
        let visualTop = size * printTopRatio
        let visualBottom = size * printBottomRatio
        let cgBottom = size * (1.0 - visualBottom)
        let cgTop = size * (1.0 - visualTop)
        let r = size * printCornerRadiusRatio

        let printRect = CGRect(
            x: inset, y: cgBottom,
            width: size - 2 * inset, height: cgTop - cgBottom
        )
        let printPath = CGPath(roundedRect: printRect, cornerWidth: r, cornerHeight: r, transform: nil)

        // Subtle vertical gradient on the print — lighter at top (emerging)
        let colors = [printHighlight, printShadow] as CFArray
        let locations: [CGFloat] = [0.0, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: locations
        ) else { return }

        ctx.saveGState()
        ctx.addPath(printPath)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size / 2, y: cgTop),
            end: CGPoint(x: size / 2, y: cgBottom),
            options: []
        )
        ctx.restoreGState()
    }
}
