import XCTest
@testable import DriveClient

final class RetryPolicyTests: XCTestCase {

    func testDelayDoublesPerAttempt() {
        let policy = RetryPolicy(
            maxAttempts: 4,
            baseDelay: .milliseconds(500),
            maxDelay: .seconds(30)
        )
        XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(500))
        XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(1000))
        XCTAssertEqual(policy.delay(forAttempt: 3), .milliseconds(2000))
    }

    func testDelayCapsAtMaxDelay() {
        let policy = RetryPolicy(
            maxAttempts: 8,
            baseDelay: .seconds(1),
            maxDelay: .seconds(4)
        )
        XCTAssertEqual(policy.delay(forAttempt: 4), .seconds(4))
        XCTAssertEqual(policy.delay(forAttempt: 5), .seconds(4))
        XCTAssertEqual(policy.delay(forAttempt: 10), .seconds(4))
    }

    func testClassify5xxRetries() {
        XCTAssertEqual(classifyDriveResponse(status: 500, body: Data()), .retry)
        XCTAssertEqual(classifyDriveResponse(status: 503, body: Data()), .retry)
        XCTAssertEqual(classifyDriveResponse(status: 599, body: Data()), .retry)
    }

    func testClassify429Retries() {
        XCTAssertEqual(classifyDriveResponse(status: 429, body: Data()), .retry)
    }

    func testClassify2xxSucceeds() {
        XCTAssertEqual(classifyDriveResponse(status: 200, body: Data()), .success)
        XCTAssertEqual(classifyDriveResponse(status: 201, body: Data()), .success)
    }

    func testClassify404Fatal() {
        XCTAssertEqual(classifyDriveResponse(status: 404, body: Data()), .fatal)
    }

    func testClassify403QuotaBodyRetries() {
        let body = Data(#"""
        {"error":{"errors":[{"domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
        """#.utf8)
        XCTAssertEqual(classifyDriveResponse(status: 403, body: body), .retry)
    }

    func testClassify403NonQuotaFatal() {
        let body = Data(#"""
        {"error":{"errors":[{"domain":"global","reason":"forbidden"}]}}
        """#.utf8)
        XCTAssertEqual(classifyDriveResponse(status: 403, body: body), .fatal)
    }

    func testClassify403RateLimitExceededRetries() {
        let body = Data(#"""
        {"error":{"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}
        """#.utf8)
        XCTAssertEqual(classifyDriveResponse(status: 403, body: body), .retry)
    }

    func testIsTransientRecognisesCommonNetworkErrors() {
        XCTAssertTrue(isTransient(urlError: URLError(.timedOut)))
        XCTAssertTrue(isTransient(urlError: URLError(.networkConnectionLost)))
        XCTAssertTrue(isTransient(urlError: URLError(.notConnectedToInternet)))
        XCTAssertFalse(isTransient(urlError: URLError(.badURL)))
        XCTAssertFalse(isTransient(urlError: URLError(.cannotParseResponse)))
    }
}
