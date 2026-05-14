import Catalog
import EditEngine
import Harness
import SwiftUI
import UI

struct ContentView: View {
    let router: AppRouter
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var developViewModel: DevelopViewModel
    @ObservedObject var importCoordinator: ImportCoordinator
    @ObservedObject var exportCoordinator: ExportCoordinator
    @ObservedObject var uploadCoordinator: UploadCoordinator
    @ObservedObject var undoStack: UndoStack
    let catalog: CatalogDatabase?
    @State private var showExportSheet = false
    /// Non-nil while the delete-confirmation dialog is presented.
    /// Carries the count so the dialog title reads e.g. "Delete 3 photos?".
    @State private var pendingDeleteCount: Int?

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
                },
                undoEnabled: undoStack.canUndo,
                redoEnabled: undoStack.canRedo,
                undoTooltip: undoStack.undoDescription.map { "Undo \($0)" } ?? "Undo",
                redoTooltip: undoStack.redoDescription.map { "Redo \($0)" } ?? "Redo",
                onUndo: { Task { await undoStack.undo() } },
                onRedo: { Task { await undoStack.redo() } }
            )

            Group {
                switch router.route {
                case .library:
                    LibraryView(
                        viewModel: libraryViewModel,
                        pendingDeleteCount: $pendingDeleteCount,
                        onOpenLoupe: { _ in router.route = .loupe }
                    )
                case .loupe:
                    LoupeView(viewModel: libraryViewModel)
                case .develop:
                    DevelopView(viewModel: developViewModel)
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
            if exportCoordinator.isActive {
                ExportProgressView(coordinator: exportCoordinator)
            }
        }
        .overlay {
            if uploadCoordinator.isActive {
                UploadProgressView(coordinator: uploadCoordinator)
            }
        }
        .overlay {
            RatingToastView(toast: $libraryViewModel.ratingToast)
        }
        .sheet(isPresented: $showExportSheet) {
            let scopedAssets = ExportScope.resolve(
                selectedIds: libraryViewModel.selectedAssetIds,
                rows: libraryViewModel.rows
            )
            ExportSheetView(
                assetCount: scopedAssets.count,
                onExport: { [catalog] destinationURL, format, jpegQuality, applyEdits in
                    showExportSheet = false
                    guard let catalog else { return }
                    Task {
                        await exportCoordinator.run(
                            assets: scopedAssets,
                            catalog: catalog,
                            format: format,
                            jpegQuality: jpegQuality,
                            applyEdits: applyEdits,
                            destinationDirectory: destinationURL
                        )
                    }
                },
                onCancel: {
                    showExportSheet = false
                }
            )
        }
        .onReceive(exportSheetPublisher) { _ in
            showExportSheet = true
        }
        // `.focusable()` keeps the root view eligible to receive the Esc
        // key via `.onKeyPress(.escape)`. Other modifierless shortcuts
        // (g/e/d, ratings, arrows, z, h, ⌘A, ⌘[ / ⌘]) used to live here
        // too, but they silently no-opped at launch when focus hadn't
        // landed on a child view — the same focus bug #134 fixed for
        // Backspace. They are now menu-attached key equivalents that
        // post notifications observed below; see `MenuActionName` in
        // DimroomApp for the whitelist.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            router.goBack()
            return .handled
        }
        .onReceive(menuActionPublisher(.modeLibrary)) { _ in
            router.route = .library
        }
        .onReceive(menuActionPublisher(.modeLoupe)) { _ in
            router.route = .loupe
        }
        .onReceive(menuActionPublisher(.modeDevelop)) { _ in
            router.route = .develop
        }
        .onReceive(menuActionPublisher(.rotateCW)) { _ in
            guard let assetId = libraryViewModel.selectedAssetId else { return }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: true) }
        }
        .onReceive(menuActionPublisher(.rotateCCW)) { _ in
            guard let assetId = libraryViewModel.selectedAssetId else { return }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: false) }
        }
        .onReceive(menuActionPublisher(.setRating1)) { _ in applyRating(1) }
        .onReceive(menuActionPublisher(.setRating2)) { _ in applyRating(2) }
        .onReceive(menuActionPublisher(.setRating3)) { _ in applyRating(3) }
        .onReceive(menuActionPublisher(.setRating4)) { _ in applyRating(4) }
        .onReceive(menuActionPublisher(.setRating5)) { _ in applyRating(5) }
        .onReceive(menuActionPublisher(.clearRating)) { _ in applyRating(0) }
        .onReceive(menuActionPublisher(.zoomToggle)) { _ in
            guard router.route == .loupe else { return }
            libraryViewModel.pendingZoomCommand = .toggleFitTo100
        }
        .onReceive(menuActionPublisher(.zoomReset)) { _ in
            guard router.route == .loupe else { return }
            libraryViewModel.pendingZoomCommand = .resetToFit
        }
        .onReceive(menuActionPublisher(.toggleHistogram)) { _ in
            guard router.route == .develop else { return }
            developViewModel.showHistogram.toggle()
        }
        .onReceive(menuActionPublisher(.selectPrevious)) { _ in
            guard router.route == .library || router.route == .loupe else { return }
            libraryViewModel.selectPrevious()
        }
        .onReceive(menuActionPublisher(.selectNext)) { _ in
            guard router.route == .library || router.route == .loupe else { return }
            libraryViewModel.selectNext()
        }
        .onReceive(menuActionPublisher(.selectUp)) { _ in
            guard router.route == .library else { return }
            libraryViewModel.selectUp()
        }
        .onReceive(menuActionPublisher(.selectDown)) { _ in
            guard router.route == .library else { return }
            libraryViewModel.selectDown()
        }
        .onReceive(menuActionPublisher(.selectAllVisible)) { _ in
            guard router.route == .library else { return }
            libraryViewModel.selectAllVisible()
        }
        // Delete is dispatched from the Edit → Delete Selected menu
        // item (keyboardShortcut .delete). Routing it through a
        // notification sidesteps the focus bug that kept the grid's
        // own `onKeyPress(.delete)` from firing.
        .onReceive(deleteSelectedPublisher) { _ in
            guard router.route == .library else { return }
            let count = libraryViewModel.selectedAssetIds.count
            guard count > 0 else { return }
            pendingDeleteCount = count
        }
        .onChange(of: router.route) { oldRoute, newRoute in
            if newRoute == .develop {
                Task {
                    await developViewModel.activate(assetId: libraryViewModel.selectedAssetId)
                }
            }
            if oldRoute == .develop {
                developViewModel.deactivate()
            }
        }
    }

    private func applyRating(_ rating: Int) {
        guard let assetId = libraryViewModel.selectedAssetId else { return }
        Task { await libraryViewModel.setRating(for: assetId, to: rating) }
    }

    private func menuActionPublisher(_ action: MenuActionName) -> NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: action.notificationName)
    }

    /// The export sheet is triggered by File → Export… (Cmd+Shift+E) via
    /// a notification from the menu command in DimroomApp.
    private var exportSheetPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .showExportSheet)
    }

    /// Edit → Delete Selected (or Backspace via its key equivalent).
    private var deleteSelectedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .requestDeleteSelected)
    }
}
