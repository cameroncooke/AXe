import Foundation

enum RemoteXPCValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(Int64) // Nanoseconds since 1970.
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([RemoteXPCValue])
    case dictionary([String: RemoteXPCValue])

    var dictionaryValue: [String: RemoteXPCValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var dataValue: Data? {
        guard case .data(let value) = self else { return nil }
        return value
    }

    var uuidValue: UUID? {
        guard case .uuid(let value) = self else { return nil }
        return value
    }
}

enum RemoteXPCWireError: LocalizedError {
    case malformed(String)
    case unsupportedType(UInt32)
    case messageTooLarge
    case nestingTooDeep

    var errorDescription: String? {
        switch self {
        case .malformed(let field): return "Invalid RemoteXPC \(field)."
        case .unsupportedType(let tag): return "Unsupported RemoteXPC object type 0x\(String(tag, radix: 16))."
        case .messageTooLarge: return "RemoteXPC message exceeds the 64 MiB limit."
        case .nestingTooDeep: return "RemoteXPC object nesting exceeds the supported depth."
        }
    }
}

struct RemoteXPCMessage: Sendable, Equatable {
    private static let headerSize = 24
    private static let wrapperMagic: UInt32 = 0x29B0_0B92
    private static let payloadMagic: UInt32 = 0x4213_3742
    private static let payloadVersion: UInt32 = 5
    private static let maximumBodySize = 64 * 1024 * 1024

    let flags: UInt32
    let messageID: UInt64
    let body: RemoteXPCValue?

    func encode() throws -> Data {
        var writer = RemoteXPCWriter()
        writer.append(Self.wrapperMagic)
        writer.append(flags)
        let lengthIndex = writer.bytes.count
        writer.append(UInt64(0))
        writer.append(messageID)
        if let body {
            writer.append(Self.payloadMagic)
            writer.append(Self.payloadVersion)
            try writer.appendObject(body, depth: 0)
        }
        let bodySize = writer.bytes.count - Self.headerSize
        guard bodySize <= Self.maximumBodySize else { throw RemoteXPCWireError.messageTooLarge }
        writer.replace(at: lengthIndex, with: UInt64(bodySize))
        return writer.bytes
    }

    // One HTTP/2 DATA payload can hold part of a wrapper or more than one wrapper.
    static func decodePrefix(_ bytes: Data) throws -> (message: Self, bytesConsumed: Int)? {
        guard bytes.count >= headerSize else { return nil }
        var reader = RemoteXPCReader(bytes)
        let end = bytes.endIndex
        guard try reader.read(UInt32.self, upTo: end) == wrapperMagic else {
            throw RemoteXPCWireError.malformed("wrapper magic")
        }
        let flags = try reader.read(UInt32.self, upTo: end)
        let bodySize = try reader.read(UInt64.self, upTo: end)
        guard bodySize <= maximumBodySize else { throw RemoteXPCWireError.messageTooLarge }
        let bytesConsumed = headerSize + Int(bodySize)
        guard bytes.count >= bytesConsumed else { return nil }
        let messageID = try reader.read(UInt64.self, upTo: end)
        let payloadEnd = bytes.startIndex + bytesConsumed
        let body: RemoteXPCValue?
        if bodySize == 0 {
            body = nil
        } else {
            guard try reader.read(UInt32.self, upTo: payloadEnd) == payloadMagic,
                  try reader.read(UInt32.self, upTo: payloadEnd) == payloadVersion else {
                throw RemoteXPCWireError.malformed("payload header")
            }
            body = try reader.readObject(upTo: payloadEnd, depth: 0)
            guard reader.position == payloadEnd else {
                throw RemoteXPCWireError.malformed("payload length")
            }
        }
        return (Self(flags: flags, messageID: messageID, body: body), bytesConsumed)
    }
}

private enum RemoteXPCObjectType: UInt32 {
    case null = 0x1000
    case bool = 0x2000
    case int64 = 0x3000
    case uint64 = 0x4000
    case double = 0x5000
    case date = 0x7000
    case data = 0x8000
    case string = 0x9000
    case uuid = 0xA000
    case array = 0xE000
    case dictionary = 0xF000

    static let maximumDepth = 64
}

private func paddingForFourByteAlignment(_ count: Int) -> Int {
    (4 - count % 4) % 4
}

private struct RemoteXPCWriter {
    private(set) var bytes = Data()

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func replace<T: FixedWidthInteger>(at index: Int, with value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            bytes.replaceSubrange(index..<(index + $0.count), with: $0)
        }
    }

    private mutating func appendLength(_ length: Int) throws {
        guard let field = UInt32(exactly: length) else { throw RemoteXPCWireError.messageTooLarge }
        append(field)
    }

    private mutating func appendPadding(for count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: paddingForFourByteAlignment(count)))
    }

    private mutating func appendCString(_ value: String) throws {
        guard !value.utf8.contains(0) else { throw RemoteXPCWireError.malformed("string") }
        bytes.append(contentsOf: value.utf8)
        bytes.append(0)
        appendPadding(for: value.utf8.count + 1)
    }

    private mutating func beginCollection(count: Int) throws -> Int {
        let lengthIndex = bytes.count
        append(UInt32(0))
        try appendLength(count)
        return lengthIndex
    }

    private mutating func endCollection(at index: Int) throws {
        let length = bytes.count - index - MemoryLayout<UInt32>.size
        guard let field = UInt32(exactly: length) else { throw RemoteXPCWireError.messageTooLarge }
        replace(at: index, with: field)
    }

    mutating func appendObject(_ value: RemoteXPCValue, depth: Int) throws {
        guard depth <= RemoteXPCObjectType.maximumDepth else { throw RemoteXPCWireError.nestingTooDeep }

        switch value {
        case .null:
            append(RemoteXPCObjectType.null.rawValue)
        case .bool(let value):
            append(RemoteXPCObjectType.bool.rawValue)
            append(UInt32(value ? 1 : 0))
        case .int64(let value):
            append(RemoteXPCObjectType.int64.rawValue)
            append(value)
        case .uint64(let value):
            append(RemoteXPCObjectType.uint64.rawValue)
            append(value)
        case .double(let value):
            append(RemoteXPCObjectType.double.rawValue)
            append(value.bitPattern)
        case .date(let value):
            append(RemoteXPCObjectType.date.rawValue)
            append(value)
        case .data(let value):
            append(RemoteXPCObjectType.data.rawValue)
            try appendLength(value.count)
            bytes.append(value)
            appendPadding(for: value.count)
        case .string(let value):
            append(RemoteXPCObjectType.string.rawValue)
            try appendLength(value.utf8.count + 1)
            try appendCString(value)
        case .uuid(let value):
            append(RemoteXPCObjectType.uuid.rawValue)
            withUnsafeBytes(of: value.uuid) { bytes.append(contentsOf: $0) }
        case .array(let values):
            append(RemoteXPCObjectType.array.rawValue)
            let lengthIndex = try beginCollection(count: values.count)
            for child in values {
                try appendObject(child, depth: depth + 1)
            }
            try endCollection(at: lengthIndex)
        case .dictionary(let values):
            append(RemoteXPCObjectType.dictionary.rawValue)
            let lengthIndex = try beginCollection(count: values.count)
            for (key, child) in values.sorted(by: { $0.key < $1.key }) {
                try appendCString(key)
                try appendObject(child, depth: depth + 1)
            }
            try endCollection(at: lengthIndex)
        }
    }
}

private struct RemoteXPCReader {
    private let bytes: Data
    private(set) var position: Int

    init(_ bytes: Data) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    private mutating func consume(_ count: Int, upTo end: Int) throws -> Range<Int> {
        guard count <= end - position else { throw RemoteXPCWireError.malformed("object length") }
        let start = position
        position += count
        return start..<position
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type, upTo end: Int) throws -> T {
        let range = try consume(MemoryLayout<T>.size, upTo: end)
        return bytes.withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(fromByteOffset: range.lowerBound - bytes.startIndex, as: type))
        }
    }

    private mutating func readPaddedBytes(count: Int, upTo end: Int) throws -> Data {
        let range = try consume(count, upTo: end)
        _ = try consume(paddingForFourByteAlignment(count), upTo: end)
        return bytes[range]
    }

    private mutating func readString(count: Int, upTo end: Int) throws -> String {
        let raw = try readPaddedBytes(count: count, upTo: end)
        guard raw.last == 0, !raw.dropLast().contains(0),
              let value = String(bytes: raw.dropLast(), encoding: .utf8) else {
            throw RemoteXPCWireError.malformed("string")
        }
        return value
    }

    private mutating func readKey(upTo end: Int) throws -> String {
        guard let terminator = bytes[position..<end].firstIndex(of: 0) else {
            throw RemoteXPCWireError.malformed("dictionary key")
        }
        return try readString(count: terminator - position + 1, upTo: end)
    }

    private mutating func readCollection(upTo end: Int, minimumItemSize: Int) throws -> (end: Int, count: Int) {
        let length = Int(try read(UInt32.self, upTo: end))
        guard length <= end - position else { throw RemoteXPCWireError.malformed("collection length") }
        let collectionEnd = position + length
        let count = Int(try read(UInt32.self, upTo: collectionEnd))
        guard count <= (collectionEnd - position) / minimumItemSize else {
            throw RemoteXPCWireError.malformed("collection count")
        }
        return (collectionEnd, count)
    }

    mutating func readObject(upTo end: Int, depth: Int) throws -> RemoteXPCValue {
        guard depth <= RemoteXPCObjectType.maximumDepth else { throw RemoteXPCWireError.nestingTooDeep }
        let tag = try read(UInt32.self, upTo: end)
        guard let type = RemoteXPCObjectType(rawValue: tag) else { throw RemoteXPCWireError.unsupportedType(tag) }

        switch type {
        case .null:
            return .null
        case .bool:
            let value = try read(UInt32.self, upTo: end)
            guard value <= 1 else { throw RemoteXPCWireError.malformed("boolean") }
            return .bool(value == 1)
        case .int64:
            return .int64(try read(Int64.self, upTo: end))
        case .uint64:
            return .uint64(try read(UInt64.self, upTo: end))
        case .double:
            return .double(Double(bitPattern: try read(UInt64.self, upTo: end)))
        case .date:
            return .date(try read(Int64.self, upTo: end))
        case .data:
            let count = Int(try read(UInt32.self, upTo: end))
            return .data(try readPaddedBytes(count: count, upTo: end))
        case .string:
            let count = Int(try read(UInt32.self, upTo: end))
            return .string(try readString(count: count, upTo: end))
        case .uuid:
            let range = try consume(16, upTo: end)
            let raw = bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: range.lowerBound - bytes.startIndex, as: uuid_t.self)
            }
            return .uuid(UUID(uuid: raw))
        case .array:
            let collection = try readCollection(upTo: end, minimumItemSize: 4)
            var values: [RemoteXPCValue] = []
            for _ in 0..<collection.count {
                values.append(try readObject(upTo: collection.end, depth: depth + 1))
            }
            guard position == collection.end else { throw RemoteXPCWireError.malformed("array length") }
            return .array(values)
        case .dictionary:
            let collection = try readCollection(upTo: end, minimumItemSize: 8)
            var values: [String: RemoteXPCValue] = [:]
            for _ in 0..<collection.count {
                let key = try readKey(upTo: collection.end)
                guard values[key] == nil else { throw RemoteXPCWireError.malformed("duplicate dictionary key") }
                values[key] = try readObject(upTo: collection.end, depth: depth + 1)
            }
            guard position == collection.end else { throw RemoteXPCWireError.malformed("dictionary length") }
            return .dictionary(values)
        }
    }
}
