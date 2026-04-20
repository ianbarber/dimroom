import EditEngine
import SwiftUI

/// Fixed-size (~200×100) overlay that draws R, G, B channel histograms
/// with additive blending on a dark translucent background. Designed
/// to sit in the bottom-left corner of the Develop preview, styled to
/// match `ZoomIndicatorView` (black 0.55 opacity, rounded 4pt).
///
/// A luminance trace is drawn underneath the RGB traces. Clipping
/// indicator triangles appear on the left edge for shadow clipping and
/// the right edge for highlight clipping; brightness encodes severity
/// (`.low` vs `.high`).
struct HistogramOverlayView: View {
    let data: HistogramData?

    static let size = CGSize(width: 200, height: 100)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.55))

            if let data {
                chartCanvas(data: data)
                    .padding(6)

                clippingIndicators(data: data)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func chartCanvas(data: HistogramData) -> some View {
        Canvas { context, size in
            let maxCount = channelMax(data: data)
            guard maxCount > 0 else { return }

            // Luminance first, under the channel traces.
            drawTrace(
                bins: data.luminance,
                maxCount: maxCount,
                in: size,
                context: &context,
                color: Color(white: 0.75, opacity: 0.35),
                additive: false
            )

            // RGB traces with additive blend so overlaps show cyan /
            // magenta / yellow / white naturally.
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                drawTrace(
                    bins: data.red,
                    maxCount: maxCount,
                    in: size,
                    context: &layer,
                    color: .red.opacity(0.75),
                    additive: true
                )
                drawTrace(
                    bins: data.green,
                    maxCount: maxCount,
                    in: size,
                    context: &layer,
                    color: .green.opacity(0.75),
                    additive: true
                )
                drawTrace(
                    bins: data.blue,
                    maxCount: maxCount,
                    in: size,
                    context: &layer,
                    color: .blue.opacity(0.75),
                    additive: true
                )
            }
        }
    }

    private func drawTrace(
        bins: [Int],
        maxCount: Int,
        in size: CGSize,
        context: inout GraphicsContext,
        color: Color,
        additive: Bool
    ) {
        guard !bins.isEmpty, maxCount > 0 else { return }
        var path = Path()
        let w = size.width
        let h = size.height
        path.move(to: CGPoint(x: 0, y: h))
        for (i, count) in bins.enumerated() {
            let x = w * CGFloat(i) / CGFloat(bins.count - 1)
            let normalised = min(1.0, CGFloat(count) / CGFloat(maxCount))
            let y = h - normalised * h
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func clippingIndicators(data: HistogramData) -> some View {
        HStack {
            clippingTriangle(level: data.shadowClipping, pointsLeft: true)
            Spacer()
            clippingTriangle(level: data.highlightClipping, pointsLeft: false)
        }
        .padding(4)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }

    @ViewBuilder
    private func clippingTriangle(level: ClippingLevel, pointsLeft: Bool) -> some View {
        if level != .none {
            Triangle(pointsLeft: pointsLeft)
                .fill(level == .high ? Color.white : Color(white: 0.6))
                .frame(width: 6, height: 6)
        }
    }

    /// The tallest single-bin count across all three channels. Used to
    /// normalise trace heights so the graph fills the overlay. Ignores
    /// the extreme clipping bins (0 and binCount-1) when they spike,
    /// otherwise a fully-clipped image would flatten the rest of the
    /// trace to an imperceptible sliver.
    private func channelMax(data: HistogramData) -> Int {
        var candidates: [Int] = []
        for array in [data.red, data.green, data.blue] {
            guard array.count > 2 else { continue }
            let interior = array[1..<(array.count - 1)]
            candidates.append(interior.max() ?? 0)
        }
        return candidates.max() ?? 1
    }
}

private struct Triangle: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsLeft {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
