import Foundation

/// Drive v3 `changes` endpoint request builders + `Codable` response
/// types used by the delta sync poller. Pure URLRequest / JSON shaping —
/// no network, no state. Mirrors the shape of `DriveFilesAPI`.
public enum DriveChangesAPI {

    public static let startPageTokenEndpoint = URL(
        string: "https://www.googleapis.com/drive/v3/changes/startPageToken"
    )!
    public static let changesEndpoint = URL(
        string: "https://www.googleapis.com/drive/v3/changes"
    )!

    /// `GET /drive/v3/changes/startPageToken` — establishes a baseline
    /// page token. Called once on first sync (no stored token).
    public static func startPageTokenRequest() -> URLRequest {
        var request = URLRequest(url: startPageTokenEndpoint)
        request.httpMethod = "GET"
        return request
    }

    /// `GET /drive/v3/changes` — list changes since `pageToken`.
    /// `pageSize` is capped at 1000 by Drive; we default to 100, which
    /// is plenty for the 5-minute polling cadence.
    public static func changesListRequest(
        pageToken: String,
        pageSize: Int = 100
    ) -> URLRequest {
        var components = URLComponents(url: changesEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,newStartPageToken,changes(changeType,removed,fileId,time,file(id,name,mimeType,modifiedTime,parents,trashed,appProperties))"
            ),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Response types

    public struct ChangeFile: Codable, Sendable, Equatable {
        public let id: String
        public let name: String?
        public let mimeType: String?
        public let modifiedTime: String?
        public let parents: [String]?
        public let trashed: Bool?
        public let appProperties: [String: String]?

        public init(
            id: String,
            name: String? = nil,
            mimeType: String? = nil,
            modifiedTime: String? = nil,
            parents: [String]? = nil,
            trashed: Bool? = nil,
            appProperties: [String: String]? = nil
        ) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.modifiedTime = modifiedTime
            self.parents = parents
            self.trashed = trashed
            self.appProperties = appProperties
        }
    }

    public struct Change: Codable, Sendable, Equatable {
        public let changeType: String?
        public let removed: Bool?
        public let fileId: String?
        public let time: String?
        public let file: ChangeFile?

        public init(
            changeType: String? = nil,
            removed: Bool? = nil,
            fileId: String? = nil,
            time: String? = nil,
            file: ChangeFile? = nil
        ) {
            self.changeType = changeType
            self.removed = removed
            self.fileId = fileId
            self.time = time
            self.file = file
        }
    }

    public struct ChangeList: Codable, Sendable, Equatable {
        public let nextPageToken: String?
        public let newStartPageToken: String?
        public let changes: [Change]

        public init(
            nextPageToken: String? = nil,
            newStartPageToken: String? = nil,
            changes: [Change] = []
        ) {
            self.nextPageToken = nextPageToken
            self.newStartPageToken = newStartPageToken
            self.changes = changes
        }
    }

    public struct StartPageTokenResponse: Codable, Sendable, Equatable {
        public let startPageToken: String

        public init(startPageToken: String) {
            self.startPageToken = startPageToken
        }
    }
}
