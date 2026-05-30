import SwiftUI
import UI

/// Top-level Settings window content. Four tabs, one per logical
/// section. Held by SwiftUI's `Settings` scene which auto-attaches the
/// Cmd+Comma shortcut.
struct SettingsRootView: View {
    /// Identifies each Settings tab so the `TabView` selection can be
    /// seeded. Used by snapshot tests to render a specific tab (e.g.
    /// Drive) within the real `TabView` chrome.
    enum Tab: Hashable {
        case general
        case cache
        case drive
        case develop
    }

    @ObservedObject var store: SettingsStore
    @ObservedObject var driveAuthState: DriveAuthState
    let libraryLocation: URL?
    let onConnectDrive: () -> Void
    let onDisconnectDrive: () -> Void
    let onClearOriginalsCache: () -> Void
    let onClearPreviewCache: () -> Void

    @State private var selection: Tab

    init(
        store: SettingsStore,
        driveAuthState: DriveAuthState,
        libraryLocation: URL?,
        onConnectDrive: @escaping () -> Void,
        onDisconnectDrive: @escaping () -> Void,
        onClearOriginalsCache: @escaping () -> Void,
        onClearPreviewCache: @escaping () -> Void,
        initialTab: Tab = .general
    ) {
        self.store = store
        self.driveAuthState = driveAuthState
        self.libraryLocation = libraryLocation
        self.onConnectDrive = onConnectDrive
        self.onDisconnectDrive = onDisconnectDrive
        self.onClearOriginalsCache = onClearOriginalsCache
        self.onClearPreviewCache = onClearPreviewCache
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab(
                store: store,
                libraryLocation: libraryLocation
            )
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Tab.general)

            CacheSettingsTab(
                store: store,
                onClearOriginals: onClearOriginalsCache,
                onClearPreviews: onClearPreviewCache
            )
            .tabItem { Label("Cache", systemImage: "internaldrive") }
            .tag(Tab.cache)

            DriveSettingsTab(
                store: store,
                driveAuthState: driveAuthState,
                onConnect: onConnectDrive,
                onDisconnect: onDisconnectDrive
            )
            .tabItem { Label("Drive", systemImage: "icloud") }
            .tag(Tab.drive)

            DevelopSettingsTab(store: store)
                .tabItem { Label("Develop", systemImage: "slider.horizontal.3") }
                .tag(Tab.develop)
        }
        .frame(width: 520, height: 520)
    }
}
