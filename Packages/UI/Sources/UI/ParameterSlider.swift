import SwiftUI

struct ParameterSlider: View {
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let identity: Double
    var trackTint: Color? = nil
    @Binding var value: Double
    var onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(Color(white: 0.85))
                .font(.system(size: 11))

            ZStack {
                if let trackTint {
                    Capsule()
                        .fill(trackTint.opacity(0.45))
                        .frame(height: 4)
                }
                // A double-click must reset the parameter to its identity.
                // `Slider` consumes pointer events on its track/thumb before
                // they reach the row-level `onTapGesture` below, so the reset
                // gesture has to live on the `Slider` itself. It must be a
                // `highPriorityGesture`, not a `simultaneousGesture`: with the
                // latter the `Slider` *also* processes the double-click and
                // jumps its value to the click location, overwriting the reset
                // that fired alongside it (issue #265). `highPriorityGesture`
                // lets the double-tap win so the reset value sticks; single
                // clicks and drags don't match `TapGesture(count: 2)` and pass
                // through to the `Slider` unchanged.
                Slider(value: $value, in: range, step: step)
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded { onReset() }
                    )
            }

            Text(formattedValue)
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(Color(white: 0.65))
                .font(.system(size: 11).monospacedDigit())
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onReset()
        }
    }

    private var formattedValue: String {
        if step >= 1 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
