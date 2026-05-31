import AppKit
import Catalog
import CryptoKit
import DriveClient
import EditEngine
import Foundation
import Harness
import ImportKit
import Previews
import SyncEngine
import UI

/// Bridges harness commands to the app's state and AppKit operations.
///
/// Catalog-dependent dependencies (`catalog`, `catalogPublisher`,
/// `changePoller`, `originalsCoordinator`, `undoStack`) are stored as
/// closure-getters rather than direct references so the hot-reload path
/// (#259) can swap the live `CatalogDatabase` and its derived objects
/// underneath the controller without rebuilding the socket server. The
/// `AppDelegate` owns the storage; every command resolves the live
/// value at dispatch time.
final class HarnessController: @unchecked Sendable {
    private let router: AppRouter
    private let catalogProvider: @Sendable () -> CatalogDatabase?
    private let originalsDirectory: URL
    private let previewStore: PreviewStore
    private let libraryViewModel: LibraryViewModel
    private let developViewModel: DevelopViewModel
    private let editClipboard: EditClipboard
    private let exportCoordinator: ExportCoordinator
    private let uploadCoordinator: UploadCoordinator
    private let driveUploader: (any DriveUploading)?
    private let driveMarkerBackfill: DriveMarkerBackfill?
    private let originalsCoordinatorProvider: @Sendable () -> OriginalsCoordinator?
    private let undoStackProvider: @Sendable () -> UndoStack?
    private let catalogPublisherProvider: @Sendable () -> CatalogPublisher?
    private let driveAuthState: DriveAuthState?
    private let settingsStore: SettingsStore?
    private let changePollerProvider: @Sendable () -> ChangePoller?
    private let catalogRestoreUploader: (any CatalogUploading)?
    private let catalogRestorePath: String?
    private let catalogRestoreFileIdStore: (any DriveFileIdStore)?
    /// Owner of the unified export entry point (`startExport(...)`). The
    /// harness export commands route through it so a regression in either
    /// the menu→sheet path or the harness path is caught by the same
    /// Layer C flow (#242).
    private let appDelegate: AppDelegate
    /// Wire-format string identifying the token store backing the
    /// `DriveClient` (`"keychain"`, `"in-memory"`, `"stub-in-memory"`).
    /// Surfaced via `driveAuthState` so Layer C flows can assert that
    /// harness runs never hit the Keychain (#260).
    private let tokenStoreKind: String?
    private var server: HarnessServer?

    /// Convenience accessors mirror the previous `let` field shape so the
    /// command handlers don't have to thread a function call through every
    /// site. Each read resolves the live value owned by `AppDelegate`.
    private var catalog: CatalogDatabase? { catalogProvider() }
    private var originalsCoordinator: OriginalsCoordinator? { originalsCoordinatorProvider() }
    private var undoStack: UndoStack? { undoStackProvider() }
    private var catalogPublisher: CatalogPublisher? { catalogPublisherProvider() }
    private var changePoller: ChangePoller? { changePollerProvider() }

    init(
        router: AppRouter,
        catalog: @escaping @Sendable () -> CatalogDatabase?,
        originalsDirectory: URL,
        previewStore: PreviewStore,
        libraryViewModel: LibraryViewModel,
        developViewModel: DevelopViewModel,
        editClipboard: EditClipboard,
        exportCoordinator: ExportCoordinator,
        uploadCoordinator: UploadCoordinator,
        appDelegate: AppDelegate,
        driveUploader: (any DriveUploading)? = nil,
        driveMarkerBackfill: DriveMarkerBackfill? = nil,
        originalsCoordinator: @escaping @Sendable () -> OriginalsCoordinator? = { nil },
        undoStack: @escaping @Sendable () -> UndoStack? = { nil },
        catalogPublisher: @escaping @Sendable () -> CatalogPublisher? = { nil },
        driveAuthState: DriveAuthState? = nil,
        settingsStore: SettingsStore? = nil,
        changePoller: @escaping @Sendable () -> ChangePoller? = { nil },
        catalogRestoreUploader: (any CatalogUploading)? = nil,
        catalogRestorePath: String? = nil,
        catalogRestoreFileIdStore: (any DriveFileIdStore)? = nil,
        tokenStoreKind: String? = nil
    ) {
        self.router = router
        self.catalogProvider = catalog
        self.originalsDirectory = originalsDirectory
        self.previewStore = previewStore
        self.libraryViewModel = libraryViewModel
        self.developViewModel = developViewModel
        self.editClipboard = editClipboard
        self.exportCoordinator = exportCoordinator
        self.uploadCoordinator = uploadCoordinator
        self.appDelegate = appDelegate
        self.driveUploader = driveUploader
        self.driveMarkerBackfill = driveMarkerBackfill
        self.originalsCoordinatorProvider = originalsCoordinator
        self.undoStackProvider = undoStack
        self.catalogPublisherProvider = catalogPublisher
        self.driveAuthState = driveAuthState
        self.settingsStore = settingsStore
        self.changePollerProvider = changePoller
        self.catalogRestoreUploader = catalogRestoreUploader
        self.catalogRestorePath = catalogRestorePath
        self.catalogRestoreFileIdStore = catalogRestoreFileIdStore
        self.tokenStoreKind = tokenStoreKind
    }

    func start(socketPath: String = HarnessServer.defaultSocketPath) throws {
        let handler: CommandHandler = { [self] command in
            try await self.handleCommand(command)
        }
        let server = try HarnessServer(socketPath: socketPath, handler: handler)
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
    }

    private func handleCommand(_ command: Command) async throws -> Response {
        switch command {
        case .navigate(let route):
            await MainActor.run { router.route = route }
            return .ok()

        case .screenshot(let path):
            return await captureScreenshot(to: path)

        case .state:
            let snapshot = await MainActor.run { () -> AppState in
                let kind: String
                switch libraryViewModel.scope {
                case .all: kind = "all"
                case .session: kind = "session"
                case .recentlyDeleted: kind = "recentlyDeleted"
                }
                var progressByString: [String: Double] = [:]
                for (id, value) in libraryViewModel.downloadProgressByAssetId {
                    progressByString[id.uuidString] = value
                }
                return AppState(
                    route: router.route,
                    assetCount: libraryViewModel.rows.count,
                    selectedAssetId: libraryViewModel.selectedAssetId,
                    minRating: libraryViewModel.minRating,
                    scopeSessionId: libraryViewModel.scopeSessionId,
                    scopeKind: kind,
                    selectedAssetIds: Array(libraryViewModel.selectedAssetIds),
                    isZoomed: libraryViewModel.isZoomed,
                    hasUndoToast: libraryViewModel.undoToast != nil,
                    downloadingAssetIds: Array(libraryViewModel.downloadingAssetIds),
                    downloadProgressByAssetId: progressByString,
                    showHistogram: developViewModel.showHistogram,
                    developIsDownloadingOriginal: developViewModel.isDownloadingOriginal,
                    developDownloadProgress: developViewModel.downloadProgress,
                    developCurrentAssetId: developViewModel.currentAssetId,
                    libraryRemoteAdditionsCount: libraryViewModel.remoteAdditionsBadge?.addedCount,
                    magnifier: AppState.MagnifierState(
                        visible: developViewModel.magnifierVisible,
                        samplePointX: developViewModel.magnifierSamplePoint.x,
                        samplePointY: developViewModel.magnifierSamplePoint.y,
                        zoom: developViewModel.magnifierZoom,
                        usingPreviewFallback: developViewModel.magnifierUsingPreviewFallback,
                        windowOffsetX: developViewModel.magnifierWindowOffset.width,
                        windowOffsetY: developViewModel.magnifierWindowOffset.height
                    )
                )
            }
            let encoder = JSONEncoder()
            let data = try encoder.encode(snapshot)
            let json = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            return .ok(data: json)

        case .quit:
            // Send response before quitting
            Task { @MainActor in
                // Small delay so the response is sent first
                try? await Task.sleep(for: .milliseconds(100))
                NSApplication.shared.terminate(nil)
            }
            return .ok()

        case .importFolder(let path):
            return try await handleImportFolder(path: path)

        case .listAssets:
            return handleListAssets()

        case .selectAsset(let id):
            await MainActor.run { libraryViewModel.select(id) }
            return .ok()

        case .setRating(let assetId, let rating):
            await libraryViewModel.setRating(for: assetId, to: rating)
            return .ok()

        case .rotate(let assetId, let direction):
            let clockwise = direction != "ccw"
            await libraryViewModel.rotate(assetId: assetId, clockwise: clockwise)
            return .ok()

        case .goBack:
            await MainActor.run { router.goBack() }
            return .ok()

        case .setFilter(let minRating):
            await libraryViewModel.setMinRating(minRating)
            return .ok()

        case .copyEdit(let assetId):
            return handleCopyEdit(assetId: assetId)

        case .pasteEdit(let assetId, let includeCrop):
            return await handlePasteEdit(assetId: assetId, includeCrop: includeCrop)

        case .setEdit(let assetId, let stateJSON):
            return await handleSetEdit(assetId: assetId, stateJSON: stateJSON)

        case .getEdit(let assetId):
            return await handleGetEdit(assetId: assetId)

        case .setCrop(let assetId, let x, let y, let width, let height, let angle):
            return await handleSetCrop(
                assetId: assetId,
                x: x,
                y: y,
                width: width,
                height: height,
                angle: angle
            )

        case .setScope(let sessionId):
            await libraryViewModel.setScope(sessionId)
            return .ok()

        case .setScopeRecentlyDeleted:
            await libraryViewModel.setScope(.recentlyDeleted)
            return .ok()

        case .listImportSessions:
            return handleListImportSessions()

        case .selectNext:
            await MainActor.run { libraryViewModel.selectNext() }
            return .ok()

        case .selectPrevious:
            await MainActor.run { libraryViewModel.selectPrevious() }
            return .ok()

        case .selectUp:
            await MainActor.run { libraryViewModel.selectUp() }
            return .ok()

        case .selectDown:
            await MainActor.run { libraryViewModel.selectDown() }
            return .ok()

        case .zoomToggle:
            await MainActor.run { libraryViewModel.pendingZoomCommand = .toggleFitTo100 }
            return .ok()

        case .zoomReset:
            await MainActor.run { libraryViewModel.pendingZoomCommand = .resetToFit }
            return .ok()

        case .toggleHistogram:
            await MainActor.run { developViewModel.showHistogram.toggle() }
            return .ok()

        case .export(let destinationPath, let format, let applyEdits):
            return await handleExport(destinationPath: destinationPath, format: format, applyEdits: applyEdits)

        case .triggerExportMenu:
            return await handleTriggerExportMenu()

        case .completeExportSheet(let destinationPath, let format, let applyEdits):
            return await handleCompleteExportSheet(
                destinationPath: destinationPath,
                format: format,
                applyEdits: applyEdits
            )

        case .fetchOriginal(let assetId):
            return await handleFetchOriginal(assetId: assetId)

        case .nudgeColorWheel(let assetId, let hueParameter, let saturationParameter, let key, let shift):
            return await handleNudgeColorWheel(
                assetId: assetId,
                hueParameter: hueParameter,
                saturationParameter: saturationParameter,
                key: key,
                shift: shift
            )

        case .setMagnifier(let visible, let samplePointX, let samplePointY, let zoom):
            return await handleSetMagnifier(
                visible: visible,
                samplePointX: samplePointX,
                samplePointY: samplePointY,
                zoom: zoom
            )

        case .setMagnifierWindowOffset(let x, let y):
            return await handleSetMagnifierWindowOffset(x: x, y: y)

        case .setEditParameter(let assetId, let parameter, let value):
            return await handleSetEditParameter(assetId: assetId, parameter: parameter, value: value)

        case .resetEditParameter(let assetId, let parameter):
            return await handleResetEditParameter(assetId: assetId, parameter: parameter)

        case .setEditFlag(let assetId, let parameter, let value):
            return await handleSetEditFlag(assetId: assetId, parameter: parameter, value: value)

        case .resetEditFlag(let assetId, let parameter):
            return await handleResetEditFlag(assetId: assetId, parameter: parameter)

        case .setEditArrayParameter(let assetId, let parameter, let index, let value):
            return await handleSetEditArrayParameter(assetId: assetId, parameter: parameter, index: index, value: value)

        case .resetEditArrayParameter(let assetId, let parameter, let index):
            return await handleResetEditArrayParameter(assetId: assetId, parameter: parameter, index: index)

        case .setCurvePoints(let assetId, let channel, let pointsJSON):
            return await handleSetCurvePoints(assetId: assetId, channel: channel, pointsJSON: pointsJSON)

        case .resetCurve(let assetId, let channel):
            return await handleResetCurve(assetId: assetId, channel: channel)

        case .selectCurveChannel(let channel):
            return await handleSelectCurveChannel(channel: channel)

        case .undo:
            return await handleUndo()

        case .redo:
            return await handleRedo()

        case .selectAssets(let ids):
            await MainActor.run {
                libraryViewModel.select(nil)
                for (index, id) in ids.enumerated() {
                    if index == 0 {
                        libraryViewModel.select(id)
                    } else {
                        libraryViewModel.toggleSelect(id)
                    }
                }
            }
            return .ok()

        case .deleteAssets(let ids):
            await libraryViewModel.deleteAssets(ids: ids)
            return .ok()

        case .restoreAssets(let ids):
            await libraryViewModel.restoreAssets(ids: ids)
            return .ok()

        case .permanentlyDeleteAssets(let ids):
            await libraryViewModel.permanentlyDeleteAssets(ids: ids)
            return .ok()

        case .uploadToDrive(let assetId):
            return await handleUploadToDrive(assetId: assetId)

        case .getPreviewSignature(let assetId):
            return handleGetPreviewSignature(assetId: assetId)

        case .enterCropMode(let assetId):
            return await handleEnterCropMode(assetId: assetId)

        case .commitCrop:
            return await handleCommitCrop()

        case .cancelCrop:
            return await handleCancelCrop()

        case .setCropPreset(let name):
            return await handleSetCropPreset(name: name)

        case .resetCrop:
            return await handleResetCrop()

        case .dragRotateHandle(let corner, let angleDelta):
            return await handleDragRotateHandle(corner: corner, angleDelta: angleDelta)

        case .inspectMenu(let title):
            return await handleInspectMenu(title: title)

        case .publishCatalog:
            return await handlePublishCatalog()

        case .connectDrive:
            return await handleConnectDrive()

        case .disconnectDrive:
            return await handleDisconnectDrive()

        case .driveAuthState:
            return await handleDriveAuthState()

        case .simulateDriveAuthFailure:
            return await handleSimulateDriveAuthFailure()

        case .postMenuAction(let name):
            return await handlePostMenuAction(name: name)

        case .releaseHeldDownloads:
            HoldUntilReleasedHarnessDownloader.shared.release()
            return .ok()

        case .getSetting(let key):
            return await handleGetSetting(key: key)

        case .setSetting(let key, let valueJSON):
            return await handleSetSetting(key: key, valueJSON: valueJSON)

        case .clearOriginalsCache:
            return await handleClearOriginalsCache()

        case .clearPreviewCache:
            return await handleClearPreviewCache()

        case .syncFromDrive:
            return await handleSyncFromDrive()

        case .backfillDriveMarkers:
            return await handleBackfillDriveMarkers()

        case .restoreCatalogFromDrive(let confirm):
            return await handleRestoreCatalogFromDrive(confirm: confirm)

        case .reloadCatalogFromDrive(let driveFileId, let modifiedTime, let pageToken):
            return await handleReloadCatalogFromDrive(
                driveFileId: driveFileId,
                modifiedTime: modifiedTime,
                pageToken: pageToken
            )

        case .dismissRemoteAdditionsBadge:
            await MainActor.run { libraryViewModel.dismissRemoteAdditionsBadge() }
            return .ok()
        }
    }

    private func handleReloadCatalogFromDrive(
        driveFileId: String,
        modifiedTime: String?,
        pageToken: String
    ) async -> Response {
        let outcome: AppDelegate.ReloadResult
        do {
            outcome = try await appDelegate.reloadCatalogFromDrive(
                driveFileId: driveFileId,
                modifiedTime: modifiedTime,
                pageToken: pageToken
            )
        } catch {
            return .error("reloadCatalogFromDrive failed: \(error)")
        }
        switch outcome {
        case .reloaded:
            return .ok(data: .dictionary([
                "outcome": .string("reloaded"),
                "driveFileId": .string(driveFileId),
            ]))
        case .pendingLocalChanges:
            return .ok(data: .dictionary([
                "outcome": .string("pendingLocalChanges"),
            ]))
        }
    }

    // MARK: - Settings

    private func handleGetSetting(key: String) async -> Response {
        guard let store = settingsStore else {
            return .error("settings store not configured")
        }
        let value: Any? = await MainActor.run { store.value(forWireKey: key) }
        guard let value else {
            return .error("unknown setting key '\(key)'")
        }
        return .ok(data: .dictionary([
            "key": .string(key),
            "value": Self.encode(value: value),
        ]))
    }

    private func handleSetSetting(key: String, valueJSON: String) async -> Response {
        guard let store = settingsStore else {
            return .error("settings store not configured")
        }
        let decoded: Any
        do {
            // Decode as `JSONValue` so we get Foundation types (NSNumber,
            // String, Bool, Array, Dict) without committing to a specific
            // Swift type up-front. The store does its own coercion.
            let raw = try JSONSerialization.jsonObject(
                with: Data(valueJSON.utf8),
                options: [.fragmentsAllowed]
            )
            decoded = raw
        } catch {
            return .error("invalid valueJSON for '\(key)': \(error.localizedDescription)")
        }
        let success: Bool = await MainActor.run {
            store.setValue(forWireKey: key, value: decoded)
        }
        if !success {
            return .error("setting '\(key)' rejected the supplied value (unknown key or type mismatch)")
        }
        return .ok(data: .dictionary([
            "key": .string(key),
        ]))
    }

    private func handleClearOriginalsCache() async -> Response {
        guard let coordinator = originalsCoordinator else {
            return .error("originals coordinator not configured")
        }
        await coordinator.clearCache()
        return .ok()
    }

    private func handleClearPreviewCache() async -> Response {
        await previewStore.removeAll()
        return .ok()
    }

    private static func encode(value: Any) -> AnyCodableValue {
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .int(v) }
        if let v = value as? Int64 {
            if v <= Int64(Int.max) && v >= Int64(Int.min) {
                return .int(Int(v))
            }
            return .double(Double(v))
        }
        if let v = value as? Double { return .double(v) }
        if let v = value as? String { return .string(v) }
        return .null
    }

    // MARK: - Catalog restore

    private func handleRestoreCatalogFromDrive(confirm: Bool) async -> Response {
        guard let uploader = catalogRestoreUploader,
              let path = catalogRestorePath,
              let store = catalogRestoreFileIdStore else {
            return .error("catalog restore uploader not configured (no DriveClient and no DIMROOM_HARNESS_STUB_REMOTE_CATALOG)")
        }
        var promptPhotoCount: Int?
        let outcome: RestoreOutcome
        do {
            outcome = try await CatalogPublisher.restoreIfNeeded(
                localPath: path,
                uploader: uploader,
                fileIdStore: store,
                prompt: { prompt in
                    promptPhotoCount = prompt.photoCount
                    return confirm
                }
            )
        } catch let error as SyncEngineError {
            return .ok(data: .dictionary([
                "outcome": .string("restoreFailed"),
                "error": .string(String(describing: error)),
            ]))
        } catch {
            return .ok(data: .dictionary([
                "outcome": .string("restoreFailed"),
                "error": .string(String(describing: error)),
            ]))
        }
        var payload: [String: AnyCodableValue] = [:]
        switch outcome {
        case .restored(let driveFileId, let bytes):
            payload["outcome"] = .string("restored")
            payload["driveFileId"] = .string(driveFileId)
            payload["downloadedBytes"] = .int(Int(bytes))
        case .declinedByUser:
            payload["outcome"] = .string("declinedByUser")
        case .noRemoteCatalog:
            payload["outcome"] = .string("noRemoteCatalog")
        case .localCatalogPresent:
            payload["outcome"] = .string("localCatalogPresent")
        case .notAuthenticated:
            payload["outcome"] = .string("notAuthenticated")
        }
        if let photoCount = promptPhotoCount {
            payload["photoCount"] = .int(photoCount)
        }
        return .ok(data: .dictionary(payload))
    }

    private func handlePostMenuAction(name: String) async -> Response {
        guard let action = MenuActionName(rawValue: name) else {
            let valid = MenuActionName.allCases.map(\.rawValue).joined(separator: ", ")
            return .error("unknown menu action '\(name)'; expected one of: \(valid)")
        }
        // Posting via the same notification path the menu uses proves
        // the menu-to-action wiring end-to-end without the harness
        // needing to synthesise NSEvents.
        await MainActor.run {
            NotificationCenter.default.post(name: action.notificationName, object: nil)
        }
        return .ok()
    }

    // MARK: - Drive auth

    private func handleConnectDrive() async -> Response {
        guard let driveAuthState else {
            return .error("drive auth state not configured (OAuth credentials missing?)")
        }
        await driveAuthState.connect()
        return await handleDriveAuthState()
    }

    private func handleDisconnectDrive() async -> Response {
        guard let driveAuthState else {
            return .error("drive auth state not configured")
        }
        await driveAuthState.disconnect()
        return await handleDriveAuthState()
    }

    private func handleDriveAuthState() async -> Response {
        guard let driveAuthState else {
            var payload: [String: AnyCodableValue] = [
                "status": .string("disconnected"),
                "configured": .bool(false),
            ]
            if let kind = tokenStoreKind {
                payload["tokenStoreKind"] = .string(kind)
            }
            return .ok(data: .dictionary(payload))
        }
        let snapshot: (status: String, email: String?, needsReauthMessage: String?) = await MainActor.run {
            let message = driveAuthState.needsReauthMessage
            switch driveAuthState.status {
            case .disconnected: return ("disconnected", nil, message)
            case .connecting: return ("connecting", nil, message)
            case .connected(let email): return ("connected", email, message)
            }
        }
        var payload: [String: AnyCodableValue] = [
            "status": .string(snapshot.status),
            "configured": .bool(true),
        ]
        if let email = snapshot.email {
            payload["email"] = .string(email)
        } else {
            payload["email"] = .null
        }
        if let message = snapshot.needsReauthMessage {
            payload["needsReauthMessage"] = .string(message)
        } else {
            payload["needsReauthMessage"] = .null
        }
        if let kind = tokenStoreKind {
            payload["tokenStoreKind"] = .string(kind)
        }
        return .ok(data: .dictionary(payload))
    }

    private func handleSimulateDriveAuthFailure() async -> Response {
        guard let driveAuthState else {
            return .error("drive auth state not configured")
        }
        await MainActor.run {
            driveAuthState.simulateAuthFailureForTesting()
        }
        return await handleDriveAuthState()
    }

    // MARK: - Preview signature

    private func handleGetPreviewSignature(assetId: UUID) -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        let asset: Asset?
        do {
            asset = try catalog.fetchAsset(id: assetId)
        } catch {
            return .error("fetchAsset failed: \(error.localizedDescription)")
        }
        guard let asset else {
            return .error("asset not found: \(assetId)")
        }
        guard let thumbURL = previewStore.thumbnailURL(for: asset) else {
            return .ok(data: .dictionary([
                "present": .bool(false),
            ]))
        }
        do {
            let data = try Data(contentsOf: thumbURL)
            let hash = Self.sha256Hex(data)
            return .ok(data: .dictionary([
                "present": .bool(true),
                "sha256": .string(hash),
                "bytes": .int(data.count),
            ]))
        } catch {
            return .error("read thumbnail failed: \(error.localizedDescription)")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Crop lifecycle

    private func handleEnterCropMode(assetId: UUID) async -> Response {
        guard catalog != nil else {
            return .error("catalog not loaded")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.enterCropMode()
        }
        return .ok()
    }

    private func handleCommitCrop() async -> Response {
        await MainActor.run {
            developViewModel.commitCropFromViewModel()
        }
        return .ok()
    }

    private func handleCancelCrop() async -> Response {
        await MainActor.run {
            developViewModel.cancelCrop()
        }
        return .ok()
    }

    private func handleSetCropPreset(name: String) async -> Response {
        guard let preset = AspectRatioPreset(rawValue: name) else {
            let valid = AspectRatioPreset.allCases.map(\.rawValue).joined(separator: ", ")
            return .error("unknown preset '\(name)'; expected one of: \(valid)")
        }
        await MainActor.run {
            developViewModel.cropViewModel.applyPreset(preset)
        }
        return .ok()
    }

    private func handleResetCrop() async -> Response {
        await MainActor.run {
            developViewModel.resetCrop()
        }
        return .ok()
    }

    private func handleDragRotateHandle(corner: String, angleDelta: Double) async -> Response {
        let validCorners = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
        guard validCorners.contains(corner) else {
            return .error("unknown corner '\(corner)'; expected one of: \(validCorners.joined(separator: ", "))")
        }
        let active = await MainActor.run { developViewModel.cropViewModel.isActive }
        guard active else {
            return .error("crop mode is not active; call enter-crop first")
        }
        // Same write path as the on-screen handle drag: accumulate the
        // delta onto the live cropAngle and re-render. Pivot is always the
        // crop centre, so `corner` only validates the protocol shape.
        await MainActor.run {
            let current = developViewModel.cropViewModel.cropAngle
            developViewModel.setCropAngleLive(current + angleDelta)
        }
        return .ok()
    }

    // MARK: - Upload to Drive

    private func handleUploadToDrive(assetId: UUID) async -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        guard let driveUploader else {
            return .error("drive uploader not configured (authenticate first)")
        }
        let asset: Asset?
        do {
            asset = try catalog.fetchAsset(id: assetId)
        } catch {
            return .error("fetchAsset failed: \(error.localizedDescription)")
        }
        guard let asset else {
            return .error("asset not found: \(assetId)")
        }
        await uploadCoordinator.run(
            assets: [asset],
            catalog: catalog,
            uploader: driveUploader
        )
        let phase = await uploadCoordinator.phase
        switch phase {
        case .done(let uploaded, let skipped):
            let refreshed = (try? catalog.fetchAsset(id: assetId))?.driveFileId ?? ""
            return .ok(data: .dictionary([
                "driveFileId": .string(refreshed),
                "uploaded": .int(uploaded),
                "skipped": .int(skipped),
            ]))
        case .failed(let message):
            return .error("upload failed: \(message)")
        default:
            return .error("upload ended in unexpected phase")
        }
    }

    // MARK: - Delta sync

    private func handleSyncFromDrive() async -> Response {
        guard let changePoller else {
            return .error("change poller not configured (drive not authenticated)")
        }
        do {
            let outcome = try await changePoller.pollOnce()
            // `--harness` skips the periodic events subscription that
            // normally drives `handleDeltaSyncOutcome` (the periodic
            // path can race the harness's own `pollOnce` and an NSAlert
            // would block the socket). Apply the non-modal portion of
            // the outcome here so badges still surface to Layer C while
            // we skip the modal alerts.
            await MainActor.run {
                appDelegate.applyNonModalDeltaSyncOutcome(outcome)
            }
            return .ok(data: Self.encode(outcome: outcome))
        } catch let error as SyncEngineError {
            return .error("syncFromDrive failed: \(error)")
        } catch {
            return .error("syncFromDrive failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Marker backfill (#328)

    private func handleBackfillDriveMarkers() async -> Response {
        guard let driveMarkerBackfill else {
            return .error("drive marker backfill not configured (drive not authenticated)")
        }
        do {
            let summary = try await driveMarkerBackfill.run()
            return .ok(data: .dictionary([
                "scanned": .int(summary.scanned),
                "patched": .int(summary.patched),
                "skipped": .int(summary.skipped),
            ]))
        } catch {
            return .error("backfillDriveMarkers failed: \(error.localizedDescription)")
        }
    }

    private static func encode(outcome: DeltaSyncOutcome) -> AnyCodableValue {
        switch outcome {
        case .bootstrapped(let pageToken):
            return .dictionary([
                "status": .string("bootstrapped"),
                "pageToken": .string(pageToken),
            ])
        case .noChanges(let pageToken):
            return .dictionary([
                "status": .string("noChanges"),
                "pageToken": .string(pageToken),
            ])
        case .catalogChanged(let driveFileId, let modifiedTime, let pageToken):
            return .dictionary([
                "status": .string("catalogChanged"),
                "driveFileId": .string(driveFileId),
                "modifiedTime": modifiedTime.map(AnyCodableValue.string) ?? .null,
                "pageToken": .string(pageToken),
            ])
        case .conflict(let localPending, let remoteFileId, let modifiedTime, let pageToken):
            return .dictionary([
                "status": .string("conflict"),
                "localPending": .bool(localPending),
                "remoteFileId": .string(remoteFileId),
                "modifiedTime": modifiedTime.map(AnyCodableValue.string) ?? .null,
                "pageToken": .string(pageToken),
            ])
        case .originalsChangedOnly(let addedCount, let pageToken):
            return .dictionary([
                "status": .string("originalsChangedOnly"),
                "addedCount": .int(addedCount),
                "pageToken": .string(pageToken),
            ])
        }
    }

    // MARK: - Publish catalog

    private func handlePublishCatalog() async -> Response {
        guard let catalogPublisher else {
            return .error("catalog publisher not configured (drive not authenticated)")
        }
        do {
            let outcome = try await catalogPublisher.publishNow()
            return .ok(data: .dictionary([
                "driveFileId": .string(outcome.driveFileId),
                "uploadedBytes": .int(Int(outcome.uploadedBytes)),
                "durationMs": .int(Self.durationToMs(outcome.duration)),
                "wasCreate": .bool(outcome.wasCreate),
            ]))
        } catch SyncEngineError.notAuthenticated {
            return .error("drive not authenticated")
        } catch {
            return .error("publishCatalog failed: \(error)")
        }
    }

    private static func durationToMs(_ duration: Duration) -> Int {
        let components = duration.components
        let ms = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return Int(ms)
    }

    // MARK: - Undo / Redo

    private func handleUndo() async -> Response {
        guard let undoStack else {
            return .error("undo stack not configured")
        }
        await undoStack.undo()
        return .ok()
    }

    private func handleRedo() async -> Response {
        guard let undoStack else {
            return .error("undo stack not configured")
        }
        await undoStack.redo()
        return .ok()
    }

    // MARK: - Fetch original

    private func handleFetchOriginal(assetId: UUID) async -> Response {
        guard let coordinator = originalsCoordinator else {
            return .error("originals coordinator not configured")
        }
        guard let url = await coordinator.fetchOriginal(assetId: assetId) else {
            return .error("failed to fetch original; Drive unreachable or asset missing driveFileId")
        }
        return .ok(data: .dictionary([
            "localPath": .string(url.path),
        ]))
    }

    // MARK: - Import

    private func handleImportFolder(path: String) async throws -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        let folderURL = URL(fileURLWithPath: path)
        let importer = FolderImporter(
            catalog: catalog,
            originalsDirectory: originalsDirectory
        )
        let result = try await importer.importFolder(folderURL)

        // Generate previews for newly imported assets so the library grid
        // shows real thumbnails, matching the GUI import path.
        for asset in result.importedAssets {
            guard let localPath = asset.localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            _ = try? await previewStore.generate(for: asset, sourceURL: sourceURL)
        }

        // Auto-scope the library to the newly imported session and
        // reload so `state` reflects the new rows.
        await libraryViewModel.setScope(result.sessionId)
        return .ok(data: .dictionary([
            "importedCount": .int(result.importedCount),
            "skippedCount": .int(result.skippedCount),
            "sessionId": .string(result.sessionId.uuidString),
        ]))
    }

    // MARK: - Export

    private func handleExport(destinationPath: String, format: String, applyEdits: Bool) async -> Response {
        guard let exportFormat = ExportFormat(rawValue: format) else {
            return .error("invalid format '\(format)'; expected original, jpeg, or tiff")
        }
        let destinationURL = URL(fileURLWithPath: destinationPath)

        // Create the destination directory if it doesn't exist.
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return .error("failed to create destination directory: \(error.localizedDescription)")
        }

        return await runExport(
            destinationURL: destinationURL,
            destinationPath: destinationPath,
            format: exportFormat,
            applyEdits: applyEdits
        )
    }

    /// Drives the menu → notification path (#242). Verifies the
    /// File → Export… menu wiring posts `.showExportSheet`, which
    /// `ContentView` should observe and flip `showExportSheet` (or
    /// `showExportConfirmation`). Returns the SwiftUI sheet-visibility
    /// mirror so the flow can assert the sheet actually mounted before
    /// firing `completeExportSheet`.
    private func handleTriggerExportMenu() async -> Response {
        let visibleAfter = await MainActor.run { () -> Bool in
            ExportLog.logger.info("Harness triggerExportMenu — posting .showExportSheet")
            NotificationCenter.default.post(name: .showExportSheet, object: nil)
            return appDelegate.isExportSheetVisible
        }
        // Give SwiftUI a couple of runloop ticks to swap state. The
        // confirmationDialog path also routes through this notification
        // (and may *not* land the sheet — that's the policy talking, not
        // a bug), so we report the post-tick visibility and let the flow
        // decide whether to assert true.
        try? await Task.sleep(for: .milliseconds(150))
        let finalVisible = await MainActor.run { appDelegate.isExportSheetVisible }
        return .ok(data: .dictionary([
            "exportSheetVisible": .bool(finalVisible),
            "exportSheetVisibleImmediately": .bool(visibleAfter),
        ]))
    }

    /// Drives the sheet's `onExport` closure: same code path the user
    /// hits after picking a destination in the File → Export… sheet.
    /// Asserts the sheet is currently mounted before firing so the
    /// command can't paper over a regression that drops the sheet
    /// presentation. NSOpenPanel itself is not harness-driveable, so
    /// `destinationPath` substitutes for the panel's URL output.
    private func handleCompleteExportSheet(
        destinationPath: String,
        format: String,
        applyEdits: Bool
    ) async -> Response {
        guard let exportFormat = ExportFormat(rawValue: format) else {
            return .error("invalid format '\(format)'; expected original, jpeg, or tiff")
        }
        let visible = await MainActor.run { appDelegate.isExportSheetVisible }
        guard visible else {
            return .error("export sheet not visible; call triggerExportMenu first or check confirmation policy")
        }
        let destinationURL = URL(fileURLWithPath: destinationPath)
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            return .error("failed to create destination directory: \(error.localizedDescription)")
        }
        // Mirror ContentView.onExport: dismiss the sheet, then run the
        // coordinator through the same `appDelegate.startExport` entry.
        await MainActor.run {
            ExportLog.logger.info("Harness completeExportSheet — dismissing sheet, invoking startExport")
            appDelegate.setExportSheetVisible(false)
        }
        return await runExport(
            destinationURL: destinationURL,
            destinationPath: destinationPath,
            format: exportFormat,
            applyEdits: applyEdits
        )
    }

    /// Shared coordinator round-trip + response shaping. Used by both
    /// `handleExport` (direct) and `handleCompleteExportSheet` (sheet
    /// path) so both produce the same payload shape.
    private func runExport(
        destinationURL: URL,
        destinationPath: String,
        format: ExportFormat,
        applyEdits: Bool
    ) async -> Response {
        await appDelegate.startExport(
            destinationURL: destinationURL,
            format: format,
            jpegQuality: 85,
            applyEdits: applyEdits
        )
        let phase = await exportCoordinator.phase
        switch phase {
        case .done(let exported, let skipped, let failures):
            return .ok(data: .dictionary([
                "exportedCount": .int(exported),
                "skippedCount": .int(skipped),
                "failedCount": .int(failures.count),
                "destinationPath": .string(destinationPath),
            ]))
        case .failed(let message):
            return .error("export failed: \(message)")
        default:
            return .error("export ended in unexpected phase")
        }
    }

    // MARK: - List assets

    private func handleListAssets() -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            // Mirror LibraryViewModel.loadRows' sort so harness flows that
            // enumerate "all assets" see them in the same order as the grid.
            let assets = try catalog.fetchAssets().sorted { lhs, rhs in
                (lhs.captureDate ?? lhs.importedDate) > (rhs.captureDate ?? rhs.importedDate)
            }
            let array: [AnyCodableValue] = assets.map { asset in
                let captureDate: AnyCodableValue
                if let date = asset.captureDate {
                    captureDate = .string(Self.iso8601.string(from: date))
                } else {
                    captureDate = .null
                }
                let driveFileId: AnyCodableValue
                if let id = asset.driveFileId {
                    driveFileId = .string(id)
                } else {
                    driveFileId = .null
                }
                return .dictionary([
                    "id": .string(asset.id.uuidString),
                    "originalFilename": .string(asset.originalFilename),
                    "captureDate": captureDate,
                    "rating": .int(asset.rating),
                    "rotation": .int(asset.rotation),
                    "sourceType": .string(asset.sourceType.rawValue),
                    "driveFileId": driveFileId,
                ])
            }
            return .ok(data: .array(array))
        } catch {
            return .error("fetchAssets failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import sessions

    private func handleListImportSessions() -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            let sessions = try catalog.fetchImportSessions()
            let array: [AnyCodableValue] = sessions.map { session in
                .dictionary([
                    "id": .string(session.id.uuidString),
                    "displayName": .string(session.displayName),
                    "assetCount": .int(session.assetCount),
                    "startedAt": .string(Self.iso8601.string(from: session.startedAt)),
                ])
            }
            return .ok(data: .array(array))
        } catch {
            return .error("fetchImportSessions failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Edit clipboard

    private func handleCopyEdit(assetId: UUID) -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            let state = try catalog.latestEditState(for: assetId) ?? EditState()
            editClipboard.copy(state, from: assetId)
            return .ok()
        } catch {
            return .error("copyEdit failed: \(error.localizedDescription)")
        }
    }

    private func handlePasteEdit(assetId: UUID, includeCrop: Bool) async -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        let state: EditState?
        if includeCrop {
            state = editClipboard.pasteIncludingCrop()
        } else {
            state = editClipboard.pasteExcludingCrop()
        }
        guard let state else {
            return .ok(data: .dictionary(["pasted": .bool(false)]))
        }
        let previous = try? catalog.latestEditState(for: assetId)
        do {
            _ = try catalog.saveEditState(state, for: assetId)
            await recordEditUndo(assetId: assetId, previous: previous, next: state)
            // Keep the live DevelopViewModel in sync with the catalog
            // write so a subsequent undo has a real starting value to
            // animate from. Without this, VM and catalog diverge and
            // undo's `reloadEditState` reads a state the VM is already
            // at, so `replaySequence` bumps but no slider moves.
            await developViewModel.reloadEditState(for: assetId)
            return .ok(data: .dictionary(["pasted": .bool(true)]))
        } catch {
            return .error("pasteEdit failed: \(error.localizedDescription)")
        }
    }

    private func handleSetEdit(assetId: UUID, stateJSON: String) async -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            let state = try JSONDecoder().decode(EditState.self, from: Data(stateJSON.utf8))
            let previous = try? catalog.latestEditState(for: assetId)
            _ = try catalog.saveEditState(state, for: assetId)
            await recordEditUndo(assetId: assetId, previous: previous, next: state)
            // Keep the live DevelopViewModel in sync with the catalog
            // write so a subsequent undo has a real starting value to
            // animate from. Without this, VM and catalog diverge and
            // undo's `reloadEditState` reads a state the VM is already
            // at, so `replaySequence` bumps but no slider moves.
            await developViewModel.reloadEditState(for: assetId)
            return .ok()
        } catch {
            return .error("setEdit failed: \(error.localizedDescription)")
        }
    }

    private func recordEditUndo(
        assetId: UUID,
        previous: EditState?,
        next: EditState
    ) async {
        guard let undoStack else { return }
        await MainActor.run {
            undoStack.push(.editSave(
                assetId: assetId,
                previous: previous,
                next: next
            ))
        }
    }

    private func handleGetEdit(assetId: UUID) async -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        let liveState: EditState? = await MainActor.run {
            developViewModel.currentAssetId == assetId ? developViewModel.editState : nil
        }
        do {
            let state: EditState?
            if let liveState {
                state = liveState
            } else {
                state = try catalog.latestEditState(for: assetId)
            }
            guard let state else {
                return .ok(data: .null)
            }
            let data = try JSONEncoder().encode(state)
            let json = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            return .ok(data: json)
        } catch {
            return .error("getEdit failed: \(error.localizedDescription)")
        }
    }

    private func handleSetCrop(
        assetId: UUID,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        angle: Double
    ) async -> Response {
        guard catalog != nil else {
            return .error("catalog not loaded")
        }

        // Activate develop mode for this asset if it isn't already, so the
        // commit routes through DevelopViewModel's debounced render +
        // auto-save. Falling back to a direct catalog write would skip
        // those paths and diverge from live state.
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }

        let normalisedRect = CGRect(x: x, y: y, width: width, height: height)
        let clampedAngle = CropGeometry.clampAngle(angle)

        await MainActor.run {
            developViewModel.commitCrop(normalisedRect: normalisedRect, angle: clampedAngle)
        }
        // The undo push is owned by DevelopViewModel.scheduleSave now,
        // which debounces slider/crop mutations to one `.editSave` per
        // save window. Pushing here as well would produce two undo
        // entries per setCrop.
        return .ok()
    }

    /// Keyboard / VoiceOver path for `ColorWheelControl` (#305). Reads the
    /// wheel's current hue/saturation off the live edit state, applies the
    /// same `ColorWheelKeyboardModel` the view's `onKeyPress` does, and
    /// writes the changed axis back through `setParameter`. Synthesising
    /// NSEvents into the focused view is unreliable in harness mode (see
    /// `postMenuAction`), so this drives the shared model directly.
    private func handleNudgeColorWheel(
        assetId: UUID,
        hueParameter: String,
        saturationParameter: String,
        key: String,
        shift: Bool
    ) async -> Response {
        guard let hueKeyPath = DevelopViewModel.keyPath(forParameter: hueParameter) else {
            return .error("unknown parameter: \(hueParameter)")
        }
        guard let satKeyPath = DevelopViewModel.keyPath(forParameter: saturationParameter) else {
            return .error("unknown parameter: \(saturationParameter)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        if key == "reset" {
            await MainActor.run {
                developViewModel.resetParameter(hueKeyPath)
                developViewModel.resetParameter(satKeyPath)
            }
            return .ok()
        }
        guard let arrow = ColorWheelKeyboardModel.ArrowKey(wireName: key) else {
            return .error("unknown key '\(key)'; expected left, right, up, down, or reset")
        }
        await MainActor.run {
            let hue = developViewModel.editState[keyPath: hueKeyPath]
            let saturation = developViewModel.editState[keyPath: satKeyPath]
            let (newHue, newSaturation) = ColorWheelKeyboardModel.nudge(
                hue: hue,
                saturation: saturation,
                key: arrow,
                shift: shift
            )
            if shift {
                developViewModel.setParameter(satKeyPath, value: newSaturation)
            } else {
                developViewModel.setParameter(hueKeyPath, value: newHue)
            }
        }
        return .ok()
    }

    /// Drive the Develop pixel magnifier (#324). Routes to Develop —
    /// activating the library's selected asset if Develop has none — then
    /// applies visibility, the (optional) sample point, and the (optional)
    /// zoom through the same `DevelopViewModel` path the L key / sidebar use.
    private func handleSetMagnifier(
        visible: Bool,
        samplePointX: Double?,
        samplePointY: Double?,
        zoom: Int?
    ) async -> Response {
        await MainActor.run {
            if router.route != .develop {
                router.route = .develop
            }
        }
        let needsActivate = await MainActor.run { developViewModel.currentAssetId == nil }
        if needsActivate {
            let selected = await MainActor.run { libraryViewModel.selectedAssetId }
            await developViewModel.activate(assetId: selected)
        }
        await MainActor.run {
            let point: CGPoint?
            if let samplePointX, let samplePointY {
                point = CGPoint(x: samplePointX, y: samplePointY)
            } else {
                point = nil
            }
            developViewModel.setMagnifier(visible: visible, samplePoint: point, zoom: zoom)
        }
        return .ok()
    }

    /// Set the floating magnifier window's drag offset (#377). Mirrors
    /// `handleSetMagnifier`'s routing — switches to Develop and activates
    /// the library's selected asset if Develop has none — then calls the
    /// same clamping `setMagnifierWindowOffset` the drag gesture uses, so
    /// the offset lands clamped on-screen. The pointer drag itself cannot
    /// be synthesised in the harness (see #348).
    private func handleSetMagnifierWindowOffset(x: Double, y: Double) async -> Response {
        await MainActor.run {
            if router.route != .develop {
                router.route = .develop
            }
        }
        let needsActivate = await MainActor.run { developViewModel.currentAssetId == nil }
        if needsActivate {
            let selected = await MainActor.run { libraryViewModel.selectedAssetId }
            await developViewModel.activate(assetId: selected)
        }
        await MainActor.run {
            developViewModel.setMagnifierWindowOffset(CGSize(width: x, height: y))
        }
        return .ok()
    }

    private func handleSetEditParameter(assetId: UUID, parameter: String, value: Double) async -> Response {
        guard let keyPath = DevelopViewModel.keyPath(forParameter: parameter) else {
            return .error("unknown parameter: \(parameter)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.setParameter(keyPath, value: value)
        }
        return .ok()
    }

    private func handleSetCurvePoints(assetId: UUID, channel: String, pointsJSON: String) async -> Response {
        guard let curveChannel = DevelopViewModel.curveChannel(named: channel) else {
            let valid = CurveChannel.allCases.map(\.rawValue).joined(separator: ", ")
            return .error("unknown curve channel '\(channel)'; expected one of: \(valid)")
        }
        // Expect `[[x, y], …]` or `[{"x":…,"y":…}, …]`. Try array-of-pairs first
        // (the canonical wire form), fall back to CGPoint dictionaries.
        let points: [CGPoint]
        let data = Data(pointsJSON.utf8)
        if let pairs = try? JSONDecoder().decode([[Double]].self, from: data) {
            points = pairs.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: pair[0], y: pair[1])
            }
            if points.count != pairs.count {
                return .error("invalid curve points: each entry must be a [x, y] pair")
            }
        } else if let decoded = try? JSONDecoder().decode([CGPoint].self, from: data) {
            points = decoded
        } else {
            return .error("invalid curve points JSON: expected an array of [x, y] pairs")
        }

        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.setCurvePoints(curveChannel, points: points)
        }
        return .ok()
    }

    private func handleResetCurve(assetId: UUID, channel: String) async -> Response {
        guard let curveChannel = DevelopViewModel.curveChannel(named: channel) else {
            let valid = CurveChannel.allCases.map(\.rawValue).joined(separator: ", ")
            return .error("unknown curve channel '\(channel)'; expected one of: \(valid)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.resetCurve(curveChannel)
        }
        return .ok()
    }

    private func handleSelectCurveChannel(channel: String) async -> Response {
        guard let curveChannel = DevelopViewModel.curveChannel(named: channel) else {
            let valid = CurveChannel.allCases.map(\.rawValue).joined(separator: ", ")
            return .error("unknown curve channel '\(channel)'; expected one of: \(valid)")
        }
        await MainActor.run {
            developViewModel.selectedCurveChannel = curveChannel
        }
        return .ok()
    }

    private func handleResetEditParameter(assetId: UUID, parameter: String) async -> Response {
        guard let keyPath = DevelopViewModel.keyPath(forParameter: parameter) else {
            return .error("unknown parameter: \(parameter)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.resetParameter(keyPath)
        }
        return .ok()
    }

    private func handleSetEditFlag(assetId: UUID, parameter: String, value: Bool) async -> Response {
        guard let keyPath = DevelopViewModel.keyPath(forFlag: parameter) else {
            return .error("unknown flag: \(parameter)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.setFlag(keyPath, value: value)
        }
        return .ok()
    }

    private func handleResetEditFlag(assetId: UUID, parameter: String) async -> Response {
        guard let keyPath = DevelopViewModel.keyPath(forFlag: parameter) else {
            return .error("unknown flag: \(parameter)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.resetFlag(keyPath)
        }
        return .ok()
    }

    private func handleSetEditArrayParameter(
        assetId: UUID,
        parameter: String,
        index: Int,
        value: Double
    ) async -> Response {
        guard let axis = DevelopViewModel.hslAxis(forParameter: parameter) else {
            return .error("unknown parameter: \(parameter)")
        }
        guard (0..<8).contains(index) else {
            return .error("index out of range: \(index) (expected 0…7)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.setHSLParameter(axis: axis, rangeIndex: index, value: value)
        }
        return .ok()
    }

    private func handleResetEditArrayParameter(
        assetId: UUID,
        parameter: String,
        index: Int
    ) async -> Response {
        guard let axis = DevelopViewModel.hslAxis(forParameter: parameter) else {
            return .error("unknown parameter: \(parameter)")
        }
        guard (0..<8).contains(index) else {
            return .error("index out of range: \(index) (expected 0…7)")
        }
        let alreadyActive: Bool = await MainActor.run {
            if developViewModel.currentAssetId != assetId {
                router.route = .develop
                return false
            }
            return true
        }
        if !alreadyActive {
            await developViewModel.activate(assetId: assetId)
        }
        await MainActor.run {
            developViewModel.resetHSLParameter(axis: axis, rangeIndex: index)
        }
        return .ok()
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Menu inspection

    @MainActor
    private func handleInspectMenu(title: String) async -> Response {
        guard let mainMenu = NSApplication.shared.mainMenu else {
            return .error("main menu is not available")
        }
        guard let topItem = mainMenu.items.first(where: { $0.title == title }),
              let submenu = topItem.submenu else {
            return .error("menu '\(title)' not found")
        }
        // We report whatever NSMenuItem.isEnabled SwiftUI rendered into
        // the menu — that's exactly what the user would see if they
        // opened the menu right now. Note that in harness mode SwiftUI
        // does not re-render `.commands` on every `@Published` change
        // (the scene needs an active UI cycle), so the dynamic flip is
        // only observable at scene creation — see the docstring on
        // `harness-multi-select-delete-flow.sh` for the regression
        // story that drives the trade-off.
        let items: [AnyCodableValue] = submenu.items.map { item in
            .dictionary([
                "title": .string(item.title),
                "keyEquivalent": .string(item.keyEquivalent),
                "modifierMask": .int(Int(item.keyEquivalentModifierMask.rawValue)),
                "isEnabled": .bool(item.isEnabled),
                "isSeparator": .bool(item.isSeparatorItem),
            ])
        }
        return .ok(data: .dictionary([
            "title": .string(title),
            "items": .array(items),
        ]))
    }

    @MainActor
    private func captureScreenshot(to path: String) async -> Response {
        // Wait up to 5 seconds for a window to appear
        var window: NSWindow?
        for _ in 0..<50 {
            window = NSApplication.shared.windows.first(where: { $0.contentView != nil })
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard let window, let view = window.contentView else {
            return .error("No window available for screenshot")
        }

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return .error("Failed to create bitmap")
        }

        view.cacheDisplay(in: view.bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return .error("Failed to encode PNG")
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: url)
            return .ok()
        } catch {
            return .error("Failed to write screenshot: \(error.localizedDescription)")
        }
    }
}
