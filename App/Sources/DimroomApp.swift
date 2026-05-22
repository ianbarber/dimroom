import AppIcon
import AppKit
import Catalog
import Combine
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
                originalFetcher: appDelegate.originalFetcher,
                appDelegate: appDelegate
            )
        }
        Settings {
            SettingsRootView(
                store: appDelegate.settingsStore,
                driveAuthState: appDelegate.driveAuthState,
                libraryLocation: appDelegate.libraryLocationDescription,
                onConnectDrive: { appDelegate.connectGoogleDriveFromMenu() },
                onDisconnectDrive: { appDelegate.disconnectGoogleDriveFromMenu() },
                onClearOriginalsCache: { appDelegate.clearOriginalsCacheFromSettings() },
                onClearPreviewCache: { appDelegate.clearPreviewCacheFromSettings() }
            )
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Folder...") {
                    appDelegate.importFolderFromMenu()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Export...") {
                    ExportLog.logger.info("File → Export menu fired — posting .showExportSheet")
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
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let router = AppRouter()
    let importCoordinator = ImportCoordinator()
    let exportCoordinator = ExportCoordinator()
    let uploadCoordinator = UploadCoordinator()
    let editClipboard = EditClipboard()
    /// Settings-backed configuration store. Initialised eagerly so the
    /// SwiftUI `Settings { ... }` scene — read before
    /// `applicationDidFinishLaunching` runs — has a real instance to
    /// bind to. The store reads `UserDefaults` immediately, so values
    /// the user has previously written are present at launch.
    ///
    /// Honours `--settings-suite <name>` on the command line so the
    /// Layer C harness flow can run against an isolated suite without
    /// touching the user's real preferences plist. Argv is parsed
    /// inline rather than via `ProcessInfo.arguments` only because the
    /// property initialiser runs before `applicationDidFinishLaunching`,
    /// and we need the value before downstream wiring runs.
    let settingsStore: SettingsStore = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--settings-suite"),
           index + 1 < args.count,
           let suite = UserDefaults(suiteName: args[index + 1]) {
            return SettingsStore(defaults: suite)
        }
        return SettingsStore()
    }()
    /// Subscriptions that mirror SettingsStore changes into the
    /// downstream consumers (cache, publisher, view models). Held so
    /// they live for the lifetime of the app delegate.
    private var settingsCancellables: Set<AnyCancellable> = []
    /// Mirror of the SwiftUI `showExportSheet` state owned by `ContentView`.
    /// `ContentView` writes this via `.onChange(of: showExportSheet)` so the
    /// harness can assert the sheet round-tripped through SwiftUI before
    /// firing `completeExportSheet` (#242).
    @Published private(set) var isExportSheetVisible: Bool = false
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
    private var changePoller: ChangePoller?
    private var changePollerEventsTask: Task<Void, Never>?
    private var driveReauthCancellable: AnyCancellable?
    /// Catalog path resolved at launch. Stashed so the harness restore
    /// command can re-run `restoreIfNeeded` against the same local path.
    private var resolvedCatalogPath: String?
    /// Harness-only catalog uploader (resolved from
    /// `DIMROOM_HARNESS_STUB_REMOTE_CATALOG`). Used by the
    /// `restoreCatalogFromDrive` command so Layer C flows don't talk
    /// to Google.
    private var stubCatalogUploader: (any CatalogUploading)?

    /// One-shot flag set by `attemptCatalogRestore` when the launch-time
    /// "Connect Google Drive?" alert returns `true`. Consumed at the
    /// tail of `applicationDidFinishLaunching` to kick off the same menu
    /// Connect flow (#256). Re-entering the restore probe inside the
    /// launch-blocking semaphore is out of scope; the next launch picks
    /// up the refreshed token and restores the catalog normally.
    private var pendingDriveConnectAfterLaunch = false

    /// Public read-only view of the wired-up `OriginalsCoordinator` so
    /// `ContentView` can route export-with-edits through it. Returns
    /// `nil` before `applicationDidFinishLaunching` has wired the
    /// originals cache.
    var originalFetcher: (any OriginalFetcher)? { originalsCoordinator }

    /// Human-friendly path for the read-only "Library location" row in
    /// Settings → General. Falls back to the Application Support path
    /// when launched without a fixture catalog.
    var libraryLocationDescription: URL? {
        if let catalogPathURL = catalogPath { return catalogPathURL.deletingLastPathComponent() }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        return appSupport?.appendingPathComponent("Dimroom", isDirectory: true)
    }

    private var catalogPath: URL?

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

        // Seed the view models with the user-configured initial values
        // before configuring catalog access. Subscriptions below keep
        // them in sync with later changes from the Settings UI.
        libraryViewModel.columnCount = settingsStore.libraryGridColumns
        libraryViewModel.recentImportsLimit = settingsStore.recentImportsLimit
        developViewModel.showHistogram = settingsStore.developHistogramVisible
        developViewModel.renderDebounceMillis = settingsStore.developRenderDebounceMillis
        developViewModel.saveDebounceMillis = settingsStore.developSaveDebounceMillis

        // Resolve drive client first so restoreIfNeeded can probe Drive
        // before the catalog is opened.
        let resolvedDriveClient = resolveDriveClient()
        self.driveClient = resolvedDriveClient

        let catalogPath = resolveCatalogPath(from: args)
        self.catalogPath = URL(fileURLWithPath: catalogPath)
        self.resolvedCatalogPath = catalogPath
        let fileIdStore = FileSystemDriveFileIdStore(
            path: FileSystemDriveFileIdStore.defaultPath()
        )
        self.driveFileIdStore = fileIdStore
        self.stubCatalogUploader = Self.resolveStubCatalogUploader()

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

        // If the user clicked "Connect Google Drive…" on the launch-time
        // restore alert (#256), kick off the same OAuth flow the menu
        // uses. Safe to call here: the launch-blocking semaphore has
        // been released, and `connectGoogleDriveFromMenu()` itself
        // dispatches to `Task { @MainActor in ... }`.
        if Self.consumePendingConnectFlag(&pendingDriveConnectAfterLaunch) {
            connectGoogleDriveFromMenu()
        }

        // Surface stale-token refresh failures (issue #195). When any
        // authorized DriveClient request hits `refreshFailed`, the auth
        // state publishes `needsReauthMessage`. Show a one-shot NSAlert
        // and clear the message so the next failure can re-fire.
        driveReauthCancellable = driveAuthState.$needsReauthMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self, let message else { return }
                self.presentDriveReauthAlert(message: message)
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
                    ),
                    debounceInterval: .seconds(settingsStore.driveAutoPublishDebounceSeconds)
                )
                self.catalogPublisher = publisher
                // Disable up-front if the user has turned auto-publish
                // off in Settings — the start() call below still arms
                // the debouncer so subsequent toggling works, but no
                // mutation will schedule a publish until enabled.
                Task { await publisher.setEnabled(settingsStore.driveAutoPublish) }
                // Wire onChange → debouncer trigger. Captured weakly so
                // the catalog doesn't pin the publisher in a retain
                // cycle after the app shuts down.
                resolvedCatalog.onChange = { [weak publisher] in
                    publisher?.scheduleDebouncedPublish()
                }
                Task { await publisher.start() }

                let fetcher: any DriveChangesFetching
                if let fixturePath = ProcessInfo.processInfo.environment[
                    "DIMROOM_HARNESS_DRIVE_CHANGES_FIXTURE"
                ] {
                    fetcher = HarnessStubChangesFetcher(fixturePath: fixturePath)
                } else {
                    fetcher = DriveChangesClient(session: session)
                }
                let poller = ChangePoller(
                    catalog: resolvedCatalog,
                    fetcher: fetcher,
                    publisher: publisher,
                    fileIdStore: driveFileIdStore ?? FileSystemDriveFileIdStore(
                        path: FileSystemDriveFileIdStore.defaultPath()
                    )
                )
                self.changePoller = poller
                // Harness flows drive `pollOnce()` directly through
                // `syncFromDrive` and the controller encodes the
                // outcome back to the test — racing the periodic loop
                // would make those assertions non-deterministic, and
                // an NSAlert on a poll-driven tick would block the
                // harness socket.
                if !args.contains("--harness") {
                    // Subscribe before start() so we don't miss the
                    // bootstrap event from the periodic loop's first
                    // tick.
                    changePollerEventsTask = Task { @MainActor [weak self] in
                        let stream = await poller.events()
                        for await outcome in stream {
                            self?.handleDeltaSyncOutcome(outcome)
                        }
                    }
                    Task { await poller.start() }
                }
            }
        }

        // Wire SettingsStore changes into the downstream consumers so
        // moving a slider in Settings → Cache / Drive / Develop /
        // Library takes effect immediately, without restart.
        wireSettingsSubscriptions()

        // Handing the harness controller a Settings handle lets Layer C
        // flows round-trip getSetting/setSetting through the same
        // store the UI binds to.
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
                    originalFetcher: originalsCoordinator,
                    appDelegate: self
                )
            )
            window.title = "Dimroom"
            window.center()
            window.makeKeyAndOrderFront(nil)
            harnessWindow = window
        }

        let socketPath = ProcessInfo.processInfo.environment["DIMROOM_HARNESS_SOCKET"]
            ?? HarnessServer.defaultSocketPath

        let restoreUploader: (any CatalogUploading)? = stubCatalogUploader ?? catalogUploader
        let tokenStoreKind = Self.chooseTokenStoreKind(
            args: args,
            env: ProcessInfo.processInfo.environment
        ).rawValue
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
            appDelegate: self,
            driveUploader: driveUploader,
            originalsCoordinator: originalsCoordinator,
            undoStack: undoStack,
            catalogPublisher: catalogPublisher,
            driveAuthState: driveAuthState,
            settingsStore: settingsStore,
            changePoller: changePoller,
            catalogRestoreUploader: restoreUploader,
            catalogRestorePath: catalogPath,
            catalogRestoreFileIdStore: fileIdStore,
            tokenStoreKind: tokenStoreKind
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

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let poller = changePoller else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--harness") { return }
        Task { await poller.start() }
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard let poller = changePoller else { return }
        Task { await poller.stop() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        changePollerEventsTask?.cancel()
        if let poller = changePoller {
            Task { await poller.stop() }
        }
    }

    // MARK: - Export

    /// Updates the sheet-visibility mirror so the harness flow can
    /// assert the sheet was actually mounted by SwiftUI before firing
    /// `completeExportSheet`. Called from `ContentView.onChange`.
    func setExportSheetVisible(_ visible: Bool) {
        ExportLog.logger.info("AppDelegate.setExportSheetVisible(\(visible, privacy: .public))")
        isExportSheetVisible = visible
    }

    /// Single entry point for kicking off an export. Both the SwiftUI
    /// sheet's `onExport` closure and the harness `completeExportSheet`
    /// command call this so a regression in either path is caught by
    /// the same harness flow. Previously the two paths each held their
    /// own copy of the `ExportScope.resolve(...) → coordinator.run(...)`
    /// chain; #242 collapses them.
    func startExport(
        destinationURL: URL,
        format: ExportFormat,
        jpegQuality: Int,
        applyEdits: Bool
    ) async {
        ExportLog.logger.info("AppDelegate.startExport entered — destination=\(destinationURL.path, privacy: .public) format=\(format.rawValue, privacy: .public) applyEdits=\(applyEdits, privacy: .public)")
        guard let catalog else {
            ExportLog.logger.error("AppDelegate.startExport aborted: no catalog loaded")
            return
        }
        let scoped = ExportScope.resolve(
            selectedIds: libraryViewModel.selectedAssetIds,
            rows: libraryViewModel.rows
        )
        ExportLog.logger.info("AppDelegate.startExport scope resolved — count=\(scoped.count, privacy: .public) selectedIds=\(self.libraryViewModel.selectedAssetIds.count, privacy: .public) rows=\(self.libraryViewModel.rows.count, privacy: .public)")
        await exportCoordinator.run(
            assets: scoped,
            catalog: catalog,
            format: format,
            jpegQuality: jpegQuality,
            applyEdits: applyEdits,
            destinationDirectory: destinationURL,
            originalFetcher: originalsCoordinator
        )
        ExportLog.logger.info("AppDelegate.startExport coordinator returned — phase=\(String(describing: self.exportCoordinator.phase), privacy: .public)")
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

    /// Routes a `DeltaSyncOutcome` from the periodic poller into the UI.
    /// Bootstrap and steady-state results are silent; a catalog change
    /// surfaces a reload prompt; a conflict surfaces a warning alert.
    /// Reload-in-place is deferred to a follow-up — for now the alert
    /// just tells the user to relaunch (see issue #235 risks).
    func handleDeltaSyncOutcome(_ outcome: DeltaSyncOutcome) {
        switch outcome {
        case .bootstrapped, .noChanges, .originalsChangedOnly:
            return
        case .catalogChanged(_, let modifiedTime, _):
            presentCatalogChangedAlert(modifiedTime: modifiedTime)
        case .conflict(let localPending, _, _, _):
            presentSyncConflictAlert(localPending: localPending)
        }
    }

    private func presentCatalogChangedAlert(modifiedTime: String?) {
        let alert = NSAlert()
        alert.messageText = "Catalog Updated on Google Drive"
        var info = "Another machine published a newer catalog."
        if let modifiedTime {
            info += " Last modified \(modifiedTime)."
        }
        info += "\n\nRelaunch Dimroom to pick up the changes."
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func presentSyncConflictAlert(localPending: Bool) {
        let alert = NSAlert()
        alert.messageText = "Drive Sync Conflict"
        var info = "Both this catalog and the copy on Drive have changed since the last sync."
        if localPending {
            info += " You have local edits that haven't been published yet."
        }
        info += "\n\nLast-write-wins: the next publish will overwrite the remote catalog."
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    /// Shows a one-shot alert when a DriveClient operation has failed
    /// to refresh — typically a stale or revoked token. Default action
    /// re-runs the menu Connect flow; cancel just dismisses. The
    /// message is cleared regardless so a future failure can re-fire.
    private func presentDriveReauthAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Google Drive Disconnected"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reconnect…")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        driveAuthState.clearNeedsReauthMessage()
        if response == .alertFirstButtonReturn {
            connectGoogleDriveFromMenu()
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

    /// On a fresh install (no local catalog), offer to restore the most
    /// recent catalog from Drive before opening it. Three branches:
    ///
    ///   - **Authenticated**: probe Drive, prompt + restore (or "Start
    ///     Fresh").
    ///   - **Not authenticated**: show a "Connect Google Drive?" alert
    ///     that re-runs the probe once auth lands, or starts fresh.
    ///   - **Restore failed**: show a "Restore Failed" alert offering
    ///     a fresh-start fallback (deletes any half-written file).
    ///
    /// Blocks the launch path so the catalog open below sees the
    /// restored file. The bridge from sync to async uses a semaphore;
    /// it only runs when the local catalog is missing, so the common
    /// launch path is unaffected.
    private func attemptCatalogRestore(
        catalogPath: String,
        driveClient: DriveClient?,
        fileIdStore: DriveFileIdStore
    ) {
        let localCatalogPresent = FileManager.default.fileExists(atPath: catalogPath)
        let stubUploader = self.stubCatalogUploader
        let isAuthenticated: Bool = {
            guard !localCatalogPresent, stubUploader == nil, let driveClient else {
                return false
            }
            return Self.runBlocking { await driveClient.isAuthenticated }
        }()

        let decision = Self.launchRestoreDecision(
            localCatalogPresent: localCatalogPresent,
            hasStubUploader: stubUploader != nil,
            hasDriveClient: driveClient != nil,
            isAuthenticated: isAuthenticated
        )

        let uploader: (any CatalogUploading)?
        switch decision {
        case .skipLocalPresent:
            return
        case .offerConnectNoAuth:
            // No Drive auth available — offer connect-or-skip alert.
            // Skipping just returns and the empty local catalog is
            // created below. The "Connect" path stashes a one-shot
            // flag; the consumer at the tail of
            // `applicationDidFinishLaunching` kicks off the menu
            // Connect flow once the launch-blocking semaphore has
            // been released (#256).
            if Self.offerConnectForRestore() {
                pendingDriveConnectAfterLaunch = true
            }
            return
        case .attemptRestoreWithStub:
            uploader = stubUploader
        case .attemptRestoreWithDrive:
            guard let driveClient else { return }
            let httpClient = URLSessionHTTPClient()
            let session = AuthorizedSession(client: httpClient, provider: driveClient)
            let resolver = DriveFolderResolver(session: session)
            uploader = DriveCatalogUploader(session: session, folderResolver: resolver)
        }

        guard let uploader else { return }

        // `runBlocking` parks the main thread on a semaphore. The
        // prompt callback therefore cannot `await MainActor.run { ... }`
        // — that hop deadlocks because Main is the thread we're parked
        // on. When a harness env var pre-answers the prompt we short-
        // circuit to a plain boolean and skip the MainActor hop. The
        // interactive path still goes via MainActor (real users have a
        // main run loop running, not a launch-blocking semaphore).
        let result: Result<RestoreOutcome, Error> = Self.runBlocking { @Sendable in
            do {
                let outcome = try await CatalogPublisher.restoreIfNeeded(
                    localPath: catalogPath,
                    uploader: uploader,
                    fileIdStore: fileIdStore,
                    prompt: { prompt in
                        if Self.shouldAutoConfirmRestorePrompt() {
                            return Self.harnessAutoConfirmValue()
                        }
                        return await MainActor.run { Self.confirmRestore(prompt) }
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
            // Remove any half-written file before falling back to a
            // fresh-start catalog, otherwise the next `openCatalog`
            // call would see a corrupt SQLite file and degrade.
            try? FileManager.default.removeItem(atPath: catalogPath)
            let reason = (error as? SyncEngineError).map(Self.describeRestoreError)
                ?? String(describing: error)
            _ = Self.offerFreshStartAfterFailure(reason: reason)
        }
    }

    private static func describeRestoreError(_ error: SyncEngineError) -> String {
        switch error {
        case .restoreFailed(let underlying), .uploadFailed(let underlying),
             .snapshotFailed(let underlying), .fileIdStoreFailed(let underlying),
             .changesFetchFailed(let underlying), .pageTokenStoreFailed(let underlying):
            return underlying
        case .notAuthenticated:
            return "Not authenticated"
        }
    }

    /// Pure decision tree for the launch-time catalog-restore branch
    /// (#234). Extracted so the alert routing can be tested without
    /// launching the app — see `App/Tests/CatalogRestoreDecisionTests`.
    /// Maps the four input bits to the alert/path that should fire:
    ///
    ///   - `skipLocalPresent` — local catalog already exists.
    ///   - `attemptRestoreWithStub` — harness env var supplied a local
    ///     fixture; restore from it.
    ///   - `attemptRestoreWithDrive` — real `DriveClient` is authed;
    ///     probe Drive.
    ///   - `offerConnectNoAuth` — no stub and no usable auth; show the
    ///     "Connect Google Drive?" alert.
    enum LaunchRestoreDecision: Equatable {
        case skipLocalPresent
        case attemptRestoreWithStub
        case attemptRestoreWithDrive
        case offerConnectNoAuth
    }

    nonisolated static func launchRestoreDecision(
        localCatalogPresent: Bool,
        hasStubUploader: Bool,
        hasDriveClient: Bool,
        isAuthenticated: Bool
    ) -> LaunchRestoreDecision {
        if localCatalogPresent { return .skipLocalPresent }
        if hasStubUploader { return .attemptRestoreWithStub }
        if hasDriveClient, isAuthenticated { return .attemptRestoreWithDrive }
        return .offerConnectNoAuth
    }

    /// Reads `DIMROOM_HARNESS_STUB_REMOTE_CATALOG` and, if set, returns a
    /// `LocalFileStubCatalogUploader` pointing at that path. Used by
    /// Layer C harness flows to simulate "a published catalog exists on
    /// Drive" without real OAuth.
    private static func resolveStubCatalogUploader() -> LocalFileStubCatalogUploader? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DIMROOM_HARNESS_STUB_REMOTE_CATALOG"], !path.isEmpty else {
            return nil
        }
        let photoCount = env["DIMROOM_HARNESS_STUB_REMOTE_CATALOG_PHOTO_COUNT"]
            .flatMap(Int.init)
        return LocalFileStubCatalogUploader(sourcePath: path, photoCount: photoCount)
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
        if Self.shouldAutoConfirmRestorePrompt() {
            return Self.harnessAutoConfirmValue()
        }
        let alert = NSAlert()
        alert.messageText = "Restore Catalog From Drive?"
        let view = CatalogRestorePromptView(
            style: .restoreExisting(
                photoCount: ref.photoCount,
                sizeBytes: ref.sizeBytes,
                modifiedTime: ref.modifiedTime
            )
        )
        alert.informativeText = view.body(now: Date())
        alert.accessoryView = NSHostingView(rootView: view)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Start Fresh")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Alert shown when the local catalog is missing and Drive auth is
    /// not configured. Returns `true` when the user picks
    /// "Connect Google Drive…", which the caller turns into a one-shot
    /// flag consumed at the tail of `applicationDidFinishLaunching`
    /// (post-semaphore) — that flag triggers the same OAuth flow as
    /// the Drive menu's Connect item (#256). The next launch picks up
    /// the refreshed token and restores the catalog normally.
    @MainActor
    @discardableResult
    private static func offerConnectForRestore() -> Bool {
        if Self.shouldAutoConfirmConnectForRestorePrompt() {
            return Self.harnessConnectForRestoreValue()
        }
        if Self.shouldAutoConfirmRestorePrompt() {
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Connect Google Drive?"
        let view = CatalogRestorePromptView(style: .offerConnect)
        alert.informativeText = view.body(now: Date())
        alert.accessoryView = NSHostingView(rootView: view)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect Google Drive…")
        alert.addButton(withTitle: "Start Fresh")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Alert shown when `restoreIfNeeded` threw. Confirms a fresh local
    /// catalog so the caller can drop the partial file and proceed.
    @MainActor
    @discardableResult
    private static func offerFreshStartAfterFailure(reason: String) -> Bool {
        if Self.shouldAutoConfirmRestorePrompt() {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Restore Failed"
        let view = CatalogRestorePromptView(style: .restoreFailed(reason: reason))
        alert.informativeText = view.body(now: Date())
        alert.accessoryView = NSHostingView(rootView: view)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start Fresh")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
            // User opted out of starting fresh — exit so they don't get
            // a degraded "no catalog" mode they didn't ask for.
            NSApplication.shared.terminate(nil)
        }
        return response == .alertFirstButtonReturn
    }

    /// Harness flows can pre-answer launch-time prompts via env vars so
    /// the modal NSAlerts don't block headless runs. The default
    /// "restore" prompt auto-confirms (matches the Layer C flow that
    /// asserts the restored state); flip via env var to drive declines.
    /// Called from the detached restore task as well as MainActor —
    /// keep nonisolated so the harness short-circuit doesn't have to
    /// hop into MainActor (which deadlocks under launch-time
    /// runBlocking — see `attemptCatalogRestore`).
    nonisolated static func shouldAutoConfirmRestorePrompt() -> Bool {
        ProcessInfo.processInfo.environment["DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE"] != nil
    }

    nonisolated static func harnessAutoConfirmValue() -> Bool {
        // `1`/`true`/`yes` → confirm; any other non-empty value → decline.
        guard let raw = ProcessInfo.processInfo.environment["DIMROOM_HARNESS_AUTO_CONFIRM_RESTORE"] else {
            return true
        }
        switch raw.lowercased() {
        case "0", "false", "no", "decline": return false
        default: return true
        }
    }

    /// Sibling of `shouldAutoConfirmRestorePrompt` for the connect-or-skip
    /// alert (#256). Lets Layer C flows pre-answer the launch-time
    /// "Connect Google Drive?" prompt without showing a modal NSAlert.
    /// Values: `connect` → click Connect, `skip` → click Start Fresh.
    nonisolated static func shouldAutoConfirmConnectForRestorePrompt() -> Bool {
        ProcessInfo.processInfo.environment["DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE"] != nil
    }

    nonisolated static func harnessConnectForRestoreValue() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE"] else {
            return false
        }
        switch raw.lowercased() {
        case "connect", "1", "true", "yes": return true
        default: return false
        }
    }

    /// One-shot read-and-clear for the pending Drive-connect flag.
    /// Extracted as a `nonisolated static` helper so the set/consume
    /// semantics can be pinned by a Layer A test without spinning up
    /// `NSApplication` — see `PendingDriveConnectAtLaunchTests`.
    nonisolated static func consumePendingConnectFlag(_ flag: inout Bool) -> Bool {
        let was = flag
        flag = false
        return was
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

    /// Byte budget for the originals cache. `DIMROOM_ORIGINALS_CACHE_BYTES`
    /// still wins so harness flows can pin a tiny value deterministically;
    /// outside the harness the SettingsStore value is honoured.
    private func resolveOriginalsCacheBudget() -> Int64 {
        if let raw = ProcessInfo.processInfo.environment["DIMROOM_ORIGINALS_CACHE_BYTES"],
           let value = Int64(raw), value > 0 {
            return value
        }
        return settingsStore.originalsCacheBudgetBytes
    }

    /// Best-effort `DriveClient` construction: returns `nil` when OAuth
    /// isn't configured so harness runs without credentials don't fail
    /// to launch. The fallback downloader surfaces "unreachable" to the
    /// UI, which is the documented degraded state.
    ///
    /// When `DIMROOM_HARNESS_DRIVE_STUB` is set, returns a `DriveClient`
    /// wired against in-memory stubs that drive `authenticate()` /
    /// `fetchAccountEmail()` end-to-end without real Google traffic, so
    /// Layer C flows can exercise the connect path.
    ///
    /// When `DIMROOM_HARNESS_DISABLE_DRIVE` is set (issue #278), returns
    /// `nil` *before* `OAuthConfig.load()` is consulted. This is the
    /// "skip Drive entirely at launch" knob for harness flows that don't
    /// exercise Drive — without it, dev machines with a previously
    /// authenticated keychain entry hang at `attemptCatalogRestore` →
    /// `runBlocking { await driveClient.isAuthenticated }` →
    /// `SecItemCopyMatching` (the keychain prompt can't be served
    /// because Main is parked on the semaphore). `DIMROOM_HARNESS_DRIVE_STUB`
    /// takes precedence so flows that explicitly want a stub client
    /// keep working.
    ///
    /// In `--harness` mode (with or without the stub) the `DriveClient`
    /// is constructed with an `InMemoryTokenStore` so the Keychain is
    /// never touched. SPM debug builds resign on every rebuild, which
    /// invalidates the Keychain ACL and would otherwise pop a password
    /// dialog on every harness run — see #260.
    private func resolveDriveClient() -> DriveClient? {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        switch Self.harnessDriveStrategy(env: env) {
        case .stubClient:
            return makeHarnessStubDriveClient()
        case .disabled:
            return nil
        case .useOAuthConfig:
            guard let config = try? OAuthConfig.load() else { return nil }
            switch Self.chooseTokenStoreKind(args: args, env: env) {
            case .inMemory, .stubInMemory:
                return DriveClient(config: config, tokenStore: InMemoryTokenStore())
            case .keychain:
                return DriveClient(config: config)
            }
        }
    }

    /// Outcome of the harness env-var dispatch inside `resolveDriveClient`.
    /// Extracted so #278's "skip Drive at launch" knob and its precedence
    /// against `DIMROOM_HARNESS_DRIVE_STUB` are pinned in Layer A.
    enum HarnessDriveStrategy: Equatable {
        /// `DIMROOM_HARNESS_DRIVE_STUB` — fake `DriveClient` wired to
        /// in-memory stubs so flows can exercise `authenticate()`.
        case stubClient
        /// `DIMROOM_HARNESS_DISABLE_DRIVE` — return `nil` before
        /// `OAuthConfig.load()` so the keychain probe never fires.
        case disabled
        /// Production path: try `OAuthConfig.load()` and wire a real
        /// `DriveClient` if it succeeds, otherwise `nil`.
        case useOAuthConfig
    }

    nonisolated static func harnessDriveStrategy(env: [String: String]) -> HarnessDriveStrategy {
        if env["DIMROOM_HARNESS_DRIVE_STUB"] != nil { return .stubClient }
        if shouldDisableDriveForHarness(env: env) { return .disabled }
        return .useOAuthConfig
    }

    /// Matches `shouldAutoConfirmRestorePrompt`'s "is set" semantics:
    /// the variable being present in the env (even with an empty value)
    /// is enough to opt in. Pinned by `HarnessDriveDisableTests`.
    nonisolated static func shouldDisableDriveForHarness(
        env: [String: String]
    ) -> Bool {
        env["DIMROOM_HARNESS_DISABLE_DRIVE"] != nil
    }

    private func makeHarnessStubDriveClient() -> DriveClient {
        let config = OAuthConfig(clientID: "harness-stub-client")
        return DriveClient(
            config: config,
            httpClient: HarnessStubHTTPClient(),
            tokenStore: InMemoryTokenStore(),
            browserLauncher: HarnessStubBrowserLauncher()
        )
    }

    // MARK: - Settings → live components

    /// Subscribe to every relevant `@Published` property on
    /// `settingsStore` and forward each change to the matching
    /// downstream component. The reverse direction (UI → store) lives
    /// in the SwiftUI binding inside each tab view.
    private func wireSettingsSubscriptions() {
        settingsStore.$libraryGridColumns
            .dropFirst()
            .sink { [weak self] newValue in
                self?.libraryViewModel.columnCount = newValue
            }
            .store(in: &settingsCancellables)

        settingsStore.$recentImportsLimit
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                self.libraryViewModel.recentImportsLimit = newValue
                self.libraryViewModel.reload()
            }
            .store(in: &settingsCancellables)

        settingsStore.$originalsCacheBudgetBytes
            .dropFirst()
            .sink { [weak self] newValue in
                guard let coordinator = self?.originalsCoordinator else { return }
                Task { await coordinator.setCacheBudget(newValue) }
            }
            .store(in: &settingsCancellables)

        settingsStore.$driveAutoPublish
            .dropFirst()
            .sink { [weak self] newValue in
                guard let publisher = self?.catalogPublisher else { return }
                Task { await publisher.setEnabled(newValue) }
            }
            .store(in: &settingsCancellables)

        settingsStore.$driveAutoPublishDebounceSeconds
            .dropFirst()
            .sink { [weak self] newValue in
                guard let publisher = self?.catalogPublisher else { return }
                Task { await publisher.setDebounceInterval(.seconds(newValue)) }
            }
            .store(in: &settingsCancellables)

        settingsStore.$developHistogramVisible
            .dropFirst()
            .sink { [weak self] newValue in
                // Don't override a live user toggle; only seed the
                // default when no asset is active so a future activation
                // honours the new preference. Active sessions keep
                // whatever the user just chose with the H key.
                guard let self else { return }
                if self.developViewModel.currentAssetId == nil {
                    self.developViewModel.showHistogram = newValue
                }
            }
            .store(in: &settingsCancellables)

        settingsStore.$developRenderDebounceMillis
            .dropFirst()
            .sink { [weak self] newValue in
                self?.developViewModel.renderDebounceMillis = newValue
            }
            .store(in: &settingsCancellables)

        settingsStore.$developSaveDebounceMillis
            .dropFirst()
            .sink { [weak self] newValue in
                self?.developViewModel.saveDebounceMillis = newValue
            }
            .store(in: &settingsCancellables)
    }

    // MARK: - Settings actions

    func clearOriginalsCacheFromSettings() {
        guard let coordinator = originalsCoordinator else { return }
        Task { await coordinator.clearCache() }
    }

    func clearPreviewCacheFromSettings() {
        guard let previewStore else { return }
        Task {
            await previewStore.removeAll()
            await MainActor.run { self.libraryViewModel.reload() }
        }
    }

    /// Pure helper that picks the token store backing `DriveClient`
    /// from the launch arguments and environment. Extracted so Layer A
    /// tests can pin the three branches without instantiating
    /// `DriveClient` (which would touch the real Keychain on the
    /// keychain branch).
    ///
    ///   - no `--harness` → `.keychain` (production OAuth)
    ///   - `--harness` alone → `.inMemory` (real-OAuth-config path in
    ///     a harness run; Keychain skipped to avoid the rebuild-resign
    ///     prompt described in #260)
    ///   - `--harness` + `DIMROOM_HARNESS_DRIVE_STUB` → `.stubInMemory`
    ///     (in-memory + stub HTTPClient + stub browser; the existing
    ///     `harness-drive-auth-flow.sh` path)
    enum TokenStoreKind: String, Equatable {
        case keychain
        case inMemory = "in-memory"
        case stubInMemory = "stub-in-memory"
    }

    nonisolated static func chooseTokenStoreKind(
        args: [String],
        env: [String: String]
    ) -> TokenStoreKind {
        let harness = args.contains("--harness")
        let stub = env["DIMROOM_HARNESS_DRIVE_STUB"] != nil
        if harness && stub { return .stubInMemory }
        if harness { return .inMemory }
        return .keychain
    }

    /// Returns a harness-specific downloader when the env var requests
    /// one, so Layer C flows can drive the determinate-progress overlay
    /// without needing real Drive credentials. Production runs (no env
    /// var) get `nil` and fall through to the regular Drive client.
    private func resolveHarnessDownloader() -> OriginalsDownloader? {
        switch ProcessInfo.processInfo.environment["DIMROOM_HARNESS_STUB_DOWNLOADER"] {
        case "slow-chunks":
            return SlowChunkHarnessDownloader()
        case "hold-until-released":
            return HoldUntilReleasedHarnessDownloader()
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
    var authFailures: AsyncStream<Void> { AsyncStream { $0.finish() } }
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
