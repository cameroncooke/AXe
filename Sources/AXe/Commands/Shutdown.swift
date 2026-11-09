import ArgumentParser
import Darwin
import Foundation

struct Shutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Shut down one simulator and confirm its Shutdown state. This is not a lock or power-button action.")

    @Option(name: .customLong("udid"), help: "Exact simulator UUID. Names, booted and all are not accepted.")
    var simulatorUDID: String

    func validate() throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID) { return }
        guard UUID(uuidString: simulatorUDID) != nil else {
            throw ValidationError("shutdown requires --udid with one valid simulator UUID.")
        }
    }

    func run() async throws {
        try AutomationTarget.refuseOnDevice(simulatorUDID, "AXe cannot shut down a physical device.")
        guard let udid = UUID(uuidString: simulatorUDID) else {
            throw ValidationError("shutdown requires --udid with one valid simulator UUID.")
        }
        let output = try await SimulatorShutdown.run(udid: udid)
        try DeviceState.emit(output, text: [output.text])
    }
}

/// `outcome` is `shutDown`, after a fresh read confirmed the request, or `alreadyShutDown`, when
/// the first read found the simulator shut down and no request was sent.
struct ShutdownOutput: Encodable, Sendable {
    let udid: String
    let initialState: String
    let outcome: String

    var text: String {
        outcome == "alreadyShutDown" ? "\(udid) was already shut down" : "Shut down \(udid) (was \(initialState))"
    }
}

/// Use only the public simctl command. No simulator input session or private framework is needed.
@MainActor
private enum SimulatorShutdown {
    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: UUID
            let state: String
        }
        let devices: [String: [Device]]
    }

    static func run(udid: UUID) async throws -> ShutdownOutput {
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        let initialState = try await state(of: udid, deadline: deadline)
        if initialState == "Shutdown" {
            return ShutdownOutput(udid: udid.uuidString, initialState: initialState, outcome: "alreadyShutDown")
        }

        do {
            _ = try await simctl(["shutdown", udid.uuidString], deadline: deadline)
            while try await state(of: udid, deadline: deadline) != "Shutdown" {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            throw CLIError(errorDescription: "The simulator shutdown was not confirmed: " + CLIErrorMapping.failure(for: error).message + " The request was not repeated; check the simulator state before another request.", code: .actionOutcomeUnknown)
        }
        return ShutdownOutput(udid: udid.uuidString, initialState: initialState, outcome: "shutDown")
    }

    private static func state(of udid: UUID, deadline: TimeInterval) async throws -> String {
        let data = try await simctl(["list", "devices", "--json"], deadline: deadline)
        let inventory: DeviceList
        do {
            inventory = try JSONDecoder().decode(DeviceList.self, from: data)
        } catch {
            throw CLIError(errorDescription: "Could not read the simulator list from simctl.", code: .readFailed)
        }
        let matches = inventory.devices.values.flatMap { $0 }.filter { $0.udid == udid }
        guard let device = matches.first else {
            throw CLIError.simulatorNotFound(udid: udid.uuidString)
        }
        guard matches.count == 1 else {
            throw CLIError(errorDescription: "simctl returned more than one device for UUID \(udid.uuidString).", code: .readFailed)
        }
        return device.state
    }

    private static func simctl(_ arguments: [String], deadline: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw CLIError(errorDescription: "The 60-second simulator shutdown deadline expired.", code: .timeout)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("axe-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CLIError(errorDescription: "Could not create simctl output files.", code: .outputFailed)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw CLIError(errorDescription: "The 60-second simulator shutdown deadline expired.", code: .timeout)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            stop(process)
            throw error
        }
        process.waitUntilExit()
        try Task.checkCancellation()

        // Regular files avoid pipe backpressure while the child runs. Bound reads before allocation.
        let outputData = try read(outputURL, limit: 4 * 1024 * 1024)
        let errorData = try read(errorURL, limit: 64 * 1024)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(errorDescription: "simctl \(arguments.first ?? "command") failed (\(process.terminationStatus)): \(detail)")
        }
        return outputData
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw CLIError(errorDescription: "simctl output exceeded its read limit.", code: .readFailed)
        }
        return data
    }

    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
