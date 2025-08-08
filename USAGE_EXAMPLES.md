# AXe Usage Examples

This document shows how to use AXe's comprehensive HID functionality including gesture presets, delay controls, and coordinate helpers.

## Basic Setup

First, get the UDID of your simulator:

```bash
# List available simulators
axe list-simulators

# Find a booted simulator and copy its UDID
# Example: B34FF305-5EA8-412B-943F-1D0371CA17FF
```

## HID Commands Overview

AXe provides comprehensive HID (Human Interface Device) functionality matching idb capabilities:

### **1. Text Input**

```bash
# Simple text input
axe type 'Hello World!' --udid SIMULATOR_UDID

# Use single quotes for special characters
axe type 'Special chars: @#$%^&*()' --udid SIMULATOR_UDID

# From stdin (best for automation)
echo "Complex text with any characters!" | axe type --stdin --udid SIMULATOR_UDID

# From file
echo "Multi-line text content" > input.txt
axe type --file input.txt --udid SIMULATOR_UDID
```

### **2. Touch & Gestures**

```bash
# Simple tap
axe tap -x 100 -y 200 --udid SIMULATOR_UDID

# Tap with timing controls
axe tap -x 100 -y 200 --pre-delay 1.0 --post-delay 0.5 --udid SIMULATOR_UDID

# Swipe gestures
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --udid SIMULATOR_UDID
axe swipe --start-x 50 --start-y 500 --end-x 350 --end-y 500 --duration 2.0 --delta 25 --udid SIMULATOR_UDID

# Swipe with timing controls
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --pre-delay 1.0 --post-delay 0.5 --udid SIMULATOR_UDID

# Advanced touch control
axe touch -x 150 -y 250 --down --udid SIMULATOR_UDID         # Touch down only
axe touch -x 150 -y 250 --up --udid SIMULATOR_UDID           # Touch up only
axe touch -x 150 -y 250 --down --up --delay 1.0 --udid SIMULATOR_UDID  # Touch with delay
```

### **3. Gesture Presets** 🆕

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

# Edge swipe gestures
axe gesture swipe-from-left-edge --udid SIMULATOR_UDID
axe gesture swipe-from-bottom-edge --udid SIMULATOR_UDID

# Gesture presets with custom parameters
axe gesture scroll-up --duration 2.0 --delta 100 --udid SIMULATOR_UDID
axe gesture scroll-down --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID

# Gesture presets with timing controls
axe gesture scroll-down --pre-delay 1.0 --post-delay 0.5 --udid SIMULATOR_UDID
axe gesture swipe-from-left-edge --pre-delay 2.0 --duration 0.8 --post-delay 1.0 --udid SIMULATOR_UDID
```

### **4. Hardware Buttons**

```bash
# Available buttons: home, lock, side-button, siri, apple-pay
axe button home --udid SIMULATOR_UDID
axe button lock --udid SIMULATOR_UDID
axe button lock --duration 3.0 --udid SIMULATOR_UDID  # Long press

# Side button (iPhone X+)
axe button side-button --udid SIMULATOR_UDID

# Siri button
axe button siri --udid SIMULATOR_UDID

# Apple Pay button
axe button apple-pay --udid SIMULATOR_UDID
```

### **5. Keyboard Control**

```bash
# Individual key presses by keycode
axe key 40 --udid SIMULATOR_UDID                    # Enter key
axe key 44 --udid SIMULATOR_UDID                    # Space key
axe key 42 --duration 1.0 --udid SIMULATOR_UDID    # Hold Backspace for 1 second

# Key sequences
axe key-sequence --keycodes 11,8,15,15,18 --udid SIMULATOR_UDID    # Type "hello"
axe key-sequence --keycodes 40,40,40 --delay 0.5 --udid SIMULATOR_UDID  # Press Enter 3 times
```

## Advanced Timing Control 🆕

### **Pre/Post Delays**

```bash
# Add delays before and after actions
axe tap -x 100 -y 200 --pre-delay 2.0 --post-delay 1.0 --udid SIMULATOR_UDID
axe swipe --start-x 100 --start-y 300 --end-x 300 --end-y 100 --pre-delay 1.5 --udid SIMULATOR_UDID
axe gesture scroll-up --pre-delay 1.0 --post-delay 2.0 --udid SIMULATOR_UDID
```

### **Complex Timing Sequences**

```bash
# Sequence with precise timing
axe tap -x 100 -y 200 --post-delay 1.0 --udid SIMULATOR_UDID
axe gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --udid SIMULATOR_UDID
axe button home --udid SIMULATOR_UDID
```

## Common Use Cases

### **App Navigation with Presets**

```bash
# Modern app navigation using presets
axe tap -x 100 -y 200 --udid SIMULATOR_UDID                    # Launch app
axe gesture scroll-up --post-delay 1.0 --udid SIMULATOR_UDID   # Scroll content
axe gesture swipe-from-left-edge --udid SIMULATOR_UDID          # Navigate back
axe button home --udid SIMULATOR_UDID                          # Go to home screen
```

### **Pull-to-Refresh Testing**

```bash
# Test scroll down functionality
axe tap -x 200 -y 400 --udid SIMULATOR_UDID                    # Tap list area
axe gesture scroll-down --pre-delay 1.0 --udid SIMULATOR_UDID  # Scroll down
axe gesture scroll-down --post-delay 2.0 --udid SIMULATOR_UDID     # Scroll to see results
```

### **Multi-Screen Testing**

```bash
# Different screen sizes with presets
# iPhone 15
axe gesture scroll-up --screen-width 390 --screen-height 844 --udid SIMULATOR_UDID

# iPhone 15 Plus
axe gesture scroll-up --screen-width 430 --screen-height 932 --udid SIMULATOR_UDID

# iPad Pro
axe gesture scroll-up --screen-width 1024 --screen-height 1366 --udid SIMULATOR_UDID
```

### **Form Input with Timing**

```bash
# Fill a form with proper timing
axe tap -x 150 -y 300 --post-delay 0.5 --udid SIMULATOR_UDID           # Tap text field, wait for focus
axe type 'john.doe@example.com' --udid SIMULATOR_UDID                  # Enter email
axe key 43 --udid SIMULATOR_UDID                                       # Tab to next field
axe type 'SecurePassword123!' --udid SIMULATOR_UDID                    # Enter password
axe key 40 --pre-delay 0.5 --udid SIMULATOR_UDID                      # Wait then press Enter/Submit
```

### **Gaming & Interactive Apps**

```bash
# Game controls with precise timing
axe touch -x 100 -y 500 --down --udid SIMULATOR_UDID           # Start drag
axe gesture swipe-from-top-edge --pre-delay 0.2 --duration 0.3 --udid SIMULATOR_UDID  # Quick swipe action
axe touch -x 300 -y 200 --up --udid SIMULATOR_UDID             # End drag

# Edge swipes with timing
axe gesture swipe-from-left-edge --duration 0.5 --udid SIMULATOR_UDID    # Quick back
axe gesture swipe-from-right-edge --pre-delay 1.0 --duration 0.3 --udid SIMULATOR_UDID  # Forward after delay
```

### **Accessibility Testing with Presets**

```bash
# Get accessibility info
axe describe-ui --point 100,200 --udid SIMULATOR_UDID

# Navigate with presets and keyboard
axe gesture scroll-down --post-delay 1.0 --udid SIMULATOR_UDID         # Scroll to content
axe key-sequence --keycodes 43,43,40 --delay 1.0 --udid SIMULATOR_UDID # Tab navigation
```

### **Video Streaming**

```bash
# Stream video from simulator using screenshot-based capture

# Basic MJPEG streaming at 10 FPS
axe stream-video --udid SIMULATOR_UDID --fps 10 --format mjpeg > recording.mjpeg

# Real-time H264 encoding with ffmpeg (recommended)
axe stream-video --udid SIMULATOR_UDID --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset ultrafast output.mp4

# View stream in real-time with ffplay
axe stream-video --udid SIMULATOR_UDID --fps 15 --format ffmpeg | \
  ffplay -f image2pipe -framerate 15 -i -

# Stream with reduced bandwidth (lower quality and resolution)
axe stream-video --udid SIMULATOR_UDID --fps 10 --quality 60 --scale 0.5 --format mjpeg > low-bandwidth.mjpeg

# Raw JPEG stream for custom processing
axe stream-video --udid SIMULATOR_UDID --fps 5 --format raw | custom-video-processor

# Legacy BGRA format (raw pixel data)
axe stream-video --udid SIMULATOR_UDID --format bgra | \
  ffmpeg -f rawvideo -pixel_format bgra -video_size 393x852 -framerate 10 -i - output.mp4

# Automated recording script
#!/bin/bash
UDID=$(axe list-simulators | grep "Booted" | head -1 | grep -o '[A-F0-9-]\{36\}')
OUTPUT="recording_$(date +%Y%m%d_%H%M%S).mp4"

# Start recording
axe stream-video --udid "$UDID" --fps 30 --format ffmpeg | \
  ffmpeg -f image2pipe -framerate 30 -i - -c:v libx264 -preset fast "$OUTPUT" &
RECORD_PID=$!

# Run your automation
axe tap -x 100 -y 200 --udid "$UDID"
axe gesture scroll-down --udid "$UDID"
# ... more commands ...

# Stop recording
sleep 2
kill $RECORD_PID
```

## Shell Escaping Solutions

### ❌ Problematic Examples:
```bash
# This fails due to history expansion
axe type "Hello World!" --udid SIMULATOR_UDID

# This fails due to variable expansion  
axe type "Hello $USER" --udid SIMULATOR_UDID
```

### ✅ Recommended Solutions:

#### **1. Use Single Quotes**
```bash
axe type 'Hello World!' --udid SIMULATOR_UDID
axe type 'Special chars: @#$%^&*()' --udid SIMULATOR_UDID
```

#### **2. Use stdin (Best for Scripts)**
```bash
echo "Hello World! Any characters work here: @#$%^&*()" | axe type --stdin --udid SIMULATOR_UDID

# In scripts
TEXT="Complex text with $variables"
echo "$TEXT" | axe type --stdin --udid SIMULATOR_UDID
```

#### **3. Use Files**
```bash
echo "Complex multi-line text" > input.txt
axe type --file input.txt --udid SIMULATOR_UDID
```

## Automation Examples

### **Advanced Shell Script Automation**
```bash
#!/bin/bash

# Get simulator UDID
UDID=$(axe list-simulators | grep "Booted" | head -1 | grep -o '[A-F0-9-]\{36\}')

# Advanced app testing with presets and timing
axe tap -x 100 -y 200 --post-delay 1.0 --udid "$UDID"           # Launch app, wait for load
axe gesture scroll-up --pre-delay 0.5 --post-delay 1.0 --udid "$UDID"  # Scroll with timing
axe gesture swipe-from-left-edge --udid "$UDID"                  # Navigate back
axe button home --pre-delay 0.5 --udid "$UDID"                  # Return home with delay
```

### **Python Script Automation with Presets**
```python
import subprocess
import time

def run_axe_command(cmd):
    subprocess.run(cmd, shell=True, check=True)

udid = "YOUR_SIMULATOR_UDID"

# Advanced interaction sequence with presets
run_axe_command(f"axe tap -x 150 -y 300 --post-delay 1.0 --udid {udid}")
run_axe_command(f"echo 'Automated input' | axe type --stdin --udid {udid}")
run_axe_command(f"axe gesture scroll-down --pre-delay 0.5 --post-delay 1.0 --udid {udid}")
run_axe_command(f"axe gesture scroll-down --udid {udid}")
run_axe_command(f"axe button home --pre-delay 1.0 --udid {udid}")
```

### **Performance Testing with Presets**
```bash
# Rapid gesture testing
for gesture in scroll-up scroll-down scroll-left scroll-right; do
    axe gesture $gesture --duration 0.3 --post-delay 0.2 --udid SIMULATOR_UDID
done

# Stress testing with timing control
for i in {1..10}; do
    axe gesture swipe-from-left-edge --duration 0.4 --post-delay 0.1 --udid SIMULATOR_UDID
    axe gesture swipe-from-right-edge --duration 0.4 --post-delay 0.1 --udid SIMULATOR_UDID
done
```

### **Multi-Device Testing**
```bash
# Test same gesture on different screen sizes
devices=("390,844" "430,932" "393,852" "1024,1366")
for device in "${devices[@]}"; do
    IFS=',' read -r width height <<< "$device"
    echo "Testing on ${width}x${height}"
    axe gesture scroll-up --screen-width $width --screen-height $height --udid SIMULATOR_UDID
    axe gesture scroll-down --screen-width $width --screen-height $height --udid SIMULATOR_UDID
done
```

## Gesture Preset Reference 🆕

### **Available Presets**

| Preset | Description | Default Duration | Default Delta | Use Case |
|--------|-------------|------------------|---------------|----------|
| `scroll-up` | Scroll up in center | 0.5s | 25px | Content scrolling |
| `scroll-down` | Scroll down in center | 0.5s | 25px | Content scrolling |
| `scroll-left` | Scroll left in center | 0.5s | 25px | Horizontal scrolling |
| `scroll-right` | Scroll right in center | 0.5s | 25px | Horizontal scrolling |
| `swipe-from-left-edge` | Left edge to right | 0.3s | 50px | Back navigation |
| `swipe-from-right-edge` | Right edge to left | 0.3s | 50px | Forward navigation |
| `swipe-from-top-edge` | Top to bottom | 0.3s | 50px | Dismiss/close |
| `swipe-from-bottom-edge` | Bottom to top | 0.3s | 50px | Open/reveal |

### **Timing Control Reference** 🆕

| Parameter | Range | Description | Available On |
|-----------|-------|-------------|--------------|
| `--pre-delay` | 0-10 seconds | Delay before action | tap, swipe, gesture |
| `--post-delay` | 0-10 seconds | Delay after action | tap, swipe, gesture |
| `--duration` | 0-10 seconds | Action duration | swipe, gesture, button, key |
| `--delay` | 0-5 seconds | Between-key delay | key-sequence, touch |

## Key Advantages

1. **Complete HID Coverage**: All idb functionality now available in AXe
2. **Gesture Presets**: 11 common patterns with intelligent defaults
3. **Precise Timing Control**: Pre/post delays for complex automation
4. **Multi-Screen Support**: Automatic coordinate calculation for different devices
5. **No Shell Escaping**: Use `--stdin` or `--file` for complex text
6. **Automation-Friendly**: Perfect for CI/CD and testing scripts
7. **Flexible Input Methods**: Multiple ways to provide input and control timing
8. **Comprehensive Validation**: Built-in parameter validation and error handling

## Common Keycodes Reference

```
# Letters (lowercase)
a=4, b=5, c=6, d=7, e=8, f=9, g=10, h=11, i=12, j=13, k=14, l=15, m=16
n=17, o=18, p=19, q=20, r=21, s=22, t=23, u=24, v=25, w=26, x=27, y=28, z=29

# Numbers
1=30, 2=31, 3=32, 4=33, 5=34, 6=35, 7=36, 8=37, 9=38, 0=39

# Special keys
Enter=40, Escape=41, Backspace=42, Tab=43, Space=44
Minus=45, Equal=46, LeftBracket=47, RightBracket=48, Backslash=49
Semicolon=51, Quote=52, Grave=53, Comma=54, Period=55, Slash=56

# Function keys
F1=58, F2=59, F3=60, F4=61, F5=62, F6=63, F7=64, F8=65, F9=66, F10=67

# Modifier keys
LeftCtrl=224, LeftShift=225, LeftAlt=226, LeftGUI=227
RightCtrl=228, RightShift=229, RightAlt=230, RightGUI=231
``` 