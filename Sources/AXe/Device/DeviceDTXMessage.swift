import Foundation

/// DTX control-channel framing used by remoteAXService.
struct DeviceDTXMessage {
    private static let magic: UInt32 = 0x1F3D5B79
    private static let headerSize = 32
    private static let payloadHeaderSize = 16
    private static let maxFragmentCount = 512
    private static let maxBodySize = PhysicalAXTreeArchive.maximumBytes + 64 * 1024

    let identifier: UInt32
    let conversation: UInt32
    let channel: Int32
    let expectsReply: Bool
    let payloadType: UInt32
    private let auxiliary: Data
    private let object: Data

    var isEmptyAcknowledgement: Bool { payloadType == 0 && auxiliary.isEmpty && object.isEmpty }

    static func read(from read: (Int) throws -> Data) throws -> Self {
        let first = try readHeader(from: read)
        guard first.fragmentIndex == 0 else { throw malformed("unexpected first fragment index") }

        var body = Data()
        if first.fragmentCount == 1 {
            body = try read(first.bodyLength)
        } else {
            // Fragment zero declares the combined size and carries no body.
            body.reserveCapacity(first.bodyLength)
            for index in 1..<first.fragmentCount {
                let fragment = try readHeader(from: read)
                guard fragment.fragmentIndex == index,
                      fragment.fragmentCount == first.fragmentCount,
                      fragment.identifier == first.identifier,
                      fragment.conversation == first.conversation,
                      fragment.channel == first.channel,
                      fragment.expectsReply == first.expectsReply,
                      fragment.bodyLength <= first.bodyLength - body.count else {
                    throw malformed("fragment does not match the message")
                }
                body.append(try read(fragment.bodyLength))
            }
        }
        guard body.count == first.bodyLength else { throw malformed("message size does not match the fragments") }

        let payloadType = body.littleEndian(UInt32.self, at: 0)
        let auxiliarySize = Int(body.littleEndian(UInt32.self, at: 4))
        let dataSize = body.littleEndian(UInt64.self, at: 8)
        guard dataSize == UInt64(body.count - payloadHeaderSize), auxiliarySize <= Int(dataSize),
              payloadType == 0 || payloadType == 2 else {
            throw malformed("invalid or compressed payload")
        }
        let split = payloadHeaderSize + auxiliarySize
        return Self(identifier: first.identifier, conversation: first.conversation, channel: first.channel,
            expectsReply: first.expectsReply, payloadType: payloadType,
            auxiliary: Data(body[payloadHeaderSize..<split]), object: Data(body[split...]))
    }

    func selector() throws -> String? {
        guard payloadType == 2, !object.isEmpty, object.count <= 4_096 else { return nil }
        guard let selector = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: object) else {
            throw Self.malformed("missing selector")
        }
        return selector as String
    }

    func archiveArgument(maximumBytes: Int) throws -> Data {
        let sectionSize = auxiliary.count - 16
        guard sectionSize >= 12,
              auxiliary.littleEndian(UInt64.self, at: 0) & 0xff == 0xf0,
              auxiliary.littleEndian(UInt64.self, at: 8) == UInt64(sectionSize),
              auxiliary.littleEndian(UInt32.self, at: 16) == 10,
              auxiliary.littleEndian(UInt32.self, at: 20) == 2 else {
            throw Self.malformed("invalid accessibility argument header")
        }
        let size = Int(auxiliary.littleEndian(UInt32.self, at: 24))
        guard size == auxiliary.count - 28, size <= maximumBytes + 4_096,
              let archive = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSData.self, from: Data(auxiliary[28...])
              ), archive.length > 0, archive.length <= maximumBytes else {
            throw Self.malformed("invalid accessibility archive argument")
        }
        return archive as Data
    }

    static func invocation(_ selector: String, argument: NSObject, identifier: UInt32, expectsReply: Bool = false) throws -> Data {
        let object = try NSKeyedArchiver.archivedData(withRootObject: selector as NSString, requiringSecureCoding: true)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: argument, requiringSecureCoding: true)
        var auxiliary = Data()
        auxiliary.appendLittleEndian(UInt64(0x1F0))
        auxiliary.appendLittleEndian(UInt64(12 + archive.count))
        auxiliary.appendLittleEndian(UInt32(10))
        auxiliary.appendLittleEndian(UInt32(2))
        auxiliary.appendLittleEndian(UInt32(archive.count))
        auxiliary.append(archive)
        return encode(identifier: identifier, conversation: 0, channel: 0, type: 2,
                      auxiliary: auxiliary, object: object, expectsReply: expectsReply)
    }

    static func capabilities(identifier: UInt32) throws -> Data {
        try invocation("_notifyOfPublishedCapabilities:", argument: [
            "com.apple.private.DTXBlockCompression": NSNumber(value: 0),
            "com.apple.private.DTXConnection": NSNumber(value: 1),
        ] as NSDictionary, identifier: identifier)
    }

    func acknowledgement() -> Data {
        Self.encode(identifier: identifier, conversation: 1, channel: channel, type: 0)
    }

    private static func encode(identifier: UInt32, conversation: UInt32, channel: Int32,
                               type: UInt32, auxiliary: Data = Data(), object: Data = Data(), expectsReply: Bool = false) -> Data {
        let size = auxiliary.count + object.count
        var bytes = Data()
        bytes.appendLittleEndian(magic)
        bytes.appendLittleEndian(UInt32(headerSize))
        bytes.appendLittleEndian(UInt16(0))
        bytes.appendLittleEndian(UInt16(1))
        bytes.appendLittleEndian(UInt32(payloadHeaderSize + size))
        bytes.appendLittleEndian(identifier)
        bytes.appendLittleEndian(conversation)
        bytes.appendLittleEndian(channel)
        bytes.appendLittleEndian(UInt32(expectsReply ? 1 : 0))
        bytes.appendLittleEndian(type)
        bytes.appendLittleEndian(UInt32(auxiliary.count))
        bytes.appendLittleEndian(UInt64(size))
        bytes.append(auxiliary)
        bytes.append(object)
        return bytes
    }

    private struct Header {
        let fragmentIndex: Int
        let fragmentCount: Int
        let bodyLength: Int
        let identifier: UInt32
        let conversation: UInt32
        let channel: Int32
        let expectsReply: Bool
    }

    private static func readHeader(from read: (Int) throws -> Data) throws -> Header {
        let bytes = try read(headerSize)
        guard bytes.count == headerSize,
              bytes.littleEndian(UInt32.self, at: 0) == magic,
              bytes.littleEndian(UInt32.self, at: 4) == headerSize else {
            throw malformed("invalid header")
        }
        let index = Int(bytes.littleEndian(UInt16.self, at: 8))
        let count = Int(bytes.littleEndian(UInt16.self, at: 10))
        let size = Int(bytes.littleEndian(UInt32.self, at: 12))
        let expectsReply = bytes.littleEndian(UInt32.self, at: 28)
        guard (1...maxFragmentCount).contains(count), index < count,
              size >= (index == 0 ? payloadHeaderSize : 1), size <= maxBodySize, expectsReply <= 1 else {
            throw malformed("invalid fragment fields")
        }
        return Header(fragmentIndex: index, fragmentCount: count, bodyLength: size,
            identifier: bytes.littleEndian(UInt32.self, at: 16),
            conversation: bytes.littleEndian(UInt32.self, at: 20),
            channel: bytes.littleEndian(Int32.self, at: 24), expectsReply: expectsReply == 1)
    }

    private static func malformed(_ details: String) -> DeviceServiceError {
        .invalidProtocol("DTX: \(details)")
    }
}

private extension Data {
    func littleEndian<Integer: FixedWidthInteger>(_ type: Integer.Type, at offset: Int) -> Integer {
        withUnsafeBytes { Integer(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: type)) }
    }

    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ number: Integer) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
