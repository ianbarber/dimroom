import Foundation

extension CatalogPublisher {
    /// Static restore helper. Runs *before* the catalog is opened so
    /// `AppDelegate.applicationDidFinishLaunching` can offer to download
    /// the remote catalog into `localPath` when the local file is
    /// absent.
    ///
    /// The flow:
    ///   1. If a file already exists at `localPath` → return `.localCatalogPresent`.
    ///   2. Try `uploader.findExistingCatalog()`. Network/auth failures
    ///      surface as `.notAuthenticated` when the uploader signals it
    ///      that way; other errors propagate.
    ///   3. If no remote → `.noRemoteCatalog`.
    ///   4. Ask `prompt` whether to restore. `false` → `.declinedByUser`.
    ///   5. `download(...)` into `localPath`, store the file id,
    ///      return `.restored(...)`.
    public static func restoreIfNeeded(
        localPath: String,
        uploader: any CatalogUploading,
        fileIdStore: any DriveFileIdStore,
        prompt: (CatalogRestorePrompt) async -> Bool
    ) async throws -> RestoreOutcome {
        if FileManager.default.fileExists(atPath: localPath) {
            return .localCatalogPresent
        }

        let remote: DriveCatalogRef?
        do {
            remote = try await uploader.findExistingCatalog()
        } catch SyncEngineError.notAuthenticated {
            return .notAuthenticated
        } catch {
            throw SyncEngineError.restoreFailed(underlying: String(describing: error))
        }

        guard let remote else {
            return .noRemoteCatalog
        }

        let approved = await prompt(
            CatalogRestorePrompt(
                driveFileId: remote.driveFileId,
                sizeBytes: remote.sizeBytes,
                modifiedTime: remote.modifiedTime
            )
        )
        if !approved {
            return .declinedByUser
        }

        let parent = URL(fileURLWithPath: localPath).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw SyncEngineError.restoreFailed(underlying: String(describing: error))
        }

        let bytes: Int64
        do {
            bytes = try await uploader.download(fileId: remote.driveFileId, to: localPath)
        } catch {
            throw SyncEngineError.restoreFailed(underlying: String(describing: error))
        }

        // Cache the id so subsequent publishes PATCH this file.
        do {
            try fileIdStore.save(remote.driveFileId)
        } catch {
            throw SyncEngineError.fileIdStoreFailed(underlying: String(describing: error))
        }

        return .restored(driveFileId: remote.driveFileId, downloadedBytes: bytes)
    }
}
