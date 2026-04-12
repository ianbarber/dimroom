import Catalog
import CoreGraphics
import CoreImage
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

    /// Return the cached thumbnail URL for `asset`, or `nil` if no
    /// thumbnail has been generated yet. This is a pure filesystem check;
    /// nonisolated so it can be called from any context without awaiting
    /// the actor.
    public nonisolated func thumbnailURL(for asset: Asset) -> URL? {
        cachedURL(for: asset, kind: .thumbnail)
    }

    public nonisolated func previewURL(for asset: Asset) -> URL? {
        cachedURL(for: asset, kind: .preview)
    }

    private nonisolated func cachedURL(for asset: Asset, kind: PreviewKind) -> URL? {
        let url = CachePaths.fileURL(for: asset, kind: kind, in: cacheDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Remove any cached thumbnail and preview JPEGs for `asset`. After
    /// this call both `thumbnailURL(for:)` and `previewURL(for:)` return
    /// `nil` until the next `generate` call regenerates them. Missing
    /// files are ignored — this is a best-effort cleanup, not an
    /// assertion that the cache was populated.
    ///
    /// Used by `LibraryViewModel.rotate` to force a synchronous
    /// regeneration after `Asset.rotation` changes, because `generate`
    /// short-circuits when both cached files already exist on disk.
    public func invalidate(for asset: Asset) {
        for kind in PreviewKind.allCases {
            let url = CachePaths.fileURL(for: asset, kind: kind, in: cacheDirectory)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Produce both preview sizes for `asset` from its original at
    /// `sourceURL`. Idempotent: if both files already exist on disk the
    /// call returns immediately without decoding.
    @discardableResult
    public func generate(for asset: Asset, sourceURL: URL) async throws -> PreviewSet {
        let thumbURL = CachePaths.fileURL(for: asset, kind: .thumbnail, in: cacheDirectory)
        let previewURL = CachePaths.fileURL(for: asset, kind: .preview, in: cacheDirectory)

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
            let target = CachePaths.fileURL(for: asset, kind: kind, in: cacheDirectory)
            let scaled = scale(rotated, longEdge: kind.maxEdge)
            try writeJPEG(scaled, to: target)
        }

        return PreviewSet(thumbnail: thumbURL, preview: previewURL)
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
