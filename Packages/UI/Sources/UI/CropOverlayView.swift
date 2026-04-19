import EditEngine
import SwiftUI

/// Interactive crop overlay.
///
/// Given a bound `CropViewModel` whose `cropRect` is in normalised 0…1
/// space, this view draws a darkened exterior, 4 corner + 4 midpoint
/// handles, and a rule-of-thirds grid inside the crop. Drag gestures
/// on handles resize the crop; a drag gesture on the interior
/// translates the crop. Coordinates are mapped through
/// `CropGeometry.pixelToNormalized` so the view-model stays in
/// normalised space.
public struct CropOverlayView: View {
    @ObservedObject var viewModel: CropViewModel

    public init(viewModel: CropViewModel) {
        self.viewModel = viewModel
    }

    private let handleSize: CGFloat = 12
    private let exteriorFill = Color.black.opacity(0.55)
    private let handleColor = Color.white
    private let gridColor = Color.white.opacity(0.4)
    private let borderColor = Color.white.opacity(0.9)

    public var body: some View {
        GeometryReader { geo in
            let cropPixels = CropGeometry.normalizedToPixel(
                rect: viewModel.cropRect,
                imageSize: geo.size
            )
            ZStack(alignment: .topLeading) {
                exteriorMask(bounds: geo.size, cropPixels: cropPixels)
                cropBorder(cropPixels: cropPixels)
                ruleOfThirdsGrid(cropPixels: cropPixels)
                translateCatcher(cropPixels: cropPixels, imageSize: geo.size)
                handles(cropPixels: cropPixels, imageSize: geo.size)
            }
        }
    }

    // MARK: - Subviews

    private func exteriorMask(bounds: CGSize, cropPixels: CGRect) -> some View {
        // Even-odd fill: outer rect minus inner crop rect leaves a
        // doughnut shape darkened over the image.
        Path { path in
            path.addRect(CGRect(origin: .zero, size: bounds))
            path.addRect(cropPixels)
        }
        .fill(exteriorFill, style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func cropBorder(cropPixels: CGRect) -> some View {
        Rectangle()
            .stroke(borderColor, lineWidth: 1)
            .frame(width: cropPixels.width, height: cropPixels.height)
            .offset(x: cropPixels.minX, y: cropPixels.minY)
            .allowsHitTesting(false)
    }

    private func ruleOfThirdsGrid(cropPixels: CGRect) -> some View {
        Path { path in
            let thirdW = cropPixels.width / 3
            let thirdH = cropPixels.height / 3
            // Two vertical lines
            for i in 1...2 {
                let x = cropPixels.minX + CGFloat(i) * thirdW
                path.move(to: CGPoint(x: x, y: cropPixels.minY))
                path.addLine(to: CGPoint(x: x, y: cropPixels.maxY))
            }
            // Two horizontal lines
            for i in 1...2 {
                let y = cropPixels.minY + CGFloat(i) * thirdH
                path.move(to: CGPoint(x: cropPixels.minX, y: y))
                path.addLine(to: CGPoint(x: cropPixels.maxX, y: y))
            }
        }
        .stroke(gridColor, lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func translateCatcher(cropPixels: CGRect, imageSize: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: cropPixels.width, height: cropPixels.height)
            .offset(x: cropPixels.minX, y: cropPixels.minY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        translate(by: value.translation, from: cropPixels, imageSize: imageSize)
                    }
            )
    }

    private func handles(cropPixels: CGRect, imageSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Handle.allCases, id: \.self) { handle in
                let point = handle.position(in: cropPixels)
                handleShape
                    .frame(width: handleSize, height: handleSize)
                    .offset(
                        x: point.x - handleSize / 2,
                        y: point.y - handleSize / 2
                    )
                    .gesture(dragGesture(for: handle, cropPixels: cropPixels, imageSize: imageSize))
            }
        }
    }

    private var handleShape: some View {
        Rectangle()
            .fill(handleColor)
            .overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Gesture handling

    private func dragGesture(
        for handle: Handle,
        cropPixels: CGRect,
        imageSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let new = handle.apply(
                    translation: value.translation,
                    to: cropPixels
                )
                let anchor = handle.anchor(in: cropPixels)
                let anchorNorm = CGPoint(
                    x: anchor.x / imageSize.width,
                    y: anchor.y / imageSize.height
                )
                let normalised = CropGeometry.pixelToNormalized(
                    rect: new,
                    imageSize: imageSize
                )
                viewModel.updateRect(normalised, anchor: anchorNorm)
            }
    }

    private func translate(
        by translation: CGSize,
        from cropPixels: CGRect,
        imageSize: CGSize
    ) {
        let moved = cropPixels.offsetBy(
            dx: translation.width,
            dy: translation.height
        )
        let normalised = CropGeometry.pixelToNormalized(
            rect: moved,
            imageSize: imageSize
        )
        // Translation should never change the shape, so pass a nil
        // aspect ratio anchor — `updateRect` will still clamp to bounds.
        viewModel.updateRect(normalised, anchor: CGPoint(x: normalised.midX, y: normalised.midY))
    }
}

// MARK: - Handles

private enum Handle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, leading, trailing

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .leading: return CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// The anchor corner/edge that must stay fixed while this handle is
    /// being dragged (used for aspect-ratio constraint).
    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .leading: return CGPoint(x: rect.maxX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Apply the gesture `translation` to `rect` according to which edge
    /// or corner this handle controls.
    func apply(translation: CGSize, to rect: CGRect) -> CGRect {
        var r = rect
        switch self {
        case .topLeft:
            r.origin.x += translation.width
            r.origin.y += translation.height
            r.size.width -= translation.width
            r.size.height -= translation.height
        case .topRight:
            r.origin.y += translation.height
            r.size.width += translation.width
            r.size.height -= translation.height
        case .bottomLeft:
            r.origin.x += translation.width
            r.size.width -= translation.width
            r.size.height += translation.height
        case .bottomRight:
            r.size.width += translation.width
            r.size.height += translation.height
        case .top:
            r.origin.y += translation.height
            r.size.height -= translation.height
        case .bottom:
            r.size.height += translation.height
        case .leading:
            r.origin.x += translation.width
            r.size.width -= translation.width
        case .trailing:
            r.size.width += translation.width
        }
        // Drag past opposite edge: clamp to zero-width rather than flip.
        if r.size.width < 0 { r.size.width = 0 }
        if r.size.height < 0 { r.size.height = 0 }
        return r
    }
}
