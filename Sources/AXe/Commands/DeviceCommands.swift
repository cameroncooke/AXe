import ArgumentParser
import FBControlCore

struct ListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List known physical iPhones and iPads.")

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

    private struct Inventory: Encodable {
        let devices: [DeviceSummary]
    }

    private struct DeviceSummary: Encodable {
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

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check if a simulator or physical device is ready.")

    @Option(help: "The UDID of the simulator or physical device.")
    var udid: String

    @MainActor
    func run() async throws {
        let report: TargetReadiness
        switch try await AutomationTarget.resolve(udid: udid) {
        case let .simulator(simulator):
            let state = FBiOSTargetStateStringFromState(simulator.state)
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
        } else {
            CLIOutput.message("\(report.name ?? report.target) (\(report.udid)): \(report.ready ? "ready" : "not ready")")
            for check in report.checks {
                let message = check.message.map { " — " + $0 } ?? ""
                CLIOutput.message("  \(Self.labels[check.id] ?? check.id): \(check.status.rawValue)\(message)")
            }
        }
        guard report.ready else { throw report.failure }
    }

    /// Text labels for the check IDs, which name the failure and double as JSON error codes.
    private static let labels = [
        "simulatorNotBooted": "Booted", "notPaired": "Paired", "developerModeDisabled": "Developer Mode",
        "deviceNotConnected": "Connected", "developerDiskImageUnavailable": "Disk image",
        "deviceLocked": "Unlocked", "screenshotServiceUnavailable": "Screenshot service",
    ]
}
