import SwiftUI

struct CacheSettingsTab: View {
    @ObservedObject var store: SettingsStore
    let onClearOriginals: () -> Void
    let onClearPreviews: () -> Void

    private static let oneGB: Int64 = 1024 * 1024 * 1024

    private var originalsBudgetGB: Binding<Double> {
        Binding(
            get: { Double(store.originalsCacheBudgetBytes) / Double(Self.oneGB) },
            set: { store.originalsCacheBudgetBytes = Int64($0 * Double(Self.oneGB)) }
        )
    }

    private var previewBudgetGB: Binding<Double> {
        Binding(
            get: { Double(store.previewCacheBudgetBytes) / Double(Self.oneGB) },
            set: { store.previewCacheBudgetBytes = Int64($0 * Double(Self.oneGB)) }
        )
    }

    var body: some View {
        Form {
            Section("Originals cache") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Budget: \(String(format: "%.0f", originalsBudgetGB.wrappedValue)) GB")
                    Slider(value: originalsBudgetGB, in: 1...50, step: 1)
                }
                Button("Clear originals cache") { onClearOriginals() }
            }

            Section("Preview cache") {
                VStack(alignment: .leading, spacing: 6) {
                    if previewBudgetGB.wrappedValue == 0 {
                        Text("Budget: unlimited")
                    } else {
                        Text("Budget: \(String(format: "%.0f", previewBudgetGB.wrappedValue)) GB")
                    }
                    Slider(value: previewBudgetGB, in: 0...20, step: 1)
                }
                Button("Clear preview cache") { onClearPreviews() }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Report natural height so the Settings window can size to fit
        // all sections (see SettingsRootView).
        .fixedSize(horizontal: false, vertical: true)
    }
}
