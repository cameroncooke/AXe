import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Type: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Type text by entering a sequence of characters.",
        discussion: """
        Input Methods:
        1. Direct text: axe type "Hello World" --udid UDID
        2. From stdin: echo "Hello World!" | axe type --stdin --udid UDID
        3. From file: axe type --file text.txt --udid UDID
        
        Examples:
        • Simple text: axe type "Hello World" --udid UDID
        • Agent focus and type: axe type "Hello" --agent --focus --snapshot-id UUID --ref e2 --udid UDID
        • With spaces: axe type "Hello, how are you?" --udid UDID
        • Special characters: axe type 'Hello!' --udid UDID
        
        Shell Escaping Tips:
        • Use double quotes for text with spaces: "Hello World"
        • Use single quotes for text with special characters: 'Hello!'
        • For complex text or automation, prefer --stdin or --file methods
        
        Character Support:
        • Only US keyboard characters are supported via HID keycodes
        • Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
        • Not supported: International characters (£€¥), accented letters (éñü), etc.
        • This is a limitation of the underlying HID keyboard protocol
        
        Note: iOS may apply smart punctuation spacing to some characters.
        """
    )
    
    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?
    
    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false
    
    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator or physical device.")
    var simulatorUDID: String

    @Flag(name: .customLong("focus"), help: "Agent only: physically tap the referenced TextField, verify its focus, then type. Returns two phase receipts; input is never replayed.")
    var focusBeforeTyping = false

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var selectedKeyboard: SelectedKeyboardOptions
    @OptionGroup var agentMode: AgentModeOptions

    func validate() throws {
        try agentMode.validate()
        if focusBeforeTyping {
            guard agentMode.enabled, agentMode.snapshotID != nil, agentMode.elementRef != nil,
                  selectedKeyboard.focusID == nil else {
                throw ValidationError("--focus requires --agent, --snapshot-id and --ref, without --focus-id.")
            }
        }
        if agentMode.enabled {
            try AgentModeCommandAdapter.validateContext(input: selectedInput, expectedPID: selectedKeyboard.expectedPID)
            let focusID = selectedKeyboard.focusID
            guard (agentMode.elementRef != nil) != (focusID != nil) else {
                throw ValidationError("Agent type requires one --ref or one --focus-id for an already focused TextField.")
            }
            if let focusID {
                guard !focusID.isEmpty, focusID.utf8.count <= 4096,
                      focusID == focusID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw ValidationError("--focus-id must be a nonempty exact TextField ID.")
                }
            }
        } else {
            try selectedKeyboard.validate(input: selectedInput)
        }
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }

        if sourceCount == 0 {
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        }
    }

    func agentRequest(standardInput: FileHandle = .standardInput) throws -> SelectedHIDRequest {
        let input = try AgentModeCommandAdapter.readText(text, useStdin: useStdin,
            inputFile: inputFile, standardInput: standardInput)
        return try AgentModeCommandAdapter.request(AgentModeRequest(kind: focusBeforeTyping ? .focusAndType : .typeText,
            expectedPID: selectedKeyboard.expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            selectorKind: selectedKeyboard.focusID == nil ? nil : .id,
            selectorValue: selectedKeyboard.focusID, text: input), input: selectedInput)
    }

    func selectedRequest(standardInput: FileHandle = .standardInput) throws -> SelectedHIDRequest {
        let input: String
        switch (text, useStdin, inputFile) {
        case (let literal?, false, nil): input = literal
        case (nil, true, nil): input = try SelectedKeyboardOptions.readText(from: standardInput)
        case (nil, false, let file?):
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            input = try SelectedKeyboardOptions.readText(from: handle)
        default: throw ValidationError("Select one text input source.")
        }
        return try selectedKeyboard.request(input: selectedInput, event: SelectedKeyboardRequest.textEvent(input))
    }

    func physicalType(on input: PhysicalDeviceInput, standardInput: FileHandle = .standardInput) async throws {
        guard !agentMode.enabled, selectedInput.mode != .selected else {
            throw AutomationTarget.unsupportedOnDevice("Physical typing sends keys to the current focus without agent or selected display options.")
        }
        let text = try AgentModeCommandAdapter.readText(text, useStdin: useStdin,
            inputFile: inputFile, standardInput: standardInput)
        guard !text.isEmpty, text.utf8.count <= SelectedKeyboardRequest.maximumTextBytes else {
            throw ValidationError("Physical typing requires 1...256 UTF-8 bytes.")
        }
        let steps = try text.flatMap { character -> [PhysicalKeyStep] in
            let event = KeyEvent.keyCodeForString(String(character))
            guard event.keyCode != 0 else {
                throw TextToHIDEvents.TextConversionError.unsupportedCharacter(character)
            }
            let code = UInt64(event.keyCode)
            let press = [PhysicalKeyStep(code: code, pressed: true), PhysicalKeyStep(code: code, pressed: false)]
            if event.shift {
                return [PhysicalKeyStep(code: 225, pressed: true)] + press + [PhysicalKeyStep(code: 225, pressed: false)]
            }
            return press
        }
        try await input.keys(steps)
    }

    func run() async throws {
        if AutomationTarget.isPhysicalInputUDID(simulatorUDID),
           let device = try await AutomationTarget.physicalInputDevice(udid: simulatorUDID) {
            try await PhysicalDeviceInput.withSession(for: device) { input in
                try await physicalType(on: input)
            }
            return
        }
        if agentMode.enabled {
            try AgentModeCommandAdapter.send(agentRequest(), simulatorUDID: simulatorUDID)
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
        
        // Determine input source and get text
        let inputText: String
        
        // Check if we have multiple input sources
        let sourceCount = [text != nil, useStdin, inputFile != nil].filter { $0 }.count
        if sourceCount > 1 {
            throw ValidationError("Please specify only one input source: text argument, --stdin, or --file.")
        }
        
        switch (text, useStdin, inputFile) {
        case (let positionalText?, false, nil):
            // Positional argument
            inputText = positionalText
            logger.info().log("Using positional text input: '\(inputText)'")
            
        case (nil, true, nil):
            // Read from stdin
            logger.info().log("Reading text from standard input...")
            inputText = readFromStdin()
            logger.info().log("Read from stdin: '\(inputText)'")
            
        case (nil, false, let file?):
            // Read from file
            logger.info().log("Reading text from file: \(file)")
            inputText = try readFromFile(file)
            logger.info().log("Read from file: '\(inputText)'")
            
        case (nil, false, nil):
            // No input provided
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
            
        default:
            // This shouldn't happen due to earlier check
            throw ValidationError("Invalid input configuration.")
        }
        
        // Validate text first
        guard TextToHIDEvents.validateText(inputText) else {
            // Find unsupported characters for detailed error message
            let unsupportedChars = inputText.compactMap { char in
                let keyEvent = KeyEvent.keyCodeForString(String(char))
                return keyEvent.keyCode == 0 ? char : nil
            }
            let errorMessage = """
                Unsupported characters found: \(unsupportedChars.map { "'\($0)'" }.joined(separator: ", "))
                
                Only US keyboard characters are supported via HID keycodes.
                Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
                """
            logger.error().log(errorMessage)
            throw TextToHIDEvents.TextConversionError.unsupportedCharacter(unsupportedChars.first!)
        }
        
        // Convert text to HID events using the new utility
        let hidEvents: [FBSimulatorHIDEvent]
        do {
            hidEvents = try TextToHIDEvents.convertTextToHIDEvents(inputText)
            logger.info().log("Successfully converted text to \(hidEvents.count) HID events")
        } catch let error as TextToHIDEvents.TextConversionError {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
        } catch {
            logger.error().log("Unexpected error during text conversion: \(error.localizedDescription)")
            throw error
        }
        
        logger.info().log("Performing HID event sequence for text typing")
        
        if !hidEvents.isEmpty {
            // Keep typing in one ordered session. Indigo awaits each send, while DTUHID adds its
            // own keyboard pacing; unconditional delays here would double-pace the DTUHID path.
            try await LegacyDuoInput.performKeyboard(
                .composite(hidEvents), simulatorUDID: simulatorUDID, logger: logger
            )
        }
        
        logger.info().log("Text typing completed successfully")
    }

    // MARK: - Input Methods
    
    func readFromStdin() -> String {
        var input = ""
        while let line = readLine() {
            if !input.isEmpty {
                input += "\n"
            }
            input += line
        }
        return input
    }
    
    func readFromFile(_ filePath: String) throws -> String {
        do {
            return try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            throw ValidationError("Failed to read file '\(filePath)': \(error.localizedDescription)")
        }
    }
}
