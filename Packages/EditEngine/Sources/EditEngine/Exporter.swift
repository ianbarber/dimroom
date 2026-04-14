import Catalog
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stateless single-file export writer.
///
/// Takes a source URL, optional `EditState`, format configuration, and a
/// shared `CIContext`, then writes the rendered output to a destination path.
/// The caller is responsible for collision-free naming — this type writes
/// exactly where it's told.
public enum Exporter {

    /// Export a single asset to disk.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the original file on disk.
    ///   - editState: If non-nil and `config.applyEdits` is true, the edit
    ///     state is rendered through `Renderer` before writing.
    ///   - config: Format, quality, and destination settings.
    ///   - context: A shared `CIContext` for GPU-backed rendering. Reuse
    ///     across a batch to amortize setup cost.
    /// - Returns: The URL the file was written to.
    @discardableResult
    public static func export(
        sourceURL: URL,
        editState: EditState?,
        config: ExportConfiguration,
        context: CIContext
    ) throws -> URL {
        switch config.format {
        case .original:
            return try exportOriginal(sourceURL: sourceURL, destinationURL: config.destinationURL)
        case .jpeg:
            let quality = CGFloat(config.jpegQuality) / 100.0
            return try exportRendered(
                sourceURL: sourceURL,
                editState: config.applyEdits ? editState : nil,
                destinationURL: config.destinationURL,
                context: context,
                writeImage: { rendered, dest, ctx in
                    try writeViaImageIO(
                        rendered, to: dest, context: ctx,
                        type: UTType.jpeg.identifier as CFString,
                        properties: [kCGImageDestinationLossyCompressionQuality: quality]
                    )
                }
            )
        case .tiff:
            return try exportRendered(
                sourceURL: sourceURL,
                editState: config.applyEdits ? editState : nil,
                destinationURL: config.destinationURL,
                context: context,
                writeImage: { rendered, dest, ctx in
                    try writeViaImageIO(
                        rendered, to: dest, context: ctx,
                        type: UTType.tiff.identifier as CFString,
                        properties: [:]
                    )
                }
            )
        }
    }

    // MARK: - Collision-free naming

    /// Given a base filename and the set of existing filenames in the
    /// destination directory, return a filename that doesn't collide.
    ///
    /// If `photo.jpg` already exists, returns `photo_1.jpg`, then
    /// `photo_2.jpg`, etc. Works with files that have no extension
    /// and with dotfiles.
    public static func collisionFreeName(
        baseName: String,
        existingNames: Set<String>
    ) -> String {
        guard existingNames.contains(baseName) else {
            return baseName
        }

        let nsName = baseName as NSString
        let ext = nsName.pathExtension
        let stem: String
        if ext.isEmpty {
            stem = baseName
        } else {
            stem = nsName.deletingPathExtension
        }

        var counter = 1
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(stem)_\(counter)"
            } else {
                candidate = "\(stem)_\(counter).\(ext)"
            }
            if !existingNames.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Private

    private static func exportOriginal(sourceURL: URL, destinationURL: URL) throws -> URL {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func exportRendered(
        sourceURL: URL,
        editState: EditState?,
        destinationURL: URL,
        context: CIContext,
        writeImage: (CIImage, URL, CIContext) throws -> Void
    ) throws -> URL {
        guard var image = CIImage(contentsOf: sourceURL) else {
            throw ExportError.unreadableSource(sourceURL)
        }

        if let editState {
            image = Renderer.render(source: image, editState: editState)
        }

        try writeImage(image, destinationURL, context)
        return destinationURL
    }

    /// Render a CIImage to a CGImage and write it to disk via ImageIO.
    /// This avoids the `CIImageRepresentationOption` bridging issues with
    /// `CIContext.writeJPEGRepresentation` and gives us explicit control
    /// over compression quality and output type.
    private static func writeViaImageIO(
        _ image: CIImage,
        to url: URL,
        context: CIContext,
        type: CFString,
        properties: [CFString: Any]
    ) throws {
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw ExportError.unreadableSource(url)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type, 1, nil
        ) else {
            throw ExportError.unreadableSource(url)
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.unreadableSource(url)
        }
    }
}

public enum ExportError: Error, LocalizedError {
    case unreadableSource(URL)
    case missingLocalPath(UUID)

    public var errorDescription: String? {
        switch self {
        case .unreadableSource(let url):
            return "Cannot read source file at \(url.path)"
        case .missingLocalPath(let id):
            return "Asset \(id) has no local path"
        }
    }
}
