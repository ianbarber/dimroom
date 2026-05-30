import Catalog
import SwiftUI

/// Dropdown menu for scoping the Library grid: All Photos, one of the
/// recent import sessions, or the Recently Deleted trash. Sits in the
/// filter bar alongside the rating picker.
struct ScopePicker: View {
    let sessions: [ImportSessionSummary]
    @Binding var selectedScope: LibraryViewModel.Scope

    var body: some View {
        Menu {
            Button {
                selectedScope = .all
            } label: {
                if selectedScope == .all {
                    Label("All Photos", systemImage: "checkmark")
                } else {
                    Text("All Photos")
                }
            }

            Button {
                selectedScope = .recentlyDeleted
            } label: {
                if selectedScope == .recentlyDeleted {
                    Label("Recently Deleted", systemImage: "checkmark")
                } else {
                    Text("Recently Deleted")
                }
            }

            if !sessions.isEmpty {
                Divider()
                ForEach(sessions) { session in
                    Button {
                        selectedScope = .session(session.id)
                    } label: {
                        if selectedScope == .session(session.id) {
                            Label(
                                "\(session.displayName) (\(session.assetCount))",
                                systemImage: "checkmark"
                            )
                        } else {
                            Text("\(session.displayName) (\(session.assetCount))")
                        }
                    }
                }
            }
        } label: {
            // Why: `.foregroundStyle` must be applied per-child here — not on
            // the enclosing HStack — because `Menu` with
            // `.menuStyle(.borderlessButton)` does not propagate foreground
            // style to its label subtree in live rendering (it renders as
            // black on dark gray). `ImageRenderer` *does* propagate it, so
            // offline snapshots can't catch a regression here; see
            // ScopePickerStructureTests for the structural guard.
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .foregroundStyle(Color(white: 0.7))
                Text(currentLabel)
                    .lineLimit(1)
                    .foregroundStyle(Color(white: 0.7))
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        // Why: `.menuStyle(.borderlessButton)` draws the *closed* label through
        // the system control foreground path in live AppKit, which ignores the
        // per-child `.foregroundStyle` set above — so the closed pill renders
        // near-black against the dark filter bar even though the open menu and
        // `ImageRenderer` snapshots look correct. Forcing the dark color scheme
        // makes the system-supplied closed label render light, restoring
        // contrast. Same rendering-path divergence as the segmented rating
        // Picker in #241; guarded structurally in ScopePickerStructureTests
        // because a pixel snapshot provably can't catch it (see #74, #121).
        .colorScheme(.dark)
        .fixedSize()
    }

    private var iconName: String {
        switch selectedScope {
        case .recentlyDeleted: return "trash"
        default: return "tray.2"
        }
    }

    private var currentLabel: String {
        switch selectedScope {
        case .all:
            return "All Photos"
        case .recentlyDeleted:
            return "Recently Deleted"
        case .session(let id):
            return sessions.first(where: { $0.id == id })?.displayName ?? "Session"
        }
    }
}
