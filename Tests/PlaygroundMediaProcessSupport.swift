import Foundation
import Testing

/// The observer launches the exact supplied CLI and inventories its dedicated process group.
enum PlaygroundMediaProcess {
    static func start(cli: String, arguments: [String], directory: URL, name: String,
                      phase: String? = nil) throws -> PlaygroundTestProcess {
        let observer = try #require(ProcessInfo.processInfo.environment["AXE_MEDIA_PROCESS_OBSERVER_PATH"])
        let receipt = directory.appendingPathComponent(name + "-ownership.json")
        var options = ["python3", observer, "--receipt", receipt.path]
        if let phase { options += ["--phase", phase] }
        options += ["--", cli] + arguments
        try JSONEncoder().encode([cli] + arguments).write(to: directory.appendingPathComponent(name + "-argv.json"), options: .withoutOverwriting)
        let process = try PlaygroundTestProcess(executable: "/usr/bin/env", arguments: options,
                                                directory: directory, name: name)
        try process.start()
        return process
    }

    static func requireClean(directory: URL, name: String, phase: String? = nil) throws -> MediaProcessReceipt {
        let data = try Data(contentsOf: directory.appendingPathComponent(name + "-ownership.json"))
        let receipt = try JSONDecoder().decode(MediaProcessReceipt.self, from: data)
        try #require(receipt.schemaVersion == 1 && receipt.directCLIReaped && receipt.completeOwnedGroupAbsent && receipt.newSelectedBootGuestHelpersAbsent)
        try #require(receipt.failures.isEmpty && receipt.remaining.isEmpty && receipt.forcedCleanup.isEmpty)
        try #require(!receipt.owned.isEmpty && receipt.owned.contains { $0.pid == receipt.cliPID })
        if let phase {
            let child = try #require(receipt.matchedSignalChild)
            try #require(child.pid != receipt.cliPID && receipt.owned.contains { $0.pid == child.pid })
            try #require(child.signal == (phase == "capture-int" ? 2 : 15))
            let executable = try #require(child.executable)
            let arguments = try #require(child.arguments)
            try #require(URL(fileURLWithPath: executable).lastPathComponent == "simctl")
            try #require(arguments.count >= 6 && arguments[1] == "io" && arguments[3] == "screenshot")
            try #require(arguments[4].hasPrefix("--display=") && arguments[5].hasSuffix("/capture.png"))
        }
        return receipt
    }
}

struct MediaProcessReceipt: Decodable {
    let schemaVersion: Int
    let cliPID: Int32
    let cliExitCode: Int32
    let directCLIReaped: Bool
    let completeOwnedGroupAbsent: Bool
    let newSelectedBootGuestHelpersAbsent: Bool
    let owned: [MediaOwnedProcess]
    let matchedSignalChild: MediaOwnedProcess?
    let forcedCleanup: [MediaForcedCleanup]
    let remaining: [MediaOwnedProcess]
    let failures: [String]
}

struct MediaOwnedProcess: Decodable {
    let pid: Int32
    let ppid: Int32
    let pgid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String?
    let arguments: [String]?
    let signal: Int32?
}

struct MediaForcedCleanup: Decodable { let pid: Int32; let signal: Int32 }
