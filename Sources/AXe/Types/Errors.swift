import Foundation

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
    let errorDescription: String

    init(errorDescription: String) {
        self.errorDescription = errorDescription
    }

    static func simulatorNotFound(udid: String) -> CLIError {
        CLIError(
            errorDescription: "No simulator with UDID \(udid) was found. Run `axe list-simulators` to see available simulators."
        )
    }

    var userFacingDescription: String {
        errorDescription
    }
}
