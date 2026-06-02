import DriveClient
import Foundation
import UI

/// Harness-only stub `DriveUploading` that records every call and returns
/// a deterministic synthetic Drive file ID. Used by the auto-upload
/// Layer C flow (#414): with the real `DriveUploader` not wired in
/// harness mode, the toggle-on path in `AutoUploadAfterImport` would
/// short-circuit at the `driveUploader == nil` guard, so we couldn't
/// prove the upload step actually runs.
///
/// Installed when the app sees `--stub-drive-uploader` on launch.
final class HarnessStubDriveUploader: DriveUploading {
    private let counter = AtomicCounter()

    func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome {
        // Pretend the file is small and finishes immediately; the
        // coordinator's progress sink doesn't care about specific values,
        // only that the call completes.
        progress(1, 1)
        let id = counter.next()
        return .uploaded(fileID: "stub-drive-file-\(id)-\(ref.contentHash.prefix(8))")
    }

    /// Tiny actor-equivalent so the @Sendable closure can produce stable
    /// monotonic IDs without needing a non-Sendable mutable counter.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// Stub authenticator paired with `HarnessStubDriveUploader`: reports
/// "authenticated" so `DriveAuthState.hydrate()` flips the menu to
/// `.connected`, lets the auto-upload guard see a connected state.
final class HarnessStubDriveAuth: DriveAuthenticating {
    var isAuthenticated: Bool { get async { true } }
    var authFailures: AsyncStream<Void> { AsyncStream { _ in } }
    func authenticate() async throws {}
    func deauthenticate() async throws {}
    func fetchAccountEmail() async throws -> String? { "harness@stub.local" }
}
