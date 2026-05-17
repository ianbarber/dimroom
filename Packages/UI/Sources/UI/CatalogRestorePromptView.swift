import Foundation
import SwiftUI

/// Layout for the catalog-restore prompt shown at launch when a fresh
/// machine finds a published catalog on Drive (or fails to download
/// one). Pure view — no actions. The alert/sheet layer wires buttons;
/// this view renders the body so the production NSAlert and the
/// Layer B snapshot share the same text shape.
public struct CatalogRestorePromptView: View {
    public enum Style: Equatable, Sendable {
        /// Catalog found, ask the user whether to restore. `photoCount`
        /// is omitted from the body when nil (legacy catalogs without
        /// `appProperties.dimroom_photo_count`).
        case restoreExisting(photoCount: Int?, sizeBytes: Int64, modifiedTime: Date?)
        /// No local catalog and no Drive auth — offer the user a way to
        /// connect Drive (and maybe restore) or start fresh.
        case offerConnect
        /// Catalog found but the download failed. Show the underlying
        /// reason and let the user fall back to a fresh local catalog.
        case restoreFailed(reason: String)
    }

    public let style: Style
    public let now: Date

    public init(style: Style, now: Date = Date()) {
        self.style = style
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(body(now: now))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 360, alignment: .leading)
    }

    public var title: String {
        switch style {
        case .restoreExisting:
            return "Restore Catalog From Drive?"
        case .offerConnect:
            return "Connect Google Drive?"
        case .restoreFailed:
            return "Restore Failed"
        }
    }

    public func body(now: Date) -> String {
        switch style {
        case .restoreExisting(let photoCount, let sizeBytes, let modifiedTime):
            return Self.restoreExistingBody(
                photoCount: photoCount,
                sizeBytes: sizeBytes,
                modifiedTime: modifiedTime,
                now: now
            )
        case .offerConnect:
            return Self.offerConnectBody
        case .restoreFailed(let reason):
            return Self.restoreFailedBody(reason: reason)
        }
    }

    static func restoreExistingBody(
        photoCount: Int?,
        sizeBytes: Int64,
        modifiedTime: Date?,
        now: Date
    ) -> String {
        var fragments: [String] = []
        if let photoCount {
            fragments.append("\(photoCount) photo\(photoCount == 1 ? "" : "s")")
        }
        let sizeMB = Double(sizeBytes) / 1_048_576
        fragments.append(String(format: "%.1f MB", sizeMB))
        if let modifiedTime {
            fragments.append("last updated \(Self.formattedDate(modifiedTime, now: now))")
        }
        let detail = fragments.joined(separator: ", ")
        return "Existing catalog found on Drive (\(detail)). Restore it to this machine, or start with an empty catalog?"
    }

    static let offerConnectBody: String =
        "No local catalog was found on this machine. Connect Google Drive to look for an existing catalog to restore, or start with an empty catalog."

    static func restoreFailedBody(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Couldn't download the catalog from Drive. Start with an empty catalog?"
        }
        return "Couldn't download the catalog from Drive: \(trimmed). Start with an empty catalog?"
    }

    static func formattedDate(_ date: Date, now: Date) -> String {
        // Use a fixed-locale absolute date so snapshot output is
        // deterministic regardless of the host's locale at test time.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        _ = now
        return formatter.string(from: date)
    }
}
