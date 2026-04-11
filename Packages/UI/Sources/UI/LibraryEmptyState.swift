import SwiftUI

/// Shown when the catalog has no non-deleted assets. Kept in its own view
/// so the snapshot test can target it without the rest of the grid.
struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color(white: 0.55))
            Text("No photos imported yet")
                .font(.headline)
                .foregroundStyle(Color(white: 0.75))
            Text("Import a folder to populate your library.")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
