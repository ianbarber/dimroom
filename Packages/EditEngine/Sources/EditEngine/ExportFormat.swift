import Foundation

/// Supported export formats.
public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case original
    case jpeg
    case tiff
}

/// Configuration for a single file export.
public struct ExportConfiguration: Sendable {
    public let format: ExportFormat
    /// JPEG quality on a 0-100 integer scale. Ignored for non-JPEG formats.
    public let jpegQuality: Int
    public let applyEdits: Bool
    public let destinationURL: URL

    public init(
        format: ExportFormat,
        jpegQuality: Int = 85,
        applyEdits: Bool = true,
        destinationURL: URL
    ) {
        self.format = format
        self.jpegQuality = jpegQuality
        self.applyEdits = applyEdits
        self.destinationURL = destinationURL
    }
}
