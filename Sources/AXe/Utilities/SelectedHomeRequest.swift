import Foundation
import FBSimulatorControl

/// Hardware buttons act on the device. The selected panel binds admission, not routing.
private enum SelectedButtonPolicy {
    static func validate(duration: Double?, expectedBoot: String?, name: String) throws {
        if let duration {
            guard duration.isFinite, duration > 0, duration <= 10 else {
                throw SelectedHIDFailure.invalid("Selected \(name) duration must be finite, greater than zero and at most 10 seconds")
            }
        }
        if let expectedBoot {
            guard !expectedBoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SelectedHIDFailure.invalid("Expected boot identity must not be empty")
            }
        }
    }

    static func validate(duration: Double?, expectedBoot: String?, name: String,
                         observation: FBSimulatorHIDSessionObservation) throws {
        try validate(duration: duration, expectedBoot: expectedBoot, name: name)
        if let expectedBoot, expectedBoot != observation.bootIdentity {
            throw SelectedHIDFailure.invalid("Selected \(name) boot identity differs; no input")
        }
    }

    static func event(_ button: FBSimulatorHIDButton, duration: Double?) -> FBSimulatorHIDEvent {
        guard let duration else { return .shortButtonPress(button) }
        return .composite([.button(direction: .down, button: button),
                           .delay(duration), .button(direction: .up, button: button)])
    }
}

struct SelectedHomeRequest: Codable, Sendable {
    let duration: Double?
    let expectedBoot: String?

    func validate() throws {
        try SelectedButtonPolicy.validate(duration: duration, expectedBoot: expectedBoot, name: "Home")
    }

    func validate(observation: FBSimulatorHIDSessionObservation) throws {
        try SelectedButtonPolicy.validate(duration: duration, expectedBoot: expectedBoot, name: "Home", observation: observation)
    }

    func event(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        try validate(observation: observation)
        return SelectedButtonPolicy.event(.homeButton, duration: duration)
    }
}

struct SelectedButtonRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case sideButton = "side-button" }
    let kind: Kind
    let duration: Double?
    let expectedBoot: String?

    func validate() throws {
        try SelectedButtonPolicy.validate(duration: duration, expectedBoot: expectedBoot, name: kind.rawValue)
    }

    func validate(observation: FBSimulatorHIDSessionObservation) throws {
        try SelectedButtonPolicy.validate(duration: duration, expectedBoot: expectedBoot, name: kind.rawValue, observation: observation)
    }

    func event(observation: FBSimulatorHIDSessionObservation) throws -> FBSimulatorHIDEvent {
        try validate(observation: observation)
        switch kind {
        case .sideButton: return SelectedButtonPolicy.event(.sideButton, duration: duration)
        }
    }
}

struct SelectedButtonResult: Codable, Sendable {
    let kind: SelectedButtonRequest.Kind
    let execution: SelectedButtonExecutionEvidence
}

// Keep the existing Home source name and encoded fields.
typealias SelectedHomeResult = SelectedButtonExecutionEvidence

/// Available session evidence only. This is not an OS held-button inventory or a UI effect.
struct SelectedButtonExecutionEvidence: Codable, Sendable {
    struct Interruption: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case cancelled, staleContext, observationUnavailable, transportFailure
            case invalidRetainedInput, inputAdmissionRejected
        }
        let kind: Kind
        let detail: String?
        init(_ source: FBSimulatorHIDInterruption) {
            switch source {
            case .cancelled: kind = .cancelled; detail = nil
            case .staleContext: kind = .staleContext; detail = nil
            case .observationUnavailable(let value): kind = .observationUnavailable; detail = value
            case .transportFailure(let value): kind = .transportFailure; detail = value
            case .invalidRetainedInput(let value): kind = .invalidRetainedInput; detail = value
            case .inputAdmissionRejected(let value): kind = .inputAdmissionRejected; detail = value
            }
        }
    }
    let schemaVersion: Int
    let operationID: UUID
    let simulatorUDID: String
    let axDisplayID: UInt32
    let boundContext: SelectedHIDContext
    let phase: String
    let plannedPrimitiveCount: Int
    let sentPrimitiveCount: Int
    let allInputsReleasedBeforeCleanup: Bool
    let drainCompleted: Bool
    let interruption: Interruption?
    let executionCleanup: String
    let startedUptime: Double
    let finishedUptime: Double
    let cleanupEvidence: FBSimulatorHIDCleanupEvidence?

    init(execution: FBSimulatorHIDExecutionEvidence, cleanup: FBSimulatorHIDCleanupEvidence?) {
        schemaVersion = 1
        operationID = execution.operationID
        simulatorUDID = execution.boundObservation.simulatorUDID
        axDisplayID = execution.boundObservation.axDisplayID
        boundContext = SelectedHIDContext(execution.boundObservation)
        phase = execution.phase.rawValue
        plannedPrimitiveCount = execution.plannedPrimitiveCount
        sentPrimitiveCount = execution.sentPrimitiveCount
        allInputsReleasedBeforeCleanup = execution.allInputsReleasedBeforeCleanup
        drainCompleted = execution.drainCompleted
        interruption = execution.interruption.map(Interruption.init)
        executionCleanup = execution.cleanup.rawValue
        startedUptime = execution.startedUptime
        finishedUptime = execution.finishedUptime
        cleanupEvidence = cleanup
    }
}
