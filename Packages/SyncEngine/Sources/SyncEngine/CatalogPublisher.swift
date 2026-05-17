import Catalog
import Foundation

/// Background catalog publisher. Wires `CatalogDatabase.onChange` into a
/// debouncer that takes a `VACUUM INTO` snapshot of the live catalog and
/// uploads it to Drive after 30 seconds of quiet (configurable). A
/// max-wait ceiling (default 5 minutes) guarantees forward progress
/// during continuous edits.
///
/// Each successful publish caches the returned Drive file id in
/// `fileIdStore` so subsequent publishes PATCH the same file rather
/// than `files.list`-ing the catalog folder every time.
public actor CatalogPublisher {
    private let catalog: CatalogDatabase
    private let uploader: any CatalogUploading
    private let fileIdStore: any DriveFileIdStore
    private let snapshotDirectory: URL
    private var debounceInterval: Duration
    private let maxDebounceInterval: Duration
    private let clock: any Clock<Duration>

    private var debouncer: Debouncer?
    private var isStarted = false
    private var isEnabled = true

    public init(
        catalog: CatalogDatabase,
        uploader: any CatalogUploading,
        fileIdStore: any DriveFileIdStore,
        snapshotDirectory: URL = FileManager.default.temporaryDirectory,
        debounceInterval: Duration = .seconds(30),
        maxDebounceInterval: Duration = .seconds(300),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.catalog = catalog
        self.uploader = uploader
        self.fileIdStore = fileIdStore
        self.snapshotDirectory = snapshotDirectory
        self.debounceInterval = debounceInterval
        self.maxDebounceInterval = maxDebounceInterval
        self.clock = clock
    }

    /// Lazily constructs the debouncer. Idempotent — calling twice is a
    /// no-op so `AppDelegate` can call it without checking state.
    public func start() async {
        if isStarted { return }
        let debouncer = Debouncer(
            interval: debounceInterval,
            maxInterval: maxDebounceInterval,
            clock: clock,
            fire: { [weak self] in
                await self?.runDebouncedPublish()
            }
        )
        self.debouncer = debouncer
        isStarted = true
    }

    /// Cancel any pending publish and stop accepting new triggers.
    public func stop() async {
        await debouncer?.cancel()
        debouncer = nil
        isStarted = false
    }

    /// Bridge for `CatalogDatabase.onChange`. Non-isolated so the
    /// catalog can call it synchronously from its write queue. Spawns
    /// a detached task to forward into the actor.
    public nonisolated func scheduleDebouncedPublish() {
        Task { [weak self] in
            await self?.triggerOnActor()
        }
    }

    /// Enable or disable scheduled publishes. Disabling cancels any
    /// in-flight debounce immediately. Re-enabling does not re-arm a
    /// previously dropped trigger — the next catalog mutation does.
    /// Used by the Settings UI to mirror the "auto-publish catalog"
    /// toggle into the live publisher.
    public func setEnabled(_ enabled: Bool) async {
        if enabled == isEnabled { return }
        isEnabled = enabled
        if !enabled {
            await debouncer?.cancel()
        }
    }

    /// Rebuild the debouncer with a new quiet-window interval. Cancels
    /// any pending publish so the new interval applies cleanly to the
    /// next trigger.
    public func setDebounceInterval(_ interval: Duration) async {
        guard interval != debounceInterval else { return }
        debounceInterval = interval
        if isStarted {
            await debouncer?.cancel()
            debouncer = Debouncer(
                interval: debounceInterval,
                maxInterval: maxDebounceInterval,
                clock: clock,
                fire: { [weak self] in
                    await self?.runDebouncedPublish()
                }
            )
        }
    }

    /// Force an immediate publish, bypassing debounce. Used by the
    /// harness command. Returns the publish outcome on success.
    @discardableResult
    public func publishNow() async throws -> PublishOutcome {
        await debouncer?.cancel()
        return try await runPublish()
    }

    // MARK: - Internals

    private func triggerOnActor() async {
        guard isEnabled, let debouncer else { return }
        await debouncer.scheduleTrigger()
    }

    private func runDebouncedPublish() async {
        do {
            _ = try await runPublish()
        } catch {
            // Debounced publishes never throw to the caller. Log and
            // move on — the next mutation will re-arm the debouncer.
            print("[CatalogPublisher] debounced publish failed: \(error)")
        }
    }

    private func runPublish() async throws -> PublishOutcome {
        let snapshotURL = snapshotDirectory.appendingPathComponent(
            "dimroom-catalog-snapshot-\(UUID().uuidString).sqlite"
        )

        let started = ContinuousClock.now
        do {
            try catalog.snapshot(to: snapshotURL.path)
        } catch {
            throw SyncEngineError.snapshotFailed(underlying: String(describing: error))
        }
        defer {
            try? FileManager.default.removeItem(at: snapshotURL)
        }

        let cachedId: String?
        do {
            cachedId = try fileIdStore.load()
        } catch {
            throw SyncEngineError.fileIdStoreFailed(underlying: String(describing: error))
        }

        let result: CatalogUploadResult
        do {
            result = try await uploader.upload(
                snapshotPath: snapshotURL.path,
                existingFileId: cachedId
            )
        } catch let error as SyncEngineError {
            throw error
        } catch {
            throw SyncEngineError.uploadFailed(underlying: String(describing: error))
        }

        do {
            try fileIdStore.save(result.driveFileId)
        } catch {
            throw SyncEngineError.fileIdStoreFailed(underlying: String(describing: error))
        }

        let elapsed = ContinuousClock.now - started
        return PublishOutcome(
            driveFileId: result.driveFileId,
            uploadedBytes: result.uploadedBytes,
            duration: elapsed,
            wasCreate: result.wasCreate
        )
    }
}
