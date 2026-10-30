import CryptoKit
import Darwin
import Foundation
import FBSimulatorControl

/// The socket carries only an identity. Raw keyboard input keeps its existing size and timing contract.
struct LegacyDuoKeyboard: Codable, Sendable {
    let requestID: UUID
    let device: Int32
    let inode: UInt64
    let byteCount: Int
    let sha256: String

    private static let io = DispatchQueue(label: "axe.legacy-keyboard.file")
    private var filename: String { "legacy-keyboard-\(requestID.uuidString).json" }

    func validate(requestID expected: UUID) throws {
        guard requestID == expected, byteCount > 0, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SelectedHIDFailure.invalid("Invalid legacy keyboard payload identity")
        }
    }

    static func prepare(_ event: FBSimulatorHIDEvent, requestID: UUID, endpoint: String) throws -> Self {
        let events = try primitives(from: event)
        try validate(events)
        let data = try JSONEncoder().encode(events)
        let directory = try openDirectory(endpoint: endpoint)
        defer { Darwin.close(directory) }
        let filename = "legacy-keyboard-\(requestID.uuidString).json"
        let descriptor = Darwin.openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HIDBroker.posixError("create keyboard payload") }
        var identity: stat?
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete {
                if let identity {
                    try? remove(directory: directory, filename: filename, device: identity.st_dev, inode: identity.st_ino)
                } else {
                    // No payload bytes are written before the first identity check.
                    try? removeEmptyCreatedFile(directory: directory, filename: filename)
                }
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw HIDBroker.posixError("chmod keyboard payload") }
        var created = stat()
        guard fstat(descriptor, &created) == 0 else { throw HIDBroker.posixError("fstat keyboard payload") }
        identity = created
        try validateFile(created)
        try HIDBroker.writeAll(data, to: descriptor)
        var written = stat()
        guard fstat(descriptor, &written) == 0 else { throw HIDBroker.posixError("fstat keyboard payload") }
        try validateFile(written)
        guard written.st_dev == created.st_dev, written.st_ino == created.st_ino,
              written.st_size == Int64(data.count) else {
            throw SelectedHIDFailure.invalid("Legacy keyboard payload changed while writing")
        }
        complete = true
        return Self(requestID: requestID, device: written.st_dev, inode: written.st_ino,
            byteCount: data.count, sha256: digest(data))
    }

    /// Join the file read before returning. Cancellation is checked again before any native work.
    func consume(endpoint: String) async throws -> [SelectedKeyboardPrimitive] {
        try await withCheckedThrowingContinuation { continuation in
            Self.io.async { continuation.resume(with: Result { try readAndRemove(endpoint: endpoint) }) }
        }
    }

    func removeIfOwned(endpoint: String) throws {
        let directory = try Self.openDirectory(endpoint: endpoint)
        defer { Darwin.close(directory) }
        try Self.remove(directory: directory, filename: filename, device: device, inode: inode)
    }

    private func readAndRemove(endpoint: String) throws -> [SelectedKeyboardPrimitive] {
        try validate(requestID: requestID)
        let directory = try Self.openDirectory(endpoint: endpoint)
        defer { Darwin.close(directory) }
        let descriptor = Darwin.openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HIDBroker.posixError("open keyboard payload") }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw HIDBroker.posixError("fstat keyboard payload") }
        try Self.validateFile(before)
        guard before.st_dev == device, before.st_ino == inode, before.st_size == Int64(byteCount) else {
            throw SelectedHIDFailure.invalid("Legacy keyboard payload file identity changed")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < byteCount {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, byteCount - data.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SelectedHIDFailure.invalid("Legacy keyboard payload is incomplete") }
            data.append(contentsOf: buffer[..<count])
        }
        var extra: UInt8 = 0
        var extraCount: Int
        repeat { extraCount = Darwin.read(descriptor, &extra, 1) } while extraCount < 0 && errno == EINTR
        guard extraCount == 0 else { throw SelectedHIDFailure.invalid("Legacy keyboard payload size changed") }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw HIDBroker.posixError("fstat keyboard payload") }
        try Self.validateFile(after)
        guard after.st_dev == device, after.st_ino == inode, after.st_size == Int64(byteCount),
              Self.digest(data) == sha256 else {
            throw SelectedHIDFailure.invalid("Legacy keyboard payload content changed")
        }
        let events = try JSONDecoder().decode([SelectedKeyboardPrimitive].self, from: data)
        try Self.validate(events)
        // Remove only the exact submitted inode, before the owner can open or send input.
        try Self.remove(directory: directory, filename: filename, device: device, inode: inode, missingIsOK: false)
        return events
    }

    private static func openDirectory(endpoint: String) throws -> Int32 {
        let root = URL(fileURLWithPath: endpoint).deletingLastPathComponent().path
        let descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HIDBroker.posixError("open keyboard payload directory") }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw HIDBroker.posixError("fstat keyboard payload directory") }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  info.st_mode & 0o7777 == 0o700 else {
                throw SelectedHIDFailure.invalid("Legacy keyboard payload directory must be owned and mode 0700")
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    private static func validateFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            throw SelectedHIDFailure.invalid("Legacy keyboard payload must be one owned regular file with mode 0600")
        }
    }

    private static func remove(directory: Int32, filename: String, device: Int32, inode: UInt64, missingIsOK: Bool = true) throws {
        var info = stat()
        if fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT, missingIsOK { return }
            throw HIDBroker.posixError("stat keyboard payload")
        }
        try validateFile(info)
        guard info.st_dev == device, info.st_ino == inode else {
            throw SelectedHIDFailure.invalid("Refusing to remove a replaced legacy keyboard payload")
        }
        guard unlinkat(directory, filename, 0) == 0 else { throw HIDBroker.posixError("unlink keyboard payload") }
    }

    private static func removeEmptyCreatedFile(directory: Int32, filename: String) throws {
        var info = stat()
        guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw HIDBroker.posixError("stat empty keyboard payload")
        }
        try validateFile(info)
        guard info.st_size == 0 else { throw SelectedHIDFailure.invalid("Refusing to remove changed keyboard payload") }
        try remove(directory: directory, filename: filename, device: info.st_dev, inode: info.st_ino)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func primitives(from event: FBSimulatorHIDEvent) throws -> [SelectedKeyboardPrimitive] {
        var result: [SelectedKeyboardPrimitive] = []
        func append(_ value: FBSimulatorHIDEvent) throws {
            switch value {
            case .keyboard(.down, let code): result.append(.down(code))
            case .keyboard(.up, let code): result.append(.up(code))
            case .delay(let seconds): result.append(.delay(seconds))
            case .composite(let children): for child in children { try append(child) }
            default: throw SelectedHIDFailure.invalid("Legacy keyboard payload cannot contain other input")
            }
        }
        try append(event)
        return result
    }

    private static func validate(_ events: [SelectedKeyboardPrimitive]) throws {
        var held: [UInt32: Int] = [:]
        var downs = 0
        for event in events {
            switch event {
            case .down(let code):
                guard code <= 255 else { throw SelectedHIDFailure.invalid("Legacy keyboard keycode is invalid") }
                held[code, default: 0] += 1
                downs += 1
            case .up(let code):
                guard code <= 255, let count = held[code], count > 0 else {
                    throw SelectedHIDFailure.invalid("Legacy keyboard release has no matching key down")
                }
                if count == 1 { held.removeValue(forKey: code) }
                else { held[code] = count - 1 }
            case .delay(let seconds):
                guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) / 1_000_000_000 else {
                    throw SelectedHIDFailure.invalid("Legacy keyboard delay is invalid")
                }
            }
        }
        guard downs > 0, held.isEmpty else {
            throw SelectedHIDFailure.invalid("Legacy keyboard payload must release every key")
        }
    }
}
