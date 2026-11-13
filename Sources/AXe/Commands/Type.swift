import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Type: PhysicalDeviceCommand {
    static let configuration = CommandConfiguration(
        abstract: "Type text on the simulator's keyboard layout.",
        discussion: """
        Pass the text as an argument, with --stdin or with --file. AXe sends key presses to the focused field, choosing the keys from the simulator's own hardware keyboard layout, so German, French and other keyboards type what you pass. A character the layout has no key for, such as 日 on German, fails before anything is typed. An app keeps the layout it was launched with: after changing the simulator's keyboards, relaunch the app or name the layout with --layout. --layout us sends US key positions whatever the simulator is set to. On a physical device, which does not report the keyboard in use, --layout auto is unavailable: name the layout, or AXe sends US key positions. Physical devices and selected input take at most 256 UTF-8 bytes. With --agent, --focus taps the --ref field before typing.

        Examples:
          axe type 'Hello, world!' --udid <UDID>
          printf 'line one\\nline two' | axe type --stdin --udid <UDID>
          axe type --file message.txt --udid <UDID>
          axe type 'Grüße an @alle' --udid <UDID>
          axe type 'user@example.com' --layout us --udid <UDID>
        """
    )
    
    @Argument(help: "Text to type.")
    var text: String?
    
    @Flag(name: .customLong("stdin"), help: "Read the text from standard input.")
    var useStdin: Bool = false
    
    @Option(name: .customLong("file"), help: "Read the text from this file.")
    var inputFile: String?
    
    @Option(name: .customLong("udid"), help: "UDID of the simulator or physical device.")
    var simulatorUDID: String

    @Flag(name: .customLong("focus"), help: "Agent only: tap the --ref TextField and wait for focus before typing.")
    var focusBeforeTyping = false

    @OptionGroup var selectedInput: SelectedInputOptions
    @OptionGroup var selectedOutput: SelectedOutputOptions
    @OptionGroup var selectedKeyboard: SelectedKeyboardOptions
    @OptionGroup var agentMode: AgentModeOptions

    @Option(name: .customLong("layout"), help: "Hardware keyboard layout: auto (simulator default, read the simulator's keyboard settings), us (US key positions, physical device default), or a layout iOS ships, such as German, French or British.")
    var layout: String?

    /// A simulator reads its own layout unless one is named.
    private var simulatorLayout: String { layout ?? TypingLayout.automatic }

    func validate() throws {
        try agentMode.validate()
        if let layout, layout.isEmpty || layout.utf8.count > 64 {
            throw ValidationError("--layout takes auto, us or a keyboard layout name.")
        }
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
        var request = AgentModeRequest(kind: focusBeforeTyping ? .focusAndType : .typeText,
            expectedPID: selectedKeyboard.expectedPID, snapshotID: agentMode.snapshotID, ref: agentMode.elementRef,
            selectorKind: selectedKeyboard.focusID == nil ? nil : .id,
            selectorValue: selectedKeyboard.focusID, text: input)
        request.layout = try typingLayout()
        return try AgentModeCommandAdapter.request(request, input: selectedInput)
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
        return try selectedKeyboard.request(input: selectedInput, event: SelectedKeyboardRequest.textEvent(input, layout: typingLayout()))
    }

    func validateOnDevice(inBatch: Bool) throws {
        try selectedInput.refuseOnDevice(agent: agentMode.enabled,
            "Physical typing sends keys to the current focus without agent or selected display options.")
        // Literal text is checked here; text from standard input or a file is read only once, in `runOnDevice`.
        // A named layout's data is found in `runOnDevice`, where its check also comes before any input.
        if layout == TypingLayout.automatic { throw TypingLayout.deviceAutomatic }
        guard let text else { return }
        if layout == nil || layout == TypingLayout.fixedUS {
            _ = try Self.physicalKeySteps(for: text)
        } else {
            try Self.requirePhysicalTextBounds(text)
        }
    }

    func runOnDevice(_ input: PhysicalDeviceInput) async throws {
        let text = try AgentModeCommandAdapter.readText(text, useStdin: useStdin,
            inputFile: inputFile, standardInput: .standardInput)
        try Self.requirePhysicalTextBounds(text)
        let logger = AxeLogger()
        let typing = try TypingLayout.resolve(layout, deviceVersion: input.osVersion) { logger.info().log($0) }
        // Every character is planned before the first key is sent.
        try await input.keys(Self.physicalKeySteps(for: text, layout: typing))
    }

    static func requirePhysicalTextBounds(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= SelectedKeyboardRequest.maximumTextBytes else {
            throw ValidationError("Physical typing requires 1...256 UTF-8 bytes.")
        }
    }

    static func physicalKeySteps(for text: String, layout: TypingLayout = .us) throws -> [PhysicalKeyStep] {
        try requirePhysicalTextBounds(text)
        return try layout.keyStrokes(for: text).flatMap { stroke -> [PhysicalKeyStep] in
            let modifiers: [UInt64] = (stroke.shift ? [225] : []) + (stroke.option ? [226] : [])
            let code = UInt64(stroke.usage)
            return modifiers.map { PhysicalKeyStep(code: $0, pressed: true) }
                + [PhysicalKeyStep(code: code, pressed: true), PhysicalKeyStep(code: code, pressed: false)]
                + modifiers.reversed().map { PhysicalKeyStep(code: $0, pressed: false) }
        }
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
        let logger = AxeLogger()
        // Read the simulator's keyboard layout while the input session is set up, so that
        // finding it adds no time to the command.
        let layoutChoice = simulatorLayout, udid = simulatorUDID
        let layoutLookup = Task.detached { () throws -> (TypingLayout, [String]) in
            var notes: [String] = []
            let typing = try TypingLayout.resolve(layoutChoice, simulatorUDID: udid) { notes.append($0) }
            return (typing, notes)
        }
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
        
        let hidEvents: [FBSimulatorHIDEvent]
        do {
            let (typing, notes) = try await layoutLookup.value
            notes.forEach { logger.info().log($0) }
            hidEvents = try typing.events(for: inputText)
            logger.info().log("Successfully converted text to \(hidEvents.count) HID events")
        } catch {
            logger.error().log("Text conversion failed: \(error.localizedDescription)")
            throw error
        }
        
        logger.info().log("Performing HID event sequence for text typing")
        
        if !hidEvents.isEmpty {
            // Keep typing in one ordered session. Indigo awaits each send, while DTUHID adds its
            // own keyboard pacing; unconditional delays here would double-pace the DTUHID path.
            try await OrdinaryBrokerInput.performKeyboard(
                .composite(hidEvents), simulatorUDID: simulatorUDID, logger: logger, verbose: selectedOutput.verbose
            )
        }
        
        logger.info().log("Text typing completed successfully")
    }

    // MARK: - Keyboard Layout

    /// The layout --layout names on this simulator; `auto` reads its keyboard settings.
    func typingLayout(note: (String) -> Void = { _ in }) throws -> TypingLayout {
        try TypingLayout.resolve(simulatorLayout, simulatorUDID: simulatorUDID, note: note)
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
