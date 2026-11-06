import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Selected AX element type")
struct FBSimulatorAXElementTypeTests {
  private struct Provider: FBSimulatorHIDFreshnessProvider {
    let value: FBSimulatorHIDSessionObservation
    func observation() async throws -> FBSimulatorHIDSessionObservation { value }
  }
  private func observation(boot: String = "boot-one") throws -> FBSimulatorHIDSessionObservation {
    try .init(simulatorUDID: "test", bootIdentity: boot, screenID: 3,
      screenUniqueID: "769ED878-389B-4346-9C56-CB0703AB3E58", axDisplayID: 3,
      displayContext: .init(hidTarget: 3, nativePixelSize: CGSize(width: 900, height: 1800),
        scale: 3, rotation: .rot0), poseRevision: "open")
  }
  private func node(_ json: String) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
  }
  private var buttonJSON: String {
    #"{"type":"Button","AXUniqueId":"target","AXLabel":"Tap","pid":42,"frame":{"x":10,"y":10,"width":100,"height":40},"children":[{"type":"StaticText","AXLabel":"Tap","pid":42,"frame":{"x":40,"y":20,"width":40,"height":20}}]}"#
  }
  private func snapshot(_ roots: [FBSimulatorAXNode]) throws -> FBSimulatorAXSnapshot {
    try .init(observation: observation(), jsonData: JSONEncoder().encode(roots))
  }
  private func requireAmbiguous(_ roots: [FBSimulatorAXNode], selector: FBSimulatorAXSelector,
                                count: Int) async throws {
    do {
      _ = try await snapshot(roots).resolve(selector, freshnessProvider: Provider(value: observation()))
      Issue.record("Ambiguous targets were accepted")
    } catch FBSimulatorAXSnapshotError.ambiguous(let actual) {
      #expect(actual == count)
    }
  }

  @Test func typeFiltersBeforeUniquenessWithoutChangingOldLabelRule() async throws {
    let button = try node(buttonJSON)
    let selected = try snapshot([button])
    let provider = Provider(value: try observation())
    let actual = try await selected.resolve(.labelWithType(" Tap ", elementType: "Button"), freshnessProvider: provider)
    #expect(actual.node.identifier == "target" && actual.node.type == "Button")
    try await requireAmbiguous([button], selector: .label("Tap"), count: 2)
    let oldID = try await selected.resolve(.identifier("target"), freshnessProvider: provider)
    #expect(oldID.node.identifier == actual.node.identifier)
    let filteredID = try await selected.resolve(.identifierWithType("target", elementType: "Button"), freshnessProvider: provider)
    #expect(filteredID.snapshotID == actual.snapshotID)
  }

  @Test func matchingDuplicateTypeStillRejects() async throws {
    let button = try node(buttonJSON)
    try await requireAmbiguous([button, button], selector: .labelWithType("Tap", elementType: "Button"), count: 2)
    try await requireAmbiguous([button, button], selector: .identifierWithType("target", elementType: "Button"), count: 2)
  }

  @Test(arguments: ["button", " Button", "Button ", "Slider"])
  func typeMatchingIsExact(type: String) async throws {
    let selected = try snapshot([node(buttonJSON)])
    do {
      _ = try await selected.resolve(.identifierWithType("target", elementType: type),
        freshnessProvider: Provider(value: observation()))
      Issue.record("A different type matched")
    } catch FBSimulatorAXSnapshotError.notFound {}
  }

  @Test func missingTypeAndEmptyFilterCannotMatch() async throws {
    let untyped = try node(#"{"AXUniqueId":"target","AXLabel":"Tap","pid":42}"#)
    do {
      _ = try await snapshot([untyped]).resolve(.identifierWithType("target", elementType: "Button"),
        freshnessProvider: Provider(value: observation()))
      Issue.record("Missing type was accepted")
    } catch FBSimulatorAXSnapshotError.notFound {}
    for type in ["", " "] {
      #expect(throws: FBSimulatorAXSnapshotError.self) {
        try FBSimulatorAXSelector.identifierWithType("target", elementType: type).validate()
      }
    }
  }

  @Test func staleContextStillRejectsTypedResolution() async throws {
    let selected = try snapshot([node(buttonJSON)])
    do {
      _ = try await selected.resolve(.labelWithType("Tap", elementType: "Button"),
        freshnessProvider: Provider(value: observation(boot: "boot-two")))
      Issue.record("Changed boot was accepted")
    } catch FBSimulatorAXSnapshotError.staleContext {}
  }

  @Test func directHitKeepsTypePIDFrameAndFirstDownChecks() throws {
    let expected = try node(buttonJSON)
    let selector = FBSimulatorAXSelector.identifierWithType("target", elementType: "Button")
    let point = CGPoint(x: 60, y: 30)
    let actual = try FBAXTargetValidationRules.hit([expected], expected: expected, selector: selector,
      expectedPID: 42, hitPID: 42, point: point)
    #expect(actual.identifier == "target")
    for json in [buttonJSON.replacingOccurrences(of: #""type":"Button""#, with: #""type":"Slider""#),
                 buttonJSON.replacingOccurrences(of: #""width":100"#, with: #""width":101"#),
                 buttonJSON.replacingOccurrences(of: #""pid":42"#, with: #""pid":43"#)] {
      let changed = try node(json)
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.hit([changed], expected: expected, selector: selector,
          expectedPID: 42, hitPID: 42, point: point)
      }
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.hit([expected], expected: expected,
        selector: .identifierWithType("target", elementType: "Slider"), expectedPID: 42, hitPID: 42, point: point)
    }
    try FBAXTargetValidationRules.firstEvent(.touch(direction: .down, x: 60, y: 30), point: point)
    #expect(throws: (any Error).self) {
      try FBAXTargetValidationRules.firstEvent(.touch(direction: .down, x: 61, y: 30), point: point)
    }
  }

  @Test func descendantTypeAppliesToFreshButtonNotItsTextChild() throws {
    let expected = try node(buttonJSON)
    let child = try #require(expected.children.first)
    let selector = FBSimulatorAXSelector.labelWithType("Tap", elementType: "Button")
    let point = CGPoint(x: 60, y: 30)
    let actual = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [expected],
      expected: expected, selector: selector, expectedPID: 42, hitPID: 42, point: point)
    #expect(actual.identifier == "target" && child.type == "StaticText")
    for roots in [[], [expected, expected],
                  [try node(buttonJSON.replacingOccurrences(of: #""type":"Button""#, with: #""type":"Slider""#))]] {
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.descendantHit([child], freshRoots: roots,
          expected: expected, selector: selector, expectedPID: 42, hitPID: 42, point: point)
      }
    }
    #expect(throws: (any Error).self) {
      _ = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [expected], expected: expected,
        selector: .labelWithType("Tap", elementType: "StaticText"), expectedPID: 42, hitPID: 42, point: point)
    }
  }


  @Test func simulatorTokenRejectsInvalidIdentityBeforeNativeUse() throws {
    let bytes: [UInt8] = [42,0,0,0, 1,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0]
    let valid = try FBAXSimulatorDeviceToken(data: Data(bytes), expectedPID: 42)
    #expect(valid.pid == 42 && valid.element == 1 && valid.elementID == 2)
    var zeroElement = bytes; zeroElement[4] = 0
    var zeroID = bytes; zeroID[12] = 0
    var negativePID = bytes; negativePID.replaceSubrange(0..<4, with: [255,255,255,255])
    for data in [Data(bytes.dropLast()), Data(bytes + [0]), Data(zeroElement), Data(zeroID), Data(negativePID)] {
      #expect(throws: FBAXNativeSwitchError.self) {
        _ = try FBAXSimulatorDeviceToken(data: data, expectedPID: 42)
      }
    }
    #expect(throws: FBAXNativeSwitchError.self) {
      _ = try FBAXSimulatorDeviceToken(data: Data(bytes), expectedPID: 43)
    }
  }

  @Test func switchCandidateKeepsUniqueIdentityPIDAndPointRequirements() throws {
    let target = try node(#"{"type":"CheckBox","AXUniqueId":"switch","pid":42,"frame":{"x":10,"y":10,"width":100,"height":40}}"#)
    let hit = try node(#"{"type":"Group","pid":42,"frame":{"x":20,"y":10,"width":80,"height":40}}"#)
    let selector = FBSimulatorAXSelector.identifier("switch")
    let point = CGPoint(x: 60, y: 30)
    let candidate = try FBAXTargetValidationRules.nativeSwitchTarget([hit], freshRoots: [target],
      expected: target, selector: selector, expectedPID: 42, hitPID: 42, point: point)
    #expect(candidate.identifier == "switch")
    for roots in [[], [target,target], [try node(buttonJSON)]] {
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.nativeSwitchTarget([hit], freshRoots: roots,
          expected: target, selector: selector, expectedPID: 42, hitPID: 42, point: point)
      }
    }
    for (pid, location) in [(Int32(43), point), (Int32(42), CGPoint(x: 5, y: 30))] {
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.nativeSwitchTarget([hit], freshRoots: [target],
          expected: target, selector: selector, expectedPID: 42, hitPID: pid, point: location)
      }
    }
  }
}
