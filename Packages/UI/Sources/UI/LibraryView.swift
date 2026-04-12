import SwiftUI

/// The library grid — home screen for browsing the catalog.
///
/// Always renders either the empty-state placeholder or a 4-column
/// `LazyVGrid` of cached thumbnails. Selection lives on the view model
/// (`selectedAssetId`) so the harness and keyboard shortcuts can observe
/// and mutate it without threading state through view hierarchy.
public struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel

    public init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    private static let columnCount = 4
    private static let cellSpacing: CGFloat = 8

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
            count: Self.columnCount
        )
    }

    public var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                LibraryEmptyState()
            } else {
                grid
            }
        }
        .background(Color(white: 0.08))
        .task {
            viewModel.reload()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                ForEach(viewModel.rows) { row in
                    LibraryCell(
                        row: row,
                        isSelected: row.id == viewModel.selectedAssetId
                    )
                    .onTapGesture {
                        viewModel.select(row.id)
                    }
                }
            }
            .padding(Self.cellSpacing)
        }
    }
}
