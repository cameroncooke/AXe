# IDBKit

AXe's copy of the two IDB frameworks it uses, `FBControlCore` and `FBSimulatorControl`, with the
private headers they compile against and their tests. This is the single source for those
frameworks. Edit the sources here directly; there is no upstream checkout or patch to keep in step.

## Origin

The sources started from Meta's [IDB](https://github.com/facebook/idb) at upstream commit
`e682506725e9efefb9c43b8b917c0b12eb2a5939`, by way of AXe's former fork at
`604c51013438f0c3603b720a05a44b7c5b8f286d`, with AXe's Duo foundation changes applied. The repository
history up to the removal of `patches/idb-duo-foundation.patch` records how those changes evolved.

Only what AXe uses is kept:

- `FBControlCore` and `FBSimulatorControl`. `FBDeviceControl`, `XCTestBootstrap` and the IDB companion,
  CLI and Python client are not included. The simulator REPL and XCTest commands were removed with
  `XCTestBootstrap`.
- `PrivateHeaders` for the private Apple frameworks these two compile against.
- `FBSimulatorHIDEventTransportTests`, AXe's test target for this code.

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
