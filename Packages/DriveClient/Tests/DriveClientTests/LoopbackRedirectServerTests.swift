import XCTest
@testable import DriveClient

final class LoopbackRedirectServerTests: XCTestCase {
    func testCapturesCodeFromRealHTTPGet() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()

        async let redirect = server.waitForRedirect()

        let url = URL(string: "http://127.0.0.1:\(port)/?code=abc123&state=xyz")!
        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let captured = try await redirect
        XCTAssertEqual(captured.code, "abc123")
        XCTAssertEqual(captured.state, "xyz")
        await server.stop()
    }

    func testMissingCodeReturns400AndThrows() async throws {
        let server = LoopbackRedirectServer()
        let port = try await server.start()

        async let redirect = server.waitForRedirect()

        let url = URL(string: "http://127.0.0.1:\(port)/?error=access_denied")!
        let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        do {
            _ = try await redirect
            XCTFail("expected failure")
        } catch let DriveClientError.authorizationDenied(reason) {
            XCTAssertEqual(reason, "access_denied")
        }
        await server.stop()
    }

    func testParseQuery() {
        let q = LoopbackRedirectServer.parseQuery(from: "/?code=abc%20def&state=xyz")
        XCTAssertEqual(q["code"], "abc def")
        XCTAssertEqual(q["state"], "xyz")
    }
}
