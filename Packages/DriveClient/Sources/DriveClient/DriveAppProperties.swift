import Foundation

/// Shared marker stamped onto every file dimroom writes to Drive (asset
/// originals + the catalog snapshot). Used by `ChangePoller` to drop
/// `drive.changes.list` rows that belong to files outside the
/// `/PhotoTool/` workflow — Drive v3 has no server-side parent filter
/// on `changes.list`, so the filter is necessarily client-side.
public enum DriveAppProperties {
    public static let dimroomMarkerKey = "dimroom"
    public static let dimroomMarkerValue = "1"
}
