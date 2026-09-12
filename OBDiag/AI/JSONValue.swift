import Foundation

/// Minimal dynamic JSON value used for tool schemas, tool arguments and tool
/// results. Keeps the wire types strongly typed without a dependency.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return Format.number(value, decimals: 2)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            if value.lowercased() == "true" { return true }
            if value.lowercased() == "false" { return false }
            return nil
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    // MARK: Serialization

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    var prettyString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Schema helpers

extension JSONValue {
    static func schema(
        type: String = "object",
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        description: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(type),
            "properties": .object(properties)
        ]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        if let description { object["description"] = .string(description) }
        return .object(object)
    }

    static func stringProperty(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues { object["enum"] = .array(enumValues.map { .string($0) }) }
        return .object(object)
    }

    static func integerProperty(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    static func booleanProperty(_ description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    static func arrayProperty(_ description: String, items: JSONValue) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": items
        ])
    }
}
