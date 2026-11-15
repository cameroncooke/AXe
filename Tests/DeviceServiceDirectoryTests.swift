import Foundation
import Testing
@testable import AXe

// Rows follow nettop output recorded on macOS 26.6 with an iPad on iOS 27.2. Addresses and ports are invented.

@Suite("CoreDevice service directory port lookup")
struct DeviceServiceDirectoryPortTests {
    static let udid = "00008103-000000000000801E"

    static func tunnel(_ host: String = "fd77:197:3d4d::1") throws -> DeviceTunnelAddress {
        try DeviceTunnelAddress(host)
    }

    @Test("nettop: remoted's established connection to the tunnel")
    func nettopPort() throws {
        let sockets = """
            ,state,
            remoted.363,,
            tcp6 fd77:197:3d4d::2.58874<->*.*,Listen,
            tcp6 fd77:197:3d4d::2.58876<->fd77:197:3d4d::1.57198,Established,
            tcp6 fd00:1::2.58000<->fd00:1::1.50000,Established,
            """
        #expect(try Self.tunnel().portFromNettop(sockets) == 57198)
    }

    @Test("nettop: a header alone, when remoted has no connection")
    func nettopEmpty() throws {
        #expect(try Self.tunnel().portFromNettop(",state,\n") == nil)
    }

    @Test("nettop: two ports on the tunnel address are ambiguous")
    func nettopAmbiguous() throws {
        let sockets = """
            tcp6 fd77:197:3d4d::2.58876<->fd77:197:3d4d::1.57198,Established,
            tcp6 fd77:197:3d4d::2.58877<->fd77:197:3d4d::1.57199,Established,
            """
        #expect(try Self.tunnel().portFromNettop(sockets) == nil)
    }

    @Test("nettop: another address on the tunnel's prefix is ignored")
    func nettopExactAddress() throws {
        let sockets = """
            tcp6 fd77:197:3d4d::2.58876<->fd77:197:3d4d::3.57198,Established,
            """
        #expect(try Self.tunnel().portFromNettop(sockets) == nil)
    }

    @Test("A failed nettop read names the reason and the line to paste",
          arguments: [
            (DeviceTunnelAddress.CommandOutcome.output(",state,\n"), "listed no single remoted connection to fd77:197:3d4d::1"),
            (.timedOut(3), "timed out after 3 s"),
            (.failed, "failed"),
          ])
    func notFound(outcome: DeviceTunnelAddress.CommandOutcome, reason: String) throws {
        let tunnel = try Self.tunnel()
        #expect {
            try tunnel.serviceDirectoryPort(expectedUDID: Self.udid, readSockets: { outcome })
        } throws: { error in
            guard case DeviceServiceError.rsdPortUnavailable(_, Self.udid, reason)? = error as? DeviceServiceError else {
                return false
            }
            let message = error.localizedDescription
            return message.contains("nettop \(reason)") && message.contains("axe device-port --udid \(Self.udid)")
        }
    }

    @Test("The pasted line matches netstat's shortened address and prints the port alone")
    func savePortCommand() throws {
        // A numeric scope, because a named one such as utun4 exists only on a Mac with that interface.
        let command = try Self.tunnel("fd77:197:3d4d::1%4").savePortCommand(udid: Self.udid)
        #expect(command.hasPrefix("axe device-port --udid \(Self.udid) --port \"$(netstat -anv -p tcp | awk -v p='fd77:197:3d4d::' "))
        #expect(command.hasSuffix("')\""))

        // Run the awk program on recorded netstat rows, the way the pasted line does.
        let awk = try #require(command.split(separator: "'").dropFirst(3).first.map(String.init))
        let rows = """
            tcp6       0      0  fd77:197:3d4d::2.58876 fd77:197:3d4d::.57198  ESTABLISHED        84044        18765  364160  131072          remoted:363    00182 00000000
            tcp6       0      0  fd77:197:3d4d::2.58875 *.*                    LISTEN                 0            0  131072  131072          remoted:363    00180 00000006
            tcp6       0      0  fd00:1::2.58000        fd00:1::1.50000        ESTABLISHED        10           10  131072  131072          remoted:363    00180 00000006
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = ["-v", "p=fd77:197:3d4d::", awk]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(rows.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "57198\n")
    }

    @Test("device-port takes exactly one port from the pasted line")
    func parsePort() throws {
        #expect(try DevicePort.parsePort("57198\n", tunnel: "fd77:197:3d4d::1") == 57198)
        for text in ["", "57198\n57199\n", "0", "65536", "abc"] {
            #expect(throws: CLIOutputFailure.self) { try DevicePort.parsePort(text, tunnel: "fd77:197:3d4d::1") }
        }
    }
}

@Suite("Saved service directory ports")
struct DeviceServicePortStoreTests {
    static func store() -> DeviceServicePortStore {
        DeviceServicePortStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-port-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("device-service-ports.json"))
    }

    @Test("A saved port is used only for the tunnel it was found on")
    func savedPortForTunnel() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let tunnel = try DeviceTunnelAddress("fd77:197:3d4d::1")
        try store.save(port: 57198, udid: "00008103-000000000000801e", tunnel: tunnel)

        #expect(store.port(udid: "00008103-000000000000801E", tunnel: tunnel) == 57198)
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: try DeviceTunnelAddress("fd77:197:3d4d:0::1")) == 57198)
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: try DeviceTunnelAddress("fd99:1:2::1")) == nil)
        #expect(store.port(udid: "00008140-000000000000401C", tunnel: tunnel) == nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A new port replaces the device's entry, and remove clears it")
    func replaceAndRemove() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let old = try DeviceTunnelAddress("fd77:197:3d4d::1")
        let new = try DeviceTunnelAddress("fd99:1:2::1")
        try store.save(port: 57198, udid: "00008103-000000000000801E", tunnel: old)
        try store.save(port: 61890, udid: "00008103-000000000000801E", tunnel: new)
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: old) == nil)
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: new) == 61890)

        store.remove(udid: "00008103-000000000000801E")
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: new) == nil)
    }

    @Test("An unreadable file counts as no saved port")
    func unreadableFile() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.port(udid: "00008103-000000000000801E", tunnel: try DeviceTunnelAddress("fd77:197:3d4d::1")) == nil)
    }
}
