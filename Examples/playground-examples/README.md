# AXe Playground Examples

This directory contains practical examples using the included Playground iOS app to demonstrate the different execution modes of the `axe stream` command.

## 🎯 **Quick Start**

1. **Launch the Playground app** in your simulator
2. **Get the simulator UDID**: `xcrun simctl list devices | grep Booted`
3. **Run examples** using the commands below

## 📱 **Playground App Overview**

The Playground app includes several test views perfect for demonstrating HID event sequences:

- **Tap Test**: Shows coordinates of CLI taps with visual indicators
- **Text Input**: Displays text typed by CLI commands
- **Swipe Test**: Visualizes CLI swipe paths and gestures
- **Touch Control**: Shows touch down/up events
- **Key Press**: Detects CLI key events
- **Button Test**: Hardware button press detection

## 🚀 **Execution Mode Examples**

### 1. Composite Mode (Default) - Maximum Performance

**Best for**: Fixed sequences, performance-critical automation, simple workflows

#### Example 1: Quick App Navigation
```bash
# Navigate to Tap Test and perform 3 quick taps
axe stream --file playground-examples/composite-navigation.json --mode composite --udid YOUR_UDID
```

#### Example 2: Text Input Workflow
```bash
# Navigate to text input and type a message
axe stream --file playground-examples/composite-text-input.json --mode composite --udid YOUR_UDID
```

### 2. Sequential Mode - Maximum Control

**Best for**: Dynamic sequences, debugging, conditional logic, precise timing

#### Example 1: Interactive Tap Testing
```bash
# Navigate to Tap Test with precise timing between taps
axe stream --file playground-examples/sequential-tap-test.json --mode sequential --udid YOUR_UDID
```

#### Example 2: Complex Swipe Patterns
```bash
# Navigate to Swipe Test and perform complex gesture patterns
axe stream --file playground-examples/sequential-swipe-patterns.json --mode sequential --udid YOUR_UDID
```

### 3. Batch Mode - Balanced Performance & Control

**Best for**: Large sequences, moderate control needs, performance optimization

#### Example 1: Multi-Screen Testing
```bash
# Test multiple screens with batched operations
axe stream --file playground-examples/batch-multi-screen.json --mode batch --batch-size 5 --udid YOUR_UDID
```

#### Example 2: Stress Testing
```bash
# Perform stress testing with batched events
axe stream --file playground-examples/batch-stress-test.json --mode batch --batch-size 10 --udid YOUR_UDID
```

## 📊 **Performance Comparison**

| Example | Events | Composite | Sequential | Batch (5) |
|---------|--------|-----------|------------|-----------|
| Navigation | 5 | ~0.1s | ~2.5s | ~1.0s |
| Text Input | 15 | ~0.2s | ~7.5s | ~3.0s |
| Swipe Test | 20 | ~0.3s | ~10.0s | ~4.0s |
| Multi-Screen | 50 | ~0.5s | ~25.0s | ~10.0s |

*Times are approximate and depend on simulator performance*

## 🎮 **Interactive Examples**

### Real-time Tap Visualization
Watch taps appear in real-time on the Tap Test screen:
```bash
axe stream --file playground-examples/realtime-taps.json --mode sequential --udid YOUR_UDID
```

### Text Typing Animation
See text appear character by character:
```bash
axe stream --file playground-examples/typing-animation.json --mode sequential --udid YOUR_UDID
```

### Gesture Choreography
Complex multi-touch gestures with precise timing:
```bash
axe stream --file playground-examples/gesture-choreography.json --mode sequential --udid YOUR_UDID
```

## 🔧 **Customization Tips**

1. **Adjust Delays**: Modify `delayAfter` values for different timing
2. **Batch Sizes**: Experiment with `--batch-size` for optimal performance
3. **Screen Coordinates**: Use the Playground app to find exact coordinates
4. **Accessibility IDs**: Target specific UI elements using accessibility identifiers

## 🐛 **Debugging**

Use the `--dry-run` flag to preview sequences without execution:
```bash
axe stream --file playground-examples/any-example.json --dry-run --udid YOUR_UDID
```

Use `--verbose` for detailed execution logs:
```bash
axe stream --file playground-examples/any-example.json --mode sequential --verbose --udid YOUR_UDID
```

