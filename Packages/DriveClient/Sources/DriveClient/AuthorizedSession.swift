import Foundation

public protocol AccessTokenProvider: Sendable {
    func currentAccessToken() async throws -> String
    func forceRefreshAccessToken() async throws -> String
}

public struct AuthorizedSession: Sendable {
    private let client: HTTPClient
    private let streamingClient: StreamingHTTPClient
    private let provider: AccessTokenProvider

    public init(
        client: HTTPClient,
        streamingClient: StreamingHTTPClient = URLSessionStreamingHTTPClient(),
        provider: AccessTokenProvider
    ) {
        self.client = client
        self.streamingClient = streamingClient
        self.provider = provider
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var authed = request
        let token = try await provider.currentAccessToken()
        authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: authed)
        guard response.statusCode == 401 else {
            return (data, response)
        }
        let refreshed: String
        do {
            refreshed = try await provider.forceRefreshAccessToken()
        } catch {
            throw DriveClientError.refreshFailed
        }
        var retry = request
        retry.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
        return try await client.data(for: retry)
    }

    /// Streams `request` to `destinationURL`, layering bearer-auth and
    /// 401-refresh-retry on top of the streaming client. Writes go to a
    /// sibling temp path so a failed attempt cannot leave a half-written file
    /// at the destination; on success the temp is atomically moved into place.
    public func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tempURL = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)"
        )

        // Any exit that doesn't move the temp into place must not leave the
        // `.partial-<uuid>` file behind: a non-2xx terminal status, a
        // mid-stream throw from the streaming client, or a cancellation. The
        // 401-retry path below still removes `tempURL` eagerly because it
        // reuses the same path before this defer can fire.
        var movedIntoPlace = false
        defer {
            if !movedIntoPlace {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let attempt: @Sendable (String) async throws -> HTTPURLResponse = { token in
            var authed = request
            authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await streamingClient.download(for: authed, to: tempURL, progress: progress)
        }

        let token = try await provider.currentAccessToken()
        var response = try await attempt(token)
        if response.statusCode == 401 {
            try? FileManager.default.removeItem(at: tempURL)
            let refreshed: String
            do {
                refreshed = try await provider.forceRefreshAccessToken()
            } catch {
                throw DriveClientError.refreshFailed
            }
            response = try await attempt(refreshed)
        }

        guard (200..<300).contains(response.statusCode) else {
            return response
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        movedIntoPlace = true
        return response
    }
}
