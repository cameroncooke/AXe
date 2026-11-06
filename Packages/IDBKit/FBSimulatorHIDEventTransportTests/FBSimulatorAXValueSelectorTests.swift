import CoreGraphics
import Foundation
import Testing
@testable import FBSimulatorControl

@Suite("Selected AX value selector")
struct FBSimulatorAXValueSelectorTests {
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
  private func json(value: String?, type: String = "Button", pid: Int32 = 42,
                    width: Int = 100, child: Bool = false) -> String {
    let field = value.map { ",\"AXValue\":" + $0 } ?? ""
    let children = child ? #", "children":[{"type":"StaticText","AXLabel":"Tap","pid":42,"frame":{"x":40,"y":20,"width":40,"height":20}}]"# : ""
    return "{\"type\":\"\(type)\",\"AXUniqueId\":\"target\",\"AXLabel\":\"Tap\",\"pid\":\(pid),\"frame\":{\"x\":10,\"y\":10,\"width\":\(width),\"height\":40}\(field)\(children)}"
  }
  private func node(_ source: String) throws -> FBSimulatorAXNode {
    try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(source.utf8))
  }
  private func snapshot(_ roots: [String]) throws -> FBSimulatorAXSnapshot {
    try .init(observation: observation(), jsonData: Data(("[" + roots.joined(separator: ",") + "]").utf8))
  }
  private func resolve(_ roots: [String], _ selector: FBSimulatorAXSelector) async throws -> FBSimulatorAXReference {
    try await snapshot(roots).resolve(selector, freshnessProvider: Provider(value: observation()))
  }

  @Test(arguments: [
    (#"" Ready ""#, "Ready"), ("42", "42"), ("42.5", "42.5"),
    ("true", "true"), ("false", "false"), ("9007199254740993", "9007199254740993"),
    ("9223372036854775807", "9223372036854775807"), ("1.0", "1"), ("-0.0", "0")
  ])
  func scalarConversionUsesLegacyDecodeOrder(raw: String, requested: String) async throws {
    let reference = try await resolve([json(value: raw)], .value(requested))
    #expect(reference.node.identifier == "target")
    #expect(FBSimulatorAXSelector.valueWithType(requested, elementType: "Button").matches(reference.node))
    if raw == "9007199254740993" {
      #expect(!FBSimulatorAXSelector.value("9007199254740992").matches(reference.node))
    }
  }

  @Test func stringMatchingTrimsEdgesButKeepsCaseAndLiteralNumberText() async throws {
    let value = try await resolve([json(value: #""  Ready\n""#)], .value(" \nReady\t"))
    #expect(!FBSimulatorAXSelector.value("ready").matches(value.node))
    let literal = try node(json(value: #""42.0""#))
    #expect(FBSimulatorAXSelector.value("42.0").matches(literal))
    #expect(!FBSimulatorAXSelector.value("42").matches(literal))
    let boolean = try node(json(value: "true"))
    #expect(!FBSimulatorAXSelector.value("1").matches(boolean))
    #expect(!FBSimulatorAXSelector.value("TRUE").matches(boolean))
  }

  @Test(arguments: ["null", "[]", "{}", #""""#, #"" \n ""#])
  func absentOrNonScalarValuesDoNotMatch(raw: String) async throws {
    do {
      _ = try await resolve([json(value: raw)], .value("wanted"))
      Issue.record("An absent, blank or non-scalar value matched")
    } catch FBSimulatorAXSnapshotError.notFound {}
  }

  @Test func missingValueAndBlankSelectorsReject() async throws {
    do {
      _ = try await resolve([json(value: nil)], .value("wanted"))
      Issue.record("A missing value matched")
    } catch FBSimulatorAXSnapshotError.notFound {}
    for selector in [FBSimulatorAXSelector.value(""), .value(" \n"),
                     .valueWithType("wanted", elementType: " ")] {
      #expect(throws: FBSimulatorAXSnapshotError.self) { try selector.validate() }
    }
  }

  @Test func exactTypeFiltersBeforeStrictUniqueness() async throws {
    let button = json(value: #""same""#)
    let text = json(value: #""same""#, type: "StaticText")
    let actual = try await resolve([button, text], .valueWithType("same", elementType: "Button"))
    #expect(actual.node.type == "Button")
    for roots in [[button, text], [button, button]] {
      do {
        _ = try await resolve(roots, .value("same"))
        Issue.record("Ambiguous values were accepted")
      } catch FBSimulatorAXSnapshotError.ambiguous(let count) { #expect(count == 2) }
    }
    do {
      _ = try await resolve([button, button], .valueWithType("same", elementType: "Button"))
      Issue.record("A duplicate matching type was accepted")
    } catch FBSimulatorAXSnapshotError.ambiguous(let count) { #expect(count == 2) }
    for type in ["button", " Button", "Button ", "Slider"] {
      #expect(!FBSimulatorAXSelector.valueWithType("same", elementType: type).matches(actual.node))
    }
  }

  @Test func staleContextStillRejectsValueResolution() async throws {
    do {
      _ = try await snapshot([json(value: "42")]).resolve(.value("42"),
        freshnessProvider: Provider(value: observation(boot: "boot-two")))
      Issue.record("A changed boot was accepted")
    } catch FBSimulatorAXSnapshotError.staleContext {}
  }

  @Test func directHitRejectsChangedOrMissingCurrentValue() throws {
    let expected = try node(json(value: #""ready""#))
    let selector = FBSimulatorAXSelector.valueWithType("ready", elementType: "Button")
    let point = CGPoint(x: 60, y: 30)
    let actual = try FBAXTargetValidationRules.hit([expected], expected: expected, selector: selector,
      expectedPID: 42, hitPID: 42, point: point)
    #expect(actual.identifier == "target")
    for raw in [#""changed""#, "null", "false"] {
      let changed = try node(json(value: raw))
      #expect(throws: FBSimulatorAXTargetError.self) {
        _ = try FBAXTargetValidationRules.hit([changed], expected: expected, selector: selector,
          expectedPID: 42, hitPID: 42, point: point)
      }
    }
    let exactInteger = try node(json(value: "9007199254740993"))
    let integerSelector = FBSimulatorAXSelector.value("9007199254740993")
    _ = try FBAXTargetValidationRules.hit([exactInteger], expected: exactInteger,
      selector: integerSelector, expectedPID: 42, hitPID: 42, point: point)
    let roundedInteger = try node(json(value: "9007199254740992"))
    #expect(exactInteger.value == roundedInteger.value)
    #expect(throws: FBSimulatorAXTargetError.self) {
      _ = try FBAXTargetValidationRules.hit([roundedInteger], expected: exactInteger,
        selector: integerSelector, expectedPID: 42, hitPID: 42, point: point)
    }
  }

  @Test func descendantSelectionChecksFreshButtonValueNotChildValue() throws {
    let expected = try node(json(value: #""ready""#, child: true))
    let child = try #require(expected.children.first)
    let selector = FBSimulatorAXSelector.valueWithType("ready", elementType: "Button")
    let point = CGPoint(x: 60, y: 30)
    let actual = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [expected],
      expected: expected, selector: selector, expectedPID: 42, hitPID: 42, point: point)
    #expect(actual.identifier == "target" && child.value == nil)
    for roots in [[], [expected, expected], [try node(json(value: #""changed""#, child: true))]] {
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.descendantHit([child], freshRoots: roots,
          expected: expected, selector: selector, expectedPID: 42, hitPID: 42, point: point)
      }
    }
  }

  @Test func valueSelectionDoesNotWeakenFramePIDOrButtonChildRules() throws {
    let expected = try node(json(value: "42", child: true))
    let selector = FBSimulatorAXSelector.value("42")
    let point = CGPoint(x: 60, y: 30)
    for source in [json(value: "42", pid: 43), json(value: "42", width: 101),
                   json(value: "42", type: "Slider")] {
      let changed = try node(source)
      #expect(throws: (any Error).self) {
        _ = try FBAXTargetValidationRules.hit([changed], expected: expected, selector: selector,
          expectedPID: 42, hitPID: 42, point: point)
      }
    }
    let slider = try node(json(value: "42", type: "Slider", child: true))
    let child = try #require(slider.children.first)
    #expect(throws: FBSimulatorAXTargetError.self) {
      _ = try FBAXTargetValidationRules.descendantHit([child], freshRoots: [slider], expected: slider,
        selector: selector, expectedPID: 42, hitPID: 42, point: point)
    }
    #expect(throws: FBSimulatorAXTargetError.self) {
      try FBAXTargetValidationRules.firstEvent(.touch(direction: .down, x: 61, y: 30), point: point)
    }
  }

  @Test func publicValueEncodingHasNoSelectorMetadata() throws {
    let original = try node(json(value: "42.5"))
    #expect(original.value == .number(42.5))
    let fields = try JSONDecoder().decode([String: FBSimulatorAXValue].self, from: JSONEncoder().encode(original))
    #expect(fields["AXValue"] == .number(42.5))
    #expect(fields["scalarSelectionValue"] == nil)
    let roundTrip = try JSONDecoder().decode(FBSimulatorAXNode.self, from: JSONEncoder().encode(original))
    #expect(FBSimulatorAXSelector.value("42.5").matches(roundTrip))
  }
}
