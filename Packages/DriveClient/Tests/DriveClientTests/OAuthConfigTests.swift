import XCTest
@testable import DriveClient

final class OAuthConfigTests: XCTestCase {
    func testEnvironmentWinsOverFile() throws {
        let fileURL = try writeConfigFile(["client_id": "from-file"])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let config = try OAuthConfig.load(
            environment: [OAuthConfig.environmentVariable: "from-env"],
            fileURL: fileURL
        )
        XCTAssertEqual(config.clientID, "from-env")
        XCTAssertNil(config.clientSecret)
    }

    func testEnvironmentSecretLoaded() throws {
        let config = try OAuthConfig.load(
            environment: [
                OAuthConfig.environmentVariable: "env-id",
                OAuthConfig.clientSecretEnvironmentVariable: "env-secret",
            ],
            fileURL: URL(fileURLWithPath: "/nonexistent/oauth.json")
        )
        XCTAssertEqual(config.clientID, "env-id")
        XCTAssertEqual(config.clientSecret, "env-secret")
    }

    func testFileFallbackParses() throws {
        let fileURL = try writeConfigFile([
            "client_id": "file-id",
            "client_secret": "file-secret",
        ])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let config = try OAuthConfig.load(environment: [:], fileURL: fileURL)
        XCTAssertEqual(config.clientID, "file-id")
        XCTAssertEqual(config.clientSecret, "file-secret")
    }

    func testMissingBothThrows() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        XCTAssertThrowsError(try OAuthConfig.load(environment: [:], fileURL: url)) { error in
            XCTAssertEqual(error as? DriveClientError, .clientIDNotConfigured)
        }
    }

    func testEmptyEnvironmentFallsBackToFile() throws {
        let fileURL = try writeConfigFile(["client_id": "from-file"])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let config = try OAuthConfig.load(
            environment: [OAuthConfig.environmentVariable: ""],
            fileURL: fileURL
        )
        XCTAssertEqual(config.clientID, "from-file")
    }

    private func writeConfigFile(_ payload: [String: String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oauth-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)
        return url
    }
}
