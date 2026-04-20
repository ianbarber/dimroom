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
    case setCrop(assetId: UUID, x: Double, y: Double, width: Double, height: Double, angle: Double)
    case setScope(importSessionId: UUID?)
    case setScopeRecentlyDeleted
    case listImportSessions
    case selectNext
    case selectPrevious
    case selectUp
    case selectDown
    case zoomToggle
    case zoomReset
    case export(destinationPath: String, format: String, applyEdits: Bool)
    case fetchOriginal(assetId: UUID)
    case setEditParameter(assetId: UUID, parameter: String, value: Double)
    case resetEditParameter(assetId: UUID, parameter: String)
    case undo
    case redo
    case selectAssets(ids: [UUID])
    case deleteAssets(ids: [UUID])
    case restoreAssets(ids: [UUID])
    case permanentlyDeleteAssets(ids: [UUID])
    case uploadToDrive(assetId: UUID)
    case getPreviewSignature(assetId: UUID)

    private enum CodingKeys: String, CodingKey {
        case type
        case route
        case path
        case id
        case ids
        case assetId
        case rating
        case direction
        case minRating
        case includeCrop
        case stateJSON
        case importSessionId
        case destinationPath
        case format
        case applyEdits
        case parameter
        case value
        case x
        case y
        case width
        case height
        case angle
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
        case setCrop
        case setScope
        case setScopeRecentlyDeleted
        case listImportSessions
        case selectNext
        case selectPrevious
        case selectUp
        case selectDown
        case zoomToggle
        case zoomReset
        case export
        case fetchOriginal
        case setEditParameter
        case resetEditParameter
        case undo
        case redo
        case selectAssets
        case deleteAssets
        case restoreAssets
        case permanentlyDeleteAssets
        case uploadToDrive
        case getPreviewSignature
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
        case .setCrop:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            let width = try container.decode(Double.self, forKey: .width)
            let height = try container.decode(Double.self, forKey: .height)
            let angle = try container.decode(Double.self, forKey: .angle)
            self = .setCrop(
                assetId: assetId,
                x: x,
                y: y,
                width: width,
                height: height,
                angle: angle
            )
        case .setScope:
            let sessionId = try container.decodeIfPresent(UUID.self, forKey: .importSessionId)
            self = .setScope(importSessionId: sessionId)
        case .setScopeRecentlyDeleted:
            self = .setScopeRecentlyDeleted
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
        case .export:
            let destinationPath = try container.decode(String.self, forKey: .destinationPath)
            let format = try container.decode(String.self, forKey: .format)
            let applyEdits = try container.decode(Bool.self, forKey: .applyEdits)
            self = .export(destinationPath: destinationPath, format: format, applyEdits: applyEdits)
        case .fetchOriginal:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .fetchOriginal(assetId: assetId)
        case .setEditParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            let value = try container.decode(Double.self, forKey: .value)
            self = .setEditParameter(assetId: assetId, parameter: parameter, value: value)
        case .resetEditParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            self = .resetEditParameter(assetId: assetId, parameter: parameter)
        case .undo:
            self = .undo
        case .redo:
            self = .redo
        case .selectAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .selectAssets(ids: ids)
        case .deleteAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .deleteAssets(ids: ids)
        case .restoreAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .restoreAssets(ids: ids)
        case .permanentlyDeleteAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .permanentlyDeleteAssets(ids: ids)
        case .uploadToDrive:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .uploadToDrive(assetId: assetId)
        case .getPreviewSignature:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .getPreviewSignature(assetId: assetId)
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
        case .setCrop(let assetId, let x, let y, let width, let height, let angle):
            try container.encode(CommandType.setCrop, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(angle, forKey: .angle)
        case .setScope(let sessionId):
            try container.encode(CommandType.setScope, forKey: .type)
            try container.encodeIfPresent(sessionId, forKey: .importSessionId)
        case .setScopeRecentlyDeleted:
            try container.encode(CommandType.setScopeRecentlyDeleted, forKey: .type)
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
        case .export(let destinationPath, let format, let applyEdits):
            try container.encode(CommandType.export, forKey: .type)
            try container.encode(destinationPath, forKey: .destinationPath)
            try container.encode(format, forKey: .format)
            try container.encode(applyEdits, forKey: .applyEdits)
        case .fetchOriginal(let assetId):
            try container.encode(CommandType.fetchOriginal, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .setEditParameter(let assetId, let parameter, let value):
            try container.encode(CommandType.setEditParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
            try container.encode(value, forKey: .value)
        case .resetEditParameter(let assetId, let parameter):
            try container.encode(CommandType.resetEditParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
        case .undo:
            try container.encode(CommandType.undo, forKey: .type)
        case .redo:
            try container.encode(CommandType.redo, forKey: .type)
        case .selectAssets(let ids):
            try container.encode(CommandType.selectAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .deleteAssets(let ids):
            try container.encode(CommandType.deleteAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .restoreAssets(let ids):
            try container.encode(CommandType.restoreAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .permanentlyDeleteAssets(let ids):
            try container.encode(CommandType.permanentlyDeleteAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .uploadToDrive(let assetId):
            try container.encode(CommandType.uploadToDrive, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .getPreviewSignature(let assetId):
            try container.encode(CommandType.getPreviewSignature, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        }
    }
}
