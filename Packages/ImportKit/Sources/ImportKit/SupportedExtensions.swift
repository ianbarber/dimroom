import Foundation

/// Allowlist of file extensions the folder importer recognises.
/// All comparisons are case-insensitive — callers lowercase before looking up.
public enum SupportedExtensions {
    /// All recognised extensions, lowercased. Anything outside this set is ignored
    /// by the folder importer.
    public static let all: Set<String> = [
        "jpg", "jpeg",
        "heic", "heif",
        "png",
        "tiff", "tif",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf",
    ]

    /// Subset of `all` that is treated as RAW — these extensions populate
    /// `Asset.rawFormat` on import.
    public static let raw: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf",
    ]

    /// Returns true if the given extension (with or without a leading dot,
    /// any case) is in the supported allowlist.
    public static func isSupported(_ ext: String) -> Bool {
        all.contains(normalize(ext))
    }

    /// Returns true if the extension is a RAW format.
    public static func isRaw(_ ext: String) -> Bool {
        raw.contains(normalize(ext))
    }

    private static func normalize(_ ext: String) -> String {
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return e
    }
}
