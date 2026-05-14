import AppIcon
import AppKit
import Catalog
import DriveClient
import EditEngine
import Harness
import ImportKit
import Previews
import SwiftUI
import SyncEngine
import UI

@main
struct DimroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                router: appDelegate.router,
                libraryViewModel: appDelegate.libraryViewModel,
                developViewModel: appDelegate.developViewModel,
                importCoordinator: appDelegate.importCoordinator,
                exportCoordinator: appDelegate.exportCoordinator,
                uploadCoordinator: appDelegate.uploadCoordinator,
                undoStack: appDelegate.undoStack,
                catalog: appDelegate.catalog
            )
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Folder...") {
                    appDelegate.importFolderFromMenu()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export...") {
                    NotificationCenter.default.post(name: .showExportSheet, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Connect Google Drive...") {
                    appDelegate.connectGoogleDriveFromMenu()
                }

                Button("Upload Selected to Drive") {
                    appDelegate.uploadSelectedToDriveFromMenu()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Edit Settings") {
                    appDelegate.copyEditSettings()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Paste Edit Settings") {
                    appDelegate.pasteEditSettings(includeCrop: false)
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(appDelegate.editClipboard.isEmpty)

                Button("Paste Edit Settings (All)") {
                    appDelegate.pasteEditSettings(includeCrop: true)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(appDelegate.editClipboard.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                UndoRedoMenuItems(undoStack: appDelegate.undoStack)
            }
            CommandGroup(after: .pasteboard) {
                DeleteMenuItem(
                    libraryViewModel: appDelegate.libraryViewModel,
                    router: appDelegate.router
                )
            }
        }
    }
}

/// A menu-attached key equivalent dispatches Backspace through the
/// menu's responder chain, bypassing the focus bug that made the
/// grid's `onKeyPress(.delete)` beep. Observes the view model and
/// router so enablement tracks selection + mode.
private struct DeleteMenuItem: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let router: AppRouter

    var body: some View {
        Button("Delete Selected") {
            NotificationCenter.default.post(name: .requestDeleteSelected, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(libraryViewModel.selectedAssetIds.isEmpty || router.route != .library)
    }
}

/// Lives as a separate SwiftUI view so it can observe the
/// `UndoStack`'s `@Published` flags and refresh the menu titles /
/// disabled states reactively. Injecting the stack directly into
/// `commands` doesn't pick up `ObservableObject` changes the same way.
private struct UndoRedoMenuItems: View {
    @ObservedObject var undoStack: UndoStack

    var body: some View {
        Button(undoTitle) {
            Task { @MainActor in await undoStack.undo() }
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!undoStack.canUndo)

        Button(redoTitle) {
            Task { @MainActor in await undoStack.redo() }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!undoStack.canRedo)
    }

    private var undoTitle: String {
        if let desc = undoStack.undoDescription {
            return "Undo \(desc)"
        }
        return "Undo"
    }

    private var redoTitle: String {
        if let desc = undoStack.redoDescription {
            return "Redo \(desc)"
        }
        return "Redo"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = AppRouter()
    let importCoordinator = ImportCoordinator()
    let exportCoordinator = ExportCoordinator()
    let uploadCoordinator = UploadCoordinator()
    let editClipboard = EditClipboard()
    /// View model shared between the SwiftUI tree and the harness
    /// controller. Initialised eagerly with an in-memory empty catalog so
    /// the `@main App` scene can read it before `applicationDidFinishLaunching`
    /// runs, then replaced in `applicationDidFinishLaunching` once the
    /// CLI flags are parsed and the real catalog + preview store are
    /// available.
    private(set) var libraryViewModel: LibraryViewModel = LibraryViewModel.empty()
    private(set) var developViewModel: DevelopViewModel = DevelopViewModel.empty()
    /// Shared in-memory undo stack. Rebuilt in
    /// `applicationDidFinishLaunching` once the real catalog is known so
    /// undo writes go against the same backing store the UI reads from.
    private(set) var undoStack: UndoStack = UndoStack.empty()
    private(set) var catalog: CatalogDatabase?
    private var previewStore: PreviewStore?
    private var originalsDirectory: URL?
    private var harnessController: HarnessController?
    private var harnessWindow: NSWindow?
    private var originalsCoordinator: OriginalsCoordinator?
    private var driveClient: DriveClient?
    private var driveUploader: DriveUploader?
    private var catalogPublisher: CatalogPublisher?
    private var catalogUploader: DriveCatalogUploader?
    private var driveFileIdStore: FileSystemDriveFileIdStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        // Always claim regular activation policy so the app gets a Dock
        // icon, its own menu bar, and can become frontmost. Without this,
        // bare SPM executables run as accessory processes.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        } else {
            print("[Dimroom] AppIcon.icns not found in bundle resources")
        }

        let resolvedOriginalsDirectory = resolveOriginalsDirectory()
        let previewCacheDirectory = resolvePreviewCacheDirectory(from: args)
        let resolvedPreviewStore = PreviewStore(cacheDirectory: previewCacheDirectory)

        // Resolve drive client first so restoreIfNeeded can probe Drive
        // before the catalog is opened.
        let resolvedDriveClient = resolveDriveClient()
        self.driveClient = resolvedDriveClient

        let catalogPath = resolveCatalogPath(from: args)
        let fileIdStore = FileSystemDriveFileIdStore(
            path: FileSystemDriveFileIdStore.defaultPath()
        )
        self.driveFileIdStore = fileIdStore

        attemptCatalogRestore(
            catalogPath: catalogPath,
            driveClient: resolvedDriveClient,
            fileIdStore: fileIdStore
        )

        let resolvedCatalog = openCatalog(at: catalogPath)
        self.catalog = resolvedCatalog
        self.previewStore = resolvedPreviewStore
        self.originalsDirectory = resolvedOriginalsDirectory

        // Reconfigure the existing view model with the real catalog so
        // the SwiftUI view tree — which already holds a reference to this
        // instance — picks up the change. Creating a new instance here
        // would leave the views observing the old (empty) placeholder.
        if let resolvedCatalog {
            libraryViewModel.configure(
                catalog: resolvedCatalog,
                previewStore: resolvedPreviewStore
            )
            developViewModel.configure(
                catalog: resolvedCatalog,
                previewStore: resolvedPreviewStore
            )
            undoStack.configure(
                catalog: resolvedCatalog,
                libraryViewModel: libraryViewModel
            )
            undoStack.attach(developViewModel: developViewModel)
            libraryViewModel.undoStack = undoStack
            developViewModel.attach(undoStack: undoStack)
        }

        if let resolvedCatalog {
            let cacheDir = resolveOriginalsCacheDirectory(from: args)
            let budget = resolveOriginalsCacheBudget()
            let downloader: OriginalsDownloader = resolveHarnessDownloader()
                ?? resolvedDriveClient
                ?? UnavailableOriginalsDownloader()
            let coordinator = OriginalsCoordinator(catalog: resolvedCatalog)
            if let cache = try? OriginalsCache(
                directory: cacheDir,
                budgetBytes: budget,
                downloader: downloader,
                onEvict: { [weak coordinator] id in
                    coordinator?.handleEviction(assetId: id)
                }
            ) {
                coordinator.attach(cache: cache)
                libraryViewModel.originalFetcher = coordinator
                originalsCoordinator = coordinator
            }
        }

        if let resolvedDriveClient {
            let httpClient = URLSessionHTTPClient()
            let session = AuthorizedSession(client: httpClient, provider: resolvedDriveClient)
            let resolver = DriveFolderResolver(session: session)
            self.driveUploader = DriveUploader(session: session, folderResolver: resolver)

            // Catalog publisher reuses the same authorized session +
            // folder resolver but talks through a catalog-specific
            // uploader (overwrite-in-place, no dedup).
            if let resolvedCatalog {
                let catalogUploader = DriveCatalogUploader(
                    session: session,
                    folderResolver: resolver
                )
                self.catalogUploader = catalogUploader
                let publisher = CatalogPublisher(
                    catalog: resolvedCatalog,
                    uploader: catalogUploader,
                    fileIdStore: driveFileIdStore ?? FileSystemDriveFileIdStore(
                        path: FileSystemDriveFileIdStore.defaultPath()
                    )
                )
                self.catalogPublisher = publisher
                // Wire onChange → debouncer trigger. Captured weakly so
                // the catalog doesn't pin the publisher in a retain
                // cycle after the app shuts down.
                resolvedCatalog.onChange = { [weak publisher] in
                    publisher?.scheduleDebouncedPublish()
                }
                Task { await publisher.start() }
            }
        }

        guard args.contains("--harness") else { return }

        // Create a window explicitly for harness mode so screenshots work
        // even when running as a bare SPM executable without an app bundle.
        if NSApplication.shared.windows.isEmpty {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(
                rootView: ContentView(
                    router: router,
                    libraryViewModel: libraryViewModel,
                    developViewModel: developViewModel,
                    importCoordinator: importCoordinator,
                    exportCoordinator: exportCoordinator,
                    uploadCoordinator: uploadCoordinator,
                    undoStack: undoStack,
                    catalog: resolvedCatalog
                )
            )
            window.title = "Dimroom"
            window.center()
            window.makeKeyAndOrderFront(nil)
            harnessWindow = window
        }

        let socketPath = ProcessInfo.processInfo.environment["DIMROOM_HARNESS_SOCKET"]
            ?? HarnessServer.defaultSocketPath

        let controller = HarnessController(
            router: router,
            catalog: resolvedCatalog,
            originalsDirectory: resolvedOriginalsDirectory,
            previewStore: resolvedPreviewStore,
            libraryViewModel: libraryViewModel,
            developViewModel: developViewModel,
            editClipboard: editClipboard,
            exportCoordinator: exportCoordinator,
            uploadCoordinator: uploadCoordinator,
            driveUploader: driveUploader,
            originalsCoordinator: originalsCoordinator,
            undoStack: undoStack,
            catalogPublisher: catalogPublisher
        )
        do {
            try controller.start(socketPath: socketPath)
            harnessController = controller
            print("[Dimroom] Harness mode active — listening on \(socketPath)")
            if resolvedCatalog != nil {
                print("[Dimroom] Catalog loaded; originals dir = \(resolvedOriginalsDirectory.path)")
                print("[Dimroom] Preview cache dir = \(previewCacheDirectory.path)")
            } else {
                print("[Dimroom] No --fixture-catalog provided; catalog-dependent commands will fail")
            }
        } catch {
            print("[Dimroom] Failed to start harness server: \(error)")
        }
    }

    // MARK: - Import from menu

    func importFolderFromMenu() {
        guard !importCoordinator.isActive else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to import photos from"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        guard let catalog, let previewStore, let originalsDirectory else {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = "No catalog is loaded. Launch with --fixture-catalog to enable import."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDirectory)

        Task { @MainActor in
            await importCoordinator.run(
                folderURL: folderURL,
                importer: importer,
                previewStore: previewStore
            )

            switch importCoordinator.phase {
            case .failed(let message):
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = message
                alert.alertStyle = .critical
                alert.runModal()
            case .done:
                Task {
                    await libraryViewModel.setScope(importCoordinator.lastImportSessionId)
                }
            default:
                break
            }
        }
    }

    // MARK: - Drive menu actions

    func connectGoogleDriveFromMenu() {
        guard let driveClient else {
            let alert = NSAlert()
            alert.messageText = "Drive Not Configured"
            alert.informativeText = "Set DIMROOM_GOOGLE_CLIENT_ID or create ~/Library/Application Support/dimroom/oauth.json."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        Task { @MainActor in
            do {
                try await driveClient.authenticate()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Drive Authentication Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func uploadSelectedToDriveFromMenu() {
        guard let catalog else {
            let alert = NSAlert()
            alert.messageText = "Upload Failed"
            alert.informativeText = "No catalog is loaded."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        guard let driveUploader else {
            let alert = NSAlert()
            alert.messageText = "Drive Not Configured"
            alert.informativeText = "Set DIMROOM_GOOGLE_CLIENT_ID or create ~/Library/Application Support/dimroom/oauth.json, then Connect Google Drive…"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let scoped = ExportScope.resolve(
            selectedIds: libraryViewModel.selectedAssetIds,
            rows: libraryViewModel.rows
        )
        guard !scoped.isEmpty else { return }

        Task { @MainActor in
            await uploadCoordinator.run(
                assets: scoped,
                catalog: catalog,
                uploader: driveUploader
            )
            if case .failed(let message) = uploadCoordinator.phase {
                let alert = NSAlert()
                alert.messageText = "Upload Failed"
                alert.informativeText = message
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    // MARK: - Edit copy/paste

    func copyEditSettings() {
        guard let catalog,
              let assetId = libraryViewModel.selectedAssetId else { return }
        do {
            let state = try catalog.latestEditState(for: assetId) ?? EditState()
            editClipboard.copy(state, from: assetId)
        } catch {
            print("[Dimroom] copyEditSettings failed: \(error)")
        }
    }

    func pasteEditSettings(includeCrop: Bool) {
        guard let catalog,
              let assetId = libraryViewModel.selectedAssetId else { return }
        let state: EditState?
        if includeCrop {
            state = editClipboard.pasteIncludingCrop()
        } else {
            state = editClipboard.pasteExcludingCrop()
        }
        guard let state else { return }
        let previous = try? catalog.latestEditState(for: assetId)
        do {
            _ = try catalog.saveEditState(state, for: assetId)
            undoStack.push(.editSave(
                assetId: assetId,
                previous: previous,
                next: state
            ))
            libraryViewModel.reload()
            // Keep the live DevelopViewModel in sync with the catalog
            // write so a subsequent undo has a real starting value to
            // animate from. Without this, VM and catalog diverge and
            // undo's `reloadEditState` reads a state the VM is already
            // at, so `replaySequence` bumps but no slider moves.
            if developViewModel.currentAssetId == assetId {
                Task { @MainActor in
                    await developViewModel.reloadEditState(for: assetId)
                }
            }
        } catch {
            print("[Dimroom] pasteEditSettings failed: \(error)")
        }
    }

    /// Resolves the catalog path from `--fixture-catalog <path>` if
    /// present, otherwise the default location under Application
    /// Support. Returns `nil` only when the parent directory cannot be
    /// created (extremely unlikely).
    private func resolveCatalogPath(from args: [String]) -> String {
        if let index = args.firstIndex(of: "--fixture-catalog"),
           index + 1 < args.count {
            return args[index + 1]
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let catalogDir = appSupport.appendingPathComponent("Dimroom", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: catalogDir,
            withIntermediateDirectories: true
        )
        return catalogDir.appendingPathComponent("catalog.sqlite").path
    }

    /// Opens the catalog at `path`. Returns nil on failure; the caller
    /// surfaces a degraded "no catalog" mode where catalog-dependent
    /// commands respond with an error.
    private func openCatalog(at path: String) -> CatalogDatabase? {
        do {
            return try CatalogDatabase(path: path)
        } catch {
            print("[Dimroom] Failed to open catalog at \(path): \(error)")
            return nil
        }
    }

    /// On a fresh install (no local catalog, Drive authenticated), offer
    /// to restore the most recent catalog from Drive before opening it.
    /// Blocks the launch path so the catalog open below sees the
    /// restored file. The bridge from sync to async uses a semaphore;
    /// it only runs when the local catalog is missing, so the common
    /// launch path is unaffected.
    private func attemptCatalogRestore(
        catalogPath: String,
        driveClient: DriveClient?,
        fileIdStore: DriveFileIdStore
    ) {
        if FileManager.default.fileExists(atPath: catalogPath) { return }
        guard let driveClient else { return }

        let isAuthenticated = Self.runBlocking { await driveClient.isAuthenticated }
        guard isAuthenticated else { return }

        let httpClient = URLSessionHTTPClient()
        let session = AuthorizedSession(client: httpClient, provider: driveClient)
        let resolver = DriveFolderResolver(session: session)
        let uploader = DriveCatalogUploader(session: session, folderResolver: resolver)

        let result: Result<RestoreOutcome, Error> = Self.runBlocking { @Sendable in
            do {
                let outcome = try await CatalogPublisher.restoreIfNeeded(
                    localPath: catalogPath,
                    uploader: uploader,
                    fileIdStore: fileIdStore,
                    prompt: { ref in
                        await MainActor.run { Self.confirmRestore(ref) }
                    }
                )
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case .success(.restored(_, let bytes)):
            print("[Dimroom] catalog restored from Drive (\(bytes) bytes)")
        case .success(.declinedByUser):
            print("[Dimroom] catalog restore declined by user")
        case .success(.noRemoteCatalog),
             .success(.notAuthenticated),
             .success(.localCatalogPresent):
            break
        case .failure(let error):
            print("[Dimroom] catalog restore failed: \(error)")
        }
    }

    /// Synchronously runs an async closure on a detached task and waits
    /// for it. Used during launch where we can't easily make the
    /// surrounding code `async` (NSApplicationDelegate hook). Keep usage
    /// minimal — once-per-launch, off the hot path.
    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            let value = await work()
            box.set(value)
            semaphore.signal()
        }
        semaphore.wait()
        return box.take()
    }

    @MainActor
    private static func confirmRestore(_ ref: CatalogRestorePrompt) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore Catalog From Drive?"
        let sizeMB = Double(ref.sizeBytes) / 1_048_576
        var info = "A catalog was found on Google Drive (\(String(format: "%.1f", sizeMB)) MB)."
        if let modified = ref.modifiedTime {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            info += " Last modified \(formatter.string(from: modified))."
        }
        info += "\n\nDownload it to this machine? Selecting 'Start Fresh' opens an empty local catalog instead."
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Start Fresh")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Parses `--preview-cache <path>` out of the argument vector. Falls
    /// back to a Dimroom-specific subdirectory of Application Support so
    /// running the app without harness flags still works the same as
    /// before.
    private func resolvePreviewCacheDirectory(from args: [String]) -> URL {
        if let index = args.firstIndex(of: "--preview-cache"),
           index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Dimroom", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
    }

    /// Resolves the staging directory for copied originals. The harness flow
    /// overrides the default via `DIMROOM_ORIGINALS_DIR` so tests do not leak
    /// files into the user's Application Support.
    private func resolveOriginalsDirectory() -> URL {
        if let envPath = ProcessInfo.processInfo.environment["DIMROOM_ORIGINALS_DIR"],
           !envPath.isEmpty
        {
            return URL(fileURLWithPath: envPath)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Dimroom", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
    }

    /// Directory used by the LRU originals cache. Defaults to the same
    /// location as the import-staging directory so a freshly copied
    /// original is immediately available to the cache layer without an
    /// extra move. `--originals-cache <path>` overrides for harness/test
    /// runs.
    private func resolveOriginalsCacheDirectory(from args: [String]) -> URL {
        if let index = args.firstIndex(of: "--originals-cache"),
           index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        return resolveOriginalsDirectory()
    }

    /// Byte budget for the originals cache. Defaults to 10 GB; override
    /// via `DIMROOM_ORIGINALS_CACHE_BYTES` for tests.
    private func resolveOriginalsCacheBudget() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["DIMROOM_ORIGINALS_CACHE_BYTES"],
           let value = Int64(raw), value > 0 {
            return value
        }
        return 10 * 1024 * 1024 * 1024
    }

    /// Best-effort `DriveClient` construction: returns `nil` when OAuth
    /// isn't configured so harness runs without credentials don't fail
    /// to launch. The fallback downloader surfaces "unreachable" to the
    /// UI, which is the documented degraded state.
    private func resolveDriveClient() -> DriveClient? {
        guard let config = try? OAuthConfig.load() else { return nil }
        return DriveClient(config: config)
    }

    /// Returns a harness-specific downloader when the env var requests
    /// one, so Layer C flows can drive the determinate-progress overlay
    /// without needing real Drive credentials. Production runs (no env
    /// var) get `nil` and fall through to the regular Drive client.
    private func resolveHarnessDownloader() -> OriginalsDownloader? {
        switch ProcessInfo.processInfo.environment["DIMROOM_HARNESS_STUB_DOWNLOADER"] {
        case "slow-chunks":
            return SlowChunkHarnessDownloader()
        default:
            return nil
        }
    }
}

/// Tiny lock-protected slot used by `AppDelegate.runBlocking` to
/// shuttle a value across the sync/async boundary during launch.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func take() -> T {
        lock.lock(); defer { lock.unlock() }
        return value!
    }
}

/// Downloader used when Drive credentials aren't configured. Always
/// throws `OriginalsCacheError.unreachable`, making the degraded state
/// explicit for Drive-backed assets.
private struct UnavailableOriginalsDownloader: OriginalsDownloader {
    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        throw OriginalsCacheError.unreachable
    }
}

// A LibraryViewModel needs a catalog to be useful, but the `@main`
// `App` struct initialises its delegate property before we've parsed any
// flags. We fall back to an in-memory empty catalog for that early-init
// window; `applicationDidFinishLaunching` replaces it with the real one
// once flags are known.
extension Notification.Name {
    static let showExportSheet = Notification.Name("dimroom.showExportSheet")
    static let requestDeleteSelected = Notification.Name("dimroom.requestDeleteSelected")
}

private extension DevelopViewModel {
    static func empty() -> DevelopViewModel {
        let catalog: CatalogDatabase
        do {
            catalog = try CatalogDatabase.inMemory()
        } catch {
            fatalError("in-memory catalog init failed: \(error)")
        }
        let store = PreviewStore(cacheDirectory: FileManager.default.temporaryDirectory)
        return DevelopViewModel(catalog: catalog, previewStore: store)
    }
}

private extension LibraryViewModel {
    static func empty() -> LibraryViewModel {
        let catalog: CatalogDatabase
        do {
            catalog = try CatalogDatabase.inMemory()
        } catch {
            fatalError("in-memory catalog init failed: \(error)")
        }
        let store = PreviewStore(cacheDirectory: FileManager.default.temporaryDirectory)
        return LibraryViewModel(catalog: catalog, previewStore: store)
    }
}

private extension UndoStack {
    static func empty() -> UndoStack {
        let catalog: CatalogDatabase
        do {
            catalog = try CatalogDatabase.inMemory()
        } catch {
            fatalError("in-memory catalog init failed: \(error)")
        }
        return UndoStack(catalog: catalog)
    }
}
