import Catalog
import EditEngine
import Foundation
import Previews

/// One reversible catalog mutation. The stack stores these so it can
/// replay the inverse on `undo()` and re-apply the forward on `redo()`.
///
/// Each case carries both the `from` and `to` value for the thing it
/// changed. That way the same action can drive either direction —
/// `undo` writes `from`, `redo` writes `to`.
public enum UndoAction: Equatable, Sendable {
    case rating(assetId: UUID, from: Int, to: Int)
    case rotation(assetId: UUID, from: Int, to: Int)
    case editSave(assetId: UUID, previous: EditState?, next: EditState)
    case softDelete(assetId: UUID)

    /// Short human label used in the Edit menu ("Undo Set Rating 4",
    /// "Redo Rotate", etc.) and asserted verbatim by tests.
    public var description: String {
        switch self {
        case .rating(_, _, let to):
            return to == 0 ? "Clear Rating" : "Set Rating \(to)"
        case .rotation:
            return "Rotate"
        case .editSave:
            return "Edit"
        case .softDelete:
            return "Delete"
        }
    }
}

/// In-memory undo/redo stack shared between the `LibraryViewModel`,
/// `AppDelegate` edit handlers, and the harness controller. Bounded to
/// `maxDepth` (50) entries; the oldest entries are silently dropped.
///
/// Not persisted across app restarts by design.
@MainActor
public final class UndoStack: ObservableObject {
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var undoDescription: String?
    @Published public private(set) var redoDescription: String?

    /// True while `undo()` / `redo()` is in flight. Mutation sites on
    /// the view model / edit handlers consult this so they skip the
    /// "also push onto the stack" step — otherwise every undo would
    /// immediately push a mirror action and the stack would grow
    /// without bound.
    public private(set) var isReplaying: Bool = false

    public static let maxDepth = 50

    private var catalog: CatalogDatabase
    private weak var libraryViewModel: LibraryViewModel?

    private var undoActions: [UndoAction] = []
    private var redoActions: [UndoAction] = []

    public init(
        catalog: CatalogDatabase,
        libraryViewModel: LibraryViewModel? = nil
    ) {
        self.catalog = catalog
        self.libraryViewModel = libraryViewModel
    }

    /// Late binding so AppDelegate can construct the stack before the
    /// shared view model is fully wired.
    public func attach(libraryViewModel: LibraryViewModel) {
        self.libraryViewModel = libraryViewModel
    }

    /// Swap the backing catalog (and optionally the library view model) in
    /// place. Used by `AppDelegate.applicationDidFinishLaunching` to
    /// upgrade the placeholder stack to the real one while preserving the
    /// object identity SwiftUI is already observing for the menu items.
    public func configure(
        catalog: CatalogDatabase,
        libraryViewModel: LibraryViewModel? = nil
    ) {
        self.catalog = catalog
        if let libraryViewModel {
            self.libraryViewModel = libraryViewModel
        }
        undoActions.removeAll()
        redoActions.removeAll()
        publishStateFlags()
    }

    /// Record a new forward action. Called by the view models / edit
    /// handlers after a successful mutation. No-op while replaying —
    /// that's how `undo` / `redo` avoid re-pushing their own work.
    public func push(_ action: UndoAction) {
        guard !isReplaying else { return }
        undoActions.append(action)
        if undoActions.count > Self.maxDepth {
            undoActions.removeFirst(undoActions.count - Self.maxDepth)
        }
        redoActions.removeAll()
        publishStateFlags()
    }

    /// Pop the top action and apply its inverse. No-op when empty.
    public func undo() async {
        guard let action = undoActions.popLast() else { return }
        isReplaying = true
        await apply(action, direction: .reverse)
        redoActions.append(action)
        if redoActions.count > Self.maxDepth {
            redoActions.removeFirst(redoActions.count - Self.maxDepth)
        }
        isReplaying = false
        publishStateFlags()
    }

    /// Replay the most recently undone action. No-op when empty.
    public func redo() async {
        guard let action = redoActions.popLast() else { return }
        isReplaying = true
        await apply(action, direction: .forward)
        undoActions.append(action)
        if undoActions.count > Self.maxDepth {
            undoActions.removeFirst(undoActions.count - Self.maxDepth)
        }
        isReplaying = false
        publishStateFlags()
    }

    private enum Direction { case forward, reverse }

    private func apply(_ action: UndoAction, direction: Direction) async {
        switch action {
        case .rating(let assetId, let from, let to):
            let target = direction == .forward ? to : from
            if let vm = libraryViewModel {
                await vm.setRating(for: assetId, to: target)
            } else {
                try? catalog.updateRating(assetId: assetId, rating: target)
            }
        case .rotation(let assetId, let from, let to):
            let target = direction == .forward ? to : from
            if let vm = libraryViewModel {
                await vm.applyRotation(assetId: assetId, to: target)
            } else {
                try? catalog.updateRotation(assetId: assetId, rotation: target)
            }
        case .editSave(let assetId, let previous, let next):
            let state = direction == .forward ? next : (previous ?? EditState())
            _ = try? catalog.saveEditState(state, for: assetId)
            await libraryViewModel?.reloadAndWait()
        case .softDelete(let assetId):
            if direction == .forward {
                try? catalog.deleteAsset(id: assetId)
            } else {
                try? catalog.restoreAsset(id: assetId)
            }
            await libraryViewModel?.reloadAndWait()
        }
    }

    private func publishStateFlags() {
        canUndo = !undoActions.isEmpty
        canRedo = !redoActions.isEmpty
        undoDescription = undoActions.last?.description
        redoDescription = redoActions.last?.description
    }
}
