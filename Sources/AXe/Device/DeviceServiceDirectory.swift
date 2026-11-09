import Darwin
import Foundation

enum DeviceServiceError: LocalizedError {
    case invalidTunnelAddress
    case rsdPortUnavailable
    case connectionFailed(String)
    case timeout
    case invalidProtocol(String)
    case targetMismatch
    case serviceUnavailable(String)
    case screenshotServiceUnavailable
    case screenshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTunnelAddress:
            return "The device has no valid CoreDevice tunnel address. Connect it in Xcode and try again."
        case .rsdPortUnavailable:
            return "The CoreDevice service directory port was not found. Check the device connection in Xcode and try again."
        case .connectionFailed(let reason):
            return "Could not connect to the CoreDevice service: \(reason)"
        case .timeout:
            return "The CoreDevice service did not respond in time. Check the device connection in Xcode and try again."
        case .invalidProtocol(let reason):
            return "The CoreDevice service returned an invalid response: \(reason)"
        case .targetMismatch:
            return "The CoreDevice service directory belongs to a different device. Refresh the device connection in Xcode."
        case .serviceUnavailable(let service):
            return "The device does not advertise a supported \(service) service. Check device preparation in Xcode."
        case .screenshotServiceUnavailable:
            return "The device does not advertise the screenshot service. Check Developer Mode and developer disk image readiness in Xcode."
        case .screenshotFailed(let reason):
            return "The device did not return a screenshot: \(reason)"
        }
    }
}

/// Holds the RSD connection while service connections use its advertised ports.
final class DeviceServiceDirectory: @unchecked Sendable {
    private static let screenshotService = "com.apple.coredevice.screencaptureservice"
    private static let hidService = "com.apple.coredevice.hid.indigo"
    private static let displayService = "com.apple.coredevice.deviceinfo"

    private let queue = DispatchQueue(label: "axe.device-services")
    private let tunnel: DeviceTunnelAddress
    private let servicePorts: [String: UInt16]
    // The queue owns the session from the moment the directory is published.
    private var session: RemoteXPCConnection?
    private var hidConnection: RemoteXPCConnection?

    var hasScreenshotService: Bool { servicePorts[Self.screenshotService] != nil }

    private init(tunnel: DeviceTunnelAddress, servicePorts: [String: UInt16], session: RemoteXPCConnection) {
        self.tunnel = tunnel
        self.servicePorts = servicePorts
        self.session = session
    }

    static func connect(tunnelAddress: String, expectedUDID: String) async throws -> DeviceServiceDirectory {
        do {
            return try await connectOnce(tunnelAddress: tunnelAddress, expectedUDID: expectedUDID)
        } catch DeviceServiceError.connectionFailed {
            // The first service-directory connection after an idle period was reset by the device
            // on both test devices; the next attempt, with a fresh port lookup, succeeded.
            try await Task.sleep(for: .milliseconds(500))
            return try await connectOnce(tunnelAddress: tunnelAddress, expectedUDID: expectedUDID)
        }
    }

    private static func connectOnce(tunnelAddress: String, expectedUDID: String) async throws -> DeviceServiceDirectory {
        try await run(on: .global(qos: .userInitiated)) {
            let tunnel = try DeviceTunnelAddress(tunnelAddress)
            let port = try tunnel.serviceDirectoryPort(expectedUDID: expectedUDID)
            let session = try RemoteXPCConnection(tunnel: tunnel, port: port, timeout: 8)
            let services = try session.readServiceDirectory(expectedUDID: expectedUDID)
            let ports = services.compactMapValues { service -> UInt16? in
                let fields = service.dictionaryValue
                let properties = fields?["Properties"]?.dictionaryValue
                guard properties?["UsesRemoteXPC"] == .bool(true),
                      properties?["EncryptSocketData"] != .bool(true),
                      let text = fields?["Port"]?.stringValue,
                      let port = UInt16(text), port != 0 else { return nil }
                return port
            }
            return DeviceServiceDirectory(tunnel: tunnel, servicePorts: ports, session: session)
        }
    }

    func close() {
        queue.sync {
            hidConnection = nil
            session = nil
        }
    }

    /// Reads the primary display on a new `deviceinfo` connection. A whole read, connection included, took
    /// about 20 ms on an iPad Pro over USB. Reusing the connection was measured and rejected: a second request
    /// on it after a pause of 0.5 s or more usually got no reply, and fresh connections then also stalled for
    /// a few seconds.
    func readDisplay(deviceIdentifier: String, coreDeviceVersion: String,
                     timeout: TimeInterval) async throws -> PhysicalDeviceDisplay {
        try PhysicalDeviceDisplay(response: await requestCoreDevice(service: Self.displayService,
            feature: "getdisplayinfo", action: "displayinfo", input: [:], deviceIdentifier: deviceIdentifier,
            coreDeviceVersion: coreDeviceVersion, timeout: timeout))
    }

    func captureScreenshot(deviceIdentifier: String, coreDeviceVersion: String,
                           timeout: TimeInterval = 20) async throws -> Data {
        guard hasScreenshotService else { throw DeviceServiceError.screenshotServiceUnavailable }
        let response = try await requestCoreDevice(
            service: Self.screenshotService,
            feature: "capturescreenshot",
            action: "capturescreenshot",
            input: ["displayUniqueID": .null, "requestedFormat": .string("png")],
            deviceIdentifier: deviceIdentifier,
            coreDeviceVersion: coreDeviceVersion,
            timeout: timeout
        )
        guard let output = response["CoreDevice.output"]?.dictionaryValue,
              output["imageFormat"]?.stringValue == "png",
              let png = output["image"]?.dataValue,
              png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw DeviceServiceError.screenshotFailed(Self.serviceErrorDescription(response))
        }
        return png
    }

    func requestCoreDevice(
        service: String,
        feature: String,
        action: String,
        input: [String: RemoteXPCValue],
        deviceIdentifier: String,
        coreDeviceVersion: String,
        timeout: TimeInterval
    ) async throws -> [String: RemoteXPCValue] {
        try await request(service: service, body: Self.coreDeviceRequest(feature: feature, action: action,
            input: input, deviceIdentifier: deviceIdentifier, coreDeviceVersion: coreDeviceVersion), timeout: timeout)
    }

    static func coreDeviceRequest(
        feature: String,
        action: String,
        input: [String: RemoteXPCValue],
        deviceIdentifier: String,
        coreDeviceVersion: String
    ) throws -> [String: RemoteXPCValue] {
        let versionComponents = coreDeviceVersion.split(separator: ".", omittingEmptySubsequences: false)
        let components = versionComponents.compactMap { UInt64($0) }
        guard !components.isEmpty, components.count == versionComponents.count else {
            throw DeviceServiceError.invalidProtocol("could not read the CoreDevice version")
        }
        return [
            "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.\(feature)"),
            "CoreDevice.actionIdentifier": .string("com.apple.coredevice.action.\(action)"),
            "CoreDevice.action": .dictionary([:]),
            "CoreDevice.input": .dictionary(input),
            "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
            "CoreDevice.deviceIdentifier": .string(deviceIdentifier),
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(2),
            "CoreDevice.coreDeviceVersion": .dictionary([
                "components": .array(components.map(RemoteXPCValue.uint64)),
                "originalComponentsCount": .int64(Int64(components.count)),
                "stringValue": .string(coreDeviceVersion),
            ]),
        ]
    }

    func request(
        service: String,
        body: [String: RemoteXPCValue],
        timeout: TimeInterval
    ) async throws -> [String: RemoteXPCValue] {
        try await Self.run(on: queue) {
            let connection = try self.open(service, timeout: timeout)
            return try connection.request(body)
        }
    }

    func prepareHID() async throws {
        try await Self.run(on: queue) {
            if self.hidConnection == nil {
                self.hidConnection = try self.open(Self.hidService, timeout: 8)
            }
        }
    }

    func sendHID(_ body: [String: RemoteXPCValue], cleanup: Bool = false) async throws {
        try await Self.run(on: queue, checkCancellation: !cleanup) {
            guard let connection = self.hidConnection else {
                throw DeviceServiceError.connectionFailed("the HID connection is closed")
            }
            try connection.sendEvent(body)
        }
    }

    func drainHID() async throws {
        try await Self.run(on: queue, checkCancellation: false) {
            try self.hidConnection?.drainEvents()
        }
    }

    func openPhysicalDisplayControl(timeout: TimeInterval) async throws -> PhysicalDisplayControl {
        try await Self.run(on: queue) {
            PhysicalDisplayControl(connection: try self.open("com.apple.coredevice.displayservice", timeout: timeout))
        }
    }

    func withRawService<Value: Sendable>(
        _ service: String,
        timeout: TimeInterval,
        _ operation: @escaping @Sendable (DeviceTCPSocket) throws -> Value
    ) async throws -> Value {
        let port = try await Self.run(on: queue) { try self.port(for: service) }
        let serviceQueue = DispatchQueue(label: "axe.device-raw-service", qos: .userInitiated)
        return try await Self.run(on: serviceQueue) {
            let socket = try DeviceTCPSocket(address: self.tunnel.socketAddress(port: port), timeout: timeout)
            return try operation(socket)
        }
    }

    private func open(_ service: String, timeout: TimeInterval) throws -> RemoteXPCConnection {
        try RemoteXPCConnection(tunnel: tunnel, port: port(for: service), timeout: timeout)
    }

    private func port(for service: String) throws -> UInt16 {
        guard session != nil else {
            throw DeviceServiceError.connectionFailed("the service directory is closed")
        }
        guard let port = servicePorts[service] else {
            throw DeviceServiceError.serviceUnavailable(service)
        }
        return port
    }

    private static func serviceErrorDescription(_ response: [String: RemoteXPCValue]) -> String {
        if let error = response["CoreDevice.error"]?.dictionaryValue {
            for key in ["localizedDescription", "NSLocalizedDescription", "message"] {
                if let reason = error[key]?.stringValue, !reason.isEmpty {
                    return String(reason.prefix(400))
                }
            }
        }
        return "expected a PNG image. Check that the device is unlocked and ready in Xcode."
    }

    private static func run<Value: Sendable>(
        on queue: DispatchQueue,
        checkCancellation: Bool = true,
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        if checkCancellation { try Task.checkCancellation() }
        let value = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: work))
            }
        }
        if checkCancellation { try Task.checkCancellation() }
        return value
    }
}

struct DeviceTunnelAddress {
    private let address: in6_addr
    private let scopeID: UInt32

    init(_ host: String) throws {
        let parts = host.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, let hostPart = parts.first,
            let address = Self.parseIPv6(hostPart)
        else {
            throw DeviceServiceError.invalidTunnelAddress
        }
        let scopeID: UInt32
        if parts.count == 2 {
            let scope = String(parts[1])
            scopeID = UInt32(scope) ?? if_nametoindex(scope)
            guard scopeID != 0 else { throw DeviceServiceError.invalidTunnelAddress }
        } else {
            scopeID = 0
        }

        self.address = address
        self.scopeID = scopeID
    }

    func socketAddress(port: UInt16) -> sockaddr_in6 {
        var socketAddress = sockaddr_in6()
        socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        socketAddress.sin6_family = sa_family_t(AF_INET6)
        socketAddress.sin6_addr = address
        socketAddress.sin6_scope_id = scopeID
        socketAddress.sin6_port = port.bigEndian
        return socketAddress
    }

    func serviceDirectoryPort(expectedUDID: String) throws -> UInt16 {
        if let sockets = Self.readCommand("/usr/sbin/netstat", arguments: ["-anv", "-p", "tcp"], timeout: 3),
            let port = portFromSockets(sockets)
        {
            return port
        }

        let allowedCharacters = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        guard !expectedUDID.isEmpty, expectedUDID.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw DeviceServiceError.rsdPortUnavailable
        }
        let predicate = """
            process == "remotepairingd" AND eventMessage CONTAINS[c] "(\(expectedUDID))" AND
            (eventMessage CONTAINS[c] "server port " OR eventMessage CONTAINS[c] "Tunnel established")
            """
        if let logs = Self.readCommand(
            "/usr/bin/log",
            arguments: ["show", "--last", "1d", "--style", "compact", "--predicate", predicate],
            timeout: 8
        ), let port = portFromLogs(logs, expectedUDID: expectedUDID) {
            return port
        }
        throw DeviceServiceError.rsdPortUnavailable
    }

    private func portFromSockets(_ sockets: String) -> UInt16? {
        var ports: Set<UInt16> = []
        var exactPorts: Set<UInt16> = []
        for line in sockets.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count > 10, fields[0] == "tcp6", fields[5] == "ESTABLISHED",
                fields[10].hasPrefix("remoted:"),
                let separator = fields[4].lastIndex(of: "."),
                let port = UInt16(fields[4][fields[4].index(after: separator)...]),
                port != 0
            else { continue }

            let host = fields[4][..<separator].split(separator: "%").first
            guard let host, let foreign = Self.parseIPv6(host), matches(foreign, byteCount: 8) else { continue }
            ports.insert(port)
            if matches(foreign, byteCount: 16) {
                exactPorts.insert(port)
            }
        }
        let candidates = exactPorts.isEmpty ? ports : exactPorts
        return candidates.count == 1 ? candidates.first : nil
    }

    private func portFromLogs(_ logs: String, expectedUDID: String) -> UInt16? {
        var matchingTunnel = false
        var port: UInt16?
        for line in logs.split(whereSeparator: \.isNewline) {
            guard line.range(of: "(\(expectedUDID))", options: .caseInsensitive) != nil else { continue }
            if line.range(of: "Tunnel established", options: .caseInsensitive) != nil {
                matchingTunnel = containsTunnelAddress(line)
                port = nil
            }
            if let marker = line.range(of: "server port ", options: .caseInsensitive),
                matchingTunnel || containsTunnelAddress(line),
                let candidate = UInt16(line[marker.upperBound...].prefix(while: \.isNumber)),
                candidate != 0
            {
                port = candidate
            }
        }
        return port
    }

    private func containsTunnelAddress(_ line: Substring) -> Bool {
        line.split { $0.isWhitespace || "[](),;<>".contains($0) }.contains { field in
            let host = field.split(separator: "%").first ?? field
            guard let loggedAddress = Self.parseIPv6(host) else { return false }
            return matches(loggedAddress, byteCount: 16)
        }
    }

    private static func parseIPv6(_ host: Substring) -> in6_addr? {
        var result = in6_addr()
        return inet_pton(AF_INET6, String(host), &result) == 1 ? result : nil
    }

    private func matches(_ other: in6_addr, byteCount: Int) -> Bool {
        withUnsafeBytes(of: address) { ownBytes in
            withUnsafeBytes(of: other) { otherBytes in
                ownBytes.prefix(byteCount).elementsEqual(otherBytes.prefix(byteCount))
            }
        }
    }

    private static func readCommand(_ executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("stdout")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        guard let input = try? FileHandle(forReadingFrom: output) else { return nil }
        defer { try? input.close() }
        let maximumOutput = 4 * 1024 * 1024
        guard let data = try? input.read(upToCount: maximumOutput + 1), data.count <= maximumOutput else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
