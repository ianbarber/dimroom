import Catalog
import Foundation

/// Polls Drive's `changes` endpoint for updates since the last sync,
/// classifies the result, and emits a `DeltaSyncOutcome` per poll. Owns
/// the page-token state machine; persists the token in `sync_state` via
/// the catalog so it round-trips across machines together with the rest
/// of the data.
///
/// Polling cadence is driven by `start()` — a 5-minute Task.sleep loop
/// scoped to the foreground lifecycle. The harness `syncFromDrive`
/// command calls `pollOnce()` directly, so Layer C tests don't have to
/// wait for the periodic tick.
public actor ChangePoller {
    private let catalog: CatalogDatabase
    private let fetcher: any DriveChangesFetching
    private let publisher: CatalogPublisher?
    private let fileIdStore: any DriveFileIdStore
    private let pollInterval: Duration
    private let clock: any Clock<Duration>

    private var loopTask: Task<Void, Never>?

    /// Async stream of poll outcomes for the AppDelegate to subscribe
    /// to. Created lazily on first `events()` call.
    private var continuation: AsyncStream<DeltaSyncOutcome>.Continuation?

    public init(
        catalog: CatalogDatabase,
        fetcher: any DriveChangesFetching,
        publisher: CatalogPublisher?,
        fileIdStore: any DriveFileIdStore,
        pollInterval: Duration = .seconds(300),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.catalog = catalog
        self.fetcher = fetcher
        self.publisher = publisher
        self.fileIdStore = fileIdStore
        self.pollInterval = pollInterval
        self.clock = clock
    }

    /// Subscribe to poll outcomes. Single-subscriber: the AppDelegate
    /// binds exactly one UI handler. Subscribe before `start()` if you
    /// need to observe the bootstrap tick — the periodic loop drops
    /// values until a subscriber exists.
    public func events() -> AsyncStream<DeltaSyncOutcome> {
        if continuation != nil {
            let (stream, finished) = AsyncStream<DeltaSyncOutcome>.makeStream()
            finished.finish()
            return stream
        }
        let (stream, continuation) = AsyncStream<DeltaSyncOutcome>.makeStream()
        self.continuation = continuation
        return stream
    }

    /// Begin the periodic poll loop. Idempotent.
    public func start() {
        if loopTask != nil { return }
        let interval = pollInterval
        let clock = self.clock
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.pollOnce()
                try? await clock.sleep(for: interval)
            }
        }
    }

    /// Cancel the periodic poll loop. Idempotent.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Run a single poll cycle. The harness command invokes this
    /// directly so Layer C tests can assert on outcomes without waiting
    /// for the next tick. Throws when Drive returns a non-transient
    /// failure or when persisting the new page token fails.
    @discardableResult
    public func pollOnce() async throws -> DeltaSyncOutcome {
        let storedToken: String?
        do {
            storedToken = try catalog.loadDrivePageToken()
        } catch {
            throw SyncEngineError.pageTokenStoreFailed(
                underlying: String(describing: error)
            )
        }

        guard let storedToken else {
            return try await bootstrap()
        }
        return try await runDelta(pageToken: storedToken)
    }

    // MARK: - Internals

    private func bootstrap() async throws -> DeltaSyncOutcome {
        let token = try await fetcher.startPageToken()
        try persistPageToken(token)
        let outcome = DeltaSyncOutcome.bootstrapped(pageToken: token)
        continuation?.yield(outcome)
        return outcome
    }

    private func runDelta(pageToken initialToken: String) async throws -> DeltaSyncOutcome {
        var pageToken = initialToken
        var newStartPageToken: String?
        var allChanges: [DriveChange] = []

        // Walk pagination until Drive returns `newStartPageToken`. The
        // poller keeps the in-flight `pageToken` in a local, so a mid-walk
        // failure doesn't clobber the stored baseline.
        while true {
            let page = try await fetcher.listChanges(pageToken: pageToken)
            allChanges.append(contentsOf: page.changes)
            if let next = page.nextPageToken {
                pageToken = next
                continue
            }
            newStartPageToken = page.newStartPageToken
            break
        }

        guard let finalToken = newStartPageToken else {
            throw SyncEngineError.changesFetchFailed(
                underlying: "missing newStartPageToken in final page"
            )
        }

        // Persist the new token before classifying so the next poll
        // doesn't re-fetch the same window if classification crashes.
        try persistPageToken(finalToken)

        let outcome = try await classify(
            changes: allChanges,
            pageToken: finalToken
        )
        continuation?.yield(outcome)
        return outcome
    }

    private func persistPageToken(_ token: String) throws {
        do {
            try catalog.saveDrivePageToken(token)
        } catch {
            throw SyncEngineError.pageTokenStoreFailed(
                underlying: String(describing: error)
            )
        }
    }

    private func classify(
        changes: [DriveChange],
        pageToken: String
    ) async throws -> DeltaSyncOutcome {
        if changes.isEmpty {
            return .noChanges(pageToken: pageToken)
        }

        let cachedCatalogId: String?
        do {
            cachedCatalogId = try fileIdStore.load()
        } catch {
            throw SyncEngineError.fileIdStoreFailed(
                underlying: String(describing: error)
            )
        }

        var catalogChange: DriveChange?
        var nonCatalogCount = 0
        for change in changes {
            // Skip removals — the catalog file or any tracked original
            // disappearing isn't something the poller should act on by
            // itself; the next publish or asset fetch will surface it.
            if change.removed || change.trashed { continue }
            if let cachedCatalogId, change.fileId == cachedCatalogId {
                catalogChange = change
            } else {
                nonCatalogCount += 1
            }
        }

        if let catalogChange {
            let lastPublishedTime = try? catalog.loadLastPublishedCatalogModifiedTime()
            // After a hot-reload (#259) the new catalog is stamped with
            // the just-applied remote `modifiedTime`. A subsequent poll
            // can replay the same change — most often because the
            // harness fixture is deterministic, but also possible in
            // production if Drive returns the same change row before
            // the next mutation lands. Treat a perfect match against
            // the stamped time as "we already have this state" and
            // skip both the conflict and reload paths so the user
            // isn't re-prompted for an update they applied seconds
            // ago.
            if let lastPublishedTime,
               let remoteTime = catalogChange.modifiedTime,
               remoteTime == lastPublishedTime {
                if nonCatalogCount > 0 {
                    return .originalsChangedOnly(
                        addedCount: nonCatalogCount,
                        pageToken: pageToken
                    )
                }
                return .noChanges(pageToken: pageToken)
            }
            let localPending = await (publisher?.hasPendingChanges() ?? false)
            let remoteMovedPastLastPublish: Bool
            if let lastPublishedTime, let remoteTime = catalogChange.modifiedTime {
                remoteMovedPastLastPublish = remoteTime != lastPublishedTime
            } else {
                remoteMovedPastLastPublish = false
            }
            if localPending || remoteMovedPastLastPublish {
                return .conflict(
                    localPending: localPending,
                    remoteFileId: catalogChange.fileId,
                    modifiedTime: catalogChange.modifiedTime,
                    pageToken: pageToken
                )
            }
            return .catalogChanged(
                driveFileId: catalogChange.fileId,
                modifiedTime: catalogChange.modifiedTime,
                pageToken: pageToken
            )
        }

        if nonCatalogCount > 0 {
            return .originalsChangedOnly(
                addedCount: nonCatalogCount,
                pageToken: pageToken
            )
        }
        return .noChanges(pageToken: pageToken)
    }
}
