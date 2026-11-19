# AXe Mirror

AXe Mirror is the iPhone and iPad app that shows an iOS Simulator running on your Mac. You see the simulator's screen live and touch it from the device in your hand.

The app is the viewer for the `axe mirror` command. The Mac runs the host:

```bash
axe mirror pair              # shows a one-time code and QR code; scan or type it in the app
axe mirror --udid <UDID>     # hosts one booted simulator; tap the Mac in the app to connect
```

The host sends the screen as HEVC video. The app decodes it, and sends back touches (one or two fingers) and the Home, app switcher and Lock buttons. The connection is encrypted from end to end (QUIC, through the [iroh](https://github.com/n0-computer/iroh) library). It is direct when the two devices can reach each other and goes through a relay when they cannot. See [Mirror](../README.md#mirror-a-simulator-on-your-iphone-or-ipad) in the main README for the command.

## Getting the app

AXe Mirror is free and open source, under the same MIT licence as AXe. There are two ways to get it:

- From the [App Store](https://apps.apple.com/app/id6836545597).
- By building it yourself from this folder, which needs nothing from the App Store. A self-built copy works the same way: it pairs with `axe mirror pair`, finds the same relays, and can try the demo.

## Build it yourself for your iPhone or iPad

You need a Mac with Xcode and an Apple ID. A free Apple ID is enough; with one, the app stops opening after seven days and has to be installed again, and the Macs you paired stay paired as long as the app is not deleted. A paid developer account lasts a year.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), then generate and open the project:

   ```bash
   git clone https://github.com/cameroncooke/AXe.git
   cd AXe/AXeMirror
   xcodegen generate
   open AXeMirror.xcodeproj
   ```

2. In Xcode, select the AXeMirror target, open Signing & Capabilities, choose your own team, and change the bundle identifier to one of your own, for example `com.example.axemirror`. The identifier in `project.yml` belongs to the App Store copy and cannot be signed by anyone else.
3. Connect the iPhone or iPad, choose it as the run destination and press Run. The first time, the device asks you to trust your developer certificate under Settings > General > VPN & Device Management.

Or do steps 2 and 3 from the command line, with your own team ID and identifier:

```bash
xcodebuild -project AXeMirror.xcodeproj -scheme AXeMirror \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your team ID> PRODUCT_BUNDLE_IDENTIFIER=com.example.axemirror build
```

Then pair and connect as usual: `axe mirror pair` on the Mac, scan the code in the app, and `axe mirror --udid <UDID>`.

## Requirements

- Xcode 27 or later (a release version, not a beta, for App Store builds)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- iOS or iPadOS 17.5 or later on the device or simulator

## Build for the simulator

The Xcode project is generated from `project.yml` and is not checked in.

```bash
cd AXeMirror
xcodegen generate
open AXeMirror.xcodeproj
```

Or build for the simulator from the command line:

```bash
xcodebuild -project AXeMirror.xcodeproj -scheme AXeMirror \
  -destination 'generic/platform=iOS Simulator' build
```

The project depends on the [iroh-ffi](https://github.com/n0-computer/iroh-ffi) Swift package, version 1.2.0, which Xcode fetches on the first build.

## Source layout

| Path | Contents |
|---|---|
| `Sources/HomeView.swift` | The app's entry point, the home screen with the paired Macs, and the About screen |
| `Sources/PairView.swift` | Pairing: the QR scanner and the typed code |
| `Sources/StreamView.swift` | The stream screen and its touch handling |
| `Sources/MirrorClient.swift` | The connection to the Mac and the video decoder |
| `Sources/AppModel.swift` | The app's state, this device's identity and its storage |
| `Resources/` | The asset catalogue and the privacy manifest |
| `Tools/make_app_icon.swift` | Draws the app icon: `swift Tools/make_app_icon.swift <appiconset-dir>` |
| `../Sources/AXe/Mirror/Shared/` | The protocol files shared with `axe mirror` (pairing, relays, settings, protocol names), compiled into both |

## Launch arguments for testing

None of these is used in a normal run.

| Argument | Effect |
|---|---|
| `-MirrorDemoHost <host ID>` | Uses this host for the "Try the demo" button in place of the published one |
| `-MirrorDemoRelay <URL>` | The relay that demo host listens on |
| `-MirrorSampleHosts YES` | Fills the list with example Macs, for screenshots |

For example, to try the app in a simulator against a demo host on the same Mac, start `axe mirror --udid <UDID> --demo`, take the `hostID` from its `endpoint` line, and launch the app with it:

```bash
xcrun simctl launch <VIEWER_UDID> com.cameroncooke.axemirror -MirrorDemoHost <host ID>
```

A simulator has no camera, so the pairing screen opens on "Type the code" there.

## Settings read from DNS

The app reads two DNS TXT records when it starts, so they can change without an app update. Both have built-in fallbacks, so the app works when the lookup fails.

- `_relays.axe-cli.com` lists the relays, for example `v=1 https://eu1.relay.axe-cli.com https://us1.relay.axe-cli.com public`. Each `https://` word is one of AXe's relays. `public` allows iroh's public relays as a last resort. `axe mirror` reads the same record.
- `_mirror.axe-cli.com` holds the app's settings, for example `v=1 min=1 demo=<host ID> demo-relay=https://eu1.relay.axe-cli.com`. `min` is the lowest app build that may still connect; an older build asks its user to update. `demo` is the ID of the demo host behind "Try the demo" and `demo-relay` the relay it listens on. With no `demo` the button is hidden.

Words a version does not know are skipped, so later versions can add to either record.

## Privacy

The app has no accounts, no analytics and no tracking, and its privacy manifest declares no collected data. It keeps two things: a random identity key in the Keychain, readable only on this device, and the list of Macs you paired with, in the app's own files. The camera is used only to scan the pairing code. The video and your touches are encrypted from end to end, so a relay cannot read them.
