import SwiftUI

/// Small overlay showing the current zoom percentage in the bottom-right
/// corner. Fades out 1.5 s after the last zoom change; reappears on any
/// zoom gesture.
struct ZoomIndicatorView: View {
    let label: String

    /// Controls visibility. The parent view sets this to `true` on every
    /// zoom change and manages the auto-hide timer.
    let isVisible: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isVisible)
    }
}
