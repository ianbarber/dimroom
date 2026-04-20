import Foundation

/// Drive v3 request builders and response Codables used by the uploader.
/// Pure URLRequest / JSON shaping — no network, no state. Kept small and
/// testable so the flows built on top can focus on orchestration.
public enum DriveFilesAPI {

    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let filesEndpoint = URL(string: "https://www.googleapis.com/drive/v3/files")!
    public static let uploadEndpoint = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!

    /// `GET /drive/v3/files` — list immediate children of `parentId` with
    /// the given name / mimeType filter. Used by the folder resolver to
    /// check "does this segment already exist?" before creating it.
    public static func listFolderRequest(name: String, parentId: String) -> URLRequest {
        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)!
        let query = #"name = '\#(escapeForDriveQuery(name))' and mimeType = '\#(folderMimeType)' and '\#(parentId)' in parents and trashed = false"#
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    /// `POST /drive/v3/files` — create a folder named `name` under
    /// `parentId`.
    public static func createFolderRequest(name: String, parentId: String) throws -> URLRequest {
        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "mimeType": folderMimeType,
            "parents": [parentId],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// `GET /drive/v3/files` — look up an existing file inside `parentId`
    /// whose `appProperties.contentHash` equals the given hash. Kept as
    /// the per-folder fallback for `DriveUploader` when `DedupScope.folder`
    /// is selected; the default `.library` path uses
    /// `findByContentHashAnywhereRequest` so re-imports under a different
    /// capture date still dedup.
    public static func findByContentHashRequest(contentHash: String, parentId: String) -> URLRequest {
        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)!
        let query = #"appProperties has { key='contentHash' and value='\#(escapeForDriveQuery(contentHash))' } and '\#(parentId)' in parents and trashed = false"#
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,appProperties)"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    /// `GET /drive/v3/files` — library-wide variant of
    /// `findByContentHashRequest`. Drops the `'<parent>' in parents`
    /// clause so a match anywhere under the app's Drive (same
    /// `appProperties.contentHash`) deduplicates. Used by default so
    /// re-importing a photo months after the original upload (or under a
    /// different capture date) still short-circuits to the existing file.
    public static func findByContentHashAnywhereRequest(contentHash: String) -> URLRequest {
        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)!
        let query = #"appProperties has { key='contentHash' and value='\#(escapeForDriveQuery(contentHash))' } and trashed = false"#
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,appProperties)"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Response types

    public struct DriveFile: Codable, Sendable, Equatable {
        public let id: String
        public let name: String?
        public let appProperties: [String: String]?

        public init(id: String, name: String? = nil, appProperties: [String: String]? = nil) {
            self.id = id
            self.name = name
            self.appProperties = appProperties
        }
    }

    public struct DriveFileList: Codable, Sendable, Equatable {
        public let files: [DriveFile]

        public init(files: [DriveFile]) {
            self.files = files
        }
    }

    // MARK: - Helpers

    /// Escapes single quotes and backslashes in Drive query strings per
    /// the v3 query grammar.
    static func escapeForDriveQuery(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            if c == "\\" || c == "'" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }
}
