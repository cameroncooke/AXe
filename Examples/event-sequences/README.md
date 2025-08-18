# AXe Event Sequences

This directory contains example JSON files demonstrating the AXe `stream` command functionality for executing complex sequences of HID events.

## Overview

The `stream` command allows you to execute sequences of HID events (taps, swipes, typing, etc.) with precise timing control. This is useful for:

- **UI Automation**: Automate complex user interactions
- **Testing**: Create repeatable test sequences
- **Game Input**: Simulate complex game controls
- **Accessibility Testing**: Test app behavior with various input patterns

## Quick Start

### Generate an Example

```bash
# Generate a simple example
axe stream --example > my-sequence.json

# Generate a comprehensive example with all event types
axe stream --comprehensive-example > comprehensive.json
```

### Execute a Sequence

```bash
# Execute from file
axe stream --file simple-tap-sequence.json --udid YOUR_SIMULATOR_UDID

# Execute inline JSON
axe stream --json '{"events": [{"type": "tap", "parameters": {"x": 100, "y": 200}}]}' --udid YOUR_SIMULATOR_UDID

# Execute from stdin
cat login-automation.json | axe stream --stdin --udid YOUR_SIMULATOR_UDID
```

### Validation and Testing

```bash
# Validate without executing
axe stream --file my-sequence.json --validate-only

# Dry run to see execution plan
axe stream --file my-sequence.json --dry-run --udid YOUR_SIMULATOR_UDID

# Show detailed summary
axe stream --file my-sequence.json --summary --udid YOUR_SIMULATOR_UDID
```

## JSON Format

### Basic Structure

```json
{
  "metadata": {
    "name": "Sequence Name",
    "description": "What this sequence does",
    "version": "1.0",
    "author": "Your Name",
    "tags": ["tag1", "tag2"]
  },
  "settings": {
    "default_delay": 0.5,
    "stop_on_error": true,
    "max_execution_time": 60.0,
    "validate_before_execution": true
  },
  "events": [
    {
      "type": "event_type",
      "parameters": { /* event-specific parameters */ },
      "pre_delay": 0.5,
      "post_delay": 0.3,
      "id": "unique_event_id",
      "description": "What this event does"
    }
  ]
}
```

### Event Types

#### Tap
```json
{
  "type": "tap",
  "parameters": {
    "x": 100,
    "y": 200
  }
}
```

#### Swipe
```json
{
  "type": "swipe",
  "parameters": {
    "start_x": 50,
    "start_y": 300,
    "end_x": 350,
    "end_y": 300,
    "duration": 1.0,
    "delta": 50
  }
}
```

#### Type Text
```json
{
  "type": "type",
  "parameters": {
    "text": "Hello, World!"
  }
}
```

#### Key Press
```json
{
  "type": "key",
  "parameters": {
    "keycode": 40,
    "duration": 0.5
  }
}
```

#### Key Sequence
```json
{
  "type": "key_sequence",
  "parameters": {
    "keycodes": [11, 8, 15, 15, 18],
    "delay": 0.1
  }
}
```

#### Button Press
```json
{
  "type": "button",
  "parameters": {
    "button": "home",
    "duration": 1.0
  }
}
```

Valid buttons: `home`, `lock`, `volumeUp`, `volumeDown`, `siri`

#### Touch and Hold
```json
{
  "type": "touch",
  "parameters": {
    "x": 200,
    "y": 400,
    "duration": 2.0
  }
}
```

#### Delay
```json
{
  "type": "delay",
  "parameters": {
    "duration": 1.5
  }
}
```

#### Gesture
```json
{
  "type": "gesture",
  "parameters": {
    "start_x": 200,
    "start_y": 500,
    "end_x": 200,
    "end_y": 100,
    "duration": 0.8,
    "delta": 30
  }
}
```

## Execution Modes

### Composite Mode (Default)
All events are combined into a single composite operation and executed together. This is more efficient but provides less granular control.

```bash
axe stream --file sequence.json --mode composite --udid UDID
```

### Sequential Mode
Events are executed sequentially with real-time timing. This provides more control and better error handling for individual events.

```bash
axe stream --file sequence.json --mode sequential --udid UDID
```

## Timing Control

### Batch Mode
Events are executed in configurable batches, providing a balance between performance and control.

```bash
axe stream --file sequence.json --mode batch --batch-size 5 --udid UDID
```

### Event-Level Timing
- `pre_delay`: Delay before executing the event
- `post_delay`: Delay after executing the event

### Global Timing
- `default_delay`: Default delay between events (in settings)
- Event-specific durations (for swipes, touches, key holds)

### Example with Complex Timing
```json
{
  "settings": {
    "default_delay": 0.3
  },
  "events": [
    {
      "type": "tap",
      "parameters": {"x": 100, "y": 200},
      "pre_delay": 1.0,
      "post_delay": 0.5
    },
    {
      "type": "swipe",
      "parameters": {
        "start_x": 50, "start_y": 300,
        "end_x": 350, "end_y": 300,
        "duration": 2.0
      }
    }
  ]
}
```

## Error Handling

### Stop on Error (Default)
```json
{
  "settings": {
    "stop_on_error": true
  }
}
```

### Continue on Error
```json
{
  "settings": {
    "stop_on_error": false
  }
}
```

## Example Files

- **`simple-tap-sequence.json`**: Basic tap sequence with delays
- **`login-automation.json`**: Automated login form filling
- **`swipe-navigation.json`**: Navigation using swipe gestures
- **`game-input.json`**: Complex game input with multiple event types

## Best Practices

1. **Start Simple**: Begin with basic tap and delay sequences
2. **Use IDs**: Add unique IDs to events for easier debugging
3. **Add Descriptions**: Document what each event does
4. **Test Incrementally**: Use `--dry-run` and `--validate-only` during development
5. **Handle Errors**: Consider whether to stop or continue on errors
6. **Optimize Timing**: Adjust delays based on app responsiveness
7. **Use Streaming Mode**: For complex sequences where individual event control is important

## Troubleshooting

### Validation Errors
```bash
# Check for validation errors
axe stream --file sequence.json --validate-only
```

### Timing Issues
- Use `--verbose` to see detailed execution information
- Increase delays if events are happening too quickly
- Use streaming mode for better timing control

### Coordinate Problems
- Use AXe's other commands to find correct coordinates
- Test individual taps before adding to sequences

### Text Input Issues
- Only US keyboard characters are supported
- Use key sequences for special characters if needed

## JSON Schema

Generate the JSON schema for validation:

```bash
axe stream --schema > sequence-schema.json
```

This schema can be used with JSON editors for validation and auto-completion.

