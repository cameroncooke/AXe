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

struct Button: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button.",
        discussion: """
        Physical devices support home, siri and lock; lock needs --allow-lock, and you must unlock the device yourself.

        Examples:
          axe button home --udid <UDID>
          axe button lock --duration 2 --udid <UDID>
          axe button siri --udid <UDID>
        """
    )
    
    @Argument(help: "Button to press.")
    var buttonType: ButtonType
    
    @Option(name: .customLong("duration"), help: "Seconds to hold the button, up to 10.")
    var duration: Double?
    
    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @Flag(name: .customLong("allow-lock"), help: "Allow the lock button on a physical device.")
    var allowLock = false

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions

    @Option(name: .customLong("expected-boot"),
        help: ArgumentHelp("Selected hardware button: require this exact measured boot identity before input.", visibility: .hidden))
    var expectedBoot: String?

    func validate() throws {
        try selectedInput.validate()
        if allowLock, buttonType != .lock || !AutomationTarget.isPhysicalInputUDID(simulatorUDID) {
            throw ValidationError("--allow-lock requires the lock button and a physical device UDID.")
        }
        if selectedInput.mode == .selected {
            try selectedButtonPayload.validate()
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
        let request = try selectedInput.baseRequest(payload: .button(selectedButtonPayload))
        try request.validate()
        return request
    }

    private var selectedButtonPayload: SelectedButtonRequest {
        let kind: SelectedButtonRequest.Kind
        switch buttonType {
        case .home: kind = .home
        case .sideButton: kind = .sideButton
        case .siri: kind = .siri
        case .lock: kind = .lock
        case .applePay: kind = .applePay
        }
        return SelectedButtonRequest(kind: kind, duration: duration, expectedBoot: expectedBoot)
    }

    /// The ordinary button event, for the standalone command and batch steps.
    var hidEvent: FBSimulatorHIDEvent {
        guard let duration else { return .shortButtonPress(buttonType.hidButton) }
        return .composite([.button(direction: .down, button: buttonType.hidButton), .delay(duration),
            .button(direction: .up, button: buttonType.hidButton)])
    }

    private func physicalButtonTarget() throws -> PhysicalDeviceButton {
        guard selectedInput.mode != .selected else {
            throw AutomationTarget.unsupportedOnDevice("Physical buttons do not support selected display options.")
        }
        let button: PhysicalDeviceButton
        switch buttonType {
        case .home: button = .home
        case .siri: button = .siri
        case .lock:
            guard allowLock else {
                throw AutomationTarget.unsupportedOnDevice("Physical lock requires --allow-lock. You must unlock the device yourself.")
            }
            button = .lock
        case .sideButton, .applePay:
            throw AutomationTarget.unsupportedOnDevice("This button is not available on physical devices.")
        }
        return button
    }

    func validateOnDevice(inBatch: Bool) throws {
        _ = try physicalButtonTarget()
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        try await input.pressButton(physicalButtonTarget(), hold: duration ?? 0.08, allowLock: allowLock)
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

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        try await HIDInteractor.performHIDEvent(hidEvent, for: simulatorUDID, logger: logger)
        logger.info().log("\(buttonType.description) press completed successfully")
    }
} 
