import Foundation

/// App-internal clipboard for copying and pasting edit settings between assets.
///
/// Holds a single `EditState` in memory (not serialised to the system pasteboard).
/// Shared across Library, Loupe, and Develop modes via `AppDelegate`.
public final class EditClipboard: ObservableObject {
    @Published public private(set) var copiedState: EditState?
    public private(set) var sourceAssetId: UUID?

    public var isEmpty: Bool { copiedState == nil }

    public init() {}

    /// Store an edit state from the given asset.
    public func copy(_ state: EditState, from assetId: UUID) {
        copiedState = state
        sourceAssetId = assetId
    }

    /// Returns the copied state with `cropRect` and `cropAngle` stripped.
    /// Returns `nil` if the clipboard is empty.
    public func pasteExcludingCrop() -> EditState? {
        guard var state = copiedState else { return nil }
        state.cropRect = nil
        state.cropAngle = nil
        return state
    }

    /// Returns the copied state as-is, including crop fields.
    /// Returns `nil` if the clipboard is empty.
    public func pasteIncludingCrop() -> EditState? {
        copiedState
    }
}
