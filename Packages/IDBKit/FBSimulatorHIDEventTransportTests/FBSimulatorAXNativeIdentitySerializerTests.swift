import AppKit
import FBControlCore
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Optional native identity serialization")
struct FBSimulatorAXNativeIdentitySerializerTests {
  @Test(arguments: [true, false])
  func optInAddsOnlyIdentityAndPreservesEverySemanticRow(nested: Bool) throws {
    let child = IdentityElement(key: .init(pid: 42, objectID: UInt64.max), role: "AXTextField", label: "Field")
    let root = IdentityElement(key: .init(pid: 42, objectID: 1), children: [child])
    let legacy = try serialize(root, nested: nested)
    let collector = FBAXNativeIdentityCollector()
    let augmented = try serialize(root, nested: nested, identities: collector)
    #expect(collector.metadata == .init(complete: true))
    #expect(stripIdentities(augmented) == legacy)
    #expect(identityCount(augmented) == 2)
    #expect(root.tokens.allSatisfy { $0 == "owned-read" })
    #expect(child.tokens.allSatisfy { $0 == "owned-read" })
    #expect(root.actionCalls == 0 && child.actionCalls == 0)
  }

  @Test(arguments: ["missingIdentity", "nilChildren", "unsupportedChildType"])
  func unavailableOptionalDataKeepsSemanticChildren(reason: String) throws {
    let child = IdentityElement(key: .init(pid: 42, objectID: 2), label: "Child")
    let root = IdentityElement(key: reason == "missingIdentity" ? nil : .init(pid: 42, objectID: 1),
      children: [child], reason: reason == "missingIdentity" ? nil : reason)
    let legacy = try serialize(root)
    let collector = FBAXNativeIdentityCollector()
    let augmented = try serialize(root, identities: collector)
    #expect(!collector.metadata.complete && collector.metadata.reason == reason)
    #expect(stripIdentities(augmented) == legacy)
    #expect(root.actionCalls == 0 && child.actionCalls == 0)
  }

  @Test func optionalIdentityBoundsDoNotRemoveSemanticControls() throws {
    let element = IdentityElement(key: .init(pid: 42, objectID: 1))
    let tooDeep = FBAXNativeIdentityCollector()
    #expect(tooDeep.identity(of: element, depth: 65) == nil)
    #expect(tooDeep.metadata == .init(complete: false, reason: "depthLimit"))
    let tooMany = FBAXNativeIdentityCollector()
    for _ in 0..<4096 { #expect(tooMany.identity(of: element, depth: 0) != nil) }
    #expect(tooMany.identity(of: element, depth: 0) == nil)
    #expect(tooMany.metadata == .init(complete: false, reason: "nodeLimit"))
    let semantic = try serialize(element)
    #expect(identityCount(semantic) == 0)
  }

  @Test func cancellationStopsOptInTraversalWithoutInput() async {
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let root = IdentityElement(key: .init(pid: 42, objectID: 1))
      return try serialize(root, identities: FBAXNativeIdentityCollector())
    }
    do { _ = try await operation.value; Issue.record("A cancelled identity traversal returned a snapshot.") }
    catch is CancellationError {}
    catch { Issue.record("Unexpected cancellation result: \(error)") }
  }

  private func serialize(_ root: IdentityElement, nested: Bool = true,
    identities: FBAXNativeIdentityCollector? = nil) throws -> FBSimulatorAXValue {
    let keys: Set<FBAXKeys> = [.label, .value, .uniqueID, .type, .frameDict, .pid, .isRemote,
      .focused, .enabled, .hidden, .role, .roleDescription, .subrole]
    let values: [[String: Any]]
    if let identities {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root,
        token: "owned-read", nestedFormat: nested, keys: keys, collector: nil,
        coverageGrid: nil, seenPids: nil, nativeIdentity: identities)
    } else {
      values = try FBSimulatorAccessibilitySerializer.recursiveDescription(fromElement: root,
        token: "owned-read", nestedFormat: nested, keys: keys, collector: nil,
        coverageGrid: nil, seenPids: nil)
    }
    return try JSONDecoder().decode(FBSimulatorAXValue.self, from: JSONSerialization.data(withJSONObject: values))
  }

  private func stripIdentities(_ value: FBSimulatorAXValue) -> FBSimulatorAXValue {
    switch value {
    case .object(let members): return .object(members.filter { $0.key != "nativeIdentity" }.mapValues(stripIdentities))
    case .array(let members): return .array(members.map(stripIdentities))
    default: return value
    }
  }

  private func identityCount(_ value: FBSimulatorAXValue) -> Int {
    switch value {
    case .object(let members): return (members["nativeIdentity"] == nil ? 0 : 1) + members.values.reduce(0) { $0 + identityCount($1) }
    case .array(let members): return members.reduce(0) { $0 + identityCount($1) }
    default: return 0
    }
  }

  private final class IdentityElement: FBAXPlatformElement {
    let key: FBSimulatorAXNativeIdentity?
    let role: String
    let label: String
    let children: [IdentityElement]
    let reason: String?
    var tokens: [String] = []
    var actionCalls = 0
    init(key: FBSimulatorAXNativeIdentity?, role: String = "AXGroup", label: String = "Group",
      children: [IdentityElement] = [], reason: String? = nil) {
      self.key = key; self.role = role; self.label = label; self.children = children; self.reason = reason
    }
    func axNativeIdentity() -> FBSimulatorAXNativeIdentity? { key }
    func axNativeIdentityChildren() -> FBAXNativeIdentityChildren { .init(elements: children, reason: reason) }
    func axChildren() -> [FBAXPlatformElement] { children }
    func axSetBridgeDelegateToken(_ token: String?) { tokens.append(token ?? "<nil>") }
    var axTranslationPid: pid_t { 42 }
    func axFrame() -> NSRect { NSRect(x: 10, y: 20, width: 100, height: 30) }
    func axRole() -> String? { role }
    func axLabel() -> String? { label }
    func axValue() -> Any? { nil }
    func axIdentifier() -> String? { nil }
    func axTitle() -> String? { nil }
    func axHelp() -> String? { nil }
    func axRoleDescription() -> String? { nil }
    func axSubrole() -> String? { nil }
    func axPlaceholderValue() -> String? { nil }
    func axIsEnabled() -> Bool { true }
    func axIsRequired() -> Bool { false }
    func axIsExpanded() -> Bool { false }
    func axIsHidden() -> Bool { false }
    func axIsFocused() -> Bool { false }
    func axCustomActionNames() -> [String] { [] }
    func axActionNames() -> [String] { [] }
    func axTraits() -> [String]? { nil }
    func axPerformPress() -> Bool { actionCalls += 1; return false }
    func axScroll(_ direction: FBAccessibilityScrollDirection) { actionCalls += 1 }
    func axSetValue(_ value: Any?) { actionCalls += 1 }
  }
}
