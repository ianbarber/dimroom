import SwiftUI

struct ParameterSlider: View {
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let identity: Double
    @Binding var value: Double
    var onReset: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(Color(white: 0.85))
                .font(.system(size: 11))

            Slider(value: $value, in: range, step: step)

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
