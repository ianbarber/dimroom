import CoreGraphics
import Foundation

/// Pure value-type model for zoom and pan state in the Loupe view.
///
/// All methods are free of UI dependencies — they operate on explicit
/// `imageSize` and `containerSize` parameters so the logic can be
/// tested at Layer A without constructing views.
public struct ZoomState: Equatable {
    /// Absolute zoom scale where 1.0 = one image pixel per screen point.
    public var zoomScale: CGFloat

    /// Offset from centre when panning a zoomed image.
    public var panOffset: CGSize

    /// Maximum allowed zoom (4× = 400%).
    public static let maxZoom: CGFloat = 4.0

    public init(zoomScale: CGFloat = 0, panOffset: CGSize = .zero) {
        self.zoomScale = zoomScale
        self.panOffset = panOffset
    }

    // MARK: - Fit scale

    /// The scale at which the image fits entirely within the container
    /// (aspect-fit). This is the minimum zoom level.
    public static func fitScale(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return 1.0
        }
        return min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
    }

    /// Whether the current zoom scale is at (or effectively at) fit-to-window.
    /// A `zoomScale` of 0 is the sentinel for "fit", so it counts as at-fit.
    public func isAtFit(imageSize: CGSize, containerSize: CGSize) -> Bool {
        zoomScale == 0 ||
        abs(zoomScale - Self.fitScale(imageSize: imageSize, containerSize: containerSize)) < 0.001
    }

    // MARK: - Display label

    /// Human-readable label for the current zoom level.
    /// Returns "Fit" when at fit-to-window, otherwise a percentage like "100%".
    public func displayLabel(imageSize: CGSize, containerSize: CGSize) -> String {
        if isAtFit(imageSize: imageSize, containerSize: containerSize) {
            return "Fit"
        }
        let percent = Int((zoomScale * 100).rounded())
        return "\(percent)%"
    }

    // MARK: - Mutations

    /// Toggle between fit-to-window and 100% (1:1 pixel mapping).
    /// When at fit, jumps to 1.0. When at any other scale, returns to fit.
    public mutating func toggleFitTo100(
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        let fit = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        if isAtFit(imageSize: imageSize, containerSize: containerSize) {
            zoomScale = 1.0
        } else {
            zoomScale = fit
            panOffset = .zero
        }
        clampZoom(imageSize: imageSize, containerSize: containerSize)
    }

    /// Reset to fit-to-window with no pan offset.
    public mutating func resetToFit(
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        zoomScale = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        panOffset = .zero
    }

    /// Clamp zoom scale to [fitScale, maxZoom].
    public mutating func clampZoom(
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        let fit = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        zoomScale = max(fit, min(Self.maxZoom, zoomScale))
    }

    /// Clamp pan offset so the image edges cannot be pulled inside the
    /// container bounds. At fit-to-window, pan is always zero.
    public mutating func clampPan(
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        let fit = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        if zoomScale <= fit + 0.001 {
            panOffset = .zero
            return
        }

        let scaledWidth = imageSize.width * zoomScale
        let scaledHeight = imageSize.height * zoomScale
        let maxOffsetX = max(0, (scaledWidth - containerSize.width) / 2)
        let maxOffsetY = max(0, (scaledHeight - containerSize.height) / 2)

        panOffset = CGSize(
            width: max(-maxOffsetX, min(maxOffsetX, panOffset.width)),
            height: max(-maxOffsetY, min(maxOffsetY, panOffset.height))
        )
    }

    /// Apply a pinch magnification gesture. `magnification` is the gesture's
    /// cumulative scale (1.0 = no change from gesture start). `anchor` is the
    /// normalised point within the container (0…1 each axis) where the pinch
    /// is centred.
    ///
    /// The `startScale` parameter should be captured at gesture start via
    /// `.onChanged` and passed through to maintain a stable reference.
    public mutating func applyMagnification(
        _ magnification: CGFloat,
        anchor: CGPoint,
        startScale: CGFloat,
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        if zoomScale == 0 {
            zoomScale = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        }
        let oldScale = zoomScale
        zoomScale = startScale * magnification

        clampZoom(imageSize: imageSize, containerSize: containerSize)

        // Adjust pan so the anchor point stays stationary on screen.
        let anchorInContainer = CGPoint(
            x: (anchor.x - 0.5) * containerSize.width,
            y: (anchor.y - 0.5) * containerSize.height
        )
        let scaleFactor = zoomScale / oldScale
        panOffset = CGSize(
            width: panOffset.width * scaleFactor + anchorInContainer.x * (1 - scaleFactor),
            height: panOffset.height * scaleFactor + anchorInContainer.y * (1 - scaleFactor)
        )

        clampPan(imageSize: imageSize, containerSize: containerSize)
    }

    /// Apply a scroll-wheel zoom delta. Positive delta zooms in.
    public mutating func applyScrollZoom(
        delta: CGFloat,
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        if zoomScale == 0 {
            zoomScale = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        }
        let factor: CGFloat = 1.0 + delta * 0.01
        zoomScale *= factor
        clampZoom(imageSize: imageSize, containerSize: containerSize)
        clampPan(imageSize: imageSize, containerSize: containerSize)
    }

    /// Apply a two-finger trackpad scroll delta as a pan translation.
    ///
    /// Sign convention matches macOS "natural scrolling" (the default):
    /// swiping fingers up pans the image up (reveals content below),
    /// mirroring Preview and Photos. `dx` from `NSEvent.scrollingDeltaX`
    /// adds directly to `panOffset.width`, `dy` from `scrollingDeltaY`
    /// is subtracted to account for Cocoa's Y-up vs SwiftUI's Y-down
    /// offset convention.
    ///
    /// No-ops at or below fit scale (including the `zoomScale == 0`
    /// sentinel), since there is no room to pan.
    public mutating func applyPan(
        dx: CGFloat,
        dy: CGFloat,
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        let fit = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
        if zoomScale == 0 || zoomScale <= fit + 0.001 {
            return
        }
        panOffset = CGSize(
            width: panOffset.width + dx,
            height: panOffset.height - dy
        )
        clampPan(imageSize: imageSize, containerSize: containerSize)
    }

    /// Toggle fit ↔ 100% centred on a specific point in the container.
    /// Used for double-click: zooms in centred on the click location.
    public mutating func toggleFitTo100Centred(
        at point: CGPoint,
        imageSize: CGSize,
        containerSize: CGSize
    ) {
        let wasAtFit = isAtFit(imageSize: imageSize, containerSize: containerSize)
        toggleFitTo100(imageSize: imageSize, containerSize: containerSize)

        if wasAtFit {
            // Centre the zoom on the clicked point.
            let anchorX = (point.x - containerSize.width / 2)
            let anchorY = (point.y - containerSize.height / 2)
            let fit = Self.fitScale(imageSize: imageSize, containerSize: containerSize)
            let scaleFactor = zoomScale / fit
            panOffset = CGSize(
                width: -anchorX * (scaleFactor - 1),
                height: -anchorY * (scaleFactor - 1)
            )
            clampPan(imageSize: imageSize, containerSize: containerSize)
        }
    }
}
