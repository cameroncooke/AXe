import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    
    var hidButton: FBSimulatorHIDButton {
        switch self {
        case .applePay:
            return FBSimulatorHIDButton(rawValue: 1)! // FBSimulatorHIDButtonApplePay
        case .home:
            return FBSimulatorHIDButton(rawValue: 2)! // FBSimulatorHIDButtonHomeButton
        case .lock:
            return FBSimulatorHIDButton(rawValue: 3)! // FBSimulatorHIDButtonLock
        case .sideButton:
            return FBSimulatorHIDButton(rawValue: 4)! // FBSimulatorHIDButtonSideButton
        case .siri:
            return FBSimulatorHIDButton(rawValue: 5)! // FBSimulatorHIDButtonSiri
        }
    }
    
    var description: String {
        switch self {
        case .applePay:
            return "Apple Pay button"
        case .home:
            return "Home button"
        case .lock:
            return "Lock/Power button"
        case .sideButton:
            return "Side button"
        case .siri:
            return "Siri button"
        }
    }
}

struct Button: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the simulator.",
        discussion: """
        Available buttons: apple-pay, home, lock, side-button, siri
        Selected mode supports all five buttons. The screen pair guards the active context;
        buttons act on the whole device. Transport evidence does not prove a UI, lock or power state.
        
        Examples:
          axe button home --udid SIMULATOR_UDID
          axe button lock --duration 2.0 --udid SIMULATOR_UDID
          axe button siri --udid SIMULATOR_UDID
        """
    )
    
    @Argument(help: "The button to press.")
    var buttonType: ButtonType
    
    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (optional).")
    var duration: Double?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    @OptionGroup var selectedInput: SelectedInputOptions

    @Option(name: .customLong("expected-boot"), help: "Selected hardware button: require this exact measured boot identity before input.")
    var expectedBoot: String?

    func validate() throws {
        try selectedInput.validate()
        if selectedInput.mode == .selected {
            if let payload = selectedButtonPayload {
                try payload.validate()
            } else {
                try SelectedHomeRequest(duration: duration, expectedBoot: expectedBoot).validate()
            }
        } else if expectedBoot != nil {
            throw ValidationError("--expected-boot requires a selected hardware button.")
        }
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
    }

    func selectedRequest() throws -> SelectedHIDRequest {
        try validate()
        guard selectedInput.mode == .selected, let screenID = selectedInput.screenID,
              let screenUUID = selectedInput.screenUUID.flatMap(UUID.init(uuidString:)) else {
            throw ValidationError("Selected button requires an explicit screen ID and UUID.")
        }
        var request = SelectedHIDRequest(version: SelectedHIDRequest.version, requestID: UUID(),
            screenID: screenID, screenUUID: screenUUID, operation: .complete, token: nil, primitives: [])
        if let payload = selectedButtonPayload {
            request.button = payload
        } else {
            request.home = SelectedHomeRequest(duration: duration, expectedBoot: expectedBoot)
        }
        try request.validate()
        return request
    }

    private var selectedButtonPayload: SelectedButtonRequest? {
        let kind: SelectedButtonRequest.Kind
        switch buttonType {
        case .home: return nil
        case .sideButton: kind = .sideButton
        case .siri: kind = .siri
        case .lock: kind = .lock
        case .applePay: kind = .applePay
        }
        return SelectedButtonRequest(kind: kind, duration: duration, expectedBoot: expectedBoot)
    }

    func run() async throws {
        if selectedInput.mode == .selected {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(selectedRequest(), simulatorUDID: simulatorUDID))
            return
        }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        // Create button HID event
        let buttonEvent: FBSimulatorHIDEvent
        
        if let duration = duration {
            // For duration-based presses, we need to create separate down/up events with delay
            let buttonDownEvent = FBSimulatorHIDEvent.button(direction: .down, button: buttonType.hidButton)
            let delayEvent = FBSimulatorHIDEvent.delay(duration)
            let buttonUpEvent = FBSimulatorHIDEvent.button(direction: .up, button: buttonType.hidButton)

            buttonEvent = FBSimulatorHIDEvent.composite([
                buttonDownEvent,
                delayEvent,
                buttonUpEvent
            ])
        } else {
            // Simple short button press
            buttonEvent = FBSimulatorHIDEvent.shortButtonPress(buttonType.hidButton)
        }
        
        // Perform the button event
        try await HIDInteractor
            .performHIDEvent(
                buttonEvent,
                for: simulatorUDID,
                logger: logger
            )
        
        logger.info().log("\(buttonType.description) press completed successfully")
    }
} 
