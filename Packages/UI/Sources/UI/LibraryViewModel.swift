import Catalog
import Combine
import Foundation
import Previews

/// Drives the library grid. Holds the sorted, filtered list of assets the
/// grid displays plus the current single-selection. Construct with
/// injected `CatalogDatabase` and `PreviewStore`; no globals.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var rows: [LibraryRow] = []
    @Published public var selectedAssetId: UUID?

    private let catalog: CatalogDatabase
    private let previewStore: PreviewStore

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    /// Reload non-deleted assets from the catalog, sort them newest-first,
    /// and resolve their thumbnail URLs. If the selected asset disappears
    /// on reload, selection is cleared.
    public func reload() {
        let fetched: [Asset]
        do {
            fetched = try catalog.fetchAssets(filter: AssetFilter())
        } catch {
            // Catalog read failures are rare and non-recoverable from the
            // view. Surface them as an empty grid rather than crashing.
            rows = []
            selectedAssetId = nil
            return
        }

        let sorted = fetched.sorted { lhs, rhs in
            Self.effectiveDate(for: lhs) > Self.effectiveDate(for: rhs)
        }
        let resolved = sorted.map { asset in
            LibraryRow(
                asset: asset,
                thumbnailURL: previewStore.thumbnailURL(for: asset)
            )
        }
        rows = resolved
        if let currentSelection = selectedAssetId,
           !resolved.contains(where: { $0.id == currentSelection }) {
            selectedAssetId = nil
        }
    }

    /// Set the current single-selection. Passing `nil` clears it.
    public func select(_ assetId: UUID?) {
        selectedAssetId = assetId
    }

    /// Sort key: prefer capture date (when a photo was taken) and fall
    /// back to import date for scans / screenshots that don't carry EXIF.
    private static func effectiveDate(for asset: Asset) -> Date {
        asset.captureDate ?? asset.importedDate
    }
}
