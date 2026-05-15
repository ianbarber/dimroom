import DriveClient
import Foundation

/// Harness-only downloader that *holds* every `download(...)` call until
/// `release()` is invoked. Pairs with the
/// `DIMROOM_HARNESS_STUB_DOWNLOADER=hold-until-released` env arm and the
/// `Command.releaseHeldDownloads` harness verb so a Layer C flow can
/// drive a Drive-only asset into the in-flight state, stay there
/// indefinitely, and assert the *immediate* post-asset-switch state of
/// `DevelopViewModel.isDownloadingOriginal` (the regression #204 fixed).
/// Once released, the call writes a small synthetic payload identical in
/// shape to `SlowChunkHarnessDownloader`'s output so
/// `OriginalsCache.fetch` resolves to a real on-disk file.
///
/// Differs from `SlowChunkHarnessDownloader` in one important way: that
/// downloader paces a known duration (~1.5 s), which races the flow's
/// poll loop. This one cannot finish on its own, so the flow's
/// immediate-state assertions can't be confounded by a download that
/// happens to complete between the asset-switch command and the next
/// state poll.
struct HoldUntilReleasedHarnessDownloader: OriginalsDownloader {
    /// Process-wide coordinator. The downloader value is itself a thin
    /// adapter — the held continuations and the release entry point live
    /// on the shared coordinator so `HarnessController` can reach them
    /// without threading a reference through `OriginalsCache`.
    static let shared = HoldCoordinator()

    /// Synthetic payload size, matching `SlowChunkHarnessDownloader` so a
    /// flow toggling between the two stubs hits the same on-disk size
    /// budget.
    static let payloadByteCount = 2048

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        // Honour cancellation before parking — a task that's already
        // cancelled (e.g. cancelled by the time `OriginalsCache` reaches
        // the downloader on an A→B switch) should unwind without
        // registering a hold.
        try Task.checkCancellation()
        try await Self.shared.hold()
        try Task.checkCancellation()

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(repeating: 0, count: Self.payloadByteCount))
        progress?(1.0)
    }
}

/// Process-scoped registry of parked download calls. Released en masse
/// via `release()` from the `Command.releaseHeldDownloads` handler.
///
/// `@unchecked Sendable` because the underlying state is guarded by an
/// `NSLock`; the type intentionally avoids actor isolation so it can be
/// reached from inside the synchronous `OriginalsDownloader.download`
/// adapter (and from `HarnessController` on any task).
final class HoldCoordinator: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]

    /// Park the calling task until `release()` fires. A cancellation
    /// while parked unwinds via `withTaskCancellationHandler`, which
    /// drops the registration so a later `release()` is a no-op for
    /// this slot.
    func hold() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Re-check cancellation under the lock. If the task was
                // cancelled between `withTaskCancellationHandler`'s
                // initial check and reaching the registration, resume
                // immediately rather than parking a continuation that
                // would only be drained by `release()`.
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let entry = pending.removeValue(forKey: id)
            lock.unlock()
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Drain every currently-parked continuation. Safe to call when no
    /// downloads are pending (empty map → no-op). New holds registered
    /// after `release()` returns are *not* drained — the next
    /// `release()` will pick them up.
    func release() {
        lock.lock()
        let drained = pending
        pending.removeAll()
        lock.unlock()
        for entry in drained.values {
            entry.continuation.resume()
        }
    }

    /// Test-only inspection: number of currently-parked downloads.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}
