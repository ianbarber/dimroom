import AppKit
@testable import Dimroom
import SwiftUI
import TestSupport
import UI
import XCTest

/// Layer B snapshots for each of the four Settings tabs at fixed
/// window size. Built on `NSHostingView` + `NSBitmapImageRep`, matching
/// the existing `RatingToastSnapshotTests` style so the snapshot
/// machinery is shared.
@MainActor
final class SettingsTabSnapshotTests: XCTestCase {
    private static let snapshotRecordMode: SnapshotTestingConfiguration.Record? = {
        if ProcessInfo.processInfo.environment["DIMROOM_RECORD_SNAPSHOTS"] == "1" {
            return .all
        }
        return nil
    }()

    private func runAssertSnapshot(_ body: () -> Void) {
        if let recordMode = Self.snapshotRecordMode {
            withSnapshotTesting(record: recordMode) {
                body()
            }
        } else {
            body()
        }
    }

    /// Production Settings-window width. Height is intrinsic — driven by
    /// the active tab's content — matching `SettingsRootView`, which now
    /// sizes to fit each tab rather than clamping to a fixed height.
    private static let tabWidth: CGFloat = 520
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    /// Hosts `view` constrained to the production tab width with
    /// content-driven height — the same `fixedSize(vertical:)` the live
    /// `Settings` window relies on — and returns the host laid out at its
    /// measured fitting size. The golden's pixel height therefore equals
    /// the tab's natural content height, so a clipped section (the #262
    /// bug) cannot hide off-frame.
    private func measuredHost(for view: some View) -> (NSHostingView<AnyView>, CGSize) {
        let host = NSHostingView(rootView: AnyView(
            view
                .frame(width: Self.tabWidth)
                .fixedSize(horizontal: false, vertical: true)
        ))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height.rounded(.up)
        let size = CGSize(width: Self.tabWidth, height: height)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return (host, size)
    }

    private func bitmap(of host: NSView, size: CGSize) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            fatalError("Failed to allocate NSBitmapImageRep for snapshot")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let (host, size) = measuredHost(for: view)
        return bitmap(of: host, size: size)
    }

    /// Like `renderFixedPixelImage`, but hosts the view in an offscreen
    /// `NSWindow` first. The bare `NSHostingView.cacheDisplay` path draws
    /// `TabView` chrome blank — the segmented tab bar is backed by
    /// `NSTabView`'s segmented control, which only draws once it lives in
    /// a window. Used by the full-`SettingsRootView` snapshot so the
    /// golden reflects the real tab-bar geometry.
    private func renderWindowImage(for view: some View) -> NSImage {
        let (host, size) = measuredHost(for: view)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // The segmented tab bar (NSSegmentedControl) defers its drawing
        // until the window has gone through a real display cycle, so
        // order the window front and let the runloop turn once before
        // capturing. Without this the bar comes out blank.
        window.orderFrontRegardless()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

        let image = bitmap(of: host, size: size)
        window.orderOut(nil)
        return image
    }

    private func freshStore() -> SettingsStore {
        let suite = "dimroom.settings-snapshot-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    private func disconnectedDriveAuthState() -> DriveAuthState {
        DriveAuthState(client: StubDriveAuth(authenticated: false))
    }

    private func connectedDriveAuthState() async -> DriveAuthState {
        let state = DriveAuthState(client: StubDriveAuth(authenticated: true, email: "test@example.com"))
        await state.hydrate()
        return state
    }

    // MARK: - General

    func test_settings_general() {
        let view = GeneralSettingsTab(
            store: freshStore(),
            libraryLocation: URL(fileURLWithPath: "/Library/Dimroom")
        )
        let image = renderFixedPixelImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Cache

    func test_settings_cache() {
        let view = CacheSettingsTab(
            store: freshStore(),
            onClearOriginals: {},
            onClearPreviews: {}
        )
        let image = renderFixedPixelImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Drive

    func test_settings_drive_disconnected() {
        let view = DriveSettingsTab(
            store: freshStore(),
            driveAuthState: disconnectedDriveAuthState(),
            onConnect: {},
            onDisconnect: {}
        )
        let image = renderFixedPixelImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    func test_settings_drive_connected() async {
        let view = DriveSettingsTab(
            store: freshStore(),
            driveAuthState: await connectedDriveAuthState(),
            onConnect: {},
            onDisconnect: {}
        )
        let image = renderFixedPixelImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Develop

    func test_settings_develop() {
        let view = DevelopSettingsTab(store: freshStore())
        let image = renderFixedPixelImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Full window chrome

    /// Renders the whole `SettingsRootView` — `TabView` segmented bar
    /// included — at the live 520×520 window size with the Drive tab
    /// selected. The per-tab snapshots above render bare tab bodies into
    /// the full frame, so they are optimistic by the tab-bar height; this
    /// golden reflects the true (shorter) content area and proves the
    /// Drive Sync row survives beneath the tab bar in the real window.
    func test_settings_root_chrome_drive() async {
        let view = SettingsRootView(
            store: freshStore(),
            driveAuthState: await connectedDriveAuthState(),
            libraryLocation: URL(fileURLWithPath: "/Library/Dimroom"),
            onConnectDrive: {},
            onDisconnectDrive: {},
            onClearOriginalsCache: {},
            onClearPreviewCache: {},
            initialTab: .drive
        )
        let image = renderWindowImage(for: view)
        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }
}

/// Stub authenticator that satisfies the `DriveAuthState(client:)`
/// initialiser without making real Google traffic.
private struct StubDriveAuth: DriveAuthenticating {
    let authenticated: Bool
    var email: String?
    var isAuthenticated: Bool { get async { authenticated } }
    var authFailures: AsyncStream<Void> { AsyncStream { $0.finish() } }
    func authenticate() async throws {}
    func deauthenticate() async throws {}
    func fetchAccountEmail() async throws -> String? { email }

    init(authenticated: Bool, email: String? = nil) {
        self.authenticated = authenticated
        self.email = email
    }
}
