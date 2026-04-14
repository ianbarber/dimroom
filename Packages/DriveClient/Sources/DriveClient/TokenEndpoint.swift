import Foundation

public struct TokenResponse: Decodable, Equatable {
    public let access_token: String
    public let refresh_token: String?
    public let expires_in: Int?
    public let token_type: String?
    public let scope: String?
}

enum TokenEndpoint {
    static func exchange(
        code: String,
        verifier: String,
        redirectURI: String,
        config: OAuthConfig,
        client: HTTPClient
    ) async throws -> TokenResponse {
        var fields: [(String, String)] = [
            ("client_id", config.clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI),
        ]
        if let secret = config.clientSecret {
            fields.append(("client_secret", secret))
        }
        let request = makeRequest(url: config.tokenEndpoint, fields: fields)
        return try await send(request: request, client: client)
    }

    static func refresh(
        refreshToken: String,
        config: OAuthConfig,
        client: HTTPClient
    ) async throws -> TokenResponse {
        var fields: [(String, String)] = [
            ("client_id", config.clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]
        if let secret = config.clientSecret {
            fields.append(("client_secret", secret))
        }
        let request = makeRequest(url: config.tokenEndpoint, fields: fields)
        return try await send(request: request, client: client)
    }

    static func makeRequest(url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func send(request: URLRequest, client: HTTPClient) async throws -> TokenResponse {
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveClientError.tokenExchangeFailed(status: response.statusCode, body: body)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
