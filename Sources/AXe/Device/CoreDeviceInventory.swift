import Darwin
import Foundation

struct CoreDevice: Sendable {
    let identifier: String
    let udid: String?
    let name: String?
    let model: String?
    let osVersion: String?
    let tunnelAddress: String?
    let tunnelConnected: Bool?
    let transport: String?
    let paired: Bool?
    let developerModeEnabled: Bool?
    let developerDiskImageMounted: Bool?
    let coreDeviceVersion: String?

    func matches(_ target: String) -> Bool {
        identifier.caseInsensitiveCompare(target) == .orderedSame
            || udid?.caseInsensitiveCompare(target) == .orderedSame
    }
}

/// A failure devicectl reported: its error codes from outermost to innermost and the innermost
/// localized description.
struct CoreDeviceFailure: Error, Sendable, Equatable {
    let codes: [Int]
    let message: String
}

enum CoreDeviceInventory {
    static func list() async throws -> [CoreDevice] {
        physicalDevices(try await query(["list", "devices"]))
    }

    private static func physicalDevices(_ response: Response<Inventory>) -> [CoreDevice] {
        response.result.devices
            .filter(\.isPhysicalMobileDevice)
            .map { $0.device(coreDeviceVersion: response.coreDeviceVersion) }
    }

    static func details(for device: CoreDevice) async throws -> CoreDevice {
        let response: Response<DeviceRecord> = try await query([
            "device", "info", "details", "--device", device.identifier
        ])
        let details = response.result.device(coreDeviceVersion: response.coreDeviceVersion)
        guard details.identifier.caseInsensitiveCompare(device.identifier) == .orderedSame else {
            throw CLIError(errorDescription: "CoreDevice returned details for a different device.")
        }
        if let expectedUDID = device.udid, let actualUDID = details.udid,
           expectedUDID.caseInsensitiveCompare(actualUDID) != .orderedSame {
            throw CLIError(errorDescription: "CoreDevice returned details with a different hardware UDID.")
        }
        return details
    }

    static func lockState(for device: CoreDevice) async throws -> Bool? {
        let response: Response<LockState> = try await query([
            "device", "info", "lockState", "--device", device.identifier
        ])
        let state = response.result
        guard state.deviceIdentifier.caseInsensitiveCompare(device.identifier) == .orderedSame else {
            throw CLIError(errorDescription: "CoreDevice returned lock state for a different device.")
        }
        // These fields describe passcode access and the first unlock after boot.
        if state.unlockedSinceBoot == false { return true }
        return state.passcodeRequired
    }

    private static func query<Result: Decodable>(_ arguments: [String]) async throws -> Response<Result> {
        let operation = arguments.prefix(3).joined(separator: " ")
        guard let data = try await run(arguments).json else {
            throw CLIError(errorDescription: "devicectl \(operation) returned no JSON. Check the selected Xcode installation.")
        }
        return try decode(data.contents, operation: operation, succeeded: data.succeeded)
    }

    /// Runs one devicectl command and reads its JSON file output. `json` is nil when devicectl wrote
    /// no file, which is how it reports a usage error (exit status 64) such as an unknown subcommand.
    static func run(_ arguments: [String]) async throws -> (json: (contents: Data, succeeded: Bool)?, exitStatus: Int32) {
        try Task.checkCancellation()
        let operation = arguments.prefix(3).joined(separator: " ")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-coredevice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("result.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl"] + arguments + ["-q", "--timeout", "10", "-j", jsonURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exitEvents, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { _ in
            continuation.yield(())
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            throw CLIError(errorDescription: "Could not start xcrun devicectl. Select Xcode with xcode-select.")
        }
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exitEvents { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(12))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        if !exited, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            // Give Foundation time to reap the child, even after task cancellation.
            await Task.detached {
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(1)
                while process.isRunning, clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }.value
        }
        try Task.checkCancellation()
        guard exited else {
            if process.isRunning {
                throw CLIError(errorDescription: "CoreDevice timed out during \(operation). devicectl did not exit.")
            }
            throw CLIError(errorDescription: "CoreDevice timed out during \(operation).")
        }

        let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
        guard let data = try? Data(contentsOf: jsonURL) else { return (nil, process.terminationStatus) }
        return ((data, succeeded), process.terminationStatus)
    }

    private static func decode<Result: Decodable>(_ data: Data, operation: String,
                                                  succeeded: Bool) throws -> Response<Result> {
        let envelope: Envelope<Result>
        do {
            envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
        } catch {
            throw CLIError(errorDescription: "devicectl \(operation) returned an unrecognized JSON response.")
        }
        guard succeeded, let result = envelope.result else {
            let detail = envelope.error?.userInfo?.localizedDescription?.string ?? "The operation failed."
            throw CLIError(errorDescription: "devicectl \(operation): \(detail)")
        }
        return Response(result: result, coreDeviceVersion: envelope.info?.version)
    }

    /// Decodes a devicectl JSON file: the result when the command succeeded, otherwise the failure it
    /// reported as a `CoreDeviceFailure`.
    static func result<Result: Decodable>(fromJSON data: Data, succeeded: Bool, operation: String) throws -> Result {
        let envelope: Envelope<Result>
        do {
            envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
        } catch {
            throw CLIError(errorDescription: "devicectl \(operation) returned an unrecognized JSON response.")
        }
        if succeeded, let result = envelope.result { return result }
        throw CoreDeviceFailure(codes: envelope.error?.codes ?? [],
            message: envelope.error?.innermostDescription ?? "devicectl \(operation) failed.")
    }

    /// Decodes saved `devicectl list devices` JSON the same way as `list()`.
    static func devices(fromListJSON data: Data) throws -> [CoreDevice] {
        physicalDevices(try decode(data, operation: "list devices", succeeded: true))
    }

    /// Decodes saved `devicectl device info details` JSON the same way as `details(for:)`.
    static func device(fromDetailsJSON data: Data) throws -> CoreDevice {
        let response: Response<DeviceRecord> = try decode(data, operation: "device info details", succeeded: true)
        return response.result.device(coreDeviceVersion: response.coreDeviceVersion)
    }

    private struct Response<Result> {
        let result: Result
        let coreDeviceVersion: String?
    }
}

private struct Envelope<Result: Decodable>: Decodable {
    let info: Info?
    let result: Result?
    let error: Failure?

    struct Info: Decodable {
        let version: String?
    }

    /// A class, because each error can carry its underlying error.
    final class Failure: Decodable {
        let code: Int?
        let userInfo: UserInfo?

        /// Error codes from this error to the innermost underlying one.
        var codes: [Int] { (code.map { [$0] } ?? []) + (userInfo?.underlying?.error.codes ?? []) }

        /// The innermost localized description.
        var innermostDescription: String? {
            userInfo?.underlying?.error.innermostDescription ?? userInfo?.localizedDescription?.string
        }

        struct UserInfo: Decodable {
            let localizedDescription: DescriptionValue?
            let underlying: Underlying?

            enum CodingKeys: String, CodingKey {
                case localizedDescription = "NSLocalizedDescription"
                case underlying = "NSUnderlyingError"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                localizedDescription = try? values.decodeIfPresent(DescriptionValue.self, forKey: .localizedDescription)
                // An underlying error AXe cannot read must not hide the outer description.
                underlying = try? values.decodeIfPresent(Underlying.self, forKey: .underlying)
            }
        }

        struct Underlying: Decodable {
            let error: Failure
        }

        struct DescriptionValue: Decodable {
            let string: String?
        }
    }
}

private struct Inventory: Decodable {
    let devices: [DeviceRecord]
}

private struct LockState: Decodable {
    let deviceIdentifier: String
    let passcodeRequired: Bool?
    let unlockedSinceBoot: Bool?
}

private struct DeviceRecord: Decodable {
    let identifier: String
    let visibilityClass: String?
    let properties: Properties?
    let hardwareProperties: Hardware?
    let deviceProperties: LegacyDeviceProperties?
    let connectionProperties: Connection?

    private var hardware: Hardware? { properties?.hardware ?? hardwareProperties }
    private var transport: String? { properties?.connection?.transportType ?? connectionProperties?.transportType }

    var isPhysicalMobileDevice: Bool {
        let fidelity = hardware?.fidelity ?? hardware?.reality
        guard fidelity != "simulated", visibilityClass != "simulators", transport != "sameMachine" else {
            return false
        }
        if let family = hardware?.productFamily ?? hardware?.deviceType {
            return family == "iPhone" || family == "iPad"
        }
        guard let product = hardware?.productType else { return false }
        return product.hasPrefix("iPhone") || product.hasPrefix("iPad")
    }

    func device(coreDeviceVersion: String?) -> CoreDevice {
        let connection = properties?.connection
        let state = properties?.state
        let tunnelAddress = connection?.tunnelIPAddressString ?? connectionProperties?.tunnelIPAddress
        let tunnelState = connection?.state ?? connectionProperties?.tunnelState
        let pairingState = connection?.pairingState ?? connectionProperties?.pairingState

        let tunnelConnected: Bool?
        switch tunnelState {
        case "connected": tunnelConnected = true
        case "disconnected": tunnelConnected = false
        default: tunnelConnected = tunnelAddress == nil ? nil : true
        }

        let paired: Bool?
        switch pairingState {
        case "paired": paired = true
        case "unpaired": paired = false
        default: paired = nil
        }

        return CoreDevice(
            identifier: identifier,
            udid: hardware?.udid,
            name: state?.name ?? deviceProperties?.name,
            model: hardware?.marketingName ?? hardware?.productType,
            osVersion: properties?.software?.osVersionNumber?.stringValue ?? deviceProperties?.osVersionNumber,
            tunnelAddress: tunnelAddress,
            tunnelConnected: tunnelConnected,
            transport: transport,
            paired: paired,
            developerModeEnabled: state?.developerModeStatus?.isEnabled ?? deviceProperties?.developerModeStatus?.isEnabled,
            developerDiskImageMounted: state?.areDeveloperDiskImageServicesAvailable ?? deviceProperties?.ddiServicesAvailable,
            coreDeviceVersion: coreDeviceVersion
        )
    }

    struct Properties: Decodable {
        let hardware: Hardware?
        let connection: Connection?
        let software: Software?
        let state: State?
    }

    struct Hardware: Decodable {
        let udid: String?
        let marketingName: String?
        let productType: String?
        let productFamily: String?
        let deviceType: String?
        let fidelity: String?
        let reality: String?
    }

    struct Connection: Decodable {
        let transportType: String?
        let pairingState: String?
        let state: String?
        let tunnelState: String?
        let tunnelIPAddressString: String?
        let tunnelIPAddress: String?
    }

    struct Software: Decodable {
        let osVersionNumber: Version?

        struct Version: Decodable {
            let stringValue: String?
        }
    }

    struct State: Decodable {
        let name: String?
        let developerModeStatus: DeveloperModeStatus?
        let areDeveloperDiskImageServicesAvailable: Bool?
    }

    struct LegacyDeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
        let developerModeStatus: DeveloperModeStatus?
        let ddiServicesAvailable: Bool?
    }

    struct DeveloperModeStatus: Decodable {
        let isEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case enabled, disabled
        }

        init(from decoder: Decoder) throws {
            if let status = try? decoder.singleValueContainer().decode(String.self) {
                switch status {
                case "enabled": isEnabled = true
                case "disabled": isEnabled = false
                default: isEnabled = nil
                }
                return
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.enabled) {
                isEnabled = true
            } else if values.contains(.disabled) {
                isEnabled = false
            } else {
                isEnabled = nil
            }
        }
    }
}
