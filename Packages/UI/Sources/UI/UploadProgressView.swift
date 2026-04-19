import SwiftUI

/// Overlay shown during a Drive upload flow. Mirrors
/// `ExportProgressView`: reads published state from an
/// `UploadCoordinator` and displays per-file + overall progress.
public struct UploadProgressView: View {
    @ObservedObject var coordinator: UploadCoordinator

    public init(coordinator: UploadCoordinator) {
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
                .frame(width: 280)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            if coordinator.totalBytes > 0, case .uploading = coordinator.phase {
                ProgressView(
                    value: Double(coordinator.currentBytes),
                    total: Double(coordinator.totalBytes)
                )
                .progressViewStyle(.linear)
                .frame(width: 280)
            }

            Text(label)
                .font(.headline)
                .foregroundStyle(.white)

            if !coordinator.currentFilename.isEmpty,
               case .uploading = coordinator.phase {
                Text(coordinator.currentFilename)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 280)
            }
        }
        .padding(40)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.3))
    }

    private var label: String {
        switch coordinator.phase {
        case .uploading:
            if coordinator.totalItems > 0 {
                return "Uploading \(coordinator.currentItem + 1) of \(coordinator.totalItems)..."
            }
            return "Preparing upload..."
        case .done(let uploaded, let skipped):
            if skipped > 0 {
                return "Uploaded \(uploaded), skipped \(skipped)"
            }
            return "Uploaded \(uploaded)"
        case .failed(let message):
            return "Upload failed: \(message)"
        case .idle:
            return ""
        }
    }
}
