import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Native AX identity values and complete lookup")
struct FBSimulatorAXNativeIdentityTests {
  @Test(arguments: [UInt64(1), 12_001_969_872_672_651_012, UInt64.max])
  func decimalStringsRoundTripWithoutFloatingPointLoss(objectID: UInt64) throws {
    let value = FBSimulatorAXNativeIdentity(pid: 42, objectID: objectID)
    let data = try JSONEncoder().encode(value)
    let json = try JSONDecoder().decode([String: FBSimulatorAXValue].self, from: data)
    #expect(json["objectID"] == .string(String(objectID)))
    #expect(try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self, from: data) == value)
  }

  @Test(arguments: [#""0""#, #""01""#, #""+1""#, #""-1""#, #"" 1""#, #""1 ""#,
    #""1.0""#, #""1e2""#, #""18446744073709551616""#, #""１""#, "1", "0", "null"])
  func decoderRejectsNoncanonicalOrNumericObjectIDs(object: String) {
    let data = Data((#"{"pid":42,"objectID":"# + object + "}").utf8)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self, from: data) }
  }

  @Test(arguments: [Int32(0), -1])
  func constructorDoesNotGiveInvalidPIDAuthority(pid: Int32) {
    let identity = FBSimulatorAXNativeIdentity(pid: pid, objectID: 1)
    #expect(throws: (any Error).self) { try identity.validate() }
    #expect(throws: (any Error).self) { _ = try JSONEncoder().encode(identity) }
    let data = Data(("{\"pid\":" + String(pid) + ",\"objectID\":\"1\"}").utf8)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(FBSimulatorAXNativeIdentity.self, from: data) }
  }

  @Test func zeroObjectCannotBeEncodedOrSelected() {
    let identity = FBSimulatorAXNativeIdentity(pid: 42, objectID: 0)
    #expect(throws: (any Error).self) { _ = try JSONEncoder().encode(identity) }
    #expect(throws: (any Error).self) { try FBSimulatorAXSelector.nativeObject(identity: identity, elementType: "Button").validate() }
  }

  @Test func olderNodeOutputRetainsItsKeySet() throws {
    let data = Data(#"{"type":"Button","AXUniqueId":"semantic","pid":42,"children":[]}"#.utf8)
    let node = try JSONDecoder().decode(FBSimulatorAXNode.self, from: data)
    #expect(node.nativeIdentity == nil)
    let encoded = try JSONEncoder().encode(node)
    let values = try JSONDecoder().decode([String: FBSimulatorAXValue].self, from: encoded)
    #expect(values["nativeIdentity"] == nil)
    #expect(Set(values.keys) == ["type", "AXUniqueId", "pid", "children"])
    #expect(FBSimulatorAXSelector.identifier("semantic").matches(node))
  }

  @Test func sameLabelsAndFramesDoNotAliasOpaqueObjects() throws {
    var first = NativeIdentityFixture()
    first.AXUniqueId = nil
    var second = first; second.nativeIdentity = .init(pid: 42, objectID: 2)
    let roots = try [first.node(), second.node()]
    let selected = try FBAXNativeObjectSelection.uniqueNode(in: roots, identity: first.key, elementType: "Button")
    #expect(selected.nativeIdentity == first.key)
    #expect(!FBSimulatorAXSelector.nativeObject(identity: first.key, elementType: "Button").matches(roots[1]))
    #expect(FBSimulatorAXButtonLeafSelection.resolve(in: roots, selector: .nativeObject(identity: first.key, elementType: "Button")) == nil)
  }

  @Test(arguments: ["type", "hidden", "disabled", "pid"])
  func duplicatesAreCountedBeforeFilters(change: String) throws {
    let original = NativeIdentityFixture()
    var duplicate = original
    switch change {
    case "type": duplicate.type = "Group"; duplicate.role = "AXGroup"
    case "hidden": duplicate.hidden = true
    case "disabled": duplicate.enabled = false
    default: duplicate.pid = 99
    }
    do {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [original.node(), duplicate.node()], identity: original.key, elementType: "Button")
      Issue.record("A duplicated native object key passed selection.")
    } catch FBSimulatorAXSnapshotError.ambiguous(let count) { #expect(count == 2) }
  }

  @Test func incompleteTreeCannotHideAnOccurrence() throws {
    let original = NativeIdentityFixture()
    var unknown = original; unknown.nativeIdentity = nil
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [original.node(), unknown.node()], identity: original.key, elementType: "Button")
    }
    var invalid = original; invalid.nativeIdentity = .init(pid: 0, objectID: 2)
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [original.node(), invalid.node()], identity: original.key, elementType: "Button")
    }
  }

  @Test func changedKeyOwnerAndTypeDoNotSelectByAppearance() throws {
    let original = NativeIdentityFixture()
    var changed = original; changed.nativeIdentity = .init(pid: 42, objectID: 2)
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [changed.node()], identity: original.key, elementType: "Button")
    }
    changed = original; changed.pid = 99
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [changed.node()], identity: original.key, elementType: "Button")
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [original.node()], identity: original.key, elementType: "Group")
    }
  }

  @Test func optionalIdentityMetadataCannotRemoveSemanticResolution() async throws {
    let fixture = NativeIdentityFixture()
    let data = try JSONEncoder().encode([fixture])
    let observation = try nativeIdentityObservation()
    let provider = NativeIdentityProvider(value: observation)
    for metadata in [nil, .init(complete: false, reason: "nilChildren"),
      .init(complete: false, reason: "pointSubtreeOnly")] as [FBSimulatorAXNativeIdentityMetadata?] {
      let snapshot = try FBSimulatorAXSnapshot(observation: observation, jsonData: data, nativeIdentityMetadata: metadata)
      let semantic = try await snapshot.resolve(.identifier("semantic"), freshnessProvider: provider)
      #expect(semantic.node.identifier == "semantic")
      do {
        _ = try await snapshot.resolve(.nativeObject(identity: fixture.key, elementType: "Button"), freshnessProvider: provider)
        Issue.record("Incomplete metadata authorized an opaque selector.")
      } catch FBSimulatorAXSnapshotError.invalidSelection {}
    }
    let complete = try FBSimulatorAXSnapshot(observation: observation, jsonData: data,
      nativeIdentityMetadata: .init(complete: true))
    let ref = try await complete.resolve(.nativeObject(identity: fixture.key, elementType: "Button"), freshnessProvider: provider)
    #expect(ref.node.nativeIdentity == fixture.key)
    let changed = NativeIdentityProvider(value: try nativeIdentityObservation(pose: "closed"))
    do {
      _ = try await complete.resolve(.nativeObject(identity: fixture.key, elementType: "Button"), freshnessProvider: changed)
      Issue.record("An opaque selector crossed a device context change.")
    } catch FBSimulatorAXSnapshotError.staleContext {}
  }

  @Test func completeLookupHonorsDepthAndNodeBounds() throws {
    var chain = NativeIdentityFixture()
    for index in 2...66 {
      var parent = NativeIdentityFixture(); parent.nativeIdentity = .init(pid: 42, objectID: UInt64(index))
      parent.children = [chain]; chain = parent
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: [chain.node()], identity: .init(pid: 42, objectID: 1), elementType: "Button")
    }
    let tooMany = try (1...4097).map { index in
      var item = NativeIdentityFixture(); item.nativeIdentity = .init(pid: 42, objectID: UInt64(index)); return try item.node()
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXNativeObjectSelection.uniqueNode(in: tooMany, identity: .init(pid: 42, objectID: 1), elementType: "Button")
    }
  }
}

struct NativeIdentityFixture: Encodable {
  struct Frame: Encodable { var x = 10.0; var y = 20.0; var width = 100.0; var height = 30.0 }
  var type = "Button"
  var role: String? = "AXButton"
  var role_description: String? = "button"
  var subrole: String? = nil
  var AXUniqueId: String? = "semantic"
  var nativeIdentity: FBSimulatorAXNativeIdentity? = .init(pid: 42, objectID: 1)
  var AXLabel: String? = "Control"
  var AXValue: String? = "0"
  var pid: Int32 = 42
  var focused: Bool? = false
  var enabled: Bool? = true
  var hidden: Bool? = false
  var frame = Frame()
  var children: [NativeIdentityFixture] = []
  var key: FBSimulatorAXNativeIdentity { nativeIdentity! }
  func node() throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(self))
  }
}

struct NativeIdentityProvider: FBSimulatorHIDFreshnessProvider {
  let value: FBSimulatorHIDSessionObservation
  func observation() async throws -> FBSimulatorHIDSessionObservation { value }
}

func nativeIdentityObservation(pose: String = "open") throws -> FBSimulatorHIDSessionObservation {
  try .init(simulatorUDID: "native-identity", bootIdentity: "boot", screenID: 1,
    screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 1,
    displayContext: .init(hidTarget: 1, nativePixelSize: CGSize(width: 1200, height: 2400), scale: 3, rotation: .rot0),
    poseRevision: pose)
}
