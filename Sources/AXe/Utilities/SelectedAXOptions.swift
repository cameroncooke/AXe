import ArgumentParser
import Foundation
import FBSimulatorControl

extension SelectedAXPreparation: ExpressibleByArgument {}
enum SelectedSliderEndpoint: String, ExpressibleByArgument {
    case minimum, maximum
    var libraryValue: FBSimulatorSliderEndpoint { self == .minimum ? .minimum : .maximum }
}

struct SelectedAXOptions: ParsableArguments {
    @Option(name: .customLong("expected-pid"), help: "Selected AX only: require this frontmost application process ID.")
    var expectedPID: Int32?

    @Option(name: .customLong("ax-preparation"), help: "Selected AX only: automation-session (default) or existing-bridge. No fallback.")
    var preparation: SelectedAXPreparation?

    func validate(required: Bool) throws {
        if required {
            guard let expectedPID, expectedPID > 0 else { throw ValidationError("Selected AX requires a positive --expected-pid.") }
        } else if expectedPID != nil || preparation != nil {
            throw ValidationError("--expected-pid and --ax-preparation require a selected AX operation.")
        }
    }

    func request(input: SelectedInputOptions, kind: SelectedAXRequest.Kind,
                 selectorKind: SelectedAXRequest.SelectorKind? = nil, selectorValue: String? = nil,
                 endpoint: FBSimulatorSliderEndpoint? = nil, point: SelectedAXPoint? = nil, preDelay: Double = 0, postDelay: Double = 0,
                 elementType: String? = nil, tapStyle: SelectedTapStyle? = nil,
                 waitPolicy: SelectedAXWaitPolicy? = nil, percentage: Double? = nil) throws -> SelectedHIDRequest {
        try validate(required: true)
        try input.validate()
        guard input.mode == .selected, let expectedPID, let screenID = input.screenID,
              let rawUUID = input.screenUUID, let screenUUID = UUID(uuidString: rawUUID) else {
            throw ValidationError("Missing selected AX display or process identity.")
        }
        let ax = SelectedAXRequest(kind: kind, expectedPID: expectedPID,
            preparation: preparation ?? .automationSession, endpoint: endpoint,
            selectorKind: selectorKind, selectorValue: selectorValue, preDelay: preDelay, postDelay: postDelay, point: point,
            elementType: elementType, tapStyle: tapStyle, waitPolicy: waitPolicy, percentage: percentage)
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: screenUUID, operation: .complete, token: nil, primitives: [], ax: ax)
        try request.validate()
        return request
    }
}
