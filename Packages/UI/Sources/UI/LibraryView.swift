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

    private static let cellSpacing: CGFloat = 8

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
            count: LibraryViewModel.columnCount
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            Group {
                if viewModel.rows.isEmpty {
                    LibraryEmptyState()
                } else {
                    grid
                }
            }
        }
        .background(Color(white: 0.08))
        .task {
            viewModel.reload()
        }
    }

    /// Top-bar row containing the min-rating filter. Kept deliberately
    /// thin — a single `Picker` is enough to satisfy the issue's
    /// "Picker / SegmentedControl / custom" latitude. A star-chip
    /// custom control can come in a follow-up if the plain picker ever
    /// feels wrong in practice.
    private var filterBar: some View {
        HStack(spacing: 12) {
            ScopePicker(
                sessions: viewModel.recentSessions,
                selectedSessionId: scopeBinding
            )
            Divider()
                .frame(height: 16)
            Text("Min rating")
                .font(.caption)
                .foregroundStyle(Color(white: 0.7))
            Picker("Min rating", selection: filterBinding) {
                Text("All").tag(0)
                ForEach(1...5, id: \.self) { n in
                    Text("\(n)★").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    /// Bridge the view model's `setMinRating(_:)` async entry point into
    /// a SwiftUI `Binding<Int>`. The picker only writes on user input,
    /// so kicking off a `Task` from the setter is fine — there's no
    /// chance of a reentrant redraw.
    private var filterBinding: Binding<Int> {
        Binding(
            get: { viewModel.minRating },
            set: { newValue in
                Task { await viewModel.setMinRating(newValue) }
            }
        )
    }

    private var scopeBinding: Binding<UUID?> {
        Binding(
            get: { viewModel.scopeSessionId },
            set: { newValue in
                Task { await viewModel.setScope(newValue) }
            }
        )
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                    ForEach(viewModel.rows) { row in
                        LibraryCell(
                            row: row,
                            isSelected: row.id == viewModel.selectedAssetId,
                            rowVersion: viewModel.rowVersion
                        )
                        .id(row.id)
                        .onTapGesture {
                            viewModel.select(row.id)
                        }
                    }
                }
                .padding(Self.cellSpacing)
            }
            .onChange(of: viewModel.pendingScrollToAssetId) { _, newValue in
                if let id = newValue {
                    proxy.scrollTo(id, anchor: nil)
                    viewModel.pendingScrollToAssetId = nil
                }
            }
        }
    }
}
