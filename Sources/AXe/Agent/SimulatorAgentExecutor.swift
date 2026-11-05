import AXeCore
import Foundation
import FBControlCore
import FBSimulatorControl

struct AgentExecutedAction: Sendable {
    let targetDescription: String?
    let text: String?
    let launchedApplication: AgentApplication?
}

@MainActor
final class SimulatorAgentExecutor {
    private let simulatorUDID: String
    private let logger: AxeLogger
    private let observer: AgentScreenObserver
    private var hidSession: HIDInteractor.Session?
    private var cachedMapping: (viewport: AgentFrame?, mapping: CoordinateMapping)?

    init(simulatorUDID: String, logger: AxeLogger, observer: AgentScreenObserver) {
        self.simulatorUDID = simulatorUDID
        self.logger = logger
        self.observer = observer
    }

    func execute(
        _ decision: AgentDecision,
        screen: AgentScreenSnapshot,
        goal: String,
        history: [AgentHistoryEntry],
        textModelClient: AgentTextModelClient?
    ) async throws -> AgentExecutedAction {
        switch decision.operation {
        case .openApp:
            guard let application = decision.application else {
                throw AgentPolicyError.missingTarget(.openApp)
            }
            try await SimulatorApplicationCatalog.launch(application, on: observer.target())
            return AgentExecutedAction(
                targetDescription: "\(application.name) (\(application.bundleIdentifier))",
                text: nil,
                launchedApplication: application
            )

        case .tap:
            guard let element = decision.element else {
                throw AgentPolicyError.missingTarget(.tap)
            }
            try await tap(element, screen: screen)
            return AgentExecutedAction(
                targetDescription: element.displayName,
                text: nil,
                launchedApplication: nil
            )

        case .typeText:
            guard let element = decision.element else {
                throw AgentPolicyError.missingTarget(.typeText)
            }
            let text: String
            if let explicitText = decision.text {
                text = explicitText
            } else if let textModelClient {
                text = try await textModelClient.text(
                    for: AgentTextFieldContext(
                        goal: goal,
                        fieldLabel: element.label ?? element.identifier,
                        fieldType: element.role?.rawValue,
                        currentValue: element.value,
                        screenText: RuntimeSnapshotCompactor.text(in: screen.elements)
                            .map(\.text)
                            .joined(separator: "\n"),
                        recentActions: Array(history.suffix(6))
                    )
                )
            } else {
                throw AgentTextModelError.missingConfiguration
            }
            try Self.validateTextForHID(text)
            try await replaceText(in: element, with: text, screen: screen)
            return AgentExecutedAction(
                targetDescription: element.displayName,
                text: text,
                launchedApplication: nil
            )

        case .clearText:
            guard let element = decision.element else {
                throw AgentPolicyError.missingTarget(.clearText)
            }
            try await replaceText(in: element, with: nil, screen: screen)
            return AgentExecutedAction(
                targetDescription: element.displayName,
                text: nil,
                launchedApplication: nil
            )

        case .scrollDown, .scrollUp:
            // Revealing lower content means dragging the content upwards.
            let direction: RuntimeSwipeDirection = decision.operation == .scrollDown ? .up : .down
            try await scroll(direction, within: decision.element, screen: screen)
            return AgentExecutedAction(
                targetDescription: decision.element?.displayName ?? "current screen",
                text: nil,
                launchedApplication: nil
            )

        case .pressReturn:
            let session = try await session()
            try await HIDInteractor.performHIDEvent(
                .shortKeyPress(40),
                in: session,
                logger: logger
            )
            return AgentExecutedAction(targetDescription: "keyboard Return", text: nil, launchedApplication: nil)

        case .wait:
            // The post-action settle adds further observation time.
            try await Task.sleep(for: .milliseconds(250))
            return AgentExecutedAction(targetDescription: nil, text: nil, launchedApplication: nil)

        case .done, .blocked:
            return AgentExecutedAction(targetDescription: nil, text: nil, launchedApplication: nil)
        }
    }

    private func tap(_ element: RuntimeSnapshotElement, screen: AgentScreenSnapshot) async throws {
        let logicalPoint = element.activationPoint
        let physicalPoint = try await physicalPoints([logicalPoint], screen: screen)[0]
        let session = try await session()
        // rs/1 activates switches with a touch rather than a synthetic tap.
        if element.role == .switch {
            try await HIDInteractor.performPhysicalTap(
                at: physicalPoint,
                preDelay: nil,
                postDelay: nil,
                in: session,
                logger: logger
            )
        } else {
            try await HIDInteractor.performHIDEvent(
                .tapAt(x: physicalPoint.x, y: physicalPoint.y),
                in: session,
                logger: logger
            )
        }
    }

    private func replaceText(
        in element: RuntimeSnapshotElement,
        with text: String?,
        screen: AgentScreenSnapshot
    ) async throws {
        try await tap(element, screen: screen)
        try await Task.sleep(for: .milliseconds(75))

        let session = try await session()
        // Each HID event is a separate round trip, so skip select-all and delete for an empty field.
        var events: [FBSimulatorHIDEvent] = element.value == nil ? [] : [
            .keyboard(direction: .down, keyCode: 227),
            .shortKeyPress(4),
            .keyboard(direction: .up, keyCode: 227),
            .shortKeyPress(42),
        ]
        guard text != nil || !events.isEmpty else { return }

        if let text {
            events.append(contentsOf: try TextToHIDEvents.convertTextToHIDEvents(text))
        }

        try await HIDInteractor.performHIDEvent(
            .composite(events),
            in: session,
            logger: logger
        )
    }

    private static func validateTextForHID(_ text: String) throws {
        guard TextToHIDEvents.validateText(text) else {
            let unsupported = text.first { KeyEvent.keyCodeForString(String($0)).keyCode == 0 }
            throw CLIError(
                errorDescription: "The selected text contains a character AXe cannot type using the US HID keyboard: \(unsupported.map(String.init) ?? "unknown")."
            )
        }
    }

    private func scroll(
        _ direction: RuntimeSwipeDirection,
        within element: RuntimeSnapshotElement?,
        screen: AgentScreenSnapshot
    ) async throws {
        let area: RuntimeSnapshotElement
        if let element {
            area = element
        } else if let viewport = screen.viewport, viewport.isValid {
            area = RuntimeSnapshotElement(ref: "viewport", role: .application, frame: viewport, actions: [.swipeWithin])
        } else {
            throw CLIError(errorDescription: "AXe could not determine a scroll area or application frame for scrolling.")
        }
        guard let points = area.swipePoints(direction: direction) else {
            throw CLIError(errorDescription: "The scroll area '\(area.displayName)' is too small for a reliable swipe.")
        }

        let physicalPoints = try await physicalPoints([points.from, points.to], screen: screen)
        let session = try await session()
        // rs/1 swipe geometry with a shorter drag than `axe swipe`'s 1 second default.
        try await HIDInteractor.performHIDEvent(
            .swipe(
                physicalPoints[0].x,
                yStart: physicalPoints[0].y,
                xEnd: physicalPoints[1].x,
                yEnd: physicalPoints[1].y,
                delta: 50,
                duration: 0.5
            ),
            in: session,
            logger: logger
        )
    }

    /// Maps logical points to HID coordinates. Orientation detection from a fresh hierarchy costs
    /// about 250 ms, so the mapping is derived from the observer's latest hierarchy (about 3 ms) and
    /// reused until the viewport changes.
    private func physicalPoints(
        _ points: [AgentPoint],
        screen: AgentScreenSnapshot
    ) async throws -> [(x: Double, y: Double)] {
        let mapping: CoordinateMapping
        if let cachedMapping, cachedMapping.viewport == screen.viewport {
            mapping = cachedMapping.mapping
        } else {
            mapping = try await OrientationAwareCoordinates.detectMapping(
                from: observer.latestRoots,
                simulatorUDID: simulatorUDID,
                logger: logger
            )
            cachedMapping = (screen.viewport, mapping)
        }
        return points.map {
            OrientationAwareCoordinates.applyMapping(mapping, to: (x: $0.x, y: $0.y), logger: logger)
        }
    }

    private func session() async throws -> HIDInteractor.Session {
        if let hidSession {
            return hidSession
        }
        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        hidSession = session
        return session
    }
}
