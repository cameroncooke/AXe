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

    func validate() throws {
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

    func run() async throws {
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
