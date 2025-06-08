import Foundation

// MARK: - Event Sequence Parser

struct EventSequenceParser {
    
    // MARK: - Parsing Methods
    
    /// Parse an event sequence from JSON string
    static func parseFromJSON(_ jsonString: String) throws -> EventSequence {
        guard let data = jsonString.data(using: .utf8) else {
            throw EventSequenceParseError.invalidJSONString
        }
        
        return try parseFromData(data)
    }
    
    /// Parse an event sequence from JSON data
    static func parseFromData(_ data: Data) throws -> EventSequence {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        do {
            let sequence = try decoder.decode(EventSequence.self, from: data)
            try sequence.validate()
            return sequence
        } catch let error as DecodingError {
            throw EventSequenceParseError.decodingError(error)
        } catch let error as EventSequenceError {
            throw EventSequenceParseError.validationError(error)
        } catch {
            throw EventSequenceParseError.unknownError(error)
        }
    }
    
    /// Parse an event sequence from a file
    static func parseFromFile(_ filePath: String) throws -> EventSequence {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            return try parseFromData(data)
        } catch let error as EventSequenceParseError {
            throw error
        } catch {
            throw EventSequenceParseError.fileReadError(filePath, error)
        }
    }
    
    /// Parse an event sequence from stdin
    static func parseFromStdin() throws -> EventSequence {
        var input = ""
        while let line = readLine() {
            if !input.isEmpty {
                input += "\n"
            }
            input += line
        }
        
        guard !input.isEmpty else {
            throw EventSequenceParseError.emptyInput
        }
        
        return try parseFromJSON(input)
    }
    
    // MARK: - Validation Helpers
    
    /// Validate a JSON string without fully parsing it
    static func validateJSON(_ jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else {
            return false
        }
        
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return true
        } catch {
            return false
        }
    }
    
    /// Get detailed validation errors for a JSON string
    static func getValidationErrors(_ jsonString: String) -> [String] {
        var errors: [String] = []
        
        do {
            _ = try parseFromJSON(jsonString)
        } catch let error as EventSequenceParseError {
            errors.append(error.localizedDescription)
        } catch {
            errors.append(error.localizedDescription)
        }
        
        return errors
    }
    
    // MARK: - Example Generation
    
    /// Generate an example event sequence JSON
    static func generateExampleJSON() -> String {
        let exampleSequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: 0.5,
                    postDelay: nil,
                    id: "tap_1",
                    description: "Tap on button"
                ),
                HIDEventDefinition(
                    type: .delay,
                    parameters: .delay(DelayParameters(duration: 1.0)),
                    preDelay: nil,
                    postDelay: nil,
                    id: "wait_1",
                    description: "Wait for animation"
                ),
                HIDEventDefinition(
                    type: .type,
                    parameters: .type(TypeParameters(text: "Hello World")),
                    preDelay: nil,
                    postDelay: 0.2,
                    id: "type_1",
                    description: "Type greeting"
                ),
                HIDEventDefinition(
                    type: .swipe,
                    parameters: .swipe(SwipeParameters(
                        startX: 100,
                        startY: 300,
                        endX: 300,
                        endY: 300,
                        duration: 0.5,
                        delta: 50
                    )),
                    preDelay: nil,
                    postDelay: nil,
                    id: "swipe_1",
                    description: "Swipe right"
                )
            ],
            metadata: SequenceMetadata(
                name: "Example Sequence",
                description: "A simple example showing different event types",
                version: "1.0",
                author: "AXe",
                tags: ["example", "demo"]
            ),
            settings: SequenceSettings(
                defaultDelay: 0.1,
                stopOnError: true,
                maxExecutionTime: 30.0,
                validateBeforeExecution: true
            )
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        do {
            let data = try encoder.encode(exampleSequence)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to generate example\"}"
        }
    }
    
    /// Generate a comprehensive example with all event types
    static func generateComprehensiveExampleJSON() -> String {
        let exampleSequence = EventSequence(
            events: [
                // Tap event
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: 0.5,
                    postDelay: 0.2,
                    id: "tap_example",
                    description: "Tap at coordinates (100, 200)"
                ),
                
                // Swipe event
                HIDEventDefinition(
                    type: .swipe,
                    parameters: .swipe(SwipeParameters(
                        startX: 50,
                        startY: 300,
                        endX: 350,
                        endY: 300,
                        duration: 1.0,
                        delta: 50
                    )),
                    preDelay: nil,
                    postDelay: nil,
                    id: "swipe_example",
                    description: "Swipe from left to right"
                ),
                
                // Type event
                HIDEventDefinition(
                    type: .type,
                    parameters: .type(TypeParameters(text: "Hello, World!")),
                    preDelay: 0.3,
                    postDelay: nil,
                    id: "type_example",
                    description: "Type a greeting message"
                ),
                
                // Key event
                HIDEventDefinition(
                    type: .key,
                    parameters: .key(KeyParameters(keycode: 40, duration: nil)),
                    preDelay: nil,
                    postDelay: nil,
                    id: "key_example",
                    description: "Press Enter key (keycode 40)"
                ),
                
                // Key sequence event
                HIDEventDefinition(
                    type: .keySequence,
                    parameters: .keySequence(KeySequenceParameters(
                        keycodes: [11, 8, 15, 15, 18], // "hello"
                        delay: 0.1
                    )),
                    preDelay: nil,
                    postDelay: nil,
                    id: "key_sequence_example",
                    description: "Type 'hello' using keycodes"
                ),
                
                // Button event
                HIDEventDefinition(
                    type: .button,
                    parameters: .button(ButtonParameters(button: "home", duration: nil)),
                    preDelay: 0.5,
                    postDelay: nil,
                    id: "button_example",
                    description: "Press home button"
                ),
                
                // Touch event
                HIDEventDefinition(
                    type: .touch,
                    parameters: .touch(TouchParameters(x: 200, y: 400, duration: 2.0)),
                    preDelay: nil,
                    postDelay: nil,
                    id: "touch_example",
                    description: "Long touch for 2 seconds"
                ),
                
                // Delay event
                HIDEventDefinition(
                    type: .delay,
                    parameters: .delay(DelayParameters(duration: 1.5)),
                    preDelay: nil,
                    postDelay: nil,
                    id: "delay_example",
                    description: "Wait for 1.5 seconds"
                ),
                
                // Gesture event
                HIDEventDefinition(
                    type: .gesture,
                    parameters: .gesture(GestureParameters(
                        startX: 200,
                        startY: 500,
                        endX: 200,
                        endY: 100,
                        duration: 0.8,
                        delta: 30
                    )),
                    preDelay: nil,
                    postDelay: nil,
                    id: "gesture_example",
                    description: "Swipe up gesture"
                )
            ],
            metadata: SequenceMetadata(
                name: "Comprehensive Example",
                description: "Example showing all supported event types",
                version: "1.0",
                author: "AXe Team",
                tags: ["comprehensive", "example", "all-events"]
            ),
            settings: SequenceSettings(
                defaultDelay: 0.1,
                stopOnError: true,
                maxExecutionTime: 60.0,
                validateBeforeExecution: true
            )
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        do {
            let data = try encoder.encode(exampleSequence)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"Failed to generate comprehensive example\"}"
        }
    }
}

// MARK: - Parse Error Types

enum EventSequenceParseError: Error, LocalizedError {
    case invalidJSONString
    case emptyInput
    case fileReadError(String, Error)
    case decodingError(DecodingError)
    case validationError(EventSequenceError)
    case unknownError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidJSONString:
            return "Invalid JSON string - could not convert to data"
        case .emptyInput:
            return "Empty input provided"
        case .fileReadError(let path, let error):
            return "Failed to read file '\(path)': \(error.localizedDescription)"
        case .decodingError(let error):
            return "JSON decoding error: \(formatDecodingError(error))"
        case .validationError(let error):
            return "Validation error: \(error.localizedDescription)"
        case .unknownError(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
    
    private func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .valueNotFound(let type, let context):
            return "Value not found for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .keyNotFound(let key, let context):
            return "Key '\(key.stringValue)' not found at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Data corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return "Unknown decoding error"
        }
    }
}

// MARK: - Input Source Detection

extension EventSequenceParser {
    
    /// Determine the input source and parse accordingly
    static func parseFromSource(
        jsonString: String?,
        filePath: String?,
        useStdin: Bool
    ) throws -> EventSequence {
        
        // Count how many input sources are specified
        let sourceCount = [jsonString != nil, filePath != nil, useStdin].filter { $0 }.count
        
        guard sourceCount == 1 else {
            throw EventSequenceParseError.invalidJSONString // TODO: Add specific error for multiple sources
        }
        
        if let jsonString = jsonString {
            return try parseFromJSON(jsonString)
        } else if let filePath = filePath {
            return try parseFromFile(filePath)
        } else if useStdin {
            return try parseFromStdin()
        } else {
            throw EventSequenceParseError.emptyInput
        }
    }
}

// MARK: - JSON Schema Generation

extension EventSequenceParser {
    
    /// Generate a JSON schema for event sequences
    static func generateJSONSchema() -> String {
        return """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "AXe Event Sequence",
          "description": "Schema for AXe HID event sequences",
          "type": "object",
          "properties": {
            "metadata": {
              "type": "object",
              "properties": {
                "name": { "type": "string" },
                "description": { "type": "string" },
                "version": { "type": "string" },
                "author": { "type": "string" },
                "tags": {
                  "type": "array",
                  "items": { "type": "string" }
                }
              }
            },
            "settings": {
              "type": "object",
              "properties": {
                "default_delay": { "type": "number", "minimum": 0, "maximum": 60 },
                "stop_on_error": { "type": "boolean" },
                "max_execution_time": { "type": "number", "minimum": 0, "maximum": 3600 },
                "validate_before_execution": { "type": "boolean" }
              }
            },
            "events": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "type": {
                    "type": "string",
                    "enum": ["tap", "swipe", "type", "key", "key_sequence", "button", "touch", "delay", "gesture"]
                  },
                  "parameters": { "type": "object" },
                  "pre_delay": { "type": "number", "minimum": 0, "maximum": 60 },
                  "post_delay": { "type": "number", "minimum": 0, "maximum": 60 },
                  "id": { "type": "string" },
                  "description": { "type": "string" }
                },
                "required": ["type", "parameters"]
              }
            }
          },
          "required": ["events"]
        }
        """
    }
}

