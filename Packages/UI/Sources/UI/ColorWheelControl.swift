import SwiftUI

/// 2-D hue + saturation picker. The user clicks and drags inside the
/// wheel to set hue (angle from centre) and saturation (radius from
/// centre) in a single gesture; double-clicking resets both back to
/// identity. Each axis is reported through a separate callback so the
/// upstream `DevelopViewModel.setParameter` path is unchanged — the
/// harness `setEditParameter` surface continues to work without any
/// new commands.
///
/// Coordinate convention: `hue` is `[0, 360)` degrees with 0° at 3
/// o'clock and angles increasing clockwise, matching the default
/// `AngularGradient` sweep so the indicator dot lines up with the hue
/// it's pointing at. `saturation` is `[0, 100]`.
struct ColorWheelControl: View {
    let label: String
    let hue: Double
    let saturation: Double
    var onHueChange: (Double) -> Void
    var onSaturationChange: (Double) -> Void
    var onReset: () -> Void

    private static let wheelSize: CGFloat = 110
    private static let indicatorDiameter: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 0.55))

            HStack(alignment: .center, spacing: 12) {
                wheel
                    .frame(width: Self.wheelSize, height: Self.wheelSize)
                readout
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("color-wheel-\(label.lowercased())")
    }

    // MARK: - Wheel

    private var wheel: some View {
        ZStack {
            AngularGradient(
                gradient: Gradient(colors: Self.hueRingColors),
                center: .center
            )
            RadialGradient(
                gradient: Gradient(colors: [.white, .white.opacity(0)]),
                center: .center,
                startRadius: 0,
                endRadius: Self.wheelSize / 2
            )
        }
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color(white: 0.2), lineWidth: 1)
        )
        .overlay(indicator)
        .contentShape(Circle())
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onReset() }
        )
    }

    private var indicator: some View {
        GeometryReader { geo in
            let pt = Self.polarToPoint(
                hue: hue,
                saturation: saturation,
                inSize: geo.size
            )
            ZStack {
                Circle()
                    .fill(Color(hue: hue / 360.0,
                                saturation: max(saturation, 0) / 100.0,
                                brightness: 1.0))
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
            }
            .frame(width: Self.indicatorDiameter, height: Self.indicatorDiameter)
            .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
            .position(pt)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "H %3d°", Int(hue.rounded())))
            Text(String(format: "S %3d", Int(saturation.rounded())))
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Color(white: 0.65))
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let (h, s) = Self.pointToPolar(
                    point: value.location,
                    inSize: CGSize(width: Self.wheelSize, height: Self.wheelSize)
                )
                onHueChange(h)
                onSaturationChange(s)
            }
    }

    // MARK: - Coordinate math (testable)

    /// Convert a local touch point to `(hue, saturation)` for a wheel
    /// occupying `inSize` centred in its own coordinate space. Points
    /// outside the disc clamp `saturation` to 100; `hue` is always
    /// derived from the angle so a drag past the edge still tracks the
    /// hue smoothly.
    static func pointToPolar(point: CGPoint, inSize size: CGSize) -> (hue: Double, saturation: Double) {
        let radius = min(size.width, size.height) / 2
        guard radius > 0 else { return (0, 0) }
        let dx = Double(point.x - size.width / 2)
        let dy = Double(point.y - size.height / 2)
        let distance = (dx * dx + dy * dy).squareRoot()
        let saturation = min(max(distance / Double(radius), 0), 1) * 100
        if distance == 0 {
            return (0, 0)
        }
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        return (angle, saturation)
    }

    /// Inverse of `pointToPolar` — returns the indicator centre point
    /// for `(hue, saturation)` in the wheel's local coordinate space.
    static func polarToPoint(hue: Double, saturation: Double, inSize size: CGSize) -> CGPoint {
        let radius = min(size.width, size.height) / 2
        let s = max(0, min(saturation, 100)) / 100
        let theta = hue * .pi / 180
        let x = size.width / 2 + CGFloat(s) * radius * CGFloat(cos(theta))
        let y = size.height / 2 + CGFloat(s) * radius * CGFloat(sin(theta))
        return CGPoint(x: x, y: y)
    }

    // 36 evenly-spaced rainbow stops feed the conic gradient. SwiftUI
    // interpolates between adjacent stops in RGB, which is close enough
    // to the canonical HSV→RGB curve at this resolution that the user
    // can pick a hue confidently.
    private static let hueRingColors: [Color] = stride(
        from: 0.0,
        through: 1.0,
        by: 1.0 / 36.0
    ).map { Color(hue: $0, saturation: 1, brightness: 1) }
}
