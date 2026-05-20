import DriveClient
import Foundation

/// One page of `drive.changes.list`, lifted into a SyncEngine-native
/// type so the poller doesn't have to depend on DriveClient's raw JSON
/// shape (and tests don't have to hand-craft HTTP bodies).
public struct DriveChangesPage: Sendable, Equatable {
    public let changes: [DriveChange]
    public let nextPageToken: String?
    public let newStartPageToken: String?

    public init(
        changes: [DriveChange],
        nextPageToken: String? = nil,
        newStartPageToken: String? = nil
    ) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

/// Subset of a Drive change record the poller actually reads.
public struct DriveChange: Sendable, Equatable {
    public let fileId: String
    public let removed: Bool
    public let trashed: Bool
    public let name: String?
    public let mimeType: String?
    public let modifiedTime: String?
    public let parents: [String]

    public init(
        fileId: String,
        removed: Bool = false,
        trashed: Bool = false,
        name: String? = nil,
        mimeType: String? = nil,
        modifiedTime: String? = nil,
        parents: [String] = []
    ) {
        self.fileId = fileId
        self.removed = removed
        self.trashed = trashed
        self.name = name
        self.mimeType = mimeType
        self.modifiedTime = modifiedTime
        self.parents = parents
    }
}

/// Abstraction over Drive's `changes` endpoints. The poller depends on
/// this protocol so unit tests can swap in a programmable stub without
/// going near HTTP.
public protocol DriveChangesFetching: Sendable {
    /// Establish a baseline page token for first sync.
    func startPageToken() async throws -> String
    /// Fetch a single page of changes since `pageToken`. The poller is
    /// responsible for walking `nextPageToken` until `newStartPageToken`.
    func listChanges(pageToken: String) async throws -> DriveChangesPage
}
