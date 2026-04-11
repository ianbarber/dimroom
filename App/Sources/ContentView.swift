import Harness
import SwiftUI
import UI

struct ContentView: View {
    let router: AppRouter
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        Group {
            switch router.route {
            case .library:
                LibraryView(viewModel: libraryViewModel)
            case .loupe:
                LoupeView(viewModel: libraryViewModel)
            case .develop:
                placeholder("Develop")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Mode switch keys, Lightroom-style: G → Library, E → Loupe,
        // D → Develop. Attached at the root so they fire regardless of
        // which subview currently has focus.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.init("g")) {
            router.route = .library
            return .handled
        }
        .onKeyPress(.init("e")) {
            router.route = .loupe
            return .handled
        }
        .onKeyPress(.init("d")) {
            router.route = .develop
            return .handled
        }
        // Culling keys — 0-5 set the rating on the current selection,
        // R rotates 90° clockwise. All no-ops when nothing is selected.
        .onKeyPress(.init("0")) { handleRating(0) }
        .onKeyPress(.init("1")) { handleRating(1) }
        .onKeyPress(.init("2")) { handleRating(2) }
        .onKeyPress(.init("3")) { handleRating(3) }
        .onKeyPress(.init("4")) { handleRating(4) }
        .onKeyPress(.init("5")) { handleRating(5) }
        .onKeyPress(.init("r")) {
            guard let id = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.rotate(assetId: id) }
            return .handled
        }
    }

    private func handleRating(_ rating: Int) -> KeyPress.Result {
        guard let id = libraryViewModel.selectedAssetId else {
            return .ignored
        }
        Task { await libraryViewModel.setRating(for: id, to: rating) }
        return .handled
    }

    private func placeholder(_ label: String) -> some View {
        VStack {
            Text(label)
                .font(.largeTitle)
                .foregroundStyle(Color(white: 0.75))
            Text("coming soon")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }
}
