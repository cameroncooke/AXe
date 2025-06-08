import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl

struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute a sequence of HID events from JSON input.",
        discussion: """
        Execute complex sequences of HID events (taps, swipes, typing, etc.) with precise timing control.
        
        Input Methods:
        1. JSON file: axe stream --file sequence.json --udid UDID
        2. Inline JSON: axe stream --json '{"events": [...]}' --udid UDID
        3. From stdin: echo '{"events": [...]}' | axe stream --stdin --udid UDID
        
        Execution Modes:
        • Composite mode (default): All events executed as a single composite operation
        • Sequential mode: Events executed sequentially with real-time timing
        • Batch mode: Events executed in batches with real-time timing
        
        Event Types Supported:
        • tap: Tap at coordinates
        • swipe: Swipe between two points
        • type: Type text using keyboard
        • key: Press individual keys by keycode
        • key_sequence: Press multiple keys in sequence
        • button: Press device buttons (home, lock, volume, siri)
        • touch: Touch and hold at coordinates
        • delay: Wait for specified duration
        • gesture: Custom gesture between points
        
        Timing Control:
        • pre_delay: Delay before each event
        • post_delay: Delay after each event
        • default_delay: Global delay between events (in settings)
        
        Examples:
        
        Simple tap sequence:
        axe stream --json '{
          "events": [
            {"type": "tap", "parameters": {"x": 100, "y": 200}},
            {"type": "delay", "parameters": {"duration": 1.0}},
            {"type": "tap", "parameters": {"x": 300, "y": 400}}
          ]
        }' --udid SIMULATOR_UDID
        
        Complex automation:
        axe stream --file automation.json --mode sequential --udid SIMULATOR_UDID
        
        Generate example:
        axe stream --example > example.json
        """
    )
    
    // MARK: - Input Options
    
    @Option(name: .customLong("json"), help: "JSON string containing the event sequence.")
    var jsonString: String?
    
    @Option(name: .customLong("file"), help: "Path to JSON file containing the event sequence.")
    var filePath: String?
    
    @Flag(name: .customLong("stdin"), help: "Read JSON from standard input.")
    var useStdin: Bool = false
    
    // MARK: - Execution Options
    
    @Option(name: .customLong("mode"), help: "Execution mode: 'composite' (default), 'sequential', or 'batch'.")
    var executionMode: ExecutionModeOption = .composite
    
    @Option(name: .customLong("batch-size"), help: "Number of events per batch (only used in batch mode, default: 10).")
    var batchSize: Int = 10
    
    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String
    
    // MARK: - Control Options
    
    @Flag(name: .customLong("dry-run"), help: "Validate and show what would be executed without actually running.")
    var dryRun: Bool = false
    
    @Flag(name: .customLong("verbose"), help: "Show detailed execution information.")
    var verbose: Bool = false
    
    @Flag(name: .customLong("validate-only"), help: "Only validate the sequence without executing.")
    var validateOnly: Bool = false
    
    @Flag(name: .customLong("summary"), help: "Show sequence summary before execution.")
    var showSummary: Bool = false
    
    // MARK: - Example Generation
    
    @Flag(name: .customLong("example"), help: "Generate and output an example JSON sequence.")
    var generateExample: Bool = false
    
    @Flag(name: .customLong("comprehensive-example"), help: "Generate a comprehensive example with all event types.")
    var generateComprehensiveExample: Bool = false
    
    @Flag(name: .customLong("schema"), help: "Output the JSON schema for event sequences.")
    var outputSchema: Bool = false
    
    // MARK: - Validation
    
    func validate() throws {
        // Handle example generation first
        if generateExample || generateComprehensiveExample || outputSchema {
            return // Skip other validation for example generation
        }
        
        // Validate input source
        let sourceCount = [jsonString != nil, filePath != nil, useStdin].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Please specify exactly one input source: --json, --file, or --stdin.")
        }
        
        // Validate UDID is provided (unless dry-run or validate-only)
        if !dryRun && !validateOnly && simulatorUDID.isEmpty {
            throw ValidationError("Simulator UDID is required unless using --dry-run or --validate-only.")
        }
    }
    
    // MARK: - Execution
    
    func run() async throws {
        let logger = AxeLogger()
        
        // Handle special modes first
        if generateExample {
            print(EventSequenceParser.generateExampleJSON())
            return
        }
        
        if generateComprehensiveExample {
            print(EventSequenceParser.generateComprehensiveExampleJSON())
            return
        }
        
        if outputSchema {
            print(EventSequenceParser.generateJSONSchema())
            return
        }
        
        // Setup if we're going to execute
        if !dryRun && !validateOnly {
            try await setup(logger: logger)
            try await performGlobalSetup(logger: logger)
        }
        
        // Parse the event sequence
        logger.info().log("Parsing event sequence...")
        let sequence: EventSequence
        do {
            sequence = try EventSequenceParser.parseFromSource(
                jsonString: jsonString,
                filePath: filePath,
                useStdin: useStdin
            )
            logger.info().log("Event sequence parsed successfully")
        } catch {
            logger.error().log("Failed to parse event sequence: \\(error.localizedDescription)")
            throw CLIError(errorDescription: "Parse error: \\(error.localizedDescription)")
        }
        
        // Show summary if requested
        if showSummary || verbose {
            let summary = HIDEventFactory.getEventSummary(sequence)
            print("\\n" + summary.description())
            
            if summary.hasErrors {
                logger.error().log("Sequence contains validation errors")
                if !dryRun {
                    throw CLIError(errorDescription: "Sequence validation failed")
                }
            }
        }
        
        // Validate the sequence
        logger.info().log("Validating event sequence...")
        do {
            try HIDEventFactory.validateEventSequence(sequence)
            logger.info().log("Event sequence validation passed")
        } catch {
            logger.error().log("Event sequence validation failed: \\(error.localizedDescription)")
            throw CLIError(errorDescription: "Validation error: \\(error.localizedDescription)")
        }
        
        // Stop here if validate-only mode
        if validateOnly {
            print("✅ Event sequence is valid")
            return
        }
        
        // Prepare execution plan
        logger.info().log("Creating execution plan for \\(executionMode.rawValue) mode...")
        let executionPlan = try HIDEventFactory.prepareEvents(
            from: sequence,
            mode: executionMode.hidEventFactoryMode,
            batchSize: batchSize
        )
        logger.info().log("Execution plan created")
        
        // Show execution plan if dry-run
        if dryRun {
            print("\\n🔍 Dry Run - Execution Plan:")
            print("Mode: \\(executionMode.rawValue)")
            print("Estimated Duration: \\(String(format: "%.2f", executionPlan.estimatedExecutionTime()))s")
            
            switch executionPlan {
            case .batch(let event):
                print("Batch Execution: Single composite event")
            case .streaming(let events):
                print("Streaming Execution: \\(events.count) individual events")
            }
            
            print("\\n✅ Sequence is ready for execution")
            return
        }
        
        // Execute the sequence
        logger.info().log("Starting event sequence execution...")
        let startTime = Date()
        
        do {
            switch executionPlan {
            case .composite(let compositeEvent):
                try await executeCompositeMode(compositeEvent, logger: logger)
                
            case .sequential(let events):
                try await executeSequentialMode(events, sequence: sequence, logger: logger)
                
            case .batch(let batches):
                try await executeBatchMode(batches, sequence: sequence, logger: logger)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            logger.info().log("Event sequence completed successfully in \\(String(format: "%.2f", duration))s")
            print("✅ Event sequence executed successfully (\\(String(format: "%.2f", duration))s)")
            
        } catch {
            logger.error().log("Event sequence execution failed: \\(error.localizedDescription)")
            throw CLIError(errorDescription: "Execution error: \\(error.localizedDescription)")
        }
    }
    
    // MARK: - Execution Methods
    
    private func executeCompositeMode(_ event: FBSimulatorHIDEvent, logger: AxeLogger) async throws {
        if verbose {
            print("🚀 Executing composite mode (single IPC call)...")
        }
        
        try await HIDInteractor.performHIDEvent(
            event,
            for: simulatorUDID,
            logger: logger
        )
        
        if verbose {
            print("✅ Composite execution completed")
        }
    }
    
    private func executeSequentialMode(
        _ events: [FBSimulatorHIDEvent],
        sequence: EventSequence,
        logger: AxeLogger
    ) async throws {
        if verbose {
            print("🚀 Executing sequential mode (\\(events.count) individual events)...")
        }
        
        let stopOnError = sequence.settings?.stopOnError ?? true
        var executedCount = 0
        
        for (index, event) in events.enumerated() {
            do {
                if verbose {
                    print("  Executing event \\(index + 1)/\\(events.count)...")
                }
                
                try await HIDInteractor.performHIDEvent(
                    event,
                    for: simulatorUDID,
                    logger: logger
                )
                
                executedCount += 1
                
            } catch {
                logger.error().log("Event \\(index + 1) failed: \\(error.localizedDescription)")
                
                if stopOnError {
                    throw CLIError(errorDescription: "Event \\(index + 1) failed: \\(error.localizedDescription)")
                } else {
                    if verbose {
                        print("  ⚠️ Event \\(index + 1) failed, continuing...")
                    }
                }
            }
        }
        
        if verbose {
            print("✅ Sequential execution completed (\\(executedCount)/\\(events.count) events)")
        }
    }
    
    private func executeBatchMode(
        _ batches: [FBSimulatorHIDEvent],
        sequence: EventSequence,
        logger: AxeLogger
    ) async throws {
        if verbose {
            print("🚀 Executing batch mode (\\(batches.count) batches)...")
        }
        
        let stopOnError = sequence.settings?.stopOnError ?? true
        var executedCount = 0
        
        for (index, batch) in batches.enumerated() {
            do {
                if verbose {
                    print("  Executing batch \\(index + 1)/\\(batches.count)...")
                }
                
                try await HIDInteractor.performHIDEvent(
                    batch,
                    for: simulatorUDID,
                    logger: logger
                )
                
                executedCount += 1
                
            } catch {
                logger.error().log("Batch \\(index + 1) failed: \\(error.localizedDescription)")
                
                if stopOnError {
                    throw CLIError(errorDescription: "Batch \\(index + 1) failed: \\(error.localizedDescription)")
                } else {
                    if verbose {
                        print("  ⚠️ Batch \\(index + 1) failed, continuing...")
                    }
                }
            }
        }
        
        if verbose {
            print("✅ Batch execution completed (\\(executedCount)/\\(batches.count) batches)")
        }
    }
}

// MARK: - Execution Mode Option

enum ExecutionModeOption: String, ExpressibleByArgument, CaseIterable {
    case composite = "composite"
    case sequential = "sequential"
    case batch = "batch"
    
    var hidEventFactoryMode: HIDEventFactory.ExecutionMode {
        switch self {
        case .composite:
            return .composite
        case .sequential:
            return .sequential
        case .batch:
            return .batch
        }
    }
    
    static var allValueStrings: [String] {
        return allCases.map { $0.rawValue }
    }
}

// MARK: - Helper Extensions

extension Stream {
    
    /// Show progress for long-running sequences
    private func showProgress(current: Int, total: Int, eventId: String?) {
        if verbose {
            let percentage = Int((Double(current) / Double(total)) * 100)
            let idString = eventId.map { " (\\($0))" } ?? ""
            print("  Progress: \\(current)/\\(total) (\\(percentage)%)\\(idString)")
        }
    }
    
    /// Validate execution constraints
    private func validateExecutionConstraints(_ sequence: EventSequence) throws {
        // Check max execution time
        if let maxTime = sequence.settings?.maxExecutionTime {
            let summary = HIDEventFactory.getEventSummary(sequence)
            if summary.estimatedDuration > maxTime {
                throw CLIError(errorDescription: "Estimated execution time (\\(String(format: "%.2f", summary.estimatedDuration))s) exceeds maximum allowed time (\\(String(format: "%.2f", maxTime))s)")
            }
        }
        
        // Check for reasonable sequence length
        if sequence.events.count > 1000 {
            throw CLIError(errorDescription: "Sequence too long: \\(sequence.events.count) events (maximum recommended: 1000)")
        }
    }
}
