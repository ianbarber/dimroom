import SwiftUI

/// Minimal top bar showing the current mode with shortcut hints and an
/// optional back button. Accepts closures so the App target can wire
/// navigation without the UI package depending on Harness/Route.
public struct NavigationBar: View {
    public let currentMode: NavigationMode
    public var onBack: (() -> Void)?
    public var onNavigate: ((NavigationMode) -> Void)?

    public init(
        currentMode: NavigationMode,
        onBack: (() -> Void)? = nil,
        onNavigate: ((NavigationMode) -> Void)? = nil
    ) {
        self.currentMode = currentMode
        self.onBack = onBack
        self.onNavigate = onNavigate
    }

    public var body: some View {
        HStack(spacing: 0) {
            if currentMode != .library {
                Button(action: { onBack?() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }

            HStack(spacing: 16) {
                ForEach(NavigationMode.allCases, id: \.self) { mode in
                    Button(action: { onNavigate?(mode) }) {
                        Text("\(mode.label) (\(mode.shortcutHint))")
                            .font(.system(size: 11, weight: mode == currentMode ? .bold : .regular))
                            .foregroundStyle(mode == currentMode ? Color.white : Color(white: 0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, currentMode == .library ? 12 : 4)

            Spacer()
        }
        .frame(height: 32)
        .background(Color(white: 0.08))
    }
}
