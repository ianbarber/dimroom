import AppKit
import SwiftUI

/// The library grid — home screen for browsing the catalog.
///
/// Always renders either the empty-state placeholder or a 4-column
/// `LazyVGrid` of cached thumbnails. Selection lives on the view model
/// (`selectedAssetIds`) so the harness and keyboard shortcuts can observe
/// and mutate it without threading state through view hierarchy.
public struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    /// Binding controlled by `ContentView` so Delete/Backspace can open
    /// the confirmation dialog hosted by this view. Bound externally so
    /// the key handler at the app root can set it without the grid
    /// needing to be focused. Optional so previews / tests can ignore it.
    @Binding private var pendingDeleteCount: Int?
    /// Navigate to Loupe for `assetId`. Invoked by the double-click
    /// handler on a thumbnail — the view model has already moved the
    /// primary selection to `assetId` by the time this fires. Defaulted
    /// to a no-op so previews and snapshot tests don't need to care
    /// about routing.
    private let onOpenLoupe: (UUID) -> Void

    public init(
        viewModel: LibraryViewModel,
        pendingDeleteCount: Binding<Int?> = .constant(nil),
        onOpenLoupe: @escaping (UUID) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self._pendingDeleteCount = pendingDeleteCount
        self.onOpenLoupe = onOpenLoupe
    }

    private static let cellSpacing: CGFloat = 8

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.cellSpacing),
            count: viewModel.columnCount
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
        .overlay(alignment: .bottom) {
            UndoToastView(
                toast: $viewModel.undoToast,
                onUndo: { Task { await viewModel.undoLastDelete() } }
            )
            .padding(.bottom, 24)
            .animation(.easeInOut(duration: 0.2), value: viewModel.undoToast)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteCount
        ) { count in
            Button("Delete", role: .destructive) {
                pendingDeleteCount = nil
                Task { await viewModel.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteCount = nil
            }
        } message: { count in
            Text("They will be moved to Recently Deleted and can be recovered within 30 days.")
        }
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
                selectedScope: scopeBinding
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
            // Why: `.pickerStyle(.segmented)` is backed by NSSegmentedControl,
            // which renders segment text in its default (near-black) color and
            // ignores `.foregroundStyle` applied to the inner `Text` views.
            // Forcing dark color scheme makes the system-supplied segment text
            // light, restoring contrast against the dark filter bar. See #241.
            // ImageRenderer renders segment text light regardless, so a
            // structural test (FilterBarStructureTests) guards this modifier.
            .colorScheme(.dark)
            if let badge = viewModel.remoteAdditionsBadge {
                remoteAdditionsBadgeView(badge)
            }
            Spacer()
            deleteButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    /// Non-modal "N new on Drive" capsule. Surfaces a delta-sync tick
    /// classified as `originalsChangedOnly` so the user knows there are
    /// remote photos worth pulling for, without auto-triggering a
    /// catalog reload (the next `catalogChanged` tick handles that).
    /// Tapping the close button clears the badge via the view model;
    /// a subsequent reload also clears it.
    private func remoteAdditionsBadgeView(
        _ badge: LibraryViewModel.RemoteAdditionsBadge
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption)
            Text(badgeText(for: badge.addedCount))
                .font(.caption)
                .lineLimit(1)
            Button {
                viewModel.dismissRemoteAdditionsBadge()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss new originals badge")
        }
        .foregroundStyle(Color(white: 0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(red: 0.12, green: 0.32, blue: 0.55))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(badge.addedCount) new on Drive")
    }

    private func badgeText(for count: Int) -> String {
        count == 1 ? "1 new on Drive" : "\(count) new on Drive"
    }

    /// Trash icon wired to the same `pendingDeleteCount` binding the
    /// menu shortcut uses, so the confirmation dialog path is
    /// identical regardless of how the user triggered it. Disabled
    /// — not hidden — when nothing is selected so users learn where
    /// the control lives before they have a selection.
    private var deleteButton: some View {
        Button {
            let count = viewModel.selectedAssetIds.count
            guard count > 0 else { return }
            pendingDeleteCount = count
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete Selected")
        .accessibilityLabel("Delete Selected")
        .disabled(viewModel.selectedAssetIds.isEmpty || viewModel.scope == .recentlyDeleted)
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

    private var scopeBinding: Binding<LibraryViewModel.Scope> {
        Binding(
            get: { viewModel.scope },
            set: { newValue in
                Task { await viewModel.setScope(newValue) }
            }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteCount != nil },
            set: { newValue in
                if !newValue { pendingDeleteCount = nil }
            }
        )
    }

    private var confirmationTitle: String {
        let count = pendingDeleteCount ?? 0
        return count == 1 ? "Delete 1 photo?" : "Delete \(count) photos?"
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.cellSpacing) {
                    ForEach(viewModel.rows) { row in
                        LibraryCell(
                            row: row,
                            isSelected: viewModel.selectedAssetIds.contains(row.id),
                            rowVersion: viewModel.rowVersion
                        )
                        .id(row.id)
                        // Double-tap must be registered before the
                        // single-tap handler so SwiftUI's gesture
                        // disambiguation routes a double-click to the
                        // Loupe-open path instead of the select path.
                        .onTapGesture(count: 2) {
                            viewModel.focus(row.id)
                            onOpenLoupe(row.id)
                        }
                        .onTapGesture {
                            handleTap(on: row.id)
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

    /// Translate a raw tap plus the current `NSEvent.modifierFlags` into
    /// the matching view-model action. `onTapGesture` doesn't expose
    /// modifiers, so we read them off the current event directly — this
    /// is the same trick AppKit selection handlers use.
    private func handleTap(on id: UUID) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) {
            viewModel.extendSelect(to: id)
        } else if modifiers.contains(.command) {
            viewModel.toggleSelect(id)
        } else {
            viewModel.select(id)
        }
    }
}
