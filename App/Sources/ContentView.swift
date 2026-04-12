import Harness
import SwiftUI
import UI

struct ContentView: View {
    let router: AppRouter
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var importCoordinator: ImportCoordinator

    private var currentMode: NavigationMode {
        switch router.route {
        case .library: .library
        case .loupe: .loupe
        case .develop: .develop
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                currentMode: currentMode,
                onBack: { router.goBack() },
                onNavigate: { mode in
                    switch mode {
                    case .library: router.route = .library
                    case .loupe: router.route = .loupe
                    case .develop: router.route = .develop
                    }
                }
            )

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
        }
        .overlay {
            if importCoordinator.isActive {
                ImportProgressView(coordinator: importCoordinator)
            }
        }
        .overlay {
            RatingToastView(toast: $libraryViewModel.ratingToast)
        }
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
        .onKeyPress(.escape) {
            router.goBack()
            return .handled
        }
        .onKeyPress(.init("]"), modifiers: .command) {
            guard let assetId = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: true) }
            return .handled
        }
        .onKeyPress(.init("["), modifiers: .command) {
            guard let assetId = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: false) }
            return .handled
        }
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
