import EditEngine
import SwiftUI

/// The HSL section of the Develop sidebar. Owns the currently-selected
/// axis (Hue / Saturation / Luminance) and renders one tinted slider
/// per colour range. Slider bindings route value reads and writes
/// through the supplied closures so DevelopViewModel remains the
/// single source of truth for `EditState`.
struct HSLPanelView: View {
    @State var selectedAxis: HSLAxis = .hue
    let value: (HSLAxis, Int) -> Double
    let setValue: (HSLAxis, Int, Double) -> Void
    let reset: (HSLAxis, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HSL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)

            Picker("Axis", selection: $selectedAxis) {
                Text("Hue").tag(HSLAxis.hue)
                Text("Saturation").tag(HSLAxis.saturation)
                Text("Luminance").tag(HSLAxis.luminance)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // `.segmented` is backed by NSSegmentedControl, whose segment
            // labels render near-black against the dark sidebar; the shared
            // dark-theme convention forces the system label colour light.
            // See `darkThemeControl()` and #241.
            .darkThemeControl()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(HSLColorRange.allCases) { range in
                    TintedParameterSlider(
                        label: range.displayName,
                        trackColor: Self.swiftUIColor(for: range),
                        value: Binding(
                            get: { value(selectedAxis, range.rawValue) },
                            set: { setValue(selectedAxis, range.rawValue, $0) }
                        ),
                        onReset: { reset(selectedAxis, range.rawValue) }
                    )
                }
            }
        }
    }

    private static func swiftUIColor(for range: HSLColorRange) -> Color {
        let rgb = range.representativeRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
