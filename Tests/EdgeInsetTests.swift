import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Edge preset start inset")
@MainActor
struct EdgeInsetTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }
    private func command(_ preset: GesturePreset, inset: String? = nil, selected: Bool = true) throws -> Gesture {
        var arguments = [preset.rawValue, "--udid", udid]
        if let inset { arguments += ["--edge-inset", inset] }
        if selected { arguments += selection }
        return try Gesture.parse(arguments)
    }
    private func ends(_ preset: GesturePreset, inset: Double) -> (CGPoint, CGPoint) {
        // Fixed expectations for a 951 by 669 logical display.
        switch preset {
        case .swipeFromLeftEdge: return (CGPoint(x: inset, y: 334.5), CGPoint(x: 931, y: 334.5))
        case .swipeFromRightEdge: return (CGPoint(x: 951 - inset, y: 334.5), CGPoint(x: 20, y: 334.5))
        case .swipeFromTopEdge: return (CGPoint(x: 475.5, y: inset), CGPoint(x: 475.5, y: 649))
        case .swipeFromBottomEdge: return (CGPoint(x: 475.5, y: 669 - inset), CGPoint(x: 475.5, y: 20))
        default: preconditionFailure("Only edge presets are test inputs")
        }
    }
    private func leaves(_ event: FBSimulatorHIDEvent) -> [FBSimulatorHIDEvent] {
        guard let children = event.subEvents else { return [event] }
        return children.flatMap(leaves)
    }
    private func assertEnds(_ events: [FBSimulatorHIDEvent], _ expected: (CGPoint, CGPoint)) {
        #expect(events.first == .touch(direction: .down, x: expected.0.x, y: expected.0.y))
        #expect(events.last == .touch(direction: .up, x: expected.1.x, y: expected.1.y))
        let delays = events.compactMap { event -> Double? in
            if case let .delay(seconds) = event { return seconds }
            return nil
        }
        #expect(abs(delays.reduce(0, +) - 0.3) < 0.000001)
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func explicitInsetChangesStartOnly(preset: GesturePreset) throws {
        let parsed = try command(preset, inset: "1")
        let payload = try parsed.selectedPath()
        #expect(payload.edgeInset == 1 && payload.duration == 0.3 && payload.delta == 50)
        let points = preset.coordinates(screenWidth: 951, screenHeight: 669, edgeInset: parsed.edgeInset)
        let expected = ends(preset, inset: 1)
        #expect(CGPoint(x: points.startX, y: points.startY) == expected.0)
        #expect(CGPoint(x: points.endX, y: points.endY) == expected.1)
        let events = try payload.primitives(logicalSize: CGSize(width: 951, height: 669)).map(\.event)
        assertEnds(events, expected)
        let contacts = events.filter { if case .delay = $0 { return false }; return true }
        #expect(contacts.count == (preset == .swipeFromLeftEdge || preset == .swipeFromRightEdge ? 21 : 15))
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func omittedInsetKeepsDefaultGeometryAndTiming(preset: GesturePreset) throws {
        let original = try command(preset).selectedPath()
        let explicit = try command(preset, inset: "20").selectedPath()
        #expect(original.edgeInset == nil && original.duration == 0.3 && original.delta == 50)
        let size = CGSize(width: 951, height: 669)
        let events = try original.primitives(logicalSize: size).map(\.event)
        let explicitEvents = try explicit.primitives(logicalSize: size).map(\.event)
        #expect(events == explicitEvents)
        assertEnds(events, ends(preset, inset: 20))
    }

    @Test(arguments: ["0", "-1", "nan", "inf", "-inf"])
    func invalidInsetRejectsBothCLIRoutes(raw: String) throws {
        for selected in [false, true] {
            #expect(throws: (any Error).self) { _ = try command(.swipeFromLeftEdge, inset: raw, selected: selected) }
        }
    }

    @Test(arguments: ["scroll-up", "scroll-down", "scroll-left", "scroll-right",
                      "pinch", "double-tap", "rotate", "two-finger-tap", "two-finger-hold"])
    func nonEdgeCommandsRejectOption(name: String) throws {
        do {
            _ = try Gesture.parse([name, "--udid", udid, "--edge-inset", "1"] + selection)
            Issue.record("Non-edge gesture accepted the edge inset")
        } catch {
            #expect(Gesture.message(for: error) == "--edge-inset is available only for edge presets.")
        }
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func inwardPathIsCheckedAgainstFreshSize(preset: GesturePreset) throws {
        let path = try command(preset, inset: "80").selectedPath()
        try path.validate() // No client-side dimension guess.
        #expect(throws: (any Error).self) { _ = try path.primitives(logicalSize: CGSize(width: 100, height: 100)) }
        #expect(throws: (any Error).self) { _ = try path.primitives(logicalSize: CGSize(width: 90, height: 90)) }
        #expect(throws: (any Error).self) { _ = try path.primitives(logicalSize: CGSize(width: 20, height: 20)) }
        let narrowCrossAxis = preset == .swipeFromLeftEdge || preset == .swipeFromRightEdge
            ? CGSize(width: 101, height: 50) : CGSize(width: 50, height: 101)
        #expect(try !path.primitives(logicalSize: narrowCrossAxis).isEmpty)
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func legacyShortInsetRejectsBeforeDirectOrBatchConversion(preset: GesturePreset) async throws {
        let arguments = [preset.rawValue, "--edge-inset", "80", "--screen-width", "101", "--screen-height", "101"]
        let expectedError = "Explicit legacy edge inset requires a path span at least as large as delta."
        do {
            _ = try Gesture.parse(arguments + ["--udid", udid])
            Issue.record("Legacy direct command accepted a zero-step path")
        } catch {
            #expect(Gesture.message(for: error) == expectedError)
        }
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none, typeSubmissionMode: .composite, typeChunkSize: 200)
        do {
            _ = try await BatchStepParser.parseStepTokens(["gesture"] + arguments, globalUDID: udid, context: context, logger: AxeLogger())
            Issue.record("Legacy batch reached the zero-step factory")
        } catch {
            #expect(Gesture.message(for: error) == expectedError)
        }
        // The selected builder safely keeps one movement step for the same short span.
        let selected = try Gesture.parse(arguments + ["--udid", udid] + selection).selectedPath()
        let points = try selected.primitives(logicalSize: CGSize(width: 101, height: 101))
        #expect(points.filter { $0.kind != .delay }.count == 3)
        #expect(points.compactMap(\.x).allSatisfy(\.isFinite) && points.compactMap(\.y).allSatisfy(\.isFinite))
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func legacyExactDeltaAndSmallerRequestedDeltaKeepFiniteEvents(preset: GesturePreset) async throws {
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none, typeSubmissionMode: .composite, typeChunkSize: 200)
        for (length, deltaOption) in [(150.0, [String]()), (101.0, ["--delta", "1"])] {
            let arguments = [preset.rawValue, "--edge-inset", "80", "--screen-width", String(length), "--screen-height", String(length)] + deltaOption
            let parsed = try Gesture.parse(arguments + ["--udid", udid])
            #expect(parsed.edgeInset == 80)
            let plan = try await BatchStepParser.parseStepTokens(["gesture"] + arguments, globalUDID: udid, context: context, logger: AxeLogger())
            guard case let .hidMergeable(event) = try #require(plan.first) else {
                Issue.record("Expected a legacy gesture event"); return
            }
            #expect(plan.count == 1)
            let observation = try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: "test",
                screenID: 3, screenUniqueID: screen, axDisplayID: 3,
                displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                    nativePixelSize: CGSize(width: length * 3, height: length * 3), scale: 3, rotation: .rot0),
                poseRevision: "test")
            // Actual factory output must contain only finite in-bounds balanced contact events.
            let checked = try FBSimulatorHIDSession.preflight(event, observation: observation)
            #expect(checked.primitiveCount > 0 && abs(checked.requestedDelaySeconds - 0.3) < 0.000001)
        }
    }

    @Test func omittedInsetRetainsLegacyAdmission() throws {
        // Do not invoke the old factory's short-path behavior in this option-only check.
        let parsed = try Gesture.parse(["swipe-from-left-edge", "--udid", udid, "--screen-width", "41"])
        #expect(parsed.edgeInset == nil && parsed.delta == nil)
    }

    @Test func rawPathRejectsInsetOnOtherKindsOrInvalidValues() throws {
        for kind in [SelectedHIDPath.Kind.swipe, .drag] {
            let path = SelectedHIDPath(kind: kind, startX: 1, startY: 50, endX: 80, endY: 50,
                duration: 0.3, delta: kind == .swipe ? 50 : nil, steps: kind == .drag ? 2 : nil, edgeInset: 1)
            #expect(throws: (any Error).self) { try path.validate() }
        }
        for value in [0, -1, Double.nan, Double.infinity] {
            let path = SelectedHIDPath(kind: .preset, preset: .swipeFromLeftEdge, duration: 0.3, delta: 50, edgeInset: value)
            #expect(throws: (any Error).self) { try path.validate() }
        }
        let scroll = SelectedHIDPath(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 25, edgeInset: 1)
        #expect(throws: (any Error).self) { try scroll.validate() }
    }

    @Test func payloadRoundTripKeepsInsetAndAbsentFieldKeepsDefault() throws {
        let parsed = try command(.swipeFromLeftEdge, inset: "1")
        let request = try parsed.selectedInput.pathRequest(parsed.selectedPath())
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.path?.edgeInset == 1)
        assertEnds(leaves(try decoded.completeEvent(logicalSize: CGSize(width: 951, height: 669))), ends(.swipeFromLeftEdge, inset: 1))
        let bytes = Data(#"{"kind":"preset","preset":"swipe-from-left-edge","duration":0.3,"delta":50,"preDelay":0,"postDelay":0}"#.utf8)
        let absent = try JSONDecoder().decode(SelectedHIDPath.self, from: bytes)
        #expect(absent.edgeInset == nil)
        assertEnds(try absent.primitives(logicalSize: CGSize(width: 951, height: 669)).map(\.event), ends(.swipeFromLeftEdge, inset: 20))
    }

    @Test func selectedBatchCarriesInsetAndRejectsInvalidStepBeforeSend() async throws {
        let input = try SelectedInputOptions.parse(selection)
        let request = try SelectedBatchStep.request(["gesture", "swipe-from-left-edge", "--edge-inset", "1"], input: input, simulatorUDID: udid)
        #expect(request.path?.edgeInset == 1)
        assertEnds(leaves(try request.completeEvent(logicalSize: CGSize(width: 951, height: 669))), ends(.swipeFromLeftEdge, inset: 1))
        var sends = 0
        var receipts: [SelectedBatchStepReceipt] = []
        await #expect(throws: (any Error).self) {
            try await SelectedBatchRunner.run(lines: ["gesture scroll-up --edge-inset 1", "gesture scroll-up"], input: input, simulatorUDID: udid,
                send: { _, _ in sends += 1; throw ValidationError("Unexpected send") }, emit: { receipts.append($0) })
        }
        #expect(sends == 0 && receipts.count == 1 && receipts.first?.status == .rejectedBeforeSend)
    }

    @Test(arguments: [GesturePreset.swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge])
    func legacyBatchCarriesInsetIntoActualEvent(preset: GesturePreset) async throws {
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none, typeSubmissionMode: .composite, typeChunkSize: 200)
        let plan = try await BatchStepParser.parseStepTokens(["gesture", preset.rawValue, "--edge-inset", "1",
            "--screen-width", "951", "--screen-height", "669"], globalUDID: udid, context: context, logger: AxeLogger())
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Expected legacy gesture event"); return
        }
        #expect(plan.count == 1)
        assertEnds(leaves(event), ends(preset, inset: 1))
    }

    @Test func oldSelectedWireRejectsBeforeAdmission() throws {
        #expect(SelectedHIDRequest.version == 25)
        let path = try command(.swipeFromLeftEdge, inset: "1").selectedPath()
        let request = SelectedHIDRequest(version: 11, requestID: UUID(), screenID: 3, screenUUID: UUID(uuidString: screen),
            operation: .complete, token: nil, primitives: [], path: path)
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(request) }
        #expect(!admission.inFlight && admission.token == nil)
    }
}
