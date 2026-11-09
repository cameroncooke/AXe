import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Hinge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read or set the iPhone Duo hinge angle.",
        subcommands: [Read.self, Set.self])

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the hinge angle iOS senses and the posture: closed, partially open or open.")
        @Option(name: .customLong("udid"), help: "Simulator UDID.") var simulatorUDID: String
        @Option(name: .customLong("expected-boot"),
            help: ArgumentHelp("Refuse unless the simulator boot identity is PID:SECONDS:MICROSECONDS.", visibility: .hidden))
        var expectedBoot: String?
        @Flag(name: .customLong("verbose"), help: "Print the full broker reply as JSON: samples, capability and boot identity.")
        var verbose = false

        func validate() throws {
            if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
            try request().validate()
        }
        func request() throws -> SelectedHingeRequest {
            guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
            return SelectedHingeRequest(kind: .read, expectedBootIdentity: expectedBoot,
                degrees: nil, toleranceDegrees: nil, timeoutSeconds: nil)
        }
        func run() async throws {
            try AutomationTarget.refuseOnDevice(simulatorUDID, "The hinge is available on iPhone Duo simulators only.")
            let response = try SelectedHIDBroker.send(try request().brokerRequest(), simulatorUDID: simulatorUDID)
            try Self.report(response, udid: simulatorUDID, verbose: verbose)
        }

        /// `verbose` prints the receipt in place of the result; the checks and codes are the same.
        static func report(_ response: SelectedHIDResponse, udid: String, verbose: Bool) throws {
            if verbose { try SelectedHIDBroker.writeReceipt(response) }
            guard response.error == nil, let sample = response.hinge?.readback?.sample else {
                throw DeviceStateFailure.hinge(response)
            }
            guard !verbose else { return }
            let output = HingeReadOutput(udid: udid, hinge: HingeStateOutput(sample))
            try DeviceState.emit(output, text: ["Hinge \(output.hinge.text)"])
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move the hinge, wait for the screens to settle, and show the new angle and active screen.",
            discussion: "Sends one request and never repeats it. The command pins the simulator boot it reads when it starts and fails if the simulator restarts before the hinge reaches the angle.")
        @Argument(
            help: "Angle in degrees (0...180), or closed (0), tabletop (90), open (180). Names are case-sensitive.",
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
        @Option(name: .customLong("expected-boot"),
            help: ArgumentHelp("Refuse unless the simulator boot identity is PID:SECONDS:MICROSECONDS.", visibility: .hidden))
        var expectedBoot: String?
        @Option(name: .customLong("tolerance"), help: "Mechanical match tolerance in degrees, 0...1.") var tolerance: Double = 0.5
        @Option(name: .customLong("timeout"), help: "Seconds to wait for the hinge to reach the angle, 0.5...15.") var timeout: Double = 8
        @Flag(name: .customLong("no-wait"), help: "Return when the hinge reaches the angle, without waiting for the screens to settle.")
        var noWait = false
        @Option(name: .customLong("wait-for-screen-id"),
            help: ArgumentHelp("Wait until this screen ID is active after the move; requires its UUID.", visibility: .hidden))
        var waitForScreenID: UInt32?
        @Option(name: .customLong("wait-for-screen-uuid"),
            help: ArgumentHelp("Wait until this screen UUID is active after the move; requires its ID.", visibility: .hidden),
            transform: { text in
                guard let value = UUID(uuidString: text) else {
                    throw ValidationError("Invalid expected display UUID")
                }
                return value
            }) var waitForScreenUUID: UUID?
        @Option(name: .customLong("readiness-timeout"),
            help: ArgumentHelp("Seconds to wait for the expected screen, 0.5...15 (default 8); requires both wait-for options.", visibility: .hidden))
        var readinessTimeout: Double?
        @Flag(name: .customLong("verbose"), help: "Print the full broker reply as JSON: receipts, samples and boot identity.")
        var verbose = false

        func validate() throws {
            if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
            try request(bootIdentity: expectedBoot).validate()
            if noWait, waitForScreenID != nil {
                throw ValidationError("--no-wait cannot be combined with --wait-for-screen-id")
            }
        }
        func request(bootIdentity: String?) throws -> SelectedHingeRequest {
            guard UUID(uuidString: simulatorUDID) != nil else { throw ValidationError("Invalid simulator UDID") }
            let readiness: FBSimulatorHingeReadinessRequest?
            if let screenID = waitForScreenID, let screenUUID = waitForScreenUUID {
                readiness = try FBSimulatorHingeReadinessRequest(screenID: screenID, screenUUID: screenUUID,
                    timeoutSeconds: readinessTimeout ?? DisplayTransition.settleBudgetSeconds)
            } else {
                guard waitForScreenID == nil, waitForScreenUUID == nil, readinessTimeout == nil else {
                    throw ValidationError("Both wait-for-screen-id and wait-for-screen-uuid are required for readiness")
                }
                readiness = nil
            }
            return SelectedHingeRequest(kind: .set, expectedBootIdentity: bootIdentity,
                degrees: degrees, toleranceDegrees: tolerance, timeoutSeconds: timeout, readiness: readiness)
        }
        func run() async throws {
            try AutomationTarget.refuseOnDevice(simulatorUDID, "The hinge is available on iPhone Duo simulators only.")
            let boot = try expectedBoot ?? DeviceState.currentBootIdentity(udid: simulatorUDID)
            let response = try SelectedHIDBroker.send(try request(bootIdentity: boot).brokerRequest(),
                simulatorUDID: simulatorUDID)
            let receipt = try Self.receipt(from: response, verbose: verbose)
            let previous = DeviceStateText.rounded(receipt.before.sensedDegrees)
            guard !noWait else {
                if verbose { return }
                let hinge = HingeStateOutput(receipt.matchingSamples.last ?? receipt.before)
                let output = HingeSetOutput(udid: simulatorUDID, previousDegrees: previous, hinge: hinge, activeScreen: nil)
                try DeviceState.emit(output, text: output.textLines)
                return
            }
            let simulator = try await DeviceState.bootedSimulator(udid: simulatorUDID, logger: AxeLogger())
            let (discovery, displays) = try await DeviceState.displays(for: simulator)
            guard discovery.bootIdentity == boot else {
                throw CLIOutputFailure(code: "bootChanged",
                    message: "The simulator restarted after the hinge moved. Read its state again.")
            }
            if verbose { return }
            let hinge = displays.hinge ?? HingeStateOutput(receipt.matchingSamples.last ?? receipt.before)
            let output = HingeSetOutput(udid: simulatorUDID, previousDegrees: previous, hinge: hinge,
                activeScreen: displays.activeScreen)
            try DeviceState.emit(output, text: output.textLines)
        }

        /// `verbose` prints the receipt; the checks and codes are the same with or without it.
        static func receipt(from response: SelectedHIDResponse, verbose: Bool) throws -> FBSimulatorHingeReceipt {
            if verbose { try SelectedHIDBroker.writeReceipt(response) }
            guard response.error == nil, let receipt = response.hinge?.receipt else {
                throw DeviceStateFailure.hinge(response)
            }
            return receipt
        }
    }
}

struct HingeReadOutput: Encodable {
    let udid: String
    let hinge: HingeStateOutput

    private enum CodingKeys: String, CodingKey { case udid, degrees, mechanicalDegrees, posture }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(udid, forKey: .udid)
        try values.encode(hinge.degrees, forKey: .degrees)
        try values.encode(hinge.mechanicalDegrees, forKey: .mechanicalDegrees)
        try values.encode(hinge.posture, forKey: .posture)
    }
}

struct HingeSetOutput: Encodable {
    let udid: String
    let previousDegrees: Double
    let hinge: HingeStateOutput
    let activeScreen: ScreenStateOutput?

    var textLines: [String] {
        var lines = ["Hinge \(hinge.text) (was \(DeviceStateText.degrees(previousDegrees)))"]
        if let activeScreen { lines += DeviceStateText.screenLines(activeScreen, active: true) }
        return lines
    }

    private enum CodingKeys: String, CodingKey {
        case udid, previousDegrees, degrees, mechanicalDegrees, posture, activeScreen
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(udid, forKey: .udid)
        try values.encode(previousDegrees, forKey: .previousDegrees)
        try values.encode(hinge.degrees, forKey: .degrees)
        try values.encode(hinge.mechanicalDegrees, forKey: .mechanicalDegrees)
        try values.encode(hinge.posture, forKey: .posture)
        try values.encodeIfPresent(activeScreen, forKey: .activeScreen)
    }
}
