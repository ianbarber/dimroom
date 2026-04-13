import AppKit
import Catalog
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
    private let editClipboard: EditClipboard
    private var server: HarnessServer?

    init(
        router: AppRouter,
        catalog: CatalogDatabase?,
        originalsDirectory: URL,
        previewStore: PreviewStore,
        libraryViewModel: LibraryViewModel,
        editClipboard: EditClipboard
    ) {
        self.router = router
        self.catalog = catalog
        self.originalsDirectory = originalsDirectory
        self.previewStore = previewStore
        self.libraryViewModel = libraryViewModel
        self.editClipboard = editClipboard
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
                AppState(
                    route: router.route,
                    assetCount: libraryViewModel.rows.count,
                    selectedAssetId: libraryViewModel.selectedAssetId,
                    minRating: libraryViewModel.minRating,
                    scopeSessionId: libraryViewModel.scopeSessionId
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
            return handlePasteEdit(assetId: assetId, includeCrop: includeCrop)

        case .setEdit(let assetId, let stateJSON):
            return handleSetEdit(assetId: assetId, stateJSON: stateJSON)

        case .getEdit(let assetId):
            return handleGetEdit(assetId: assetId)

        case .setScope(let sessionId):
            await libraryViewModel.setScope(sessionId)
            return .ok()

        case .listImportSessions:
            return handleListImportSessions()

        case .selectNext:
            await MainActor.run { libraryViewModel.selectNext() }
            return .ok()

        case .selectPrevious:
            await MainActor.run { libraryViewModel.selectPrevious() }
            return .ok()

        case .zoomToggle:
            await MainActor.run { libraryViewModel.pendingZoomCommand = .toggleFitTo100 }
            return .ok()

        case .zoomReset:
            await MainActor.run { libraryViewModel.pendingZoomCommand = .resetToFit }
            return .ok()
        }
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

    private func handlePasteEdit(assetId: UUID, includeCrop: Bool) -> Response {
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
        do {
            _ = try catalog.saveEditState(state, for: assetId)
            return .ok(data: .dictionary(["pasted": .bool(true)]))
        } catch {
            return .error("pasteEdit failed: \(error.localizedDescription)")
        }
    }

    private func handleSetEdit(assetId: UUID, stateJSON: String) -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            let state = try JSONDecoder().decode(EditState.self, from: Data(stateJSON.utf8))
            _ = try catalog.saveEditState(state, for: assetId)
            return .ok()
        } catch {
            return .error("setEdit failed: \(error.localizedDescription)")
        }
    }

    private func handleGetEdit(assetId: UUID) -> Response {
        guard let catalog else {
            return .error("catalog not loaded")
        }
        do {
            guard let state = try catalog.latestEditState(for: assetId) else {
                return .ok(data: .null)
            }
            let data = try JSONEncoder().encode(state)
            let json = try JSONDecoder().decode(AnyCodableValue.self, from: data)
            return .ok(data: json)
        } catch {
            return .error("getEdit failed: \(error.localizedDescription)")
        }
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
