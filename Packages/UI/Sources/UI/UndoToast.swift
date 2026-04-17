import SwiftUI

/// Bottom-of-screen toast shown for ~10 s after a soft-delete. Displays
/// "Deleted N photos" with an "Undo" action that restores the deleted
/// assets. Auto-dismiss is driven by the view model — the view itself
/// only renders what's in the binding and invokes the action closure.
public struct UndoToastView: View {
    @Binding public var toast: LibraryViewModel.UndoToast?
    public let onUndo: () -> Void

    public init(
        toast: Binding<LibraryViewModel.UndoToast?>,
        onUndo: @escaping () -> Void
    ) {
        self._toast = toast
        self.onUndo = onUndo
    }

    public var body: some View {
        if let toast {
            HStack(spacing: 12) {
                Text(deletedLabel(count: toast.deletedIds.count))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Button("Undo") {
                    onUndo()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.82))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func deletedLabel(count: Int) -> String {
        count == 1 ? "Deleted 1 photo" : "Deleted \(count) photos"
    }
}
