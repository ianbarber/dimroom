import SwiftUI

/// Small overlay shown while the originals cache is pulling bytes from
/// Drive. Renders determinate progress when the caller has a fraction to
/// report; falls back to an indeterminate spinner otherwise (e.g. when
/// `Content-Length` is unknown and the streaming delegate is suppressing
/// ticks).
public struct DownloadIndicatorView: View {
    private let progress: Double?

    public init(progress: Double? = nil) {
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 100)
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
