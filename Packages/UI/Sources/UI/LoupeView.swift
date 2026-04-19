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
    /// Local URLs we've resolved to full-resolution originals during
    /// this Loupe session. Key is `asset.id`. A miss here falls back to
    /// the preview, so Loupe never blocks on a fetch that's in flight.
    @State private var originalURLs: [UUID: URL] = [:]
    /// Ids we've already kicked off a fetch for in this session. Prevents
    /// the `.onChange` triggers from spawning duplicate work.
    @State private var requestedOriginalIds: Set<UUID> = []

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

                // Originals download overlay — top-right corner, visible
                // only while the cache is fetching bytes for the selected
                // asset. Falls back to the preview underneath while the
                // download is in flight so the user still sees something.
                if let row = selectedRow,
                   viewModel.downloadingAssetIds.contains(row.id) {
                    VStack {
                        HStack {
                            Spacer()
                            DownloadIndicatorView(
                                progress: viewModel.downloadProgressByAssetId[row.id]
                            )
                            .padding(12)
                        }
                        Spacer()
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
                syncIsZoomed()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedAssetId) { _, _ in
            resetZoomOnAssetChange()
        }
        .onChange(of: viewModel.pendingZoomCommand) { _, command in
            guard let command else { return }
            switch command {
            case .toggleFitTo100:
                toggleZoom()
            case .resetToFit:
                resetZoom()
            }
            viewModel.pendingZoomCommand = nil
        }
        .onChange(of: viewModel.isZoomed) { _, zoomed in
            guard zoomed, let id = viewModel.selectedAssetId else { return }
            requestOriginalIfNeeded(assetId: id)
        }
    }

    private func requestOriginalIfNeeded(assetId: UUID) {
        guard originalURLs[assetId] == nil,
              !requestedOriginalIds.contains(assetId) else { return }
        requestedOriginalIds.insert(assetId)
        Task { @MainActor in
            if let url = await viewModel.fetchOriginalIfNeeded(assetId: assetId) {
                originalURLs[assetId] = url
            }
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
                ScrollWheelZoomView(
                    onZoom: { delta in
                        scrollZoom(delta: delta, imageSize: imageSize, containerSize: containerSize)
                    },
                    onPan: { dx, dy in
                        scrollPan(dx: dx, dy: dy, imageSize: imageSize, containerSize: containerSize)
                    }
                )
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
                syncIsZoomed()
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
                syncIsZoomed()
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
        syncIsZoomed()
    }

    /// Handle a two-finger trackpad scroll as a pan. Returns `true` if the
    /// event was applied, `false` at fit scale (so the caller can let the
    /// event pass through to any underlying scroll consumer).
    private func scrollPan(
        dx: CGFloat,
        dy: CGFloat,
        imageSize: CGSize,
        containerSize: CGSize
    ) -> Bool {
        let fit = ZoomState.fitScale(imageSize: imageSize, containerSize: containerSize)
        guard zoomState.zoomScale > fit + 0.001 else { return false }
        zoomState.applyPan(
            dx: dx,
            dy: dy,
            imageSize: imageSize,
            containerSize: containerSize
        )
        // Keep click-drag's start offset in sync so a follow-up drag
        // doesn't jump back to the pre-scroll position.
        panStartOffset = zoomState.panOffset
        return true
    }

    // MARK: - Keyboard actions

    private func toggleZoom() {
        guard let row = selectedRow, let image = loadedImage(for: row) else { return }
        let imageSize = image.size
        zoomState.toggleFitTo100(imageSize: imageSize, containerSize: containerSize)
        magnifyStartScale = zoomState.zoomScale
        panStartOffset = zoomState.panOffset
        flashIndicator()
        syncIsZoomed()
    }

    private func resetZoom() {
        guard let row = selectedRow, let image = loadedImage(for: row) else { return }
        let imageSize = image.size
        zoomState.resetToFit(imageSize: imageSize, containerSize: containerSize)
        magnifyStartScale = zoomState.zoomScale
        panStartOffset = zoomState.panOffset
        flashIndicator()
        syncIsZoomed()
    }

    private func resetZoomOnAssetChange() {
        zoomState = ZoomState()
        magnifyStartScale = 0
        panStartOffset = .zero
        showZoomIndicator = false
        hideIndicatorTask?.cancel()
        viewModel.isZoomed = false
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

    // MARK: - isZoomed sync

    private func syncIsZoomed() {
        guard let row = selectedRow, let image = loadedImage(for: row) else {
            viewModel.isZoomed = false
            return
        }
        let imageSize = image.size
        let scale = effectiveZoomScale(imageSize: imageSize, containerSize: containerSize)
        let fit = ZoomState.fitScale(imageSize: imageSize, containerSize: containerSize)
        viewModel.isZoomed = scale > fit + 0.001
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
        if let originalURL = originalURLs[row.id],
           let image = NSImage(contentsOf: originalURL) {
            return image
        }
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
