import Foundation

/// Live `DriveMarkerScanning` over an `AuthorizedSession`. Resolves the
/// `/PhotoTool/` root folder, recursively pages through its children
/// collecting every non-folder file, and PATCHes the dimroom marker onto
/// a single file on demand. Reuses the shared `sendWithRetry(...)` helper
/// + `RetryPolicy`, exactly like `DriveUploader` / `DriveFolderResolver`.
public struct DriveMarkerScanner: DriveMarkerScanning {
    private let session: AuthorizedSession
    private let folderResolver: DriveFolderResolver
    private let retryPolicy: RetryPolicy
    private let clock: any Clock<Duration>

    public init(
        session: AuthorizedSession,
        folderResolver: DriveFolderResolver,
        retryPolicy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.session = session
        self.folderResolver = folderResolver
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    public func listAllFiles() async throws -> [DriveFilesAPI.DriveFile] {
        let rootId = try await folderResolver.resolve(segments: [DrivePath.libraryRoot])
        return try await walk(parentId: rootId)
    }

    /// Depth-first walk: pages through `parentId`'s children, appending
    /// non-folder files and recursing into folders.
    private func walk(parentId: String) async throws -> [DriveFilesAPI.DriveFile] {
        var collected: [DriveFilesAPI.DriveFile] = []
        var pageToken: String?
        repeat {
            let request = DriveFilesAPI.listChildrenRequest(
                parentId: parentId,
                pageToken: pageToken
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
            for file in list.files {
                if file.mimeType == DriveFilesAPI.folderMimeType {
                    collected.append(contentsOf: try await walk(parentId: file.id))
                } else {
                    collected.append(file)
                }
            }
            pageToken = list.nextPageToken
        } while pageToken != nil
        return collected
    }

    public func patchMarker(fileId: String) async throws {
        let request = try DriveFilesAPI.patchAppPropertiesRequest(
            fileId: fileId,
            appProperties: [
                DriveAppProperties.dimroomMarkerKey: DriveAppProperties.dimroomMarkerValue,
            ]
        )
        let result = try await sendWithRetry(
            request: request,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        guard (200..<300).contains(result.response.statusCode) else {
            throw DriveUploadError.patchFailed(status: result.response.statusCode)
        }
    }
}
