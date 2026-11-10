import ArgumentParser
import Darwin
import Foundation
import FBSimulatorControl

// MARK: - Error Types
protocol UserFacingError: Error, CustomStringConvertible {
    var userFacingDescription: String { get }
}

extension UserFacingError {
    var description: String {
        userFacingDescription
    }
}

struct CLIError: LocalizedError, UserFacingError {
    /// The `error.code` a JSON result reports. Keep this list small and documented in README
    /// "Output format"; prefer an existing code for the same condition.
    enum Code: String, Sendable {
        case commandFailed, invalidArguments, targetNotFound, notBooted, busy, timeout, interrupted
        case inputUnavailable, inputFailed, rejectedBeforeInput, cleanupUncertain
        case treeUnavailable, elementNotFound, ambiguousElement, screenChanged
        case captureFailed, outputFailed, readFailed, actionOutcomeUnknown, xcodeUnavailable
    }

    let code: Code
    let errorDescription: String

    init(errorDescription: String, code: Code = .commandFailed) {
        self.errorDescription = errorDescription
        self.code = code
    }

    static func simulatorNotFound(udid: String) -> CLIError {
        CLIError(
            errorDescription: "No simulator with UDID \(udid) was found. Run `axe list-simulators` to see available simulators.",
            code: .targetNotFound
        )
    }

    var userFacingDescription: String {
        errorDescription
    }
}

/// The one place a thrown error becomes what the user sees: a code and a sentence, never a Swift
/// type dump. The plain and `--output` paths both use it.
enum CLIErrorMapping {
    /// Errors ArgumentParser renders itself: help, usage and exit codes, including its internal
    /// help request that `axe help <command>` throws from `run()`.
    static func isArgumentParserError(_ error: Error) -> Bool {
        error is ValidationError || error is CleanExit || error is ExitCode
            || String(reflecting: type(of: error)).hasPrefix("ArgumentParser.")
    }

    /// A cancellation caused by SIGINT or SIGTERM, which exits with 128 + the signal.
    static func interruptionExitCode(for error: Error) -> Int32? {
        guard failure(for: error).code == CLIError.Code.interrupted.rawValue,
              let signal = SignalObserver.lastReceivedSignal else { return nil }
        return 128 + signal
    }

    static func failure(for error: Error) -> CLIOutputFailure {
        switch error {
        case let known as CLIOutputFailure:
            return known
        case let known as AgentModeFailure:
            return CLIOutputFailure(code: known.code, message: known.message)
        case let known as CLIError:
            return CLIOutputFailure(code: known.code.rawValue, message: known.errorDescription)
        case let known as ValidationError:
            return CLIOutputFailure(code: "invalidArguments", message: known.message)
        case is CancellationError:
            return interrupted
        case let known as ElementResolutionError:
            let code: String
            switch known {
            case .notFound: code = "elementNotFound"
            case .multipleMatches, .multipleSwitchDescendants: code = "ambiguousElement"
            case .invalidFrame: code = "elementNotHittable"
            }
            return CLIOutputFailure(code: code, message: known.userFacingDescription)
        case let known as SelectedHIDFailure:
            switch known {
            case .busy: return DeviceStateFailure.busy
            case .invalidToken: return CLIOutputFailure(code: "invalidArguments", message: sentence(known.errorDescription))
            case .selectionChanged: return CLIOutputFailure(code: "screenChanged", message: sentence(known.errorDescription))
            case .invalid(let message):
                return CLIOutputFailure(code: "rejectedBeforeInput", message: sentence(message) + " No input was sent.")
            case .coded(let code, let message):
                return CLIOutputFailure(code: code, message: sentence(message) + " No input was sent.")
            }
        case is HIDBrokerAdmissionFailure:
            return DeviceStateFailure.busy
        case let known as FBSimulatorContextError:
            switch known {
            case .changedDuringRead:
                return CLIOutputFailure(code: "screensDidNotSettle", message: "The screens changed while AXe read them. Read them again.")
            case .unavailable(let detail):
                return CLIOutputFailure(code: "displayUnavailable",
                    message: "The simulator display state could not be read: " + sentence(detail))
            @unknown default:
                return CLIOutputFailure(code: "displayUnavailable", message: "The simulator display state could not be read.")
            }
        case let known as FBSimulatorSelectedScreenshotError:
            switch known {
            case .changedContext:
                return CLIOutputFailure(code: "screenChanged", message: "The screen changed during capture. Run axe displays and try again.")
            case .wrongDimensions:
                return CLIOutputFailure(code: "screenChanged", message: "The screen size changed during capture. Run axe displays and try again.")
            case .invalidPNG:
                return CLIOutputFailure(code: "captureFailed", message: "The simulator returned an invalid PNG.")
            case .invalidRequest:
                return CLIOutputFailure(code: "invalidArguments", message: "The screen selection is invalid. Pass the active screen's id and uuid from axe displays.")
            @unknown default:
                return CLIOutputFailure(code: "captureFailed", message: "The capture failed.")
            }
        case let known as ActivePanelReadError:
            if known.childFailure == .cancelled { return interrupted }
            if known.childFailure == .deadline {
                return CLIOutputFailure(code: "timeout", message: "Reading the simulator screens timed out. Try again.")
            }
            if let validation = known.validationFailure { return failure(for: validation) }
            return CLIOutputFailure(code: "displayUnavailable", message: "The simulator screens could not be read. Try again.")
        case let known as ActivePanelValidationError:
            switch known {
            case .inactiveSelection, .selectedGeometryMismatch, .selectedRotationMismatch:
                return CLIOutputFailure(code: "screenChanged",
                    message: "The selected screen is not the active screen in that orientation. Run axe displays and pass the active screen.")
            default:
                return CLIOutputFailure(code: "displayUnavailable", message: "The simulator reported an inconsistent screen layout. Try again.")
            }
        case let known as FBSimulatorHIDSessionError:
            switch known {
            case .busy: return DeviceStateFailure.busy
            case .interrupted(let reason, let cleanup):
                if cleanup == .uncertain {
                    return CLIOutputFailure(code: "cleanupUncertain",
                        message: "Input stopped and AXe could not confirm that every touch or key was released. Read the screen before trying again.")
                }
                if case .cancelled = reason { return interrupted }
                if case .staleContext = reason {
                    return CLIOutputFailure(code: "screenChanged", message: "The screen changed during input. " + someInputSent)
                }
                return CLIOutputFailure(code: "inputFailed", message: "Input stopped. " + someInputSent)
            default:
                return CLIOutputFailure(code: "inputFailed", message: "Simulator input failed. " + someInputSent)
            }
        case is DecodingError:
            return CLIOutputFailure(code: "readFailed", message: "AXe could not read a response it expected. Try again.")
        default:
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                return CLIOutputFailure(code: "commandFailed", message: description)
            }
            if type(of: error) is NSError.Type {
                return CLIOutputFailure(code: "commandFailed", message: error.localizedDescription)
            }
            return CLIOutputFailure(code: "commandFailed", message: "The command failed unexpectedly.")
        }
    }

    static let interrupted = CLIOutputFailure(code: "interrupted", message: "The command was interrupted.")
    static let someInputSent = "Some input may have been sent; it was not repeated. Read the screen before trying again."

    /// Readable text from a broker or framework detail, or nil when it is a Swift or Objective-C
    /// value dump such as `busy`, `interrupted(reason: …)`, `FBSimulatorHingeFailure(…)` or
    /// `Error Domain=…`. Dumps stay in the `--verbose` receipt.
    static func readable(_ detail: String?) -> String? {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return nil }
        let dump = #"^[a-z][A-Za-z0-9]*(\(.*\))?$|^[A-Z][A-Za-z0-9.]*\(.*\)$|^Error Domain=|FBSimulatorControl\.|FBControlCore\."#
        guard detail.range(of: dump, options: .regularExpression) == nil else { return nil }
        return sentence(detail)
    }

    /// Ends the text with a full stop when it has no closing punctuation.
    static func sentence(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}
