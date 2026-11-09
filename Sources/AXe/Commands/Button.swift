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
        abstract: "Press a hardware button on a simulator or physical device.",
        discussion: """
        Available buttons: apple-pay, home, lock, side-button, siri
        Selected mode supports all five buttons. An optional --screen-id/--screen-uuid pair guards
        the active context; without it AXe uses the active screen. Buttons act on the whole device. Transport evidence does not prove a UI, lock or power state.
        
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
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
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
        var request = try selectedInput.baseRequest(operation: .complete, token: nil, primitives: [])
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

    func physicalButton(on input: PhysicalDeviceInput) async throws {
        try await input.pressButton(physicalButtonTarget(), hold: duration ?? 0.08, allowLock: allowLock)
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID),
           let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) {
            let button = try physicalButtonTarget()
            try await PhysicalDeviceInput.withSession(for: device) { input in
                try await input.pressButton(button, hold: duration ?? 0.08, allowLock: allowLock)
            }
            return
        }
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
