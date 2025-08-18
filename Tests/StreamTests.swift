import Testing
import Foundation
@testable import AXe

struct StreamTests {
    
    // MARK: - Event Sequence Parsing Tests
    
    @Test("Parse simple event sequence from JSON")
    func testParseSimpleEventSequence() throws {
        let jsonString = """
        {
          "events": [
            {
              "type": "tap",
              "parameters": {
                "x": 100,
                "y": 200
              }
            },
            {
              "type": "delay",
              "parameters": {
                "duration": 1.0
              }
            }
          ]
        }
        """
        
        let sequence = try EventSequenceParser.parseFromJSON(jsonString)
        
        #expect(sequence.events.count == 2)
        #expect(sequence.events[0].type == .tap)
        #expect(sequence.events[1].type == .delay)
        
        // Verify tap parameters
        if case .tap(let tapParams) = sequence.events[0].parameters {
            #expect(tapParams.x == 100)
            #expect(tapParams.y == 200)
        } else {
            Issue.record("Expected tap parameters")
        }
        
        // Verify delay parameters
        if case .delay(let delayParams) = sequence.events[1].parameters {
            #expect(delayParams.duration == 1.0)
        } else {
            Issue.record("Expected delay parameters")
        }
    }
    
    @Test("Parse event sequence with metadata and settings")
    func testParseEventSequenceWithMetadata() throws {
        let jsonString = """
        {
          "metadata": {
            "name": "Test Sequence",
            "description": "A test sequence",
            "version": "1.0",
            "author": "Test Author",
            "tags": ["test", "demo"]
          },
          "settings": {
            "default_delay": 0.5,
            "stop_on_error": true,
            "max_execution_time": 30.0,
            "validate_before_execution": true
          },
          "events": [
            {
              "type": "tap",
              "parameters": {
                "x": 100,
                "y": 200
              },
              "pre_delay": 0.2,
              "post_delay": 0.3,
              "id": "test_tap",
              "description": "Test tap event"
            }
          ]
        }
        """
        
        let sequence = try EventSequenceParser.parseFromJSON(jsonString)
        
        // Verify metadata
        #expect(sequence.metadata?.name == "Test Sequence")
        #expect(sequence.metadata?.description == "A test sequence")
        #expect(sequence.metadata?.version == "1.0")
        #expect(sequence.metadata?.author == "Test Author")
        #expect(sequence.metadata?.tags == ["test", "demo"])
        
        // Verify settings
        #expect(sequence.settings?.defaultDelay == 0.5)
        #expect(sequence.settings?.stopOnError == true)
        #expect(sequence.settings?.maxExecutionTime == 30.0)
        #expect(sequence.settings?.validateBeforeExecution == true)
        
        // Verify event details
        let event = sequence.events[0]
        #expect(event.preDelay == 0.2)
        #expect(event.postDelay == 0.3)
        #expect(event.id == "test_tap")
        #expect(event.description == "Test tap event")
    }
    
    @Test("Parse all event types")
    func testParseAllEventTypes() throws {
        let jsonString = """
        {
          "events": [
            {
              "type": "tap",
              "parameters": { "x": 100, "y": 200 }
            },
            {
              "type": "swipe",
              "parameters": {
                "start_x": 50, "start_y": 100,
                "end_x": 150, "end_y": 200,
                "duration": 1.0, "delta": 50
              }
            },
            {
              "type": "type",
              "parameters": { "text": "Hello" }
            },
            {
              "type": "key",
              "parameters": { "keycode": 40, "duration": 0.5 }
            },
            {
              "type": "key_sequence",
              "parameters": { "keycodes": [11, 8, 15], "delay": 0.1 }
            },
            {
              "type": "button",
              "parameters": { "button": "home", "duration": 1.0 }
            },
            {
              "type": "touch",
              "parameters": { "x": 200, "y": 300, "duration": 2.0 }
            },
            {
              "type": "delay",
              "parameters": { "duration": 1.5 }
            },
            {
              "type": "gesture",
              "parameters": {
                "start_x": 100, "start_y": 200,
                "end_x": 200, "end_y": 300,
                "duration": 0.8, "delta": 30
              }
            }
          ]
        }
        """
        
        let sequence = try EventSequenceParser.parseFromJSON(jsonString)
        
        #expect(sequence.events.count == 9)
        
        let expectedTypes: [HIDEventType] = [
            .tap, .swipe, .type, .key, .keySequence, .button, .touch, .delay, .gesture
        ]
        
        for (index, expectedType) in expectedTypes.enumerated() {
            #expect(sequence.events[index].type == expectedType)
        }
    }
    
    // MARK: - Validation Tests
    
    @Test("Validate event sequence with valid data")
    func testValidateValidEventSequence() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        // Should not throw
        try sequence.validate()
    }
    
    @Test("Validate event sequence with invalid coordinates")
    func testValidateInvalidCoordinates() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: -10, y: 200)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        #expect(throws: EventSequenceError.self) {
            try sequence.validate()
        }
    }
    
    @Test("Validate empty event sequence")
    func testValidateEmptyEventSequence() throws {
        let sequence = EventSequence(events: [])
        
        #expect(throws: EventSequenceError.self) {
            try sequence.validate()
        }
    }
    
    @Test("Validate event sequence with invalid keycode")
    func testValidateInvalidKeycode() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .key,
                    parameters: .key(KeyParameters(keycode: 300, duration: nil)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        #expect(throws: EventSequenceError.self) {
            try sequence.validate()
        }
    }
    
    @Test("Validate event sequence with invalid delay")
    func testValidateInvalidDelay() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: -1.0, // Invalid negative delay
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        #expect(throws: EventSequenceError.self) {
            try sequence.validate()
        }
    }
    
    // MARK: - HID Event Factory Tests
    
    @Test("Create HID events from simple sequence")
    func testCreateHIDEventsFromSequence() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: 0.5,
                    postDelay: 0.3,
                    id: nil,
                    description: nil
                ),
                HIDEventDefinition(
                    type: .delay,
                    parameters: .delay(DelayParameters(duration: 1.0)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        let hidEvents = try HIDEventFactory.createHIDEvents(from: sequence)
        
        // Should have: pre-delay, tap, post-delay, delay
        #expect(hidEvents.count == 4)
    }
    
    @Test("Create composite HID event from sequence")
    func testCreateCompositeHIDEvent() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                ),
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 300, y: 400)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        let compositeEvent = try HIDEventFactory.createCompositeHIDEvent(from: sequence)
        
        // Should create a composite event (exact type checking would require access to FBSimulatorHIDEvent internals)
        // For now, just verify it doesn't throw
    }
    
    @Test("Validate event sequence factory")
    func testValidateEventSequenceFactory() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        // Should not throw
        try HIDEventFactory.validateEventSequence(sequence)
    }
    
    @Test("Get event sequence summary")
    func testGetEventSequenceSummary() throws {
        let sequence = EventSequence(
            events: [
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 100, y: 200)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                ),
                HIDEventDefinition(
                    type: .tap,
                    parameters: .tap(TapParameters(x: 300, y: 400)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                ),
                HIDEventDefinition(
                    type: .delay,
                    parameters: .delay(DelayParameters(duration: 1.0)),
                    preDelay: nil,
                    postDelay: nil,
                    id: nil,
                    description: nil
                )
            ]
        )
        
        let summary = HIDEventFactory.getEventSummary(sequence)
        
        #expect(summary.totalEvents == 3)
        #expect(summary.eventCounts[.tap] == 2)
        #expect(summary.eventCounts[.delay] == 1)
        #expect(summary.estimatedDuration > 0)
        #expect(!summary.hasErrors)
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Handle invalid JSON")
    func testHandleInvalidJSON() throws {
        let invalidJSON = "{ invalid json }"
        
        #expect(throws: EventSequenceParseError.self) {
            try EventSequenceParser.parseFromJSON(invalidJSON)
        }
    }
    
    @Test("Handle missing required fields")
    func testHandleMissingRequiredFields() throws {
        let jsonWithMissingFields = """
        {
          "events": [
            {
              "type": "tap"
            }
          ]
        }
        """
        
        #expect(throws: EventSequenceParseError.self) {
            try EventSequenceParser.parseFromJSON(jsonWithMissingFields)
        }
    }
    
    @Test("Handle unsupported event type")
    func testHandleUnsupportedEventType() throws {
        let jsonWithUnsupportedType = """
        {
          "events": [
            {
              "type": "unsupported_type",
              "parameters": {}
            }
          ]
        }
        """
        
        #expect(throws: EventSequenceParseError.self) {
            try EventSequenceParser.parseFromJSON(jsonWithUnsupportedType)
        }
    }
    
    // MARK: - Example Generation Tests
    
    @Test("Generate example JSON")
    func testGenerateExampleJSON() throws {
        let exampleJSON = EventSequenceParser.generateExampleJSON()
        
        #expect(!exampleJSON.isEmpty)
        #expect(exampleJSON.contains("events"))
        
        // Verify the generated JSON is valid by parsing it
        let sequence = try EventSequenceParser.parseFromJSON(exampleJSON)
        #expect(sequence.events.count > 0)
    }
    
    @Test("Generate comprehensive example JSON")
    func testGenerateComprehensiveExampleJSON() throws {
        let comprehensiveJSON = EventSequenceParser.generateComprehensiveExampleJSON()
        
        #expect(!comprehensiveJSON.isEmpty)
        #expect(comprehensiveJSON.contains("events"))
        
        // Verify the generated JSON is valid by parsing it
        let sequence = try EventSequenceParser.parseFromJSON(comprehensiveJSON)
        #expect(sequence.events.count > 5) // Should have multiple event types
    }
    
    @Test("Generate JSON schema")
    func testGenerateJSONSchema() throws {
        let schema = EventSequenceParser.generateJSONSchema()
        
        #expect(!schema.isEmpty)
        #expect(schema.contains("$schema"))
        #expect(schema.contains("properties"))
        #expect(schema.contains("events"))
    }
    
    // MARK: - File Operations Tests
    
    @Test("Parse from temporary file")
    func testParseFromFile() throws {
        let jsonContent = """
        {
          "events": [
            {
              "type": "tap",
              "parameters": {
                "x": 100,
                "y": 200
              }
            }
          ]
        }
        """
        
        // Create temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sequence.json")
        try jsonContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let sequence = try EventSequenceParser.parseFromFile(tempURL.path)
        
        #expect(sequence.events.count == 1)
        #expect(sequence.events[0].type == .tap)
    }
}

