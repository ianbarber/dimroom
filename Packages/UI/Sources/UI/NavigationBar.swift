import SwiftUI

/// Minimal top bar showing the current mode with shortcut hints and an
/// optional back button. Accepts closures so the App target can wire
/// navigation without the UI package depending on Harness/Route.
public struct NavigationBar: View {
    public let currentMode: NavigationMode
    public var onBack: (() -> Void)?
    public var onNavigate: ((NavigationMode) -> Void)?
    public var undoEnabled: Bool
    public var redoEnabled: Bool
    public var undoTooltip: String?
    public var redoTooltip: String?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?

    public init(
        currentMode: NavigationMode,
        onBack: (() -> Void)? = nil,
        onNavigate: ((NavigationMode) -> Void)? = nil,
        undoEnabled: Bool = false,
        redoEnabled: Bool = false,
        undoTooltip: String? = nil,
        redoTooltip: String? = nil,
        onUndo: (() -> Void)? = nil,
        onRedo: (() -> Void)? = nil
    ) {
        self.currentMode = currentMode
        self.onBack = onBack
        self.onNavigate = onNavigate
        self.undoEnabled = undoEnabled
        self.redoEnabled = redoEnabled
        self.undoTooltip = undoTooltip
        self.redoTooltip = redoTooltip
        self.onUndo = onUndo
        self.onRedo = onRedo
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

            undoRedoButtons
                .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(white: 0.08))
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            undoRedoButton(
                systemName: "arrow.uturn.backward",
                enabled: undoEnabled,
                tooltip: undoTooltip ?? "Undo",
                action: onUndo
            )
            undoRedoButton(
                systemName: "arrow.uturn.forward",
                enabled: redoEnabled,
                tooltip: redoTooltip ?? "Redo",
                action: onRedo
            )
        }
    }

    private func undoRedoButton(
        systemName: String,
        enabled: Bool,
        tooltip: String,
        action: (() -> Void)?
    ) -> some View {
        Button(action: { if enabled { action?() } }) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color(white: 0.85) : Color(white: 0.35))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(tooltip)
    }
}
