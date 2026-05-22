import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

final class LibraryViewModelRemoteAdditionsTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempCacheDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    @MainActor
    private func makeViewModel() throws -> LibraryViewModel {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        return LibraryViewModel(catalog: catalog, previewStore: store)
    }

    @MainActor
    func testDefaultBadgeIsNil() throws {
        let vm = try makeViewModel()
        XCTAssertNil(vm.remoteAdditionsBadge)
    }

    @MainActor
    func testRecordRemoteOriginalsAddedPublishesBadge() throws {
        let vm = try makeViewModel()
        vm.recordRemoteOriginalsAdded(count: 3)
        XCTAssertEqual(vm.remoteAdditionsBadge?.addedCount, 3)
    }

    @MainActor
    func testSuccessiveRecordCallsAccumulate() throws {
        let vm = try makeViewModel()
        vm.recordRemoteOriginalsAdded(count: 3)
        let firstSeenAt = vm.remoteAdditionsBadge?.firstSeenAt

        // Sleep a microsecond so the second call's "now" is distinguishable
        // — but the badge must preserve the earlier firstSeenAt regardless.
        vm.recordRemoteOriginalsAdded(count: 2)

        XCTAssertEqual(vm.remoteAdditionsBadge?.addedCount, 5)
        XCTAssertEqual(vm.remoteAdditionsBadge?.firstSeenAt, firstSeenAt)
    }

    @MainActor
    func testZeroAndNegativeCountsAreIgnored() throws {
        let vm = try makeViewModel()
        vm.recordRemoteOriginalsAdded(count: 0)
        XCTAssertNil(vm.remoteAdditionsBadge)

        vm.recordRemoteOriginalsAdded(count: -4)
        XCTAssertNil(vm.remoteAdditionsBadge)
    }

    @MainActor
    func testDismissClearsBadge() throws {
        let vm = try makeViewModel()
        vm.recordRemoteOriginalsAdded(count: 4)
        XCTAssertNotNil(vm.remoteAdditionsBadge)

        vm.dismissRemoteAdditionsBadge()
        XCTAssertNil(vm.remoteAdditionsBadge)
    }

    @MainActor
    func testDismissThenRecordRestartsAccumulation() throws {
        let vm = try makeViewModel()
        vm.recordRemoteOriginalsAdded(count: 3)
        vm.dismissRemoteAdditionsBadge()

        vm.recordRemoteOriginalsAdded(count: 2)
        XCTAssertEqual(vm.remoteAdditionsBadge?.addedCount, 2)
    }
}
