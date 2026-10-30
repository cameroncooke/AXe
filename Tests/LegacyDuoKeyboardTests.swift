import Darwin
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Legacy Duo keyboard file boundary")
struct LegacyDuoKeyboardTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }
    private func payloadURL(_ value: LegacyDuoKeyboard, in root: URL) -> URL {
        root.appendingPathComponent("legacy-keyboard-\(value.requestID.uuidString).json")
    }
    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: "fixture", bootIdentity: "boot-one",
            screenID: 3, screenUniqueID: "00000000-0000-0000-0000-000000000003", axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0),
            poseRevision: "pose-one")
    }
    private func request(_ value: LegacyDuoKeyboard) throws -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: value.requestID,
            screenID: 3, screenUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000003"),
            operation: .complete, token: nil, primitives: [],
            expectedContext: SelectedHIDContext(try observation()), legacyKeyboard: value)
    }

    @Test("Raw input larger than the socket and selected keyboard limits remains exact")
    func uncappedRoundTrip() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent("fixture.sock").path
        let events = try TextToHIDEvents.convertTextToHIDEvents(String(repeating: "aQ7", count: 1500))
        let value = try LegacyDuoKeyboard.prepare(.composite(events), requestID: UUID(), endpoint: endpoint)
        #expect(value.byteCount > HIDBroker.maximumMessageBytes)
        #expect(events.count > SelectedKeyboardRequest.maximumEvents)
        let wire = try JSONEncoder().encode(request(value))
        #expect(wire.count < HIDBroker.maximumMessageBytes)
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: wire)
        try decoded.validate()
        let file = try #require(decoded.legacyKeyboard)
        let actual = try await file.consume(endpoint: endpoint)
        #expect(FBSimulatorHIDEvent.composite(actual.map(\.event)) == .composite(events))
        #expect(!FileManager.default.fileExists(atPath: payloadURL(value, in: root).path))
        try value.removeIfOwned(endpoint: endpoint)
    }

    @Test("Repeated modifiers and the existing long key-sequence delays are unchanged")
    func legacyEventSemantics() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent("fixture.sock").path
        let modifiers: [UInt32] = [4, 4, 255, 0, 224, 1, 225, 225]
        var events = modifiers.map { FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: $0) }
            + [.keyboard(direction: .down, keyCode: 225), .keyboard(direction: .up, keyCode: 225)]
            + modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
        for index in 0..<100 {
            events += [.keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4)]
            if index < 99 { events.append(.delay(5)) }
        }
        let value = try LegacyDuoKeyboard.prepare(.composite(events), requestID: UUID(), endpoint: endpoint)
        let actual = try await value.consume(endpoint: endpoint)
        #expect(FBSimulatorHIDEvent.composite(actual.map(\.event)) == .composite(events))
    }

    @Test(arguments: ["content", "mode", "hardlink", "inode", "symlink", "size"])
    func unsafeFileIsRejected(fault: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent("fixture.sock").path
        let value = try LegacyDuoKeyboard.prepare(.shortKeyPress(4), requestID: UUID(), endpoint: endpoint)
        let url = payloadURL(value, in: root)
        switch fault {
        case "content":
            var before = stat(); try #require(lstat(url.path, &before) == 0)
            var data = try Data(contentsOf: url)
            let codes = data.indices.filter { data[$0] == 52 }
            try #require(codes.count == 2)
            for index in codes { data[index] = 53 }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: data); try handle.close()
            var after = stat(); try #require(lstat(url.path, &after) == 0)
            try #require(after.st_dev == before.st_dev && after.st_ino == before.st_ino
                && after.st_size == before.st_size)
            let changed = try JSONDecoder().decode([SelectedKeyboardPrimitive].self, from: data)
            try #require(FBSimulatorHIDEvent.composite(changed.map(\.event)) == .shortKeyPress(5))
        case "mode": #expect(chmod(url.path, 0o644) == 0)
        case "hardlink":
            #expect(link(url.path, root.appendingPathComponent("second-link").path) == 0)
        case "inode", "symlink":
            let original = root.appendingPathComponent("original")
            try FileManager.default.moveItem(at: url, to: original)
            if fault == "symlink" { try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original) }
            else {
                try Data("replacement".utf8).write(to: url)
                #expect(chmod(url.path, 0o600) == 0)
            }
        default:
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0); try handle.close()
        }
        await #expect(throws: (any Error).self) { _ = try await value.consume(endpoint: endpoint) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        if fault == "inode" || fault == "symlink" {
            #expect(throws: (any Error).self) { try value.removeIfOwned(endpoint: endpoint) }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Invalid input is rejected before a payload file exists")
    func invalidEventAndDirectory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent("fixture.sock").path
        let invalid: [FBSimulatorHIDEvent] = [.keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .down, keyCode: 4), .shortKeyPress(256), .tapAt(x: 1, y: 2),
            .composite([.keyboard(direction: .down, keyCode: 4), .delay(.nan), .keyboard(direction: .up, keyCode: 4)])]
        for event in invalid {
            #expect(throws: (any Error).self) { _ = try LegacyDuoKeyboard.prepare(event, requestID: UUID(), endpoint: endpoint) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: (any Error).self) { _ = try LegacyDuoKeyboard.prepare(.shortKeyPress(4), requestID: UUID(), endpoint: endpoint) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("The file identity, measured context and single payload must match the request")
    func mixedAndOldWireCannotEnter() throws {
        let value = LegacyDuoKeyboard(requestID: UUID(), device: 1, inode: 1,
            byteCount: 1, sha256: String(repeating: "a", count: 64))
        let clean = try request(value)
        try clean.validate()
        var invalid: [SelectedHIDRequest] = []
        var mixed = clean; mixed.expectedContext = nil; invalid.append(mixed)
        mixed = clean; mixed.keyboard = .init(expectedPID: 42, focusID: "field", events: [.down(4), .up(4)]); invalid.append(mixed)
        invalid.append(SelectedHIDRequest(version: clean.version, requestID: clean.requestID,
            screenID: clean.screenID, screenUUID: clean.screenUUID, operation: clean.operation,
            token: clean.token, primitives: [.touch(.down, x: 1, y: 2)],
            expectedContext: clean.expectedContext, legacyKeyboard: value))
        mixed = clean; mixed.legacyKeyboard = .init(requestID: UUID(), device: 1, inode: 1,
            byteCount: 1, sha256: String(repeating: "a", count: 64)); invalid.append(mixed)
        invalid.append(SelectedHIDRequest(version: 35, requestID: value.requestID, screenID: clean.screenID,
            screenUUID: clean.screenUUID, operation: .complete, token: nil, primitives: [],
            expectedContext: clean.expectedContext, legacyKeyboard: value))
        for input in invalid {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try admission.enter(input) }
            #expect(!admission.inFlight)
        }
    }

    @Test("A busy admission leaves the exact file for client cleanup")
    func busyDoesNotConsumePayload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appendingPathComponent("fixture.sock").path
        let value = try LegacyDuoKeyboard.prepare(.shortKeyPress(4), requestID: UUID(), endpoint: endpoint)
        let input = try request(value)
        var admission = SelectedHIDAdmission()
        try admission.enter(input)
        #expect(throws: (any Error).self) { try admission.enter(input) }
        #expect(FileManager.default.fileExists(atPath: payloadURL(value, in: root).path))
        try value.removeIfOwned(endpoint: endpoint)
        #expect(!FileManager.default.fileExists(atPath: payloadURL(value, in: root).path))
    }

    @Test("A write-half-close cancels and joins the operation while its reply remains readable")
    @MainActor func cancelledPeerCanReceiveJoinedCleanup() async throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw HIDBroker.posixError("socketpair") }
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        var pending: Task<Bool, Never>?
        await withCheckedContinuation { started in
            pending = Task { @MainActor in
                await SelectedHIDClientLifetime.run(descriptor: descriptors[0]) {
                    started.resume()
                    do { try await Task.sleep(for: .seconds(30)); return false }
                    catch { return Task.isCancelled }
                }
            }
        }
        #expect(Darwin.shutdown(descriptors[1], SHUT_WR) == 0)
        let task = try #require(pending)
        #expect(await task.value)
        try HIDBroker.writeAll(Data("joined-cleanup\n".utf8), to: descriptors[0])
        #expect(try HIDBroker.readMessage(from: descriptors[1]) == Data("joined-cleanup".utf8))
    }
}
