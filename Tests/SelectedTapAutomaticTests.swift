import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected automatic tap")
@MainActor
struct SelectedTapAutomaticTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func parse(_ arguments: [String]) throws -> Tap {
        try Tap.parse(["--udid", udid] + selection + arguments)
    }
    private func node(_ json: String) throws -> FBSimulatorAXNode {
        try JSONDecoder().decode(FBSimulatorAXNode.self, from: Data(json.utf8))
    }
    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try .init(simulatorUDID: udid, bootIdentity: "test-boot", screenID: 3, screenUniqueID: screen,
            axDisplayID: 3, displayContext: .init(hidTarget: 3, nativePixelSize: CGSize(width: 300, height: 600),
            scale: 3, rotation: .rot0), poseRevision: "test-pose")
    }

    @Test(arguments: [
        #"{"type":"Switch"}"#, #"{"type":"Toggle"}"#,
        #"{"type":"CheckBox","role":"AXSwitch"}"#,
        #"{"type":"Button","subrole":"AXSwitch"}"#,
        #"{"type":"Button","role_description":"  SWITCH control \n"}"#,
        #"{"type":"Button","role_description":"Toggle control"}"#
    ])
    func switchPolicyUsesTheExactLegacyDecoder(json: String) throws {
        let target = try node(json)
        let legacy = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
        #expect(legacy.isSwitchLikeControl)
        let chosen = try SelectedTapStyle.automatic.resolved(for: target)
        #expect(chosen == .physical)
        #expect(try chosen.event(x: 10, y: 20) == .tapAt(x: 10, y: 20, duration: 0.1))
        try chosen.validateAutomaticChoice(verifiedTarget: target)
    }

    @Test(arguments: [
        #"{}"#, #"{"type":"Button"}"#, #"{"type":"CheckBox"}"#,
        #"{"type":"switch"}"#, #"{"role":"axswitch","subrole":" AXSwitch "}"#,
        #"{"role_description":" \n"}"#, #"{"role_description":"slider"}"#,
        #"{"type":"Button","children":[{"type":"Switch"}]}"#
    ])
    func otherTargetsKeepSimulatorChoiceWithoutChildRedirection(json: String) throws {
        let target = try node(json)
        let legacy = try JSONDecoder().decode(AccessibilityElement.self, from: Data(json.utf8))
        #expect(!legacy.isSwitchLikeControl)
        let chosen = try SelectedTapStyle.automatic.resolved(for: target)
        #expect(chosen == .simulator)
        #expect(try chosen.event(x: 10, y: 20) == .tapAt(x: 10, y: 20))
    }

    @Test(arguments: [false, true])
    func changedVerifiedTargetChoiceRejectsAtTheProductionGate(initialSwitch: Bool) throws {
        let button = try node(#"{"type":"Button","role_description":"button"}"#)
        let toggle = try node(#"{"type":"Button","role_description":"toggle"}"#)
        let initial = initialSwitch ? toggle : button
        let fresh = initialSwitch ? button : toggle
        let chosen = try SelectedTapStyle.automatic.resolved(for: initial)
        try chosen.validateAutomaticChoice(verifiedTarget: initial)
        #expect(throws: (any Error).self) { try chosen.validateAutomaticChoice(verifiedTarget: fresh) }
        // The production first-down guard calls this gate after native validation and
        // before returning to HID enqueue. This pure check does not claim native input.
    }

    @Test func freshTargetMayChangeMetadataWithoutChangingStyle() throws {
        let initial = try node(#"{"type":"Button","role_description":"toggle"}"#)
        let fresh = try node(#"{"type":"Button","subrole":"AXSwitch"}"#)
        let chosen = try SelectedTapStyle.automatic.resolved(for: initial)
        try chosen.validateAutomaticChoice(verifiedTarget: fresh)
    }

    @Test func unresolvedAutomaticCannotBuildAXEventOrPassChoiceGuard() throws {
        let ax = try #require(parse(["--id", "target", "--expected-pid", "42", "--tap-style", "automatic"]).selectedRequest().ax)
        #expect(throws: (any Error).self) { _ = try ax.tapEvent(at: CGPoint(x: 10, y: 20)) }
        #expect(throws: (any Error).self) { _ = try SelectedTapStyle.automatic.event(x: 10, y: 20) }
        #expect(throws: (any Error).self) {
            try SelectedTapStyle.automatic.validateAutomaticChoice(verifiedTarget: node(#"{"type":"Button"}"#))
        }
    }

    @Test(arguments: [false, true])
    func coordinateAutomaticUsesActualNoHoldFactoryAndBatch(withDelays: Bool) throws {
        var arguments = ["-x", "12.5", "-y", "20.25", "--tap-style", "automatic"]
        if withDelays { arguments += ["--pre-delay", "0.2", "--post-delay", "0.3"] }
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let contacts: [FBSimulatorHIDEvent] = [.touch(direction: .down, x: 12.5, y: 20.25),
                                             .touch(direction: .up, x: 12.5, y: 20.25)]
        #expect(FBSimulatorHIDEvent.tapAt(x: 12.5, y: 20.25) == .composite(contacts))
        let expected = withDelays ? [.delay(0.2)] + contacts + [.delay(0.3)] : contacts
        #expect(direct.event == .composite(expected) && batch.event == direct.event)
        #expect(direct.ax == nil && batch.ax == nil && direct.version == 21)
        let checked = try FBSimulatorHIDSession.preflight(direct.event, observation: observation())
        #expect(checked.primitiveCount == 2 && checked.requestedDelaySeconds == (withDelays ? 0.5 : 0))
    }

    @Test(arguments: [
        ["--id", "target"], ["--id", "target", "--element-type", "Button"],
        ["--label", "Tap target"], ["--label", "Tap target", "--element-type", "Button"],
        ["--value", " Ready "], ["--value", " Ready ", "--element-type", "TextField"]
    ])
    func selectorTypeDelaysAndAutomaticStyleReachWireAndBatch(selector: [String]) throws {
        let arguments = selector + ["--expected-pid", "42", "--tap-style", "automatic",
            "--ax-preparation", "existing-bridge", "--pre-delay", "0.2", "--post-delay", "0.3"]
        let direct = try parse(arguments).selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(direct.ax) == encoder.encode(batch.ax))
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: encoder.encode(direct))
        try decoded.validate()
        let ax = try #require(decoded.ax)
        #expect(ax.tapStyle == .automatic && ax.selectorValue == selector[1] && ax.expectedPID == 42)
        #expect(ax.selectorKind?.rawValue == String(selector[0].dropFirst(2)) && ax.selector != nil)
        #expect(ax.elementType == (selector.count == 4 ? selector[3] : nil))
        #expect(ax.preDelay == 0.2 && ax.postDelay == 0.3 && ax.preparation == .existingBridge)
        #expect(direct.requestID != batch.requestID && decoded.version == 21)
        let target = try node(#"{"type":"Button","subrole":"AXSwitch"}"#)
        #expect(try ax.tapEvent(at: CGPoint(x: 10, y: 20), target: target) == .tapAt(x: 10, y: 20, duration: 0.1))
    }

    @Test(arguments: [[], ["--tap-style", "physical"], ["--tap-style", "simulator"]])
    func existingStylesKeepTheirExactEventsAndPayloads(style: [String]) throws {
        let command = try parse(["--id", "target", "--expected-pid", "42"] + style)
        let ax = try #require(command.selectedRequest().ax)
        let switchTarget = try node(#"{"type":"Switch"}"#)
        let event = try ax.tapEvent(at: CGPoint(x: 10, y: 20), target: switchTarget)
        let expected: FBSimulatorHIDEvent = style.last == "simulator" ? .tapAt(x: 10, y: 20)
            : .tapAt(x: 10, y: 20, duration: 0.1)
        #expect(event == expected)
        #expect(ax.tapStyle == (style.last == "simulator" ? .simulator : nil))
        let coordinate = try parse(["-x", "10", "-y", "20"] + style).selectedRequest()
        #expect(coordinate.event == event)
    }

    @Test func wireSixteenRejectsBeforeOwnership() throws {
        let current = try parse(["--id", "target", "--expected-pid", "42", "--tap-style", "automatic"]).selectedRequest()
        let old = SelectedHIDRequest(version: 16, requestID: current.requestID, screenID: current.screenID,
            screenUUID: current.screenUUID, operation: .complete, token: nil, primitives: [], ax: current.ax)
        var owner = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try owner.enter(old) }
        #expect(!owner.inFlight && owner.token == nil)
        try owner.enter(current)
        #expect(owner.inFlight && current.version == 21)
    }

    @Test(arguments: [SelectedAXRequest.Kind.describe, .describePoint, .sliderEndpoint, .semanticPress])
    func automaticCannotEnterOtherAXKinds(kind: SelectedAXRequest.Kind) throws {
        let ax = SelectedAXRequest(kind: kind, expectedPID: 42, preparation: .existingBridge,
            endpoint: kind == .sliderEndpoint ? .minimum : nil,
            selectorKind: kind == .sliderEndpoint || kind == .semanticPress ? .id : nil,
            selectorValue: kind == .sliderEndpoint || kind == .semanticPress ? "target" : nil,
            preDelay: 0, postDelay: 0, point: kind == .describePoint ? .init(x: 1, y: 2) : nil, tapStyle: .automatic)
        var owner = SelectedHIDAdmission()
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: UUID(uuidString: screen), operation: .complete, token: nil, primitives: [], ax: ax)
        #expect(throws: (any Error).self) { try owner.enter(request) }
        #expect(!owner.inFlight)
    }

    @Test(arguments: [
        ["--id", "target", "--expected-pid", "42", "--semantic-press"],
        ["--id", "target", "--expected-pid", "42", "--wait-timeout", "1"],
        ["--id", "target", "--expected-pid", "42", "--poll-interval", "0.1"],
        ["-x", "1", "-y", "2", "--element-type", "Button"]
    ])
    func invalidAutomaticOptionsStillReject(arguments: [String]) throws {
        #expect(throws: (any Error).self) { _ = try parse(arguments + ["--tap-style", "automatic"]) }
    }

    @Test func batchDefaultStyleDoesNotOverrideSelectedSteps() throws {
        for batchStyle in [[], ["--tap-style", "automatic"]] {
            let command = try Batch.parse(["--udid", udid] + selection + batchStyle +
                ["--step", "tap -x 1 -y 2", "--step", "tap --id target --expected-pid 42"])
            #expect(command.tapStyle == .automatic)
            let coordinate = try SelectedBatchStep.request(ShellTokenizer.tokenize(command.steps[0]),
                input: command.selectedInput, simulatorUDID: command.simulatorUDID)
            #expect(coordinate.ax == nil && coordinate.event == .tapAt(x: 1, y: 2, duration: 0.1))
            let checked = try FBSimulatorHIDSession.preflight(coordinate.event, observation: observation())
            #expect(checked.primitiveCount == 2 && checked.requestedDelaySeconds == 0.1)
            let target = try SelectedBatchStep.request(ShellTokenizer.tokenize(command.steps[1]),
                input: command.selectedInput, simulatorUDID: command.simulatorUDID)
            let ax = try #require(target.ax)
            #expect(ax.tapStyle == nil)
            #expect(try ax.tapEvent(at: CGPoint(x: 1, y: 2)) == .tapAt(x: 1, y: 2, duration: 0.1))
        }
        for style in ["physical", "simulator"] {
            #expect(throws: (any Error).self) {
                _ = try Batch.parse(["--udid", udid] + selection +
                    ["--tap-style", style, "--step", "tap -x 1 -y 2"])
            }
        }
    }

    @Test(arguments: ["failedBeforeInput", "failedNoReplay"])
    func failedAutomaticHitStopsBatchWithNoOtherStyleOrSentinel(outcome: String) async throws {
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["tap --id target --expected-pid 42 --tap-style automatic", "tap -x 2 -y 3"],
                input: SelectedInputOptions.parse(selection), simulatorUDID: udid,
                send: { request, _ in
                    sends += 1
                    #expect(request.ax?.tapStyle == .automatic)
                    return SelectedHIDResponse(version: request.version, requestID: request.requestID,
                        brokerID: UUID(), outcome: outcome, token: nil, enqueuedEventCount: 0,
                        cleanup: "notNeeded", error: "Fresh hit rejected", context: nil)
                }, emit: { receipts.append($0) })
        }
        #expect(sends == 1 && receipts.count == 1 && receipts[0].status == .failedResponse)
    }
}
