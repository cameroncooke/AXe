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
    private var hidSession: HIDInteractor.Session?

    init(simulatorUDID: String, logger: AxeLogger) {
        self.simulatorUDID = simulatorUDID
        self.logger = logger
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
            try await SimulatorApplicationCatalog.launch(application, on: simulatorUDID)
            return AgentExecutedAction(
                targetDescription: "\(application.name) (\(application.bundleIdentifier))",
                text: nil,
                launchedApplication: application
            )

        case .tap:
            guard let element = decision.element else {
                throw AgentPolicyError.missingTarget(.tap)
            }
            try await tap(element)
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
                        fieldType: element.type ?? element.role,
                        currentValue: element.value,
                        screenText: screen.text,
                        recentActions: Array(history.suffix(6))
                    )
                )
            } else {
                throw AgentTextModelError.missingConfiguration
            }
            try Self.validateTextForHID(text)
            try await replaceText(in: element, with: text)
            return AgentExecutedAction(
                targetDescription: element.displayName,
                text: text,
                launchedApplication: nil
            )

        case .clearText:
            guard let element = decision.element else {
                throw AgentPolicyError.missingTarget(.clearText)
            }
            try await replaceText(in: element, with: nil)
            return AgentExecutedAction(
                targetDescription: element.displayName,
                text: nil,
                launchedApplication: nil
            )

        case .scrollDown:
            try await scroll(down: true, in: screen)
            return AgentExecutedAction(targetDescription: "current screen", text: nil, launchedApplication: nil)

        case .scrollUp:
            try await scroll(down: false, in: screen)
            return AgentExecutedAction(targetDescription: "current screen", text: nil, launchedApplication: nil)

        case .pressReturn:
            let session = try await session()
            try await HIDInteractor.performHIDEvent(
                .shortKeyPress(40),
                in: session,
                logger: logger
            )
            return AgentExecutedAction(targetDescription: "keyboard Return", text: nil, launchedApplication: nil)

        case .wait:
            try await Task.sleep(for: .milliseconds(500))
            return AgentExecutedAction(targetDescription: nil, text: nil, launchedApplication: nil)

        case .done, .blocked:
            return AgentExecutedAction(targetDescription: nil, text: nil, launchedApplication: nil)
        }
    }

    private func tap(_ element: AgentObservedElement) async throws {
        let logicalPoint = element.activationPoint
        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: (x: logicalPoint.x, y: logicalPoint.y),
            for: simulatorUDID,
            logger: logger
        )
        let session = try await session()
        if element.isSwitchLike {
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
        in element: AgentObservedElement,
        with text: String?
    ) async throws {
        try await tap(element)
        try await Task.sleep(for: .milliseconds(75))

        let session = try await session()
        var events: [FBSimulatorHIDEvent] = [
            .keyboard(direction: .down, keyCode: 227),
            .shortKeyPress(4),
            .keyboard(direction: .up, keyCode: 227),
            .shortKeyPress(42),
        ]

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

    private func scroll(down: Bool, in screen: AgentScreenSnapshot) async throws {
        guard let frame = screen.applicationFrame, frame.isValid else {
            throw CLIError(errorDescription: "AXe could not determine the current application frame for scrolling.")
        }

        let x = frame.x + (frame.width * 0.5)
        let upperY = frame.y + (frame.height * 0.28)
        let lowerY = frame.y + (frame.height * 0.72)
        let logicalStart = down ? AgentPoint(x: x, y: lowerY) : AgentPoint(x: x, y: upperY)
        let logicalEnd = down ? AgentPoint(x: x, y: upperY) : AgentPoint(x: x, y: lowerY)
        let physicalPoints = try await OrientationAwareCoordinates.translateBatch(
            points: [
                (x: logicalStart.x, y: logicalStart.y),
                (x: logicalEnd.x, y: logicalEnd.y),
            ],
            for: simulatorUDID,
            logger: logger
        )
        let session = try await session()
        try await HIDInteractor.performHIDEvent(
            .swipe(
                physicalPoints[0].x,
                yStart: physicalPoints[0].y,
                xEnd: physicalPoints[1].x,
                yEnd: physicalPoints[1].y,
                delta: 24,
                duration: 0.25
            ),
            in: session,
            logger: logger
        )
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
