import Foundation

/// Produces the Drive folder chain a given asset belongs under, per the
/// layout decision in CLAUDE.md:
/// `/PhotoTool/library/YYYY/YYYY-MM-DD/{digital|scans}/`.
///
/// This file stays dependency-free (no `Catalog` import) so the DriveClient
/// package can be consumed without pulling in storage; callers pass the
/// relevant pieces of an `Asset` via `DriveAssetRef` instead.
public enum DrivePath {

    public static let libraryRoot = "PhotoTool"
    public static let libraryDir = "library"

    /// UTC date formatter used to build the daily folder name. `en_US_POSIX`
    /// + fixed `yyyy-MM-dd` pattern avoids any user-locale surprises.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy"
        return f
    }()

    /// Full folder chain from the Drive root, e.g.
    /// `["PhotoTool", "library", "2024", "2024-06-14", "digital"]`.
    ///
    /// Uses `captureDate` when available, falling back to `importedDate`.
    /// The rationale: users organise by shoot date, so a 2024 photo
    /// imported today belongs under `2024/…`, not under the import day.
    /// Assets without EXIF capture data (e.g. film scans with no embedded
    /// timestamp) still land somewhere predictable via `importedDate`.
    public static func libraryFolderSegments(
        captureDate: Date?,
        importedDate: Date,
        sourceType: DriveSourceType
    ) -> [String] {
        let effectiveDate = captureDate ?? importedDate
        return [
            libraryRoot,
            libraryDir,
            yearFormatter.string(from: effectiveDate),
            dayFormatter.string(from: effectiveDate),
            sourceType.folderName,
        ]
    }

    /// Convenience — joins the segments with `/` for logging / display.
    public static func displayPath(
        captureDate: Date?,
        importedDate: Date,
        sourceType: DriveSourceType
    ) -> String {
        "/" + libraryFolderSegments(
            captureDate: captureDate,
            importedDate: importedDate,
            sourceType: sourceType
        ).joined(separator: "/")
    }
}

/// Mirrors `Asset.SourceType` without pulling `Catalog` in as a dependency.
/// Callers building a `DriveAssetRef` translate from their own enum.
public enum DriveSourceType: String, Sendable, Equatable {
    case digital
    case scan

    public var folderName: String {
        switch self {
        case .digital: return "digital"
        case .scan: return "scans"
        }
    }
}
