import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Selected healthy transport routes")
@MainActor
struct SelectedHealthyTransportRouteTests {
    private let udid = "00000000-0000-0000-0000-000000000001"
    private let screen = "00000000-0000-0000-0000-000000000003"
    private var selection: [String] {
        ["--input-mode", "selected", "--screen-id", "3", "--screen-uuid", screen]
    }

    @Test(arguments: [false, true])
    func physicalCoordinateTapUsesCompleteAdmission(withDelays: Bool) throws {
        var arguments = ["-x", "104.5", "-y", "170", "--tap-style", "physical"]
        if withDelays { arguments += ["--pre-delay", "0.2", "--post-delay", "0.3"] }
        let command = try Tap.parse(arguments + ["--udid", udid] + selection)
        let direct = try command.selectedRequest()
        let batch = try SelectedBatchStep.request(["tap"] + arguments,
            input: SelectedInputOptions.parse(selection), simulatorUDID: udid)
        for request in [direct, batch] {
            try requireCompleteAdmission(request)
            #expect(request.ax == nil && request.path == nil && request.gesture == nil)
            #expect(request.primitives.first(where: { $0.kind == .down })?.x == 104.5)
            #expect(request.primitives.first(where: { $0.kind == .down })?.y == 170)
        }
    }

    @Test(arguments: [false, true])
    func readOnlyCaptureHasNoInputPayload(atPoint: Bool) throws {
        let options = atPoint ? ["--point", "104.5,170"] : []
        let command = try DescribeUI.parse(options + ["--expected-pid", "42", "--udid", udid] + selection)
        let request = try command.selectedRequest()
        try requireCompleteAdmission(request)
        #expect(request.ax?.kind == (atPoint ? .describePoint : .describe))
        #expect(request.primitives.isEmpty && request.path == nil && request.gesture == nil)
    }

    @Test func semanticAndEndpointActionsKeepTheirAXPayloads() throws {
        let semantic = try Tap.parse(["--semantic-press", "--id", "switch", "--expected-pid", "42",
            "--udid", udid] + selection).selectedRequest()
        let slider = try Slider.parse(["--id", "slider", "--endpoint", "maximum", "--expected-pid", "42",
            "--udid", udid] + selection).selectedRequest()
        for request in [semantic, slider] {
            try requireCompleteAdmission(request)
            #expect(request.ax != nil && request.primitives.isEmpty)
            #expect(request.path == nil && request.gesture == nil)
        }
    }

    @Test(arguments: ["begin", "move", "end"])
    func retainedTouchKeepsTokenAndRejectsCompetingInput(operation: String) throws {
        let token = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000007"))
        let begin = try Touch.parse(["-x", "104.5", "-y", "170", "--down", "--udid", udid] + selection).selectedRequest()
        var arguments = ["-x", "104.5", "-y", "170", operation == "end" ? "--up" : "--down"]
        if operation != "begin" { arguments += ["--contact-token", token.uuidString] }
        let request = try Touch.parse(arguments + ["--udid", udid] + selection).selectedRequest()
        try request.validate()
        #expect(request.operation.rawValue == operation)
        var admission = SelectedHIDAdmission()
        try admission.enter(begin)
        admission.retain(begin, token: token)
        admission.finish()
        if operation != "begin" {
            try admission.enter(request)
            #expect(admission.inFlight && request.token == token)
            admission.finish()
        }
        let complete = try Tap.parse(["-x", "104.5", "-y", "170", "--tap-style", "physical", "--udid", udid]
            + selection).selectedRequest()
        try requireBusy(complete, admission: &admission)
        #expect(admission.token == token && admission.screenID == 3)
        #expect(admission.screenUUID == UUID(uuidString: screen) && !admission.inFlight)
        // The owner clears admission only when its retained session closes.
        admission.clear()
        try admission.enter(complete)
        #expect(admission.inFlight && admission.token == nil)
    }

    @Test func coordinateDragUsesCompletePathAdmission() throws {
        let command = try Drag.parse(["--start-x", "104.5", "--start-y", "170",
            "--end-x", "160", "--end-y", "240", "--udid", udid] + selection)
        let request = try command.selectedRequest()
        try requireCompleteAdmission(request)
        #expect(request.path != nil && request.gesture == nil && request.ax == nil)
        #expect(request.primitives.isEmpty)
    }

    @Test(arguments: ["two-finger-tap", "two-finger-hold"])
    func pairedContactUsesCompleteGestureAdmission(name: String) throws {
        var arguments = [name, "-x", "100", "-y", "170", "--x2", "150", "--y2", "170"]
        if name == "two-finger-hold" { arguments += ["--hold", "0.8"] }
        let command = try Gesture.parse(arguments + ["--udid", udid] + selection)
        let request = try command.selectedInput.gestureRequest(command.selectedCompleteGesture())
        try requireCompleteAdmission(request)
        #expect(request.gesture != nil && request.path == nil && request.ax == nil)
        #expect(request.primitives.isEmpty)
    }

    private func requireCompleteAdmission(_ request: SelectedHIDRequest) throws {
        try request.validate()
        #expect(request.operation == .complete && request.token == nil)
        #expect(request.screenID == 3 && request.screenUUID == UUID(uuidString: screen))
        var admission = SelectedHIDAdmission()
        try admission.enter(request)
        #expect(admission.inFlight && admission.token == nil)
        try requireBusy(request, admission: &admission)
        admission.finish()
        #expect(!admission.inFlight && admission.token == nil)
        try admission.enter(request)
        admission.finish()
    }

    private func requireBusy(_ request: SelectedHIDRequest, admission: inout SelectedHIDAdmission) throws {
        do {
            try admission.enter(request)
            throw TestError.unexpectedState("Competing input was admitted while the owner was busy.")
        } catch SelectedHIDFailure.busy {}
    }
}
