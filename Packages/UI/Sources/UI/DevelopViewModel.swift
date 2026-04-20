import AppKit
import Catalog
import CoreImage
import EditEngine
import Foundation
import Previews

@MainActor
public final class DevelopViewModel: ObservableObject {
    @Published public private(set) var editState: EditState = EditState()
    @Published public private(set) var renderedImage: NSImage?
    @Published public private(set) var isRendering: Bool = false
    @Published public private(set) var histogram: HistogramData?
    /// Monotonic counter bumped whenever `reloadEditState()` refreshes
    /// `editState` from the catalog (i.e. an undo/redo replay replaced
    /// the current values). The Develop view keys its slider animation
    /// off this so only replays tween — interactive drags don't.
    @Published public private(set) var replaySequence: Int = 0
    public private(set) var currentAssetId: UUID?

    /// Child view model driving the interactive crop overlay. Owned
    /// here so DevelopView can bind to it and so `commitCrop` has a
    /// direct write path when the harness fires `setCrop`.
    public let cropViewModel = CropViewModel()

    private var catalog: CatalogDatabase
    private var previewStore: PreviewStore
    private var sourceImage: CIImage?
    private let ciContext = CIContext()
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var hasUnsavedChanges: Bool = false

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    /// Size of the preview image currently driving the Develop pipeline,
    /// if any. Used to convert normalised crop coordinates to pixel
    /// coordinates for the renderer.
    public var sourceImageSize: CGSize? {
        guard let source = sourceImage else { return nil }
        return source.extent.size
    }

    public func configure(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    public func activate(assetId: UUID?) async {
        guard let assetId else { return }
        guard let asset = try? catalog.fetchAsset(id: assetId) else { return }

        let previewURL = previewStore.previewURL(for: asset)
        guard let url = previewURL,
              let source = CIImage(contentsOf: url) else {
            currentAssetId = assetId
            editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
            hasUnsavedChanges = false
            return
        }

        sourceImage = source
        currentAssetId = assetId
        editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
        hasUnsavedChanges = false
        triggerRender()
    }

    public func deactivate() {
        renderTask?.cancel()
        saveTask?.cancel()
        renderTask = nil
        saveTask = nil

        if hasUnsavedChanges, let assetId = currentAssetId {
            _ = try? catalog.saveEditState(editState, for: assetId)
        }
        hasUnsavedChanges = false

        sourceImage = nil
        renderedImage = nil
        histogram = nil
        currentAssetId = nil
        editState = EditState()
    }

    /// Re-read the latest `EditState` from the catalog for the active
    /// asset and bump `replaySequence` so the Develop view animates the
    /// sliders to the new values. No-op if the view model isn't
    /// currently showing `assetId` (or isn't active at all). Does NOT
    /// schedule a save — the caller (UndoStack replay) has already
    /// written the catalog and we must not loop back through
    /// `scheduleSave` on top of it.
    public func reloadEditState(for assetId: UUID) async {
        guard currentAssetId == assetId else { return }
        let reloaded = (try? catalog.latestEditState(for: assetId)) ?? EditState()
        editState = reloaded
        replaySequence &+= 1
        hasUnsavedChanges = false
        scheduleRender()
    }

    public func setParameter(_ keyPath: WritableKeyPath<EditState, Double>, value: Double) {
        editState[keyPath: keyPath] = value
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    // MARK: - Crop

    /// Enter the interactive crop mode, seeding `cropViewModel` from
    /// the current `editState` (or identity if no crop has been
    /// applied yet).
    public func enterCropMode() {
        let normalised: CGRect
        if let existing = editState.cropRect, let size = sourceImageSize,
           size.width > 0, size.height > 0 {
            normalised = CropGeometry.pixelToNormalized(
                rect: existing,
                imageSize: size
            )
        } else {
            normalised = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let aspect: Double
        if let size = sourceImageSize, size.height > 0 {
            aspect = Double(size.width / size.height)
        } else {
            aspect = 1.0
        }
        cropViewModel.activate(
            cropRect: normalised,
            angle: editState.cropAngle ?? 0,
            imageAspect: aspect
        )
    }

    /// Commit the CropViewModel's current rect + angle to `editState`
    /// and exit crop mode, triggering the debounced render + save.
    public func commitCropFromViewModel() {
        let (rect, angle) = cropViewModel.commit()
        commitCrop(normalisedRect: rect, angle: angle)
    }

    /// Exit crop mode discarding any in-progress edits.
    public func cancelCrop() {
        cropViewModel.cancel()
    }

    /// Write a normalised crop rect and straighten angle into
    /// `editState`, converting to pixel coordinates using the current
    /// preview size. Schedules a re-render + auto-save.
    ///
    /// Full-image identity crop (rect ≈ (0,0,1,1), angle == 0) is
    /// written as `nil` for both fields so EditState stays canonical.
    public func commitCrop(normalisedRect: CGRect, angle: Double) {
        let clampedAngle = CropGeometry.clampAngle(angle)
        let isIdentity = abs(normalisedRect.minX) < 1e-9 &&
            abs(normalisedRect.minY) < 1e-9 &&
            abs(normalisedRect.width - 1) < 1e-9 &&
            abs(normalisedRect.height - 1) < 1e-9 &&
            clampedAngle == 0

        if isIdentity {
            editState.cropRect = nil
            editState.cropAngle = nil
        } else {
            if let size = sourceImageSize, size.width > 0, size.height > 0 {
                editState.cropRect = CropGeometry.normalizedToPixel(
                    rect: normalisedRect,
                    imageSize: size
                )
            } else {
                // No preview loaded yet — store the normalised rect
                // directly. The renderer won't see this until a preview
                // is attached and commitCrop fires again.
                editState.cropRect = normalisedRect
            }
            editState.cropAngle = clampedAngle == 0 ? nil : clampedAngle
        }
        scheduleRender()
        scheduleSave()
    }

    public func resetParameter(_ keyPath: WritableKeyPath<EditState, Double>) {
        let identity = Self.identityValue(for: keyPath)
        setParameter(keyPath, value: identity)
    }

    nonisolated public static func keyPath(forParameter name: String) -> WritableKeyPath<EditState, Double>? {
        switch name {
        case "exposure": return \.exposure
        case "contrast": return \.contrast
        case "highlights": return \.highlights
        case "shadows": return \.shadows
        case "whites": return \.whites
        case "blacks": return \.blacks
        case "temperature": return \.temperature
        case "tint": return \.tint
        case "clarity": return \.clarity
        case "vibrance": return \.vibrance
        case "saturation": return \.saturation
        default: return nil
        }
    }

    // MARK: - Private

    private static func identityValue(for keyPath: WritableKeyPath<EditState, Double>) -> Double {
        if keyPath == \EditState.temperature { return 6500 }
        return 0
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await performRender()
        }
    }

    private func triggerRender() {
        renderTask?.cancel()
        renderTask = Task {
            await performRender()
        }
    }

    private func performRender() async {
        guard let source = sourceImage else { return }
        let state = editState
        isRendering = true

        let result: (image: NSImage?, histogram: HistogramData?) = await Task.detached(priority: .userInitiated) { [ciContext] in
            let output = Renderer.render(source: source, editState: state)
            let histogram = Histogram.compute(from: output, context: ciContext)
            guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
                return (nil, histogram)
            }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return (NSImage(cgImage: cgImage, size: size), histogram)
        }.value

        guard !Task.isCancelled else { return }
        renderedImage = result.image
        histogram = result.histogram
        isRendering = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let assetId = currentAssetId else { return }
            _ = try? catalog.saveEditState(editState, for: assetId)
            hasUnsavedChanges = false
        }
    }
}
