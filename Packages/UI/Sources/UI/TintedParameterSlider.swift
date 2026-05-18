import SwiftUI

/// Thin convenience over `ParameterSlider` that hardcodes the
/// HSL-band defaults (-100…+100, step 1, identity 0) and forwards a
/// representative track tint. New `ParameterSlider` features (e.g.
/// reset semantics, value formatting) flow through automatically.
struct TintedParameterSlider: View {
    let label: String
    let trackColor: Color
    @Binding var value: Double
    var onReset: () -> Void

    var body: some View {
        ParameterSlider(
            label: label,
            range: -100...100,
            step: 1,
            identity: 0,
            trackTint: trackColor,
            value: $value,
            onReset: onReset
        )
    }
}
