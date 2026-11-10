import Darwin
import Foundation
import FBSimulatorControl
import Testing
@testable import AXe

@Suite("Ordinary broker keyboard payload")
struct OrdinaryBrokerKeyboardTests {
    private func observation() throws -> FBSimulatorHIDSessionObservation {
        try FBSimulatorHIDSessionObservation(simulatorUDID: "fixture", bootIdentity: "boot-one",
            screenID: 3, screenUniqueID: "00000000-0000-0000-0000-000000000003", axDisplayID: 3,
            displayContext: FBSimulatorHIDDisplayContext(hidTarget: 3,
                nativePixelSize: CGSize(width: 300, height: 600), scale: 3, rotation: .rot0),
            poseRevision: "pose-one")
    }
    private func request(_ value: OrdinaryBrokerKeyboard) throws -> SelectedHIDRequest {
        SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: 3, screenUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000003"),
            operation: .complete, token: nil, payload: .ordinaryKeyboard(value),
            expectedContext: SelectedHIDContext(try observation()))
    }

    /// Writes `data` and a newline into one end of a socket pair and reads it as the broker does.
    private func brokerRead(_ data: Data) throws -> SelectedHIDRequest {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw HIDBroker.posixError("socketpair") }
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let writer = Thread { try? HIDBroker.writeAll(data + Data([10]), to: descriptors[0]) }
        writer.start()
        return try SelectedHIDBroker.readRequest(from: descriptors[1])
    }

    @Test("Long ordinary text crosses the broker socket in one message with exactly its events")
    func longTextRoundTripsThroughTheBrokerRead() throws {
        let text = String(repeating: "aQ7", count: 20_000)
        let events = try TextToHIDEvents.convertTextToHIDEvents(text)
        let value = try OrdinaryBrokerKeyboard(.composite(events))
        let original = try KeyboardPrimitives.from(.composite(events), limits: .ordinary)
        // The enum encoding the file side channel carried would not fit one 64 KiB message.
        #expect(try JSONEncoder().encode(original).count > 16 * HIDBroker.maximumMessageBytes)
        let wire = try JSONEncoder().encode(request(value))
        #expect(wire.count > HIDBroker.maximumMessageBytes && wire.count < OrdinaryBrokerKeyboard.maximumMessageBytes)
        let decoded = try brokerRead(wire)
        try decoded.validate()
        let keyboard = try #require(decoded.ordinaryKeyboard)
        #expect(keyboard == value)
        // The same events in the same order, with no delay added or dropped, keep the typing timing.
        #expect(FBSimulatorHIDEvent.composite(try keyboard.primitives().map(\.event))
            == FBSimulatorHIDEvent.composite(original.map(\.event)))
        #expect(keyboard.delays.isEmpty && keyboard.keys.count == original.count)
    }

    @Test("Only ordinary keyboard input may exceed 64 KiB on the broker socket")
    func largeOtherRequestIsRefused() throws {
        var tap = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: 3,
            screenUUID: UUID(), operation: .complete, token: nil,
            payload: .contact([.touch(.down, x: 1, y: 1), .touch(.up, x: 1, y: 1)]))
        tap.timing = true
        let small = try JSONEncoder().encode(tap)
        #expect(try brokerRead(small).requestID == tap.requestID)
        // Unknown keys decode, so padding makes a valid request larger than the bound.
        var padded = try #require(String(data: small, encoding: .utf8))
        padded.removeLast()
        padded += ",\"padding\":\"" + String(repeating: "x", count: HIDBroker.maximumMessageBytes) + "\"}"
        #expect(throws: (any Error).self) { _ = try brokerRead(Data(padded.utf8)) }
    }

    @Test("Repeated modifiers and the existing long key-sequence delays are unchanged")
    func legacyEventSemantics() throws {
        let modifiers: [UInt32] = [4, 4, 255, 0, 224, 1, 225, 225]
        var events = modifiers.map { FBSimulatorHIDEvent.keyboard(direction: .down, keyCode: $0) }
            + [.keyboard(direction: .down, keyCode: 225), .keyboard(direction: .up, keyCode: 225)]
            + modifiers.reversed().map { .keyboard(direction: .up, keyCode: $0) }
        for index in 0..<100 {
            events += [.keyboard(direction: .down, keyCode: 4), .keyboard(direction: .up, keyCode: 4)]
            if index < 99 { events.append(.delay(5)) }
        }
        let value = try OrdinaryBrokerKeyboard(.composite(events))
        let decoded = try JSONDecoder().decode(OrdinaryBrokerKeyboard.self, from: JSONEncoder().encode(value))
        #expect(FBSimulatorHIDEvent.composite(try decoded.primitives().map(\.event)) == .composite(events))
        #expect(decoded.delays == Array(repeating: 5, count: 99))
    }

    @Test("Invalid input is rejected before a request exists")
    func invalidEvent() throws {
        let invalid: [FBSimulatorHIDEvent] = [.keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .down, keyCode: 4), .shortKeyPress(256), .tapAt(x: 1, y: 2),
            .composite([.keyboard(direction: .down, keyCode: 4), .delay(.nan), .keyboard(direction: .up, keyCode: 4)])]
        for event in invalid {
            #expect(throws: (any Error).self) { _ = try OrdinaryBrokerKeyboard(event) }
        }
    }

    @Test("A changed payload is refused before the owner sends input", arguments: [
        #"{"keys":[4,600],"delays":[]}"#, #"{"keys":[4,-1,260],"delays":[]}"#,
        #"{"keys":[4,260],"delays":[1]}"#, #"{"keys":[260,4],"delays":[]}"#,
        #"{"keys":[4],"delays":[]}"#, #"{"keys":[-1],"delays":[1]}"#, #"{"keys":[4,-1,260],"delays":[-1]}"#,
    ])
    func changedPayloadIsRefused(json: String) throws {
        let value = try JSONDecoder().decode(OrdinaryBrokerKeyboard.self, from: Data(json.utf8))
        #expect(throws: (any Error).self) { try value.validate() }
        #expect(throws: (any Error).self) { try request(value).validate() }
    }

    @Test("The measured context and single payload must match the request")
    func mixedAndOldWireCannotEnter() throws {
        let value = try OrdinaryBrokerKeyboard(.shortKeyPress(4))
        let clean = try request(value)
        try clean.validate()
        var invalid: [SelectedHIDRequest] = []
        var unmeasured = clean; unmeasured.expectedContext = nil; invalid.append(unmeasured)
        invalid.append(SelectedHIDRequest(version: 35, requestID: clean.requestID, screenID: clean.screenID,
            screenUUID: clean.screenUUID, operation: .complete, token: nil, payload: .ordinaryKeyboard(value),
            expectedContext: clean.expectedContext))
        for input in invalid {
            var admission = SelectedHIDAdmission()
            #expect(throws: (any Error).self) { try admission.enter(input) }
            #expect(!admission.inFlight)
        }
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
