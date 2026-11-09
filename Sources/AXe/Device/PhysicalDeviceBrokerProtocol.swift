import Darwin
import Dispatch
import Foundation

enum PhysicalDeviceBrokerOperation: Codable, Sendable {
    case display
    case keepAlive
    case touch([PhysicalTouchStep], display: PhysicalDeviceDisplay?, allowPartial: Bool, deadlineUptime: UInt64?)
    case keys([PhysicalKeyStep])
    case button(PhysicalDeviceButton, hold: Double, allowLock: Bool)
    case rotate(PhysicalRotationDirection, timeout: Double)
    case tree(timeout: Double)
    case semanticPress(identifier: String)

    var sendsInput: Bool {
        switch self {
        case .display, .tree, .keepAlive: false
        case .touch, .keys, .button, .rotate, .semanticPress: true
        }
    }

    var timeoutMilliseconds: Int {
        guard case let .keys(steps) = self else { return PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds }
        let delay = steps.reduce(0) { $0 + $1.delayAfter }
        guard delay.isFinite, delay >= 0, delay <= 600 else {
            return PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds
        }
        return max(PhysicalDeviceBrokerProtocol.operationTimeoutMilliseconds, Int(ceil(delay * 1000)) + 30_000)
    }

    func validate() throws {
        let duration: Double
        switch self {
        case let .touch(steps, _, _, _):
            guard (1...8_192).contains(steps.count) else { throw Self.invalidOperation }
            duration = steps.reduce(0) { $0 + $1.delayAfter }
        case let .keys(steps):
            guard (1...8_192).contains(steps.count) else { throw Self.invalidOperation }
            let delay = steps.reduce(0) { $0 + $1.delayAfter }
            guard delay.isFinite, (0...600).contains(delay) else { throw Self.invalidOperation }
            return
        case let .button(button, hold, allowLock):
            guard button != .lock || allowLock else {
                throw AutomationTarget.unsupportedOnDevice("Physical lock requires --allow-lock.")
            }
            duration = hold
        case let .rotate(_, timeout), let .tree(timeout):
            duration = timeout
        case let .semanticPress(identifier):
            guard !identifier.isEmpty, identifier.utf8.count <= 4_096,
                  identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CLIOutputFailure(code: "invalidArguments", message: "Supply one nonempty exact checkbox ID.")
            }
            duration = 0
        case .display, .keepAlive:
            duration = 0
        }
        guard duration.isFinite, (0...60).contains(duration) else { throw Self.invalidOperation }
    }

    private static var invalidOperation: CLIOutputFailure {
        CLIOutputFailure(code: "invalidArguments", message: "The device broker operation exceeds its input limits.")
    }
}

enum PhysicalDeviceBrokerValue: Codable, Sendable {
    case done
    case display(PhysicalDeviceDisplay)
    case tree(Data, display: PhysicalDeviceDisplay)
    case semanticPress(PhysicalSemanticPressReceipt)
}

enum PhysicalDeviceBrokerProtocol {
    static let version = 1
    static let commandName = "physical-device-broker"
    static let maximumFrameBytes = 16 * 1024 * 1024
    static let frameTimeoutMilliseconds = 3_000
    static let operationTimeoutMilliseconds = 90_000
    static let closeTimeoutMilliseconds = 20_000
    static let leaseIdleMilliseconds = 60_000

    static func endpoint(udid: String) throws -> String {
        try HIDBroker.endpointPath(simulatorUDID: udid.uppercased(),
            developerDirectory: "/physical-device-broker", version: version)
    }

    static var busy: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBusy", message: "Another AXe command owns this physical device.")
    }

    static var unavailable: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBrokerUnavailable", message: "The physical device broker connection is unavailable.")
    }

    static var mismatch: CLIOutputFailure {
        CLIOutputFailure(code: "deviceBrokerMismatch",
            message: "A different AXe build owns the physical device broker. Wait for it to exit before trying again.")
    }

    static var outcomeUnknown: CLIOutputFailure {
        CLIOutputFailure(code: "inputOutcomeUnknown",
            message: "AXe could not confirm the result of the device input request. Check the device before sending more input.")
    }

    struct BuildIdentity: Codable, Equatable, Sendable {
        let executable: String
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        static func current() throws -> Self {
            guard let url = Bundle.main.executableURL else { throw unavailable }
            let executable = url.resolvingSymlinksInPath().path
            var info = stat()
            guard lstat(executable, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw unavailable }
            return Self(executable: executable, device: info.st_dev, inode: info.st_ino,
                bytes: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }
    }

    struct Hello: Codable, Sendable {
        let version: Int
        let workerPID: Int32
        let build: BuildIdentity
        let udid: String
        let failure: Failure?
    }

    enum Request: Codable, Sendable {
        case open
        case operation(UUID, PhysicalDeviceBrokerOperation)
        case close
    }

    enum Response: Codable, Sendable {
        case opened(Failure?)
        case value(UUID, PhysicalDeviceBrokerValue)
        case failed(UUID, Failure)
        case closed(Failure?)
    }

    struct Failure: Codable, Sendable {
        let code: String
        let message: String

        init(_ error: Error) {
            if let failure = error as? CLIOutputFailure {
                code = failure.code
                message = String(failure.message.prefix(1_024))
            } else if error is CancellationError {
                code = "deviceOperationInterrupted"
                message = "The device operation was interrupted."
            } else {
                code = "deviceOperationFailed"
                let detail = (error as? UserFacingError)?.userFacingDescription ?? error.localizedDescription
                message = String(detail.prefix(1_024))
            }
        }

        var error: CLIOutputFailure {
            CLIOutputFailure(code: code, message: message)
        }
    }
}
