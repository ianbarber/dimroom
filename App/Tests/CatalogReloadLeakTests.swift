import Catalog
@testable import Dimroom
import DriveClient
import Foundation
import Previews
import SyncEngine
import XCTest

/// Layer A weak-reference leak coverage for the catalog hot-reload swap
/// (#321, following up on #259). #314 shipped `CatalogHotReloader` and
/// `CatalogHotReloaderTests` for the file-swap / validation / stamping
/// mechanics, but nothing pinned the property #259's verification
/// criterion actually named: swapping in a fresh `CatalogDatabase` must
/// release the previous one and everything derived from it
/// (`OriginalsCoordinator`, `ChangePoller`, `CatalogPublisher`, and the
/// `changePollerEventsTask` closure capture).
///
/// These tests drive the *real* `AppDelegate.rewireForReloadedCatalog`
/// against a seeded old-catalog object graph and assert the previous
/// objects deallocate after one `autoreleasepool` tick. Exercising the
/// real method — rather than a hand-rolled mirror — is the point: a
/// future refactor that reintroduces a strong reference to the
/// swapped-out catalog fails here.
@MainActor
final class CatalogReloadLeakTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogReloadLeakTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFileIdStore(in dir: URL, name: String) -> FileSystemDriveFileIdStore {
        FileSystemDriveFileIdStore(path: dir.appendingPathComponent(name).path)
    }

    /// Build the old-catalog object graph the way the launch path wires
    /// it — coordinator + publisher + poller + a live events task
    /// subscribed to the poller — and seed it onto `appDelegate`. The
    /// seam also installs the coordinator as the live `originalFetcher`
    /// on both view models, which is precisely what turns a missed
    /// teardown into a leak of the old catalog. Returns the strong refs
    /// so the caller can stash `weak` copies before letting them fall
    /// out of scope.
    private func seedOldGraph(
        on appDelegate: AppDelegate,
        dir: URL
    ) throws -> (
        catalog: CatalogDatabase,
        coordinator: OriginalsCoordinator,
        poller: ChangePoller,
        publisher: CatalogPublisher,
        eventsTask: Task<Void, Never>
    ) {
        let oldCatalog = try CatalogDatabase(path: dir.appendingPathComponent("old.sqlite").path)
        let oldCoordinator = OriginalsCoordinator(catalog: oldCatalog)
        let oldPublisher = CatalogPublisher(
            catalog: oldCatalog,
            uploader: NoopCatalogUploader(),
            fileIdStore: makeFileIdStore(in: dir, name: "old-publisher-id.txt")
        )
        let oldPoller = ChangePoller(
            catalog: oldCatalog,
            fetcher: NoopChangesFetcher(),
            publisher: oldPublisher,
            fileIdStore: makeFileIdStore(in: dir, name: "old-poller-id.txt")
        )
        // Mirror the real `changePollerEventsTask`: a task that holds the
        // poller strongly via the `events()` subscription. Leak surface
        // #2 — cancelling + dropping this task must release that capture.
        let eventsTask = Task { @MainActor in
            let stream = await oldPoller.events()
            for await _ in stream {}
        }
        appDelegate.installReloadStateForTesting(
            catalog: oldCatalog,
            coordinator: oldCoordinator,
            publisher: oldPublisher,
            poller: oldPoller,
            eventsTask: eventsTask
        )
        return (oldCatalog, oldCoordinator, oldPoller, oldPublisher, eventsTask)
    }

    // MARK: - Success path

    /// The happy path: a valid originals-cache directory, `driveClient`
    /// nil so the publisher/poller rebuild (step 5) is skipped and the
    /// test stays bounded. Every object derived from the previous
    /// catalog must deallocate once the swap completes.
    func testHotReloadReleasesPreviousCatalog() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let appDelegate = AppDelegate()
        let previewStore = PreviewStore(cacheDirectory: dir.appendingPathComponent("previews"))
        let newCatalog = try CatalogDatabase(path: dir.appendingPathComponent("new.sqlite").path)

        weak var weakOldCatalog: CatalogDatabase?
        weak var weakOldCoordinator: OriginalsCoordinator?
        weak var weakOldPoller: ChangePoller?
        weak var weakOldPublisher: CatalogPublisher?
        var eventsTask: Task<Void, Never>?

        do {
            let graph = try seedOldGraph(on: appDelegate, dir: dir)
            weakOldCatalog = graph.catalog
            weakOldCoordinator = graph.coordinator
            weakOldPoller = graph.poller
            weakOldPublisher = graph.publisher
            eventsTask = graph.eventsTask

            // Sanity: the graph is alive and seeded before the swap.
            XCTAssertNotNil(weakOldCatalog)

            await appDelegate.rewireForReloadedCatalog(
                newCatalog,
                previewStore: previewStore,
                cacheDirectory: dir.appendingPathComponent("originals-cache"),
                budgetBytes: 1_000_000,
                originalsDownloader: NoopOriginalsDownloader(),
                driveClient: nil
            )
        }

        // Drain the cancelled events task so its strong capture of the
        // old poller is released before we assert (leak surface #2).
        await eventsTask?.value
        eventsTask = nil
        autoreleasepool {}

        XCTAssertNil(weakOldCatalog, "previous CatalogDatabase leaked after hot-reload")
        XCTAssertNil(weakOldCoordinator, "previous OriginalsCoordinator leaked after hot-reload")
        XCTAssertNil(weakOldPoller, "previous ChangePoller leaked after hot-reload")
        XCTAssertNil(weakOldPublisher, "previous CatalogPublisher leaked after hot-reload")

        // The freshly-swapped catalog stays alive (held by appDelegate).
        XCTAssertNotNil(newCatalog)
    }

    // MARK: - Cache-init failure path (leak surface #1)

    /// If `OriginalsCache.init` throws, the new coordinator can't attach
    /// a cache — but it must still be bound to the view models and
    /// `originalsCoordinator` so they stop pointing at the previous
    /// catalog's coordinator. Before #321 those rebinds lived inside the
    /// `if let cache` block, so a failed init pinned the swapped-out
    /// catalog through the view models' `originalFetcher`. This test
    /// fails against that older shape.
    func testHotReloadReleasesPreviousCatalogWhenOriginalsCacheInitFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Force `OriginalsCache.init` to throw: aim the cache directory
        // at a path whose parent is a regular file, so `createDirectory`
        // can't create it.
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let unusableCacheDir = blocker.appendingPathComponent("originals-cache")

        let appDelegate = AppDelegate()
        let previewStore = PreviewStore(cacheDirectory: dir.appendingPathComponent("previews"))
        let newCatalog = try CatalogDatabase(path: dir.appendingPathComponent("new.sqlite").path)

        weak var weakOldCatalog: CatalogDatabase?
        weak var weakOldCoordinator: OriginalsCoordinator?
        var eventsTask: Task<Void, Never>?

        do {
            let graph = try seedOldGraph(on: appDelegate, dir: dir)
            weakOldCatalog = graph.catalog
            weakOldCoordinator = graph.coordinator
            eventsTask = graph.eventsTask

            await appDelegate.rewireForReloadedCatalog(
                newCatalog,
                previewStore: previewStore,
                cacheDirectory: unusableCacheDir,
                budgetBytes: 1_000_000,
                originalsDownloader: NoopOriginalsDownloader(),
                driveClient: nil
            )
        }

        await eventsTask?.value
        eventsTask = nil
        autoreleasepool {}

        XCTAssertNil(
            weakOldCatalog,
            "previous CatalogDatabase leaked when OriginalsCache init failed during hot-reload"
        )
        XCTAssertNil(
            weakOldCoordinator,
            "previous OriginalsCoordinator leaked when OriginalsCache init failed during hot-reload"
        )
    }
}

// MARK: - Test stubs

/// Never invoked — the leak tests rewire the coordinator/cache but never
/// fetch an original. Present only to satisfy `OriginalsCache.init`.
private struct NoopOriginalsDownloader: OriginalsDownloader {
    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {}
}

/// Minimal `CatalogUploading` so the seeded `CatalogPublisher` can be
/// constructed. The publisher is never started, so none of these run.
private struct NoopCatalogUploader: CatalogUploading {
    func upload(
        snapshotPath: String,
        existingFileId: String?,
        photoCount: Int?
    ) async throws -> CatalogUploadResult {
        CatalogUploadResult(driveFileId: "stub", uploadedBytes: 0, wasCreate: false)
    }
    func findExistingCatalog() async throws -> DriveCatalogRef? { nil }
    func download(fileId: String, to localPath: String) async throws -> Int64 { 0 }
}

/// Minimal `DriveChangesFetching` so the seeded `ChangePoller` can be
/// constructed. The poll loop is never started, so neither method runs.
private struct NoopChangesFetcher: DriveChangesFetching {
    func startPageToken() async throws -> String { "stub-token" }
    func listChanges(pageToken: String) async throws -> DriveChangesPage {
        DriveChangesPage(changes: [])
    }
}
