import AppKit
import SwiftUI

/// Single-asset preview. Renders the currently-selected row's preview
/// JPEG fit-to-window on a neutral dark background, and exposes left /
/// right arrow keys for prev / next navigation. Paired with `LibraryView`
/// via a shared `LibraryViewModel` — the two views read and mutate the
/// same `selectedAssetId`, so the highlight survives a round-trip
/// through Loupe and back.
///
/// Out of scope for this view: zoom/pan, info overlays, histograms,
/// compare. This is intentionally a thin "look closer" surface.
public struct LoupeView: View {
    @ObservedObject private var viewModel: LibraryViewModel

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color(white: 0.05)
                .ignoresSafeArea()

            if let row = selectedRow, let image = loadedImage(for: row) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    // Force SwiftUI to rebuild the image subtree whenever
                    // the view model bumps its row-version counter (on
                    // rotate). Without this, AppKit keeps serving the
                    // CGImage it decoded the first time it saw the file
                    // and the new orientation doesn't appear until the
                    // user navigates away and back.
                    .id(viewModel.rowVersion)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `.onKeyPress` needs a focusable host; the focus ring would
        // clash with the dark chrome-free look so it's disabled.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext()
            return .handled
        }
    }

    private var selectedRow: LibraryRow? {
        guard let id = viewModel.selectedAssetId else { return nil }
        return viewModel.rows.first(where: { $0.id == id })
    }

    /// Decodes the preview JPEG for display. Returns nil if the URL is
    /// missing (cache miss) or the file fails to decode — both surfaced
    /// as the placeholder state.
    private func loadedImage(for row: LibraryRow) -> NSImage? {
        guard let url = row.previewURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(white: 0.35))
            Text("No photo selected")
                .font(.headline)
                .foregroundStyle(Color(white: 0.55))
        }
    }
}
