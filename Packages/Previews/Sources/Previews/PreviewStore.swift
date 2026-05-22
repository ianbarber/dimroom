import Catalog
import Combine
import CoreGraphics
import CoreImage
import EditEngine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates and serves cached thumbnails and previews for assets.
///
/// `PreviewStore` guarantees "one decode per asset per generate call": a
/// given source file is decoded into a single `CIImage`, then scaled to
/// both the thumbnail and preview sizes. Repeat calls for an asset whose
/// cache files already exist short-circuit without touching Core Image.
///
/// The cache directory is injectable so tests can operate in a temporary
/// directory and real callers can pass their
/// `~/Library/Application Support/Dimroom/previews` URL.
///
/// ## Tiered layout
///
/// Each asset has two on-disk tiers (issue #186):
///
/// - **Master** (`<hash>.thumb.jpg` / `<hash>.preview.jpg`) — written
///   exactly once from the original by `generate(...)`. Never overwritten
///   by edits. This is what `regenerateWithEdit` reads from, so repeated
///   regens are byte-identical and don't accumulate JPEG loss.
/// - **Display** (`<hash>.edit.thumb.jpg` / `<hash>.edit.preview.jpg`) —
///   written by `regenerateWithEdit` when `EditState` is non-identity.
///   Deleted when `EditState` is identity, so a reset-to-zero edit
///   surfaces the unedited master cleanly. Library + Loupe see display
///   files first via `thumbnailURL(for:)` / `previewURL(for:)`, which
///   transparently fall back to master.
public actor PreviewStore {
    private let cacheDirectory: URL
    private let context: CIContext
    private let fileManager: FileManager
    private let jpegQuality: CGFloat

    /// Number of times a source file has been fully decoded. Used by
    /// tests to assert idempotent regeneration doesn't re-decode.
    private(set) var decodeCount: Int = 0

    /// Number of times the RAW decode branch (`CIRAWFilter`) has been
    /// taken. Used by tests to distinguish "decoded via RAW path" from
    /// "decoded via JPEG path" without having to commit a real DNG.
    private(set) var rawDecodeCount: Int = 0

    /// Emits the asset id whose cached thumbnail + preview have just been
    /// rewritten via `regenerateWithEdit(for:editState:)`. Observers
    /// (e.g. `LibraryViewModel`) subscribe to force a grid reload so the
    /// edited look replaces the original-appearance thumbnail. Declared
    /// `nonisolated` so non-actor callers can subscribe without hopping
    /// through the actor; sends happen only on the actor.
    private nonisolated let regeneratedSubject = PassthroughSubject<UUID, Never>()

    public nonisolated var previewRegenerated: AnyPublisher<UUID, Never> {
        regeneratedSubject.eraseToAnyPublisher()
    }

    public init(cacheDirectory: URL) {
        self.init(
            cacheDirectory: cacheDirectory,
            context: CIContext(options: [.useSoftwareRenderer: false]),
            fileManager: .default,
            jpegQuality: 0.85
        )
    }

    /// Test-friendly initialiser. The `context` is injectable so unit
    /// tests can use a software-backed context if they need one, and the
    /// `fileManager` can be swapped for fakes if we ever need one.
    init(
        cacheDirectory: URL,
        context: CIContext,
        fileManager: FileManager,
        jpegQuality: CGFloat
    ) {
        self.cacheDirectory = cacheDirectory
        self.context = context
        self.fileManager = fileManager
        self.jpegQuality = jpegQuality
    }

    // MARK: - Public API

    /// Return the cached thumbnail URL for `asset`, preferring the
    /// display tier so callers see the edited look, falling back to
    /// master, returning `nil` if neither exists. Pure filesystem check;
    /// nonisolated so it can be called without awaiting the actor.
    public nonisolated func thumbnailURL(for asset: Asset) -> URL? {
        cachedURL(for: asset, kind: .thumbnail)
    }

    public nonisolated func previewURL(for asset: Asset) -> URL? {
        cachedURL(for: asset, kind: .preview)
    }

    /// Return the cached **master** thumbnail URL — the file written by
    /// `generate`, ignoring any display-tier override. Returns `nil` if
    /// `generate` has never run for this asset. Used by Develop, which
    /// must drive its render pipeline from unedited pixels so the saved
    /// `EditState` isn't double-applied (issue #186).
    public nonisolated func masterThumbnailURL(for asset: Asset) -> URL? {
        let url = CachePaths.fileURL(for: asset, kind: .thumbnail, tier: .master, in: cacheDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public nonisolated func masterPreviewURL(for asset: Asset) -> URL? {
        let url = CachePaths.fileURL(for: asset, kind: .preview, tier: .master, in: cacheDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func cachedURL(for asset: Asset, kind: PreviewKind) -> URL? {
        let display = CachePaths.fileURL(for: asset, kind: kind, tier: .display, in: cacheDirectory)
        if FileManager.default.fileExists(atPath: display.path) {
            return display
        }
        let master = CachePaths.fileURL(for: asset, kind: kind, tier: .master, in: cacheDirectory)
        return FileManager.default.fileExists(atPath: master.path) ? master : nil
    }

    /// Remove every cached preview file under the cache directory.
    /// Best-effort; missing files are ignored. The directory itself is
    /// recreated so subsequent `generate` calls can write into it.
    public func removeAll() {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return }
        if let contents = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Remove all cached thumbnail/preview JPEGs for `asset` across both
    /// tiers. After this call both URL accessors return `nil` until the
    /// next `generate` (and optional `regenerateWithEdit`) call rebuilds
    /// the cache. Missing files are ignored — this is a best-effort
    /// cleanup, not an assertion that the cache was populated.
    ///
    /// Used by `LibraryViewModel.rotate` to force a synchronous
    /// regeneration after `Asset.rotation` changes, because `generate`
    /// short-circuits when both cached master files already exist.
    public func invalidate(for asset: Asset) {
        for kind in PreviewKind.allCases {
            for tier: PreviewTier in [.master, .display] {
                let url = CachePaths.fileURL(for: asset, kind: kind, tier: tier, in: cacheDirectory)
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Produce both master preview sizes for `asset` from its original at
    /// `sourceURL`. Idempotent: if both master files already exist on
    /// disk the call returns immediately without decoding. Does not
    /// touch display-tier files — those are only written by
    /// `regenerateWithEdit`.
    @discardableResult
    public func generate(for asset: Asset, sourceURL: URL) async throws -> PreviewSet {
        let thumbURL = CachePaths.fileURL(for: asset, kind: .thumbnail, tier: .master, in: cacheDirectory)
        let previewURL = CachePaths.fileURL(for: asset, kind: .preview, tier: .master, in: cacheDirectory)

        if fileManager.fileExists(atPath: thumbURL.path),
           fileManager.fileExists(atPath: previewURL.path) {
            return PreviewSet(thumbnail: thumbURL, preview: previewURL)
        }

        let directory = CachePaths.directory(for: asset, in: cacheDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoded = try decode(sourceURL: sourceURL, asset: asset)
        decodeCount += 1
        let rotated = applyRotation(to: decoded, rotation: asset.rotation)

        for kind in PreviewKind.allCases {
            let target = CachePaths.fileURL(for: asset, kind: kind, tier: .master, in: cacheDirectory)
            let scaled = scale(rotated, longEdge: kind.maxEdge)
            try writeJPEG(scaled, to: target)
        }

        return PreviewSet(thumbnail: thumbURL, preview: previewURL)
    }

    /// Re-render `asset`'s display-tier thumbnail and preview by applying
    /// `editState` to the **master** preview. The master files are never
    /// touched, so this call is idempotent — running it repeatedly with
    /// the same `editState` produces byte-identical display JPEGs and
    /// doesn't accumulate JPEG generation loss (issue #186).
    ///
    /// When `editState` is identity, both display files are deleted (if
    /// present) so the URL accessors fall back to master, and the signal
    /// fires so Library reloads its grid back to the unedited bytes.
    ///
    /// No-op when the master preview hasn't been generated yet — the
    /// next `generate` call will lay down the master, and a subsequent
    /// `regenerateWithEdit` call will produce a display tier from it.
    ///
    /// Emits `asset.id` on `previewRegenerated` on success so observers
    /// can reload.
    public func regenerateWithEdit(for asset: Asset, editState: EditState) async {
        let masterPreviewURL = CachePaths.fileURL(
            for: asset, kind: .preview, tier: .master, in: cacheDirectory
        )
        guard fileManager.fileExists(atPath: masterPreviewURL.path),
              let source = CIImage(contentsOf: masterPreviewURL) else {
            return
        }

        if editState == EditState() {
            for kind in PreviewKind.allCases {
                let displayURL = CachePaths.fileURL(
                    for: asset, kind: kind, tier: .display, in: cacheDirectory
                )
                if fileManager.fileExists(atPath: displayURL.path) {
                    try? fileManager.removeItem(at: displayURL)
                }
            }
            regeneratedSubject.send(asset.id)
            return
        }

        let rendered = Renderer.render(source: source, editState: editState)

        for kind in PreviewKind.allCases {
            let target = CachePaths.fileURL(
                for: asset, kind: kind, tier: .display, in: cacheDirectory
            )
            let scaled = scale(rendered, longEdge: kind.maxEdge)
            do {
                try writeJPEG(scaled, to: target)
            } catch {
                // A write failure on one size leaves the cache in a
                // best-effort state; don't emit a signal that would
                // prompt consumers to reload stale bytes.
                return
            }
        }

        regeneratedSubject.send(asset.id)
    }

    // MARK: - Decoding

    private func decode(sourceURL: URL, asset: Asset) throws -> CIImage {
        if isRAW(asset: asset, sourceURL: sourceURL) {
            guard let filter = CIRAWFilter(imageURL: sourceURL),
                  let output = filter.outputImage else {
                throw PreviewError.decodeFailed(sourceURL)
            }
            rawDecodeCount += 1
            return output
        }

        // If ImageIO can't see any images in the file it's not a format
        // we can handle; if it sees images but Core Image still can't
        // produce a `CIImage`, that's a decode failure on a known format.
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PreviewError.unsupportedFormat(sourceURL)
        }

        guard let image = CIImage(contentsOf: sourceURL) else {
            throw PreviewError.decodeFailed(sourceURL)
        }
        return image
    }

    private func isRAW(asset: Asset, sourceURL: URL) -> Bool {
        if asset.rawFormat != nil { return true }
        guard let type = UTType(filenameExtension: sourceURL.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .rawImage)
    }

    // MARK: - Transformation

    private func applyRotation(to image: CIImage, rotation: Int) -> CIImage {
        // Normalise to 0/90/180/270. Any non-multiple-of-90 is treated as 0.
        let normalised = ((rotation % 360) + 360) % 360
        guard normalised % 90 == 0, normalised != 0 else { return image }

        // `Asset.rotation` is expressed as clockwise degrees for display.
        // Core Image uses a y-up coordinate system in which a positive
        // rotation angle is counter-clockwise, so we negate to get a
        // visual clockwise rotation of the image content.
        let radians = -CGFloat(normalised) * .pi / 180
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        // Rotating around the origin can push the image into negative
        // space; translate it back so the extent origin is at (0, 0).
        let translate = CGAffineTransform(
            translationX: -rotated.extent.origin.x,
            y: -rotated.extent.origin.y
        )
        return rotated.transformed(by: translate)
    }

    private func scale(_ image: CIImage, longEdge: CGFloat) -> CIImage {
        let extent = image.extent
        let currentLong = max(extent.width, extent.height)
        guard currentLong > 0 else { return image }

        // Never upscale — if the source is already smaller than the
        // target, just use it unmodified.
        let scale = min(1.0, longEdge / currentLong)
        guard scale < 1.0 else { return image }

        // CILanczosScaleTransform gives the best quality/speed tradeoff
        // for photographic downscales.
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    // MARK: - Encoding

    private func writeJPEG(_ image: CIImage, to url: URL) throws {
        // Render through the CIContext, then hand the resulting CGImage
        // to ImageIO for JPEG encoding. CGImageDestination gives us an
        // unambiguous way to set the compression quality; going through
        // `CIContext.writeJPEGRepresentation` would require fiddly
        // bridging of `CIImageRepresentationOption` keys.
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw PreviewError.encodeFailed
        }

        // Atomic write: encode to a sibling temp file and rename into
        // place, so a crash mid-write can't leave a half-written JPEG
        // that would later be served as a cache hit.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PreviewError.encodeFailed
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: tempURL)
            throw PreviewError.encodeFailed
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: tempURL, to: url)
        } catch {
            // Clean up the temp file if the rename failed so we don't
            // accumulate garbage in the cache directory.
            try? fileManager.removeItem(at: tempURL)
            throw PreviewError.writeFailed(url)
        }
    }
}
