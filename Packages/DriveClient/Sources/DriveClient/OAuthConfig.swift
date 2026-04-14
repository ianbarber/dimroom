import Foundation

public struct OAuthConfig: Equatable {
    public var clientID: String
    public var clientSecret: String?
    public var scope: String
    public var authEndpoint: URL
    public var tokenEndpoint: URL

    public init(
        clientID: String,
        clientSecret: String? = nil,
        scope: String = "https://www.googleapis.com/auth/drive",
        authEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    public static let environmentVariable = "DIMROOM_GOOGLE_CLIENT_ID"
    public static let clientSecretEnvironmentVariable = "DIMROOM_GOOGLE_CLIENT_SECRET"

    public static func defaultConfigFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("dimroom/oauth.json")
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws -> OAuthConfig {
        if let id = environment[environmentVariable], !id.isEmpty {
            let secret = environment[clientSecretEnvironmentVariable].flatMap { $0.isEmpty ? nil : $0 }
            return OAuthConfig(clientID: id, clientSecret: secret)
        }
        let url = fileURL ?? defaultConfigFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(FileSchema.self, from: data)
            guard !file.client_id.isEmpty else {
                throw DriveClientError.clientIDNotConfigured
            }
            return OAuthConfig(
                clientID: file.client_id,
                clientSecret: file.client_secret?.isEmpty == true ? nil : file.client_secret
            )
        }
        throw DriveClientError.clientIDNotConfigured
    }

    private struct FileSchema: Decodable {
        let client_id: String
        let client_secret: String?
    }
}
