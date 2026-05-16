import Catalog
import CoreGraphics
import Foundation

/// One of the four tone-curve channels editable in Develop.
///
/// Owns the wire-string mapping (`rawValue`) used by the harness
/// commands and the `WritableKeyPath<EditState, [CGPoint]>` lookup used
/// by both the view-model and the harness handler so the two surfaces
/// can't drift apart.
public enum CurveChannel: String, CaseIterable, Sendable {
    case luminance
    case red
    case green
    case blue

    public var displayName: String {
        switch self {
        case .luminance: return "Luminance"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    public var keyPath: WritableKeyPath<EditState, [CGPoint]> {
        switch self {
        case .luminance: return \EditState.toneCurvePoints
        case .red: return \EditState.redCurvePoints
        case .green: return \EditState.greenCurvePoints
        case .blue: return \EditState.blueCurvePoints
        }
    }
}
