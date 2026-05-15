import SwiftUI

/// Overlay shown during an export flow. Reads published state from an
/// `ExportCoordinator` and displays a progress bar with a label.
/// Follows the same visual pattern as `ImportProgressView`.
public struct ExportProgressView: View {
    @ObservedObject var coordinator: ExportCoordinator

    public init(coordinator: ExportCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 16) {
            if coordinator.totalItems > 0 {
                ProgressView(
                    value: Double(coordinator.currentItem),
                    total: Double(coordinator.totalItems)
                )
                .progressViewStyle(.linear)
                .frame(width: 240)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Text(label)
                .font(.headline)
                .foregroundStyle(.white)

            if let downloadProgress = coordinator.currentItemProgress {
                VStack(spacing: 6) {
                    ProgressView(value: min(max(downloadProgress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                    Text("Downloading original…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(40)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }

    private var label: String {
        switch coordinator.phase {
        case .exporting:
            if coordinator.totalItems > 0 {
                return "Exporting \(coordinator.currentItem) of \(coordinator.totalItems)..."
            }
            return "Preparing export..."
        case .idle, .done, .failed:
            return ""
        }
    }
}
