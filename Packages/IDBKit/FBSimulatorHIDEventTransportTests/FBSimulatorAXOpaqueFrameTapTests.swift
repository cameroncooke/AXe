import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Explicit opaque physical tap frame authority")
struct FBSimulatorAXOpaqueFrameTapTests {
  @Test func exactKnownAndUnmappedStatesStayDistinct() throws {
    let target = NativeIdentityFixture()
    var other = target; other.nativeIdentity = .init(pid: 42, objectID: 2)
    let roots = try [target.node(), other.node()]
    let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: roots, metadata: .init(complete: true))
    #expect(try relation(target, target: target, counts: counts) == .exactKey)
    #expect(try relation(other, target: target, counts: counts) == .knownOther)
    other.nativeIdentity = .init(pid: 42, objectID: 99)
    #expect(try relation(other, target: target, counts: counts) == .unmapped)
    #expect(other.key != target.key)
    // No installed hook means the existing exact/owned checks, not frame authority.
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([other.node()], expected: target.node(),
        selector: selector(target), expectedPID: 42, hitPID: 42, point: point)
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([other.node()], freshRoots: roots,
        expected: target.node(), selector: selector(target), expectedPID: 42, hitPID: 42, point: point)
    }
  }

  @Test(arguments: ["Button", "StaticText", "Group"])
  func everyKnownDifferentPointObjectRefusesFrameAuthority(type: String) throws {
    let target = NativeIdentityFixture()
    var other = target; other.nativeIdentity = .init(pid: 42, objectID: 2)
    other.type = type; other.role = "AX" + type
    let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: [target.node(), other.node()], metadata: .init(complete: true))
    #expect(try relation(other, target: target, counts: counts) == .knownOther)
  }

  @Test(arguments: ["hidden", "disabled", "type", "foreign-node-pid"])
  func duplicateTargetKeysCannotDisappearBeforeFiltering(change: String) throws {
    let target = NativeIdentityFixture()
    var duplicate = target
    switch change {
    case "hidden": duplicate.hidden = true
    case "disabled": duplicate.enabled = false
    case "type": duplicate.type = "StaticText"; duplicate.role = "AXStaticText"
    default: duplicate.pid = 99
    }
    let original = try snapshot([target])
    let fresh = try snapshot([target, duplicate])
    #expect(throws: (any Error).self) { _ = try authority(original, fresh, target) }
    if change != "foreign-node-pid" {
      let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: fresh.roots, metadata: fresh.nativeIdentityMetadata)
      #expect(counts[target.key] == 2)
      #expect(try relation(target, target: target, counts: counts) == .knownOther)
    }
  }

  @Test(arguments: [nil, .init(complete: false, reason: "unknownChildren")] as [FBSimulatorAXNativeIdentityMetadata?])
  func incompleteMetadataDoesNotAuthorizeAFrame(metadata: FBSimulatorAXNativeIdentityMetadata?) throws {
    let target = NativeIdentityFixture()
    let original = try snapshot([target])
    let fresh = try snapshot([target], metadata: metadata)
    #expect(throws: (any Error).self) { _ = try authority(original, fresh, target) }
  }

  @Test func identicalStringTreeRetainsTargetAndLargeNumericAliasesRefuse() throws {
    let target = NativeIdentityFixture()
    let tree = try snapshot([target])
    #expect(try authority(tree, tree, target).nativeIdentity == target.key)
    let observation = try nativeIdentityObservation()
    let first = Data(#"[{"pid":42,"type":"Button","AXValue":9007199254740992,"children":[]}]"#.utf8)
    let second = Data(#"[{"pid":42,"type":"Button","AXValue":9007199254740993,"children":[]}]"#.utf8)
    let a = try FBSimulatorAXSnapshot(observation: observation, jsonData: first)
    let z = try FBSimulatorAXSnapshot(observation: observation, jsonData: second)
    #expect(a.roots[0].value == z.roots[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(a.roots, z.roots) }
  }

  @Test(arguments: ["key", "frame", "value", "label", "role", "subrole", "description", "focus", "hidden", "enabled", "semanticID", "pid"])
  func anyRawTargetOrOtherOccurrenceChangeRefuses(change: String) throws {
    let target = NativeIdentityFixture()
    var other = target; other.nativeIdentity = .init(pid: 42, objectID: 2)
    let original = try snapshot([target, other])
    switch change {
    case "key": other.nativeIdentity = .init(pid: 42, objectID: 3)
    case "frame": other.frame.x += 1
    case "value": other.AXValue = "1"
    case "label": other.AXLabel = "Changed"
    case "role": other.role = "AXGroup"
    case "subrole": other.subrole = "different"
    case "description": other.role_description = "different"
    case "focus": other.focused = true
    case "hidden": other.hidden = true
    case "enabled": other.enabled = false
    case "semanticID": other.AXUniqueId = "different"
    default: other.pid = 99
    }
    #expect(throws: (any Error).self) { _ = try authority(original, snapshot([target, other]), target) }
  }

  @Test func childAndRootOrderStayPartOfThePrivateContract() throws {
    let target = NativeIdentityFixture()
    var other = target; other.nativeIdentity = .init(pid: 42, objectID: 2)
    #expect(throws: (any Error).self) {
      try FBAXOpaqueFrameTapRules.requireUnchangedTree([target.node(), other.node()], [other.node(), target.node()])
    }
    var parent = target; parent.nativeIdentity = .init(pid: 42, objectID: 3); parent.children = [target, other]
    var reordered = parent; reordered.children.reverse()
    #expect(throws: (any Error).self) {
      try FBAXOpaqueFrameTapRules.requireUnchangedTree([parent.node()], [reordered.node()])
    }
  }

  @Test(arguments: ["negative-width", "negative-height", "zero-width", "outside", "missing-focus"])
  func invalidCurrentGeometryOrUnknownStateRefuses(change: String) throws {
    var target = NativeIdentityFixture()
    switch change {
    case "negative-width": target.frame.width = -100
    case "negative-height": target.frame.height = -30
    case "zero-width": target.frame.width = 0
    case "outside": target.frame.x = 390
    default: target.focused = nil
    }
    let tree = try snapshot([target])
    #expect(throws: (any Error).self) { _ = try authority(tree, tree, target) }
  }

  @Test func secondPointMustStayTheSameUnmappedNativeObservation() throws {
    let target = NativeIdentityFixture()
    let counts = try FBAXOpaqueFrameTapRules.keyCounts(in: [target.node()], metadata: .init(complete: true))
    var unknown = target; unknown.nativeIdentity = .init(pid: 42, objectID: 99)
    try FBAXOpaqueFrameTapRules.requireStableUnmappedPoint([unknown.node()], [unknown.node()],
      expectedPID: 42, firstPID: 42, secondPID: 42, target: target.node(), point: point, counts: counts)
    for change in ["key", "frame", "value", "known-key", "pid"] {
      var changed = unknown
      switch change {
      case "key": changed.nativeIdentity = .init(pid: 42, objectID: 100)
      case "frame": changed.frame.x += 1
      case "value": changed.AXValue = "1"
      case "known-key": changed.nativeIdentity = target.key
      default: changed.pid = 99
      }
      #expect(throws: (any Error).self) {
        try FBAXOpaqueFrameTapRules.requireStableUnmappedPoint([unknown.node()], [changed.node()],
          expectedPID: 42, firstPID: 42, secondPID: 42, target: target.node(), point: point, counts: counts)
      }
    }
  }

  @Test func changedPoseCannotReuseFrameAuthority() throws {
    let target = NativeIdentityFixture()
    let original = try snapshot([target])
    let changed = try snapshot([target], observation: nativeIdentityObservation(pose: "folded"))
    #expect(throws: (any Error).self) { _ = try authority(original, changed, target) }
  }

  @Test(arguments: [#"[9007199254740992]"#, #"[9007199254740993]"#,
    #"{"n":9007199254740992}"#, #"{"n":9007199254740993}"#, #"["text"]"#, #"{"n":null}"#])
  func compoundValuesRefuseEvenWhenUnchanged(raw: String) throws {
    let nodes = try valueNodes(raw)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes) }
  }

  @Test(arguments: ["array", "object"])
  func roundedCompoundLargeIntegersCannotPassAsUnchanged(shape: String) throws {
    let left = try valueNodes(shape == "array" ? "[9007199254740992]" : #"{"n":9007199254740992}"#)
    let right = try valueNodes(shape == "array" ? "[9007199254740993]" : #"{"n":9007199254740993}"#)
    #expect(left[0].value == right[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(left, right) }
  }

  @Test(arguments: ["9223372036854775808", "9223372036854775809", "18446744073709551615", "18446744073709551616"])
  func numbersOutsideExactIntEvidenceRefuseEvenWhenUnchanged(raw: String) throws {
    let nodes = try valueNodes(raw)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes) }
  }

  @Test func unsignedBoundaryAliasAndAllIntegerBoundariesRefuseFrameAuthority() throws {
    let first = try valueNodes("9223372036854775808")
    let second = try valueNodes("9223372036854775809")
    #expect(first[0].value == second[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(first, second) }
    for raw in [String(Int.min), "-1", "0", "1", "9007199254740993", String(Int.max)] {
      let nodes = try valueNodes(raw)
      #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes) }
    }
    let maximum = try valueNodes(String(Int.max))
    #expect(maximum[0].value == first[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(maximum, first) }
  }

  @Test(arguments: ["1.5", "-0.5", "1e100"])
  func fractionalAndOverflowNumericValuesRefuse(raw: String) throws {
    let nodes = try valueNodes(raw)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes) }
  }

  @Test(arguments: ["small", "large"])
  func FoundationRoundedFractionsAndTheirIntegerAliasesBothRefuse(shape: String) throws {
    let integer = try valueNodes(shape == "small" ? "1" : "9007199254740992")
    let fraction = try valueNodes(shape == "small" ? "1.00000000000000001" : "9007199254740992.5")
    #expect(integer[0].value == fraction[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(integer, integer) }
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(fraction, fraction) }
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(integer, fraction) }
  }

  @Test func simpleValuesAndExactStringBytesHaveExplicitCoverage() throws {
    for raw in [nil, "null", #""plain""#, #""1.5""#, #""18446744073709551615""#, "true", "false"] as [String?] {
      let nodes = try valueNodes(raw)
      try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes)
    }
    let composed = try valueNodes(#""\u00e9""#)
    let decomposed = try valueNodes(#""e\u0301""#)
    #expect(composed[0].value == decomposed[0].value)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(composed, decomposed) }
    let composedLabel = try JSONDecoder().decode([FBSimulatorAXNode].self, from: Data(#"[{"AXLabel":"\u00e9"}]"#.utf8))
    let decomposedLabel = try JSONDecoder().decode([FBSimulatorAXNode].self, from: Data(#"[{"AXLabel":"e\u0301"}]"#.utf8))
    #expect(composedLabel[0].label == decomposedLabel[0].label)
    #expect(throws: (any Error).self) {
      try FBAXOpaqueFrameTapRules.requireUnchangedTree(composedLabel, decomposedLabel)
    }
  }

  @Test(arguments: ["NaN", "Infinity", "-Infinity"])
  func nonfiniteValuesCannotAuthorizeTheUnmappedFrameRoute(raw: String) throws {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity", nan: "NaN")
    let data = Data(("[{\"AXValue\":\"" + raw + "\"}]").utf8)
    let nodes = try decoder.decode([FBSimulatorAXNode].self, from: data)
    guard case .some(.number(let value)) = nodes[0].value else { Issue.record("The nonfinite fixture did not decode a number."); return }
    #expect(!value.isFinite)
    #expect(throws: (any Error).self) { try FBAXOpaqueFrameTapRules.requireUnchangedTree(nodes, nodes) }
  }

  private func valueNodes(_ raw: String?) throws -> [FBSimulatorAXNode] {
    let member = raw.map { ",\"AXValue\":" + $0 } ?? ""
    return try JSONDecoder().decode([FBSimulatorAXNode].self,
      from: Data(("[{\"pid\":42,\"type\":\"Button\",\"children\":[]" + member + "}]").utf8))
  }

  private var point: CGPoint { CGPoint(x: 50, y: 30) }
  private func selector(_ target: NativeIdentityFixture) -> FBSimulatorAXSelector {
    .nativeObject(identity: target.key, elementType: target.type)
  }
  private func snapshot(_ nodes: [NativeIdentityFixture], metadata: FBSimulatorAXNativeIdentityMetadata? = .init(complete: true),
    observation: FBSimulatorHIDSessionObservation? = nil) throws -> FBSimulatorAXSnapshot {
    try .init(observation: observation ?? nativeIdentityObservation(), jsonData: JSONEncoder().encode(nodes), nativeIdentityMetadata: metadata)
  }
  private func authority(_ original: FBSimulatorAXSnapshot, _ fresh: FBSimulatorAXSnapshot,
    _ target: NativeIdentityFixture) throws -> FBSimulatorAXNode {
    try FBAXOpaqueFrameTapRules.validateAuthority(original: original, fresh: fresh,
      expected: target.node(), selector: selector(target), point: point, observation: original.observation)
  }
  private func relation(_ hit: NativeIdentityFixture, target: NativeIdentityFixture,
    counts: [FBSimulatorAXNativeIdentity: Int]) throws -> FBAXOpaqueFrameTapRules.PointRelationship {
    try FBAXOpaqueFrameTapRules.relationship(pointRoots: [hit.node()], expectedPID: 42, hitPID: 42,
      target: target.node(), point: point, counts: counts)
  }
}
