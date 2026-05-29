import Foundation

/// Pure keyboard / VoiceOver nudge math for `ColorWheelControl`. Lifted
/// out of the view so the per-key behaviour has Layer A coverage without
/// rendering, and so the harness can drive the exact same step logic the
/// `onKeyPress` handler does. Hue wraps within `[0, 360)`; saturation
/// clamps to `[0, 100]`.
public enum ColorWheelKeyboardModel {
    public static let hueStep: Double = 5
    public static let saturationStep: Double = 5

    public enum ArrowKey: Equatable {
        case left, right, up, down

        /// Maps the harness wire names to a key, rejecting anything else.
        public init?(wireName: String) {
            switch wireName {
            case "left": self = .left
            case "right": self = .right
            case "up": self = .up
            case "down": self = .down
            default: return nil
            }
        }

        /// +1 for the increasing direction (right / up), -1 for the
        /// decreasing direction (left / down).
        var sign: Double {
            switch self {
            case .right, .up: return 1
            case .left, .down: return -1
            }
        }
    }

    /// Nudge one axis by a fixed step. Plain arrows move hue; arrows with
    /// shift held move saturation. The axis that did not move is returned
    /// unchanged so callers apply only the one that did.
    public static func nudge(
        hue: Double,
        saturation: Double,
        key: ArrowKey,
        shift: Bool
    ) -> (hue: Double, saturation: Double) {
        if shift {
            let next = min(max(saturation + key.sign * saturationStep, 0), 100)
            return (hue, next)
        }
        return (wrapHue(hue + key.sign * hueStep), saturation)
    }

    /// Reset both axes to identity — mirrors the wheel's double-click and
    /// `0` reset.
    public static func reset() -> (hue: Double, saturation: Double) {
        (0, 0)
    }

    private static func wrapHue(_ value: Double) -> Double {
        var h = value.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }
}
