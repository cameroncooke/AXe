import Foundation

/// What a mirror host started without `--udid` does to this Mac's simulators on a viewer's behalf:
/// lists them, creates one and boots one. All of it goes through `xcrun simctl`, the public tool,
/// so the host does to a simulator exactly what a person at the Mac's terminal would.
enum MirrorSimulatorControl {
    /// Booting takes a few seconds on a simulator that has run before and over a minute on a new one.
    static let bootTimeout: TimeInterval = 300

    // MARK: Reading simctl's list

    private struct Listing: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
            let deviceTypeIdentifier: String?
            let lastUsedAt: String?
        }
        struct DeviceType: Decodable {
            let identifier: String
            let name: String
            let productFamily: String?
        }
        struct Runtime: Decodable {
            let identifier: String
            let name: String
            let platform: String?
            let version: String?
            let isAvailable: Bool?
            let supportedDeviceTypes: [DeviceType]?
        }
        let devices: [String: [Device]]
        let runtimes: [Runtime]
        let devicetypes: [DeviceType]?
    }

    /// The viewer's list, from the output of `simctl list --json`. Only iOS runtimes that can be
    /// used and iPhone and iPad devices are kept: the mirror shows nothing else. Runtimes are
    /// newest first; simctl lists one twice when two copies are installed, and it is kept once.
    /// Simulators are running ones first, then by name.
    static func list(fromSimctl data: Data) throws -> MirrorSimulatorList {
        let listing: Listing
        do {
            listing = try JSONDecoder().decode(Listing.self, from: data)
        } catch {
            throw CLIError(errorDescription: "Could not read the simulator list from simctl.", code: .readFailed)
        }
        var modelNames: [String: String] = [:]
        for type in listing.devicetypes ?? [] { modelNames[type.identifier] = type.name }
        var runtimes: [(version: [Int], runtime: MirrorRuntime)] = []
        for runtime in listing.runtimes where runtime.platform == "iOS" && runtime.isAvailable != false {
            guard !runtimes.contains(where: { $0.runtime.id == runtime.identifier }) else { continue }
            let types = (runtime.supportedDeviceTypes ?? []).compactMap { type -> MirrorDeviceType? in
                modelNames[type.identifier] = type.name
                guard let family = type.productFamily, family == "iPhone" || family == "iPad" else { return nil }
                return MirrorDeviceType(id: type.identifier, name: type.name, family: family)
            }
            let version = (runtime.version ?? "").split(separator: ".").map { Int($0) ?? 0 }
            runtimes.append((version, MirrorRuntime(id: runtime.identifier, name: runtime.name, deviceTypes: types)))
        }
        // A stable sort: two runtimes of one version keep simctl's order.
        let newestFirst = runtimes.enumerated().sorted { first, second in
            first.element.version == second.element.version ? first.offset < second.offset
                : second.element.version.lexicographicallyPrecedes(first.element.version)
        }.map(\.element.runtime)

        var simulators: [MirrorSimulator] = []
        for runtime in newestFirst {
            for device in listing.devices[runtime.id] ?? [] where device.isAvailable != false {
                let model = device.deviceTypeIdentifier.flatMap { modelNames[$0] } ?? device.name
                simulators.append(MirrorSimulator(udid: device.udid, name: device.name, booted: device.state == "Booted",
                                                  model: model, os: runtime.name, lastUsed: device.lastUsedAt))
            }
        }
        simulators.sort { first, second in
            if first.booted != second.booted { return first.booted }
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.udid < second.udid : order == .orderedAscending
        }
        return MirrorSimulatorList(simulators: simulators, runtimes: newestFirst.filter { !$0.deviceTypes.isEmpty })
    }

    // MARK: Acting on simulators

    static func list() async throws -> MirrorSimulatorList {
        try list(fromSimctl: await simctl(["list", "--json"], timeout: 30))
    }

    /// Creates a simulator and returns it. The device and the runtime must be a pair from the list
    /// the viewer was sent, so a viewer cannot have simctl try anything else.
    static func create(name: String?, deviceType: String?, runtime: String?) async throws -> MirrorSimulator {
        let available = try await list()
        guard let chosenRuntime = available.runtimes.first(where: { $0.id == runtime }),
              let chosenType = chosenRuntime.deviceTypes.first(where: { $0.id == deviceType }) else {
            throw CLIError(errorDescription: "That device and iOS version cannot be combined on this Mac.", code: .commandFailed)
        }
        guard let given = MirrorSimulatorChoice.usableName(name ?? "") else {
            throw CLIError(errorDescription: "A simulator's name is one line of at most \(MirrorSimulatorChoice.nameLimit) characters and does not start with a hyphen.", code: .commandFailed)
        }
        let finalName = given.isEmpty ? chosenType.name : given
        let output = try await simctl(["create", finalName, chosenType.id, chosenRuntime.id], timeout: 120)
        let udid = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: udid) != nil else {
            throw CLIError(errorDescription: "simctl created a simulator but did not say which.", code: .readFailed)
        }
        return MirrorSimulator(udid: udid, name: finalName, booted: false, model: chosenType.name, os: chosenRuntime.name)
    }

    /// Boots the simulator if it is not running and waits until it has finished starting. Returns
    /// at once for one that already has.
    static func boot(udid: String) async throws {
        guard UUID(uuidString: udid) != nil else {
            throw CLIError(errorDescription: "\(udid) is not a simulator's UDID.", code: .commandFailed)
        }
        // `bootstatus -b` boots a simulator that is shut down and returns when the system is up.
        _ = try await simctl(["bootstatus", udid, "-b"], timeout: bootTimeout)
    }

    /// Shuts a simulator down and returns once it has stopped. One that is not running is left alone.
    static func shutDown(_ simulator: MirrorSimulator) async throws {
        guard simulator.booted else { return }
        _ = try await simctl(["shutdown", simulator.udid], timeout: 60)
    }

    /// Shuts a simulator down even if it no longer answers: simctl first, and if that fails or has
    /// not finished in 30 seconds, the simulator's own launchd and every process under it are
    /// killed, as quitting Simulator.app by force does. Killing the launchd alone left its other
    /// processes behind, and the next boot did not finish (seen with a frozen simulator). Returns
    /// once simctl lists it as shut down. Nothing in the simulator's files is lost.
    static func forceShutDown(udid: String) async throws {
        guard UUID(uuidString: udid) != nil else {
            throw CLIError(errorDescription: "\(udid) is not a simulator's UDID.", code: .commandFailed)
        }
        // The tree is read before the shutdown: once the launchd is gone its children belong to
        // launchd and cannot be told from others. Whatever of it outlives the shutdown is killed,
        // however the shutdown went: simctl reported a frozen simulator shut down while its
        // processes were still there, and the next boot did not finish.
        let bootstrap = "CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"
        let tree = descendants(of: processes(matching: bootstrap))
        let stopped = (try? await simctl(["shutdown", udid], timeout: 30)) != nil
        for pid in tree.reversed() where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        if stopped { return }
        for _ in 0..<40 {
            if try await state(of: udid) == "Shutdown" { return }
            for pid in processes(matching: "CoreSimulator/Devices/\(udid)/") { kill(pid, SIGKILL) }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CLIError(errorDescription: "The simulator did not stop, even when forced. Quit Simulator.app and try again.", code: .timeout)
    }

    /// Whether the simulator starts a process within a few seconds. It takes about 0.2 s on one that
    /// is running well; a frozen simulator never does.
    /// Its output goes nowhere: simctl hands its own to the process it starts in the simulator, and
    /// in a frozen one that process never exits, so a pipe read here would never end.
    static func answers(udid: String) async -> Bool {
        let process = Process()
        if let simctlPath {
            process.executableURL = URL(fileURLWithPath: simctlPath)
            process.arguments = ["spawn", udid, "/usr/bin/true"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "spawn", udid, "/usr/bin/true"]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            let once = Run()
            func finish(_ answered: Bool) {
                var first = false
                once.set { if !$0.expired { $0.expired = true; first = true } }
                if first { continuation.resume(returning: answered) }
            }
            process.terminationHandler = { finished in
                finish(finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do { try process.run() } catch { finish(false); return }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                guard process.isRunning else { return }
                kill(pid, SIGKILL)
                finish(false)
            }
        }
    }

    /// simctl's state for one simulator, such as Booted or Shutdown.
    static func state(of udid: String) async throws -> String? {
        let data = try await simctl(["list", "devices", "--json"], timeout: 30)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        for list in devices.values {
            if let device = list.first(where: { ($0["udid"] as? String) == udid }) { return device["state"] as? String }
        }
        return nil
    }

    /// `roots` and every process under them, parents before children, from one `ps` listing.
    private static func descendants(of roots: [pid_t]) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return roots }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var found: [pid_t] = []
        var queue = roots
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            found.append(pid)
            queue.append(contentsOf: children[pid] ?? [])
        }
        return found.filter { $0 > 1 && $0 != getpid() }
    }

    /// The IDs of the processes whose command line contains `text`.
    private static func processes(matching text: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", text]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let own = getpid()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.filter { $0 != own }
    }

    /// Deletes a simulator and everything in it. It is shut down first if it is running.
    static func delete(_ simulator: MirrorSimulator) async throws {
        try await shutDown(simulator)
        _ = try await simctl(["delete", simulator.udid], timeout: 120)
    }

    // MARK: simctl

    /// What one run of simctl leaves behind besides its output, written from more than one thread.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (expired: false, errors: Data())
        func set(_ change: (inout (expired: Bool, errors: Data)) -> Void) { lock.withLock { change(&state) } }
        func read() -> (expired: Bool, errors: Data) { lock.withLock { state } }
    }

    /// The simctl of the selected Xcode, found once with `xcrun -f`. It is run directly rather
    /// than through xcrun, which starts it as a child: ending xcrun at a timeout left simctl running
    /// with the output open, waiting on a frozen simulator for ever.
    ///
    /// The path is found once and kept, and found again when the file is no longer there: updating
    /// Xcode while the host runs removes the old one, and every simctl call then failed until the
    /// host was restarted (seen on 21 November 2026).
    private static var simctlPath: String? {
        simctlLock.lock()
        defer { simctlLock.unlock() }
        if let known = simctlKnown, FileManager.default.isExecutableFile(atPath: known) { return known }
        simctlKnown = findSimctl()
        return simctlKnown
    }
    private static let simctlLock = NSLock()
    nonisolated(unsafe) private static var simctlKnown: String?

    private static func findSimctl() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "simctl"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs simctl and returns what it printed. Ends it at `timeout`.
    static func simctl(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        let process = Process()
        if let simctlPath {
            process.executableURL = URL(fileURLWithPath: simctlPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments
        }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let command = arguments.first ?? "command"
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CLIError(errorDescription: "Could not start xcrun simctl. Select Xcode with xcode-select.", code: .xcodeUnavailable))
                    return
                }
                let run = Run()
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    run.set { $0.expired = true }
                    process.terminate()
                    // simctl waiting on a frozen simulator can ignore the request to stop.
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Both pipes are read to their end while the process runs, so it never waits on a full one.
                let errorsRead = DispatchGroup()
                errorsRead.enter()
                DispatchQueue.global().async {
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    run.set { $0.errors = data }
                    errorsRead.leave()
                }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                errorsRead.wait()
                process.waitUntilExit()
                deadline.cancel()
                let (expired, errorData) = run.read()
                if expired {
                    continuation.resume(throwing: CLIError(errorDescription: "simctl \(command) did not finish within \(Int(timeout)) seconds.", code: .timeout))
                } else if process.terminationReason == .exit, process.terminationStatus == 0 {
                    continuation.resume(returning: outputData)
                } else {
                    let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: CLIError(errorDescription: "simctl \(command) failed (\(process.terminationStatus)): \(detail)", code: .commandFailed))
                }
            }
        }
    }
}
