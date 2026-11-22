#if AXE_MIRROR
import Foundation

/// The iPhones and iPads this Mac knows by name: the ones Xcode has been used with. A build is
/// signed for a list of device identifiers, which mean nothing to a person; these are the names to
/// say them by, so that "signed for 7 devices" can become "Your iPhone Duo is one of them".
///
/// Asked of `devicectl`, which lists them whether or not they are connected. Simulators are left
/// out. When the tool is missing or says nothing, there are none, and nothing is said about devices.
enum MirrorKnownDevices {
    struct Device: Equatable, Sendable {
        var name: String
        var udid: String
    }

    static func list() -> [Device] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("axe-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--json-output", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard done.wait(timeout: .now() + 15) == .success else { process.terminate(); return [] }
        guard let data = try? Data(contentsOf: file) else { return [] }
        return parse(data)
    }

    /// The physical devices in `devicectl`'s listing.
    static func parse(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String != "simulated", let udid = hardware["udid"] as? String, !udid.isEmpty,
                  let name = (device["deviceProperties"] as? [String: Any])?["name"] as? String, !name.isEmpty else { return nil }
            return Device(name: name, udid: udid)
        }
        .sorted { $0.name < $1.name }
    }

    /// Which of `known` a build signed for `devices` can be installed on, and which it cannot, by name.
    static func coverage(of devices: [String], among known: [Device]) -> (covered: [String], notCovered: [String]) {
        let signed = Set(devices.map { $0.uppercased() })
        return (known.filter { signed.contains($0.udid.uppercased()) }.map(\.name), known.filter { !signed.contains($0.udid.uppercased()) }.map(\.name))
    }
}
#endif
