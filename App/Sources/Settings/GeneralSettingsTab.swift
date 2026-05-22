import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    let libraryLocation: URL?

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Library location") {
                    Text(libraryLocation?.path ?? "—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section("Scope picker") {
                Stepper(
                    "Recent imports shown: \(store.recentImportsLimit)",
                    value: $store.recentImportsLimit,
                    in: 1...100
                )
            }

            Section("Library grid") {
                Stepper(
                    "Columns: \(store.libraryGridColumns)",
                    value: $store.libraryGridColumns,
                    in: 1...8
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
