import Foundation

/// Response sent back over the harness socket.
public struct Response: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        case error
    }

    public let status: Status
    public let data: AnyCodableValue?
    public let error: String?

    public init(status: Status, data: AnyCodableValue? = nil, error: String? = nil) {
        self.status = status
        self.data = data
        self.error = error
    }

    public static func ok(data: AnyCodableValue? = nil) -> Response {
        Response(status: .ok, data: data)
    }

    public static func error(_ message: String) -> Response {
        Response(status: .error, error: message)
    }
}

/// A type-erased Codable value for embedding arbitrary JSON in responses.
public enum AnyCodableValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let dbl = try? container.decode(Double.self) {
            self = .double(dbl)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dictionary(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
