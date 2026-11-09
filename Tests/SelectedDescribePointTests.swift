import ArgumentParser
import Foundation
import Testing
@testable import AXe

@Suite("Selected describe point")
struct SelectedDescribePointTests {
    private let selected = ["--udid", "TEST", "--input-mode", "selected", "--screen-id", "3",
        "--screen-uuid", "769ED878-389B-4346-9C56-CB0703AB3E58", "--expected-pid", "42"]

    @Test func selectedPointProducesOneReadOnlyPayload() throws {
        let command = try DescribeUI.parse(selected + ["--point", "150,250"])
        let request = try command.selectedRequest()
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request))
        try decoded.validate()
        #expect(decoded.version == SelectedHIDRequest.version && decoded.ax?.kind == .describePoint)
        #expect(decoded.ax?.point?.x == 150 && decoded.ax?.point?.y == 250)
        #expect(decoded.ax?.expectedPID == 42)
        #expect(decoded.operation == .complete && decoded.token == nil && decoded.primitives.isEmpty)
        #expect(decoded.ax?.selector == nil && decoded.path == nil && decoded.keyboard == nil)
    }

    @Test func wholeTreeAndLegacyPointKeepTheirModes() throws {
        let tree = try DescribeUI.parse(selected).selectedRequest()
        #expect(tree.ax?.kind == .describe && tree.ax?.point == nil)
        let legacy = try DescribeUI.parse(["--udid", "TEST", "--point", "10,20"])
        #expect(legacy.selectedInput.mode == .legacy)
        #expect(throws: (any Error).self) { _ = try legacy.selectedRequest() }
    }

    @Test(arguments: ["", "1", "1,2,3", "-1,2", "1,-2", "nan,2", "1,inf"])
    func malformedPointIsRejected(_ point: String) {
        #expect(throws: (any Error).self) { _ = try DescribeUI.parse(selected + ["--point", point]) }
    }

    @Test func selectedPointBindsActiveScreenAndFrontmostAppWhenOmitted() throws {
        let unbound = try DescribeUI.parse(["--udid", "TEST", "--input-mode", "selected", "--point", "10,20"])
            .selectedRequest()
        #expect(unbound.activeDisplay == true && unbound.screenID == nil && unbound.screenUUID == nil)
        #expect(unbound.ax?.expectedPID == nil && unbound.ax?.kind == .describePoint)
        let withoutPID = try DescribeUI.parse(Array(selected.dropLast(2)) + ["--point", "10,20"]).selectedRequest()
        #expect(withoutPID.screenID == 3 && withoutPID.activeDisplay == nil && withoutPID.ax?.expectedPID == nil)
        for args in [
            selected + ["--point", "10,20", "--expected-pid", "0"],
            ["--udid", "TEST", "--input-mode", "selected", "--screen-id", "3", "--point", "10,20"]
        ] {
            #expect(throws: (any Error).self) { _ = try DescribeUI.parse(args) }
        }
    }

    @Test func pointPayloadCannotEnterActionOrTreeKinds() throws {
        for kind in [SelectedAXRequest.Kind.describe, .tap, .semanticPress, .sliderEndpoint] {
            let request = SelectedAXRequest(kind: kind, expectedPID: 42,
                endpoint: kind == .sliderEndpoint ? .minimum : nil,
                selectorKind: kind == .describe ? nil : .id,
                selectorValue: kind == .describe ? nil : "feature.switch", preDelay: 0, postDelay: 0,
                point: .init(x: 10, y: 20))
            #expect(throws: (any Error).self) { try request.validate() }
        }
        for request in [
            SelectedAXRequest(kind: .describePoint, expectedPID: 42,
                endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 0),
            SelectedAXRequest(kind: .describePoint, expectedPID: 42,
                endpoint: nil, selectorKind: .id, selectorValue: "x", preDelay: 0, postDelay: 0, point: .init(x: 1, y: 2)),
            SelectedAXRequest(kind: .describePoint, expectedPID: 42,
                endpoint: nil, selectorKind: nil, selectorValue: nil, preDelay: 0, postDelay: 1, point: .init(x: 1, y: 2))
        ] {
            #expect(throws: (any Error).self) { try request.validate() }
        }
    }

    @Test func pointReadRejectsOldWireTouchAndRetainedToken() throws {
        let valid = try DescribeUI.parse(selected + ["--point", "150,250"]).selectedRequest()
        for request in [
            SelectedHIDRequest(version: 10, requestID: UUID(), screenID: valid.screenID,
                screenUUID: valid.screenUUID, operation: .complete, token: nil, primitives: [], ax: valid.ax),
            SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: valid.screenID,
                screenUUID: valid.screenUUID, operation: .complete, token: nil,
                primitives: [.touch(.down, x: 150, y: 250)], ax: valid.ax),
            SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(), screenID: valid.screenID,
                screenUUID: valid.screenUUID, operation: .complete, token: UUID(), primitives: [], ax: valid.ax)
        ] {
            #expect(throws: (any Error).self) { try request.validate() }
        }
        var owned = SelectedHIDAdmission()
        try owned.enter(valid)
        #expect(throws: (any Error).self) { try owned.enter(valid) }
        #expect(owned.inFlight)
        owned.finish()
        try owned.enter(valid)
    }
}
