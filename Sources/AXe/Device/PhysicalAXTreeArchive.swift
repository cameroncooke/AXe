import Foundation

enum PhysicalAXTreeArchiveError: LocalizedError {
    case invalidArchive
    case exceedsLimit

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "The device returned an invalid accessibility tree archive."
        case .exceedsLimit: "The device accessibility tree exceeded the read limits."
        }
    }
}

struct PhysicalAXTreeArchive: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    private static let maximumNodes = 4_096
    private static let maximumRecords = 32_768
    private static let maximumDepth = 64

    enum Kind: String, Sendable {
        case initial = "AXPTreeDumpTypeInitialDump"
        case additional = "AXPTreeDumpTypeAdditionalData"
        case empty
    }

    struct ObjectIdentity: Equatable, Hashable, Sendable {
        let pid: Int32
        let objectID: UInt64
    }

    struct Entry: Sendable {
        let requestType: UInt64
        let objectID: UInt64?
        let pid: Int32?
        let attribute: UInt64
    }

    let data: Data
    let kind: Kind
    let entries: [Entry]
    let rootIdentity: ObjectIdentity?
    fileprivate let pairIdentity: PairIdentity?

    fileprivate struct PairIdentity: Equatable, Sendable {
        let root: ObjectIdentity
        let children: [ShapeNode]
        let unignoredChildren: [ShapeNode]
    }

    fileprivate struct ShapeNode: Equatable, Sendable {
        let pid: Int32
        let childCount: Int
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PhysicalAXTreeArchiveError.exceedsLimit }
        guard data.starts(with: "bplist00".utf8) else { throw PhysicalAXTreeArchiveError.invalidArchive }

        let decoder: NSKeyedUnarchiver
        do {
            decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            throw PhysicalAXTreeArchiveError.invalidArchive
        }
        decoder.requiresSecureCoding = true
        decoder.decodingFailurePolicy = .setErrorAndReturn
        // Decode the captured wire records without loading the device's Objective-C classes.
        decoder.setClass(PhysicalAXWireResponse.self, forClassName: "AXPTranslatorResponse")
        decoder.setClass(PhysicalAXWireObject.self, forClassName: "AXPTranslationObject")
        let envelope = decoder.decodeObject(of: PhysicalAXWireResponse.self, forKey: NSKeyedArchiveRootObjectKey)
        decoder.finishDecoding()
        guard decoder.error == nil, let envelope, envelope.requestType == 11, envelope.errorCode == 0,
              let fields = envelope.result as? [String: NSObject],
              let records = fields["treeDump"] as? [PhysicalAXWireResponse] else {
            throw PhysicalAXTreeArchiveError.invalidArchive
        }
        guard records.count <= maximumRecords else { throw PhysicalAXTreeArchiveError.exceedsLimit }

        let kind: Kind
        if let value = fields["treeDumpType"] as? String,
           let decoded = Kind(rawValue: value), decoded != .empty {
            kind = decoded
        } else if fields["treeDumpType"] == nil, records.isEmpty {
            kind = .empty
        } else {
            throw PhysicalAXTreeArchiveError.invalidArchive
        }

        let entries = records.map { record in
            let object = record.requestType == 4 ? record.result as? PhysicalAXWireObject : record.associatedObject
            return Entry(requestType: record.requestType, objectID: object?.identity.objectID,
                         pid: object?.identity.pid, attribute: record.attribute)
        }
        let roots = records.filter { $0.requestType == 4 }
        let rootIdentity: ObjectIdentity?
        if roots.count == 1, let root = roots.first, root.errorCode == 0,
           let object = root.result as? PhysicalAXWireObject, object.isApplication {
            rootIdentity = object.identity
        } else {
            rootIdentity = nil
        }
        let pairIdentity = try rootIdentity.flatMap { try shape(of: records, root: $0) }
        return Self(data: data, kind: kind, entries: entries, rootIdentity: rootIdentity, pairIdentity: pairIdentity)
    }

    private struct Children {
        let all: [ObjectIdentity]
        let unignored: [ObjectIdentity]
    }

    private static func shape(of records: [PhysicalAXWireResponse], root: ObjectIdentity) throws -> PairIdentity? {
        var childrenByObject: [ObjectIdentity: Children] = [:]
        var referenceCount = 0
        for record in records where record.requestType == 5 {
            guard record.errorCode == 0, let identity = record.associatedObject?.identity,
                  childrenByObject[identity] == nil,
                  let attributes = record.result as? [NSNumber: NSObject],
                  let children = attributes[8] as? [PhysicalAXWireObject],
                  let unignored = attributes[9] as? [PhysicalAXWireObject] else { return nil }
            referenceCount += children.count + unignored.count
            guard childrenByObject.count < maximumNodes, referenceCount <= 2 * maximumNodes else {
                throw PhysicalAXTreeArchiveError.exceedsLimit
            }
            childrenByObject[identity] = Children(all: children.map(\.identity), unignored: unignored.map(\.identity))
        }

        // The two pushes use independent object IDs for descendants. Compare their shapes
        // without IDs, and take all content from the self-contained AdditionalData push.
        func traverse(_ childList: KeyPath<Children, [ObjectIdentity]>) throws -> [ShapeNode]? {
            var seen: Set<ObjectIdentity> = []
            var result: [ShapeNode] = []
            var stack: [(identity: ObjectIdentity, depth: Int)] = [(root, 0)]
            while let next = stack.popLast() {
                guard next.depth <= maximumDepth else { throw PhysicalAXTreeArchiveError.exceedsLimit }
                guard seen.insert(next.identity).inserted, let child = childrenByObject[next.identity] else { return nil }
                let children = child[keyPath: childList]
                result.append(ShapeNode(pid: next.identity.pid, childCount: children.count))
                stack.append(contentsOf: children.reversed().map { ($0, next.depth + 1) })
            }
            return result
        }

        guard let children = try traverse(\.all), let unignored = try traverse(\.unignored) else { return nil }
        return PairIdentity(root: root, children: children, unignoredChildren: unignored)
    }
}

struct PhysicalAXTreeAdmission {
    private var initial: PhysicalAXTreeArchive.PairIdentity?

    mutating func receive(_ data: Data) throws -> PhysicalAXTreeArchive? {
        let archive = try PhysicalAXTreeArchive.decode(data)
        switch archive.kind {
        case .initial:
            initial = archive.pairIdentity
            return nil
        case .empty:
            initial = nil
            return nil
        case .additional:
            defer { initial = nil }
            guard let initial, archive.pairIdentity == initial else { return nil }
            return archive
        }
    }

    mutating func reset() {
        initial = nil
    }
}

@objc(AXePhysicalAXWireObject)
private final class PhysicalAXWireObject: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let identity: PhysicalAXTreeArchive.ObjectIdentity
    let isApplication: Bool

    init?(coder: NSCoder) {
        let pid = coder.decodeInt32(forKey: "pid")
        guard pid > 0, let number = coder.decodeObject(of: NSNumber.self, forKey: "objectID"),
              let objectID = UInt64(number.stringValue) else { return nil }
        identity = .init(pid: pid, objectID: objectID)
        isApplication = coder.decodeBool(forKey: "isApplicationElement")
    }

    func encode(with coder: NSCoder) {}
}

@objc(AXePhysicalAXWireResponse)
private final class PhysicalAXWireResponse: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let requestType: UInt64
    let attribute: UInt64
    let errorCode: UInt64
    let associatedObject: PhysicalAXWireObject?
    let result: NSObject?

    init?(coder: NSCoder) {
        requestType = UInt64(bitPattern: coder.decodeInt64(forKey: "associatedRequestType"))
        attribute = UInt64(bitPattern: coder.decodeInt64(forKey: "attribute"))
        errorCode = UInt64(bitPattern: coder.decodeInt64(forKey: "error"))
        associatedObject = coder.decodeObject(of: PhysicalAXWireObject.self, forKey: "associatedTranslationObject")
        switch requestType {
        case 4:
            result = coder.decodeObject(of: PhysicalAXWireObject.self, forKey: "resultData")
        case 5, 11:
            result = coder.decodeObject(of: [
                NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSValue.self,
                NSUUID.self, NSData.self, NSAttributedString.self,
                PhysicalAXWireResponse.self, PhysicalAXWireObject.self,
            ], forKey: "resultData") as? NSObject
        default:
            result = nil
        }
    }

    func encode(with coder: NSCoder) {}
}
