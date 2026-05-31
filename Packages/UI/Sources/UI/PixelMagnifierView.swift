import SwiftUI

/// Floating, draggable pixel magnifier shown over the Develop preview
/// (#324). Renders the small native-resolution patch the view model
/// produces, with a 1:1 ↔ 2:1 zoom button, a "Lower resolution" badge
/// when sampling the preview rather than the original, and a download
/// spinner while the original is being fetched.
struct PixelMagnifierView: View {
    @ObservedObject var viewModel: DevelopViewModel
    /// Window offset captured at the start of a drag so the translation
    /// accumulates from where the window currently sits.
    @State private var dragStartOffset: CGSize?

    private var side: CGFloat { DevelopViewModel.magnifierPointSize }

    var body: some View {
        VStack(spacing: 0) {
            header
            patch
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(white: 0.35), lineWidth: 1)
        )
        .shadow(radius: 10)
        .accessibilityIdentifier("pixel-magnifier")
    }

    // MARK: - Header (drag handle + controls)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.6))
            Text("Magnifier")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(white: 0.7))

            Spacer()

            Button {
                viewModel.cycleMagnifierZoom()
            } label: {
                Text("\(viewModel.magnifierZoom):1")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(white: 0.85))
            .accessibilityIdentifier("magnifier-zoom-button")
            .help("Toggle 1:1 / 2:1 zoom")

            Button {
                viewModel.setMagnifierVisible(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color(white: 0.6))
            .accessibilityIdentifier("magnifier-close-button")
            .help("Hide magnifier (L)")
        }
        .padding(.horizontal, 8)
        .frame(height: DevelopViewModel.magnifierHeaderHeight)
        .frame(width: side)
        .background(Color(white: 0.18))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    // MARK: - Patch

    private var patch: some View {
        ZStack {
            Color.black

            if let image = viewModel.magnifierImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: side, height: side)
            }

            // Centre reticle marking the exact sample point.
            Path { path in
                let c = side / 2
                path.move(to: CGPoint(x: c, y: c - 9))
                path.addLine(to: CGPoint(x: c, y: c + 9))
                path.move(to: CGPoint(x: c - 9, y: c))
                path.addLine(to: CGPoint(x: c + 9, y: c))
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)

            if viewModel.isDownloadingOriginal {
                ProgressView()
                    .controlSize(.small)
            }

            if viewModel.magnifierUsingPreviewFallback {
                Text("Lower resolution")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .accessibilityIdentifier("magnifier-lowres-badge")
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStartOffset ?? viewModel.magnifierWindowOffset
                if dragStartOffset == nil { dragStartOffset = start }
                viewModel.setMagnifierWindowOffset(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }
}
