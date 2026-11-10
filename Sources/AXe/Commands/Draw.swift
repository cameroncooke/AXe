import ArgumentParser
import Foundation
import FBSimulatorControl

extension SelectedHIDCompleteGesture.Point: ExpressibleByArgument {
    /// `x,y` in logical points.
    init?(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(x: x, y: y)
    }
}

struct Draw: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move one finger through a list of points to draw a line or shape.",
        discussion: """
        Each point is x,y in logical points in the current orientation, the same units as tap -x -y.
        The finger goes down at the first point, moves in straight lines through every point in order
        and lifts at the last. --close returns to the first point. The whole stroke takes --duration.

        Examples:
          axe draw 100,400 300,400 --udid UDID
          axe draw 200,300 300,480 100,480 --close --duration 1.5 --udid UDID
          axe draw 60,500 120,420 180,500 240,420 300,500 --udid UDID
        """
    )

    static let maximumPoints = 1_000

    @Argument(help: "Two to 1,000 points, each x,y in logical points.")
    var points: [SelectedHIDCompleteGesture.Point] = []

    @Option(name: .customLong("duration"), help: "Seconds the whole stroke takes, in (0, 30] (default 1).")
    var duration: Double = 1

    @Flag(name: .customLong("close"), help: "Return to the first point at the end.")
    var close = false

    @Option(name: .customLong("pre-delay"), help: "Delay before the stroke in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after the stroke in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions

    /// Parsed only to refuse it with a clear message.
    @Flag(name: .customLong("agent"), help: .hidden)
    var agent = false

    /// The points the finger passes, with the first point again at the end for --close.
    var strokePoints: [CGPoint] {
        let given = points.map(\.cgPoint)
        guard close, let first = given.first, given.last != first else { return given }
        return given + [first]
    }

    func validate() throws {
        guard !agent else {
            throw ValidationError("Draw does not support --agent. Pass coordinates; read them with describe-ui.")
        }
        try selectedInput.validate()
        guard (2...Self.maximumPoints).contains(points.count) else {
            throw ValidationError("Draw takes 2 to \(Self.maximumPoints) points, each x,y.")
        }
        if let index = points.firstIndex(where: { !$0.x.isFinite || !$0.y.isFinite || $0.x < 0 || $0.y < 0 }) {
            throw ValidationError("Point \(index + 1) must have finite, non-negative coordinates.")
        }
        do { try TouchStroke.validate(strokePoints) }
        catch { throw ValidationError(CLIErrorMapping.sentence(error.localizedDescription)) }
        guard duration.isFinite, duration > 0, duration <= TouchStroke.maximumDuration else {
            throw ValidationError("Duration must be greater than 0 and at most 30 seconds.")
        }
        for (name, value) in [("Pre-delay", preDelay), ("Post-delay", postDelay)] {
            if let value, !(value.isFinite && (0...10).contains(value)) {
                throw ValidationError("\(name) must be between 0 and 10 seconds.")
            }
        }
    }

    var selectedPath: SelectedHIDPath {
        SelectedHIDPath(kind: .draw, duration: duration, preDelay: preDelay ?? 0, postDelay: postDelay ?? 0,
            points: strokePoints.map { SelectedHIDCompleteGesture.Point(x: $0.x, y: $0.y) })
    }

    func selectedRequest() throws -> SelectedHIDRequest {
        try selectedInput.pathRequest(selectedPath)
    }

    /// The stroke on the direct input route: one composite of physical points.
    func directEvent(through physical: [CGPoint]) -> FBSimulatorHIDEvent {
        .composite(TouchStroke.primitives(through: physical, duration: duration,
            moves: TouchStroke.moveCount(duration: duration),
            initialHold: Drag.initialHold, finalHold: Drag.finalHold).map(\.event))
    }

    /// The direct route reads the app frame once: it bounds the points and maps them to physical points.
    @MainActor
    static func directPoints(_ points: [CGPoint], simulatorUDID: String, logger: AxeLogger) async throws -> [CGPoint] {
        let roots = try await AccessibilityFetcher.fetchAccessibilityElements(for: simulatorUDID, logger: logger)
        guard let frame = OrientationAwareCoordinates.applicationFrame(from: roots) else {
            throw CLIError(errorDescription: "The screen size is unavailable because the accessibility application frame is missing.", code: .readFailed)
        }
        try TouchStroke.requireInside(points, width: frame.width, height: frame.height)
        return try await OrientationAwareCoordinates.translateBatch(points: points.map { (x: $0.x, y: $0.y) },
            roots: roots, for: simulatorUDID, logger: logger).map { CGPoint(x: $0.x, y: $0.y) }
    }

    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agent)
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        try await PhysicalDeviceGestures.path(selectedPath, on: input)
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if selectedInput.mode == .selected {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(selectedRequest(), simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        try await performGlobalSetup(logger: logger)
        let stroke = strokePoints
        logger.info().log("Drawing through \(stroke.count) points in \(duration)s")

        // Duo and verified DTUHID devices use the broker's retained input connection.
        if let context = try await LegacyDuoInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: preDelay, logger: logger, includeVerifiedRigid: true
        )?.context {
            try TouchStroke.requireInside(stroke, width: context.logicalWidth, height: context.logicalHeight)
            let path = SelectedHIDPath(kind: .draw, duration: duration,
                points: stroke.map { SelectedHIDCompleteGesture.Point(x: $0.x, y: $0.y) }, generator: .ordinary)
            try await LegacyDuoInput.perform(path: path, context: context,
                simulatorUDID: simulatorUDID, postDelay: postDelay, logger: logger, verbose: selectedOutput.verbose)
            return
        }

        let physical = try await Self.directPoints(stroke, simulatorUDID: simulatorUDID, logger: logger)
        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        if let preDelay, preDelay > 0 { try await Task.sleep(for: .seconds(preDelay)) }
        do {
            try await HIDInteractor.performHIDEvent(directEvent(through: physical), in: session, logger: logger)
        } catch {
            // A failed send can leave the finger down. Release only; never replay the stroke.
            let last = physical[physical.count - 1]
            try? await HIDInteractor.performHIDEvent(.touch(direction: .up, x: last.x, y: last.y), in: session, logger: logger)
            throw error
        }
        if let postDelay, postDelay > 0 { try await Task.sleep(for: .seconds(postDelay)) }
    }
}
