import Foundation

/// Narrow interface the originals cache uses to fetch bytes. `DriveClient`
/// is the production implementation; tests inject a stub.
public protocol OriginalsDownloader: Sendable {
    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws
}

extension DriveClient: OriginalsDownloader {
    public func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try await downloadFile(id: driveFileId, to: destinationURL, progress: progress)
    }
}
