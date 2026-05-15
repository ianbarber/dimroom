import XCTest
@testable import DriveClient

/// Covers the `authFailures` stream on `DriveClient` — the signal that
/// `DriveAuthState` subscribes to so a stale or revoked refresh token can
/// flip the UI back to `.disconnected`. See issue #195.
final class RefreshFailureStreamTests: XCTestCase {

    func testRefreshFailureYieldsToStream() async throws {
        struct BoomError: Error {}
        let http = StubHTTPClient(response: .error(BoomError()))
        let store = InMemoryTokenStore(initial: "stale-rt")
        let client = makeClient(http: http, store: store)

        let counter = StreamCounter(stream: client.authFailures)

        do {
            _ = try await client.refreshAccessToken()
            XCTFail("expected refreshFailed")
        } catch DriveClientError.refreshFailed {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }

        // Yield the cooperative runtime a few times so the AsyncStream
        // observer task can drain the buffered event before we read.
        for _ in 0..<20 {
            await Task.yield()
        }

        let count = await counter.count
        XCTAssertEqual(count, 1, "refreshFailed must yield exactly one event")
    }

    func testNotAuthenticatedDoesNotYield() async {
        // `notAuthenticated` is thrown before the token endpoint is even
        // contacted — there is no refresh round-trip to fail, so the
        // failure stream must stay silent.
        let client = makeClient(http: StubHTTPClient(responses: []), store: InMemoryTokenStore())
        let counter = StreamCounter(stream: client.authFailures)

        do {
            _ = try await client.refreshAccessToken()
            XCTFail("expected notAuthenticated")
        } catch DriveClientError.notAuthenticated {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }

        for _ in 0..<20 {
            await Task.yield()
        }

        let count = await counter.count
        XCTAssertEqual(count, 0, "notAuthenticated must not yield to authFailures")
    }

    func testSuccessfulRefreshDoesNotYield() async throws {
        let tokenJSON = #"{"access_token":"at-1","expires_in":3600}"#
        let http = StubHTTPClient(response: .success(200, Data(tokenJSON.utf8)))
        let store = InMemoryTokenStore(initial: "rt-1")
        let client = makeClient(http: http, store: store)
        let counter = StreamCounter(stream: client.authFailures)

        _ = try await client.refreshAccessToken()

        for _ in 0..<20 {
            await Task.yield()
        }

        let count = await counter.count
        XCTAssertEqual(count, 0, "happy-path refresh must not yield to authFailures")
    }

    // MARK: - helpers

    private func makeClient(
        http: HTTPClient,
        store: TokenStore
    ) -> DriveClient {
        DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: store,
            browserLauncher: RecordingBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() },
            verifierProvider: { "v" },
            stateProvider: { "s" }
        )
    }
}

/// Drains an `AsyncStream<Void>` into a counter in the background and
/// exposes the running total. Lets tests observe whether `yield()` fired
/// without racing against the actor that produced it.
private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var task: Task<Void, Never>!

    init(stream: AsyncStream<Void>) {
        self.task = Task { [weak self] in
            for await _ in stream {
                self?.increment()
            }
        }
    }

    deinit { task.cancel() }

    private func increment() {
        lock.lock(); defer { lock.unlock() }
        _count += 1
    }

    var count: Int {
        get async {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
    }
}
