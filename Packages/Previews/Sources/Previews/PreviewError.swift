import Foundation

public enum PreviewError: Error, Equatable {
    /// The source file could not be decoded into a `CIImage`.
    case decodeFailed(URL)
    /// Core Image failed to encode the scaled output as JPEG.
    case encodeFailed
    /// The source URL does not point at a supported image format.
    case unsupportedFormat(URL)
    /// A cached JPEG could not be written to disk at the given URL.
    case writeFailed(URL)
}
