import Foundation
import Testing
@testable import AXe

@Suite("Simulator device set override")
struct SimulatorDeviceSetTests {
    private let key = SimulatorDeviceSet.environmentKey

    @Test("Unset or blank, the default device set is used", arguments: [nil, "", "   "] as [String?])
    func unsetMeansDefaultSet(_ value: String?) throws {
        let environment = value.map { [key: $0] } ?? [:]
        #expect(try SimulatorDeviceSet.path(environment: environment) == nil)
        try SimulatorDeviceSet.requireDefault(for: "axe settings", SimulatorDeviceSet.devicectlReason, environment: environment)
    }

    @Test("An existing directory is used as given, standardized")
    func existingDirectoryIsUsed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axe-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let given = directory.path + "/./"
        #expect(try SimulatorDeviceSet.path(environment: [key: given]) == directory.standardizedFileURL.path)
    }

    @Test("A path that is not a directory is refused rather than created")
    func missingDirectoryIsRefused() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("axe-set-\(UUID().uuidString)").path
        #expect(throws: CLIOutputFailure.self) { try SimulatorDeviceSet.path(environment: [key: missing]) }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test("Commands that work in the default set only are refused in another")
    func defaultOnlyCommandsAreRefused() {
        let directory = FileManager.default.temporaryDirectory.path
        #expect(throws: CLIOutputFailure.self) {
            try SimulatorDeviceSet.requireDefault(for: "axe settings", SimulatorDeviceSet.devicectlReason, environment: [key: directory])
        }
    }

    // A flag that names a directory selects it for the whole process, which other tests share, so
    // only the refusals are parsed here; the accepted path is covered by `directory` above.
    @Test("--device-set refuses a path that is not a directory, and an empty one", arguments: ["", "/nonexistent/axe-device-set"])
    func flagRefusesBadPaths(_ value: String) {
        #expect(throws: (any Error).self) { try SimulatorDeviceSetOptions.parse(["--device-set", value]) }
        #expect(!FileManager.default.fileExists(atPath: "/nonexistent/axe-device-set"))
    }

    @Test("Without --device-set the flag changes nothing")
    func flagIsOptional() throws {
        #expect(try SimulatorDeviceSetOptions.parse([]).path == nil)
    }

    // In the default set, which is what the tests run in: the folder the forced shutdown has always matched.
    @Test("A simulator's processes are found by its folder in the default set")
    func defaultSetFolderMarker() {
        #expect(SimulatorDeviceSet.folderMarker(udid: "ABC") == "/CoreSimulator/Devices/ABC/")
    }

    @Test("A step may not choose its own device set")
    func stepsMayNotSelectASet() {
        #expect(SimulatorDeviceSet.isSelected(by: ["--label", "General", "--device-set", "/tmp"]))
        #expect(SimulatorDeviceSet.isSelected(by: ["--device-set=/tmp"]))
        #expect(!SimulatorDeviceSet.isSelected(by: ["--label", "--device-settings"]))
        guard case .refused = ServeProtocol.parse("tap --label General --device-set /tmp", simulatorUDID: "X") else {
            Issue.record("serve accepted --device-set in a line")
            return
        }
    }
}
