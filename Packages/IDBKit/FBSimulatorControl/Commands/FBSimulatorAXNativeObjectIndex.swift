import Foundation
import CryptoKit

/// Evidence from one complete, bounded acquisition. It grants no input authority.
/// Raw nodes and every occurrence path remain available; aliases are not deduplicated.
public struct FBSimulatorAXNativeObjectIndex: Sendable {
  public enum Failure: String, Error, Equatable, Sendable {
    case incompleteTree, invalidIdentity, hierarchyBound, missingObject
    case conflictingAliases, unavailableOccurrence, wrongOwnerOrType, unprovableValue
  }

  public struct Occurrence: Codable, Sendable {
    public let index: Int
    public let path: [Int]
    public let ancestorIndices: [Int]
    public let unavailable: Bool
  }

  public struct Resolution: Sendable {
    public let node: FBSimulatorAXNode
    public let occurrences: [Occurrence]
    public var isAlias: Bool { occurrences.count > 1 }
    public var canonicalIndex: Int { occurrences[0].index }
  }

  public let nodes: [FBSimulatorAXNode]
  private let occurrencesByKey: [FBSimulatorAXNativeIdentity: [Occurrence]]
  private let shapeIDs: [Int]
  private let subtreeDigests: [String]

  public init(roots: [FBSimulatorAXNode], metadata: FBSimulatorAXNativeIdentityMetadata?) throws {
    guard metadata?.complete == true, !roots.isEmpty else { throw Failure.incompleteTree }
    var nodes: [FBSimulatorAXNode] = []
    var occurrences: [FBSimulatorAXNativeIdentity: [Occurrence]] = [:]
    var shapes: [Int] = []
    var digests: [String] = []
    var interned: [Data: Int] = [:]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    func collect(_ node: FBSimulatorAXNode, path: [Int], ancestors: [Int], unavailable: Bool) throws -> Int {
      guard path.count <= 65, nodes.count < 4096 else { throw Failure.hierarchyBound }
      guard let key = node.nativeIdentity, key.pid > 0, key.objectID > 0, node.pid == key.pid else {
        throw Failure.invalidIdentity
      }
      let index = nodes.count
      let blocked = unavailable || node.hidden == true || node.enabled == false
      nodes.append(node)
      shapes.append(0)
      digests.append("")
      occurrences[key, default: []].append(.init(index: index, path: path,
        ancestorIndices: ancestors, unavailable: blocked))
      var childDigests: [String] = []
      let children = try node.children.enumerated().map { child in
        let childIndex = nodes.count
        let shape = try collect(child.element, path: path + [child.offset], ancestors: ancestors + [index], unavailable: blocked)
        childDigests.append(digests[childIndex])
        return shape
      }
      let own = try encoder.encode(Shape(node, key: key, children: []))
      let proof = try encoder.encode(StructuralProof(own: own, children: childDigests))
      digests[index] = SHA256.hash(data: proof).map { String(format: "%02x", $0) }.joined()
      // Exact interned values avoid hash collisions and repeated full-subtree encoding.
      let encoded = try encoder.encode(Shape(node, key: key, children: children))
      let shape: Int
      if let existing = interned[encoded] { shape = existing }
      else { shape = interned.count; interned[encoded] = shape }
      shapes[index] = shape
      return shape
    }
    for (index, root) in roots.enumerated() {
      _ = try collect(root, path: [index], ancestors: [], unavailable: false)
    }
    self.nodes = nodes
    occurrencesByKey = occurrences
    shapeIDs = shapes
    subtreeDigests = digests
  }

  public func occurrences(for identity: FBSimulatorAXNativeIdentity) -> [Occurrence] {
    occurrencesByKey[identity] ?? []
  }

  /// Only a qualified nonnumeric object class supplies a read-to-read certificate.
  /// This is not an input token or a lossless numeric value representation.
  public func subtreeDigest(for identity: FBSimulatorAXNativeIdentity) -> String? {
    guard let first = occurrencesByKey[identity]?.first, let type = nodes[first.index].type,
          (try? resolve(identity: identity, elementType: type, expectedPID: identity.pid)) != nil else { return nil }
    return subtreeDigests[first.index]
  }

  private struct StructuralProof: Encodable {
    let own: Data
    let children: [String]
  }

  /// One object may have equal serialized appearances on different paths.
  /// Equality includes exact typed fields, raw sizes and the ordered child-key subtrees.
  public func resolve(identity: FBSimulatorAXNativeIdentity, elementType: String,
    expectedPID: Int32) throws -> Resolution {
    guard expectedPID > 0, identity.pid == expectedPID, identity.objectID > 0,
          !elementType.isEmpty, elementType.utf8.count <= 256,
          elementType == elementType.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw Failure.wrongOwnerOrType
    }
    guard let matches = occurrencesByKey[identity], let first = matches.first else { throw Failure.missingObject }
    guard matches.allSatisfy({ shapeIDs[$0.index] == shapeIDs[first.index] }) else {
      throw Failure.conflictingAliases
    }
    guard matches.allSatisfy({ !$0.unavailable }) else { throw Failure.unavailableOccurrence }
    guard matches.allSatisfy({ occurrence in
      occurrence.ancestorIndices.allSatisfy { nodes[$0].pid == expectedPID }
    }) else { throw Failure.wrongOwnerOrType }
    let node = nodes[first.index]
    // A descendant key cannot conceal a conflicting appearance elsewhere in the complete tree.
    var pending = [node]
    var checked: Set<FBSimulatorAXNativeIdentity> = []
    while let current = pending.popLast() {
      guard let key = current.nativeIdentity else { throw Failure.invalidIdentity }
      if checked.insert(key).inserted {
        guard let copies = occurrencesByKey[key], let representative = copies.first,
              copies.allSatisfy({ shapeIDs[$0.index] == shapeIDs[representative.index] }) else {
          throw Failure.conflictingAliases
        }
        if !Self.hasExactTypedValueProof(current.value) { throw Failure.unprovableValue }
      }
      pending += current.children
    }
    guard node.pid == expectedPID, node.type == elementType, node.nativeIdentity == identity else {
      throw Failure.wrongOwnerOrType
    }
    return Resolution(node: node, occurrences: matches)
  }

  // Typed AX numbers use Double and can lose source decimal distinctions at any
  // magnitude. Numeric values cannot supply this proof. Native object IDs stay strings.
  private static func hasExactTypedValueProof(_ value: FBSimulatorAXValue?) -> Bool {
    guard let value else { return true }
    switch value {
    case .number: return false
    case .array(let values): return values.allSatisfy { hasExactTypedValueProof($0) }
    case .object(let values): return values.values.allSatisfy { hasExactTypedValueProof($0) }
    case .null, .boolean, .string: return true
    }
  }

  private struct RawFrame: Encodable {
    let x: Double, y: Double, width: Double, height: Double
    init(_ value: CGRect) {
      x = value.origin.x; y = value.origin.y
      width = value.size.width; height = value.size.height
    }
  }

  private struct Shape: Encodable {
    let key: FBSimulatorAXNativeIdentity
    let type: String?, role: String?, subrole: String?, roleDescription: String?
    let identifier: String?, label: String?, discoveryMethod: String?
    let value: FBSimulatorAXValue?
    let customActionNames: [String]
    let frame: RawFrame?
    let pid: Int32?
    let focused: Bool?, enabled: Bool?, hidden: Bool?
    let children: [Int]

    init(_ node: FBSimulatorAXNode, key: FBSimulatorAXNativeIdentity, children: [Int]) {
      self.key = key
      type = node.type; role = node.role; subrole = node.subrole; roleDescription = node.roleDescription
      identifier = node.identifier; label = node.label; discoveryMethod = node.discoveryMethod
      value = node.value; customActionNames = node.customActionNames; frame = node.frame.map(RawFrame.init)
      pid = node.pid; focused = node.focused; enabled = node.enabled; hidden = node.hidden
      self.children = children
    }
  }
}
