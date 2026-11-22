# AXe Mirror

AXe Mirror is the iPhone and iPad app that shows an iOS Simulator running on your Mac. You see the simulator's screen live and touch it from the device in your hand.

The app is the viewer for the `axe mirror` command. The Mac runs the host:

```bash
axe mirror pair              # shows a one-time code and QR code; scan or type it in the app
axe mirror                   # tap the Mac in the app, then choose, start or create a simulator
axe mirror --udid <UDID>     # hosts one booted simulator only; tap the Mac in the app to connect
```

Without `--udid` the app opens the Mac on a menu: the Mac's name, whether this device reaches it directly or through a relay, and under them Simulators and Apps. The pill that says how the Mac is reached is there from the start, saying only “Connected” until that is known, so nothing below it moves when it is. A wide screen, such as an iPhone Duo unfolded and held sideways or an iPad, has layouts of its own, so that nothing is drawn out across the width: every such screen is a list with what is chosen from it beside it. The menu has the Mac, Simulators and Apps down one side and the simulators or the apps beside them, with nothing to unfold; an app opens as its builds down one side, each with the start of its notes, and the chosen build beside them, Install and its notes and facts in view without a tap. Which layout a screen gets is SwiftUI's choice (`SideBySide`, in `ScreenColumn.swift`, is a `ViewThatFits`): the pair is used where it fits and the single column where it does not, and nothing measures the screen; the running simulators are tiles beside the list of the rest; the setup has its video at one side and the steps beside it; and the lists that remain are columns no wider than a phone, centred on the screen. iOS stands the status bar and the bar's buttons down one side of a Duo held that way, so the centring is against the screen and not the room that leaves, where there is width to spare for it; a narrow screen, such as the Duo's outer one, keeps all its width (`ScreenColumn.swift`). An iPhone on its side is wide and very low: the menu puts the Mac beside its doors there, and the welcome and home screens put their picture beside what to do. Simulators lists the Mac's simulators: the running ones first, each with an Open button, then the few used most recently, then a row that leads to all of them by iOS version. Tap one to open it; one that is not running is booted on the Mac first. New, in the bar, creates one from a name, a device and an iOS version. Swipe a simulator, or press and hold it, to shut it down, delete it or copy its ID. While a simulator is on screen, one button copies its UDID, to paste into an agent or a command, and Close goes back to the list, asking whether to leave the simulator running or shut it down; Back goes to the menu, whose Close leaves the Mac. Each simulator's menu in the list can shut it down, restart it or delete it. When the simulator on screen stops answering the Mac, a banner says so, with Restart: the Mac shuts it down, by force if need be, then boots and opens it again.

The controls never cover the picture. With nothing folded they go in bars above and below it, in a column at the side, or, on a wide screen, in one bar on top, whichever leaves the picture biggest. On an iPhone Duo stood on a table like a laptop, the picture is on the upright half and a deck of controls on the half lying flat, with the simulator's Home, app switcher and Lock buttons at a size for a thumb and a trackpad. Folded like a book, or open flat with a picture that loses less than a tenth of its size on one half, the picture takes one page and the controls the other, without the trackpad. The app reads the fold from SwiftUI's reserved regions (iOS 27.1 and later).

When the Mac cannot do something (list its simulators, start one, shut one down), the app says so in plain words for the person holding it, never in the Mac's own tool messages: what happened, and a button for the one thing that can be done from here, which is to try again, restart the simulator or update the list. The Mac's technical message is behind Details. The words and the action come from the host (`MirrorProblem`), so they can improve without a new app.

An iPhone Duo simulator is streamed from the screen that is lit and shown flat, as any simulator, with which screen is lit and how far it is open always in view: beside its name in the top bar and on the deck ("Inner screen · Open", "Inner screen · Half open 102°", "Outer screen · Closed"), and on two short lines under the Fold button when the controls are in the side column. Fold, beside Rotate, turns the live picture into a 3D Duo: the picture splits at the hinge and folds, face on, to the simulator's angle, still live. Fold it by dragging a half away from the middle to open it and towards the middle to close it (closed, a drag either way opens it), by spreading or pinching two fingers, by tapping it when it is closed, or with the Closed, Half open and Open buttons under it. It pivots about the middle, like a book in both hands, and stays centred; short of half open it also turns, until closed it shows its outer screen, on the back of the left half. Let go nearly closed or nearly flat and it goes the rest of the way. Drag the space around it to tilt it a little. While it is up, touches move the Duo and never reach the simulator. The simulator's hinge follows your finger, every few degrees, so the screen it lights is on the Duo as it opens. When you let go, the simulator is held the way the Duo is shown: its inner screen wide when the hinge is upright, tall when it is across, and upright whenever it is closed, since the outer screen's home screen is upright only. Opened flat with Fit to Screen on, it is held to fit the room for its picture as that room is when you let go. The 3D Duo folds first; when the simulator's picture arrives in its new shape it lies on the glass as the Duo is held, on its side if need be, and the Duo is then turned in the hand until the picture is upright, as you would turn a real one. Nothing turns after the picture is back. A fold takes the simulator about a third of a second. The Duo keeps clear of its buttons and of the notice line however small the screen is. A second and a half after the last touch the Duo unfolds and zooms back into the flat picture; Done does that at once. Either way it first waits for the simulator to be where it was asked to be and for that screen's picture to arrive, three seconds at most, so the flat picture is never the screen the simulator has just left. The frames shown on the Duo's halves are the stream's own (`DuoFoldView`), so the picture never stops. The app's own layout follows this device's fold, never the simulator's.

Rotate (a quarter turn left; touch and hold for left or right) turns the simulator, and the picture is streamed upright whatever turns it. For an iPad simulator, and an iPhone Duo simulator lying flat, the app turns it to fit the room it has for the picture, landscape on a tabletop Duo or a phone held sideways, unless Fit to Screen is turned off in the Rotate menu or the simulator has been turned by hand.

Apps, on the menu itself, lists the app builds the Mac offers to install on this device; the list is folded away to begin with, tapping the Apps heading brings it out and folds it away again, and the app remembers which. (Over a simulator's picture, on a Mac with no menu, the same list is a Builds screen.) When they are all builds of one app, the list is that app's builds, newest first, under the app's name, each with its version, when it was published, its size and the start of its notes. When the Mac has builds of several apps (they are grouped by bundle ID), the list has one row for each app, with its newest build and how many builds it has: tap an app for its builds (an app with one build opens straight on it), or hold it down for Install Latest Build, which installs its newest without opening anything. Holding a build down in a list offers Install as well. Tap a build to open it, which is where Install is: its notes in full, when it was published, its size, the iOS it needs, how long its profile lasts, how many devices it is signed for, its bundle ID and its build ID, with Install at the top. The screen says nothing about the connection while it works, and a card says so when an install goes wrong. That iOS has been handed a build is said in a line at the foot of the screen that goes after five seconds: iOS asks whether to install and tells the app nothing of the answer, so a note that stayed would go on saying a build was installing after the person had said no. When a build is published while you are connected, or the Mac has a newer build of AXe Mirror than the one running, one line at the foot of the screen says so, with Install. The Mac puts them there with `axe mirror build` or `axe mirror publish`. The first Install opens a one-time setup for each Mac (also “Set Up Installs”, at the top of Builds): the Mac makes a certificate, the app opens it in Safari, and you install it in Settings and switch it on under General › About › Certificate Trust Settings; the app checks by itself when you come back and offers the build you asked for. The setup screen plays a 47-second video of the whole journey (`Resources/trust-tutorial.mp4`): Safari's question, the Home Screen, Settings and back to the app, with the camera pulling out to show the whole phone and in on each control, a ring where the finger goes and the step in large type, and iOS floats it in Picture in Picture when you leave for Safari and Settings, so the steps stay in view over them; drag it aside or swipe it off the edge. That is why the app declares the audio background mode, although the video has no sound: iOS starts Picture in Picture by itself only for an app set up for playback, and any audio already playing on the device stops while the video plays. `Tools/make_trust_tutorial.swift` makes the video from one recording of a simulator. An iPhone simulator has no Picture in Picture, so to see the video float use a device or an iPad simulator. After that Install fetches the build from the Mac over the connection you are on, shows its progress, and hands it to iOS from this device itself (`LocalInstall.swift`): iOS asks you to confirm and installs it. Pairing is all it needs: no other network, VPN or server is involved. A build of AXe Mirror itself is marked Update or This Build; installing it closes the app while iOS replaces it.

On a table, the deck has a trackpad. It moves a pointer that the app draws over the picture: a tap clicks where the pointer is, a finger that rests before it moves drags, and two fingers scroll. The simulator knows nothing of the pointer; it gets ordinary touches at the pointer's place, so this works on iPhone and iPad simulators alike, and shows none of iPadOS's own pointer effects. This needs AXe 2.2 or later on the Mac; with an older AXe, or with `--udid`, the app opens the one simulator the Mac hosts.

The host sends the screen as HEVC video. The app decodes it, and sends back touches (one or two fingers) and the Home, app switcher and Lock buttons. The connection is encrypted from end to end (QUIC, through the [iroh](https://github.com/n0-computer/iroh) library). It is direct when the two devices can reach each other and goes through a relay when they cannot. See [Mirror](../README.md#mirror-a-simulator-on-your-iphone-or-ipad) in the main README for the command.

## Getting the app

AXe Mirror is free and open source, under the same licence as AXe: the GNU General Public License version 3 (see [LICENSE](../LICENSE)). There are two ways to get it:

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

Then pair and connect as usual: `axe mirror pair` on the Mac, scan the code in the app, and `axe mirror`.

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
| `Sources/MacHub.swift` | The menu a Mac opens on: Simulators, and the Mac's apps listed under Apps |
| `Sources/Artwork.swift` | The drawn scenes on the home screen and on every screen that waits, fails or is empty |
| `Sources/ScreenColumn.swift` | A list beside what is chosen from it where both fit (`SideBySide`), and a column centred on the screen where they do not |
| `Sources/SimulatorChooser.swift` | The list of the Mac's simulators and the form for a new one |
| `Sources/BuildsView.swift` | The Mac's builds: the menu's list of apps, the list, a build's own screen, the one-time setup, and the lines that say a new one is ready and that iOS has one |
| `Sources/TutorialVideo.swift` | The setup's video and its Picture in Picture |
| `Sources/LocalInstall.swift` | The HTTPS server on this device that iOS downloads a fetched build from |
| `Sources/Trackpad.swift` | The trackpad on an iPhone Duo stood on a table and the pointer it moves over the picture |
| `Sources/MirrorClient.swift` | The connection to the Mac and the video decoder |
| `Sources/AppModel.swift` | The app's state, this device's identity and its storage |
| `Resources/` | The asset catalogue and the privacy manifest |
| `Tools/make_app_icon.swift` | Draws the app icon: `swift Tools/make_app_icon.swift <appiconset-dir>` |
| `../Sources/AXe/Mirror/Shared/` | The protocol files shared with `axe mirror` (pairing, relays, settings, protocol names, the simulator list, folding, where the controls go), compiled into both |

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

`scripts/e2e-mirror-duo.py` checks an iPhone Duo host with the app on a second iPhone Duo simulator: taps on the screen that is lit, the 3D Duo taking no touches, folding it closed, part way and open flat by dragging, the return to the flat picture, and that folding the viewer itself does not fold the host.

A simulator build made with `CODE_SIGNING_ALLOWED=NO`, as `scripts/e2e-mirror.py` makes it, came back with a new identity each time it was launched (seen on 19 November 2026; an unsigned build most likely cannot write to the Keychain). The Mac then refuses it as not paired, so pair after the launch you mean to test with, or start the host with the hidden `--allow-unpaired`.

## Settings read from DNS

The app reads two DNS TXT records when it starts, so they can change without an app update. Both have built-in fallbacks, so the app works when the lookup fails.

- `_relays.axe-cli.com` lists the relays, for example `v=1 https://eu1.relay.axe-cli.com https://us1.relay.axe-cli.com public`. Each `https://` word is one of AXe's relays. `public` allows iroh's public relays as a last resort. `axe mirror` reads the same record.
- `_mirror.axe-cli.com` holds the app's settings, for example `v=1 min=1 demo=<host ID> demo-relay=https://eu1.relay.axe-cli.com`. `min` is the lowest app build that may still connect; an older build asks its user to update. `demo` is the ID of the demo host behind "Try the demo" and `demo-relay` the relay it listens on. With no `demo` the button is hidden.

Words a version does not know are skipped, so later versions can add to either record.

## Privacy

The app has no accounts, no analytics and no tracking, and its privacy manifest declares no collected data. It keeps two things: a random identity key in the Keychain, readable only on this device, and the list of Macs you paired with, in the app's own files. The camera is used only to scan the pairing code. The video and your touches are encrypted from end to end, so a relay cannot read them.
