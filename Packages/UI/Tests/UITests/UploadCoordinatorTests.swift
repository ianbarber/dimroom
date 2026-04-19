import Catalog
import DriveClient
import Foundation
@testable import UI
import XCTest

final class UploadCoordinatorTests: XCTestCase {

    private func makeCatalog() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    private func makeSampleAsset(
        hash: String = "h-abc",
        filename: String = "IMG.jpg",
        localPath: String? = "/tmp/fake.jpg"
    ) -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: filename,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            width: 100,
            height: 100,
            localPath: localPath,
            bytes: 10_000
        )
    }

    @MainActor
    func testHappyPathPersistsDriveFileId() async throws {
        let catalog = try makeCatalog()
        let asset = makeSampleAsset()
        try catalog.insertAsset(asset)

        let uploader = StubUploader(result: .uploaded(fileID: "uploaded-abc"))
        let coordinator = UploadCoordinator()
        await coordinator.run(assets: [asset], catalog: catalog, uploader: uploader)

        XCTAssertEqual(coordinator.phase, .done(uploadedCount: 1, skippedCount: 0))
        let refreshed = try catalog.fetchAsset(id: asset.id)
        XCTAssertEqual(refreshed?.driveFileId, "uploaded-abc")
    }

    @MainActor
    func testSkippedDuplicateStillWritesDriveFileId() async throws {
        let catalog = try makeCatalog()
        let asset = makeSampleAsset(hash: "dupe-hash")
        try catalog.insertAsset(asset)

        let uploader = StubUploader(result: .skippedDuplicate(fileID: "existing-id"))
        let coordinator = UploadCoordinator()
        await coordinator.run(assets: [asset], catalog: catalog, uploader: uploader)

        XCTAssertEqual(coordinator.phase, .done(uploadedCount: 0, skippedCount: 1))
        let refreshed = try catalog.fetchAsset(id: asset.id)
        XCTAssertEqual(refreshed?.driveFileId, "existing-id")
    }

    @MainActor
    func testErrorHaltsBatchAndSurfacesFailedPhase() async throws {
        let catalog = try makeCatalog()
        let assetA = makeSampleAsset(hash: "ok")
        let assetB = makeSampleAsset(hash: "fails")
        try catalog.insertAsset(assetA)
        try catalog.insertAsset(assetB)

        let uploader = StubUploader(results: [
            .uploaded(fileID: "file-a"),
        ], errorAfter: DriveUploadError.retryBudgetExhausted)
        let coordinator = UploadCoordinator()
        await coordinator.run(assets: [assetA, assetB], catalog: catalog, uploader: uploader)

        if case .failed(let message) = coordinator.phase {
            XCTAssertTrue(message.contains("retry budget"), "got: \(message)")
        } else {
            XCTFail("expected .failed, got \(coordinator.phase)")
        }
        // First asset still committed.
        XCTAssertEqual(try catalog.fetchAsset(id: assetA.id)?.driveFileId, "file-a")
        // Second asset had no successful upload — driveFileId should be nil.
        XCTAssertNil(try catalog.fetchAsset(id: assetB.id)?.driveFileId)
    }

    @MainActor
    func testMissingLocalPathIsSkippedWithoutUpload() async throws {
        let catalog = try makeCatalog()
        let asset = makeSampleAsset(localPath: nil)
        try catalog.insertAsset(asset)

        let uploader = StubUploader(result: .uploaded(fileID: "should-not-be-called"))
        let coordinator = UploadCoordinator()
        await coordinator.run(assets: [asset], catalog: catalog, uploader: uploader)

        // Both counters stay zero; uploader never invoked; phase done.
        XCTAssertEqual(coordinator.phase, .done(uploadedCount: 0, skippedCount: 0))
        XCTAssertEqual(uploader.callCount, 0)
    }

    @MainActor
    func testProgressIsPublished() async throws {
        let catalog = try makeCatalog()
        let asset = makeSampleAsset()
        try catalog.insertAsset(asset)

        let uploader = StubUploader(result: .uploaded(fileID: "p1"), emitProgress: true)
        let coordinator = UploadCoordinator()
        await coordinator.run(assets: [asset], catalog: catalog, uploader: uploader)

        XCTAssertEqual(coordinator.totalItems, 1)
        XCTAssertEqual(coordinator.currentItem, 1)
    }
}

// MARK: - Stub uploader

final class StubUploader: DriveUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [UploadOutcome]
    private let errorAfter: Error?
    private let emitProgress: Bool
    private(set) var callCount = 0

    init(result: UploadOutcome, emitProgress: Bool = false) {
        self.results = [result]
        self.errorAfter = nil
        self.emitProgress = emitProgress
    }

    init(results: [UploadOutcome], errorAfter: Error? = nil) {
        self.results = results
        self.errorAfter = errorAfter
        self.emitProgress = false
    }

    func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome {
        lock.lock()
        callCount += 1
        if results.isEmpty {
            lock.unlock()
            if let err = errorAfter {
                if emitProgress { progress(ref.bytes, ref.bytes) }
                throw err
            }
            throw DriveUploadError.invalidServerResponse("no more canned responses")
        }
        let next = results.removeFirst()
        lock.unlock()
        if emitProgress { progress(ref.bytes, ref.bytes) }
        return next
    }
}
