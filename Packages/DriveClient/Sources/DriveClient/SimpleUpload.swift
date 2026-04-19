import Foundation

/// Drive v3 `uploadType=multipart` — a single POST with a boundary-encoded
/// body carrying JSON metadata and the raw file bytes. Used for assets
/// under the simple/resumable threshold (default 5 MiB): one network
/// round-trip, no session management.
enum SimpleUpload {
    static let endpoint: URL = {
        var components = URLComponents(
            url: DriveFilesAPI.uploadEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id"),
        ]
        return components.url!
    }()

    struct Metadata {
        let name: String
        let parents: [String]
        let mimeType: String
        let appProperties: [String: String]
    }

    static func buildRequest(
        metadata: Metadata,
        fileData: Data,
        boundary: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/related; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let metadataJSON: [String: Any] = [
            "name": metadata.name,
            "parents": metadata.parents,
            "mimeType": metadata.mimeType,
            "appProperties": metadata.appProperties,
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadataJSON,
            options: [.sortedKeys]
        )

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Type: \(metadata.mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    /// Executes a simple upload. `clockSource` is injectable so tests can
    /// use `ImmediateClock`-style shims to avoid real sleeps.
    static func upload(
        metadata: Metadata,
        fileURL: URL,
        session: AuthorizedSession,
        retryPolicy: RetryPolicy,
        clock: any Clock<Duration>,
        boundary: String = Self.randomBoundary(),
        progress: @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        let fileData = try Data(contentsOf: fileURL)
        let request = try buildRequest(
            metadata: metadata,
            fileData: fileData,
            boundary: boundary
        )
        let result = try await sendWithRetry(
            request: request,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        guard (200..<300).contains(result.response.statusCode) else {
            let body = String(data: result.data, encoding: .utf8) ?? ""
            throw DriveUploadError.uploadFailed(status: result.response.statusCode, body: body)
        }
        let decoded = try JSONDecoder().decode(DriveFilesAPI.DriveFile.self, from: result.data)
        let totalBytes = Int64(fileData.count)
        progress(totalBytes, totalBytes)
        return decoded.id
    }

    static func randomBoundary() -> String {
        "dimroom-" + UUID().uuidString
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
