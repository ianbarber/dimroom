import AppKit
import SwiftUI

/// A single square tile in the library grid. Renders a cached thumbnail
/// when one is present on disk, otherwise a neutral placeholder — the cell
/// never decodes RAW or original JPEG at render time.
struct LibraryCell: View {
    let row: LibraryRow
    let isSelected: Bool

    var body: some View {
        ZStack {
            thumbnail
        }
        .aspectRatio(1, contentMode: .fit)
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
        } else {
            placeholder
        }
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
