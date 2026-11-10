import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Touch: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a touch down, a touch up, or both, at one point.",
        discussion: """
        --down with --up makes one press held for --delay seconds, such as a long press; a standalone physical-device touch needs both. With --input-mode selected, --down prints a contact token: pass it as --contact-token to move the contact (--down) or lift it (--up). With --agent, --ref replaces -x and -y.

        Examples:
          axe touch -x 100 -y 200 --down --up --udid <UDID>
          axe touch -x 100 -y 200 --down --up --delay 1.0 --udid <UDID>    # long press
          axe touch -x 100 -y 200 --down --udid <UDID>
          axe touch -x 100 -y 200 --up --udid <UDID>
        """
    )
    
    @Option(name: .customShort("x"), help: "X coordinate in points.")
    var pointX: Double?
    
    @Option(name: .customShort("y"), help: "Y coordinate in points.")
    var pointY: Double?
    
    @Flag(name: .customLong("down"), help: "Touch down.")
    var touchDown: Bool = false
    
    @Flag(name: .customLong("up"), help: "Touch up.")
    var touchUp: Bool = false
    
    @Option(name: .customLong("delay"), help: "Seconds between down and up, 0 to 10 (default 0.1); needs --down and --up.")
    var delay: Double?
    
    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String


    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("expected-pid"), help: "Agent only: require this frontmost app PID.")
    var expectedPID: Int32?

    @Option(name: .customLong("contact-token"), help: "Selected input only: contact token printed by an earlier --down.")
    var contactToken: String?

    func validate() throws {
        try agentMode.validate()
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: expectedPID)
            guard touchDown, touchUp, agentMode.elementRef != nil, pointX == nil, pointY == nil,
                  contactToken == nil else {
                throw ValidationError("Agent touch requires --ref, --down and --up, without coordinates or a contact token.")
            }
            _ = try agentRequest()
            return
        }
        guard expectedPID == nil else { throw ValidationError("--expected-pid requires --agent.") }
        guard let pointX, let pointY else {
            throw ValidationError("Touch requires -x and -y without --agent.")
        }
        try selectedInput.validate()
        if let contactToken {
            guard selectedInput.mode == .selected, UUID(uuidString: contactToken) != nil, touchDown != touchUp else {
                throw ValidationError("A contact token requires selected input and exactly one of --down or --up.")
            }
        }
        if selectedInput.mode == .selected, touchUp && !touchDown && contactToken == nil {
            throw ValidationError("Selected touch up requires the retained contact token.")
        }

        // Validate coordinates are non-negative
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        
        // Validate that at least one action is specified
        guard touchDown || touchUp else {
            throw ValidationError("At least one of --down or --up must be specified.")
        }
        
        // Validate delay if provided
        if let delay = delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
            
            // Delay only makes sense if both down and up are specified
            guard touchDown && touchUp else {
                throw ValidationError("Delay can only be used when both --down and --up are specified.")
            }
        }
    }

    func agentRequest() throws -> SelectedHIDRequest {
        try AgentModeCommandAdapter.request(AgentModeRequest(kind: .hold,
            expectedPID: expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            duration: delay ?? TapTiming.defaultHoldDuration), input: selectedInput)
    }

    func selectedRequest() throws -> SelectedHIDRequest {
        guard !agentMode.enabled else {
            throw ValidationError("Agent mode requires standalone commands and is not supported in batch steps.")
        }
        guard let pointX, let pointY else { throw ValidationError("Selected touch requires -x and -y.") }
        let token = contactToken.flatMap(UUID.init(uuidString:))
        let operation: SelectedHIDRequest.Operation
        var primitives: [SelectedHIDPrimitive] = [.touch(.down, x: pointX, y: pointY)]
        if touchDown && touchUp {
            operation = .complete
            primitives += [.delay(delay ?? TapTiming.defaultHoldDuration), .touch(.up, x: pointX, y: pointY)]
        } else if touchDown {
            operation = token == nil ? .begin : .move
        } else {
            operation = .end
        }
        return try selectedInput.request(operation: operation, token: token, primitives: primitives)
    }

    /// A batch step may hold a contact for a later step; a standalone touch must lift it.
    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agentMode.enabled)
        guard contactToken == nil else {
            throw AutomationTarget.unsupportedOnDevice("Physical touch does not accept a simulator contact token.")
        }
        guard inBatch || (touchDown && touchUp) else {
            throw AutomationTarget.unsupportedOnDevice("Use --down and --up together for a standalone physical device touch.")
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        guard let pointX, let pointY, touchDown || touchUp else {
            throw ValidationError("Physical touch requires coordinates and --down, --up or both.")
        }
        let point = CGPoint(x: pointX, y: pointY)
        var plan: [PhysicalTouchStep] = []
        if touchDown {
            let hold = touchUp ? delay ?? TapTiming.defaultHoldDuration : 0
            plan.append(PhysicalTouchStep(points: [point], phase: .down, delayAfter: hold))
        }
        if touchUp {
            plan.append(PhysicalTouchStep(points: [point], phase: .up))
        }
        // Only a batch step reaches here with a partial touch.
        try await input.perform(plan, allowPartial: !(touchDown && touchUp))
    }

    func run() async throws {
        if try await runOnDeviceIfTargeted() { return }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
            return
        }
        if selectedInput.mode == .selected {
            try SelectedHIDBroker.printResponse(SelectedHIDBroker.send(selectedRequest(), simulatorUDID: simulatorUDID),
                verbose: selectedOutput.verbose)
            return
        }
        guard let pointX, let pointY else { throw ValidationError("Touch requires -x and -y without --agent.") }
        let logger = AxeLogger()
        try await setup(logger: logger)
        
        try await performGlobalSetup(logger: logger)

        logger.info().log("Performing touch events at (\(pointX), \(pointY))")

        // A complete press uses the broker's retained connection on verified DTUHID devices too.
        // A partial down or up keeps its route there, so a held contact keeps one owner.
        if let context = try await OrdinaryBrokerInput.captureRoute(
            simulatorUDID: simulatorUDID, preDelay: nil, logger: logger,
            includeVerifiedRigid: touchDown && touchUp
        )?.context {
            let touch = OrdinaryBrokerTouch(x: pointX, y: pointY, down: touchDown, up: touchUp, delay: delay)
            try await OrdinaryBrokerInput.perform(touch: touch, context: context,
                simulatorUDID: simulatorUDID, logger: logger, verbose: selectedOutput.verbose)
            logger.info().log("Touch events completed successfully")
            return
        }

        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: (x: pointX, y: pointY),
            for: simulatorUDID,
            logger: logger
        )

        var primitives: [HIDBrokerPrimitive] = []
        if touchDown && touchUp {
            // Send down and up as separate HID submissions so iOS recognizers
            // observe a real hold duration for long-press gestures.
            let touchDelay = delay ?? TapTiming.defaultHoldDuration

            logger.info().log("Touch down")
            primitives.append(.touch(.down, x: physicalPoint.x, y: physicalPoint.y))

            if touchDelay > 0 {
                logger.info().log("Delay: \(touchDelay) seconds")
                primitives.append(.delay(touchDelay))
            }

            logger.info().log("Touch up")
            primitives.append(.touch(.up, x: physicalPoint.x, y: physicalPoint.y))
        } else if touchDown {
            logger.info().log("Touch down")
            primitives.append(.touch(.down, x: physicalPoint.x, y: physicalPoint.y))
        } else {
            logger.info().log("Touch up")
            primitives.append(.touch(.up, x: physicalPoint.x, y: physicalPoint.y))
        }

        try HIDBroker.sendTouchPrimitives(primitives, simulatorUDID: simulatorUDID)
        
        logger.info().log("Touch events completed successfully")
    }
} 
