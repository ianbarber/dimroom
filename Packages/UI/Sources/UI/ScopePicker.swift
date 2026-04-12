import Catalog
import SwiftUI

/// Dropdown menu for scoping the Library grid to a single import
/// session or showing all photos. Sits in the filter bar alongside
/// the rating picker.
struct ScopePicker: View {
    let sessions: [ImportSessionSummary]
    @Binding var selectedSessionId: UUID?

    var body: some View {
        Menu {
            Button {
                selectedSessionId = nil
            } label: {
                if selectedSessionId == nil {
                    Label("All Photos", systemImage: "checkmark")
                } else {
                    Text("All Photos")
                }
            }

            if !sessions.isEmpty {
                Divider()
                ForEach(sessions) { session in
                    Button {
                        selectedSessionId = session.id
                    } label: {
                        if selectedSessionId == session.id {
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
            HStack(spacing: 4) {
                Image(systemName: "tray.2")
                Text(currentLabel)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Color(white: 0.7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentLabel: String {
        guard let id = selectedSessionId,
              let session = sessions.first(where: { $0.id == id }) else {
            return "All Photos"
        }
        return session.displayName
    }
}
