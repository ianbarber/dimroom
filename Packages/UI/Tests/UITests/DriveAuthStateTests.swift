import XCTest
@testable import UI

@MainActor
final class DriveAuthStateTests: XCTestCase {

    func testHydrateConnectsWhenClientAuthenticated() async {
        let stub = StubDriveAuth(initialAuthenticated: true, email: "user@example.com")
        let state = DriveAuthState(client: stub)

        await state.hydrate()

        XCTAssertEqual(state.status, .connected(email: "user@example.com"))
    }

    func testHydrateStaysDisconnectedWhenNoToken() async {
        let stub = StubDriveAuth(initialAuthenticated: false, email: nil)
        let state = DriveAuthState(client: stub)

        await state.hydrate()

        XCTAssertEqual(state.status, .disconnected)
    }

    func testConnectSuccessTransitionsThroughConnecting() async {
        let stub = StubDriveAuth(initialAuthenticated: false, email: "user@example.com")
        let state = DriveAuthState(client: stub)
        let observer = StatusObserver()
        let cancellable = state.$status.sink { observer.record($0) }
        defer { cancellable.cancel() }

        await state.connect()

        XCTAssertEqual(state.status, .connected(email: "user@example.com"))
        XCTAssertTrue(observer.statuses.contains(.connecting),
                      "expected an intermediate .connecting state, got \(observer.statuses)")
        XCTAssertEqual(observer.statuses.last, .connected(email: "user@example.com"))
    }

    func testConnectFailureRevertsToDisconnected() async {
        let stub = StubDriveAuth(initialAuthenticated: false, email: nil)
        stub.authenticateError = StubError.boom
        let state = DriveAuthState(client: stub)

        await state.connect()

        XCTAssertEqual(state.status, .disconnected)
        XCTAssertNotNil(state.lastErrorMessage)
    }

    func testDisconnectClearsConnectedState() async {
        let stub = StubDriveAuth(initialAuthenticated: true, email: "user@example.com")
        let state = DriveAuthState(client: stub)
        await state.hydrate()
        XCTAssertEqual(state.status, .connected(email: "user@example.com"))

        await state.disconnect()

        XCTAssertEqual(state.status, .disconnected)
        XCTAssertTrue(stub.deauthenticateCalled)
    }

    func testConcurrentConnectCallsAreIgnoredWhileConnecting() async {
        let stub = StubDriveAuth(initialAuthenticated: false, email: nil)
        stub.authenticateHook = { @Sendable in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = DriveAuthState(client: stub)

        async let a: () = state.connect()
        // Give the first call a moment to flip to `.connecting`. Without
        // this, both calls hit the guard before either has mutated state.
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let b: () = state.connect()
        _ = await (a, b)

        XCTAssertEqual(stub.authenticateCount, 1,
                       "second connect() while connecting should be a no-op")
    }

    func testHydrateConnectsEvenWhenEmailFetchFails() async {
        let stub = StubDriveAuth(initialAuthenticated: true, email: nil)
        stub.fetchEmailError = StubError.boom
        let state = DriveAuthState(client: stub)

        await state.hydrate()

        XCTAssertEqual(state.status, .connected(email: nil))
    }
}

// MARK: - Helpers

private enum StubError: Error { case boom }

private final class StubDriveAuth: DriveAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _authenticated: Bool
    private var _email: String?
    var authenticateError: Error?
    var fetchEmailError: Error?
    var authenticateHook: (@Sendable () async -> Void)?
    private(set) var authenticateCount = 0
    private(set) var deauthenticateCalled = false

    init(initialAuthenticated: Bool, email: String?) {
        self._authenticated = initialAuthenticated
        self._email = email
    }

    var isAuthenticated: Bool {
        get async {
            lock.lock(); defer { lock.unlock() }
            return _authenticated
        }
    }

    func authenticate() async throws {
        let hook = lock.withLock { () -> (@Sendable () async -> Void)? in
            authenticateCount += 1
            return authenticateHook
        }
        await hook?()
        if let error = authenticateError { throw error }
        lock.withLock { _authenticated = true }
    }

    func deauthenticate() async throws {
        lock.withLock {
            deauthenticateCalled = true
            _authenticated = false
        }
    }

    func fetchAccountEmail() async throws -> String? {
        if let error = fetchEmailError { throw error }
        return lock.withLock { _email }
    }
}

@MainActor
private final class StatusObserver {
    private(set) var statuses: [DriveAuthState.Status] = []

    func record(_ status: DriveAuthState.Status) {
        statuses.append(status)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
