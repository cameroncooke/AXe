import ArgumentParser
import Foundation

/// The CoreSimulator device set that simulator commands work in. Unset, it is CoreSimulator's
/// default set (`~/Library/Developer/CoreSimulator/Devices`), as before. Set, every simulator lookup
/// and every `simctl` call uses that directory instead, the way `xcrun simctl --set <path>` does.
/// It is kept in the environment, where `--device-set` also puts it, so that the processes AXe
/// starts for itself (the input broker, the slider read worker) inherit it without an argument of
/// their own.
enum SimulatorDeviceSet {
    static let environmentKey = "AXE_DEVICE_SET_PATH"
    static let option = "--device-set"

    /// The directory named by `AXE_DEVICE_SET_PATH`, or nil for the default set.
    static func path(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let path = directory(raw) else {
            throw CLIOutputFailure(code: "invalidArguments", message: notADirectory(raw, named: environmentKey)
                + " Give the device set's directory, or unset it to use the default set.")
        }
        return path
    }

    /// `raw` as a full path, if a directory is there. CoreSimulator creates a device set at a path
    /// that has none, so a mistyped path would otherwise list no simulators and leave an empty set
    /// behind.
    static func directory(_ raw: String) -> String? {
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    static func notADirectory(_ raw: String, named name: String) -> String {
        "\(name) is \((raw as NSString).expandingTildeInPath), which is not a directory."
    }

    /// Refuses a command that works in the default device set only, when another set is selected.
    /// `reason` says why it cannot follow, as a sentence.
    static func requireDefault(for command: String, _ reason: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard try path(environment: environment) != nil else { return }
        throw CLIOutputFailure(code: "unsupportedInDeviceSet",
            message: "\(command) works in the default device set only. \(reason) Unset \(environmentKey) for this command.")
    }

    /// `devicectl` has no device set option and finds only simulators in the default set.
    static let devicectlReason = "It reaches the simulator through devicectl, which cannot be given a device set; xcrun simctl --set can do this instead."

    /// The `xcrun` arguments for one simctl command in that set: `simctl [--set <path>] <arguments>`.
    static func simctl(_ arguments: [String]) throws -> [String] {
        ["simctl"] + (try setOption()) + arguments
    }

    /// simctl's own option for that set, to go before its command: `--set <path>`, or nothing.
    static func setOption() throws -> [String] {
        try path().map { ["--set", $0] } ?? []
    }

    /// What the path of every file of one simulator contains. In the default set that is its folder
    /// under `CoreSimulator/Devices`; in another set the folder is named by the UDID alone, and the
    /// set's own path may be spelled another way there (through a symbolic link, say).
    static func folderMarker(udid: String) -> String {
        ((try? path()) ?? nil) == nil ? "/CoreSimulator/Devices/\(udid)/" : "/\(udid)/"
    }

    /// Whether a batch step or a serve line carries `--device-set`. The set belongs to the whole
    /// run: one step in another set would move every step after it there too.
    static func isSelected(by options: some Sequence<String>) -> Bool {
        options.contains { $0 == option || $0.hasPrefix(option + "=") }
    }

    static let perStepMessage = "\(option) belongs to the whole run, not to one step: pass it to the command that runs the steps."
}

/// `--device-set <path>`, on every command that can work in another device set. It overrides
/// `AXE_DEVICE_SET_PATH`.
struct SimulatorDeviceSetOptions: ParsableArguments {
    @Option(name: .customLong("device-set"),
            help: ArgumentHelp("Simulators: the directory of the CoreSimulator device set to use, as in xcrun simctl --set. Overrides \(SimulatorDeviceSet.environmentKey); the default set without either.",
                               valueName: "path"))
    var path: String?

    /// Checks the directory and selects it for this process and the processes it starts.
    func validate() throws {
        guard let path else { return }
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ValidationError("\(SimulatorDeviceSet.option) must not be empty.") }
        guard let directory = SimulatorDeviceSet.directory(raw) else {
            throw ValidationError(SimulatorDeviceSet.notADirectory(raw, named: SimulatorDeviceSet.option))
        }
        setenv(SimulatorDeviceSet.environmentKey, directory, 1)
    }
}
