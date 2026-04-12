import AppKit
import Catalog
import Foundation
import Harness
import ImportKit
import UI

/// Bridges harness commands to the app's state and AppKit operations.
final class HarnessController: @unchecked Sendable {
    private let router: AppRouter
    private let catalog: CatalogDatabase?
    private let originalsDirectory: URL
    private let libraryViewModel: LibraryViewModel
    private var server: HarnessServer?

    init(
        router: AppRouter,
        catalog: CatalogDatabase?,
        originalsDirectory: URL,
        libraryViewModel: LibraryViewModel
    ) {
        self.router = router
        self.catalog = catalog
        self.originalsDirectory = originalsDirectory
        self.libraryViewModel = libraryViewModel
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
                    minRating: libraryViewModel.minRating
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
            return await handleListAssets()

        case .selectAsset(let id):
            await MainActor.run { libraryViewModel.select(id) }
            return .ok()

        case .setRating(let assetId, let rating):
            await libraryViewModel.setRating(for: assetId, to: rating)
            return .ok()

        case .rotate(let assetId):
            await libraryViewModel.rotate(assetId: assetId)
            return .ok()

        case .setFilter(let minRating):
            await libraryViewModel.setMinRating(minRating)
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
        // Refresh the library grid so `state` reflects the new rows.
        // `reloadAndWait` is required (not `reload`) because reload now
        // runs on a background task — the subsequent `state` or `listAssets`
        // command would race with it.
        await libraryViewModel.reloadAndWait()
        return .ok(data: .dictionary([
            "importedCount": .int(result.importedCount),
            "skippedCount": .int(result.skippedCount),
            "sessionId": .string(result.sessionId.uuidString),
        ]))
    }

    // MARK: - List assets

    /// List currently visible assets. Deliberately reads
    /// `libraryViewModel.rows` rather than `catalog.fetchAssets()` so
    /// the active rating filter, sort order, and selection bookkeeping
    /// (all owned by the view model) are reflected in the response.
    /// Stage 2.3's Layer C flow asserts that after `setFilter min=3`
    /// only the rated rows come back — this is what makes that
    /// assertion load-bearing.
    private func handleListAssets() async -> Response {
        let rows = await MainActor.run { libraryViewModel.rows }
        let array: [AnyCodableValue] = rows.map { row in
            let asset = row.asset
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
