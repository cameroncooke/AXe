import AccessibilityPlatformTranslation
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Explicit semantic press admission")
struct FBSimulatorAXSemanticPressTests {
  private func binding(_ request: NSObject, _ translation: NSObject, token: String = "owned",
    pid: Int32 = 42, requestType: UInt64 = 7, actionType: UInt64 = 5,
    objectID: UInt64 = 9007199254740993, rawData: Data? = Data([1, 2, 3])) -> FBAXPressBinding {
    .init(requestIdentity: ObjectIdentifier(request), translationIdentity: ObjectIdentifier(translation),
      token: token, pid: pid, objectID: objectID, rawData: rawData,
      requestType: requestType, actionType: actionType, attributeType: 0, clientType: 2, parametersEmpty: true)
  }

  @Test func exactActionAdmitsOnlyOneSend() throws {
    let request = NSObject(); let translation = NSObject()
    let expected = binding(request, translation)
    var policy = FBAXPressAdmission(expected: expected)
    try policy.admit(expected); try policy.willSend()
    #expect(policy.callbacks == 1 && policy.sends == 1)
    #expect(throws: FBAXPressError.self) { try policy.admit(expected) }
    #expect(throws: FBAXPressError.self) { try policy.willSend() }
    #expect(policy.sends == 1)
  }

  @Test func wrongBindingCannotDispatch() {
    let request = NSObject(); let translation = NSObject(); let other = NSObject()
    let expected = binding(request, translation)
    let changed = [binding(other, translation), binding(request, other),
      binding(request, translation, token: "foreign"), binding(request, translation, pid: 43),
      binding(request, translation, requestType: 6), binding(request, translation, actionType: 6)]
    for actual in changed {
      var policy = FBAXPressAdmission(expected: expected)
      #expect(throws: FBAXPressError.self) { try policy.admit(actual) }
      #expect(throws: FBAXPressError.self) { try policy.willSend() }
      #expect(policy.sends == 0)
    }
  }

  @Test func unsupportedMappingNeverAdmits() {
    let request = NSObject(); let translation = NSObject()
    for expected in [binding(request, translation, requestType: 6),
        binding(request, translation, actionType: 6), binding(request, translation, pid: 0)] {
      var policy = FBAXPressAdmission(expected: expected)
      #expect(throws: FBAXPressError.self) { try policy.admit(expected) }
      #expect(throws: FBAXPressError.self) { try policy.willSend() }
      #expect(policy.sends == 0)
    }
  }

  @Test func noCallbackAfterTranslatorEntryIsUncertain() throws {
    let request = NSObject(); let translation = NSObject()
    let gate = FBAXPressGate(binding: binding(request, translation), validate: {})
    try gate.beginTranslatorCall()
    gate.stop(FBAXPressError.rejected("no callback"))
    let result = gate.snapshot()
    #expect(result.translatorCallAttempted && result.callbackCount == 0 && result.sendCount == 0)
    #expect(result.delivery == "uncertain" && result.outcome == "failedNoReplay")
    #expect(throws: FBAXPressError.self) { try gate.beginTranslatorCall() }
  }

  @Test func missingResponseAndNativeErrorsNeverAccept() {
    #expect(!FBSimulatorAXPressReply.decode(present: false, error: nil, attribute: nil, raw: nil).accepted)
    #expect(!FBSimulatorAXPressReply.decode(present: true, error: 3, attribute: 0, raw: NSNumber(value: true)).accepted)
    #expect(!FBSimulatorAXPressReply.decode(present: true, error: 0, attribute: 0, raw: "true").accepted)
    #expect(!FBSimulatorAXPressReply.decode(present: true, error: 0, attribute: 0, raw: NSNumber(value: false)).accepted)
  }

  @Test func replyRequiresExactBooleanValue() {
    for raw in [NSNumber(value: true), NSNumber(value: 1)] {
      #expect(FBSimulatorAXPressReply.decode(present: true, error: 0, attribute: 0, raw: raw).accepted)
    }
    for raw in [NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: Double.nan),
      NSDecimalNumber(string: "1.0000000000000000001")] {
      #expect(!FBSimulatorAXPressReply.decode(present: true, error: 0, attribute: 0, raw: raw).accepted)
    }
  }

  private final class TreeNode {
    let identifier: String?
    let children: [TreeNode]
    let identity: FBAXPressTargetIdentity
    init(_ identifier: String?, children: [TreeNode] = [], objectID: String = "9",
      rawData: Data? = Data([1, 2, 3])) {
      self.identifier = identifier; self.children = children
      identity = .init(target: .init(identifier: identifier ?? "", pid: 42, objectID: objectID,
        frame: CGRect(x: 1, y: 2, width: 30, height: 20), contextID: 12, displayID: 3), rawData: rawData)
    }
  }

  private func select(_ root: TreeNode) throws -> TreeNode {
    try FBAXPressTreeSelection.exactlyOne(root: root, identifier: "feature.switch",
      check: {}, readIdentifier: { $0.identifier }, readChildren: { $0.children })
  }

  @Test func newDuplicateAfterContextAwaitIsRejected() throws {
    let initial = TreeNode("feature.switch")
    #expect(try select(TreeNode(nil, children: [initial])) === initial)
    let finalRoot = TreeNode(nil, children: [initial, TreeNode("feature.switch", objectID: "10")])
    #expect(throws: FBAXPressError.self) { try select(finalRoot) }
  }

  @Test func removedTargetAfterContextAwaitIsRejected() throws {
    let retained = TreeNode("feature.switch")
    #expect(try select(TreeNode(nil, children: [retained])) === retained)
    // The retained old target is valid, but is no longer in the current root.
    #expect(retained.identifier == "feature.switch")
    #expect(throws: FBAXPressError.self) { try select(TreeNode(nil)) }
  }

  @Test func replacedTargetAfterContextAwaitIsRejected() throws {
    let initial = try select(TreeNode(nil, children: [TreeNode("feature.switch")]))
    let freshSame = try select(TreeNode(nil, children: [TreeNode("feature.switch")]))
    try freshSame.identity.requireSame(as: initial.identity)
    for replacement in [TreeNode("feature.switch", objectID: "10"),
      TreeNode("feature.switch", rawData: Data([4, 5, 6]))] {
      let current = try select(TreeNode(nil, children: [replacement]))
      #expect(throws: FBAXPressError.self) { try current.identity.requireSame(as: initial.identity) }
    }
  }

  @Test func absentRawBytesPreserveTypedRequestCapture() throws {
    let translation = try #require(AXPTranslationObject())
    translation.pid = 42; translation.objectID = 9007199254740993
    translation.bridgeDelegateToken = "owned"
    translation.rawElementData = nil
    let request = try #require(AXPTranslatorRequest.request(withTranslation: translation) as? AXPTranslatorRequest)
    request.requestType = 7; request.actionType = 5; request.clientType = 2
    let absent = try #require(FBAXPressBinding.capture(request, token: "owned"))
    #expect(absent.rawData == nil && absent.pid == 42 && absent.objectID == 9007199254740993)
    var policy = FBAXPressAdmission(expected: absent)
    try policy.admit(absent); try policy.willSend()
    #expect(policy.sends == 1)
    translation.rawElementData = Data()
    let empty = try #require(FBAXPressBinding.capture(request, token: "owned"))
    #expect(empty.rawData == Data() && empty != absent)
    var emptyPolicy = FBAXPressAdmission(expected: empty)
    #expect(throws: FBAXPressError.self) { try emptyPolicy.admit(empty) }
    #expect(emptyPolicy.sends == 0)
    translation.bridgeDelegateToken = "foreign"
    #expect(FBAXPressBinding.capture(request, token: "owned") == nil)
    #expect(FBAXPressBinding.capture(nil, token: "owned") == nil)
  }

  @Test func absentDataStillRequiresEveryBindingAndSingleSend() throws {
    let request = NSObject(); let translation = NSObject(); let other = NSObject()
    let expected = binding(request, translation, rawData: nil)
    var admitted = FBAXPressAdmission(expected: expected)
    try admitted.admit(expected); try admitted.willSend()
    #expect(throws: FBAXPressError.self) { try admitted.admit(expected) }
    #expect(throws: FBAXPressError.self) { try admitted.willSend() }
    #expect(admitted.sends == 1)
    for actual in [binding(other, translation, rawData: nil), binding(request, other, rawData: nil),
      binding(request, translation, token: "foreign", rawData: nil),
      binding(request, translation, pid: 43, rawData: nil),
      binding(request, translation, requestType: 6, rawData: nil),
      binding(request, translation, actionType: 6, rawData: nil),
      binding(request, translation, objectID: 9007199254740994, rawData: nil),
      binding(request, translation, rawData: Data()), binding(request, translation, rawData: Data([1]))] {
      var policy = FBAXPressAdmission(expected: expected)
      #expect(throws: FBAXPressError.self) { try policy.admit(actual) }
      #expect(throws: FBAXPressError.self) { try policy.willSend() }
      #expect(policy.sends == 0)
    }
  }

  @Test func presentDataCannotDisappearOrChangeBeforeSend() throws {
    let request = NSObject(); let translation = NSObject()
    let expected = binding(request, translation)
    for actual in [binding(request, translation, rawData: nil),
      binding(request, translation, rawData: Data()), binding(request, translation, rawData: Data([1, 2, 4]))] {
      var policy = FBAXPressAdmission(expected: expected)
      #expect(throws: FBAXPressError.self) { try policy.admit(actual) }
      #expect(policy.sends == 0)
    }
    for invalid in [binding(request, translation, pid: 0, rawData: nil),
      binding(request, translation, objectID: 0, rawData: nil)] {
      var policy = FBAXPressAdmission(expected: invalid)
      #expect(throws: FBAXPressError.self) { try policy.admit(invalid) }
      #expect(policy.sends == 0)
    }
  }

  @Test func freshSelectionPreservesOptionalRawIdentityExactly() throws {
    let original = TreeNode("feature.switch", rawData: nil).identity
    try TreeNode("feature.switch", rawData: nil).identity.requireSame(as: original)
    for changed in [TreeNode("feature.switch", objectID: "10", rawData: nil).identity,
      TreeNode("feature.switch", rawData: Data()).identity,
      TreeNode("feature.switch", rawData: Data([1])).identity] {
      #expect(throws: FBAXPressError.self) { try changed.requireSame(as: original) }
      #expect(throws: FBAXPressError.self) { try original.requireSame(as: changed) }
    }
  }
}
