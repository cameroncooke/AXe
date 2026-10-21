import Darwin
import Foundation
import FBControlCore

/// Persistent fail-closed record. A new process must not erase an uncertain result.
/// Only a caller that holds the common per-device input lease can create this record.
enum HIDInputQuarantine {
    struct Record: Codable {
        let schemaVersion: Int
        let simulatorUDID: UUID
        let developerDirectory: String
        let bootIdentity: String
        let screenID: UInt32?
        let screenUUID: String?
        let requestID: UUID
        let brokerID: UUID
        let reason: String
        let diagnostic: String?
        let diagnosticTruncated: Bool
        let context: SelectedHIDContext?
        var hinge: SelectedHingeQuarantineContext? = nil
        var observationCleanup: SelectedHingeObservationQuarantineContext? = nil
        let originalRequest: SelectedHIDRequest?
    }
    static func fileURL(simulatorUDID: String) throws -> URL {
        // Shared with every candidate input lease, independent of protocol/Xcode version.
        let endpoint = try HIDBroker.endpointPath(simulatorUDID: simulatorUDID,
            developerDirectory: "/candidate-device-input", version: 3)
        return URL(fileURLWithPath: endpoint + ".quarantine.json")
    }
    static func requireClear(simulatorUDID: String) throws {
        let url = try fileURL(simulatorUDID: simulatorUDID)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw SelectedHIDFailure.invalid("Cannot inspect input quarantine: " + url.path)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 256 * 1024 else {
            throw SelectedHIDFailure.invalid("Invalid input quarantine record; device remains blocked: " + url.path)
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= 64 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw SelectedHIDFailure.invalid("Input quarantine read failed") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count <= 64 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: bytes),
              valid(record, simulatorUDID: simulatorUDID) else {
            throw SelectedHIDFailure.invalid("Malformed input quarantine; device remains blocked: " + url.path)
        }
        throw SelectedHIDFailure.invalid("Device input is quarantined after " + record.reason + "; inspect " + url.path)
    }
    static func valid(_ record: Record, simulatorUDID: String) -> Bool {
        guard record.simulatorUDID == UUID(uuidString: simulatorUDID),
              record.developerDirectory.hasPrefix("/"), !record.bootIdentity.isEmpty,
              !record.reason.isEmpty else { return false }
        if record.schemaVersion == 1 {
            return record.observationCleanup == nil && record.hinge == nil && record.context?.bootIdentity == record.bootIdentity
        }
        if record.schemaVersion == 3 {
            guard record.reason == "observationCleanupUnconfirmed", record.context == nil, record.hinge == nil,
                  record.screenID == nil, record.screenUUID == nil, let observation = record.observationCleanup,
                  observation.expectedBootIdentity == record.bootIdentity,
                  observation.mechanicalReceipt.expectedBootIdentity == record.bootIdentity,
                  observation.readinessReceipt.expectedBootIdentity == record.bootIdentity,
                  observation.readinessReceipt.outcome == .incomplete,
                  observation.readinessReceipt.cleanup == .unconfirmed,
                  observation.readinessReceipt.failure?.code == .observationCleanupUnconfirmed,
                  let original = record.originalRequest?.hinge, original.kind == .set,
                  original.expectedBootIdentity == record.bootIdentity,
                  original.degrees == observation.mechanicalReceipt.requestedDegrees,
                  original.readiness?.screenID == observation.readinessReceipt.expected.screenID,
                  original.readiness?.screenUUID == observation.readinessReceipt.expected.screenUUID,
                  original.readiness?.timeoutSeconds == observation.readinessReceipt.expected.timeoutSeconds else { return false }
            return (try? original.validate()) != nil
        }
        guard record.schemaVersion == 2, record.observationCleanup == nil else { return false }
        if let context = record.context {
            return record.hinge == nil && context.bootIdentity == record.bootIdentity
        }
        guard let hinge = record.hinge, record.screenID == nil, record.screenUUID == nil,
              hinge.expectedBootIdentity == record.bootIdentity,
              hinge.before?.bootIdentity == record.bootIdentity,
              hinge.requestedDegrees.isFinite, (0...180).contains(hinge.requestedDegrees),
              let original = record.originalRequest?.hinge, original.kind == .set,
              original.expectedBootIdentity == record.bootIdentity,
              original.degrees == hinge.requestedDegrees else { return false }
        return (try? original.validate()) != nil
    }

    static func persist(simulatorUDID: String, response: SelectedHIDResponse, request: SelectedHIDRequest?) throws {
        guard let udid = UUID(uuidString: simulatorUDID) else { throw SelectedHIDFailure.invalid("Invalid quarantine UDID") }
        let context = response.context
        let hinge: SelectedHingeQuarantineContext?
        let observationCleanup: SelectedHingeObservationQuarantineContext?
        let boot: String
        let reason: String
        if response.hinge?.readiness?.cleanup == .unconfirmed {
            guard context == nil, response.hinge?.failure == nil,
                  let original = request?.hinge, original.kind == .set,
                  let expectedBoot = original.expectedBootIdentity,
                  let mechanical = response.hinge?.receipt, mechanical.expectedBootIdentity == expectedBoot,
                  mechanical.requestedDegrees == original.degrees,
                  let readiness = response.hinge?.readiness,
                  readiness.expectedBootIdentity == expectedBoot, readiness.outcome == .incomplete,
                  readiness.failure?.code == .observationCleanupUnconfirmed,
                  original.readiness?.screenID == readiness.expected.screenID,
                  original.readiness?.screenUUID == readiness.expected.screenUUID,
                  original.readiness?.timeoutSeconds == readiness.expected.timeoutSeconds else {
                throw SelectedHIDFailure.invalid("Missing completed hinge and unconfirmed observer cleanup context")
            }
            try original.validate()
            boot = expectedBoot; reason = "observationCleanupUnconfirmed"; hinge = nil
            observationCleanup = SelectedHingeObservationQuarantineContext(expectedBootIdentity: expectedBoot,
                mechanicalReceipt: mechanical, readinessReceipt: readiness)
        } else if response.hinge?.failure?.delivery == .uncertain {
            guard context == nil, let original = request?.hinge, original.kind == .set,
                  let expectedBoot = original.expectedBootIdentity, let degrees = original.degrees,
                  response.hinge?.readback?.bootIdentity == expectedBoot else {
                throw SelectedHIDFailure.invalid("Missing original hinge quarantine context")
            }
            try original.validate()
            boot = expectedBoot; reason = "uncertainHingeDelivery"
            hinge = SelectedHingeQuarantineContext(expectedBootIdentity: expectedBoot, requestedDegrees: degrees,
                before: response.hinge?.readback, latestSample: response.hinge?.failure?.latestSample)
            observationCleanup = nil
        } else {
            guard let context else { throw SelectedHIDFailure.invalid("Missing original quarantine context") }
            boot = context.bootIdentity; hinge = nil; observationCleanup = nil
            if response.rotation?.failure?.delivery == .uncertain { reason = "uncertainRotationDelivery" }
            else { reason = response.ax?.slider?.delivery == "uncertain" ? "uncertainAXAction" : "uncertainInputCleanup" }
        }
        let url = try fileURL(simulatorUDID: udid.uuidString)
        let developer = try FBXcodeDirectory.resolveDeveloperDirectory()
        let record = Record(schemaVersion: observationCleanup == nil ? 2 : 3, simulatorUDID: udid,
            developerDirectory: URL(fileURLWithPath: developer).resolvingSymlinksInPath().path,
            bootIdentity: boot, screenID: context?.screenID,
            screenUUID: context?.screenUUID, requestID: response.requestID, brokerID: response.brokerID,
            reason: reason,
            diagnostic: response.error.map { String($0.prefix(1024)) },
            diagnosticTruncated: (response.error?.count ?? 0) > 1024, context: context, hinge: hinge,
            observationCleanup: observationCleanup, originalRequest: request)
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= 64 * 1024 else { throw SelectedHIDFailure.invalid("Quarantine record exceeds limit") }
        let temporary = url.path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SelectedHIDFailure.invalid("Cannot create input quarantine record") }
        defer { Darwin.close(fd); _ = unlink(temporary) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw SelectedHIDFailure.invalid("Empty quarantine record") }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw SelectedHIDFailure.invalid("Cannot write input quarantine record") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw SelectedHIDFailure.invalid("Cannot flush input quarantine record") }
        // Atomic publication without replacing a prior failure, symlink or malformed record.
        guard link(temporary, url.path) == 0 else {
            throw SelectedHIDFailure.invalid("Input quarantine record already exists or cannot be published: " + url.path)
        }
        guard unlink(temporary) == 0 else { throw SelectedHIDFailure.invalid("Cannot finish input quarantine publication") }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SelectedHIDFailure.invalid("Cannot open input quarantine directory") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw SelectedHIDFailure.invalid("Cannot flush input quarantine directory") }
    }
}
