import Foundation

/// JSON values without Foundation's untyped object graph.
indirect enum CLIOutputValue: Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Decimal)
    case floatingPoint(Double)
    case string(String)
    case array([CLIOutputValue])
    case object([String: CLIOutputValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(UInt64.self) { self = .unsignedInteger(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self), decoded.isFinite {
            if let decimal = try? value.decode(Decimal.self),
               NSDecimalNumber(decimal: decimal).doubleValue == decoded {
                self = .number(decimal)
            } else {
                self = .floatingPoint(decoded)
            }
        }
        else if let decoded = try? value.decode([CLIOutputValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: CLIOutputValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(decoded): try value.encode(decoded)
        case let .integer(decoded): try value.encode(decoded)
        case let .unsignedInteger(decoded): try value.encode(decoded)
        case let .number(decoded): try value.encode(decoded)
        case let .floatingPoint(decoded): try value.encode(decoded)
        case let .string(decoded): try value.encode(decoded)
        case let .array(decoded): try value.encode(decoded)
        case let .object(decoded): try value.encode(decoded)
        }
    }

    subscript(_ key: String) -> CLIOutputValue? {
        guard case let .object(values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var arrayValue: [CLIOutputValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var scalarText: String? {
        switch self {
        case .null: return "null"
        case let .bool(value): return String(value)
        case let .integer(value): return String(value)
        case let .unsignedInteger(value): return String(value)
        case let .number(value): return NSDecimalNumber(decimal: value).stringValue
        case let .floatingPoint(value): return String(value)
        case let .string(value): return value
        case .array, .object: return nil
        }
    }
}
