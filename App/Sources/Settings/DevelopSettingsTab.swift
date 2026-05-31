import SwiftUI

struct DevelopSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Histogram") {
                Toggle(
                    "Show histogram in Develop by default",
                    isOn: $store.developHistogramVisible
                )
            }

            Section("Pixel Magnifier") {
                Toggle(
                    "Show pixel magnifier by default",
                    isOn: $store.developShowMagnifierByDefault
                )
            }

            Section("Render debounce") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.developRenderDebounceMillis) ms")
                    Slider(
                        value: Binding(
                            get: { Double(store.developRenderDebounceMillis) },
                            set: { store.developRenderDebounceMillis = Int($0) }
                        ),
                        in: 10...300,
                        step: 5
                    )
                }
            }

            Section("Auto-save debounce") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(store.developSaveDebounceMillis) ms")
                    Slider(
                        value: Binding(
                            get: { Double(store.developSaveDebounceMillis) },
                            set: { store.developSaveDebounceMillis = Int($0) }
                        ),
                        in: 100...2000,
                        step: 50
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        // Report natural height so the Settings window can size to fit
        // all sections (see SettingsRootView).
        .fixedSize(horizontal: false, vertical: true)
    }
}
