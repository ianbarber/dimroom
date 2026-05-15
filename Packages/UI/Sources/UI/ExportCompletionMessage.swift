import Foundation

/// Pure text builder for the post-export alert. Turns the
/// `ExportCoordinator`'s terminal counts into a title + body the UI can
/// drop straight into a SwiftUI `.alert`. Kept separate so the copy is
/// snapshot-testable without having to materialise an alert sheet.
public struct ExportCompletionMessage: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// Compose the alert copy from the coordinator's completion counts.
    /// Branches: all-success, partial, and total-failure. Failure
    /// reasons (one line per failed asset) are truncated to the first
    /// three with a "…and N more." tail so a large error list doesn't
    /// overflow the alert.
    public static func forCompletion(
        exported: Int,
        skipped: Int,
        failures: [String]
    ) -> ExportCompletionMessage {
        let total = exported + skipped
        if skipped == 0 {
            return ExportCompletionMessage(
                title: "Export complete",
                body: "Exported \(exported) \(exported == 1 ? "photo" : "photos")."
            )
        }
        if exported == 0 {
            let reasons = formatReasons(failures)
            return ExportCompletionMessage(
                title: "Export failed",
                body: reasons.isEmpty
                    ? "No photos were exported."
                    : "No photos were exported.\n\(reasons)"
            )
        }
        let reasons = formatReasons(failures)
        let head = "Exported \(exported) of \(total). \(skipped) \(skipped == 1 ? "photo was" : "photos were") skipped."
        let body = reasons.isEmpty ? head : "\(head)\n\(reasons)"
        return ExportCompletionMessage(
            title: "Export finished with issues",
            body: body
        )
    }

    private static func formatReasons(_ failures: [String]) -> String {
        guard !failures.isEmpty else { return "" }
        let shown = failures.prefix(3).joined(separator: "\n")
        if failures.count > 3 {
            return shown + "\n…and \(failures.count - 3) more."
        }
        return shown
    }
}
