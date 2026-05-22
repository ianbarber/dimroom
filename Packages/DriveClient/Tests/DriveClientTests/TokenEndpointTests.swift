import XCTest
@testable import DriveClient
import DriveTestSupport

final class TokenEndpointTests: XCTestCase {
    private let config = OAuthConfig(clientID: "test-client", scope: "drive")

    func testExchangeBuildsFormBody() async throws {
        let payload = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"token_type":"Bearer"}"#
        let client = StubHTTPClient(response: .success(200, Data(payload.utf8)))

        let response = try await TokenEndpoint.exchange(
            code: "CODE",
            verifier: "VER",
            redirectURI: "http://127.0.0.1:1234/",
            config: config,
            client: client
        )

        XCTAssertEqual(response.access_token, "at")
        XCTAssertEqual(response.refresh_token, "rt")
        XCTAssertEqual(response.expires_in, 3600)

        let request = try XCTUnwrap(client.captured.first)
        XCTAssertEqual(request.url, config.tokenEndpoint)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")

        let bodyString = String(data: try XCTUnwrap(request.body), encoding: .utf8) ?? ""
        let fields = parseForm(bodyString)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["client_id"], "test-client")
        XCTAssertEqual(fields["code"], "CODE")
        XCTAssertEqual(fields["code_verifier"], "VER")
        XCTAssertEqual(fields["redirect_uri"], "http://127.0.0.1:1234/")
        XCTAssertNil(fields["client_secret"])
    }

    func testExchangeIncludesClientSecretWhenPresent() async throws {
        let cfg = OAuthConfig(clientID: "test-client", clientSecret: "shh")
        let payload = #"{"access_token":"at"}"#
        let client = StubHTTPClient(response: .success(200, Data(payload.utf8)))

        _ = try await TokenEndpoint.exchange(
            code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1/",
            config: cfg, client: client
        )

        let body = String(data: try XCTUnwrap(client.captured.first?.body), encoding: .utf8) ?? ""
        XCTAssertEqual(parseForm(body)["client_secret"], "shh")
    }

    func testRefreshBuildsFormBody() async throws {
        let payload = #"{"access_token":"new-at","expires_in":3600}"#
        let client = StubHTTPClient(response: .success(200, Data(payload.utf8)))

        let response = try await TokenEndpoint.refresh(refreshToken: "RTOKEN", config: config, client: client)

        XCTAssertEqual(response.access_token, "new-at")
        let body = String(data: try XCTUnwrap(client.captured.first?.body), encoding: .utf8) ?? ""
        let fields = parseForm(body)
        XCTAssertEqual(fields["grant_type"], "refresh_token")
        XCTAssertEqual(fields["refresh_token"], "RTOKEN")
        XCTAssertEqual(fields["client_id"], "test-client")
    }

    func testErrorStatusMapsToTokenExchangeFailed() async {
        let client = StubHTTPClient(response: .success(400, Data(#"{"error":"invalid_grant"}"#.utf8)))
        do {
            _ = try await TokenEndpoint.exchange(
                code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1/",
                config: config, client: client
            )
            XCTFail("expected failure")
        } catch let DriveClientError.tokenExchangeFailed(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("invalid_grant"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPercentEncodingEncodesSpecialCharacters() {
        XCTAssertEqual(TokenEndpoint.percentEncode("a b+c"), "a%20b%2Bc")
        XCTAssertEqual(TokenEndpoint.percentEncode("A-Z_a.z~0"), "A-Z_a.z~0")
    }

    private func parseForm(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? "") : ""
            result[String(key)] = value
        }
        return result
    }
}
