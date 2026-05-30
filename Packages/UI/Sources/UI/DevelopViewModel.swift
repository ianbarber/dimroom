import AppKit
import Catalog
import CoreImage
import EditEngine
import Foundation
import Previews
import UniformTypeIdentifiers

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
    /// source of truth to read from. Initial value is configurable via
    /// the settings store.
    @Published public var showHistogram: Bool

    /// Debounce window between a slider/curve mutation and the next
    /// `performRender` pass. Tuneable via Settings; defaults preserve
    /// the previous hardcoded `50ms` behaviour.
    public var renderDebounceMillis: Int

    /// Debounce window between the last mutation and the catalog write
    /// that records the new `EditState`. Tuneable via Settings;
    /// defaults preserve the previous hardcoded `500ms` behaviour.
    public var saveDebounceMillis: Int
    /// Monotonic counter bumped whenever `reloadEditState()` refreshes
    /// `editState` from the catalog (i.e. an undo/redo replay replaced
    /// the current values). The Develop view keys its slider animation
    /// off this so only replays tween — interactive drags don't.
    @Published public private(set) var replaySequence: Int = 0
    /// True while a Drive-backed original is being fetched on Develop
    /// entry. Sliders are gated on this so a user can't push edits
    /// against an asset whose full-res bytes aren't on disk yet — the
    /// export pipeline would then have to fall back to the preview.
    @Published public private(set) var isDownloadingOriginal: Bool = false
    /// Streaming download progress (0.0...1.0) for the in-flight original
    /// fetch, or `nil` when no fetch is active or the fetcher does not
    /// report progress (cached hit, unknown `Content-Length`).
    @Published public private(set) var downloadProgress: Double?
    public private(set) var currentAssetId: UUID?

    // MARK: - Pixel magnifier (#324)

    /// Whether the floating pixel magnifier is shown. App-level workspace
    /// UI state — *not* part of `EditState` — so it survives asset
    /// switches and is seeded from a Settings default. Toggled by the L
    /// key, the sidebar button, the View menu, and the harness.
    @Published public var magnifierVisible: Bool = false
    /// Rendered magnifier patch (a small native-resolution crop around
    /// `magnifierSamplePoint`), or `nil` when hidden / not yet rendered.
    @Published public private(set) var magnifierImage: NSImage?
    /// Sample point the magnifier is centred on, normalised `0…1` with a
    /// top-left origin (matching the on-screen reticle). Session-only.
    @Published public private(set) var magnifierSamplePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Magnifier zoom factor: 1 (1:1) or 2 (2:1). Session-only.
    @Published public private(set) var magnifierZoom: Int = 2
    /// True while the magnifier is sampling the 2048px preview rather than
    /// the full-resolution original (original not local yet, or a crop /
    /// rotation makes the original's pixel grid diverge from the preview).
    /// Drives the "Lower resolution" badge.
    @Published public private(set) var magnifierUsingPreviewFallback: Bool = false
    /// Drag offset of the floating magnifier window from its default
    /// top-right anchor. Persisted across launches via Settings.
    @Published public var magnifierWindowOffset: CGSize = .zero
    /// The region the magnifier is showing, normalised `0…1` top-left
    /// within the rendered preview — drives the reticle overlay. Kept in
    /// lock-step with the magnifier render so reticle and patch agree.
    @Published public private(set) var magnifierReticleRect: CGRect?

    /// Side of the square magnifier window, in points. A 200pt window at
    /// 1:1 samples 200px; at 2:1 samples 100px.
    public static let magnifierPointSize: CGFloat = 200

    /// Child view model driving the interactive crop overlay. Owned
    /// here so DevelopView can bind to it and so `commitCrop` has a
    /// direct write path when the harness fires `setCrop`.
    public let cropViewModel = CropViewModel()

    private var catalog: CatalogDatabase
    private var previewStore: PreviewStore
    private var originalFetcher: (any OriginalFetcher)?
    private var sourceImage: CIImage?
    /// Cached lens profile for the active asset, resolved via
    /// `LensProfileLibrary.lookup` at `activate` time. Nil for assets whose
    /// `lensModel` is missing or not registered — the renderer falls back
    /// to built-in placeholders in that case.
    private var currentLensProfile: LensProfile?
    private let ciContext = CIContext()
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var hasUnsavedChanges: Bool = false
    /// `EditState` snapshot taken the first time `setParameter` /
    /// `commitCrop` runs in a debounce window. Used as the `previous`
    /// value on the `.editSave` undo entry pushed after the save fires,
    /// so a continuous slider drag collapses to a single undo step.
    private var pendingUndoPrevious: EditState?
    private weak var undoStack: UndoStack?
    /// Source image the magnifier samples from — the full-resolution
    /// original when available, else the preview `sourceImage`.
    private var magnifierSource: CIImage?
    private var magnifierRenderTask: Task<Void, Never>?
    private var magnifierSourceTask: Task<Void, Never>?

    public init(
        catalog: CatalogDatabase,
        previewStore: PreviewStore,
        originalFetcher: (any OriginalFetcher)? = nil,
        defaultShowHistogram: Bool = true,
        renderDebounceMillis: Int = 50,
        saveDebounceMillis: Int = 500
    ) {
        self.catalog = catalog
        self.previewStore = previewStore
        self.originalFetcher = originalFetcher
        self.showHistogram = defaultShowHistogram
        self.renderDebounceMillis = renderDebounceMillis
        self.saveDebounceMillis = saveDebounceMillis
    }

    /// Late-bind the shared undo stack so edit saves show up as Cmd+Z
    /// actions. Optional — unit tests / the `.empty()` placeholder can
    /// run without one.
    public func attach(undoStack: UndoStack) {
        self.undoStack = undoStack
    }

    /// Late-bind the originals fetcher so the SwiftUI tree can construct
    /// the view model before the app finishes wiring `OriginalsCoordinator`.
    /// Matches how `LibraryViewModel.originalFetcher` is assigned post-init.
    public func attach(originalFetcher: any OriginalFetcher) {
        self.originalFetcher = originalFetcher
    }

    /// Size of the preview image currently driving the Develop pipeline,
    /// if any. Used to convert normalised crop coordinates to pixel
    /// coordinates for the renderer.
    public var sourceImageSize: CGSize? {
        guard let source = sourceImage else { return nil }
        return source.extent.size
    }

    /// Swap the backing catalog and preview store. Used by the
    /// AppDelegate at launch (placeholder → real) and by the hot-reload
    /// path (#259, old catalog → freshly-downloaded one). Cancels any
    /// render/save/download work in flight against the previous catalog
    /// so the new one doesn't inherit a `renderTask` that's already
    /// mid-decode of bytes the old catalog owned, or a `saveTask`
    /// queued to write through the about-to-be-released `dbQueue`.
    public func configure(catalog: CatalogDatabase, previewStore: PreviewStore) {
        renderTask?.cancel()
        saveTask?.cancel()
        downloadTask?.cancel()
        renderTask = nil
        saveTask = nil
        downloadTask = nil
        resetMagnifierRenderState()

        self.catalog = catalog
        self.previewStore = previewStore

        // Clear transient render state too. After a hot-reload the
        // SwiftUI view tree may still be observing this model, so
        // dropping `sourceImage` / `renderedImage` / `currentAssetId` /
        // `editState` prevents a flash of pixels from the old catalog
        // before the AppDelegate routes back to Library.
        sourceImage = nil
        renderedImage = nil
        histogram = nil
        currentAssetId = nil
        editState = EditState()
        hasUnsavedChanges = false
        pendingUndoPrevious = nil
        isDownloadingOriginal = false
        downloadProgress = nil
        cropViewModel.resetToIdentity()
    }

    public func activate(assetId: UUID?) async {
        guard let assetId else { return }
        guard let asset = try? catalog.fetchAsset(id: assetId) else { return }

        // Drop any crop UI state carried over from the previous asset
        // before loading the new EditState. Without this, switching from
        // a cropped asset to an un-cropped one would leave the overlay's
        // `cropRect` pointing at the prior asset's crop (issue #239 bug 2).
        cropViewModel.resetToIdentity()

        // Reset per-asset magnifier render state before loading the new
        // asset. Visibility persists (workspace preference); the source +
        // patch are reloaded below if the magnifier is showing.
        resetMagnifierRenderState()

        // Drive the Develop pipeline from the master preview so the saved
        // `EditState` is applied once over unedited pixels, not over an
        // already-edited display JPEG (issue #186).
        let previewURL = previewStore.masterPreviewURL(for: asset)
        currentLensProfile = LensProfileLibrary.lookup(for: asset.lensModel)
        guard let url = previewURL,
              let source = CIImage(contentsOf: url) else {
            currentAssetId = assetId
            editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
            hasUnsavedChanges = false
            pendingUndoPrevious = nil
            hydrateUndoStack(for: assetId)
            fetchOriginalIfNeeded(for: asset)
            return
        }

        sourceImage = source
        currentAssetId = assetId
        editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
        hasUnsavedChanges = false
        pendingUndoPrevious = nil
        hydrateUndoStack(for: assetId)
        triggerRender()
        fetchOriginalIfNeeded(for: asset)
        if magnifierVisible {
            loadMagnifierSourceIfNeeded()
        }
    }

    public func deactivate() {
        renderTask?.cancel()
        saveTask?.cancel()
        downloadTask?.cancel()
        renderTask = nil
        saveTask = nil
        downloadTask = nil
        resetMagnifierRenderState()
        isDownloadingOriginal = false
        downloadProgress = nil

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
            let originalFetcher = self.originalFetcher
            Task.detached {
                await Self.fetchAndRegenerateWithMasterRecovery(
                    assetId: assetId,
                    editState: next,
                    catalog: catalog,
                    previewStore: previewStore,
                    originalFetcher: originalFetcher
                )
            }
        }
        hasUnsavedChanges = false
        pendingUndoPrevious = nil

        sourceImage = nil
        renderedImage = nil
        histogram = nil
        currentAssetId = nil
        currentLensProfile = nil
        editState = EditState()
        cropViewModel.resetToIdentity()
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
        // Regenerate the cached thumb + preview so Library/Loupe reflect
        // the undone/redone look. Fire-and-forget so the replay (which
        // the caller `await`s) isn't blocked. PreviewStore is an actor
        // so back-to-back regens from rapid undo/redo serialise cleanly.
        let previewStore = self.previewStore
        let catalog = self.catalog
        let originalFetcher = self.originalFetcher
        Task.detached {
            await Self.fetchAndRegenerateWithMasterRecovery(
                assetId: assetId,
                editState: reloaded,
                catalog: catalog,
                previewStore: previewStore,
                originalFetcher: originalFetcher
            )
        }
    }

    public func setParameter(_ keyPath: WritableKeyPath<EditState, Double>, value: Double) {
        capturePendingUndoPreviousIfNeeded()
        editState[keyPath: keyPath] = value
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    /// Boolean-flag equivalent of `setParameter`. The geometry/lens-corrections
    /// stage exposes its two switches (chromatic aberration auto-correct,
    /// natural lens vignette correction) through this same debounced
    /// render+save path so a toggle generates a single `.editSave` undo entry.
    public func setFlag(_ keyPath: WritableKeyPath<EditState, Bool>, value: Bool) {
        capturePendingUndoPreviousIfNeeded()
        editState[keyPath: keyPath] = value
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    public func resetFlag(_ keyPath: WritableKeyPath<EditState, Bool>) {
        setFlag(keyPath, value: false)
    }

    /// Update a single per-band HSL slot. Mirrors `setParameter` for the
    /// scalar sliders: snapshots the previous state for the undo entry,
    /// flips `hasUnsavedChanges`, and schedules render + debounced save.
    public func setHSLParameter(axis: HSLAxis, rangeIndex: Int, value: Double) {
        guard (0..<8).contains(rangeIndex) else { return }
        capturePendingUndoPreviousIfNeeded()
        switch axis {
        case .hue: editState.hueShift[rangeIndex] = value
        case .saturation: editState.hslSaturation[rangeIndex] = value
        case .luminance: editState.hslLuminance[rangeIndex] = value
        }
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    public func resetHSLParameter(axis: HSLAxis, rangeIndex: Int) {
        setHSLParameter(axis: axis, rangeIndex: rangeIndex, value: 0)
    }

    public func hslValue(axis: HSLAxis, rangeIndex: Int) -> Double {
        guard (0..<8).contains(rangeIndex) else { return 0 }
        switch axis {
        case .hue: return editState.hueShift[rangeIndex]
        case .saturation: return editState.hslSaturation[rangeIndex]
        case .luminance: return editState.hslLuminance[rangeIndex]
        }
    }

    /// Currently-selected curve channel (Luminance / R / G / B). The
    /// curve editor binds to this so the channel tabs and the canvas
    /// stay in sync, and the harness can drive it through
    /// `setCurvePoints`.
    @Published public var selectedCurveChannel: CurveChannel = .luminance

    /// Replace the points for `channel` with `points`. Routes through
    /// the same debounced render + save pipeline as `setParameter` so
    /// a series of drag updates collapses to a single `.editSave` undo
    /// entry per debounce window.
    public func setCurvePoints(_ channel: CurveChannel, points: [CGPoint]) {
        capturePendingUndoPreviousIfNeeded()
        editState[keyPath: channel.keyPath] = points
        hasUnsavedChanges = true
        scheduleRender()
        scheduleSave()
    }

    /// Reset `channel` back to identity `[(0,0), (1,1)]`.
    public func resetCurve(_ channel: CurveChannel) {
        setCurvePoints(channel, points: EditState.identityCurve)
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
            editState.cropReferenceSize = nil
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
                // Record the resolution this pixel-space rect was authored
                // against (the ~2048px master preview). The renderer
                // rescales the rect from here to whatever it's actually
                // rendering, so export of the full-res original frames the
                // same region instead of a tiny corner ROI (#320).
                editState.cropReferenceSize = size
            } else {
                // No preview loaded yet — store the normalised rect
                // directly. The renderer won't see this until a preview
                // is attached and commitCrop fires again.
                editState.cropRect = normalisedRect
                editState.cropReferenceSize = nil
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

    // MARK: - Pixel magnifier (#324)

    /// Flip the magnifier on/off. Backs the L key, the sidebar button, and
    /// the View → Show Pixel Magnifier menu item.
    public func toggleMagnifier() {
        setMagnifierVisible(!magnifierVisible)
    }

    /// Show or hide the magnifier. Showing it loads the sample source and
    /// renders the first patch; hiding it tears down the render state but
    /// keeps the sample point + zoom so re-showing resumes in place.
    public func setMagnifierVisible(_ visible: Bool) {
        let changed = visible != magnifierVisible
        magnifierVisible = visible
        if visible {
            loadMagnifierSourceIfNeeded()
        } else if changed {
            resetMagnifierRenderState()
        }
    }

    /// Move the magnifier sample point. `point` is normalised `0…1` with a
    /// top-left origin (the on-screen reticle's coordinate space).
    public func setMagnifierSamplePoint(_ point: CGPoint) {
        magnifierSamplePoint = Self.clampPoint(point)
        scheduleMagnifierRender()
    }

    /// Set the magnifier zoom factor. Any value ≤ 1 is treated as 1:1;
    /// anything else as 2:1 (the two supported levels).
    public func setMagnifierZoom(_ zoom: Int) {
        magnifierZoom = zoom <= 1 ? 1 : 2
        scheduleMagnifierRender()
    }

    /// Cycle the magnifier between 1:1 and 2:1 — backs the in-window zoom
    /// button and scroll-wheel.
    public func cycleMagnifierZoom() {
        setMagnifierZoom(magnifierZoom == 1 ? 2 : 1)
    }

    /// Update the floating window's drag offset. The AppDelegate mirrors
    /// `magnifierWindowOffset` into Settings so the position persists.
    public func setMagnifierWindowOffset(_ offset: CGSize) {
        magnifierWindowOffset = offset
    }

    /// Unified entry used by the harness `setMagnifier` command. Fields
    /// left `nil` keep their current value.
    public func setMagnifier(visible: Bool, samplePoint: CGPoint?, zoom: Int?) {
        if let samplePoint {
            magnifierSamplePoint = Self.clampPoint(samplePoint)
        }
        if let zoom {
            magnifierZoom = zoom <= 1 ? 1 : 2
        }
        if visible != magnifierVisible {
            setMagnifierVisible(visible)
        } else if visible {
            // Already visible — only the sample point / zoom moved.
            scheduleMagnifierRender()
        }
    }

    /// Look up a `CurveChannel` by its wire string. Used by the
    /// harness handler so the wire format and view-model agree on the
    /// channel name set.
    nonisolated public static func curveChannel(named name: String) -> CurveChannel? {
        return CurveChannel(rawValue: name)
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
        case "luminanceNoiseReduction": return \.luminanceNoiseReduction
        case "chrominanceNoiseReduction": return \.chrominanceNoiseReduction
        case "vignetteAmount": return \.vignetteAmount
        case "vignetteRoundness": return \.vignetteRoundness
        case "vignetteSoftness": return \.vignetteSoftness
        case "splitToneHighlightHue": return \.splitToneHighlightHue
        case "splitToneHighlightSaturation": return \.splitToneHighlightSaturation
        case "splitToneShadowHue": return \.splitToneShadowHue
        case "splitToneShadowSaturation": return \.splitToneShadowSaturation
        case "splitToneBalance": return \.splitToneBalance
        case "perspectiveVertical": return \.perspectiveVertical
        case "perspectiveHorizontal": return \.perspectiveHorizontal
        case "perspectiveRotation": return \.perspectiveRotation
        default: return nil
        }
    }

    /// Boolean counterpart to `keyPath(forParameter:)`. The harness uses this
    /// to route `setEditFlag` to the right edit-state field by name.
    nonisolated public static func keyPath(forFlag name: String) -> WritableKeyPath<EditState, Bool>? {
        switch name {
        case "chromaticAberration": return \.chromaticAberration
        case "lensVignette": return \.lensVignette
        default: return nil
        }
    }

    /// Lookup the `HSLAxis` for a harness array-parameter name. Used by
    /// `setEditArrayParameter` / `resetEditArrayParameter` so the harness
    /// can address `hueShift`, `hslSaturation`, and `hslLuminance` by
    /// string without exposing key paths to per-array elements.
    nonisolated public static func hslAxis(forParameter name: String) -> HSLAxis? {
        switch name {
        case "hueShift": return .hue
        case "hslSaturation": return .saturation
        case "hslLuminance": return .luminance
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
        let millis = max(0, renderDebounceMillis)
        renderTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
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

    /// The `EditState` the live preview renders. While the crop overlay is
    /// active the user must see the full frame with the overlay drawn on
    /// top — otherwise adjusting or undoing an existing crop is impossible
    /// (#156 bug 2) — so the crop rect is stripped while `cropAngle` is
    /// kept. Shared by `performRender` and `renderMagnifier` so the
    /// magnifier patch matches exactly what the preview shows.
    private func currentRenderEditState() -> EditState {
        var state = editState
        if cropViewModel.isActive {
            state.cropRect = nil
            state.cropAngle = cropViewModel.cropAngle == 0 ? nil : cropViewModel.cropAngle
        }
        return state
    }

    private func performRender() async {
        guard let source = sourceImage else { return }
        let state = currentRenderEditState()
        isRendering = true

        let lensProfile = currentLensProfile
        let result: (image: NSImage?, histogram: HistogramData?) = await Task.detached(priority: .userInitiated) { [ciContext] in
            let output = Renderer.render(source: source, editState: state, lensProfile: lensProfile)
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

        // Keep the magnifier patch in step with every preview render so a
        // slider change updates both. Cheap — it samples only a small region.
        if magnifierVisible {
            scheduleMagnifierRender()
        }
    }

    // MARK: - Magnifier rendering (private)

    private static func clampPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    /// Region size, in source pixels, the magnifier samples: a 200pt
    /// window covers 200px at 1:1 and 100px at 2:1.
    private var magnifierRegionPixelSize: CGSize {
        let side = Self.magnifierPointSize / CGFloat(max(1, magnifierZoom))
        return CGSize(width: side, height: side)
    }

    /// Drop per-asset magnifier render state (source, patch, reticle,
    /// fallback flag) and cancel its in-flight tasks. Leaves
    /// `magnifierVisible`, `magnifierSamplePoint`, `magnifierZoom`, and
    /// `magnifierWindowOffset` untouched — those are workspace state.
    private func resetMagnifierRenderState() {
        magnifierRenderTask?.cancel()
        magnifierSourceTask?.cancel()
        magnifierRenderTask = nil
        magnifierSourceTask = nil
        magnifierSource = nil
        magnifierImage = nil
        magnifierReticleRect = nil
        magnifierUsingPreviewFallback = false
    }

    /// Pick the image the magnifier samples from. The full-resolution
    /// original is preferred so sharpening / NR / clarity show real
    /// pixels, but a crop or a non-zero user rotation makes the original's
    /// pixel grid diverge from the rotated/cropped preview the reticle is
    /// drawn over, so we fall back to the preview (lower-resolution badge)
    /// in those cases — and while the original is still downloading.
    private func loadMagnifierSourceIfNeeded() {
        magnifierSourceTask?.cancel()
        magnifierSourceTask = nil

        guard magnifierVisible,
              let assetId = currentAssetId,
              let preview = sourceImage else {
            return
        }

        // Show the preview immediately so the window isn't blank while any
        // original download / decode runs.
        magnifierSource = preview
        magnifierUsingPreviewFallback = true
        scheduleMagnifierRender()

        let asset = try? catalog.fetchAsset(id: assetId)
        let cropActive = editState.cropRect != nil
        let rotated = (asset?.rotation ?? 0) % 360 != 0
        guard let asset, let fetcher = originalFetcher, !cropActive, !rotated else {
            return
        }

        magnifierSourceTask = Task { [weak self] in
            guard let url = await fetcher.fetchOriginal(assetId: assetId) else { return }
            let decoded: CIImage? = await Task.detached {
                Self.decodeOriginal(url: url, asset: asset)
            }.value
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                // Asset / crop may have changed while the original loaded.
                guard self.magnifierVisible,
                      self.currentAssetId == assetId,
                      self.editState.cropRect == nil,
                      let decoded else { return }
                self.magnifierSource = decoded
                self.magnifierUsingPreviewFallback = false
                self.scheduleMagnifierRender()
            }
        }
    }

    private func scheduleMagnifierRender() {
        magnifierRenderTask?.cancel()
        guard magnifierVisible, magnifierSource != nil else { return }
        // ~30ms debounce so drag-to-move and live slider updates stay smooth.
        magnifierRenderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderMagnifier()
        }
    }

    private func renderMagnifier() async {
        guard magnifierVisible, let source = magnifierSource else { return }
        let state = currentRenderEditState()
        let lensProfile = currentLensProfile
        let sampleCenter = magnifierSamplePoint
        let regionSize = magnifierRegionPixelSize

        let result: (image: NSImage?, reticle: CGRect?) = await Task.detached(priority: .userInitiated) { [ciContext] in
            let region = Renderer.renderRegion(
                source: source,
                editState: state,
                context: ciContext,
                sampleCenter: sampleCenter,
                regionPixelSize: regionSize,
                lensProfile: lensProfile
            )
            guard let cg = region.image, region.outputExtent.width > 0, region.outputExtent.height > 0 else {
                return (nil, nil)
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            // Convert the sampled region into a normalised, top-left-origin
            // rect within the rendered output so the reticle overlay lines
            // up exactly with what the patch shows.
            let ext = region.outputExtent
            let r = region.regionRect
            let reticle = CGRect(
                x: (r.minX - ext.minX) / ext.width,
                y: (ext.maxY - r.maxY) / ext.height,
                width: r.width / ext.width,
                height: r.height / ext.height
            )
            return (image, reticle)
        }.value

        guard !Task.isCancelled, magnifierVisible else { return }
        magnifierImage = result.image
        magnifierReticleRect = result.reticle
    }

    /// Decode an original into a `CIImage`, mirroring `PreviewStore.decode`:
    /// RAW files go through `CIRAWFilter`, everything else through
    /// `CIImage(contentsOf:)`. Only ever called for assets at zero user
    /// rotation, so no orientation transform is needed to match the preview.
    nonisolated private static func decodeOriginal(url: URL, asset: Asset) -> CIImage? {
        if isRAW(asset: asset, url: url) {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            return filter.outputImage
        }
        return CIImage(contentsOf: url)
    }

    nonisolated private static func isRAW(asset: Asset, url: URL) -> Bool {
        if asset.rawFormat != nil { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let millis = max(0, saveDebounceMillis)
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
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
                await Self.regenerateWithMasterRecovery(
                    asset: asset,
                    editState: next,
                    previewStore: previewStore,
                    originalFetcher: originalFetcher
                )
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

    /// Kick off an on-demand original fetch when the asset has a Drive
    /// id but no usable local file. The preview-driven Develop pipeline
    /// keeps running while this is in flight; sliders are gated on
    /// `isDownloadingOriginal` so the user can't queue edits against an
    /// asset whose full-res bytes aren't on disk yet (export would then
    /// fall back to the preview, losing resolution). No-op if no
    /// fetcher is attached, the asset already has a present local path,
    /// or there's no `driveFileId` to fetch from.
    private func fetchOriginalIfNeeded(for asset: Asset) {
        // Cancel and reset before any early-return: an A→B activation
        // where B has a local file (or no driveFileId) must not leave
        // A's task running with `isDownloadingOriginal` pinned true —
        // A's tail can't clear it because the closure gates on
        // `currentAssetId == assetId`, which is now B's id. See #204.
        downloadTask?.cancel()
        downloadTask = nil
        isDownloadingOriginal = false
        downloadProgress = nil

        guard let fetcher = originalFetcher else { return }
        if let localPath = asset.localPath,
           FileManager.default.fileExists(atPath: localPath) {
            return
        }
        guard asset.driveFileId != nil else { return }

        let assetId = asset.id
        isDownloadingOriginal = true

        downloadTask = Task { [weak self] in
            let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isDownloadingOriginal,
                          self.currentAssetId == assetId else { return }
                    let clamped = min(max(fraction, 0), 1)
                    let existing = self.downloadProgress ?? 0
                    if clamped >= existing {
                        self.downloadProgress = clamped
                    }
                }
            }
            _ = await fetcher.fetchOriginal(assetId: assetId, progress: progress)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard self.currentAssetId == assetId else { return }
                self.isDownloadingOriginal = false
                self.downloadProgress = nil
                // The original is now local — if the magnifier is showing a
                // preview fallback, upgrade it to full resolution.
                if self.magnifierVisible, self.magnifierUsingPreviewFallback {
                    self.loadMagnifierSourceIfNeeded()
                }
            }
        }
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

    /// Fetch `assetId` from the catalog and forward into
    /// `regenerateWithMasterRecovery`. Composed helper for the
    /// `deactivate` / `reloadEditState` `Task.detached` blocks, which
    /// both need to look up the asset before regenerating now that
    /// `self` has escaped. The `scheduleSave` site keeps its inline
    /// fetch because its `if let asset` lives next to a `Task.isCancelled`
    /// guard inside the outer `saveTask`.
    nonisolated static func fetchAndRegenerateWithMasterRecovery(
        assetId: UUID,
        editState: EditState,
        catalog: CatalogDatabase,
        previewStore: PreviewStore,
        originalFetcher: (any OriginalFetcher)?
    ) async {
        guard let asset = try? catalog.fetchAsset(id: assetId) else { return }
        await regenerateWithMasterRecovery(
            asset: asset,
            editState: editState,
            previewStore: previewStore,
            originalFetcher: originalFetcher
        )
    }

    /// Run `regenerateWithEdit` for `asset`, transparently rebuilding
    /// the master preview tier first if it has been evicted. When the
    /// master JPEG is missing and an `OriginalFetcher` is wired, this
    /// fetches the original and re-runs `PreviewStore.generate` to lay
    /// the master back down before the regen reads it. Without a
    /// fetcher (or when the fetch returns `nil`), the regen call falls
    /// through to `PreviewStore.regenerateWithEdit`'s own missing-master
    /// no-op so an offline / unreachable-Drive session is no worse than
    /// today's behaviour.
    ///
    /// `nonisolated static` so the `deactivate` site can call it from a
    /// `Task.detached` after `self` has escaped.
    nonisolated static func regenerateWithMasterRecovery(
        asset: Asset,
        editState: EditState,
        previewStore: PreviewStore,
        originalFetcher: (any OriginalFetcher)?
    ) async {
        if previewStore.masterPreviewURL(for: asset) == nil,
           let fetcher = originalFetcher,
           let originalURL = await fetcher.fetchOriginal(assetId: asset.id) {
            _ = try? await previewStore.generate(for: asset, sourceURL: originalURL)
        }
        await previewStore.regenerateWithEdit(for: asset, editState: editState)
    }
}
