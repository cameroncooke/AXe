import Foundation

/// Values live only inside one owned native Button-chain admission. Opaque IDs
/// are not persistent selectors, aliases, or proof of display ownership.
struct FBAXButtonChainPointSelection {
  struct Identity: Equatable, Sendable {
    let pid: Int32
    let objectID: UInt64
    let rawData: Data?
  }

  private struct Key: Hashable {
    let pid: Int32
    let objectID: UInt64
    init(_ identity: Identity) { pid = identity.pid; objectID = identity.objectID }
  }

  private let members: [Identity]
  private let occurrences: [Key: Int]
  private let allTraversalIdentitiesAvailable: Bool
  private var pinned: Identity?

  init(members: [Identity], traversal: [Identity?]) throws {
    guard members.count > 1, members.count <= 512, traversal.count <= 512,
          members.count <= traversal.count, let leaf = members.last, leaf.pid > 0,
          members.allSatisfy({ $0.pid == leaf.pid && $0.objectID > 0 }) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    let available = traversal.compactMap { $0 }
    let counts = Dictionary(available.map { (Key($0), 1) }, uniquingKeysWith: +)
    guard members.allSatisfy({ counts[Key($0)] != nil }) else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    self.members = members
    occurrences = counts
    allTraversalIdentitiesAvailable = available.count == traversal.count
  }

  /// Preserve the exact leaf case. Only the new non-leaf case needs a unique
  /// identity occurrence in both the chain and complete current native traversal.
  func memberIndex(for point: Identity) throws -> Int {
    guard let leaf = members.last, point.pid == leaf.pid, point.objectID > 0 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    if point == leaf { return members.count - 1 }
    let matches = members.indices.filter { members[$0] == point }
    guard allTraversalIdentitiesAvailable, matches.count == 1, let index = matches.first,
          occurrences[Key(point)] == 1 else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
    return index
  }

  func requireCurrent(_ identity: Identity, at index: Int) throws {
    guard members.indices.contains(index), members[index] == identity else {
      throw FBSimulatorAXTargetError.targetMismatch
    }
  }

  /// Call only after the native member's full signature and live state pass.
  mutating func pinMember(at index: Int) throws {
    guard members.indices.contains(index) else { throw FBSimulatorAXTargetError.targetMismatch }
    let identity = members[index]
    guard pinned == nil || pinned == identity else { throw FBSimulatorAXTargetError.targetMismatch }
    pinned = identity
  }
}
