import AppKit
import Catalog
import EditEngine
import Harness
import ImportKit
import Previews
import SwiftUI
import UI

@main
struct DimroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                router: appDelegate.router,
                libraryViewModel: appDelegate.libraryViewModel,
                importCoordinator: appDelegate.importCoordinator,
                exportCoordinator: appDelegate.exportCoordinator,
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
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = AppRouter()
    let importCoordinator = ImportCoordinator()
    let exportCoordinator = ExportCoordinator()
    let editClipboard = EditClipboard()
    /// View model shared between the SwiftUI tree and the harness
    /// controller. Initialised eagerly with an in-memory empty catalog so
    /// the `@main App` scene can read it before `applicationDidFinishLaunching`
    /// runs, then replaced in `applicationDidFinishLaunching` once the
    /// CLI flags are parsed and the real catalog + preview store are
    /// available.
    private(set) var libraryViewModel: LibraryViewModel = LibraryViewModel.empty()
    private(set) var catalog: CatalogDatabase?
    private var previewStore: PreviewStore?
    private var originalsDirectory: URL?
    private var harnessController: HarnessController?
    private var harnessWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments

        // Always claim regular activation policy so the app gets a Dock
        // icon, its own menu bar, and can become frontmost. Without this,
        // bare SPM executables run as accessory processes.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let resolvedOriginalsDirectory = resolveOriginalsDirectory()
        let previewCacheDirectory = resolvePreviewCacheDirectory(from: args)
        let resolvedPreviewStore = PreviewStore(cacheDirectory: previewCacheDirectory)
        let resolvedCatalog = loadCatalog(from: args)

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
                    importCoordinator: importCoordinator,
                    exportCoordinator: exportCoordinator,
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
            editClipboard: editClipboard,
            exportCoordinator: exportCoordinator
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
        do {
            _ = try catalog.saveEditState(state, for: assetId)
            libraryViewModel.reload()
        } catch {
            print("[Dimroom] pasteEditSettings failed: \(error)")
        }
    }

    /// Opens the catalog database. Uses `--fixture-catalog <path>` when
    /// present (harness / test mode); otherwise falls back to the default
    /// user catalog at ~/Library/Application Support/Dimroom/catalog.sqlite.
    private func loadCatalog(from args: [String]) -> CatalogDatabase? {
        let path: String
        if let index = args.firstIndex(of: "--fixture-catalog"),
           index + 1 < args.count {
            path = args[index + 1]
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let catalogDir = appSupport.appendingPathComponent("Dimroom", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
            } catch {
                print("[Dimroom] Failed to create catalog directory: \(error)")
                return nil
            }
            path = catalogDir.appendingPathComponent("catalog.sqlite").path
        }
        do {
            return try CatalogDatabase(path: path)
        } catch {
            print("[Dimroom] Failed to open catalog at \(path): \(error)")
            return nil
        }
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
}

// A LibraryViewModel needs a catalog to be useful, but the `@main`
// `App` struct initialises its delegate property before we've parsed any
// flags. We fall back to an in-memory empty catalog for that early-init
// window; `applicationDidFinishLaunching` replaces it with the real one
// once flags are known.
extension Notification.Name {
    static let showExportSheet = Notification.Name("dimroom.showExportSheet")
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
