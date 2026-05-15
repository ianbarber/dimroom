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
                catalog: appDelegate.catalog,
                originalFetcher: appDelegate.originalFetcher
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

                DriveMenuItems(
                    state: appDelegate.driveAuthState,
                    onConnect: { appDelegate.connectGoogleDriveFromMenu() },
                    onDisconnect: { appDelegate.disconnectGoogleDriveFromMenu() }
                )

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
                SelectAllVisibleMenuItem(
                    libraryViewModel: appDelegate.libraryViewModel,
                    router: appDelegate.router
                )
            }
            CommandMenu("View") {
                ModeMenuItems(router: appDelegate.router)
                Divider()
                ZoomToggleMenuItem(router: appDelegate.router)
                ZoomResetMenuItem(router: appDelegate.router)
                Divider()
                HistogramMenuItem(
                    router: appDelegate.router,
                    developViewModel: appDelegate.developViewModel
                )
            }
            CommandMenu("Image") {
                RotateMenuItems(libraryViewModel: appDelegate.libraryViewModel)
            }
            CommandMenu("Rating") {
                RatingMenuItems(libraryViewModel: appDelegate.libraryViewModel)
            }
            CommandMenu("Navigate") {
                NavigateMenuItems(
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
///
/// Module-internal (not `private`) so `App/Tests` can exercise the
/// `isDisabled` predicate against synthetic view-model + router state
/// — the dynamic-flip seam #208 carves out as a Layer A complement to
/// PR #206's static menu-shape assertion.
struct DeleteMenuItem: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let router: AppRouter

    /// Single source of truth feeding `.disabled(...)` in `body`.
    /// Extracted so a regression that inverts the predicate (e.g.
    /// swapping `isEmpty` for `!isEmpty`, or dropping the scope
    /// clause) is caught by a Layer A test even without an active UI
    /// cycle to flush `.commands` re-renders onto `NSMenuItem`.
    var isDisabled: Bool {
        libraryViewModel.selectedAssetIds.isEmpty
            || router.route != .library
            || libraryViewModel.scope == .recentlyDeleted
    }

    var body: some View {
        Button("Delete Selected") {
            NotificationCenter.default.post(name: .requestDeleteSelected, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(isDisabled)
    }
}

/// Mirrors `UndoRedoMenuItems`: observes `DriveAuthState` so the menu
/// flips between "Connect Google Drive…", "Connecting…", and
/// "Disconnect Google Drive (email)" as the auth status changes. This
/// is the fix for #166 — before this view existed, the menu only knew
/// the static "Connect Google Drive…" string and ignored auth events.
private struct DriveMenuItems: View {
    @ObservedObject var state: DriveAuthState
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        switch state.status {
        case .disconnected:
            Button("Connect Google Drive...") { onConnect() }
        case .connecting:
            Button("Connecting to Google Drive…") { }
                .disabled(true)
        case .connected(let email):
            Button(disconnectTitle(email: email)) { onDisconnect() }
        }
    }

    private func disconnectTitle(email: String?) -> String {
        if let email, !email.isEmpty {
            return "Disconnect Google Drive (\(email))"
        }
        return "Disconnect Google Drive"
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

/// Lightroom-style mode switch — G/E/D as menu-attached key
/// equivalents so the shortcut fires regardless of focus.
private struct ModeMenuItems: View {
    let router: AppRouter

    var body: some View {
        Button("Library") {
            NotificationCenter.default.post(
                name: MenuActionName.modeLibrary.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("g", modifiers: [])

        Button("Loupe") {
            NotificationCenter.default.post(
                name: MenuActionName.modeLoupe.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("e", modifiers: [])

        Button("Develop") {
            NotificationCenter.default.post(
                name: MenuActionName.modeDevelop.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("d", modifiers: [])
    }
}

private struct ZoomToggleMenuItem: View {
    let router: AppRouter

    var body: some View {
        Button("Zoom Fit / 100%") {
            NotificationCenter.default.post(
                name: MenuActionName.zoomToggle.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("z", modifiers: [])
        .disabled(router.route != .loupe)
    }
}

private struct ZoomResetMenuItem: View {
    let router: AppRouter

    var body: some View {
        Button("Zoom to Fit") {
            NotificationCenter.default.post(
                name: MenuActionName.zoomReset.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(router.route != .loupe)
    }
}

private struct HistogramMenuItem: View {
    let router: AppRouter
    @ObservedObject var developViewModel: DevelopViewModel

    var body: some View {
        Button(developViewModel.showHistogram ? "Hide Histogram" : "Show Histogram") {
            NotificationCenter.default.post(
                name: MenuActionName.toggleHistogram.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("h", modifiers: [])
        .disabled(router.route != .develop)
    }
}

private struct RotateMenuItems: View {
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        Button("Rotate Clockwise") {
            NotificationCenter.default.post(
                name: MenuActionName.rotateCW.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(libraryViewModel.selectedAssetId == nil)

        Button("Rotate Counter-Clockwise") {
            NotificationCenter.default.post(
                name: MenuActionName.rotateCCW.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(libraryViewModel.selectedAssetId == nil)
    }
}

private struct RatingMenuItems: View {
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        ForEach(1...5, id: \.self) { star in
            Button("Set Rating \(star)") {
                NotificationCenter.default.post(
                    name: MenuActionName.setRating(star).notificationName,
                    object: nil
                )
            }
            .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: [])
            .disabled(libraryViewModel.selectedAssetId == nil)
        }

        Divider()

        Button("Clear Rating") {
            NotificationCenter.default.post(
                name: MenuActionName.clearRating.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("0", modifiers: [])
        .disabled(libraryViewModel.selectedAssetId == nil)
    }
}

private struct NavigateMenuItems: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let router: AppRouter

    var body: some View {
        Button("Previous") {
            NotificationCenter.default.post(
                name: MenuActionName.selectPrevious.notificationName,
                object: nil
            )
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .disabled(router.route != .library && router.route != .loupe)

        Button("Next") {
            NotificationCenter.default.post(
                name: MenuActionName.selectNext.notificationName,
                object: nil
            )
        }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .disabled(router.route != .library && router.route != .loupe)

        Button("Up") {
            NotificationCenter.default.post(
                name: MenuActionName.selectUp.notificationName,
                object: nil
            )
        }
        .keyboardShortcut(.upArrow, modifiers: [])
        .disabled(router.route != .library)

        Button("Down") {
            NotificationCenter.default.post(
                name: MenuActionName.selectDown.notificationName,
                object: nil
            )
        }
        .keyboardShortcut(.downArrow, modifiers: [])
        .disabled(router.route != .library)
    }
}

private struct SelectAllVisibleMenuItem: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let router: AppRouter

    var body: some View {
        Button("Select All Visible") {
            NotificationCenter.default.post(
                name: MenuActionName.selectAllVisible.notificationName,
                object: nil
            )
        }
        .keyboardShortcut("a", modifiers: .command)
        .disabled(router.route != .library)
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
    /// Observable wrapper around the Drive client's auth state. Created
    /// eagerly with a no-op stub so the SwiftUI `.commands` builder — which
    /// reads it before `applicationDidFinishLaunching` runs — has a real
    /// `ObservableObject` to bind to. Reconfigured with the resolved
    /// `DriveClient` in `applicationDidFinishLaunching` and then hydrated.
    private(set) var driveAuthState: DriveAuthState = DriveAuthState(client: UnconfiguredDriveAuth())
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

    /// Public read-only view of the wired-up `OriginalsCoordinator` so
    /// `ContentView` can route export-with-edits through it. Returns
    /// `nil` before `applicationDidFinishLaunching` has wired the
    /// originals cache.
    var originalFetcher: (any OriginalFetcher)? { originalsCoordinator }

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

        if let resolvedDriveClient {
            driveAuthState.configure(client: resolvedDriveClient)
            // Hydrate from the stored refresh token so the menu reflects
            // the connected state on launch without a re-auth round-trip.
            Task { @MainActor in
                await driveAuthState.hydrate()
            }
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
                developViewModel.attach(originalFetcher: coordinator)
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
                    catalog: resolvedCatalog,
                    originalFetcher: originalsCoordinator
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
            catalogPublisher: catalogPublisher,
            driveAuthState: driveAuthState
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
        guard driveClient != nil else {
            let alert = NSAlert()
            alert.messageText = "Drive Not Configured"
            alert.informativeText = "Set DIMROOM_GOOGLE_CLIENT_ID or create ~/Library/Application Support/dimroom/oauth.json."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        Task { @MainActor in
            await driveAuthState.connect()
            if let message = driveAuthState.lastErrorMessage {
                let alert = NSAlert()
                alert.messageText = "Drive Authentication Failed"
                alert.informativeText = message
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func disconnectGoogleDriveFromMenu() {
        Task { @MainActor in
            await driveAuthState.disconnect()
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

/// Placeholder authenticator used to construct `DriveAuthState` before
/// the real `DriveClient` is resolved (i.e. before
/// `applicationDidFinishLaunching` runs). Always reports unauthenticated;
/// any auth call fails so the UI surfaces "Drive Not Configured" via
/// the alert path. Replaced by the real client in `configure(client:)`.
private struct UnconfiguredDriveAuth: DriveAuthenticating {
    var isAuthenticated: Bool { get async { false } }
    func authenticate() async throws { throw DriveClientError.clientIDNotConfigured }
    func deauthenticate() async throws {}
    func fetchAccountEmail() async throws -> String? { nil }
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

/// Whitelist of menu-attached actions reachable from both the menu bar's
/// keyboard shortcuts and the harness `postMenuAction` command. Defining
/// names here once (rather than as bare strings) means the
/// `HarnessController` and `ContentView` agree on the wire format and
/// notification name without typo risk.
enum MenuActionName: String, CaseIterable {
    case modeLibrary = "mode-library"
    case modeLoupe = "mode-loupe"
    case modeDevelop = "mode-develop"
    case setRating1 = "set-rating-1"
    case setRating2 = "set-rating-2"
    case setRating3 = "set-rating-3"
    case setRating4 = "set-rating-4"
    case setRating5 = "set-rating-5"
    case clearRating = "clear-rating"
    case rotateCW = "rotate-cw"
    case rotateCCW = "rotate-ccw"
    case zoomToggle = "zoom-toggle"
    case zoomReset = "zoom-reset"
    case toggleHistogram = "toggle-histogram"
    case selectNext = "select-next"
    case selectPrevious = "select-previous"
    case selectUp = "select-up"
    case selectDown = "select-down"
    case selectAllVisible = "select-all-visible"

    var notificationName: Notification.Name {
        Notification.Name("dimroom.menuAction.\(rawValue)")
    }

    static func setRating(_ star: Int) -> MenuActionName {
        switch star {
        case 1: return .setRating1
        case 2: return .setRating2
        case 3: return .setRating3
        case 4: return .setRating4
        case 5: return .setRating5
        default: fatalError("setRating only defined for 1...5, got \(star)")
        }
    }
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
