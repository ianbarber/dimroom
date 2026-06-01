import Catalog
@testable import Dimroom
import DriveClient
import Foundation
import os
@testable import UI
import XCTest

/// Layer A coverage for `AutoUploadAfterImport.runIfEnabled` — the shared
/// decision helper both import paths (`AppDelegate.importFolderFromMenu`
/// and `HarnessController.handleImportFolder`) call after a successful
/// import to wire the `driveAutoUploadOriginals` toggle (#236) into
/// `UploadCoordinator` (#270).
///
/// These tests exercise every guard in the decision rule and the happy
/// path. The happy-path case (`testToggleOn_connectedWithUploader_runsUpload`)
/// is the one that fully satisfies AC1 — Layer C cannot, because harness
/// mode wires no real `DriveUploading`.
final class AutoUploadAfterImportTests: XCTestCase {

    // MARK: - Toggle off

    @MainActor
    func testToggleOff_doesNotRunUpload() async throws {
        let fixture = try Fixture(toggleOn: false, connected: true, withUploader: true)

        await fixture.run()

        XCTAssertEqual(fixture.uploader.callCount, 0)
        XCTAssertEqual(fixture.coordinator.phase, .idle)
    }

    // MARK: - Toggle on, but a precondition fails (silent no-op)

    @MainActor
    func testToggleOn_driveDisconnected_silentNoop() async throws {
        let fixture = try Fixture(toggleOn: true, connected: false, withUploader: true)

        await fixture.run()

        XCTAssertEqual(fixture.uploader.callCount, 0)
        XCTAssertEqual(fixture.coordinator.phase, .idle)
    }

    @MainActor
    func testToggleOn_noDriveUploader_silentNoop() async throws {
        let fixture = try Fixture(toggleOn: true, connected: true, withUploader: false)

        await fixture.run()

        // No uploader to record against; the coordinator must never have run.
        XCTAssertEqual(fixture.coordinator.phase, .idle)
    }

    @MainActor
    func testToggleOn_zeroNewAssets_uploaderNotCalled() async throws {
        let fixture = try Fixture(toggleOn: true, connected: true, withUploader: true)

        // Run for a session id that has no assets linked.
        await fixture.run(sessionId: UUID())

        XCTAssertEqual(fixture.uploader.callCount, 0)
        XCTAssertEqual(fixture.coordinator.phase, .idle)
    }

    @MainActor
    func testToggleOn_uploadCoordinatorAlreadyActive_skips() async throws {
        let fixture = try Fixture(toggleOn: true, connected: true, withUploader: true)

        // A manual (or prior auto) upload is already in flight.
        fixture.coordinator.setPhaseForTesting(.uploading)

        await fixture.run()

        // Guard #4 short-circuits before re-entering `run`.
        XCTAssertEqual(fixture.uploader.callCount, 0)
        XCTAssertEqual(fixture.coordinator.phase, .uploading)
    }

    // MARK: - Happy path (AC1)

    @MainActor
    func testToggleOn_connectedWithUploader_runsUpload() async throws {
        let fixture = try Fixture(toggleOn: true, connected: true, withUploader: true)

        await fixture.run()

        // The uploader saw exactly the assets inserted under this session.
        XCTAssertEqual(fixture.uploader.uploadedAssetIds, Set(fixture.sessionAssetIds))
        XCTAssertEqual(fixture.coordinator.phase, .done(uploadedCount: fixture.sessionAssetIds.count, skippedCount: 0))

        // End-to-end: each asset's driveFileId is persisted.
        for id in fixture.sessionAssetIds {
            XCTAssertNotNil(try fixture.catalog.fetchAsset(id: id)?.driveFileId)
        }
    }

    @MainActor
    func testToggleOn_onlyUploadsThisSession() async throws {
        let fixture = try Fixture(toggleOn: true, connected: true, withUploader: true)

        // Insert a second session that must NOT be uploaded.
        let otherSession = ImportSession(sourceKind: "folder")
        try fixture.catalog.insertImportSession(otherSession)
        let strayId = UUID()
        try fixture.catalog.insertAsset(
            Asset(
                id: strayId,
                contentHash: "stray-hash",
                originalFilename: "STRAY.jpg",
                sourceType: .digital,
                width: 10,
                height: 10,
                localPath: "/tmp/stray.jpg",
                bytes: 100,
                importSessionId: otherSession.id
            )
        )

        await fixture.run()

        XCTAssertEqual(fixture.uploader.uploadedAssetIds, Set(fixture.sessionAssetIds))
        XCTAssertFalse(fixture.uploader.uploadedAssetIds.contains(strayId))
    }

    // MARK: - Fixture

    /// Bundles a catalog seeded with one import session of N assets plus
    /// the settings/auth/coordinator dependencies the helper needs.
    @MainActor
    private struct Fixture {
        let catalog: CatalogDatabase
        let settings: SettingsStore
        let auth: DriveAuthState
        let uploader: RecordingUploader
        let coordinator: UploadCoordinator
        let sessionId: UUID
        let sessionAssetIds: [UUID]
        private let withUploader: Bool

        init(toggleOn: Bool, connected: Bool, withUploader: Bool, assetCount: Int = 3) throws {
            self.catalog = try CatalogDatabase.inMemory()
            self.settings = SettingsStore(
                defaults: UserDefaults(suiteName: "auto-upload-test-\(UUID().uuidString)")!
            )
            settings.driveAutoUploadOriginals = toggleOn
            self.auth = DriveAuthState(client: StubDriveAuth(authenticated: connected))
            self.uploader = RecordingUploader()
            self.coordinator = UploadCoordinator()
            self.withUploader = withUploader

            let session = ImportSession(sourceKind: "folder")
            try catalog.insertImportSession(session)
            self.sessionId = session.id

            var ids: [UUID] = []
            for i in 0..<assetCount {
                let id = UUID()
                ids.append(id)
                try catalog.insertAsset(
                    Asset(
                        id: id,
                        contentHash: "hash-\(i)",
                        originalFilename: "IMG_\(i).jpg",
                        sourceType: .digital,
                        width: 100,
                        height: 100,
                        localPath: "/tmp/fake-\(i).jpg",
                        bytes: 10_000,
                        importSessionId: session.id
                    )
                )
            }
            self.sessionAssetIds = ids
        }

        /// Hydrates auth (so a `connected` stub flips to `.connected`) and
        /// drives the helper for the seeded session by default.
        func run(sessionId overrideSessionId: UUID? = nil) async {
            await auth.hydrate()
            await AutoUploadAfterImport.runIfEnabled(
                sessionId: overrideSessionId ?? sessionId,
                settingsStore: settings,
                driveAuthState: auth,
                driveUploader: withUploader ? uploader : nil,
                uploadCoordinator: coordinator,
                catalog: catalog
            )
        }
    }
}

// MARK: - Stubs

/// Records every `upload(_:)` call so tests can assert which assets the
/// coordinator handed to Drive. `DriveUploading` is public, so this
/// compiles from the App test target without a shared fixture. State lives
/// behind an `OSAllocatedUnfairLock` so the type is `Sendable` without the
/// async-context warning that `NSLock.lock()`/`unlock()` raises.
private final class RecordingUploader: DriveUploading {
    private struct State {
        var callCount = 0
        var uploadedAssetIds: Set<UUID> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var callCount: Int { state.withLock { $0.callCount } }
    var uploadedAssetIds: Set<UUID> { state.withLock { $0.uploadedAssetIds } }

    func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome {
        state.withLock {
            $0.callCount += 1
            $0.uploadedAssetIds.insert(ref.assetId)
        }
        return .uploaded(fileID: "file-\(ref.assetId.uuidString)")
    }
}

/// Stub authenticator so `DriveAuthState` can flip to `.connected` after
/// `hydrate()` without real Google traffic.
private struct StubDriveAuth: DriveAuthenticating {
    let authenticated: Bool
    var isAuthenticated: Bool { get async { authenticated } }
    var authFailures: AsyncStream<Void> { AsyncStream { $0.finish() } }
    func authenticate() async throws {}
    func deauthenticate() async throws {}
    func fetchAccountEmail() async throws -> String? { nil }
}
