import DriveClient
import Foundation

/// Production implementation of `CatalogUploading` backed by Drive v3.
///
/// Catalog upload differs from asset upload in two key ways:
///   - There's no dedup. Every publish replaces the existing file
///     (overwrite-in-place, last-write-wins per the issue).
///   - We PATCH by Drive file id when we have one, only POST-creating
///     when no id is cached. This avoids the `files.list` round-trip
///     and prevents the rare race where two clients each create their
///     own catalog file.
///
/// We use multipart upload for simplicity; catalog files are typically
/// well under 100 MB. If catalogs grow large enough that buffering the
/// whole snapshot in memory becomes a problem, this can swap to the
/// resumable session flow used by asset upload — out of scope for
/// Stage 5.4.
public actor DriveCatalogUploader: CatalogUploading {
    public static let catalogFolderSegments: [String] = ["PhotoTool", "catalog"]
    public static let catalogFilename: String = "catalog.sqlite"
    public static let catalogMimeType: String = "application/x-sqlite3"

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

    public func upload(
        snapshotPath: String,
        existingFileId: String?
    ) async throws -> CatalogUploadResult {
        let url = URL(fileURLWithPath: snapshotPath)
        let data = try Data(contentsOf: url)

        if let existingFileId {
            let id = try await updateExistingFile(
                fileId: existingFileId,
                bytes: data
            )
            return CatalogUploadResult(
                driveFileId: id,
                uploadedBytes: Int64(data.count),
                wasCreate: false
            )
        }
        let folderId = try await folderResolver.resolve(
            segments: Self.catalogFolderSegments
        )
        let id = try await createFile(parentId: folderId, bytes: data)
        return CatalogUploadResult(
            driveFileId: id,
            uploadedBytes: Int64(data.count),
            wasCreate: true
        )
    }

    public func findExistingCatalog() async throws -> DriveCatalogRef? {
        let folderId = try await folderResolver.resolve(
            segments: Self.catalogFolderSegments
        )
        let request = Self.listCatalogRequest(folderId: folderId)
        let (data, response) = try await sendWithCatalogRetry(request: request)
        guard (200..<300).contains(response.statusCode) else {
            throw SyncEngineError.uploadFailed(
                underlying: "files.list failed status=\(response.statusCode)"
            )
        }
        guard let parsed = try Self.parseFileList(data) else { return nil }
        return parsed
    }

    public func download(fileId: String, to localPath: String) async throws -> Int64 {
        let url = URL(
            string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media"
        )!
        let request = URLRequest(url: url)
        let destinationURL = URL(fileURLWithPath: localPath)
        let response = try await session.download(
            for: request,
            to: destinationURL,
            progress: nil
        )
        guard (200..<300).contains(response.statusCode) else {
            throw SyncEngineError.restoreFailed(
                underlying: "download failed status=\(response.statusCode)"
            )
        }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )[.size] as? Int64) ?? 0
        return size
    }

    // MARK: - Request builders

    static func uploadEndpoint(multipart: Bool, fileId: String?) -> URL {
        var pathSuffix = ""
        if let fileId {
            pathSuffix = "/\(fileId)"
        }
        var components = URLComponents(
            url: URL(string: "https://www.googleapis.com/upload/drive/v3/files\(pathSuffix)")!,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: multipart ? "multipart" : "media"),
            URLQueryItem(name: "fields", value: "id"),
        ]
        return components.url!
    }

    static func listCatalogRequest(folderId: String) -> URLRequest {
        var components = URLComponents(
            url: DriveFilesAPI.filesEndpoint,
            resolvingAgainstBaseURL: false
        )!
        let query = "name = '\(escape(Self.catalogFilename))' and '\(folderId)' in parents and trashed = false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,modifiedTime,size)"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            if c == "\\" || c == "'" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    static func parseFileList(_ data: Data) throws -> DriveCatalogRef? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]],
              let first = files.first,
              let id = first["id"] as? String else {
            return nil
        }
        let size: Int64
        if let raw = first["size"] as? String, let parsed = Int64(raw) {
            size = parsed
        } else if let intVal = first["size"] as? Int {
            size = Int64(intVal)
        } else {
            size = 0
        }
        let modified: Date?
        if let raw = first["modifiedTime"] as? String {
            modified = ISO8601DateFormatter().date(from: raw)
        } else {
            modified = nil
        }
        return DriveCatalogRef(driveFileId: id, sizeBytes: size, modifiedTime: modified)
    }

    // MARK: - Upload internals

    private func createFile(parentId: String, bytes: Data) async throws -> String {
        let boundary = "dimroom-catalog-\(UUID().uuidString)"
        let endpoint = Self.uploadEndpoint(multipart: true, fileId: nil)
        let metadata: [String: Any] = [
            "name": Self.catalogFilename,
            "parents": [parentId],
            "mimeType": Self.catalogMimeType,
        ]
        let request = try Self.multipartRequest(
            url: endpoint,
            method: "POST",
            metadata: metadata,
            body: bytes,
            boundary: boundary
        )
        return try await performUpload(request: request)
    }

    private func updateExistingFile(fileId: String, bytes: Data) async throws -> String {
        let boundary = "dimroom-catalog-\(UUID().uuidString)"
        let endpoint = Self.uploadEndpoint(multipart: true, fileId: fileId)
        // On update we don't re-send `parents` (it's owned by the file
        // and Drive rejects parent changes via this endpoint). Only
        // metadata fields the client may legitimately tweak are sent.
        let metadata: [String: Any] = [
            "mimeType": Self.catalogMimeType,
        ]
        let request = try Self.multipartRequest(
            url: endpoint,
            method: "PATCH",
            metadata: metadata,
            body: bytes,
            boundary: boundary
        )
        return try await performUpload(request: request)
    }

    private func performUpload(request: URLRequest) async throws -> String {
        let (data, response) = try await sendWithCatalogRetry(request: request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncEngineError.uploadFailed(
                underlying: "upload failed status=\(response.statusCode) body=\(body)"
            )
        }
        guard let id = Self.parseUploadResponseId(data) else {
            throw SyncEngineError.uploadFailed(
                underlying: "missing id in upload response"
            )
        }
        return id
    }

    static func parseUploadResponseId(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? String
    }

    static func multipartRequest(
        url: URL,
        method: String,
        metadata: [String: Any],
        body: Data,
        boundary: String
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "multipart/related; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        )

        var requestBody = Data()
        appendString(&requestBody, "--\(boundary)\r\n")
        appendString(&requestBody, "Content-Type: application/json; charset=UTF-8\r\n\r\n")
        requestBody.append(metadataData)
        appendString(&requestBody, "\r\n--\(boundary)\r\n")
        appendString(&requestBody, "Content-Type: \(catalogMimeType)\r\n\r\n")
        requestBody.append(body)
        appendString(&requestBody, "\r\n--\(boundary)--\r\n")

        request.httpBody = requestBody
        return request
    }

    private static func appendString(_ data: inout Data, _ string: String) {
        if let bytes = string.data(using: .utf8) {
            data.append(bytes)
        }
    }

    // MARK: - Retry loop

    /// Drive-aware retry loop. Built on `classifyDriveResponse` and
    /// `isTransient(urlError:)` from DriveClient so catalog publishes
    /// inherit the same backoff behaviour as asset uploads without
    /// reaching into the DriveClient internals.
    private func sendWithCatalogRetry(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let isLast = attempt >= retryPolicy.maxAttempts
            do {
                let (data, response) = try await session.data(for: request)
                let decision = classifyDriveResponse(status: response.statusCode, body: data)
                switch decision {
                case .success, .fatal:
                    return (data, response)
                case .retry:
                    if isLast {
                        throw SyncEngineError.uploadFailed(
                            underlying: "retry budget exhausted at status=\(response.statusCode)"
                        )
                    }
                }
            } catch let urlError as URLError {
                if !isTransient(urlError: urlError) || isLast {
                    throw SyncEngineError.uploadFailed(
                        underlying: "network error: \(urlError.localizedDescription)"
                    )
                }
            } catch {
                throw error
            }
            let delay = retryPolicy.delay(forAttempt: attempt)
            try? await clock.sleep(for: delay)
        }
    }
}
