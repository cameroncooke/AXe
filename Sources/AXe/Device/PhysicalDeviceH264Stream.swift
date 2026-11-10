import Darwin
import Foundation

@MainActor
enum PhysicalDeviceH264Stream {
    static func run(for device: CoreDevice) async throws {
        try await SelectedMediaCapture.run { owner in
            let stream = try await PhysicalDeviceDisplayStream.start(for: device)
            let result: Result<Int, Error>
            do {
                // Native frames keep the panel's orientation; AXe passes them through without re-encoding.
                let orientation: String
                switch stream.nativeFrameRotation {
                case 0?: orientation = "Frames are upright for the current interface orientation."
                case let degrees?: orientation = "Frames use the display's native orientation. Rotate them \(degrees)° "
                    + "clockwise to show the current interface upright."
                case nil: orientation = "Frames use the display's native orientation. AXe could not confirm the "
                    + "interface orientation at the start of the stream."
                }
                let description = "Physical H.264 stream negotiated \(stream.width) × \(stream.height) at \(stream.frameRate) FPS. "
                    + orientation + "\n"
                try FileHandle.standardError.write(contentsOf: Data(description.utf8))
                result = .success(try await writeFrames(from: stream, owner: owner))
            } catch {
                result = .failure(error)
            }
            do {
                try await stream.stop()
            } catch {
                if case let .failure(captureError) = result {
                    throw CLIOutputFailure(code: "cleanupUncertain",
                        message: "\(error.localizedDescription) Capture failed: \(captureError.localizedDescription)")
                }
                throw error
            }
            let units = try result.get()
            let text = "Physical H.264 stream ended after \(units) complete access units.\n"
            try FileHandle.standardError.write(contentsOf: Data(text.utf8))
        }
    }

    private static func writeFrames(from stream: PhysicalDeviceDisplayStream, owner: SelectedMediaCapture) async throws -> Int {
        let output = try SelectedStreamOutput(descriptor: STDOUT_FILENO)
        let result: Result<Int, Error>
        do {
            var codec = H264RTPDepacketizer(payloadType: stream.rtpPayloadType)
            let packetTimeout: Duration = .seconds(12)
            let firstFrameDeadline = ContinuousClock.now + packetTimeout
            var packetDeadline = firstFrameDeadline
            var written = 0
            while !owner.stopRequested {
                try Task.checkCancellation()
                let now = ContinuousClock.now
                if written == 0, now >= firstFrameDeadline {
                    let failure = await stream.stallFailure()
                    guard failure.code == "deviceStreamReplaced" else {
                        throw CLIOutputFailure(code: "deviceStreamUnavailable",
                            message: "The device did not send a complete H.264 keyframe.")
                    }
                    throw failure
                }
                if now >= packetDeadline {
                    throw await stream.stallFailure()
                }
                let datagram: Data
                do {
                    datagram = try await stream.receive(timeout: 1)
                } catch DeviceServiceError.timeout {
                    continue
                }
                packetDeadline = .now + packetTimeout
                guard let frame = try codec.accept(datagram) else { continue }
                guard try await output.write(frame, stopRequested: { owner.stopRequested }) else { break }
                written += 1
            }
            guard written > 0 else {
                throw CLIOutputFailure(code: "deviceStreamUnavailable",
                    message: "The stream stopped before a complete H.264 frame was written.")
            }
            result = .success(written)
        } catch {
            result = .failure(error)
        }
        try output.restore()
        return try result.get()
    }
}
