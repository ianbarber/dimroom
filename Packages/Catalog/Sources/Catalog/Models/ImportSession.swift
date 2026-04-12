import Foundation
import GRDB

public struct ImportSession: Identifiable, Codable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var sourceKind: String
    public var sourceDevice: String?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        sourceKind: String,
        sourceDevice: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.sourceKind = sourceKind
        self.sourceDevice = sourceDevice
        self.notes = notes
    }

    /// Human-readable label: `"{device} — {date}"` or `"Folder — {date}"`.
    public func displayName() -> String {
        let device = sourceDevice ?? "Folder"
        let dateString = Self.displayDateFormatter.string(from: startedAt)
        return "\(device) — \(dateString)"
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}

extension ImportSession: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "import_sessions" }
}
