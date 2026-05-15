import Foundation

/// Decides whether File → Export should stop and ask the user to
/// confirm before kicking off a run that would export *every* asset in
/// the catalog.
///
/// The rule: prompt only when the user has no explicit intent — no
/// selection, no rating filter, and scope is "All Photos" — but the
/// library is non-empty. In any other case (explicit selection, a
/// filter, a session scope, or an empty library) we trust the user and
/// skip the confirmation.
public enum ExportConfirmationPolicy {

    /// - Returns: `true` when the caller should present a confirmation
    ///   dialog before starting the export; `false` to proceed directly.
    public static func shouldPrompt(
        scope: LibraryViewModel.Scope,
        minRating: Int,
        selectionEmpty: Bool,
        rowCount: Int
    ) -> Bool {
        guard selectionEmpty else { return false }
        guard minRating == 0 else { return false }
        guard rowCount > 0 else { return false }
        switch scope {
        case .all:
            return true
        case .session, .recentlyDeleted:
            return false
        }
    }
}
