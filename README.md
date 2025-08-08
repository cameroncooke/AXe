<img src="banner.png" alt="AXe" width="600"/>

AXe is a comprehensive CLI tool for interacting with iOS Simulators using Apple's Accessibility APIs and HID (Human Interface Device) functionality.

[![CI](https://github.com/cameroncooke/AXe/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/cameroncooke/AXe/actions/workflows/build-and-release.yml)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

![AxeDemo](https://github.com/user-attachments/assets/9eafa5d5-3cef-4e39-82c5-7b9d41fe4548)

- [Features](#features)
  - [Touch \& Gestures](#touch--gestures)
  - [Input \& Text](#input--text)
  - [Hardware Buttons](#hardware-buttons)
  - [Timing Controls](#timing-controls)
  - [Accessibility](#accessibility)
- [Quick Start](#quick-start)
  - [Installation](#installation)
    - [Install via Homebrew](#install-via-homebrew)
    - [Build from source](#build-from-source)
  - [Basic Usage](#basic-usage)
- [Commands Overview](#commands-overview)
  - [**Touch \& Gestures**](#touch--gestures-1)
  - [**Gesture Presets**](#gesture-presets)
  - [**Text Input**](#text-input)
  - [**Hardware Buttons**](#hardware-buttons-1)
  - [**Keyboard Control**](#keyboard-control)
  - [**Video Streaming**](#video-streaming)
  - [**Accessibility \& Info**](#accessibility--info)
- [Architecture](#architecture)
  - [Why AXe?](#why-axe)
- [Gesture Presets Reference](#gesture-presets-reference)
- [Contributing](#contributing)
- [Licence](#licence)


## Features

AXe provides complete iOS Simulator automation capabilities:

### Touch & Gestures
- **Tap**: Precise touch events at specific coordinates with timing controls
- **Swipe**: Multi-touch gestures with configurable duration and delta
- **Touch Control**: Low-level touch down/up events for advanced gesture control
- **Gesture Presets**: Common gesture patterns (scroll-up, scroll-down, scroll-left, scroll-right, edge swipes)

### Input & Text
- **Text Input**: Comprehensive text typing with automatic shift key handling
- **Key Presses**: Individual key presses by HID keycode
- **Key Sequences**: Multi-key sequences with timing control
- **Multiple Input Methods**: Direct text, stdin, or file input

### Hardware Buttons
- **Home Button**: iOS home button simulation
- **Lock/Power Button**: Power button with duration control
- **Side Button**: iPhone X+ side button
- **Siri Button**: Siri activation button
- **Apple Pay Button**: Apple Pay button simulation

### Timing Controls
- **Pre/Post Delays**: Configurable delays before and after actions
- **Duration Control**: Precise timing for gestures and button presses
- **Sequence Timing**: Custom delays between key sequences
- **Complex Automation**: Multi-step workflows with precise timing

### Video Streaming
- **Screenshot-based Streaming**: Capture simulator video at 1-30 FPS
- **Multiple Output Formats**: MJPEG, raw JPEG, ffmpeg-compatible, BGRA
- **Configurable Quality**: Adjust JPEG quality and scale factor
- **Real-time Performance**: Efficient frame timing for smooth playback

### Accessibility
- **UI Description**: Extract accessibility information from any point or full screen
- **Simulator Management**: List available simulators

## Quick Start

### Installation

#### Install via Homebrew

```bash
# Install via Homebrew
brew tap cameroncooke/axe
brew install axe

# Or single liner
brew install cameroncooke/axe/axe

# Use directly
axe --help
```

> [!NOTE]
> You may see errors when using `brew install`, like `Failed to fix install linkage`; these can be safely ignored. This is because the binaries are already codesigned and Homebrew is attempting to resign them, which is not necessary.

#### Build from source

For development work:

```bash
# Clone the repository
git clone https://github.com/cameroncooke/AXe.git
cd AXe

# Run directly with Swift (frameworks handled automatically)
swift run axe --help
swift run axe list-simulators

# Build for development
swift build
.build/debug/axe --help
```

### Basic Usage

```bash
# List available simulators
axe list-simulators

# Get simulator UDID
UDID="B34FF305-5EA8-412B-943F-1D0371CA17FF"

# Basic interactions
axe tap -x 100 -y 200 --udid $UDID
axe type 'Hello World!' --udid $UDID
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid $UDID
axe button home --udid $UDID

# Gesture presets
axe gesture scroll-up --udid $UDID
axe gesture swipe-from-left-edge --udid $UDID

# With timing controls (NEW!)
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid $UDID
axe gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --udid $UDID
```

## Commands Overview

### **Touch & Gestures**

```bash
# Tap at coordinates
axe tap -x 100 -y 200 --udid SIMULATOR_UDID
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid SIMULATOR_UDID

# Swipe gestures
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid SIMULATOR_UDID
axe swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --udid SIMULATOR_UDID

# Advanced touch control
axe touch -x 150 -y 250 --down --udid SIMULATOR_UDID
axe touch -x 150 -y 250 --up --udid SIMULATOR_UDID
axe touch -x 150 -y 250 --down --up --delay 1.0 --udid SIMULATOR_UDID
```

### **Gesture Presets**

```bash
# Scrolling gestures
axe gesture scroll-up --udid SIMULATOR_UDID
axe gesture scroll-down --udid SIMULATOR_UDID
axe gesture scroll-left --udid SIMULATOR_UDID
axe gesture scroll-right --udid SIMULATOR_UDID

# Navigation gestures
axe gesture swipe-from-left-edge --udid SIMULATOR_UDID
axe gesture swipe-from-right-edge --udid SIMULATOR_UDID
axe gesture swipe-from-top-edge --udid SIMULATOR_UDID
axe gesture swipe-from-bottom-edge --udid SIMULATOR_UDID

# With custom screen dimensions
axe gesture scroll-up --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID

# With timing controls
axe gesture scroll-down --pre-delay 1.0 --post-delay 0.5 --udid SIMULATOR_UDID
```

### **Text Input**

```bash
# Simple text input (use single quotes for special characters)
axe type 'Hello World!' --udid SIMULATOR_UDID

# From stdin (best for automation)
echo "Complex text" | axe type --stdin --udid SIMULATOR_UDID

# From file
axe type --file input.txt --udid SIMULATOR_UDID
```

### **Hardware Buttons**

```bash
# Available buttons: home, lock, side-button, siri, apple-pay
axe button home --udid SIMULATOR_UDID
axe button lock --duration 2.0 --udid SIMULATOR_UDID
axe button siri --udid SIMULATOR_UDID
```

### **Keyboard Control**

```bash
# Individual key presses (by HID keycode)
axe key 40 --udid SIMULATOR_UDID                    # Enter key
axe key 42 --duration 1.0 --udid SIMULATOR_UDID    # Hold Backspace

# Key sequences
axe key-sequence --keycodes 11,8,15,15,18 --udid SIMULATOR_UDID    # Type "hello"
```

### **Video Streaming**

```bash
# Stream video from simulator (screenshot-based)
# Stream MJPEG at 10 FPS
axe stream-video --udid SIMULATOR_UDID --fps 10 --format mjpeg > stream.mjpeg

# Pipe to ffmpeg for H264 encoding
axe stream-video --udid SIMULATOR_UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4

# View in real-time with ffplay
axe stream-video --udid SIMULATOR_UDID --fps 15 --format ffmpeg | \
  ffplay -f image2pipe -framerate 15 -i -

# Stream with reduced quality and scale for bandwidth optimization
axe stream-video --udid SIMULATOR_UDID --fps 10 --quality 60 --scale 0.5 --format mjpeg > stream.mjpeg

# Legacy BGRA format (raw pixel data)
axe stream-video --udid SIMULATOR_UDID --format bgra | \
  ffmpeg -f rawvideo -pixel_format bgra -video_size 393x852 -i - output.mp4
```

### **Accessibility & Info**

```bash
# Get accessibility information
axe describe-ui --udid SIMULATOR_UDID                    # Full screen
axe describe-ui --point 100,200 --udid SIMULATOR_UDID    # Specific point

# List simulators
axe list-simulators
```

## Architecture

### Why AXe?

AXe directly utilises the lower-level frameworks provided by [idb](https://github.com/facebook/idb), Facebook's open-source suite for automating iOS Simulators and Devices.

While `idb` offers a powerful client/server architecture and a broad set of device automation features via an RPC protocol, **AXe takes a different approach**:

- **Single Binary:** AXe is distributed as a single, standalone CLI tool—no server or client setup required.
- **Focused Scope:** AXe is purpose-built for UI automation, streamlining accessibility testing and automation tasks.
- **Simple Integration:** With no external dependencies or daemons, AXe can be easily scripted and embedded into other tools or systems running on the same host.
- **Complete HID Coverage:** Full feature parity with idb's HID functionality plus gesture presets and timing controls.
- **Intelligent Automation:** Built-in gesture presets and coordinate helpers for common use cases.

This makes AXe a lightweight and easily adoptable alternative for projects that need direct, scriptable access to Simulator automation.

## Gesture Presets Reference

| Preset | Description | Use Case |
|--------|-------------|----------|
| `scroll-up` | Scroll up in center of screen | Content navigation |
| `scroll-down` | Scroll down in center of screen | Content navigation |
| `scroll-left` | Scroll left in center of screen | Horizontal scrolling |
| `scroll-right` | Scroll right in center of screen | Horizontal scrolling |
| `swipe-from-left-edge` | Left edge to right edge | Back navigation |
| `swipe-from-right-edge` | Right edge to left edge | Forward navigation |
| `swipe-from-top-edge` | Top to bottom | Dismiss/close |
| `swipe-from-bottom-edge` | Bottom to top | Open/reveal |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Licence

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
