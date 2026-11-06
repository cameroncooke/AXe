import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Current native Button-chain point identity")
struct FBSimulatorAXButtonChainPointTests {
  private typealias Selection = FBAXButtonChainPointSelection
  private typealias Identity = Selection.Identity
  // Exact distinct native IDs from the zero-input permission probe. Neither is
  // a public AXUniqueId; their values exceed Double's exact integer range.
  private let outer = Identity(pid: 7988, objectID: 8_990_092_049_072_299_155, rawData: nil)
  private let leaf = Identity(pid: 7988, objectID: 15_021_802_770_159_162_533, rawData: nil)

  @Test func recordedDistinctOuterHitCanConfirmTheSameOwnedMember() throws {
    var selection = try Selection(members: [outer, leaf], traversal: [outer, leaf])
    let initial = try selection.memberIndex(for: outer)
    #expect(initial == 0)
    try selection.pinMember(at: initial)
    let confirmed = try selection.memberIndex(for: outer)
    try selection.pinMember(at: confirmed)
    #expect(confirmed == initial)
    try selection.requireCurrent(outer, at: 0)
    try selection.requireCurrent(leaf, at: 1)
  }

  @Test func exactLeafSuccessRetainsTheOriginalIdentityCase() throws {
    var selection = try Selection(members: [outer, leaf], traversal: [outer, leaf, leaf])
    let index = try selection.memberIndex(for: leaf)
    #expect(index == 1)
    try selection.pinMember(at: index)
    try selection.pinMember(at: index)
  }

  @Test func repeatedNativeLeafIdentityDoesNotInventANewAliasRule() throws {
    // Existing exact-leaf admission already compares this identity. Only the
    // new non-leaf route requires a distinct uniquely occurring member.
    let selection = try Selection(members: [leaf, leaf], traversal: [leaf, leaf])
    #expect(try selection.memberIndex(for: leaf) == 1)
  }

  @Test func sameLookingNodeOutsideTheChainCannotAuthorizeAPoint() throws {
    let other = Identity(pid: outer.pid, objectID: outer.objectID + 1, rawData: nil)
    let selection = try Selection(members: [outer, leaf], traversal: [outer, leaf, other])
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.memberIndex(for: other) }
  }

  @Test func duplicatedOuterIdentityAnywhereInTheNativeTreeRefuses() throws {
    let selection = try Selection(members: [outer, leaf], traversal: [outer, leaf, outer])
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.memberIndex(for: outer) }
    // An opaque-key collision is still ambiguous when raw data differs.
    let collision = Identity(pid: outer.pid, objectID: outer.objectID, rawData: Data([7]))
    let collisionSelection = try Selection(members: [outer, leaf], traversal: [outer, leaf, collision])
    #expect(throws: FBSimulatorAXTargetError.self) { try collisionSelection.memberIndex(for: outer) }
  }

  @Test func anUnknownTraversalIdentityCannotAuthorizeTheNewOuterRoute() throws {
    let selection = try Selection(members: [outer, leaf], traversal: [outer, leaf, nil])
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.memberIndex(for: outer) }
    #expect(try selection.memberIndex(for: leaf) == 1)
    #expect(throws: FBSimulatorAXTargetError.self) {
      try Selection(members: [outer, leaf], traversal: [leaf, nil])
    }
  }

  @Test func duplicateNonLeafMembersRefuse() throws {
    let selection = try Selection(members: [outer, outer, leaf], traversal: [outer, outer, leaf])
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.memberIndex(for: outer) }
  }

  @Test func changedOwnerMissingIdentityOrChangedRawDataRefuse() throws {
    let selection = try Selection(members: [outer, leaf], traversal: [outer, leaf])
    let invalid = [Identity(pid: 0, objectID: outer.objectID, rawData: nil),
      Identity(pid: outer.pid + 1, objectID: outer.objectID, rawData: nil),
      Identity(pid: outer.pid, objectID: 0, rawData: nil),
      Identity(pid: outer.pid, objectID: outer.objectID, rawData: Data([1]))]
    for point in invalid {
      #expect(throws: FBSimulatorAXTargetError.self) { try selection.memberIndex(for: point) }
    }
  }

  @Test func confirmationCannotMoveBetweenOuterAndLeafInEitherDirection() throws {
    for indices in [[0, 1], [1, 0]] {
      var selection = try Selection(members: [outer, leaf], traversal: [outer, leaf])
      try selection.pinMember(at: indices[0])
      #expect(throws: FBSimulatorAXTargetError.self) { try selection.pinMember(at: indices[1]) }
    }
  }

  @Test func changingAnyRetainedMemberIdentityRefuses() throws {
    let selection = try Selection(members: [outer, leaf], traversal: [outer, leaf])
    for (index, member) in [outer, leaf].enumerated() {
      for changed in [Identity(pid: member.pid + 1, objectID: member.objectID, rawData: member.rawData),
        Identity(pid: member.pid, objectID: member.objectID + 1, rawData: member.rawData),
        Identity(pid: member.pid, objectID: member.objectID, rawData: Data([1]))] {
        #expect(throws: FBSimulatorAXTargetError.self) { try selection.requireCurrent(changed, at: index) }
      }
    }
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.requireCurrent(outer, at: -1) }
  }

  @Test func exactUInt64IdentityDoesNotMergeNearbyLargeValues() throws {
    let a = Identity(pid: 17, objectID: UInt64.max - 1, rawData: nil)
    let b = Identity(pid: 17, objectID: UInt64.max, rawData: nil)
    let selection = try Selection(members: [a, b], traversal: [a, b])
    #expect(try selection.memberIndex(for: a) == 0)
    #expect(try selection.memberIndex(for: b) == 1)
  }

  @Test func malformedChainAndInvalidMemberIndexRefuse() throws {
    for members in [[], [leaf], [Identity(pid: 0, objectID: 1, rawData: nil), leaf],
                    [Identity(pid: leaf.pid, objectID: 0, rawData: nil), leaf]] {
      #expect(throws: FBSimulatorAXTargetError.self) { try Selection(members: members, traversal: members.map(Optional.some)) }
    }
    var selection = try Selection(members: [outer, leaf], traversal: [outer, leaf])
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.pinMember(at: 2) }
    #expect(throws: FBSimulatorAXTargetError.self) { try selection.pinMember(at: -1) }
  }

  @Test func strictNativeSemanticChainStillQualifiesOnlyOneLeaf() throws {
    let roots = try decode([Fixture(children: [Fixture()])])
    let selection = try #require(FBSimulatorAXButtonLeafSelection.resolve(in: roots, selector: selector))
    #expect(selection.matchingIndices.count == 2)
    #expect(selection.node.children.isEmpty)
  }

  @Test(arguments: ["sibling-copy", "extra-child", "different-id", "different-label", "different-value",
    "different-type", "different-role", "different-subrole", "different-frame", "foreign-pid", "hidden", "disabled", "nonleaf-end"])
  func unsafeSemanticRelationshipsStayRefused(variant: String) throws {
    var leaf = Fixture()
    var parent = Fixture()
    var roots: [Fixture] = []
    switch variant {
    case "different-id": leaf.id = "other.action"
    case "different-label": leaf.label = "Different action"
    case "different-value": leaf.value = "Changed"
    case "different-type": leaf.type = "Group"
    case "different-role": leaf.role = "AXGroup"
    case "different-subrole": leaf.subrole = "AXDifferentButton"
    case "different-frame": leaf.frame.x += 1
    case "foreign-pid": leaf.pid += 1
    case "hidden": leaf.hidden = true
    case "disabled": leaf.enabled = false
    case "nonleaf-end": leaf.children = [Fixture(type: "Group", role: "AXGroup", id: nil, label: nil)]
    default: break
    }
    parent.children = [leaf]
    if variant == "extra-child" { parent.children.append(Fixture(type: "Group", role: "AXGroup", id: nil, label: nil)) }
    roots = [parent]
    if variant == "sibling-copy" { roots.append(Fixture()) }
    let native = try decode(roots)
    #expect(FBSimulatorAXButtonLeafSelection.resolve(in: native, selector: selector) == nil)
  }

  private var selector: FBSimulatorAXSelector { .identifierWithType("test.action", elementType: "Button") }

  private func decode(_ nodes: [Fixture]) throws -> [FBSimulatorAXNode] {
    try JSONDecoder().decode([FBSimulatorAXNode].self, from: JSONEncoder().encode(nodes))
  }

  private struct Fixture: Encodable {
    struct Frame: Encodable {
      var x = 57.0
      var y = 548.6666666666667
      var width = 140.0
      var height = 48.0
    }
    var type = "Button"
    var role: String? = "AXButton"
    var subrole: String? = nil
    var id: String? = "test.action"
    var label: String? = "Perform action"
    var value: String? = nil
    var frame = Frame()
    var pid: Int32 = 17
    var enabled = true
    var hidden = false
    var children: [Fixture] = []
    private enum CodingKeys: String, CodingKey {
      case type, role, subrole, id = "AXUniqueId", label = "AXLabel", value = "AXValue", frame, pid, enabled, hidden, children
    }
  }
}
