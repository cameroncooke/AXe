import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("One owned native point success proof")
struct FBSimulatorAXOpaquePointSuccessTests {
  @Test func oneSuccessfulReplyIsBoundToTheSerializedPointKey() throws {
    var state = fresh()
    try state.willSend(fact(), devicePresent: true)
    state.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    try state.requireSuccess(identity: identity)
    #expect(state.callbacks == 1 && state.sends == 1 && state.replies == 1)
    #expect(throws: (any Error).self) { try state.requireSuccess(identity: .init(pid: 42, objectID: 100)) }
  }

  @Test(arguments: ["missing", "token", "translation-token", "request-type", "attribute", "action", "pid", "object",
    "point", "display", "extra-key", "missing-device"])
  func invalidOrUnownedRequestCannotBeSent(change: String) throws {
    var state = fresh()
    #expect(throws: (any Error).self) {
      try state.willSend(change == "missing" ? nil : fact(change), devicePresent: change != "missing-device")
    }
    #expect(state.sends == 0)
    state.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    #expect(throws: (any Error).self) { try state.requireSuccess(identity: identity) }
  }

  @Test(arguments: [nil, UInt64(1), 7] as [UInt64?])
  func absentOrFailedNativeResponseCannotAuthorizeInput(error: UInt64?) throws {
    var state = fresh()
    try state.willSend(fact(), devicePresent: true)
    state.didReply(fact(), nativeResponsePresent: error != nil, error: error, identity: identity)
    #expect(throws: (any Error).self) { try state.requireSuccess(identity: identity) }
  }

  @Test func missingReplyWrongOwnerAndInvalidObjectRefuse() throws {
    var state = fresh()
    try state.willSend(fact(), devicePresent: true)
    #expect(throws: (any Error).self) { try state.requireSuccess(identity: identity) }
    for key in [nil, .init(pid: 99, objectID: 99), .init(pid: 42, objectID: 0)] as [FBSimulatorAXNativeIdentity?] {
      var sample = fresh(); try sample.willSend(fact(), devicePresent: true)
      sample.didReply(fact(), nativeResponsePresent: true, error: 0, identity: key)
      #expect(throws: (any Error).self) { try sample.requireSuccess(identity: identity) }
    }
  }

  @Test func repeatedRequestOrReplyCannotReplayOrReplaceTheProof() throws {
    var state = fresh(); try state.willSend(fact(), devicePresent: true)
    #expect(throws: (any Error).self) { try state.willSend(fact(), devicePresent: true) }
    state.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    #expect(state.sends == 1)
    #expect(throws: (any Error).self) { try state.requireSuccess(identity: identity) }
    var twice = fresh(); try twice.willSend(fact(), devicePresent: true)
    twice.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    twice.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    #expect(throws: (any Error).self) { try twice.requireSuccess(identity: identity) }
  }

  @Test func changedRequestAfterSendAndCancellationInvalidateTheProof() throws {
    var changed = fresh(); try changed.willSend(fact(), devicePresent: true)
    changed.didReply(fact("client"), nativeResponsePresent: true, error: 0, identity: identity)
    #expect(throws: (any Error).self) { try changed.requireSuccess(identity: identity) }
    var stopped = fresh(); try stopped.willSend(fact(), devicePresent: true)
    stopped.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    stopped.stop()
    #expect(throws: (any Error).self) { try stopped.requireSuccess(identity: identity) }
  }

  @Test(arguments: [CGPoint(x: -1, y: 30), CGPoint(x: 50, y: -1), CGPoint(x: CGFloat.nan, y: 30),
    CGPoint(x: 50, y: CGFloat.infinity)])
  func invalidExpectedNativePointCannotBeSent(point: CGPoint) {
    var state = FBAXOpaquePointSuccessState(token: "owned", point: point, displayID: 1, expectedPID: 42)
    #expect(throws: (any Error).self) { try state.willSend(fact(point: point), devicePresent: true) }
    #expect(state.sends == 0)
  }

  @Test func rotatedPanelBindsNativePointAndExactDisplay() throws {
    let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: "rotated", bootIdentity: "boot",
      screenID: 3, screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 3,
      displayContext: .init(hidTarget: 3, nativePixelSize: CGSize(width: 2007, height: 2853), scale: 3, rotation: .rot90),
      poseRevision: "open")
    let logical = CGPoint(x: 150, y: 250)
    let native = try FBAXPointReadRules.nativePoint(logical, observation: observation)
    #expect(native == CGPoint(x: 250, y: 801) && native != logical)
    let request = fact(point: native, display: 3)
    var state = FBAXOpaquePointSuccessState(token: "owned", point: native, displayID: 3, expectedPID: 42)
    try state.willSend(request, devicePresent: true)
    state.didReply(request, nativeResponsePresent: true, error: 0, identity: identity)
    try state.requireSuccess(identity: identity)
    var wrongPoint = FBAXOpaquePointSuccessState(token: "owned", point: native, displayID: 3, expectedPID: 42)
    #expect(throws: (any Error).self) { try wrongPoint.willSend(fact(point: logical, display: 3), devicePresent: true) }
    var wrongDisplay = FBAXOpaquePointSuccessState(token: "owned", point: native, displayID: 3, expectedPID: 42)
    #expect(throws: (any Error).self) { try wrongDisplay.willSend(fact(point: native, display: 1), devicePresent: true) }
  }

  @Test func diagnosticCapacityHasNoAuthorityOverTheOnePointProof() throws {
    let recorder = FBAXIdentityRoutingRecorder()
    let raw = FBAXRoutingRequest(token: "diagnostic", source: "point", requestType: "6", attributeType: "0",
      clientType: "0", translationPID: "0", translationObjectID: "1",
      point: .inspect(NSValue(point: CGPoint(x: 50, y: 30))), displayID: .inspect(NSNumber(value: 1)),
      contextID: .inspect(nil), genericParameter: .inspect(nil))
    for index in 0..<129 { _ = recorder.begin(raw, now: Double(index)) }
    #expect(recorder.snapshot().truncated)
    var state = fresh(); try state.willSend(fact(), devicePresent: true)
    state.didReply(fact(), nativeResponsePresent: true, error: 0, identity: identity)
    try state.requireSuccess(identity: identity)
  }

  private let identity = FBSimulatorAXNativeIdentity(pid: 42, objectID: 99)
  private final class RequestTag {}
  private final class TranslationTag {}
  private func fresh() -> FBAXOpaquePointSuccessState {
    .init(token: "owned", point: CGPoint(x: 50, y: 30), displayID: 1, expectedPID: 42)
  }
  private func fact(_ change: String = "", point: CGPoint = CGPoint(x: 50, y: 30), display: UInt32 = 1) -> FBAXOpaquePointRequestFact {
    .init(requestIdentity: ObjectIdentifier(RequestTag.self), translationIdentity: ObjectIdentifier(TranslationTag.self),
      token: change == "token" ? "other" : "owned",
      translationToken: change == "translation-token" ? "other" : "owned",
      requestType: change == "request-type" ? 2 : 6,
      attributeType: change == "attribute" ? 1 : 0,
      actionType: change == "action" ? 5 : 0,
      clientType: change == "client" ? 2 : 0,
      translationPID: change == "pid" ? 42 : 0,
      translationObjectID: change == "object" ? 0 : 1,
      point: CGPoint(x: change == "point" ? point.x + 1 : point.x, y: point.y), displayID: change == "display" ? 2 : display,
      parameterKeys: change == "extra-key" ? ["contextId", "displayId", "point"] : ["displayId", "point"])
  }
}
