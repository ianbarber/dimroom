import SwiftUI

/// Transient overlay showing filled stars for ~1.5 s after a rating
/// change. Driven by an optional `LibraryViewModel.RatingToast` binding;
/// auto-dismisses by clearing the binding after the delay.
public struct RatingToastView: View {
    @Binding public var toast: LibraryViewModel.RatingToast?

    public init(toast: Binding<LibraryViewModel.RatingToast?>) {
        self._toast = toast
    }

    public var body: some View {
        if let toast {
            HStack(spacing: 2) {
                ForEach(0..<toast.rating, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.7))
            )
            .transition(.opacity)
            .task(id: toast) {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.3)) {
                    self.toast = nil
                }
            }
        }
    }
}
