import SwiftUI

/// Overlay shown during an import-then-preview-generation flow.
/// Reads published state from an `ImportCoordinator` and displays
/// a simple progress indicator with a label.
public struct ImportProgressView: View {
    @ObservedObject var coordinator: ImportCoordinator

    public init(coordinator: ImportCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text(label)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(40)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }

    private var label: String {
        switch coordinator.phase {
        case .importing:
            return "Importing..."
        case .generatingPreviews:
            if coordinator.totalItems > 0 {
                return "Generating previews... \(coordinator.currentItem) of \(coordinator.totalItems)"
            }
            return "Generating previews..."
        case .idle, .done, .failed:
            return ""
        }
    }
}
