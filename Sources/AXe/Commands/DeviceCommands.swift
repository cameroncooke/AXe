import ArgumentParser
import FBControlCore

struct ListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the physical iPhones and iPads that Xcode knows, with any readiness problems.")

    func run() async throws {
        let devices = try await CoreDeviceInventory.list()
            .map(DeviceSummary.init)
            .sorted { $0.udid < $1.udid }

        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(Inventory(devices: devices))
            return
        }
        if devices.isEmpty {
            CLIOutput.message("No physical iPhones or iPads found.")
        }
        for device in devices {
            let description = [device.name ?? "iOS Device", device.model, device.osVersion]
                .compactMap { $0 }.joined(separator: " · ")
            CLIOutput.message("\(device.udid)  \(description)")
            for check in device.checks where check.status != .ready {
                if let message = check.message {
                    CLIOutput.message("  \(check.id) (\(check.status.rawValue)): \(message)")
                }
            }
        }
    }

    struct Inventory: Encodable {
        let devices: [DeviceSummary]
    }

    struct DeviceSummary: Encodable {
        let udid: String
        let name: String?
        let model: String?
        let osVersion: String?
        let transport: String?
        let checks: [ReadinessCheck]

        init(_ device: CoreDevice) {
            udid = device.udid ?? device.identifier
            name = device.name
            model = device.model
            osVersion = device.osVersion
            transport = device.transport
            checks = DeviceInspection.listChecks(for: device)
        }
    }
}

struct DevicePort: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "device-port",
        abstract: "Save a physical device's service directory port when AXe cannot find it.",
        discussion: """
        AXe reads the port with nettop. Some Macs hide network connections from AXe; then the device error prints a line to paste in Terminal, where netstat lists them, and that line runs this command. AXe checks the port with the device before saving it, and uses it until the device's tunnel is recreated. Without --port, prints that line.

        Example:
          axe device-port --udid <UDID>
        """)

    @Option(help: "Hardware UDID of the physical device.")
    var udid: String

    @Option(help: "The service directory port. Omit it to print the command that finds it.")
    var port: String?

    func run() async throws {
        guard let listed = try await AutomationTarget.physicalDeviceRecord(udid: udid) else {
            throw CLIOutputFailure(code: "invalidArguments",
                message: "device-port takes a physical device's hardware UDID. Run axe list-devices.")
        }
        let device = try await CoreDeviceInventory.details(for: listed)
        guard let address = device.tunnelAddress, let hardwareUDID = device.udid else {
            throw CLIOutputFailure(code: "deviceNotConnected",
                message: "CoreDevice reported no tunnel for the device. Connect it by USB or reconnect it in Xcode.")
        }
        let tunnel = try DeviceTunnelAddress(address)

        guard let port else {
            let command = tunnel.savePortCommand(udid: hardwareUDID)
            if CLIOutput.isFormatted {
                try CLIOutput.writeJSON(["udid": hardwareUDID, "tunnel": address, "command": command])
            } else {
                CLIOutput.message("Run this in Terminal to save the port:\n  \(command)")
            }
            return
        }
        let value = try Self.parsePort(port, tunnel: address)
        do {
            try await DeviceServiceDirectory.savePort(value, tunnelAddress: address, expectedUDID: hardwareUDID)
        } catch let error as DeviceServiceError {
            if case .targetMismatch = error { throw error }
            throw CLIOutputFailure(code: "invalidArguments",
                message: "Port \(value) is not the device's service directory on \(address) (\(error.localizedDescription)) Nothing was saved. Run axe device-port --udid \(hardwareUDID) for the line that finds it.")
        }
        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(Saved(udid: hardwareUDID, tunnel: address, port: value))
        } else {
            CLIOutput.message("Saved port \(value) for \(hardwareUDID) on \(address).")
        }
    }

    static func parsePort(_ text: String, tunnel: String) throws -> UInt16 {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else {
            throw CLIOutputFailure(code: "invalidArguments", message: lines.isEmpty
                ? "netstat listed no remoted connection to \(tunnel). Check the device connection in Xcode and run the line again."
                : "netstat listed more than one remoted connection to \(tunnel). Reconnect the device in Xcode and run the line again.")
        }
        guard let port = UInt16(lines[0].trimmingCharacters(in: .whitespaces)), port != 0 else {
            throw CLIOutputFailure(code: "invalidArguments",
                message: "--port must be a port number from 1 to 65535, not \"\(lines[0])\".")
        }
        return port
    }

    struct Saved: Encodable {
        let udid: String
        let tunnel: String
        let port: UInt16
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check whether a simulator or physical device is ready for AXe.",
        discussion: """
        A physical device must be paired, in Developer Mode, connected, unlocked, with its developer disk image and screenshot service available; a simulator must be booted. A failed check exits nonzero.

        Example:
          axe doctor --udid <UDID>
        """)

    @Option(help: "UDID of the simulator or physical device.")
    var udid: String

    @MainActor
    func run() async throws {
        let report: TargetReadiness
        switch try await AutomationTarget.resolve(udid: udid) {
        case let .simulator(simulator):
            let state = FBiOSTargetStateStringFromState(simulator.state).rawValue
            report = TargetReadiness(target: "simulator", udid: simulator.udid, name: simulator.name,
                checks: [ReadinessCheck("simulatorNotBooted", observed: simulator.state == .booted,
                    fix: "Simulator state: \(state). Boot the simulator and run doctor again.")])
        case let .device(device):
            let inspection = try await DeviceInspection.inspect(device)
            inspection.directory?.close()
            report = inspection.report
        }

        if CLIOutput.isFormatted {
            try CLIOutput.writeJSON(report)
            guard report.ready else { throw report.failure }
            return
        }
        CLIOutput.message("\(report.name ?? report.target) (\(report.udid)): \(report.ready ? "ready" : "not ready")")
        for check in report.checks {
            let message = check.message.map { " — " + $0 } ?? ""
            CLIOutput.message("  \(Self.labels[check.id] ?? check.id): \(check.status.rawValue)\(message)")
        }
        // The report above already names each failed check and its fix.
        guard report.ready else {
            throw CLIOutputFailure(code: report.failure.code, message: "\(report.name ?? report.target) is not ready.")
        }
    }

    /// Text labels for the check IDs, which name the failure and double as JSON error codes.
    private static let labels = [
        "simulatorNotBooted": "Booted", "notPaired": "Paired", "developerModeDisabled": "Developer Mode",
        "deviceNotConnected": "Connected", "developerDiskImageUnavailable": "Disk image",
        "deviceLocked": "Unlocked", "screenshotServiceUnavailable": "Screenshot service",
    ]
}
