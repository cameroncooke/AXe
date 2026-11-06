import Foundation

/// Candidate key inside one measured acquisition, never a persistent handle.
public struct FBSimulatorAXNativeIdentity: Codable, Hashable, Sendable {
  public let pid: Int32
  public let objectID: UInt64

  public init(pid: Int32, objectID: UInt64) { self.pid = pid; self.objectID = objectID }

  public func validate() throws {
    guard pid > 0, objectID > 0 else { throw FBSimulatorAXSnapshotError.invalidSelection }
  }

  private enum CodingKeys: String, CodingKey { case pid, objectID }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    pid = try values.decode(Int32.self, forKey: .pid)
    let text = try values.decode(String.self, forKey: .objectID)
    let bytes = Array(text.utf8)
    guard (1...20).contains(bytes.count), let first = bytes.first, (49...57).contains(first),
          bytes.dropFirst().allSatisfy({ (48...57).contains($0) }),
          let number = UInt64(text), number > 0, pid > 0 else {
      throw DecodingError.dataCorruptedError(forKey: .objectID, in: values,
        debugDescription: "Native identity requires a positive PID and canonical decimal UInt64 string.")
    }
    objectID = number
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(pid, forKey: .pid)
    try values.encode(String(objectID), forKey: .objectID)
  }
}

public struct FBSimulatorAXNativeIdentityMetadata: Codable, Equatable, Sendable {
  public let complete: Bool
  public let reason: String?
  public init(complete: Bool, reason: String? = nil) {
    self.complete = complete; self.reason = reason
  }
}

/// The legacy child collection is preserved, with an explicit optional-identity
/// completeness result. Unsupported wrappers do not remove semantic controls.
struct FBAXNativeIdentityChildren {
  let elements: [FBAXPlatformElement]
  let reason: String?
}

/// Owned by the current serial AX traversal. No native handles or mutable state
/// escape the read. An incomplete optional traversal cannot authorize a key.
final class FBAXNativeIdentityCollector {
  private var reason: String?
  private var count = 0

  func invalidate(_ reason: String) { if self.reason == nil { self.reason = reason } }

  func identity(of element: FBAXPlatformElement, depth: Int) -> FBSimulatorAXNativeIdentity? {
    count += 1
    guard count <= 4096 else { invalidate("nodeLimit"); return nil }
    guard depth <= 64 else { invalidate("depthLimit"); return nil }
    guard let identity = element.axNativeIdentity(), (try? identity.validate()) != nil else {
      invalidate("missingIdentity"); return nil
    }
    return identity
  }

  func children(of element: FBAXPlatformElement) -> [FBAXPlatformElement] {
    children(from: element.axNativeIdentityChildren())
  }

  /// The same completeness rule for children already read with the element's attributes.
  func children(from result: FBAXNativeIdentityChildren) -> [FBAXPlatformElement] {
    if let reason = result.reason { invalidate(reason) }
    return result.elements
  }

  var metadata: FBSimulatorAXNativeIdentityMetadata {
    .init(complete: reason == nil, reason: reason)
  }
}

/// Completeness is required from the producer before calling this value lookup.
/// Count every occurrence before type/state/focus can hide a duplicate key.
enum FBAXNativeObjectSelection {
  static func uniqueNode(in roots: [FBSimulatorAXNode], identity: FBSimulatorAXNativeIdentity,
    elementType: String) throws -> FBSimulatorAXNode {
    try identity.validate()
    var found: FBSimulatorAXNode?
    var unavailable = false
    var count = 0
    var visited = 0
    var pending = roots.map { (node: $0, depth: 0, unavailable: false) }
    while let item = pending.popLast() {
      guard item.depth <= 64, visited < 4096,
            let key = item.node.nativeIdentity else { throw FBSimulatorAXSnapshotError.invalidSelection }
      try key.validate()
      visited += 1
      let currentUnavailable = item.unavailable || item.node.hidden == true || item.node.enabled == false
      if key == identity { count += 1; found = item.node; unavailable = currentUnavailable }
      pending += item.node.children.map { (node: $0, depth: item.depth + 1, unavailable: currentUnavailable) }
    }
    guard count > 0, let found else { throw FBSimulatorAXSnapshotError.notFound }
    guard count == 1 else { throw FBSimulatorAXSnapshotError.ambiguous(count: count) }
    guard !unavailable, found.pid == identity.pid, found.type == elementType else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    return found
  }
}
