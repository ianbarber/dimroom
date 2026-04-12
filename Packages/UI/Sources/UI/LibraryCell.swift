import AppKit
import SwiftUI

/// A single square tile in the library grid. Renders a cached thumbnail
/// when one is present on disk, otherwise a neutral placeholder — the cell
/// never decodes RAW or original JPEG at render time.
struct LibraryCell: View {
    let row: LibraryRow
    let isSelected: Bool
    /// Monotonic version tag bumped by the view model on rotate. Used as
    /// a SwiftUI `.id(...)` on the thumbnail `Image` so a rewrite of the
    /// cached JPEG forces `NSImage(contentsOf:)` to run again instead of
    /// serving the stale decoded CGImage.
    let rowVersion: Int

    init(row: LibraryRow, isSelected: Bool, rowVersion: Int = 0) {
        self.row = row
        self.isSelected = isSelected
        self.rowVersion = rowVersion
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                thumbnail
            }
            .overlay(alignment: .bottomLeading) {
                if row.asset.rating > 0 {
                    starOverlay
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = row.thumbnailURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .id(rowVersion)
        } else {
            placeholder
        }
    }

    /// Bottom-left row of filled stars reflecting `row.asset.rating`. The
    /// count is clamped to 1...5 so a stray out-of-range value never
    /// crashes ForEach. Hidden entirely for `rating == 0` (handled by
    /// the caller via the conditional in `body`).
    private var starOverlay: some View {
        HStack(spacing: 1) {
            let count = max(1, min(5, row.asset.rating))
            ForEach(0..<count, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.7), radius: 1, x: 0, y: 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
        )
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.18))
            Image(systemName: "photo")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color(white: 0.55))
        }
    }
}
