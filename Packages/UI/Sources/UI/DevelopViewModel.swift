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
    /// Whether the Develop histogram overlay is visible. Lives on the
    /// view model (rather than as `@State` in `ContentView`) so the
    /// harness `toggleHistogram` command can flip it through the same
    /// path as the H key, and so `AppState.showHistogram` has a single
    /// source of truth to read from.
    @Published public var showHistogram: Bool = true
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
    /// `EditState` snapshot taken the first time `setParameter` /
    /// `commitCrop` runs in a debounce window. Used as the `previous`
    /// value on the `.editSave` undo entry pushed after the save fires,
    /// so a continuous slider drag collapses to a single undo step.
    private var pendingUndoPrevious: EditState?
    private weak var undoStack: UndoStack?

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    /// Late-bind the shared undo stack so edit saves show up as Cmd+Z
    /// actions. Optional — unit tests / the `.empty()` placeholder can
    /// run without one.
    public func attach(undoStack: UndoStack) {
        self.undoStack = undoStack
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

        // Drive the Develop pipeline from the master preview so the saved
        // `EditState` is applied once over unedited pixels, not over an
        // already-edited display JPEG (issue #186).
        let previewURL = previewStore.masterPreviewURL(for: asset)
        guard let url = previewURL,
              let source = CIImage(contentsOf: url) else {
            currentAssetId = assetId
            editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
            hasUnsavedChanges = false
            pendingUndoPrevious = nil
            hydrateUndoStack(for: assetId)
            return
        }

        sourceImage = source
        currentAssetId = assetId
        editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
        hasUnsavedChanges = false
        pendingUndoPrevious = nil
        hydrateUndoStack(for: assetId)
        triggerRender()
    }

    public func deactivate() {
        renderTask?.cancel()
        saveTask?.cancel()
        renderTask = nil
        saveTask = nil

        if hasUnsavedChanges, let assetId = currentAssetId {
            let previous = pendingUndoPrevious
            let next = editState
            _ = try? catalog.saveEditState(editState, for: assetId)
            recordEditUndo(assetId: assetId, previous: previous, next: next)
            // Regenerate the cached thumb + preview in the background so
            // the Library grid we're navigating back to picks up the
            // edited look. Fire-and-forget — deactivate itself must stay
            // synchronous to keep its existing callers simple.
            let previewStore = self.previewStore
            let catalog = self.catalog
            Task.detached {
                guard let asset = try? catalog.fetchAsset(id: assetId) else { return }
                await previewStore.regenerateWithEdit(for: asset, editState: next)
            }
        }
        hasUnsavedChanges = false
        pendingUndoPrevious = nil

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
        capturePendingUndoPreviousIfNeeded()
        editState[keyPath: keyPath] = value
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    // MARK: - Crop

    /// Enter the interactive crop mode, seeding `cropViewModel` from
    /// the current `editState` (or identity if no crop has been
    /// applied yet). Schedules a render so the preview switches to the
    /// uncropped source image while the overlay is active — the user
    /// must be able to see the full frame to adjust or undo the crop.
    public func enterCropMode() {
        let normalised: CGRect
        if let existing = editState.cropRect, let size = sourceImageSize,
           size.width > 0, size.height > 0 {
            normalised = CropGeometry.ciPixelToNormalizedTopLeft(
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
        scheduleRender()
    }

    /// Commit the CropViewModel's current rect + angle to `editState`
    /// and exit crop mode, triggering the debounced render + save.
    public func commitCropFromViewModel() {
        let (rect, angle) = cropViewModel.commit()
        commitCrop(normalisedRect: rect, angle: angle)
    }

    /// Exit crop mode discarding any in-progress edits. Re-renders so
    /// the preview snaps back to the pre-activate crop.
    public func cancelCrop() {
        cropViewModel.cancel()
        scheduleRender()
    }

    /// Update the straighten angle while crop mode is active and
    /// re-render the preview so the user sees the rotation live.
    /// `CropViewModel.setAngle` only mutates VM state — without a paired
    /// render schedule the Develop preview stays stuck at the
    /// pre-activation angle while the slider moves.
    public func setCropAngleLive(_ degrees: Double) {
        cropViewModel.setAngle(degrees)
        scheduleRender()
    }

    /// Reset the in-progress crop back to the full frame. Called by
    /// the double-click gesture in `CropOverlayView`. Leaves the
    /// `previousCropRect` snapshot untouched so Escape / `cancel()`
    /// still reverts to the pre-activate state.
    public func resetCrop() {
        cropViewModel.resetRect()
        cropViewModel.selectedPreset = .free
        scheduleRender()
    }

    /// Write a normalised crop rect and straighten angle into
    /// `editState`, converting to pixel coordinates using the current
    /// preview size. Schedules a re-render + auto-save.
    ///
    /// Full-image identity crop (rect ≈ (0,0,1,1), angle == 0) is
    /// written as `nil` for both fields so EditState stays canonical.
    public func commitCrop(normalisedRect: CGRect, angle: Double) {
        capturePendingUndoPreviousIfNeeded()
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
                // SwiftUI overlays use a top-left origin; Core Image
                // uses a bottom-left origin. Flip Y here so the
                // renderer crops the region the user selected rather
                // than its vertical mirror — see #156 bug 1.
                editState.cropRect = CropGeometry.normalizedTopLeftToCIPixel(
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
        case "sharpening": return \.sharpening
        case "vibrance": return \.vibrance
        case "saturation": return \.saturation
        case "vignetteAmount": return \.vignetteAmount
        case "vignetteRoundness": return \.vignetteRoundness
        case "vignetteSoftness": return \.vignetteSoftness
        default: return nil
        }
    }

    // MARK: - Private

    private static func identityValue(for keyPath: WritableKeyPath<EditState, Double>) -> Double {
        if keyPath == \EditState.temperature { return 6500 }
        if keyPath == \EditState.vignetteRoundness { return 50 }
        if keyPath == \EditState.vignetteSoftness { return 50 }
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
        // While the crop overlay is active the user must see the full
        // frame with the overlay drawn on top — otherwise adjusting or
        // undoing an existing crop is impossible (#156 bug 2). Strip
        // the crop rect for the live render but keep `cropAngle` so
        // the straighten slider still reflects its rotation.
        var state = editState
        if cropViewModel.isActive {
            state.cropRect = nil
            state.cropAngle = cropViewModel.cropAngle == 0 ? nil : cropViewModel.cropAngle
        }
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
            let previous = pendingUndoPrevious
            let next = editState
            _ = try? catalog.saveEditState(next, for: assetId)
            hasUnsavedChanges = false
            pendingUndoPrevious = nil
            recordEditUndo(assetId: assetId, previous: previous, next: next)

            // Re-render the cached thumbnail + preview so Library/Loupe
            // reflect the edit. Chained off the save so it inherits the
            // same 500 ms debounce; in-flight regeneration is cancelled
            // implicitly when the outer `saveTask` is cancelled by a
            // subsequent `scheduleSave`.
            guard !Task.isCancelled else { return }
            if let asset = try? catalog.fetchAsset(id: assetId) {
                await previewStore.regenerateWithEdit(for: asset, editState: next)
            }
        }
    }

    /// Snapshot the current `editState` the first time a mutation
    /// happens in a save-debounce window, so the `.editSave` we push
    /// after the save has an accurate `previous` value.
    private func capturePendingUndoPreviousIfNeeded() {
        if pendingUndoPrevious == nil {
            pendingUndoPrevious = editState
        }
    }

    private func recordEditUndo(assetId: UUID, previous: EditState?, next: EditState) {
        guard let stack = undoStack else { return }
        // The stack suppresses pushes made while `apply` is replaying,
        // so a save-triggered-by-undo never re-pushes itself.
        stack.push(.editSave(assetId: assetId, previous: previous, next: next))
    }

    /// Hydrate the undo stack from on-disk version history on Develop
    /// entry, so Cmd+Z can walk back through prior versions even after
    /// the app restarts or the user re-enters Develop on a different
    /// asset. No-op if the stack already has an `.editSave` entry for
    /// this asset (avoids double-load when the user leaves and
    /// re-enters within the same session).
    private func hydrateUndoStack(for assetId: UUID) {
        guard let stack = undoStack else { return }
        guard !stack.hasEditSave(forAssetId: assetId) else { return }
        guard let history = try? catalog.editHistory(for: assetId) else { return }
        // `editHistory` returns newest-first; chronological order for
        // hydration means oldest-first.
        let chronological = history.reversed()
        var previous: EditState? = nil
        var pairs: [(assetId: UUID, previous: EditState?, next: EditState)] = []
        for entry in chronological {
            pairs.append((assetId: assetId, previous: previous, next: entry.state))
            previous = entry.state
        }
        let bounded: [(assetId: UUID, previous: EditState?, next: EditState)]
        if pairs.count > UndoStack.maxDepth {
            bounded = Array(pairs.suffix(UndoStack.maxDepth))
        } else {
            bounded = pairs
        }
        stack.hydrateEditHistory(pairs: bounded)
    }

    /// Drop any in-flight debounced save + its captured undo baseline.
    /// `UndoStack.apply` calls this before the catalog write on an
    /// `.editSave` replay so a slider change whose 500 ms save happens
    /// to wake during the replay can't clobber the undone state.
    public func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        hasUnsavedChanges = false
        pendingUndoPrevious = nil
    }
}
