import Harness
import SwiftUI
import UI

struct ContentView: View {
    let router: AppRouter
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var importCoordinator: ImportCoordinator

    var body: some View {
        Group {
            switch router.route {
            case .library:
                LibraryView(viewModel: libraryViewModel)
            case .loupe:
                placeholder("Loupe")
            case .develop:
                placeholder("Develop")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if importCoordinator.isActive {
                ImportProgressView(coordinator: importCoordinator)
            }
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
