import SwiftUI

/// `ParameterSlider` variant whose track is tinted with the range's
/// representative colour so users can identify which HSL band each
/// slider drives at a glance. The label and double-click-to-reset
/// behaviour from `ParameterSlider` are preserved verbatim.
struct TintedParameterSlider: View {
    let label: String
    let trackColor: Color
    @Binding var value: Double
    var onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(Color(white: 0.85))
                .font(.system(size: 11))

            ZStack {
                // Dim coloured track behind the system slider. SwiftUI's
                // Slider draws its own track on top, but the tint shows
                // through enough at the ends and edges to be readable.
                Capsule()
                    .fill(trackColor.opacity(0.45))
                    .frame(height: 4)

                Slider(value: $value, in: -100...100, step: 1)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { onReset() }
                    )
            }

            Text(String(format: "%+.0f", value))
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(Color(white: 0.65))
                .font(.system(size: 11).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onReset()
        }
    }
}
