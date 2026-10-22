import ArgumentParser
import Foundation
import FBSimulatorControl

struct Hinge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read or set the verified simulator hinge. Mechanical completion does not select an active screen.",
        subcommands: [Read.self, Set.self])

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read native mechanical and sensed angles, range, capability and boot identity.")
        @Option(name: .customLong("udid"), help: "Simulator UDID.") var simulatorUDID: String
        @Option(name: .customLong("expected-boot"), help: "Optional observed PID:SECONDS:MICROSECONDS boot identity.") var expectedBoot: String?
        func validate() throws { try request().validate() }
        func request() throws -> SelectedHingeRequest {
            guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
            return SelectedHingeRequest(kind: .read, expectedBootIdentity: expectedBoot,
                degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil)
        }
        func run() async throws {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(try request().brokerRequest(), simulatorUDID: simulatorUDID))
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send one hinge request and observe mechanical completion. Optionally observe active-display coherence. No replay.")
        @Argument(
            help: "Requested mechanical angle in degrees (0...180), or closed (0), tabletop (90), open (180). Names are case-sensitive.",
            transform: { text in
                switch text {
                case "closed": return 0
                case "tabletop": return 90
                case "open": return 180
                default:
                    guard let degrees = Double(text) else {
                        throw ValidationError("Expected an angle in degrees or one of: closed, tabletop, open")
                    }
                    return degrees
                }
            }) var degrees: Double
        @Option(name: .customLong("udid"), help: "Simulator UDID.") var simulatorUDID: String
        @Option(name: .customLong("expected-boot"), help: "Required boot identity from a fresh hinge read: PID:SECONDS:MICROSECONDS.") var expectedBoot: String
        @Option(name: .customLong("tolerance"), help: "Mechanical match tolerance in degrees, 0...1.") var tolerance: Double = 0.5
        @Option(name: .customLong("timeout"), help: "Set/readback policy timeout in seconds, 0.5...15; setup and blocking native calls are separate.") var timeout: Double = 8
        @Option(name: .customLong("wait-for-screen-id"), help: "Expected active display ID after mechanical completion; requires its UUID.") var waitForScreenID: UInt32?
        @Option(name: .customLong("wait-for-screen-uuid"),
            help: "Expected active display UUID; requires its ID. This does not authorize input.",
            transform: { text in
                guard let value = UUID(uuidString: text) else {
                    throw ValidationError("Invalid expected display UUID")
                }
                return value
            }) var waitForScreenUUID: UUID?
        @Option(name: .customLong("readiness-timeout"), help: "Optional display coherence budget, 0.5...15 seconds (default 8); requires both wait-for options.") var readinessTimeout: Double?
        func validate() throws { try request().validate() }
        func request() throws -> SelectedHingeRequest {
            guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
            let readiness: FBSimulatorHingeReadinessRequest?
            if let screenID = waitForScreenID, let screenUUID = waitForScreenUUID {
                readiness = try FBSimulatorHingeReadinessRequest(screenID: screenID, screenUUID: screenUUID,
                    timeoutSeconds: readinessTimeout ?? 8)
            } else {
                guard waitForScreenID == nil, waitForScreenUUID == nil, readinessTimeout == nil else {
                    throw ValidationError("Both wait-for-screen-id and wait-for-screen-uuid are required for readiness")
                }
                readiness = nil
            }
            return SelectedHingeRequest(kind: .set, expectedBootIdentity: expectedBoot,
                degrees: degrees, toleranceDegrees: tolerance, timeoutSeconds: timeout, readiness: readiness)
        }
        func run() async throws {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(try request().brokerRequest(), simulatorUDID: simulatorUDID))
        }
    }
}
