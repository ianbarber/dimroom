import AppKit
import EditEngine
import SwiftUI

/// Export options sheet presented by File → Export… (Cmd+Shift+E).
///
/// Lets the user pick a destination folder, format (Original / JPEG / TIFF),
/// JPEG quality, and whether to bake edits into the output. The sheet
/// reports the user's choices through the `onExport` closure; the caller
/// (ContentView / HarnessController) is responsible for driving the
/// `ExportCoordinator`.
public struct ExportSheetView: View {
    @State private var destinationURL: URL?
    @State private var format: ExportFormat = .original
    @State private var jpegQuality: Double = 85
    @State private var applyEdits: Bool = true

    let assetCount: Int
    let onExport: (URL, ExportFormat, Int, Bool) -> Void
    let onCancel: () -> Void

    public init(
        assetCount: Int,
        onExport: @escaping (URL, ExportFormat, Int, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.assetCount = assetCount
        self.onExport = onExport
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export \(assetCount) \(assetCount == 1 ? "Photo" : "Photos")")
                .font(.headline)

            // Destination picker
            HStack {
                Text("Destination:")
                    .frame(width: 90, alignment: .trailing)
                Text(destinationURL?.lastPathComponent ?? "No folder selected")
                    .foregroundStyle(destinationURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose...") {
                    chooseDestination()
                }
            }

            // Format picker
            HStack {
                Text("Format:")
                    .frame(width: 90, alignment: .trailing)
                Picker("", selection: $format) {
                    Text("Original").tag(ExportFormat.original)
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF (16-bit)").tag(ExportFormat.tiff)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // JPEG quality slider (only visible when JPEG is selected)
            if format == .jpeg {
                HStack {
                    Text("Quality:")
                        .frame(width: 90, alignment: .trailing)
                    Slider(value: $jpegQuality, in: 0...100, step: 1)
                    Text("\(Int(jpegQuality))")
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }

            // Apply edits toggle
            HStack {
                Text("")
                    .frame(width: 90)
                Toggle("Apply edits", isOn: $applyEdits)
            }

            Divider()

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export") {
                    guard let url = destinationURL else { return }
                    onExport(url, format, Int(jpegQuality), applyEdits)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destinationURL == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose export destination"
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            destinationURL = panel.url
        }
    }
}
