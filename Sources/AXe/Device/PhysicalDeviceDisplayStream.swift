import Foundation

/// Owns the negotiated control connection, UDP receiver and client session identity.
actor PhysicalDeviceDisplayStream {
    static let service = "com.apple.coredevice.displayservice"
    private static let offeredTimeout: TimeInterval = 20

    let rtpPayloadType: UInt8
    let width: Int
    let height: Int
    let frameRate: Int
    /// Clockwise degrees that turn the native frames upright for the interface at stream start, or nil
    /// when the display orientation could not be confirmed then.
    let nativeFrameRotation: Int?

    private let directory: DeviceServiceDirectory
    private let control: PhysicalDisplayControl
    private let receiver: PhysicalDisplayUDPReceiver
    private let deviceIdentifier: String
    private let coreDeviceVersion: String
    private let clientSessionID: UUID
    private let senderPort: UInt16
    private let cleanupTimeout: TimeInterval
    private var receiving = false
    private var stopTask: Task<Void, Error>?
    private var tunnelRefresh: Task<Void, Never>?
    private var tunnelRefreshFailure: CLIOutputFailure?

    private init(directory: DeviceServiceDirectory, control: PhysicalDisplayControl, receiver: PhysicalDisplayUDPReceiver,
                 deviceIdentifier: String, coreDeviceVersion: String, clientSessionID: UUID,
                 metadata: StreamMetadata, nativeFrameRotation: Int?) {
        self.directory = directory
        self.control = control
        self.receiver = receiver
        self.deviceIdentifier = deviceIdentifier
        self.coreDeviceVersion = coreDeviceVersion
        self.clientSessionID = clientSessionID
        senderPort = metadata.senderPort
        cleanupTimeout = metadata.rtcpTimeout + 2
        rtpPayloadType = metadata.payloadType
        width = metadata.width
        height = metadata.height
        frameRate = metadata.frameRate
        self.nativeFrameRotation = nativeFrameRotation
    }

    static func start(for listedDevice: CoreDevice) async throws -> PhysicalDeviceDisplayStream {
        let device = try await PhysicalDeviceInputOwner.readyDevice(listedDevice)
        guard let address = device.tunnelAddress, let udid = device.udid, let version = device.coreDeviceVersion else {
            throw DeviceServiceError.invalidProtocol("the device did not report display service connection details")
        }

        let directory = try await DeviceServiceDirectory.connect(tunnelAddress: address, expectedUDID: udid)
        var openedReceiver: PhysicalDisplayUDPReceiver?
        do {
            let receiver = try PhysicalDisplayUDPReceiver(tunnelAddress: address)
            openedReceiver = receiver
            let (display, rotation) = try await primaryDisplay(using: directory, deviceIdentifier: device.identifier, version: version)
            let clientSessionID = UUID()
            let offer = try PhysicalDisplayOffer.make()
            let request = try DeviceServiceDirectory.coreDeviceRequest(feature: "startmediastream", action: "mediastreamstart",
                input: [
                    "clientSupportedFeatures": .uint64(140),
                    "direction": .string("output"),
                    "negotiatorOffer": .data(offer.data),
                    "options": .dictionary([
                        "AVCMediaStreamNegotiatorAccessNetworkType": .dictionary(["int": .int64(1)]),
                        "AVCMediaStreamNegotiatorTransportProtocolType": .dictionary(["int": .int64(2)]),
                        "CoreDeviceVideoDisplayMode": .dictionary(["string": .string("DisplayByID")]),
                        "VideoStreamForDisplayID": .dictionary(["int": .int64(display)]),
                        "avcMediaStreamOptionClientSessionID": .dictionary(["uuid": .uuid(clientSessionID)]),
                    ]),
                    "receiverIP": .string(receiver.receiverIP),
                    "receiverPort": .uint64(UInt64(receiver.receiverPort)),
                    "senderIP": .string(receiver.senderIP),
                    "timeout": .uint64(UInt64(offeredTimeout)),
                    "type": .string("video"),
                ], deviceIdentifier: device.identifier, coreDeviceVersion: version)
            let control = try await directory.openPhysicalDisplayControl(timeout: 8)
            var startAttempted = false
            do {
                try Task.checkCancellation()
                startAttempted = true
                // Keep the reply and owner long enough to close the stream even if the caller cancels.
                let response = try await control.request(request, timeout: 10)
                let metadata = try StreamMetadata(response: response, receiver: receiver,
                    clientSessionID: clientSessionID, offeredSSRC: offer.receiverSSRC)
                receiver.enableReceiverReports(PhysicalDisplayRTCP(payloadType: metadata.payloadType,
                    senderSSRC: metadata.senderSSRC, receiverSSRC: offer.receiverSSRC,
                    cname: clientSessionID.uuidString.lowercased() + "@axe",
                    reportInterval: metadata.rtcpReportInterval))
                try Task.checkCancellation()
                let stream = PhysicalDeviceDisplayStream(directory: directory, control: control, receiver: receiver,
                    deviceIdentifier: device.identifier, coreDeviceVersion: version,
                    clientSessionID: clientSessionID, metadata: metadata, nativeFrameRotation: rotation)
                await stream.refreshTunnel(for: device)
                return stream
            } catch {
                let startError = error
                if startAttempted {
                    do {
                        try await cleanup(directory: directory, control: control, receiver: receiver,
                            deviceIdentifier: device.identifier, version: version,
                            clientSessionID: clientSessionID, timeout: offeredTimeout + 2)
                    } catch let cleanupError as CLIOutputFailure {
                        throw CLIOutputFailure(code: cleanupError.code,
                            message: "\(startFailure(startError)) \(cleanupError.message)")
                    }
                } else {
                    control.close()
                    receiver.close()
                }
                throw startError
            }
        } catch {
            // Closing is idempotent; the start-failure path may already have closed the receiver.
            openedReceiver?.close()
            directory.close()
            throw error
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 20 else {
            throw CLIOutputFailure(code: "invalidArguments", message: "Display receive timeout must be greater than 0 and at most 20 seconds.")
        }
        guard stopTask == nil else { throw CancellationError() }
        if let tunnelRefreshFailure { throw tunnelRefreshFailure }
        guard !receiving else {
            throw CLIOutputFailure(code: "deviceBusy", message: "Another operation is reading the physical display stream.")
        }
        receiving = true
        defer { receiving = false }
        return try await receiver.receive(senderPort: senderPort, timeout: timeout)
    }

    /// Explains a packet stall from the display service status. The device sends one display
    /// video stream at a time, so another client's new stream replaces this one.
    func stallFailure() async -> CLIOutputFailure {
        let fallback = CLIOutputFailure(code: "deviceStreamUnavailable",
            message: "The physical device stopped sending RTP and RTCP packets.")
        guard stopTask == nil,
              let sessions = try? await Self.statusSessions(directory: directory, deviceIdentifier: deviceIdentifier,
                  version: coreDeviceVersion, timeout: 5),
              !sessions.contains(where: { Self.isOwned($0, clientSessionID: clientSessionID, receiver: receiver) }) else {
            return fallback
        }
        let otherVideo = sessions.contains { $0.dictionaryValue?["connection"]?.dictionaryValue?["type"] == .string("video") }
        guard otherVideo else {
            return CLIOutputFailure(code: "deviceStreamUnavailable",
                message: "The physical device ended AXe's display stream.")
        }
        return CLIOutputFailure(code: "deviceStreamReplaced",
            message: "Another client, such as Xcode Device Hub's screen view, started a display stream on the device. "
                + "The device sends one display stream at a time, so it ended AXe's stream.")
    }

    func stop() async throws {
        if let stopTask {
            try await stopTask.value
            return
        }
        let refresh = tunnelRefresh
        let task = Task {
            let result: Result<Void, Error>
            do {
                try await Self.cleanup(directory: directory, control: control, receiver: receiver,
                    deviceIdentifier: deviceIdentifier, version: coreDeviceVersion,
                    clientSessionID: clientSessionID, timeout: cleanupTimeout)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            refresh?.cancel()
            await refresh?.value
            try result.get()
        }
        stopTask = task
        try await task.value
    }

    private func refreshTunnel(for device: CoreDevice) {
        // Raw RSD and RTP traffic do not keep the Mac's CoreDevice tunnel route alive.
        // Keep the same route active through owned-stream status verification.
        tunnelRefresh = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    let current = try await CoreDeviceInventory.details(for: device)
                    guard current.udid?.lowercased() == device.udid?.lowercased(),
                          current.tunnelConnected == true, current.tunnelAddress == device.tunnelAddress,
                          current.coreDeviceVersion == device.coreDeviceVersion else {
                        throw CLIOutputFailure(code: "deviceTunnelChanged",
                            message: "CoreDevice changed the device identity or tunnel during streaming.")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let failure = (error as? CLIOutputFailure) ?? CLIOutputFailure(
                    code: "deviceTunnelUnavailable", message: "CoreDevice could not refresh the physical stream tunnel.")
                await self?.recordTunnelRefreshFailure(failure)
            }
        }
    }

    private func recordTunnelRefreshFailure(_ failure: CLIOutputFailure) {
        tunnelRefreshFailure = failure
    }

    private static func primaryDisplay(using directory: DeviceServiceDirectory,
                                       deviceIdentifier: String, version: String) async throws -> (id: Int64, rotation: Int?) {
        let geometry = try await directory.readDisplay(deviceIdentifier: deviceIdentifier, coreDeviceVersion: version,
                                                       timeout: 8)
        guard let display = geometry.displayID else {
            throw DeviceServiceError.invalidProtocol("the device did not report one built-in primary display")
        }
        // The same reply carries the orientation check; no extra read.
        return (display, (try? geometry.requireResolvedOrientation()) == nil ? nil : geometry.nativeFrameRotation)
    }

    private static func cleanup(directory: DeviceServiceDirectory, control: PhysicalDisplayControl,
                                receiver: PhysicalDisplayUDPReceiver, deviceIdentifier: String, version: String,
                                clientSessionID: UUID, timeout: TimeInterval) async throws {
        try await Task.detached {
            // Close only the owned control/UDP sockets. The verified RSD
            // connection stays open until the matching status entry disappears.
            control.close()
            receiver.close()
            defer { directory.close() }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(timeout)
            while true {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw cleanupFailure("The owned stream still appeared in the display service status.")
                }
                let timeout = remaining.timeInterval
                let sessions: [RemoteXPCValue]
                do {
                    sessions = try await statusSessions(directory: directory, deviceIdentifier: deviceIdentifier,
                        version: version, timeout: timeout)
                } catch DeviceServiceError.timeout {
                    throw cleanupFailure("The display service status read timed out.")
                } catch DeviceServiceError.invalidProtocol {
                    throw cleanupFailure("The status reply did not include an active stream list.")
                } catch {
                    throw cleanupFailure("The display service status request failed.")
                }
                let active = sessions.contains { isOwned($0, clientSessionID: clientSessionID, receiver: receiver) }
                if !active { return }
                try await Task.sleep(for: min(remaining, .milliseconds(250)))
            }
        }.value
    }

    private static func statusSessions(directory: DeviceServiceDirectory, deviceIdentifier: String, version: String,
                                       timeout: TimeInterval) async throws -> [RemoteXPCValue] {
        let response = try await directory.requestCoreDevice(service: service, feature: "getmediastreamserverstatus",
            action: "mediastreamstatus", input: [:], deviceIdentifier: deviceIdentifier,
            coreDeviceVersion: version, timeout: timeout)
        guard case let .array(sessions)? = response["CoreDevice.output"]?.dictionaryValue?["sessions"] else {
            throw DeviceServiceError.invalidProtocol("the status reply did not include an active stream list")
        }
        return sessions
    }

    private static func isOwned(_ session: RemoteXPCValue, clientSessionID: UUID,
                                receiver: PhysicalDisplayUDPReceiver) -> Bool {
        guard let connection = session.dictionaryValue?["connection"]?.dictionaryValue else { return false }
        if sessionUUID(connection) == clientSessionID { return true }
        let endpoint = connection["receiver"]?.dictionaryValue
        return endpoint?["port"]?.integer == UInt64(receiver.receiverPort)
            && endpoint?["ipv6Address"]?.stringValue.map(receiver.matchesReceiver) == true
    }

    private static func cleanupFailure(_ reason: String) -> CLIOutputFailure {
        CLIOutputFailure(code: "cleanupUnconfirmed",
            message: "AXe closed its display stream connection but could not verify that its session ended. \(reason)")
    }

    private static func startFailure(_ error: Error) -> String {
        switch error {
        case is CancellationError:
            return "Display stream start was cancelled."
        case DeviceServiceError.timeout:
            return "The display stream start request timed out."
        case DeviceServiceError.invalidProtocol:
            return "The display stream start reply did not confirm the requested stream."
        case DeviceServiceError.connectionFailed:
            return "The display control connection failed during startup."
        default:
            return "The display stream start request failed."
        }
    }

    private static func sessionUUID(_ connection: [String: RemoteXPCValue]) -> UUID? {
        connection["options"]?.dictionaryValue?["avcMediaStreamOptionClientSessionID"]?.dictionaryValue?["uuid"]?.uuidValue
    }

    private struct StreamMetadata {
        let senderPort: UInt16
        let payloadType: UInt8
        let width: Int
        let height: Int
        let frameRate: Int
        let rtcpTimeout: TimeInterval
        let rtcpReportInterval: TimeInterval
        let senderSSRC: UInt32

        init(response: [String: RemoteXPCValue], receiver: PhysicalDisplayUDPReceiver,
             clientSessionID: UUID, offeredSSRC: UInt32) throws {
            guard let output = response["CoreDevice.output"]?.dictionaryValue,
                  let connection = output["connection"]?.dictionaryValue,
                  sessionUUID(connection) == clientSessionID,
                  let remoteEndpoint = connection["sender"]?.dictionaryValue,
                  let localEndpoint = connection["receiver"]?.dictionaryValue,
                  let senderIP = remoteEndpoint["ipv6Address"]?.stringValue, receiver.matchesSender(senderIP),
                  let receiverIP = localEndpoint["ipv6Address"]?.stringValue, receiver.matchesReceiver(receiverIP),
                  localEndpoint["port"]?.integer == UInt64(receiver.receiverPort),
                  let portNumber = remoteEndpoint["port"]?.integer, let port = UInt16(exactly: portNumber), port != 0,
                  let config = connection["streamConfig"]?.dictionaryValue,
                  config["SourcePort"]?.integer == UInt64(port),
                  config["SRTPCipherSuite"]?.integer == 0, config["SRTCPCipherSuite"]?.integer == 0,
                  let payload = config["RxPayloadType"]?.integer, payload == UInt64(PhysicalDisplayOffer.payloadType),
                  config["TxPayloadType"]?.integer == payload,
                  config["RTCPEnabled"] == .bool(true), config["RTCPTimeoutEnabled"] == .bool(true),
                  config["RTCPRemotePort"]?.integer == UInt64(receiver.receiverPort),
                  case let .double(rtcpTimeout)? = config["RTCPTimeoutInterval"],
                  rtcpTimeout.isFinite, (1...30).contains(rtcpTimeout),
                  case let .double(reportInterval)? = config["RTCPSendInterval"],
                  reportInterval.isFinite, (0.2...10).contains(reportInterval), reportInterval < rtcpTimeout,
                  let width = config["CustomWidth"]?.integer, (1...16_384).contains(width),
                  let height = config["CustomHeight"]?.integer, (1...16_384).contains(height),
                  let fps = config["Framerate"]?.integer, (1...240).contains(fps) else {
                throw DeviceServiceError.invalidProtocol("the display service did not confirm the requested AVC stream")
            }
            guard let local = config["LocalSSRC"]?.integer, let localSSRC = UInt32(exactly: local), localSSRC != 0,
                  let remote = config["RemoteSSRC"]?.integer, let remoteSSRC = UInt32(exactly: remote), remoteSSRC != 0,
                  localSSRC != remoteSSRC, localSSRC == offeredSSRC || remoteSSRC == offeredSSRC else {
                throw DeviceServiceError.invalidProtocol("the display service did not confirm the offered RTCP receiver SSRC")
            }
            senderSSRC = localSSRC == offeredSSRC ? remoteSSRC : localSSRC
            senderPort = port
            payloadType = UInt8(payload)
            self.width = Int(width)
            self.height = Int(height)
            frameRate = Int(fps)
            self.rtcpTimeout = rtcpTimeout
            rtcpReportInterval = reportInterval
        }
    }
}

/// Serializes access to the retained RemoteXPC control connection.
final class PhysicalDisplayControl: @unchecked Sendable {
    private let queue = DispatchQueue(label: "axe.device-display-control")
    private var connection: RemoteXPCConnection?

    init(connection: RemoteXPCConnection) { self.connection = connection }

    func request(_ body: [String: RemoteXPCValue], timeout: TimeInterval) async throws -> [String: RemoteXPCValue] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard let connection = self.connection else {
                        throw DeviceServiceError.connectionFailed("the display control connection is closed")
                    }
                    return try connection.request(body, timeout: timeout)
                })
            }
        }
    }

    func close() {
        queue.sync { connection = nil }
    }
}
