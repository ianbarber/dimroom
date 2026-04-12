import AppKit
import SwiftUI

/// Single-asset preview with pinch-to-zoom, pan, and a zoom level
/// indicator. Renders the currently-selected row's preview JPEG on a
/// neutral dark background. Paired with `LibraryView` via a shared
/// `LibraryViewModel` — the two views read and mutate the same
/// `selectedAssetId`, so the highlight survives a round-trip through
/// Loupe and back.
///
/// Zoom/pan state resets to fit-to-window on asset change.
public struct LoupeView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    @State private var zoomState = ZoomState()
    @State private var magnifyStartScale: CGFloat = 0
    @State private var panStartOffset: CGSize = .zero
    @State private var showZoomIndicator = false
    @State private var hideIndicatorTask: Task<Void, Never>?
    @State private var containerSize: CGSize = .zero

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    /// Visible for snapshot tests — allows injecting a specific zoom scale
    /// so snapshots can capture the indicator at different zoom levels.
    init(viewModel: LibraryViewModel, initialZoomScale: CGFloat?) {
        self.viewModel = viewModel
        if let scale = initialZoomScale {
            _zoomState = State(initialValue: ZoomState(zoomScale: scale))
            _showZoomIndicator = State(initialValue: true)
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.05)
                    .ignoresSafeArea()

                if let row = selectedRow, let image = loadedImage(for: row) {
                    zoomableImage(image, row: row, containerSize: geometry.size)
                } else {
                    placeholder
                }

                // Zoom indicator overlay — bottom-right corner.
                if selectedRow != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ZoomIndicatorView(
                                label: zoomIndicatorLabel,
                                isVisible: showZoomIndicator
                            )
                            .padding(12)
                        }
                    }
                }
            }
            .onAppear {
                containerSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                containerSize = newSize
                if let row = selectedRow, let image = loadedImage(for: row) {
                    let imageSize = image.size
                    if zoomState.isAtFit(imageSize: imageSize, containerSize: containerSize) ||
                       zoomState.zoomScale == 0 {
                        zoomState.resetToFit(imageSize: imageSize, containerSize: newSize)
                    } else {
                        zoomState.clampZoom(imageSize: imageSize, containerSize: newSize)
                        zoomState.clampPan(imageSize: imageSize, containerSize: newSize)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "zZ")) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            toggleZoom()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { press in
            guard press.modifiers == .command else { return .ignored }
            resetZoom()
            return .handled
        }
        .onChange(of: viewModel.selectedAssetId) { _, _ in
            resetZoomOnAssetChange()
        }
    }

    // MARK: - Zoomable image

    @ViewBuilder
    private func zoomableImage(_ image: NSImage, row: LibraryRow, containerSize: CGSize) -> some View {
        let imageSize = image.size
        let effectiveScale = effectiveZoomScale(imageSize: imageSize, containerSize: containerSize)
        let displayWidth = imageSize.width * effectiveScale
        let displayHeight = imageSize.height * effectiveScale

        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: displayWidth, height: displayHeight)
            .offset(zoomState.panOffset)
            .id(viewModel.rowVersion)
            .gesture(magnifyGesture(imageSize: imageSize, containerSize: containerSize))
            .gesture(panGesture(imageSize: imageSize, containerSize: containerSize))
            .gesture(doubleTapGesture(imageSize: imageSize, containerSize: containerSize))
            .clipped()
            .frame(width: containerSize.width, height: containerSize.height)
            .overlay {
                ScrollWheelZoomView { delta in
                    scrollZoom(delta: delta, imageSize: imageSize, containerSize: containerSize)
                }
            }
    }

    // MARK: - Gestures

    private func magnifyGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStartScale == 0 {
                    magnifyStartScale = effectiveZoomScale(
                        imageSize: imageSize, containerSize: containerSize
                    )
                }
                zoomState.applyMagnification(
                    value.magnification,
                    anchor: CGPoint(x: 0.5, y: 0.5),
                    startScale: magnifyStartScale,
                    imageSize: imageSize,
                    containerSize: containerSize
                )
                flashIndicator()
            }
            .onEnded { _ in
                magnifyStartScale = zoomState.zoomScale
                panStartOffset = zoomState.panOffset
            }
    }

    private func panGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let fit = ZoomState.fitScale(imageSize: imageSize, containerSize: containerSize)
                guard zoomState.zoomScale > fit + 0.001 else { return }
                // DragGesture reports cumulative translation from gesture
                // start, so apply relative to the captured start offset.
                zoomState.panOffset = CGSize(
                    width: panStartOffset.width + value.translation.width,
                    height: panStartOffset.height + value.translation.height
                )
                zoomState.clampPan(imageSize: imageSize, containerSize: containerSize)
            }
            .onEnded { _ in
                panStartOffset = zoomState.panOffset
            }
    }

    private func doubleTapGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                zoomState.toggleFitTo100Centred(
                    at: value.location,
                    imageSize: imageSize,
                    containerSize: containerSize
                )
                magnifyStartScale = zoomState.zoomScale
                panStartOffset = zoomState.panOffset
                flashIndicator()
            }
    }

    // MARK: - Scroll zoom

    private func scrollZoom(delta: CGFloat, imageSize: CGSize, containerSize: CGSize) {
        zoomState.applyScrollZoom(
            delta: delta,
            imageSize: imageSize,
            containerSize: containerSize
        )
        magnifyStartScale = zoomState.zoomScale
        panStartOffset = zoomState.panOffset
        flashIndicator()
    }

    // MARK: - Keyboard actions

    private func toggleZoom() {
        guard let row = selectedRow, let image = loadedImage(for: row) else { return }
        let imageSize = image.size
        zoomState.toggleFitTo100(imageSize: imageSize, containerSize: containerSize)
        magnifyStartScale = zoomState.zoomScale
        panStartOffset = zoomState.panOffset
        flashIndicator()
    }

    private func resetZoom() {
        guard let row = selectedRow, let image = loadedImage(for: row) else { return }
        let imageSize = image.size
        zoomState.resetToFit(imageSize: imageSize, containerSize: containerSize)
        magnifyStartScale = zoomState.zoomScale
        panStartOffset = zoomState.panOffset
        flashIndicator()
    }

    private func resetZoomOnAssetChange() {
        zoomState = ZoomState()
        magnifyStartScale = 0
        panStartOffset = .zero
        showZoomIndicator = false
        hideIndicatorTask?.cancel()
    }

    // MARK: - Zoom indicator

    private var zoomIndicatorLabel: String {
        guard let row = selectedRow, let image = loadedImage(for: row) else {
            return "Fit"
        }
        let imageSize = image.size
        let effectiveScale = effectiveZoomScale(imageSize: imageSize, containerSize: containerSize)
        let state = ZoomState(zoomScale: effectiveScale, panOffset: zoomState.panOffset)
        return state.displayLabel(imageSize: imageSize, containerSize: containerSize)
    }

    private func flashIndicator() {
        showZoomIndicator = true
        hideIndicatorTask?.cancel()
        hideIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showZoomIndicator = false
        }
    }

    // MARK: - Helpers

    private func effectiveZoomScale(imageSize: CGSize, containerSize: CGSize) -> CGFloat {
        if zoomState.zoomScale == 0 {
            return ZoomState.fitScale(imageSize: imageSize, containerSize: containerSize)
        }
        return zoomState.zoomScale
    }

    private var selectedRow: LibraryRow? {
        guard let id = viewModel.selectedAssetId else { return nil }
        return viewModel.rows.first(where: { $0.id == id })
    }

    private func loadedImage(for row: LibraryRow) -> NSImage? {
        guard let url = row.previewURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(white: 0.35))
            Text("No photo selected")
                .font(.headline)
                .foregroundStyle(Color(white: 0.55))
        }
    }
}
