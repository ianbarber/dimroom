import Catalog
import DriveClient
import Foundation

/// Orchestrates a batch Drive upload flow: iterates assets, builds
/// `DriveAssetRef`s, delegates to a `DriveUploading` implementation, and
/// writes the resulting Drive file IDs back to the catalog.
///
/// Mirrors `ExportCoordinator` in shape — pure coordination logic with
/// no SwiftUI dependency, headless-testable via the `DriveUploading`
/// protocol.
@MainActor
public final class UploadCoordinator: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case idle
        case uploading
        case done(uploadedCount: Int, skippedCount: Int)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var currentItem: Int = 0
    @Published public private(set) var totalItems: Int = 0
    @Published public private(set) var currentFilename: String = ""
    @Published public private(set) var currentBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0

    public init() {}

    public var isActive: Bool {
        if case .uploading = phase { return true }
        return false
    }

    /// Uploads all provided assets. For each successful upload (or
    /// dedup hit) the asset's `driveFileId` is persisted. Unlike
    /// `ExportCoordinator`, a persistent upload failure halts the batch
    /// and flips to `.failed` — uploads are retryable, so stopping on
    /// the first unrecoverable error keeps error surfaces short and
    /// lets the user fix the cause before continuing.
    public func run(
        assets: [Asset],
        catalog: CatalogDatabase,
        uploader: any DriveUploading
    ) async {
        phase = .uploading
        currentItem = 0
        totalItems = assets.count
        currentFilename = ""
        currentBytes = 0
        totalBytes = 0

        var uploaded = 0
        var skipped = 0

        for asset in assets {
            guard let localPath = asset.localPath else {
                currentItem += 1
                continue
            }
            let ref = DriveAssetRef(
                assetId: asset.id,
                localPath: URL(fileURLWithPath: localPath),
                contentHash: asset.contentHash,
                originalFilename: asset.originalFilename,
                bytes: asset.bytes,
                captureDate: asset.captureDate,
                importedDate: asset.importedDate,
                sourceType: Self.driveSourceType(for: asset.sourceType),
                mimeType: DriveMimeType.mimeType(forFilename: asset.originalFilename)
            )

            currentFilename = asset.originalFilename
            currentBytes = 0
            totalBytes = asset.bytes

            do {
                let outcome = try await uploader.upload(ref) { [weak self] uploadedBytes, totalBytes in
                    Task { @MainActor in
                        guard let self else { return }
                        self.currentBytes = uploadedBytes
                        self.totalBytes = totalBytes
                    }
                }
                switch outcome {
                case .uploaded(let fileID):
                    try catalog.updateDriveFileId(assetId: asset.id, driveFileId: fileID)
                    uploaded += 1
                case .skippedDuplicate(let fileID):
                    // Dedup hit — still persist the reused file ID so we
                    // don't re-query on the next upload.
                    try catalog.updateDriveFileId(assetId: asset.id, driveFileId: fileID)
                    skipped += 1
                }
                currentItem += 1
            } catch {
                phase = .failed(Self.message(for: error))
                return
            }
        }

        phase = .done(uploadedCount: uploaded, skippedCount: skipped)
    }

    public func reset() {
        phase = .idle
        currentItem = 0
        totalItems = 0
        currentFilename = ""
        currentBytes = 0
        totalBytes = 0
    }

    // MARK: - Test helpers

    func setPhaseForTesting(_ newPhase: Phase) {
        phase = newPhase
    }

    func setProgressForTesting(
        current: Int,
        total: Int,
        filename: String,
        currentBytes: Int64,
        totalBytes: Int64
    ) {
        currentItem = current
        totalItems = total
        currentFilename = filename
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }

    // MARK: - Private

    private static func driveSourceType(for source: Asset.SourceType) -> DriveSourceType {
        switch source {
        case .digital: return .digital
        case .scan: return .scan
        }
    }

    private static func message(for error: Error) -> String {
        if let driveError = error as? DriveUploadError {
            switch driveError {
            case .missingLocalFile: return "original file missing locally"
            case .folderCreationFailed(let status): return "folder creation failed (\(status))"
            case .listFailed(let status): return "folder query failed (\(status))"
            case .uploadFailed(let status, _): return "upload failed (\(status))"
            case .resumableSessionLost: return "resumable session lost"
            case .retryBudgetExhausted: return "retry budget exhausted"
            case .invalidServerResponse(let reason): return "invalid server response: \(reason)"
            }
        }
        return error.localizedDescription
    }
}
