import Foundation

/// Commands sent to the harness over the Unix socket.
/// JSON uses a `type` discriminator key, e.g. `{"type":"navigate","route":"library"}`.
public enum Command: Codable, Sendable, Equatable {
    case navigate(Route)
    case screenshot(path: String)
    case state
    case quit
    case importFolder(path: String)
    case listAssets

    private enum CodingKeys: String, CodingKey {
        case type
        case route
        case path
    }

    private enum CommandType: String, Codable {
        case navigate
        case screenshot
        case state
        case quit
        case importFolder
        case listAssets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CommandType.self, forKey: .type)
        switch type {
        case .navigate:
            let route = try container.decode(Route.self, forKey: .route)
            self = .navigate(route)
        case .screenshot:
            let path = try container.decode(String.self, forKey: .path)
            self = .screenshot(path: path)
        case .state:
            self = .state
        case .quit:
            self = .quit
        case .importFolder:
            let path = try container.decode(String.self, forKey: .path)
            self = .importFolder(path: path)
        case .listAssets:
            self = .listAssets
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .navigate(let route):
            try container.encode(CommandType.navigate, forKey: .type)
            try container.encode(route, forKey: .route)
        case .screenshot(let path):
            try container.encode(CommandType.screenshot, forKey: .type)
            try container.encode(path, forKey: .path)
        case .state:
            try container.encode(CommandType.state, forKey: .type)
        case .quit:
            try container.encode(CommandType.quit, forKey: .type)
        case .importFolder(let path):
            try container.encode(CommandType.importFolder, forKey: .type)
            try container.encode(path, forKey: .path)
        case .listAssets:
            try container.encode(CommandType.listAssets, forKey: .type)
        }
    }
}
