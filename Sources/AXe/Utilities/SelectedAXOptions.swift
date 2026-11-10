import ArgumentParser
import Foundation
import FBSimulatorControl

enum SelectedSliderEndpoint: String, ExpressibleByArgument {
    case minimum, maximum
    var libraryValue: FBSimulatorSliderEndpoint { self == .minimum ? .minimum : .maximum }
}

struct SelectedAXOptions: ParsableArguments {
    @Option(name: .customLong("expected-pid"), help: "Selected or agent: require this frontmost app PID.")
    var expectedPID: Int32?

    /// `allowed` is true for a selected AX operation, where the PID is an optional guard.
    func validate(allowed: Bool) throws {
        if let expectedPID {
            guard allowed else { throw ValidationError("--expected-pid requires a selected AX operation.") }
            guard expectedPID > 0 else { throw ValidationError("--expected-pid must be a positive process ID.") }
        }
    }

    func request(input: SelectedInputOptions, kind: SelectedAXRequest.Kind,
                 selectorKind: SelectedAXRequest.SelectorKind? = nil, selectorValue: String? = nil,
                 endpoint: FBSimulatorSliderEndpoint? = nil, point: SelectedAXPoint? = nil, preDelay: Double = 0, postDelay: Double = 0,
                 elementType: String? = nil, tapStyle: SelectedTapStyle? = nil,
                 waitPolicy: SelectedAXWaitPolicy? = nil, percentage: Double? = nil) throws -> SelectedHIDRequest {
        try validate(allowed: true)
        try input.validate()
        guard input.mode == .selected else {
            throw ValidationError("Selected AX requires --input-mode selected.")
        }
        let ax = SelectedAXRequest(kind: kind, expectedPID: expectedPID,
            endpoint: endpoint,
            selectorKind: selectorKind, selectorValue: selectorValue, preDelay: preDelay, postDelay: postDelay, point: point,
            elementType: elementType, tapStyle: tapStyle, waitPolicy: waitPolicy, percentage: percentage)
        let request = try input.baseRequest(payload: .ax(ax))
        try request.validate()
        return request
    }
}
