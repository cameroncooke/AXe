import Darwin
import Foundation

@MainActor
final class AccessibilityRecoveryLockLease {
    private var didMarkRecoveryCompleted = false
    private var releaseHandler: (() -> Void)?
    private let markRecoveryCompletedHandler: () throws -> Void
    let generation: AccessibilityRecoveryGeneration

    init(
        generation: AccessibilityRecoveryGeneration = .initial,
        markRecoveryCompletedHandler: @escaping () throws -> Void = {},
        releaseHandler: @escaping () -> Void
    ) {
        self.generation = generation
        self.markRecoveryCompletedHandler = markRecoveryCompletedHandler
        self.releaseHandler = releaseHandler
    }

    func markRecoveryCompleted() throws {
        guard !didMarkRecoveryCompleted else {
            return
        }
        try markRecoveryCompletedHandler()
        didMarkRecoveryCompleted = true
    }

    func release() {
        releaseHandler?()
        releaseHandler = nil
    }
}

struct AccessibilityRecoveryGeneration: Equatable {
    static let initial = AccessibilityRecoveryGeneration(value: 0)

    let value: Int64
}

enum AccessibilityRecoveryLock {
    typealias Acquirer = @MainActor (String) async throws -> AccessibilityRecoveryLockLease
    typealias GenerationReader = @MainActor (String) throws -> AccessibilityRecoveryGeneration

    private static let retryInterval = Duration.milliseconds(100)
    private static let acquisitionTimeout = Duration.seconds(30)

    @MainActor
    static func acquire(simulatorUDID: String) async throws -> AccessibilityRecoveryLockLease {
        let descriptor = try openLockFile(simulatorUDID: simulatorUDID)
        var ownsDescriptor = true
        defer {
            if ownsDescriptor {
                Darwin.close(descriptor)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: acquisitionTimeout)

        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                let currentGeneration = try generation(descriptor: descriptor)
                ownsDescriptor = false
                return AccessibilityRecoveryLockLease(
                    generation: currentGeneration,
                    markRecoveryCompletedHandler: {
                        var marker: UInt8 = 1
                        guard Darwin.pwrite(descriptor, &marker, 1, currentGeneration.value) == 1 else {
                            throw posixError(
                                "Failed to update accessibility recovery generation",
                                code: errno
                            )
                        }
                        guard Darwin.fsync(descriptor) == 0 else {
                            throw posixError(
                                "Failed to persist accessibility recovery generation",
                                code: errno
                            )
                        }
                    },
                    releaseHandler: {
                        _ = flock(descriptor, LOCK_UN)
                        Darwin.close(descriptor)
                    }
                )
            }

            let lockError = errno
            if lockError == EINTR {
                continue
            }
            guard lockError == EWOULDBLOCK else {
                throw posixError("Failed to lock accessibility recovery state", code: lockError)
            }
            guard clock.now < deadline else {
                throw CLIError(
                    errorDescription: "Timed out waiting for accessibility recovery for simulator \(simulatorUDID)."
                )
            }

            try await Task.sleep(for: retryInterval)
        }
    }

    @MainActor
    static func currentGeneration(simulatorUDID: String) throws -> AccessibilityRecoveryGeneration {
        let descriptor = try openLockFile(simulatorUDID: simulatorUDID)
        defer { Darwin.close(descriptor) }
        return try generation(descriptor: descriptor)
    }

    private static func openLockFile(simulatorUDID: String) throws -> Int32 {
        guard !simulatorUDID.isEmpty,
              simulatorUDID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw CLIError(
                errorDescription: "Invalid simulator UDID for accessibility recovery: \(simulatorUDID)"
            )
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("axe-accessibility-\(getuid())", isDirectory: true)
        try ensurePrivateDirectory(directory)

        let path = directory.appendingPathComponent("bridge-\(simulatorUDID).lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw posixError("Failed to open accessibility recovery lock", code: errno)
        }

        do {
            try validateLockFile(descriptor: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        var metadata = stat()
        if Darwin.lstat(directory.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & 0o077 == 0
            else {
                throw CLIError(
                    errorDescription: "Accessibility recovery directory is not private: \(directory.path)"
                )
            }
            return
        }

        let lookupError = errno
        guard lookupError == ENOENT else {
            throw posixError("Failed to inspect accessibility recovery directory", code: lookupError)
        }
        guard Darwin.mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw posixError("Failed to create accessibility recovery directory", code: errno)
        }

        guard Darwin.lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw CLIError(
                errorDescription: "Accessibility recovery directory is not private: \(directory.path)"
            )
        }
    }

    private static func validateLockFile(descriptor: Int32) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError("Failed to inspect accessibility recovery lock", code: errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw CLIError(errorDescription: "Accessibility recovery lock is not a private regular file.")
        }
    }

    private static func generation(descriptor: Int32) throws -> AccessibilityRecoveryGeneration {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError("Failed to inspect accessibility recovery generation", code: errno)
        }
        return AccessibilityRecoveryGeneration(
            value: metadata.st_size
        )
    }

    private static func posixError(_ message: String, code: Int32) -> CLIError {
        CLIError(errorDescription: "\(message): \(String(cString: strerror(code)))")
    }
}
