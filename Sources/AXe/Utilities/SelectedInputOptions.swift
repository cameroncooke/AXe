import ArgumentParser
import Foundation

enum SimulatorInputMode: String, ExpressibleByArgument { case legacy, selected }

struct SelectedInputOptions: ParsableArguments {
    @Option(name: .customLong("input-mode"), help: "Input route: legacy, or selected to bind one screen and check the target before input.")
    var mode: SimulatorInputMode = .legacy

    @Option(name: .customLong("screen-id"), help: "Selected input: refuse unless this screen is active.")
    var screenID: UInt32?

    @Option(name: .customLong("screen-uuid"), help: "Selected input: that screen's UUID from axe displays; pass both.")
    var screenUUID: String?

    func validate() throws {
        if mode == .legacy {
            guard screenID == nil, screenUUID == nil else {
                throw ValidationError("Screen selection requires --input-mode selected.")
            }
            return
        }
        guard (screenID == nil) == (screenUUID == nil) else {
            throw ValidationError("Pass both --screen-id and --screen-uuid, or neither to use the active screen.")
        }
        if let screenUUID, UUID(uuidString: screenUUID) == nil {
            throw ValidationError("--screen-uuid must be a display UUID.")
        }
    }

    /// The unvalidated request: the caller attaches its payload and validates the result.
    /// Without an explicit pair the broker binds the screen that is active when it admits the request.
    func baseRequest(operation: SelectedHIDRequest.Operation, token: UUID?,
                     primitives: [SelectedHIDPrimitive]) throws -> SelectedHIDRequest {
        try validate()
        guard mode == .selected else { throw ValidationError("Selected input requires --input-mode selected.") }
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: screenUUID.flatMap(UUID.init(uuidString:)),
            operation: operation, token: token, primitives: primitives)
        if screenID == nil { request.activeDisplay = true }
        return request
    }

    func request(operation: SelectedHIDRequest.Operation, token: UUID?, primitives: [SelectedHIDPrimitive]) throws -> SelectedHIDRequest {
        let request = try baseRequest(operation: operation, token: token, primitives: primitives)
        try request.validate()
        return request
    }

    func pathRequest(_ path: SelectedHIDPath) throws -> SelectedHIDRequest {
        var request = try baseRequest(operation: .complete, token: nil, primitives: [])
        request.path = path
        try request.validate()
        return request
    }

    func pinchRequest(_ pinch: SelectedHIDPinch) throws -> SelectedHIDRequest {
        var request = try baseRequest(operation: .complete, token: nil, primitives: [])
        request.pinch = pinch
        try request.validate()
        return request
    }

    func gestureRequest(_ gesture: SelectedHIDCompleteGesture) throws -> SelectedHIDRequest {
        var request = try baseRequest(operation: .complete, token: nil, primitives: [])
        request.gesture = gesture
        try request.validate()
        return request
    }
}
