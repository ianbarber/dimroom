import Foundation
import SyncEngine

/// Harness-only `DriveChangesFetching` driven by a JSON fixture on
/// disk. Production runs never see this — the App gates it on
/// `DIMROOM_HARNESS_DRIVE_CHANGES_FIXTURE=<path>`.
///
/// Fixture format:
/// ```
/// {
///   "startPageToken": "stub-token-0",
///   "pages": [
///     {
///       "newStartPageToken": "stub-token-1",
///       "changes": [
///         { "fileId": "...", "modifiedTime": "...", "name": "...",
///           "mimeType": "...", "parents": ["..."],
///           "removed": false, "trashed": false }
///       ]
///     },
///     { ... }
///   ]
/// }
/// ```
///
/// The stub serves `pages[0]` on the first `listChanges` call,
/// `pages[1]` on the second, and so on. Reaching the end repeats the
/// last page so a flow that runs more polls than the fixture defines
/// still gets a deterministic response.
final class HarnessStubChangesFetcher: DriveChangesFetching, @unchecked Sendable {
    struct FixtureChange: Codable {
        var fileId: String
        var modifiedTime: String?
        var name: String?
        var mimeType: String?
        var parents: [String]?
        var removed: Bool?
        var trashed: Bool?
    }

    struct FixturePage: Codable {
        var newStartPageToken: String
        var nextPageToken: String?
        var changes: [FixtureChange]
    }

    struct Fixture: Codable {
        var startPageToken: String
        var pages: [FixturePage]
    }

    private let lock = NSLock()
    private let fixturePath: String
    private var callIndex = 0

    init(fixturePath: String) {
        self.fixturePath = fixturePath
    }

    func startPageToken() async throws -> String {
        let fixture = try loadFixture()
        return fixture.startPageToken
    }

    func listChanges(pageToken: String) async throws -> DriveChangesPage {
        let fixture = try loadFixture()
        let index = lock.withLock { () -> Int in
            let i = min(callIndex, fixture.pages.count - 1)
            callIndex += 1
            return i
        }
        guard index >= 0, fixture.pages.indices.contains(index) else {
            return DriveChangesPage(changes: [], newStartPageToken: fixture.startPageToken)
        }
        let page = fixture.pages[index]
        let mapped = page.changes.map { change in
            DriveChange(
                fileId: change.fileId,
                removed: change.removed ?? false,
                trashed: change.trashed ?? false,
                name: change.name,
                mimeType: change.mimeType,
                modifiedTime: change.modifiedTime,
                parents: change.parents ?? []
            )
        }
        return DriveChangesPage(
            changes: mapped,
            nextPageToken: page.nextPageToken,
            newStartPageToken: page.newStartPageToken
        )
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: fixturePath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }
}
