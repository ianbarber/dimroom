import Foundation

public enum UploadOutcome: Sendable, Equatable {
    case uploaded(fileID: String)
    case skippedDuplicate(fileID: String)
}

/// Orchestrates a single asset's upload to Drive:
///   1. Resolve the daily folder (creating it if missing).
///   2. Look up `appProperties.contentHash` inside that folder for dedup.
///   3. Pick simple vs resumable upload by byte size.
///   4. Return the Drive file ID (new or reused).
///
/// Designed to be injected: all the collaborators are value-level so
/// tests can swap them for canned responses, and the live
/// `resolveDriveClient()` wiring in the app just composes them.
public actor DriveUploader {
    private let session: AuthorizedSession
    private let folderResolver: DriveFolderResolver
    private let retryPolicy: RetryPolicy
    private let clock: any Clock<Duration>
    private let simpleUploadThreshold: Int64
    private let resumableChunkSize: Int

    public init(
        session: AuthorizedSession,
        folderResolver: DriveFolderResolver,
        retryPolicy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock(),
        simpleUploadThreshold: Int64 = 5 * 1024 * 1024,
        resumableChunkSize: Int = 8 * 1024 * 1024
    ) {
        self.session = session
        self.folderResolver = folderResolver
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.simpleUploadThreshold = simpleUploadThreshold
        self.resumableChunkSize = resumableChunkSize
    }

    public func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome {
        guard FileManager.default.fileExists(atPath: ref.localPath.path) else {
            throw DriveUploadError.missingLocalFile(ref.assetId)
        }
        let segments = DrivePath.libraryFolderSegments(
            captureDate: ref.captureDate,
            importedDate: ref.importedDate,
            sourceType: ref.sourceType
        )
        let folderId = try await folderResolver.resolve(segments: segments)

        // Dedup — any existing file in the folder with the same
        // contentHash is reused. Issue-scoped to one folder for now; a
        // library-wide lookup is tracked as a follow-up.
        if let existing = try await findExisting(contentHash: ref.contentHash, folderId: folderId) {
            return .skippedDuplicate(fileID: existing)
        }

        let metadataName = ref.originalFilename
        let appProperties: [String: String] = [
            "contentHash": ref.contentHash,
            "dimroomAssetId": ref.assetId.uuidString,
        ]

        if ref.bytes <= simpleUploadThreshold {
            let metadata = SimpleUpload.Metadata(
                name: metadataName,
                parents: [folderId],
                mimeType: ref.mimeType,
                appProperties: appProperties
            )
            let id = try await SimpleUpload.upload(
                metadata: metadata,
                fileURL: ref.localPath,
                session: session,
                retryPolicy: retryPolicy,
                clock: clock,
                progress: progress
            )
            return .uploaded(fileID: id)
        } else {
            let metadata = ResumableUpload.Metadata(
                name: metadataName,
                parents: [folderId],
                mimeType: ref.mimeType,
                appProperties: appProperties
            )
            let id = try await ResumableUpload.upload(
                metadata: metadata,
                fileURL: ref.localPath,
                totalBytes: ref.bytes,
                session: session,
                retryPolicy: retryPolicy,
                clock: clock,
                chunkSize: resumableChunkSize,
                progress: progress
            )
            return .uploaded(fileID: id)
        }
    }

    private func findExisting(contentHash: String, folderId: String) async throws -> String? {
        let request = DriveFilesAPI.findByContentHashRequest(
            contentHash: contentHash,
            parentId: folderId
        )
        let result = try await sendWithRetry(
            request: request,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        guard (200..<300).contains(result.response.statusCode) else {
            throw DriveUploadError.listFailed(status: result.response.statusCode)
        }
        let list = try JSONDecoder().decode(DriveFilesAPI.DriveFileList.self, from: result.data)
        return list.files.first?.id
    }
}

/// Narrow protocol the UI layer depends on so tests can substitute a
/// stub without pulling the full `DriveUploader` actor into UI tests.
public protocol DriveUploading: Sendable {
    func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome
}

extension DriveUploader: DriveUploading {}
