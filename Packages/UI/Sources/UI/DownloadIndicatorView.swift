import SwiftUI

/// Small overlay shown while the originals cache is pulling bytes from
/// Drive. Pass a `progress` value in `0...1` to render a determinate
/// bar; pass `nil` (the default) for an indeterminate spinner when the
/// caller doesn't have a numeric value to thread through yet.
public struct DownloadIndicatorView: View {
    public let progress: Double?

    public init(progress: Double? = nil) {
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 80)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text("Downloading original…")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.65), in: Capsule())
    }
}
