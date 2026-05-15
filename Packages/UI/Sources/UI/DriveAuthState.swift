import DriveClient
import Foundation

/// Narrow protocol over `DriveClient` so `DriveAuthState` can be tested
/// without spinning up an OAuth server or hitting the Keychain.
public protocol DriveAuthenticating: Sendable {
    var isAuthenticated: Bool { get async }
    var authFailures: AsyncStream<Void> { get }
    func authenticate() async throws
    func deauthenticate() async throws
    func fetchAccountEmail() async throws -> String?
}

extension DriveClient: DriveAuthenticating {
    /// Bridges `DriveClient.authenticate(options:)` (which has a default
    /// argument) to the protocol's no-arg requirement so `DriveClient`
    /// itself can be passed to `DriveAuthState`.
    public func authenticate() async throws {
        try await authenticate(options: AuthenticateOptions())
    }
}

/// View-model state for the Drive connection. The bug fix (#166) is that
/// before this existed, `DriveClient.authenticate()` succeeded but no
/// observable surface reflected it back to the menu, so the UI was stuck
/// reading "Connect Google Drive…" even when a refresh token was sitting
/// in the Keychain. This type wraps the client, publishes a `Status`,
/// and is hydrated from the stored refresh token at launch.
@MainActor
public final class DriveAuthState: ObservableObject {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected(email: String?)
    }

    @Published public private(set) var status: Status = .disconnected
    @Published public private(set) var lastErrorMessage: String?
    /// Set when an authorized DriveClient request has surfaced
    /// `DriveClientError.refreshFailed` — typically a stale or revoked
    /// refresh token. The AppDelegate observes this and shows a one-shot
    /// re-auth alert. Cleared on successful `connect()` and on `disconnect()`
    /// so the next failure can re-fire the alert.
    @Published public private(set) var needsReauthMessage: String?

    private var client: any DriveAuthenticating
    private var failureObserverTask: Task<Void, Never>?

    public init(client: any DriveAuthenticating) {
        self.client = client
        startObservingFailures()
    }

    deinit {
        failureObserverTask?.cancel()
    }

    /// Swaps the underlying authenticator. The App target uses this to
    /// hand off from a stub to the real `DriveClient` once OAuth config
    /// has been resolved without invalidating the published reference
    /// that the SwiftUI command builder is already observing.
    public func configure(client: any DriveAuthenticating) {
        self.client = client
        startObservingFailures()
    }

    private func startObservingFailures() {
        failureObserverTask?.cancel()
        let stream = client.authFailures
        // Task created inside a `@MainActor`-isolated method inherits
        // that isolation, so `handleAuthFailure()` runs on MainActor
        // without needing an explicit await.
        failureObserverTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.handleAuthFailure()
            }
        }
    }

    private func handleAuthFailure() {
        // Only react when the UI thinks we're connected/connecting.
        // A failure that arrives while already disconnected (e.g. a
        // stale in-flight request) shouldn't churn the published
        // message and re-fire the alert.
        switch status {
        case .connected, .connecting:
            status = .disconnected
            needsReauthMessage = "Google Drive needs to be reconnected. Your session has expired."
        case .disconnected:
            break
        }
    }

    /// Test hook: lets the harness inject the same transition the stream
    /// observer would, without requiring a real revoked-token round-trip.
    public func simulateAuthFailureForTesting() {
        handleAuthFailure()
    }

    /// Acknowledges a re-auth message after the AppDelegate has shown it,
    /// so a subsequent failure can re-trigger.
    public func clearNeedsReauthMessage() {
        needsReauthMessage = nil
    }

    /// Initialise the published status from whatever's already in the
    /// token store. Called from `applicationDidFinishLaunching` so the
    /// menu reflects an existing refresh token without re-prompting.
    /// The email fetch runs as a follow-up task so a slow/failing
    /// `/about` call doesn't block the UI from flipping to connected.
    public func hydrate() async {
        let authenticated = await client.isAuthenticated
        guard authenticated else {
            status = .disconnected
            return
        }
        status = .connected(email: nil)
        await refreshEmail()
    }

    public func connect() async {
        // Disallow concurrent connect attempts. Two `.connecting` states
        // racing the same OAuth server would each spin up a redirect
        // listener and fight over the port.
        if case .connecting = status { return }
        let previous = status
        status = .connecting
        lastErrorMessage = nil
        do {
            try await client.authenticate()
            status = .connected(email: nil)
            needsReauthMessage = nil
            await refreshEmail()
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            status = previous
        }
    }

    public func disconnect() async {
        do {
            try await client.deauthenticate()
        } catch {
            // Deauthenticate failures (Keychain quirks, etc.) shouldn't
            // strand the UI in "connected" — clearing the published
            // status is the safer default and matches what the user
            // expects from clicking Disconnect.
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
        status = .disconnected
        needsReauthMessage = nil
    }

    private func refreshEmail() async {
        do {
            let email = try await client.fetchAccountEmail()
            // Only update if we're still in `.connected`. A `disconnect`
            // racing the fetch would otherwise resurrect a stale state.
            if case .connected = status {
                status = .connected(email: email)
            }
        } catch {
            // Best-effort. The connected state stays valid without the
            // email; a subsequent hydrate or connect will retry.
        }
    }
}

public extension DriveAuthState.Status {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var email: String? {
        if case .connected(let email) = self { return email }
        return nil
    }
}
