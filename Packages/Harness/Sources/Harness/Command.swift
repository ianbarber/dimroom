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
    case selectAsset(id: UUID)
    case setRating(assetId: UUID, rating: Int)
    case rotate(assetId: UUID, direction: String)
    case goBack
    case setFilter(minRating: Int)
    case copyEdit(assetId: UUID)
    case pasteEdit(assetId: UUID, includeCrop: Bool)
    case setEdit(assetId: UUID, stateJSON: String)
    case getEdit(assetId: UUID)
    case setScope(importSessionId: UUID?)
    case listImportSessions
    case selectNext
    case selectPrevious
    case selectUp
    case selectDown
    case zoomToggle
    case zoomReset

    private enum CodingKeys: String, CodingKey {
        case type
        case route
        case path
        case id
        case assetId
        case rating
        case direction
        case minRating
        case includeCrop
        case stateJSON
        case importSessionId
    }

    private enum CommandType: String, Codable {
        case navigate
        case screenshot
        case state
        case quit
        case importFolder
        case listAssets
        case selectAsset
        case setRating
        case rotate
        case goBack
        case setFilter
        case copyEdit
        case pasteEdit
        case setEdit
        case getEdit
        case setScope
        case listImportSessions
        case selectNext
        case selectPrevious
        case selectUp
        case selectDown
        case zoomToggle
        case zoomReset
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
        case .selectAsset:
            let id = try container.decode(UUID.self, forKey: .id)
            self = .selectAsset(id: id)
        case .setRating:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let rating = try container.decode(Int.self, forKey: .rating)
            self = .setRating(assetId: assetId, rating: rating)
        case .rotate:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? "cw"
            self = .rotate(assetId: assetId, direction: direction)
        case .goBack:
            self = .goBack
        case .setFilter:
            let minRating = try container.decode(Int.self, forKey: .minRating)
            self = .setFilter(minRating: minRating)
        case .copyEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .copyEdit(assetId: assetId)
        case .pasteEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let includeCrop = try container.decode(Bool.self, forKey: .includeCrop)
            self = .pasteEdit(assetId: assetId, includeCrop: includeCrop)
        case .setEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let stateJSON = try container.decode(String.self, forKey: .stateJSON)
            self = .setEdit(assetId: assetId, stateJSON: stateJSON)
        case .getEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .getEdit(assetId: assetId)
        case .setScope:
            let sessionId = try container.decodeIfPresent(UUID.self, forKey: .importSessionId)
            self = .setScope(importSessionId: sessionId)
        case .listImportSessions:
            self = .listImportSessions
        case .selectNext:
            self = .selectNext
        case .selectPrevious:
            self = .selectPrevious
        case .selectUp:
            self = .selectUp
        case .selectDown:
            self = .selectDown
        case .zoomToggle:
            self = .zoomToggle
        case .zoomReset:
            self = .zoomReset
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
        case .selectAsset(let id):
            try container.encode(CommandType.selectAsset, forKey: .type)
            try container.encode(id, forKey: .id)
        case .setRating(let assetId, let rating):
            try container.encode(CommandType.setRating, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(rating, forKey: .rating)
        case .rotate(let assetId, let direction):
            try container.encode(CommandType.rotate, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(direction, forKey: .direction)
        case .goBack:
            try container.encode(CommandType.goBack, forKey: .type)
        case .setFilter(let minRating):
            try container.encode(CommandType.setFilter, forKey: .type)
            try container.encode(minRating, forKey: .minRating)
        case .copyEdit(let assetId):
            try container.encode(CommandType.copyEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .pasteEdit(let assetId, let includeCrop):
            try container.encode(CommandType.pasteEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(includeCrop, forKey: .includeCrop)
        case .setEdit(let assetId, let stateJSON):
            try container.encode(CommandType.setEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(stateJSON, forKey: .stateJSON)
        case .getEdit(let assetId):
            try container.encode(CommandType.getEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .setScope(let sessionId):
            try container.encode(CommandType.setScope, forKey: .type)
            try container.encodeIfPresent(sessionId, forKey: .importSessionId)
        case .listImportSessions:
            try container.encode(CommandType.listImportSessions, forKey: .type)
        case .selectNext:
            try container.encode(CommandType.selectNext, forKey: .type)
        case .selectPrevious:
            try container.encode(CommandType.selectPrevious, forKey: .type)
        case .selectUp:
            try container.encode(CommandType.selectUp, forKey: .type)
        case .selectDown:
            try container.encode(CommandType.selectDown, forKey: .type)
        case .zoomToggle:
            try container.encode(CommandType.zoomToggle, forKey: .type)
        case .zoomReset:
            try container.encode(CommandType.zoomReset, forKey: .type)
        }
    }
}
