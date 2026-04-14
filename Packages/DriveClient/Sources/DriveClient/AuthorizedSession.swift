import Foundation

public protocol AccessTokenProvider: Sendable {
    func currentAccessToken() async throws -> String
    func forceRefreshAccessToken() async throws -> String
}

public struct AuthorizedSession: Sendable {
    private let client: HTTPClient
    private let provider: AccessTokenProvider

    public init(client: HTTPClient, provider: AccessTokenProvider) {
        self.client = client
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
}
