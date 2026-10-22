import ArgumentParser
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Selected Home boundaries")
struct SelectedHomeTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen.uuidString]
    }
    private func parse(_ extra: [String] = []) throws -> Button {
        try Button.parse(["home", "--udid", udid] + selection + extra)
    }
    private func observation(boot: String = "boot-one") throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: udid, bootIdentity: boot,
            screenID: 3, screenUniqueID: screen.uuidString, axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot90),
            poseRevision: "pose-one")
    }
    private func request(version: Int = SelectedHIDRequest.version,
                         operation: SelectedHIDRequest.Operation = .complete,
                         token: UUID? = nil, screenID: UInt32? = 3,
                         screenUUID: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000003"),
                         primitives: [SelectedHIDPrimitive] = []) -> SelectedHIDRequest {
        SelectedHIDRequest(version: version, requestID: UUID(), screenID: screenID,
            screenUUID: screenUUID, operation: operation, token: token, primitives: primitives,
            home: SelectedHomeRequest(duration: nil, expectedBoot: nil))
    }

    @Test func defaultHomeRoundTripKeepsDeviceButtonAndSelectedContext() throws {
        let original = try parse().selectedRequest()
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(original))
        try decoded.validate()
        #expect(SelectedHIDRequest.version == 26)
        #expect(decoded.requestID == original.requestID && decoded.version == SelectedHIDRequest.version)
        #expect(decoded.screenID == 3 && decoded.screenUUID == screen)
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.primitives.isEmpty)
        let home = try #require(decoded.home)
        #expect(home.duration == nil && home.expectedBoot == nil)
        let event = try decoded.completeEvent(observation: observation())
        #expect(event == .composite([.button(direction: .down, button: .homeButton),
                                    .button(direction: .up, button: .homeButton)]))
        let plan = try FBSimulatorHIDSession.preflight(event, observation: observation())
        #expect(plan.primitiveCount == 2 && plan.requestedDelaySeconds == 0)
        #expect(throws: (any Error).self) { _ = try decoded.completeEvent(logicalSize: CGSize(width: 200, height: 100)) }
        var admission = SelectedHIDAdmission()
        #expect(throws: (any Error).self) { try admission.enter(request(version: 25)) }
        #expect(!admission.inFlight)
    }

    @Test(arguments: [0.2, 1.0, 10.0])
    func explicitDurationPreservesFractionAndBalancedRelease(duration: Double) throws {
        let command = try parse(["--duration", String(duration), "--expected-boot", "boot-one"])
        let request = try command.selectedRequest()
        let home = try #require(request.home)
        #expect(home.duration == duration && home.expectedBoot == "boot-one")
        let event = try request.completeEvent(observation: observation())
        #expect(event == .composite([.button(direction: .down, button: .homeButton),
                                    .delay(duration), .button(direction: .up, button: .homeButton)]))
        let plan = try FBSimulatorHIDSession.preflight(event, observation: observation())
        #expect(plan.primitiveCount == 2 && plan.requestedDelaySeconds == duration)
    }

    @Test(arguments: [0.0, -0.1, 10.001, Double.infinity, -Double.infinity, Double.nan])
    func invalidDurationCannotCreateAHomeEvent(duration: Double) throws {
        let payload = SelectedHomeRequest(duration: duration, expectedBoot: nil)
        #expect(throws: (any Error).self) { try payload.validate() }
        #expect(throws: (any Error).self) { _ = try payload.event(observation: observation()) }
        #expect(throws: (any Error).self) { _ = try parse(["--duration", String(duration)]) }
    }

    @Test(arguments: ["apple-pay", "lock", "siri"])
    func selectedOtherButtonsRejectWhileLegacyRemainsAvailable(name: String) throws {
        #expect(throws: (any Error).self) { _ = try Button.parse([name, "--udid", udid] + selection) }
        let legacy = try Button.parse([name, "--udid", udid, "--duration", "0.2"])
        #expect(legacy.buttonType.rawValue == name && legacy.duration == 0.2)
        #expect(legacy.selectedInput.mode == .legacy)
        #expect(throws: (any Error).self) { _ = try legacy.selectedRequest() }
    }

    @Test(arguments: [
        ["--input-mode", "selected"],
        ["--input-mode", "selected", "--screen-id", "3"],
        ["--input-mode", "selected", "--screen-uuid", "00000000-0000-0000-0000-000000000003"],
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", "invalid"],
        ["--input-mode", "selected", "--screen-id", "-1", "--screen-uuid", "00000000-0000-0000-0000-000000000003"],
        ["--screen-id", "3", "--screen-uuid", "00000000-0000-0000-0000-000000000003"],
        ["--expected-boot", "boot-one"]
    ])
    func parserRejectsMissingOrLegacySelection(options: [String]) throws {
        #expect(throws: (any Error).self) { _ = try Button.parse(["home", "--udid", udid] + options) }
    }

    @Test func exactBootAdmissionRejectsEmptyAndChangedIdentity() throws {
        for empty in ["", " ", "\n"] {
            #expect(throws: (any Error).self) { _ = try parse(["--expected-boot", empty]) }
        }
        let request = try parse(["--expected-boot", "boot-one"]).selectedRequest()
        let home = try #require(request.home)
        try home.validate(observation: observation())
        #expect(throws: (any Error).self) { try home.validate(observation: observation(boot: "boot-two")) }
        #expect(throws: (any Error).self) { _ = try request.completeEvent(observation: observation(boot: "boot-two")) }
        #expect(throws: (any Error).self) { _ = try request.completeEvent(observation: observation(boot: " boot-one")) }
    }

    @Test func malformedAndMixedPayloadsNeverEnterOwner() throws {
        var invalid = [request(token: UUID()), request(screenID: nil), request(screenUUID: nil),
                       request(primitives: [.touch(.down, x: 1, y: 2)])]
        invalid += [SelectedHIDRequest.Operation.begin, .move, .end, .close].map { request(operation: $0) }
        var item = request(); item.path = .init(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 25); invalid.append(item)
        item = request(); item.pinch = .init(centerX: 50, centerY: 100, scale: 2, radius: 10); invalid.append(item)
        item = request(); item.gesture = .doubleTap(.init(point: .init(x: 50, y: 100))); invalid.append(item)
        item = request(); item.ax = .init(kind: .describe, expectedPID: 123, preparation: .existingBridge,
            endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0); invalid.append(item)
        item = request(); item.keyboard = .init(expectedPID: 123, focusID: "field", events: [.down(4), .up(4)]); invalid.append(item)
        item = request(); item.hinge = .init(kind: .read, expectedBootIdentity: nil,
            degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil); invalid.append(item)
        for value in invalid {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try admission.enter(value) }
            #expect(!admission.inFlight && admission.token == nil)
        }
    }

    @Test func homeCannotReplaceAnInFlightOrRetainedContact() throws {
        var admission = SelectedHIDAdmission()
        try admission.enter(request())
        #expect(throws: (any Error).self) { try admission.enter(request()) }
        #expect(admission.inFlight)
        admission.finish()
        let begin = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: screen, operation: .begin, token: nil,
            primitives: [.touch(.down, x: 10, y: 20)])
        let token = UUID()
        try admission.enter(begin)
        admission.retain(begin, token: token)
        admission.finish()
        #expect(throws: (any Error).self) { try admission.enter(request()) }
        #expect(!admission.inFlight && admission.token == token)
        #expect(admission.screenID == 3 && admission.screenUUID == screen)
    }

    @Test func publicPreflightRejectsIncompleteHomeButtonLifetime() throws {
        for event in [FBSimulatorHIDEvent.button(direction: .down, button: .homeButton),
                      .button(direction: .up, button: .homeButton),
                      .composite([.button(direction: .down, button: .homeButton), .delay(0.2)])] {
            #expect(throws: (any Error).self) { _ = try FBSimulatorHIDSession.preflight(event, observation: observation()) }
        }
    }

    @Test(arguments: [[], ["--duration", "0.2"]])
    @MainActor func legacyBatchPreservesHomeAndRejectsSelectedBeforeConversion(extra: [String]) async throws {
        let context = BatchContext(simulatorUDID: udid, axCachePolicy: .none,
            typeSubmissionMode: .composite, typeChunkSize: 200)
        let tokens = ["button", "home"] + extra
        do {
            _ = try await BatchStepParser.parseStepTokens(tokens + selection, globalUDID: udid,
                context: context, logger: AxeLogger())
            Issue.record("Selected Home reached legacy batch conversion")
        } catch let error as ValidationError {
            #expect(error.description == "Selected input is not supported in batch steps. Run the selected command separately.")
        }
        let plan = try await BatchStepParser.parseStepTokens(tokens, globalUDID: udid,
            context: context, logger: AxeLogger())
        #expect(plan.count == 1)
        guard case let .hidMergeable(event) = try #require(plan.first) else {
            Issue.record("Legacy Home did not produce its original button event"); return
        }
        #expect(event == (try parse(extra).selectedRequest().completeEvent(observation: observation())))
    }

    @Test(arguments: ["cancelled", "staleContext", "observationUnavailable", "transportFailure", "invalidRetainedInput", "inputAdmissionRejected"])
    func typedInterruptionKeepsCauseWithoutInferringRelease(kind: String) throws {
        let source: FBSimulatorHIDInterruption
        switch kind {
        case "cancelled": source = .cancelled
        case "staleContext": source = .staleContext
        case "observationUnavailable": source = .observationUnavailable("native read failed")
        case "transportFailure": source = .transportFailure("send failed")
        case "invalidRetainedInput": source = .invalidRetainedInput("invalid input")
        default: source = .inputAdmissionRejected("context rejected")
        }
        let result = SelectedHomeResult.Interruption(source)
        let decoded = try JSONDecoder().decode(SelectedHomeResult.Interruption.self,
            from: JSONEncoder().encode(result))
        #expect(decoded.kind.rawValue == kind)
        switch kind {
        case "cancelled", "staleContext": #expect(decoded.detail == nil)
        case "observationUnavailable": #expect(decoded.detail == "native read failed")
        case "transportFailure": #expect(decoded.detail == "send failed")
        case "invalidRetainedInput": #expect(decoded.detail == "invalid input")
        default: #expect(decoded.detail == "context rejected")
        }
    }

    // This is a wire fixture, not native execution evidence. The library evidence
    // initializer is internal; native execution-to-result mapping needs main's proof.
    private struct HomeWireFixture: Encodable {
        let schemaVersion = 1
        let operationID = UUID()
        let simulatorUDID: String
        let axDisplayID: UInt32 = 3
        let boundContext: SelectedHIDContext
        let phase = "primitive"
        let plannedPrimitiveCount = 2
        let sentPrimitiveCount = 1
        let allInputsReleasedBeforeCleanup = false
        let drainCompleted = false
        let interruption = SelectedHomeResult.Interruption(FBSimulatorHIDInterruption.transportFailure("up failed"))
        let executionCleanup = "uncertain"
        let startedUptime = 1.0
        let finishedUptime = 2.0
        let cleanupEvidence: FBSimulatorHIDCleanupEvidence
    }

    @Test func partialHomeResponsePreservesFailureAndCleanupEvidence() throws {
        let cleanupJSON = """
        {"boundSimulatorUDID":"fixture","boundBootIdentity":"boot-one","boundScreenID":3,
         "boundScreenUUID":"00000000-0000-0000-0000-000000000003","boundNativeWidth":300,
         "boundNativeHeight":600,"boundScale":3,"boundRotation":90,"boundPoseRevision":"pose-one",
         "startedUptime":2,"trigger":"transportFailure","contextValidation":"unavailable",
         "releases":[{"index":0,"primitive":"Home up","startedUptime":2.1,
         "returnedSuccessfully":false,"errorDescription":"release failed"}],
         "timedOut":true,"outcome":"uncertain"}
        """
        let cleanup = try JSONDecoder().decode(FBSimulatorHIDCleanupEvidence.self, from: Data(cleanupJSON.utf8))
        let fixture = HomeWireFixture(simulatorUDID: udid,
            boundContext: SelectedHIDContext(try observation()), cleanupEvidence: cleanup)
        let home = try JSONDecoder().decode(SelectedHomeResult.self, from: JSONEncoder().encode(fixture))
        var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(),
            brokerID: UUID(), outcome: "failedNoReplay", token: nil, enqueuedEventCount: 1,
            cleanup: "uncertain", error: "up failed", context: nil)
        response.home = home
        let roundTrip = try JSONDecoder().decode(SelectedHIDResponse.self, from: JSONEncoder().encode(response))
        let result = try #require(roundTrip.home)
        #expect(roundTrip.outcome == "failedNoReplay" && roundTrip.enqueuedEventCount == 1)
        #expect(roundTrip.cleanup == "uncertain" && roundTrip.error == "up failed")
        #expect(result.schemaVersion == 1 && result.operationID == fixture.operationID)
        #expect(result.phase == "primitive" && result.plannedPrimitiveCount == 2 && result.sentPrimitiveCount == 1)
        #expect(!result.allInputsReleasedBeforeCleanup && !result.drainCompleted)
        #expect(result.interruption?.kind == .transportFailure && result.executionCleanup == "uncertain")
        #expect(result.cleanupEvidence == cleanup)
        #expect(result.cleanupEvidence?.releases.first?.returnedSuccessfully == false)
        #expect(result.cleanupEvidence?.timedOut == true)
        response.home = nil
        let noExecution = try JSONDecoder().decode(SelectedHIDResponse.self, from: JSONEncoder().encode(response))
        #expect(noExecution.home == nil)
    }
}
