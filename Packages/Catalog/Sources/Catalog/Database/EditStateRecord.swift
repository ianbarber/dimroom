import Foundation
import GRDB

struct EditStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "edit_states"

    var id: UUID
    var assetId: UUID
    var version: Int
    var state: String
    var createdAt: Date

    // MARK: - EditState encoding/decoding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encode(_ editState: EditState) throws -> String {
        let data = try encoder.encode(editState)
        return String(data: data, encoding: .utf8)!
    }

    func decodeState() throws -> EditState {
        let data = Data(state.utf8)
        return try Self.decoder.decode(EditState.self, from: data)
    }
}
