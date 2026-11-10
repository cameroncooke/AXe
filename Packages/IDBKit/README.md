# IDBKit

AXe's copy of the two IDB frameworks it uses, `FBControlCore` and `FBSimulatorControl`, with the
private headers they compile against and their tests. This is the single source for those
frameworks. Edit the sources here directly; there is no upstream checkout or patch to keep in step.

## Origin

The sources started from Meta's [IDB](https://github.com/facebook/idb) at upstream commit
`e682506725e9efefb9c43b8b917c0b12eb2a5939`, with AXe's Duo changes applied.

This copy contains:

- `FBControlCore` and `FBSimulatorControl`, trimmed to the simulator support AXe uses: the
  simulator set and lifecycle (boot, shutdown, connect), application install and launch with the
  process-spawn, launchctl and file-container code they depend on, screenshots, video recording and
  streaming, the framebuffer, HID input (Indigo and DTUHID) and accessibility.
- `PrivateHeaders` for the private Apple frameworks these two compile against.
- `FBSimulatorHIDEventTransportTests`, AXe's test target for this code. `make test` and CI do not
  run it; run it with the `xcodebuild test` command under Building.

Removed from upstream: `FBDeviceControl`, `XCTestBootstrap`, the IDB companion, CLI and Python
client, and these parts of the two frameworks AXe never calls: the XCTest, REPL, instruments and
xctrace commands; the keychain, media, settings (including status bar overrides and defaults
modification), DAP server, memory, notification, location, log, debugger and crash-log commands;
the `AsynciOSTarget` protocol that composed the async command families; and the utilities only
those used (`FBFutureContextManager`, `FBSocketServer`, crash-log parsing and storage, codesigning,
developer disk images, the XCTest shim configuration, and some async helpers).

Upstream changes are not merged automatically. Port anything useful by hand, as ordinary changes.

## Building

Both frameworks mix Objective-C and Swift, which SwiftPM cannot build in one target, so they build
from an Xcode project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd Packages/IDBKit
xcodegen generate
xcodebuild test -project FBSimulatorControl.xcodeproj -scheme FBSimulatorControl \
  -destination "platform=macOS,arch=arm64"
```

`scripts/build.sh` generates the project and builds the XCFrameworks that AXe links. The generated
project is not checked in.

## Licence

IDB is MIT licensed; see [LICENSE](LICENSE). File headers keep their original copyright notices.
