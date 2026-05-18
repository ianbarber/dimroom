import Foundation

/// `CatalogUploading` implementation backed by a real file on disk.
/// Used by harness flows (and the AppDelegate when
/// `DIMROOM_HARNESS_STUB_REMOTE_CATALOG` is set) to simulate "an
/// existing catalog already lives on Drive" without touching Google.
///
/// `findExistingCatalog` reads the file's size and modification time;
/// the photo count is taken either from a sibling JSON sidecar
/// (`<remote>.json` with shape `{"photoCount": N}`) or the
/// `DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT` env var passed
/// to the init. `download` copies the file to `localPath`.
/// `upload` is intentionally a no-op-shaped error — this stub is
/// read-only by design so harness restore flows can't accidentally
/// stomp the fixture they're restoring from.
///
/// Lives in production SyncEngine (not test target) so the app target
/// can resolve it from harness env vars without the test bundle. This
/// matches the pattern established by `DriveClient/HarnessOAuthStubs`.
public struct LocalFileStubCatalogUploader: CatalogUploading {
    public let sourcePath: String
    public let driveFileId: String
    public let photoCount: Int?

    public init(
        sourcePath: String,
        driveFileId: String = "stub-remote-catalog",
        photoCount: Int? = nil
    ) {
        self.sourcePath = sourcePath
        self.driveFileId = driveFileId
        self.photoCount = photoCount
    }

    public func upload(
        snapshotPath: String,
        existingFileId: String?,
        photoCount: Int?
    ) async throws -> CatalogUploadResult {
        throw SyncEngineError.notAuthenticated
    }

    public func findExistingCatalog() async throws -> DriveCatalogRef? {
        let url = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return nil
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: sourcePath)
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        let modified = attrs[.modificationDate] as? Date

        let resolvedCount = photoCount ?? Self.readSidecarPhotoCount(forCatalogAt: url)

        return DriveCatalogRef(
            driveFileId: driveFileId,
            sizeBytes: size,
            modifiedTime: modified,
            photoCount: resolvedCount
        )
    }

    public func download(fileId: String, to localPath: String) async throws -> Int64 {
        let src = URL(fileURLWithPath: sourcePath)
        let dst = URL(fileURLWithPath: localPath)
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        let attrs = try FileManager.default.attributesOfItem(atPath: localPath)
        return (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
    }

    private static func readSidecarPhotoCount(forCatalogAt url: URL) -> Int? {
        // Look for "<catalog-path>.json" alongside the catalog. Harness
        // flows write this to communicate the asset count without
        // opening the catalog from this package.
        let sidecar = url.appendingPathExtension("json")
        guard let data = try? Data(contentsOf: sidecar),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = object["photoCount"] as? Int {
            return value
        }
        if let raw = object["photoCount"] as? String, let parsed = Int(raw) {
            return parsed
        }
        return nil
    }
}
