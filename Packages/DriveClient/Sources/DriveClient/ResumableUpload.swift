import Foundation

/// Drive v3 `uploadType=resumable` — two-phase:
///  1. POST metadata, receive a `Location` header pointing at a session URL
///  2. PUT the file bytes in chunks to that URL with `Content-Range`
///
/// Chunk size must be a multiple of 256 KB (except the final chunk).
/// Default is 8 MiB — a reasonable trade between memory pressure and
/// request overhead for 30–60 MB RAW files; callers can override.
///
/// The file is streamed via `FileHandle`, so we never buffer the whole
/// thing in memory regardless of size.
enum ResumableUpload {
    static let initiateEndpoint: URL = {
        var components = URLComponents(
            url: DriveFilesAPI.uploadEndpoint,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
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

    static func buildInitiateRequest(metadata: Metadata) throws -> URLRequest {
        var request = URLRequest(url: initiateEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(metadata.mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        let metadataJSON: [String: Any] = [
            "name": metadata.name,
            "parents": metadata.parents,
            "mimeType": metadata.mimeType,
            "appProperties": metadata.appProperties,
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: metadataJSON,
            options: [.sortedKeys]
        )
        return request
    }

    /// Builds the chunk PUT request. `rangeStart`/`rangeEnd` are inclusive;
    /// `total` is the overall file size.
    static func buildChunkRequest(
        sessionURL: URL,
        chunk: Data,
        rangeStart: Int64,
        rangeEnd: Int64,
        total: Int64,
        mimeType: String
    ) -> URLRequest {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(
            "bytes \(rangeStart)-\(rangeEnd)/\(total)",
            forHTTPHeaderField: "Content-Range"
        )
        request.httpBody = chunk
        return request
    }

    /// Parses the `Range: bytes=0-N` header the server returns on a 308
    /// response. The ack points at the last byte the server has; the
    /// next chunk starts at `N + 1`. Returns `nil` when the header is
    /// missing (server has none of the bytes yet).
    static func parseRangeAck(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let body = trimmed.dropFirst("bytes=".count)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        let endStr = body[body.index(after: dash)...]
        return Int64(endStr)
    }

    /// Executes a resumable upload. The progress callback fires after
    /// each acknowledged chunk with `(uploaded, total)`.
    static func upload(
        metadata: Metadata,
        fileURL: URL,
        totalBytes: Int64,
        session: AuthorizedSession,
        retryPolicy: RetryPolicy,
        clock: any Clock<Duration>,
        chunkSize: Int,
        progress: @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        // Phase 1: initiate the session.
        let initiateRequest = try buildInitiateRequest(metadata: metadata)
        let initiateResult = try await sendWithRetry(
            request: initiateRequest,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        guard (200..<300).contains(initiateResult.response.statusCode) else {
            let body = String(data: initiateResult.data, encoding: .utf8) ?? ""
            throw DriveUploadError.uploadFailed(
                status: initiateResult.response.statusCode,
                body: body
            )
        }
        guard let locationHeader = initiateResult.response.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: locationHeader) else {
            throw DriveUploadError.invalidServerResponse("missing Location header on resumable initiate")
        }

        // Phase 2: chunked PUTs, resuming from any ack the server gives us.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var nextByte: Int64 = 0
        while nextByte < totalBytes {
            try handle.seek(toOffset: UInt64(nextByte))
            let remaining = totalBytes - nextByte
            let thisChunkSize = Int(min(Int64(chunkSize), remaining))
            guard let chunk = try handle.read(upToCount: thisChunkSize),
                  chunk.count == thisChunkSize else {
                throw DriveUploadError.invalidServerResponse("short read from \(fileURL.path)")
            }
            let rangeEnd = nextByte + Int64(thisChunkSize) - 1
            let request = buildChunkRequest(
                sessionURL: sessionURL,
                chunk: chunk,
                rangeStart: nextByte,
                rangeEnd: rangeEnd,
                total: totalBytes,
                mimeType: metadata.mimeType
            )

            let (data, response) = try await session.data(for: request)
            let status = response.statusCode

            if (200..<300).contains(status) {
                // Server signals completion. Decode the file ID.
                let decoded = try JSONDecoder().decode(DriveFilesAPI.DriveFile.self, from: data)
                progress(totalBytes, totalBytes)
                return decoded.id
            }
            if status == 308 {
                // Partial ack — advance past the last acknowledged byte.
                if let ack = parseRangeAck(response.value(forHTTPHeaderField: "Range")) {
                    nextByte = ack + 1
                }
                // No Range header → server has nothing yet; leave nextByte
                // where it is so we retry the same chunk.
                progress(nextByte, totalBytes)
                continue
            }
            if status >= 500 || status == 429 {
                // Transient — back off and retry this chunk.
                try? await clock.sleep(for: retryPolicy.delay(forAttempt: 1))
                continue
            }
            if status == 404 || status == 410 {
                // Session expired; caller needs to restart.
                throw DriveUploadError.resumableSessionLost
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveUploadError.uploadFailed(status: status, body: body)
        }
        throw DriveUploadError.invalidServerResponse("resumable upload completed without server 2xx")
    }
}
