import SwiftUI
import UI

struct DriveSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var driveAuthState: DriveAuthState
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Status") {
                    statusView
                }
                connectionButton
            }

            Section("Catalog publish") {
                Toggle("Auto-publish catalog to Drive", isOn: $store.driveAutoPublish)
                Stepper(
                    "Debounce: \(store.driveAutoPublishDebounceSeconds) s",
                    value: $store.driveAutoPublishDebounceSeconds,
                    in: 5...600
                )
                .disabled(!store.driveAutoPublish)
            }

            Section("Originals") {
                Toggle(
                    "Auto-upload originals after import",
                    isOn: $store.driveAutoUploadOriginals
                )
            }

            Section("Sync") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Poll interval: \(formatSeconds(store.driveSyncPollSeconds))")
                    Slider(
                        value: Binding(
                            get: { Double(store.driveSyncPollSeconds) },
                            set: { store.driveSyncPollSeconds = Int($0) }
                        ),
                        in: 30...3600,
                        step: 30
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var statusView: some View {
        switch driveAuthState.status {
        case .disconnected:
            Text("Not connected").foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting…").foregroundStyle(.secondary)
        case .connected(let email):
            Text(email ?? "Connected").foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch driveAuthState.status {
        case .disconnected:
            Button("Connect Google Drive…") { onConnect() }
        case .connecting:
            Button("Connecting…") {}
                .disabled(true)
        case .connected:
            Button("Disconnect") { onDisconnect() }
        }
    }

    private func formatSeconds(_ seconds: Int) -> String {
        if seconds % 60 == 0 {
            return "\(seconds / 60) min"
        }
        return "\(seconds) s"
    }
}
