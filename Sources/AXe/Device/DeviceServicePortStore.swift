import Foundation

/// Service directory ports saved by `axe device-port`, one per device, each for the tunnel it was found on.
/// A recreated tunnel has a new address and a new port, so an entry for another address is ignored.
struct DeviceServicePortStore: Sendable {
    static let shared = DeviceServicePortStore(fileURL: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.cameroncooke.axe", isDirectory: true)
        .appendingPathComponent("device-service-ports.json"))

    struct Entry: Codable, Equatable {
        let tunnel: String
        let port: UInt16
    }

    let fileURL: URL

    func port(udid: String, tunnel: DeviceTunnelAddress) -> UInt16? {
        guard let entry = entries()[udid.uppercased()],
              let saved = try? DeviceTunnelAddress(entry.tunnel), saved.sameAddress(as: tunnel),
              entry.port != 0 else { return nil }
        return entry.port
    }

    func save(port: UInt16, udid: String, tunnel: DeviceTunnelAddress) throws {
        var all = entries()
        all[udid.uppercased()] = Entry(tunnel: tunnel.host, port: port)
        try write(all)
    }

    func remove(udid: String) {
        var all = entries()
        guard all.removeValue(forKey: udid.uppercased()) != nil else { return }
        try? write(all)
    }

    private func entries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    private func write(_ entries: [String: Entry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
