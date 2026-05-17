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

    private static let tabSize = CGSize(width: 520, height: 360)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let size = Self.tabSize
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

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
