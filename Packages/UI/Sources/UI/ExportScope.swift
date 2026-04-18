import Catalog
import Foundation

/// Resolves which assets an export should operate on, given the current
/// selection and the rows currently visible in the library grid.
///
/// The spec (#61) is: if the user has anything selected, the export
/// should cover *only* that selection. If nothing is selected, it falls
/// back to everything the library is currently showing (i.e. respects
/// the rating filter and active scope).
///
/// Taking a `Set<UUID>` keeps the signature stable once multi-selection
/// lands — today callers always pass a 0- or 1-element set derived from
/// `LibraryViewModel.selectedAssetIds`.
public enum ExportScope {
    /// Return the assets to export, in the order they appear in `rows`.
    ///
    /// Selection is intersected with `rows` so a stale id (e.g. the
    /// selected asset was filtered out or deleted) degrades gracefully
    /// to the full visible set rather than producing an empty export.
    public static func resolve(
        selectedIds: Set<UUID>,
        rows: [LibraryRow]
    ) -> [Asset] {
        let matched = rows.filter { selectedIds.contains($0.id) }
        if !matched.isEmpty {
            return matched.map(\.asset)
        }
        return rows.map(\.asset)
    }
}
