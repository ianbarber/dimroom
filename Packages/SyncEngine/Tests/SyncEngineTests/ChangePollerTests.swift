import XCTest
import Catalog
import DriveClient
@testable import SyncEngine

final class ChangePollerTests: XCTestCase {

    // MARK: - Helpers

    private func makeCatalog() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    private func makePoller(
        catalog: CatalogDatabase,
        fetcher: StubDriveChangesFetcher,
        cachedCatalogFileId: String? = nil,
        markerFilterEnabled: Bool = true
    ) -> (ChangePoller, InMemoryDriveFileIdStore) {
        let store = InMemoryDriveFileIdStore(initial: cachedCatalogFileId)
        let poller = ChangePoller(
            catalog: catalog,
            fetcher: fetcher,
            publisher: nil,
            fileIdStore: store,
            markerFilterEnabled: markerFilterEnabled
        )
        return (poller, store)
    }

    private var markerProperties: [String: String] {
        [DriveAppProperties.dimroomMarkerKey: DriveAppProperties.dimroomMarkerValue]
    }

    // MARK: - Bootstrap

    func testBootstrapPersistsTokenWhenNoneStored() async throws {
        let catalog = try makeCatalog()
        let fetcher = StubDriveChangesFetcher(bootstrapToken: "first-token")
        let (poller, _) = makePoller(catalog: catalog, fetcher: fetcher)

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .bootstrapped(let token):
            XCTAssertEqual(token, "first-token")
        default:
            XCTFail("expected .bootstrapped, got \(outcome)")
        }
        XCTAssertEqual(try catalog.loadDrivePageToken(), "first-token")
        XCTAssertEqual(fetcher.bootstrapCalls, 1)
        XCTAssertTrue(fetcher.listCalls.isEmpty)
    }

    // MARK: - Steady-state

    func testSteadyStateNoChangesPersistsNewToken() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored-token")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [],
            newStartPageToken: "next-token"
        ))
        let (poller, _) = makePoller(catalog: catalog, fetcher: fetcher)

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .noChanges(let token):
            XCTAssertEqual(token, "next-token")
        default:
            XCTFail("expected .noChanges, got \(outcome)")
        }
        XCTAssertEqual(try catalog.loadDrivePageToken(), "next-token")
        XCTAssertEqual(fetcher.listCalls, ["stored-token"])
        XCTAssertEqual(fetcher.bootstrapCalls, 0)
    }

    // MARK: - Catalog-file change classification

    func testCatalogFileChangeProducesCatalogChanged() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        let cachedId = "drive-catalog-abc"
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(
                    fileId: cachedId,
                    modifiedTime: "2026-05-17T08:00:00.000Z",
                    parents: ["catalog-folder"]
                )
            ],
            newStartPageToken: "after-catalog-change"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: cachedId
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .catalogChanged(let driveFileId, let modifiedTime, let pageToken):
            XCTAssertEqual(driveFileId, cachedId)
            XCTAssertEqual(modifiedTime, "2026-05-17T08:00:00.000Z")
            XCTAssertEqual(pageToken, "after-catalog-change")
        default:
            XCTFail("expected .catalogChanged, got \(outcome)")
        }
    }

    func testCatalogChangeWithStaleLastPublishProducesConflict() async throws {
        // Conflict detection has two branches: (a) `Debouncer.hasPending`
        // is true (covers in-flight edits in the current session) and
        // (b) the remote `modifiedTime` doesn't match the one we
        // recorded on our last publish (covers "another machine wrote
        // after us"). This test exercises (b); (a) is tested via the
        // CatalogPublisher.hasPendingChanges path in
        // CatalogPublisherTests.
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        try catalog.saveLastPublishedCatalogModifiedTime("2026-05-16T08:00:00.000Z")
        let fetcher = StubDriveChangesFetcher()
        let cachedId = "drive-catalog-abc"
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(
                    fileId: cachedId,
                    modifiedTime: "2026-05-17T08:00:00.000Z"
                )
            ],
            newStartPageToken: "after-catalog-change"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: cachedId
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .conflict(let localPending, let remoteFileId, let modifiedTime, _):
            XCTAssertFalse(localPending)
            XCTAssertEqual(remoteFileId, cachedId)
            XCTAssertEqual(modifiedTime, "2026-05-17T08:00:00.000Z")
        default:
            XCTFail("expected .conflict, got \(outcome)")
        }
    }

    func testCatalogChangeWithPendingDebouncerProducesConflict() async throws {
        // Exercises the (a) branch of conflict detection: the publisher
        // has a debounced publish queued (so we have unwritten local
        // edits since the last successful publish). A naive reload here
        // would clobber those edits, so the poller flags conflict.
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        let cachedId = "drive-catalog-abc"
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(
                    fileId: cachedId,
                    modifiedTime: "2026-05-17T08:00:00.000Z"
                )
            ],
            newStartPageToken: "after-catalog-change"
        ))
        // A long-debounce publisher with a queued trigger but a stub
        // uploader so the fire path never actually runs.
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: false)
        ))
        let publisher = CatalogPublisher(
            catalog: catalog,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: FileManager.default.temporaryDirectory,
            debounceInterval: .seconds(60),
            maxDebounceInterval: .seconds(600)
        )
        await publisher.start()
        publisher.scheduleDebouncedPublish()
        // Allow the detached task that bridges into the publisher actor
        // to land before we poll — otherwise `hasPendingChanges()` may
        // race and return false.
        try await Task.sleep(for: .milliseconds(50))

        let store = InMemoryDriveFileIdStore(initial: cachedId)
        let poller = ChangePoller(
            catalog: catalog,
            fetcher: fetcher,
            publisher: publisher,
            fileIdStore: store
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .conflict(let localPending, let remoteFileId, _, _):
            XCTAssertTrue(localPending)
            XCTAssertEqual(remoteFileId, cachedId)
        default:
            XCTFail("expected .conflict, got \(outcome)")
        }
        await publisher.stop()
    }

    func testOriginalsOnlyChangeProducesOriginalsChangedOnly() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(fileId: "asset-1", appProperties: markerProperties),
                DriveChange(fileId: "asset-2", appProperties: markerProperties),
            ],
            newStartPageToken: "after-originals"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: "drive-catalog-abc"
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .originalsChangedOnly(let addedCount, let pageToken):
            XCTAssertEqual(addedCount, 2)
            XCTAssertEqual(pageToken, "after-originals")
        default:
            XCTFail("expected .originalsChangedOnly, got \(outcome)")
        }
    }

    // MARK: - Post-reload guard (#259)

    func testCatalogChangeMatchingLastPublishedTimeYieldsNoChanges() async throws {
        // After a hot-reload, the new catalog is stamped with the
        // applied modifiedTime. If the next poll's change list replays
        // the same change (deterministic harness fixture, or a slow
        // Drive index that hasn't moved on yet) the poller must not
        // re-fire `.catalogChanged` for state we already have.
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        try catalog.saveLastPublishedCatalogModifiedTime("2026-05-17T08:00:00.000Z")
        let fetcher = StubDriveChangesFetcher()
        let cachedId = "drive-catalog-abc"
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(
                    fileId: cachedId,
                    modifiedTime: "2026-05-17T08:00:00.000Z"
                )
            ],
            newStartPageToken: "after-replay"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: cachedId
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .noChanges(let token):
            XCTAssertEqual(token, "after-replay")
        default:
            XCTFail("expected .noChanges (post-reload guard), got \(outcome)")
        }
    }

    // MARK: - appProperties marker filter (#273)

    func testUntaggedNonCatalogChangeIsDroppedWhenFilterEnabled() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(fileId: "foreign-1"),
                DriveChange(fileId: "foreign-2"),
            ],
            newStartPageToken: "after-foreign"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: "drive-catalog-abc"
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .noChanges(let pageToken):
            XCTAssertEqual(pageToken, "after-foreign")
        default:
            XCTFail("expected .noChanges, got \(outcome)")
        }
    }

    func testUntaggedNonCatalogChangeIsKeptWhenFilterDisabled() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(fileId: "foreign-1"),
                DriveChange(fileId: "foreign-2"),
            ],
            newStartPageToken: "after-foreign"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: "drive-catalog-abc",
            markerFilterEnabled: false
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .originalsChangedOnly(let addedCount, let pageToken):
            XCTAssertEqual(addedCount, 2)
            XCTAssertEqual(pageToken, "after-foreign")
        default:
            XCTFail("expected .originalsChangedOnly, got \(outcome)")
        }
    }

    func testUntaggedCatalogIdMatchStillClassifiesAsCatalogChanged() async throws {
        // Back-compat: catalogs published before #273 won't carry the
        // marker, but a cached driveFileId match should still trump the
        // missing tag so we don't ignore real catalog updates.
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        let cachedId = "drive-catalog-legacy"
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(
                    fileId: cachedId,
                    modifiedTime: "2026-05-17T08:00:00.000Z"
                )
            ],
            newStartPageToken: "after-legacy-catalog"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: cachedId
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .catalogChanged(let driveFileId, _, let pageToken):
            XCTAssertEqual(driveFileId, cachedId)
            XCTAssertEqual(pageToken, "after-legacy-catalog")
        default:
            XCTFail("expected .catalogChanged, got \(outcome)")
        }
    }

    func testMixedBatchCountsOnlyTaggedNonCatalogChanges() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [
                DriveChange(fileId: "tagged-1", appProperties: markerProperties),
                DriveChange(fileId: "untagged-1"),
                DriveChange(fileId: "tagged-2", appProperties: markerProperties),
                DriveChange(fileId: "untagged-2"),
                DriveChange(fileId: "untagged-3"),
            ],
            newStartPageToken: "after-mixed"
        ))
        let (poller, _) = makePoller(
            catalog: catalog,
            fetcher: fetcher,
            cachedCatalogFileId: "drive-catalog-abc"
        )

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .originalsChangedOnly(let addedCount, let pageToken):
            XCTAssertEqual(addedCount, 2)
            XCTAssertEqual(pageToken, "after-mixed")
        default:
            XCTFail("expected .originalsChangedOnly, got \(outcome)")
        }
    }

    // MARK: - Pagination

    func testPaginatedChangesFollowNextPageTokenBeforePersisting() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [DriveChange(fileId: "asset-1", appProperties: markerProperties)],
            nextPageToken: "page-2-token",
            newStartPageToken: nil
        ))
        fetcher.enqueueListResponse(DriveChangesPage(
            changes: [DriveChange(fileId: "asset-2", appProperties: markerProperties)],
            newStartPageToken: "final-token"
        ))
        let (poller, _) = makePoller(catalog: catalog, fetcher: fetcher)

        let outcome = try await poller.pollOnce()

        switch outcome {
        case .originalsChangedOnly(let addedCount, let pageToken):
            XCTAssertEqual(addedCount, 2)
            XCTAssertEqual(pageToken, "final-token")
        default:
            XCTFail("expected .originalsChangedOnly, got \(outcome)")
        }
        XCTAssertEqual(fetcher.listCalls, ["stored", "page-2-token"])
        XCTAssertEqual(try catalog.loadDrivePageToken(), "final-token")
    }

    // MARK: - Error path

    func testListChangesFailurePreservesStoredToken() async throws {
        let catalog = try makeCatalog()
        try catalog.saveDrivePageToken("stored")
        let fetcher = StubDriveChangesFetcher()
        fetcher.enqueueListError(.changesFetchFailed(underlying: "boom"))
        let (poller, _) = makePoller(catalog: catalog, fetcher: fetcher)

        do {
            _ = try await poller.pollOnce()
            XCTFail("expected throw")
        } catch let error as SyncEngineError {
            if case .changesFetchFailed = error {
                // expected
            } else {
                XCTFail("expected .changesFetchFailed, got \(error)")
            }
        }
        XCTAssertEqual(
            try catalog.loadDrivePageToken(),
            "stored",
            "stored token must not be mutated on failure"
        )
    }
}

