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
    /// True while the "Export all N photos?" confirmation is on screen.
    /// Set when File → Export is triggered with no selection / filter
    /// against the full library; a yes advances to `showExportSheet`.
    @State private var showExportConfirmation = false
    /// Set when the coordinator reaches `.done` or `.failed`. Drives a
    /// post-export alert summarising what happened. Cleared by the user
    /// dismissing the alert.
    @State private var exportAlert: ExportAlertPayload?
    /// Non-nil while the delete-confirmation dialog is presented.
    /// Carries the count so the dialog title reads e.g. "Delete 3 photos?".
    @State private var pendingDeleteCount: Int?
    @State private var showHistogram: Bool = true

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
                        pendingDeleteCount: $pendingDeleteCount
                    )
                case .loupe:
                    LoupeView(viewModel: libraryViewModel)
                case .develop:
                    DevelopView(viewModel: developViewModel, showHistogram: $showHistogram)
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
        .confirmationDialog(
            "Export all \(libraryViewModel.rows.count) photos?",
            isPresented: $showExportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Export") {
                showExportSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No selection or filter is active. This will export every photo in your library.")
        }
        .alert(
            exportAlert?.title ?? "",
            isPresented: Binding(
                get: { exportAlert != nil },
                set: { newValue in
                    if !newValue {
                        exportAlert = nil
                        exportCoordinator.reset()
                    }
                }
            ),
            presenting: exportAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { payload in
            Text(payload.message)
        }
        .onReceive(exportSheetPublisher) { _ in
            let shouldPrompt = ExportConfirmationPolicy.shouldPrompt(
                scope: libraryViewModel.scope,
                minRating: libraryViewModel.minRating,
                selectionEmpty: libraryViewModel.selectedAssetIds.isEmpty,
                rowCount: libraryViewModel.rows.count
            )
            if shouldPrompt {
                showExportConfirmation = true
            } else {
                showExportSheet = true
            }
        }
        .onChange(of: exportCoordinator.phase) { _, newPhase in
            switch newPhase {
            case .done(let exported, let skipped, let failures):
                let built = ExportCompletionMessage.forCompletion(
                    exported: exported,
                    skipped: skipped,
                    failures: failures
                )
                exportAlert = ExportAlertPayload(
                    title: built.title,
                    message: built.body
                )
            case .failed(let message):
                exportAlert = ExportAlertPayload(
                    title: "Export failed",
                    message: message
                )
            case .idle, .exporting:
                break
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
        .onKeyPress(.escape) {
            router.goBack()
            return .handled
        }
        .onKeyPress(keys: ["]"], phases: .down) { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            guard let assetId = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: true) }
            return .handled
        }
        .onKeyPress(keys: ["["], phases: .down) { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            guard let assetId = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.rotate(assetId: assetId, clockwise: false) }
            return .handled
        }
        // Rating keys 1-5 (set) and 0 (clear). Active in both Library
        // and Loupe — rating applies to the selected asset regardless
        // of which view is showing.
        .onKeyPress(keys: ["1", "2", "3", "4", "5"], phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else { return .ignored }
            guard let assetId = libraryViewModel.selectedAssetId,
                  let digit = Int(String(keyPress.characters)) else {
                return .ignored
            }
            Task { await libraryViewModel.setRating(for: assetId, to: digit) }
            return .handled
        }
        .onKeyPress(keys: ["0"], phases: .down) { keyPress in
            // Plain 0 → clear rating. Cmd+0 → reset zoom (loupe only).
            if keyPress.modifiers == .command {
                guard router.route == .loupe else { return .ignored }
                libraryViewModel.pendingZoomCommand = .resetToFit
                return .handled
            }
            guard keyPress.modifiers.isEmpty else { return .ignored }
            guard let assetId = libraryViewModel.selectedAssetId else {
                return .ignored
            }
            Task { await libraryViewModel.setRating(for: assetId, to: 0) }
            return .handled
        }
        // Arrow keys — navigate between assets in Library and Loupe.
        // Left/Right move by one asset; Up/Down move by one grid row
        // (Library only — no grid concept in Loupe).
        .onKeyPress(.leftArrow) {
            guard router.route == .library || router.route == .loupe else {
                return .ignored
            }
            libraryViewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard router.route == .library || router.route == .loupe else {
                return .ignored
            }
            libraryViewModel.selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard router.route == .library else { return .ignored }
            libraryViewModel.selectUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard router.route == .library else { return .ignored }
            libraryViewModel.selectDown()
            return .handled
        }
        // Z — toggle fit ↔ 100% zoom in Loupe.
        .onKeyPress(keys: ["z"], phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else { return .ignored }
            guard router.route == .loupe else { return .ignored }
            libraryViewModel.pendingZoomCommand = .toggleFitTo100
            return .handled
        }
        // H — toggle histogram visibility in Develop. Empty modifiers
        // only, so Cmd+H (macOS hide app) isn't intercepted.
        .onKeyPress(keys: ["h"], phases: .down) { keyPress in
            guard keyPress.modifiers.isEmpty else { return .ignored }
            guard router.route == .develop else { return .ignored }
            showHistogram.toggle()
            return .handled
        }
        // Cmd+A — select every visible row. Library only, matches Finder.
        .onKeyPress(keys: ["a"], phases: .down) { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            guard router.route == .library else { return .ignored }
            libraryViewModel.selectAllVisible()
            return .handled
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

/// Carries the copy for the post-export alert. The body is built by
/// `ExportCompletionMessage.forCompletion(...)` in the UI package and
/// wrapped here so SwiftUI's `.alert(presenting:)` has an `Identifiable`
/// value to drive dismissal.
struct ExportAlertPayload: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
