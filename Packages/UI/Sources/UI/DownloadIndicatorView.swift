import SwiftUI

/// Small overlay shown while the originals cache is pulling bytes from
/// Drive. Indeterminate on purpose — the buffered HTTPClient does not
/// expose per-byte progress, and a spinner is what the user cares about
/// at 100% zoom anyway.
public struct DownloadIndicatorView: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Downloading original…")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.65), in: Capsule())
    }
}
