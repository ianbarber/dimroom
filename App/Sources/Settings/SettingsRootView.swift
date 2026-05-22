import SwiftUI
import UI

/// Top-level Settings window content. Four tabs, one per logical
/// section. Held by SwiftUI's `Settings` scene which auto-attaches the
/// Cmd+Comma shortcut.
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var driveAuthState: DriveAuthState
    let libraryLocation: URL?
    let onConnectDrive: () -> Void
    let onDisconnectDrive: () -> Void
    let onClearOriginalsCache: () -> Void
    let onClearPreviewCache: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(
                store: store,
                libraryLocation: libraryLocation
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            CacheSettingsTab(
                store: store,
                onClearOriginals: onClearOriginalsCache,
                onClearPreviews: onClearPreviewCache
            )
            .tabItem { Label("Cache", systemImage: "internaldrive") }

            DriveSettingsTab(
                store: store,
                driveAuthState: driveAuthState,
                onConnect: onConnectDrive,
                onDisconnect: onDisconnectDrive
            )
            .tabItem { Label("Drive", systemImage: "icloud") }

            DevelopSettingsTab(store: store)
                .tabItem { Label("Develop", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 520, height: 360)
    }
}
