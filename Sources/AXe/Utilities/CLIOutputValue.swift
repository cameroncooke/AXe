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

    /// The value `JSONDecoder().decode(CLIOutputValue.self, from:)` returns, without its cost.
    /// `init(from:)` probes each value with failing typed decodes, and each failure builds a
    /// DecodingError, so a large accessibility tree spends tens of milliseconds throwing. This
    /// parses strict JSON directly and hands anything it does not cover to the decoder.
    static func decodingJSON(_ data: Data) throws -> CLIOutputValue {
        let parsed = data.withUnsafeBytes { raw -> CLIOutputValue? in
            var parser = CLIOutputJSONParser(bytes: raw.bindMemory(to: UInt8.self))
            return parser.document()
        }
        if let parsed { return parsed }
        return try JSONDecoder().decode(CLIOutputValue.self, from: data)
    }
}

/// Strict JSON (RFC 8259) into `CLIOutputValue`. Every method returns nil for input it does
/// not handle exactly as `init(from:)` would, and the caller then uses the decoder instead.
private struct CLIOutputJSONParser {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private var depth = 0
    /// Well below the decoder's own nesting limit, so deeper input gets the decoder's answer.
    private static let maximumDepth = 256

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func document() -> CLIOutputValue? {
        skipWhitespace()
        guard let value = value() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func value() -> CLIOutputValue? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(CLIOutputValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func object() -> CLIOutputValue? {
        guard enter() else { return nil }
        defer { depth -= 1 }
        index += 1
        var values: [String: CLIOutputValue] = [:]
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return .object(values) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { return nil }
            skipWhitespace()
            // The decoder's choice between duplicate keys is its own; leave such input to it.
            guard let value = value(), values.updateValue(value, forKey: key) == nil else { return nil }
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(values) }
            guard consume(UInt8(ascii: ",")) else { return nil }
        }
    }

    private mutating func array() -> CLIOutputValue? {
        guard enter() else { return nil }
        defer { depth -= 1 }
        index += 1
        var values: [CLIOutputValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return .array(values) }
        while true {
            skipWhitespace()
            guard let value = value() else { return nil }
            values.append(value)
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(values) }
            guard consume(UInt8(ascii: ",")) else { return nil }
        }
    }

    /// Reads a string at the opening quote.
    private mutating func string() -> String? {
        index += 1
        let start = index
        var ascii = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let text = utf8(start..<index, ascii: ascii)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { return escapedString(prefix: start..<index, ascii: ascii) }
            if byte < 0x20 { return nil }
            if byte >= 0x80 { ascii = false }
            index += 1
        }
        return nil
    }

    private mutating func escapedString(prefix: Range<Int>, ascii prefixIsASCII: Bool) -> String? {
        guard var text = utf8(prefix, ascii: prefixIsASCII) else { return nil }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): text.append("\"")
                case UInt8(ascii: "\\"): text.append("\\")
                case UInt8(ascii: "/"): text.append("/")
                case UInt8(ascii: "b"): text.append("\u{08}")
                case UInt8(ascii: "f"): text.append("\u{0C}")
                case UInt8(ascii: "n"): text.append("\n")
                case UInt8(ascii: "r"): text.append("\r")
                case UInt8(ascii: "t"): text.append("\t")
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else { return nil }
                    text.unicodeScalars.append(scalar)
                default: return nil
                }
                continue
            }
            if byte < 0x20 { return nil }
            let start = index
            var ascii = true
            while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\"),
                  bytes[index] >= 0x20 {
                if bytes[index] >= 0x80 { ascii = false }
                index += 1
            }
            guard let run = utf8(start..<index, ascii: ascii) else { return nil }
            text += run
        }
        return nil
    }

    /// Reads the four hex digits after `\u`, and the low half of a surrogate pair.
    /// A lone surrogate goes to the decoder.
    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let high = hexQuad() else { return nil }
        if (0xD800...0xDBFF).contains(high) {
            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
            else { return nil }
            index += 2
            guard let low = hexQuad(), (0xDC00...0xDFFF).contains(low) else { return nil }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        }
        return Unicode.Scalar(high)
    }

    private mutating func hexQuad() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    /// Invalid UTF-8 goes to the decoder. Valid UTF-8 round-trips byte for byte; invalid bytes come
    /// back as U+FFFD and do not. Foundation's `String(bytes:encoding:)` would drop a leading U+FEFF,
    /// which the decoder keeps, and `String(validating:as:)` needs macOS 15.
    private func utf8(_ range: Range<Int>, ascii: Bool) -> String? {
        let slice = UnsafeBufferPointer(rebasing: bytes[range])
        let text = String(decoding: slice, as: UTF8.self)
        if ascii { return text }
        return text.utf8.elementsEqual(slice) ? text : nil
    }

    /// Integers and non-integral finite numbers take the same values `init(from:)` gives them;
    /// verified against the decoder for both encoders' renderings of random doubles. Integral
    /// literals with a fraction or exponent (`1.0`, `1e2`) and integers outside Int64 and UInt64
    /// depend on decoder details, so the decoder reads those literals itself.
    private mutating func number() -> CLIOutputValue? {
        let start = index
        _ = consume(UInt8(ascii: "-"))
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "0") { index += 1 }
        else if !digits() { return nil }
        var integral = true
        if consume(UInt8(ascii: ".")) {
            integral = false
            guard digits() else { return nil }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            integral = false
            index += 1
            if !consume(UInt8(ascii: "+")) { _ = consume(UInt8(ascii: "-")) }
            guard digits() else { return nil }
        }
        let literal = UnsafeBufferPointer(rebasing: bytes[start..<index])
        let text = String(decoding: literal, as: UTF8.self)
        if integral {
            if let value = Int64(text) { return .integer(value) }
            if let value = UInt64(text) { return .unsignedInteger(value) }
        } else if let value = Double(text), value.isFinite, value.rounded(.towardZero) != value {
            if let decimal = Decimal(string: text, locale: nil),
               NSDecimalNumber(decimal: decimal).doubleValue == value {
                return .number(decimal)
            }
            return .floatingPoint(value)
        }
        return try? JSONDecoder().decode(CLIOutputValue.self, from: Data(literal))
    }

    private mutating func digits() -> Bool {
        let start = index
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        return index > start
    }

    private mutating func literal(_ word: StaticString, _ value: CLIOutputValue) -> CLIOutputValue? {
        let count = word.utf8CodeUnitCount
        guard index + count <= bytes.count else { return nil }
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: count)
        for offset in 0..<count where bytes[index + offset] != expected[offset] { return nil }
        index += count
        return value
    }

    private mutating func enter() -> Bool {
        depth += 1
        return depth <= Self.maximumDepth
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }
}
