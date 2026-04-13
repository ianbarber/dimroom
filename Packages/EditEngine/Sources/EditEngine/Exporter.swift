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
            return try exportRendered(
                sourceURL: sourceURL,
                editState: config.applyEdits ? editState : nil,
                destinationURL: config.destinationURL,
                context: context,
                writeImage: { rendered, dest, ctx in
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                    let quality = CGFloat(config.jpegQuality) / 100.0
                    try ctx.writeJPEGRepresentation(
                        of: rendered,
                        to: dest,
                        colorSpace: colorSpace,
                        options: [kCGImageDestinationLossyCompressionQuality: quality]
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
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                    try ctx.writeTIFFRepresentation(
                        of: rendered,
                        to: dest,
                        format: .RGBA16,
                        colorSpace: colorSpace,
                        options: [:]
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
        var image = CIImage(contentsOf: sourceURL)
        guard image != nil else {
            throw ExportError.unreadableSource(sourceURL)
        }

        if let editState {
            image = Renderer.render(source: image!, editState: editState)
        }

        try writeImage(image!, destinationURL, context)
        return destinationURL
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
