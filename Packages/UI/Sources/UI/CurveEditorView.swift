import Catalog
import CoreGraphics
import EditEngine
import SwiftUI

/// Square canvas that draws a 1:1 grid, the active channel's piecewise-linear
/// curve, and draggable handles. Click on the curve to insert a point;
/// right-click a handle to remove it. Identity is `[(0,0), (1,1)]` —
/// the curve from corner to corner.
///
/// Coordinates are normalised: curve point `x` and `y` are both in
/// `[0, 1]`. The view does the y-flip (curve y=1 is at the top of the
/// canvas) so the user reads the curve like a graph paper plot.
struct CurveEditorView: View {
    let channel: CurveChannel
    let points: [CGPoint]
    /// Optional histogram backdrop, rendered faintly under the grid when
    /// the channel is `.luminance`. Other channels ignore it.
    let histogram: HistogramData?
    var onChange: (_ newPoints: [CGPoint]) -> Void
    var onReset: () -> Void

    @State private var draggingIndex: Int?

    private static let canvasSize: CGFloat = 240
    private static let handleDiameter: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            canvas
                .frame(width: Self.canvasSize, height: Self.canvasSize)
                .background(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(white: 0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(channel.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(white: 0.8))
            Spacer()
            Button("Reset") { onReset() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.6))
                .accessibilityIdentifier("curve-reset-\(channel.rawValue)")
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if channel == .luminance, let histogram {
                    histogramBackdrop(histogram, in: geo.size)
                }
                grid(in: geo.size)
                curvePath(in: geo.size)
                handles(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(insertOrDragGesture(in: geo.size))
        }
    }

    // MARK: - Drawing

    private func grid(in size: CGSize) -> some View {
        Canvas { context, _ in
            let stroke = GraphicsContext.Shading.color(Color(white: 0.18))
            var path = Path()
            for i in 0...4 {
                let f = CGFloat(i) / 4
                path.move(to: CGPoint(x: f * size.width, y: 0))
                path.addLine(to: CGPoint(x: f * size.width, y: size.height))
                path.move(to: CGPoint(x: 0, y: f * size.height))
                path.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
            context.stroke(path, with: stroke, lineWidth: 0.5)

            // Diagonal "identity" reference line.
            var diag = Path()
            diag.move(to: CGPoint(x: 0, y: size.height))
            diag.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(diag, with: .color(Color(white: 0.22)), lineWidth: 0.5)
        }
    }

    private func curvePath(in size: CGSize) -> some View {
        Canvas { context, _ in
            guard points.count >= 2 else { return }
            var path = Path()
            let first = canvasPoint(for: points[0], in: size)
            path.move(to: first)
            for p in points.dropFirst() {
                path.addLine(to: canvasPoint(for: p, in: size))
            }
            context.stroke(
                path,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func handles(in size: CGSize) -> some View {
        ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let canvasPos = canvasPoint(for: point, in: size)
                Circle()
                    .fill(strokeColor)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(width: Self.handleDiameter, height: Self.handleDiameter)
                    .position(x: canvasPos.x, y: canvasPos.y)
                    .contextMenu {
                        Button("Remove Point") {
                            let updated = CurveEditorLogic.removePoint(from: points, at: index)
                            if updated != points {
                                onChange(updated)
                            }
                        }
                        .disabled(index == 0 || index == points.count - 1)
                    }
                    .accessibilityIdentifier("curve-handle-\(channel.rawValue)-\(index)")
            }
        }
    }

    private func histogramBackdrop(_ data: HistogramData, in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let bins = data.luminance
            guard let maxCount = bins.max(), maxCount > 0, bins.count >= 2 else { return }
            var path = Path()
            let w = canvasSize.width
            let h = canvasSize.height
            path.move(to: CGPoint(x: 0, y: h))
            for (i, count) in bins.enumerated() {
                let x = w * CGFloat(i) / CGFloat(bins.count - 1)
                let normalised = min(1.0, CGFloat(count) / CGFloat(maxCount))
                let y = h - normalised * h
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            context.fill(path, with: .color(Color(white: 0.5, opacity: 0.18)))
        }
    }

    // MARK: - Gestures

    private func insertOrDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let normalised = normalisedPoint(from: value.location, in: size)
                if let index = draggingIndex {
                    let moved = CurveEditorLogic.movePoint(in: points, at: index, to: normalised)
                    if moved != points {
                        onChange(moved)
                    }
                } else {
                    // First tick of the drag — either grab an existing
                    // handle or insert a new one and start dragging it.
                    if let hit = CurveEditorLogic.nearestHandle(in: points, to: normalised) {
                        draggingIndex = hit
                    } else {
                        let inserted = CurveEditorLogic.insertPoint(into: points, at: normalised.x)
                        if inserted != points,
                           let newIndex = inserted.firstIndex(where: { abs($0.x - normalised.x) < 0.0005 }) {
                            draggingIndex = newIndex
                            onChange(inserted)
                        }
                    }
                }
            }
            .onEnded { _ in
                draggingIndex = nil
            }
    }

    // MARK: - Conversion

    /// Canvas-space point for a normalised curve point. Curve `y=0` maps
    /// to the canvas bottom; `y=1` maps to the top (so the user reads
    /// the curve like a graph paper plot).
    private func canvasPoint(for point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: point.x * size.width,
            y: (1 - point.y) * size.height
        )
    }

    /// Inverse of `canvasPoint`: convert a canvas-space click into a
    /// normalised curve point. Clamps to `[0, 1]` so a drag past the
    /// edge of the canvas doesn't push a point out of range.
    private func normalisedPoint(from location: CGPoint, in size: CGSize) -> CGPoint {
        let nx = max(0, min(1, location.x / size.width))
        let ny = max(0, min(1, 1 - location.y / size.height))
        return CGPoint(x: nx, y: ny)
    }

    private var strokeColor: Color {
        switch channel {
        case .luminance: return Color(white: 0.85)
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}
