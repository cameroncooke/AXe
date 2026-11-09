import Foundation

struct ReadinessCheck: Encodable {
    enum Status: String, Encodable {
        case ready, blocked, unchecked
    }

    let id: String
    let status: Status
    let message: String?

    init(_ id: String, observed: Bool?, fix: String) {
        self.id = id
        switch observed {
        case true?:
            status = .ready
            message = nil
        case false?:
            status = .blocked
            message = fix
        case nil:
            status = .unchecked
            message = fix
        }
    }
}

struct TargetReadiness: Encodable {
    let target: String
    let udid: String
    let name: String?
    let checks: [ReadinessCheck]
    var ready: Bool { checks.allSatisfy { $0.status == .ready } }

    private enum CodingKeys: String, CodingKey { case target, udid, name, checks, ready }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(target, forKey: .target)
        try values.encode(udid, forKey: .udid)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encode(checks, forKey: .checks)
        try values.encode(ready, forKey: .ready)
    }

    var failure: CLIOutputFailure {
        let check = checks.first { $0.status == .blocked } ?? checks.first { $0.status == .unchecked }
        return CLIOutputFailure(code: check?.id ?? "targetNotReady",
            message: check?.message ?? "AXe could not verify target readiness.")
    }
}

struct DeviceInspection {
    let device: CoreDevice
    let report: TargetReadiness
    let directory: DeviceServiceDirectory?

    static func inventoryChecks(for device: CoreDevice) -> [ReadinessCheck] {
        let connected = device.tunnelAddress != nil && device.tunnelConnected != false
        return [
            ReadinessCheck("notPaired", observed: device.paired,
                fix: "Pair the device in Xcode and confirm Trust on the device."),
            ReadinessCheck("developerModeDisabled", observed: device.developerModeEnabled,
                fix: "Enable Developer Mode in Settings on the device."),
            ReadinessCheck("deviceNotConnected", observed: connected,
                fix: "Connect the device by USB or reconnect it in Xcode."),
            ReadinessCheck("developerDiskImageUnavailable", observed: device.developerDiskImageMounted,
                fix: "Open the device in Xcode and wait for it to finish preparing the device.")
        ]
    }

    /// Checks `list-devices` can make from the inventory alone. The inventory list does not reconnect
    /// an idle tunnel; doctor and device commands do, so a paired device without one is unchecked.
    static func listChecks(for device: CoreDevice) -> [ReadinessCheck] {
        let inventory = inventoryChecks(for: device)
        let idle = device.paired == true
            && inventory.contains { $0.id == "deviceNotConnected" && $0.status == .blocked }
        return inventory.map { check in
            guard idle, check.id == "deviceNotConnected" || check.id == "developerDiskImageUnavailable" else { return check }
            return ReadinessCheck(check.id, observed: nil,
                fix: "CoreDevice has no active connection. Run axe doctor to connect and check.")
        } + [
            ReadinessCheck("deviceLocked", observed: nil, fix: "Run axe doctor to check the lock state."),
            ReadinessCheck("screenshotServiceUnavailable", observed: nil, fix: "Run axe doctor to check screenshot access."),
        ]
    }

    static func inspect(_ listedDevice: CoreDevice) async throws -> Self {
        let device = try await CoreDeviceInventory.details(for: listedDevice)
        var checks = inventoryChecks(for: device)
        let canConnect = checks.allSatisfy { $0.status == .ready }
        var unlocked: Bool?
        var unlockFix = "Unlock the device and keep it awake."
        if canConnect {
            do {
                unlocked = try await CoreDeviceInventory.lockState(for: device).map { !$0 }
            } catch {
                try Task.checkCancellation()
                unlockFix = "AXe could not read the lock state. Unlock the device and run doctor again."
            }
        }
        checks.append(ReadinessCheck("deviceLocked", observed: unlocked, fix: unlockFix))

        var directory: DeviceServiceDirectory?
        var screenshotAvailable: Bool?
        var serviceFix = "Resolve the other device checks and run doctor again."
        if canConnect, unlocked == true {
            if let address = device.tunnelAddress, let udid = device.udid {
                do {
                    let connection = try await DeviceServiceDirectory.connect(tunnelAddress: address, expectedUDID: udid)
                    screenshotAvailable = connection.hasScreenshotService
                    if connection.hasScreenshotService {
                        directory = connection
                    } else {
                        connection.close()
                        serviceFix = "The device does not advertise the screenshot service. Check device preparation in Xcode."
                    }
                } catch {
                    try Task.checkCancellation()
                    screenshotAvailable = false
                    serviceFix = error.localizedDescription
                }
            } else {
                screenshotAvailable = false
                serviceFix = "CoreDevice did not report a tunnel address or hardware UDID. Reconnect the device in Xcode."
            }
        }
        checks.append(ReadinessCheck("screenshotServiceUnavailable", observed: screenshotAvailable, fix: serviceFix))

        return DeviceInspection(device: device,
            report: TargetReadiness(target: "device", udid: device.udid ?? device.identifier,
                                    name: device.name, checks: checks),
            directory: directory)
    }
}
