import ArgumentParser
import Foundation

enum SimulatorInputMode: String, ExpressibleByArgument { case legacy, selected }

struct SelectedInputOptions: ParsableArguments {
    @Option(name: .customLong("input-mode"), help: "legacy preserves the existing route; selected uses an explicit display and owned HID session.")
    var mode: SimulatorInputMode = .legacy

    @Option(name: .customLong("screen-id"), help: "Selected input only: discovered simulator screen ID.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "Selected input only: discovered display UUID; no automatic retargeting.")
    var screenUUID: String?

    func validate() throws {
        if mode == .legacy {
            guard screenID == nil, screenUUID == nil else {
                throw ValidationError("Screen selection requires --input-mode selected.")
            }
            return
        }
        guard screenID != nil, let screenUUID, UUID(uuidString: screenUUID) != nil else {
            throw ValidationError("Selected input requires --screen-id and a valid --screen-uuid.")
        }
    }

    func request(operation: SelectedHIDRequest.Operation, token: UUID?, primitives: [SelectedHIDPrimitive]) throws -> SelectedHIDRequest {
        try validate()
        guard let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) else {
            throw ValidationError("Missing selected display")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: uuid, operation: operation, token: token, primitives: primitives)
        try request.validate()
        return request
    }
    func pathRequest(_ path: SelectedHIDPath) throws -> SelectedHIDRequest {
        try validate()
        guard let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) else {
            throw ValidationError("Missing selected display")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: uuid, operation: .complete, token: nil, primitives: [], path: path)
        try request.validate()
        return request
    }

    func pinchRequest(_ pinch: SelectedHIDPinch) throws -> SelectedHIDRequest {
        try validate()
        guard mode == .selected, let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) else {
            throw ValidationError("Pinch requires explicit selected input")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: uuid, operation: .complete, token: nil, primitives: [], pinch: pinch)
        try request.validate()
        return request
    }
    func gestureRequest(_ gesture: SelectedHIDCompleteGesture) throws -> SelectedHIDRequest {
        try validate()
        guard mode == .selected, let screenID, let screenUUID, let uuid = UUID(uuidString: screenUUID) else {
            throw ValidationError("Complete gestures require explicit selected input")
        }
        let request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: uuid, operation: .complete, token: nil, primitives: [], gesture: gesture)
        try request.validate()
        return request
    }
}
