import Catalog
import Harness
import SwiftUI

@main
struct DimroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(router: appDelegate.router)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = AppRouter()
    private var harnessController: HarnessController?
    private var harnessWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--harness") else { return }

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Create a window explicitly for harness mode so screenshots work
        // even when running as a bare SPM executable without an app bundle.
        if NSApplication.shared.windows.isEmpty {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: ContentView(router: router))
            window.title = "Dimroom"
            window.center()
            window.makeKeyAndOrderFront(nil)
            harnessWindow = window
        }

        let socketPath = ProcessInfo.processInfo.environment["DIMROOM_HARNESS_SOCKET"]
            ?? HarnessServer.defaultSocketPath

        let catalog = loadCatalogIfRequested(from: args)
        let originalsDirectory = resolveOriginalsDirectory()

        let controller = HarnessController(
            router: router,
            catalog: catalog,
            originalsDirectory: originalsDirectory
        )
        do {
            try controller.start(socketPath: socketPath)
            harnessController = controller
            print("[Dimroom] Harness mode active — listening on \(socketPath)")
            if catalog != nil {
                print("[Dimroom] Catalog loaded; originals dir = \(originalsDirectory.path)")
            } else {
                print("[Dimroom] No --fixture-catalog provided; catalog-dependent commands will fail")
            }
        } catch {
            print("[Dimroom] Failed to start harness server: \(error)")
        }
    }

    /// Parses `--fixture-catalog <path>` out of the argument vector and opens
    /// the SQLite file at that path as a `CatalogDatabase`. Returns nil when
    /// the flag is absent or the open fails — the harness surface downgrades
    /// gracefully rather than refusing to launch.
    private func loadCatalogIfRequested(from args: [String]) -> CatalogDatabase? {
        guard let index = args.firstIndex(of: "--fixture-catalog"),
              index + 1 < args.count
        else {
            return nil
        }
        let path = args[index + 1]
        do {
            return try CatalogDatabase(path: path)
        } catch {
            print("[Dimroom] Failed to open fixture catalog at \(path): \(error)")
            return nil
        }
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
