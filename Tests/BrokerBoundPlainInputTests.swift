import Foundation
import Testing
import FBSimulatorControl
@testable import AXe

/// A plain command lets a running broker bind the screen instead of measuring it in the client first.
@Suite("Broker-bound plain input")
struct BrokerBoundPlainInputTests {
    private func request(_ payload: SelectedHIDRequest.Payload, operation: SelectedHIDRequest.Operation = .complete) -> SelectedHIDRequest {
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: nil, screenUUID: nil, operation: operation, token: nil, payload: payload)
        request.activeDisplay = true
        request.plainRoute = true
        return request
    }

    private var tap: [SelectedHIDPrimitive] { [.touch(.down, x: 10, y: 20), .touch(.up, x: 10, y: 20)] }
    private var swipe: SelectedHIDPath {
        SelectedHIDPath(kind: .swipe, startX: 200, startY: 600, endX: 200, endY: 300, duration: 0.3, delta: 50, generator: .ordinary)
    }

    @Test("A plain tap, touch or ordinary path needs no measured screen when the broker binds it")
    func acceptedRequests() throws {
        try request(.contact(tap)).validate()
        try request(.path(swipe)).validate()
        try request(.path(SelectedHIDPath(kind: .drag, startX: 1, startY: 2, endX: 3, endY: 4, duration: 1, steps: 10,
            generator: .ordinary))).validate()
        try request(.path(SelectedHIDPath(kind: .draw, duration: 1,
            points: [.init(x: 1, y: 2), .init(x: 30, y: 40)], generator: .ordinary))).validate()
        // After the broker has bound the screen the flag stays and the pair replaces the active-display flag.
        var bound = request(.path(swipe))
        bound.activeDisplay = nil
        bound.screenID = 1
        bound.screenUUID = UUID()
        try bound.validate()
    }

    @Test("Without the flag an ordinary path still needs the client's measured screen")
    func ordinaryPathStillNeedsItsContext() {
        var plain = request(.path(swipe))
        plain.plainRoute = nil
        #expect(throws: SelectedHIDFailure.self) { try plain.validate() }
    }

    @Test("The flag covers one complete contact or ordinary path, and nothing else")
    func refusedRequests() {
        let selectedPath = SelectedHIDPath(kind: .swipe, startX: 200, startY: 600, endX: 200, endY: 300, duration: 0.3, delta: 50)
        let touch = OrdinaryBrokerTouch(x: 1, y: 2, down: true, up: false, delay: nil)
        let refused: [SelectedHIDRequest] = [
            request(.contact([])),
            request(.path(selectedPath)),
            request(.ordinaryTouch(touch)),
            request(.button(SelectedButtonRequest(kind: .home, duration: nil, expectedBoot: nil))),
            request(.contact(tap), operation: .begin),
        ]
        for request in refused {
            #expect(throws: (any Error).self) { try request.validate() }
        }
        var disabled = request(.contact(tap))
        disabled.plainRoute = false
        #expect(throws: SelectedHIDFailure.self) { try disabled.validate() }
        var unbound = request(.contact(tap))
        unbound.activeDisplay = nil
        #expect(throws: SelectedHIDFailure.self) { try unbound.validate() }
    }

    @Test("The flag survives the wire")
    func roundTrip() throws {
        let decoded = try JSONDecoder().decode(SelectedHIDRequest.self, from: JSONEncoder().encode(request(.contact(tap))))
        #expect(decoded.plainRoute == true && decoded.activeDisplay == true)
        try decoded.validate()
    }

    @Test("Only a refusal that sent nothing lets another route take the command")
    func refusalBeforeInput() {
        func response(outcome: String, error: String?, count: Int = 0, cleanup: String = "notNeeded",
                      quarantine: SelectedHIDQuarantine? = nil) -> SelectedHIDResponse {
            var response = SelectedHIDResponse(version: SelectedHIDRequest.version, requestID: UUID(), brokerID: UUID(),
                outcome: outcome, token: nil, enqueuedEventCount: count, cleanup: cleanup, error: error, context: nil)
            response.quarantine = quarantine
            return response
        }
        #expect(OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "rejectedBeforeInput", error: "No.")))
        #expect(!OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "enqueuedAndDrained", error: nil, count: 2)))
        #expect(!OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "rejectedBeforeInput", error: "No.", count: 1)))
        #expect(!OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "interrupted", error: "Stopped.")))
        #expect(!OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "rejectedBeforeInput", error: "No.", cleanup: "uncertain")))
        #expect(!OrdinaryBrokerInput.refusedBeforeInput(response(outcome: "rejectedBeforeInput", error: "No.",
            quarantine: SelectedHIDQuarantine(recordPath: nil, persisted: false, error: nil))))
    }

    @Test("A complete touch is one contact with its hold, and a tap keeps its style")
    func contacts() throws {
        let held = OrdinaryBrokerInput.touchPrimitives(x: 5, y: 6, hold: 0.4)
        #expect(FBSimulatorHIDEvent.composite(held.map(\.event))
            == (try OrdinaryBrokerTouch(x: 5, y: 6, down: true, up: true, delay: 0.4).event()))
        let standard = OrdinaryBrokerInput.touchPrimitives(x: 5, y: 6, hold: nil)
        #expect(FBSimulatorHIDEvent.composite(standard.map(\.event))
            == (try OrdinaryBrokerTouch(x: 5, y: 6, down: true, up: true, delay: nil).event()))
        #expect(OrdinaryBrokerInput.touchPrimitives(x: 5, y: 6, hold: 0).map(\.kind) == [.down, .up])
        #expect(FBSimulatorHIDEvent.composite(try OrdinaryBrokerInput.tapPrimitives(.simulator, at: (x: 10, y: 20)).map(\.event))
            == .tapAt(x: 10, y: 20))
        #expect(FBSimulatorHIDEvent.composite(try OrdinaryBrokerInput.tapPrimitives(.physical, at: (x: 10, y: 20)).map(\.event))
            == .tapAt(x: 10, y: 20, duration: TapTiming.defaultHoldDuration))
        #expect(throws: SelectedHIDFailure.self) { try OrdinaryBrokerInput.tapPrimitives(.automatic, at: (x: 1, y: 2)) }
    }

    @Test("A preset the broker lays out is the swipe the plain command would have measured")
    func presetLayout() throws {
        let size = CGSize(width: 402, height: 874)
        for (preset, inset, distance) in [(GesturePreset.scrollUp, nil, nil), (.scrollDown, nil, 0.4),
                                          (.swipeFromLeftEdge, 12.0, nil), (.swipeFromTopRightCorner, nil, nil)] as [(GesturePreset, Double?, Double?)] {
            let path = SelectedHIDPath(kind: .preset, preset: preset, duration: preset.defaultDuration,
                delta: preset.defaultDelta, edgeInset: inset, distance: distance, generator: .ordinary)
            try path.validate()
            let points = preset.coordinates(screenWidth: 402, screenHeight: 874, edgeInset: inset, distance: distance)
            #expect(try path.event(logicalSize: size) == .swipe(points.startX, yStart: points.startY,
                xEnd: points.endX, yEnd: points.endY, delta: preset.defaultDelta, duration: preset.defaultDuration))
        }
    }

    @Test("An ordinary preset carries no endpoints, screen size or rest, and an inset must leave room")
    func presetLimits() throws {
        var path = SelectedHIDPath(kind: .preset, preset: .scrollUp, duration: 0.5, delta: 50, generator: .ordinary)
        try path.validate()
        path.startX = 10
        #expect(throws: SelectedHIDFailure.self) { try path.validate() }
        path.startX = nil
        path.expectedWidth = 402
        #expect(throws: SelectedHIDFailure.self) { try path.validate() }
        path.expectedWidth = nil
        path.endsAtRest = true
        #expect(throws: SelectedHIDFailure.self) { try path.validate() }
        #expect(throws: SelectedHIDFailure.self) {
            try SelectedHIDPath(kind: .preset, duration: 0.5, delta: 50, generator: .ordinary).validate()
        }
        // An inset that leaves a span shorter than one move is refused on the screen it is laid out on.
        let tight = SelectedHIDPath(kind: .preset, preset: .swipeFromLeftEdge, duration: 0.5, delta: 5_000, edgeInset: 1,
            generator: .ordinary)
        try tight.validate()
        #expect(throws: (any Error).self) { try tight.event(logicalSize: CGSize(width: 402, height: 874)) }
    }

    @Test("Connecting to a running broker never starts one")
    func runningBrokerOnly() throws {
        let missing = try HIDBroker.connectToRunningBroker(endpoint: "/tmp/axe-no-such-broker.sock",
            connector: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) })
        #expect(missing == nil)
        let refused = try HIDBroker.connectToRunningBroker(endpoint: "/tmp/axe-no-such-broker.sock",
            connector: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)) })
        #expect(refused == nil)
    }
}
