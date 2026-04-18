import AppKit
import Catalog
import EditEngine
import Foundation
import Harness
import ImportKit
import Previews
import UI

/// Bridges harness commands to the app's state and AppKit operations.
final class HarnessController: @unchecked Sendable {
    private let router: AppRouter
    private let catalog: CatalogDatabase?
    private let originalsDirectory: URL
    private let previewStore: PreviewStore
    private let libraryViewModel: LibraryViewModel
    private let developViewModel: DevelopViewModel
    private let editClipboard: EditClipboard
    private let exportCoordinator: ExportCoordinator
    private let originalsCoordinator: OriginalsCoordinator?
    private let undoStack: UndoStack?
    private var server: HarnessServer?

    init(
        router: AppRouter,
        catalog: CatalogDatabase?,
        originalsDirectory: URL,
        previewStore: PreviewStore,
        libraryViewModel: LibraryViewModel,
        developViewModel: DevelopViewModel,
        editClipboard: EditClipboard,
        exportCoordinator: ExportCoordinator,
        originalsCoordinator: OriginalsCoordinator? = nil,
        undoStack: UndoStack? = nil
    ) {
        self.router = router
        self.catalog = catalog
        self.originalsDirectory = originalsDirectory
        self.previewStore = previewStore
        self.libraryViewModel = libraryViewModel
        self.developViewModel = developViewModel
        self.editClipboard = editClipboard
        self.exportCoordinator = exportCoordinator
        self.originalsCoordinator = originalsCoordinator
        self.undoStack = undoStack
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
                return AppState(
                    route: router.route,
                    assetCount: libraryViewModel.rows.count,
                    selectedAssetId: libraryViewModel.selectedAssetId,
                    minRating: libraryViewModel.minRating,
                    scopeSessionId: libraryViewModel.scopeSessionId,
                    scopeKind: kind,
                    selectedAssetIds: Array(libraryViewModel.selectedAssetIds),
                    isZoomed: libraryViewModel.isZoomed,
                    hasUndoToast: libraryViewModel.undoToast != nil
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

        case .export(let destinationPath, let format, let applyEdits):
            return await handleExport(destinationPath: destinationPath, format: format, applyEdits: applyEdits)

        case .fetchOriginal(let assetId):
            return await handleFetchOriginal(assetId: assetId)

        case .setEditParameter(let assetId, let parameter, let value):
            return await handleSetEditParameter(assetId: assetId, parameter: parameter, value: value)

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
        }
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
        guard let catalog else {
            return .error("catalog not loaded")
        }
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

        // Selection wins when non-empty; otherwise fall back to all
        // visible rows (which already respect the rating filter and
        // active scope). Same rule as the File → Export… sheet so both
        // entry points agree.
        let assets = await MainActor.run {
            ExportScope.resolve(
                selectedIds: libraryViewModel.selectedAssetIds,
                rows: libraryViewModel.rows
            )
        }

        await exportCoordinator.run(
            assets: assets,
            catalog: catalog,
            format: exportFormat,
            jpegQuality: 85,
            applyEdits: applyEdits,
            destinationDirectory: destinationURL
        )

        let exportedCount: Int
        if case .done(let count) = await exportCoordinator.phase {
            exportedCount = count
        } else {
            exportedCount = 0
        }

        return .ok(data: .dictionary([
            "exportedCount": .int(exportedCount),
            "destinationPath": .string(destinationPath),
        ]))
    }

    // MARK: - List assets

    private func handleListAssets() -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            let assets = try catalog.fetchAssets()
            let array: [AnyCodableValue] = assets.map { asset in
                let captureDate: AnyCodableValue
                if let date = asset.captureDate {
                    captureDate = .string(Self.iso8601.string(from: date))
                } else {
                    captureDate = .null
                }
                return .dictionary([
                    "id": .string(asset.id.uuidString),
                    "originalFilename": .string(asset.originalFilename),
                    "captureDate": captureDate,
                    "rating": .int(asset.rating),
                    "rotation": .int(asset.rotation),
                    "sourceType": .string(asset.sourceType.rawValue),
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

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
