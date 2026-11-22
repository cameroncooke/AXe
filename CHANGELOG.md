# Changelog

All notable changes to the AXe iOS testing framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `axe mirror` runs without `--udid`. The AXe Mirror app then opens the Mac on a menu, Simulators and Apps, with the Mac's name and whether it is reached directly or through a relay; Simulators is a door to a screen of its own, and Apps is a heading on the menu itself: tapping it lists the Mac's apps under it, with no screen of their own to go to, and tapping it again folds them away. On a wide screen, such as an iPhone Duo unfolded and held sideways, the app has layouts of its own, each a list with what is chosen from it beside it: the menu's Simulators and Apps down one side with the simulators or the apps beside them, an app's builds down one side with the chosen build beside them, running simulators as tiles, and the setup's video beside its steps. The home screen and every screen that waits, fails or is empty has a drawing of what is going on (a Mac, the phone and the line between them: flowing while connecting, broken when the Mac, the relay or the internet is out of reach, locked when the pairing is gone). Simulators lists this Mac's iPhone and iPad simulators, running ones first, and opens the one you tap; a simulator that is shut down is booted first. "New simulator" in the app creates one on the Mac from a name, a device and an installed iOS version, then boots and opens it. The host prints the UDID of each simulator it creates or opens (events `simulatorCreated`, `simulatorSelected` and `simulatorReleased`), and the app shows the UDID and copies it with one tap, to paste into an agent or a command. Close goes back to the list and asks whether to leave the simulator running or shut it down, the list's Close leaves the Mac, and the list can shut a simulator down or, after asking, delete it (events `simulatorShutDown` and `simulatorDeleted`). The list puts running simulators first, then the five used most recently, with the rest one row away by iOS version, and it can be searched. `ready` carries no `udid` on such a host. This needs version 1.2 of the app; an older one gets no picture and the host prints a `warning` with code `viewerTooOld`. `--demo` needs `--udid`. See [Mirror](README.md#mirror-a-simulator-on-your-iphone-or-ipad).
- `axe mirror` builds and publishes apps for its paired viewers to install on their own iPhone or iPad, so a build made on the Mac reaches the phone in your hand. `axe mirror build --project <project> --scheme <scheme>` (or `--workspace`) archives the app with xcodebuild, exports it for Ad Hoc (Release Testing) distribution and publishes it; `axe mirror publish <ipa>` publishes an IPA that is already signed; `axe mirror builds` lists them and manages them: `--remove <id>` (repeatable), `--keep <n>` for the newest n of each app, `--notes <id> "<text>"` to correct notes, and `--clean` for archives and logs left behind. `build` removes its Xcode archive once the build is published (`--keep-archive` keeps it), so the store does not grow by hundreds of megabytes a build, and both publishing commands say which of this Mac's devices the build will install on. Each IPA is checked before it is offered: a device app, signed for Ad Hoc distribution, its profiles not expired and matching its bundle, team and certificate, and with `--device <udid>` that device in the profile. A build that iOS would refuse is refused here, with the reason. The AXe Mirror app (1.2) lists them on the Mac's menu, under Apps (over a simulator's picture, on a Builds screen). When the Mac has builds of one app, the list is that app's builds, newest first, with version, time, size and the start of the notes. When it has builds of several apps, the list has one row for each app, with its newest build and how many it has: tap an app for its builds (an app with one build opens straight on it), or hold it down for Install Latest Build. A build has a screen of its own with Install, its notes in full (`--notes`, up to 4,000 characters) and its details, and holding a build down in a list offers Install too. On a wide screen an app opens as its builds down one side, each with the start of its notes, and the chosen build beside them. The app says at the foot of the screen when a build is published while you are connected, or when there is a newer build of AXe Mirror itself; Install is all it takes once the device is set up. That iOS has been handed a build is said in a line that goes after five seconds: iOS asks the person itself and tells the app nothing of the answer, so nothing stays on screen saying a build is installing. Pairing is all a build needs to reach the device: it goes to the app over the paired connection, direct or relayed, and the app serves it to iOS from the device itself, so no other network, VPN or server is involved. iOS will download a build only over HTTPS from a name whose certificate the device trusts, and, measured on an iPhone Duo with iOS 27.3, it does so from the device's own address when that is a real name that resolves to 127.0.0.1 (`localhost` and `127.0.0.1` it does not even connect to). So the host makes a certificate for such names with the system's openssl, throws the signing key away at once, and sends the certificate to the app. The first Install opens a setup that walks the person through installing the certificate and switching it on under Certificate Trust Settings, once for each Mac; the app checks by itself when they come back and offers the build they asked for. A 47-second video of the whole journey plays on that screen, from Safari's question through the Home Screen and Settings and back to the app, zooming out to show where each thing is and in on what to tap. It goes on playing in Picture in Picture over Safari and Settings, so the steps float beside what the person is doing. The host prints `buildsChanged` (`count`, `newest`) and `installRequested` (`bundleID`, `name`, `version`, `build`) when the build is handed to iOS; it cannot see whether iOS then installed it. `--builds <folder>` or `AXE_MIRROR_BUILDS` uses another store, `--no-builds` offers none, and a demo host offers none. The authority a device is asked to trust for installs can vouch only for the names that point at the device itself, which the app checks before it offers it, so trusting it gives nobody a way to pass for another site. A download that loses its connection carries on where it stopped, and an archive kept with `--keep-archive` stays until `axe mirror builds --clean`.

### Changed
- `axe mirror --demo` now needs `--demo-app`. Without an app to keep its visitors inside, a demo host gave a stranger the whole simulator, its browser included, and the command accepted that.
- `axe mirror` streams a simulator turned to landscape upright and wide, where it showed the portrait framebuffer with the interface on its side, and turns the viewer's touches to match. It reads the screen's rotation twice a second while streaming, so a turn by Simulator.app or by an app counts too, and prints a `rotated` event. The AXe Mirror app (1.2) has a Rotate button (a quarter turn left; hold for left or right) and turns an iPad simulator, or an iPhone Duo simulator lying flat, to fit the room it has for the picture, which a Fit to Screen setting turns off.
- The AXe Mirror app (1.2) shows the name of the simulator on screen, where it showed the Mac's, and has a button that copies the simulator's UDID. This works with `axe mirror --udid <UDID>` too.
- On a partly folded iPhone Duo, the AXe Mirror app (1.2) puts the picture on one side of the fold and its controls on the other, as large buttons: above and below when the device stands like a laptop, side by side when it is folded like a book. The controls include a trackpad that moves a pointer the app draws over the picture: tap to click, rest a finger to drag, two fingers to scroll. The simulator receives ordinary touches at the pointer's place.
- `axe mirror` hosts an iPhone Duo simulator properly. It streamed the inner screen only, which stood still while the simulator was closed, and sent touches to the outer screen whichever was lit. The host now streams the lit screen, moving to the other one when the simulator folds, sends touches to it, and turns the picture upright as it does for other simulators. It prints `screenChanged` (`udid`, `screen`) when the other screen lights. The AXe Mirror app (1.2) shows the simulator flat and says how it is folded. Fold turns the live picture into a 3D Duo, on any iPhone or iPad: drag its halves apart or together, spread or pinch two fingers, or use the Closed, Half open and Open buttons, and it folds about the middle like a book, staying centred, closed showing its outer screen; the simulator's hinge follows your finger, and when you let go the simulator is held the way the Duo is shown, upright whenever it is closed; touches move the Duo, not the simulator, until it unfolds back into the flat picture a second and a half after the last touch (event `folded`; a fold that fails prints a `warning` with code `foldFailed`, and the app says why). The host folds and turns a Duo with one message each, as dragging Device Hub's hinge slider does: a fold takes a third of a second and a turn four hundredths (iOS 27.3 simulator), and for two seconds afterwards the host reads the screens every 40 ms, so the app shows the hinge moving and the other screen lighting as they happen. A Duo shut after standing half open on the home screen often keeps its inner screen lit and its outer one dark (32 of 40 tries); the host then opens it to 8 degrees and shuts it again, which lights the outer screen (about a second in all), and until it has, it streams the inner screen, which is the one showing. It does the same for a simulator it finds like that while a viewer is watching, whoever shut it.
- `axe mirror` notices when the simulator on screen stops answering: reads of its screens or touches keep failing, its touch connection does not open within 20 seconds, a fold's hinge has not arrived within three seconds, or a process started in it every ten seconds does not start. It prints `unresponsive` (`udid`, `reason`), and `responsive` when it answers again. The AXe Mirror app (1.2) then says the simulator is not responding and offers Restart, which shuts it down, by force if it will not stop (its launchd and every process under it are killed), then boots and opens it again (event `simulatorRestarting`). Restart is also in the list for any running simulator. The host never restarts a simulator by itself. It also samples the Mac's own load once a second and prints `macBusy` (`load`, `cpu`) after ten seconds of overload, and `macNotBusy` after ten quiet ones. The app then shows one notice at a time, never two: a simulator that stops answering on a busy Mac reads "slow to answer", with the Mac's load, and Restart after a minute; on a quiet Mac "not responding", with Restart at once. Refused touches count once a quarter of a second, so one bad swipe is not taken for a simulator that has stopped, and a simulator that starts a process is taken to be answering whatever a touch or a fold said before.
- The AXe Mirror app (1.2) puts its controls wherever they leave the biggest picture: in bars above and below, in a column at the side, or in one bar on top on a wide screen. On an iPhone Duo open flat, a picture that loses little on one half takes it, with the controls on the other half; folded like a book it always does. The trackpad is only on a Duo stood on a table.
- The AXe Mirror app's first screen lists each paired Mac with a Connect button, with "Pair Another Mac" as the last row and a labelled Pair button in the toolbar where there was a plus sign. Forgetting a Mac is a swipe or a press and hold, and asks first.

### Fixed
- `axe mirror unpair` now takes a connected device's access away at once. A running host closes that viewer's session within a second and prints `unpaired`; before, a removed device kept the session it had open, with everything a paired viewer may do, until its connection happened to drop.
- A device can now be paired when it and the Mac have picked different relays, when the Mac is on iroh's public relays, and when the Mac was started with `--relay-url`: the app looks on every relay the Mac could be on at once, and a relay named on the command line travels in the QR code. A correct code no longer finds "no Mac". A pairing whose answer is lost on the way is made again instead of being reported as refused.
- `axe mirror` now stops with an error and a failing status when it cannot listen for viewers, where it went on running with no listener, and prints a `relayUnreachable` warning when no relay has answered for 20 seconds, where it waited in silence. `--relay-url` refuses an address that is not one, where it quietly used iroh's public relays instead.
- `axe mirror` sends the screen again when a frame was skipped or dropped. If that frame was the last before the screen stood still, the app went on showing the old picture while touches landed on the real one.
- `axe mirror` tries again when a simulator's touch connection does not open, where one failure left that viewer with video and no touches until the host was restarted.
- `axe mirror` no longer lets a viewer make it hold touches without limit, or play a touch whose position or time is not a number, and a demo host's visitor can no longer keep the demo by connecting again, take it from the visitor who came after, or ask for a keyframe with every frame.
- `axe mirror` prints each event as one whole line when several viewers' events come at once; long lines could be cut by another's and reach a program reading them as lines that are not JSON.
- Two devices that give the same name, as every iPhone does ("iPhone"), are now listed apart: the second is "iPhone 2", and `axe mirror unpair` takes either by name.
- An idle `axe mirror` host does no work for touches or for its link probe while nothing needs it: 0.1% of a core with no viewer connected, where it used 0.4%.
- The AXe Mirror app (1.2) says a device is not paired when the Mac says so the moment it connects, where it could say the Mac was unreachable and keep trying; shows a still picture that arrived before the Mac said what it was showing, where it could wait for one for ever; fits the picture at once when Fit to Screen is switched on; stops pairing when Cancel is tapped, where a Mac could still appear in the list afterwards; keeps the device's key when the Keychain cannot be read, where it made a new one and so unpaired every Mac; and no longer stops on a message from a Mac that holds a number that is not one.
- `axe mirror` lets every paired viewer be connected at once. It kept one viewer at a time, so a second paired device took the first one's place, the first connected again by itself and took it back, and the two went on dropping each other for as long as both were open (26 connections in two minutes, measured with two simulators on 21 November 2026). Each viewer now has a session of its own on the host: its own simulator on a host started without `--udid`, its own picture, and its own list of builds, so two people can install builds from one Mac together. Viewers shown the same simulator each get its picture and can all touch it. An event that comes from a viewer carries `viewer` (its ID, as `axe mirror viewers` lists it) and `viewerName`. A `--demo` host still takes one visitor at a time.
- The AXe Mirror app (1.2) no longer shows the host's own error text, such as "Could not start xcrun simctl. Select Xcode with xcode-select.", to someone holding a phone. `axe mirror` now sends each failure as a problem written for the viewer: what happened in plain words, a code for the kind of failure, and the one thing the viewer can do about it (try again, restart the simulator, or update the list). The app shows that with a button for the action; the host's technical message is behind Details.
- `axe mirror` keeps working when Xcode is updated or switched while it runs. It kept the path of the old Xcode's `simctl`, and every list, boot and shut-down then failed with "Could not start xcrun simctl" until the host was restarted.
- `axe mirror` no longer crashes when a simulator's screen goes away under it, as an iPhone Duo's outer screen does when it opens. CoreSimulator then calls the screen's change callback with nothing, which AXe had declared it never would, and the host stopped with a segmentation fault; the AXe Mirror app then said the Mac was not answering.
- The AXe Mirror app (1.2) shows Home, App Switcher and Lock only while a simulator is on screen and the Mac is connected. They stayed on screen, doing nothing, while the Mac could not be reached.
- `axe mirror` stops cleanly when its terminal is closed (SIGHUP), as it does on Ctrl+C, so the viewer is told at once. It died without closing the connection, and the AXe Mirror app went on looking connected for about half a minute: a simulator chosen then showed "Starting" and never started.
- The AXe Mirror app (1.2) drops a connection on which the Mac has said nothing for 15 seconds (it answers a ping twice a second) and says it is reconnecting. It relied on the connection's own timeout, about 34 seconds, and on a phone that had been in the background it went on looking connected for minutes. A choice the Mac never answered left "Starting" on screen for ever; the app now goes back to the list after 20 seconds, or when the connection drops, and says what happened.

## [v2.1.1] - 2026-11-19

### Fixed
- `axe mirror` no longer ignores a viewer's first touches after it connects again. The host remembered the gesture numbers of the last connection, and a viewer starts from one each time it connects, so it took the new touches for repeats and dropped them: after 17 touches in one connection, the first 17 of the next did nothing, while the Home and app switcher buttons still worked. A host that had served more than 32 gestures dropped a later run of 32 instead. The host now forgets them when a viewer connects or leaves, and lifts a finger that a viewer left down.

## [v2.1.0] - 2026-11-19

### Added
- `axe serve --udid <UDID>` keeps one process open and runs one command per standard input line, answering each with the JSON line `axe --output json` prints. Setup happens once, and serve keeps the input broker running between commands, so reading the screen and tapping took about 176 ms instead of 290 ms on an iPhone 17 Pro simulator (146 ms with `--minimal-keys`). Based on the serve mode proposed in [#70](https://github.com/cameroncooke/AXe/pull/70) by [@alex-hall](https://github.com/alex-hall) and [@dphurley](https://github.com/dphurley).
- `describe-ui --minimal-keys` reads only label, identifier, value, frame, role, role description, type and enabled state, about 30 ms faster on a Settings screen ([#70](https://github.com/cameroncooke/AXe/pull/70) by [@alex-hall](https://github.com/alex-hall)).
- `axe device-port --udid <UDID> --port <port>` saves a physical device's service directory port when AXe cannot read it on that Mac. AXe checks the port with the device first and uses it until the device's tunnel is recreated. Without `--port` it prints a line to paste in Terminal that finds the port with `netstat` and saves it ([#91](https://github.com/cameroncooke/AXe/issues/91)).
- Agent mode can now see and use web pages. `describe-ui --agent --web` lists the links, buttons, text fields, checkboxes, pop-up buttons and search suggestions of the pages on screen as `w` refs, and `tap --agent --ref w3`, `type --agent --focus --ref w2` and `key`, `key-combo` and `key-sequence` act on them, so an agent can fill in a form, clear a field, pick from a drop-down and move around a site or web app; `swipe --agent` on the web view's scroll area scrolls the page. Safari sheets also list their Back, Forward, Reload, Share and Open in Safari buttons and the keyboard's Previous, Next and Done; their Close button is not reachable through accessibility. It works in WKWebViews in any app, whether or not they set `isInspectable`, in Safari, SFSafariViewController and ASWebAuthenticationSession sign-in sheets. Only controls a tap would reach now are listed; the page text is left to screenshots. AXe finds each page with a few hit tests, walks it for controls, and checks the element at a control's point again just before the tap and before each key (when the keyboard covers a field, each key checks only that the same app is still in front). On an iPhone 18 Pro simulator (release build) a capture took about 0.29 s with `--web` and 0.13 s without, and agent commands without `--web` are as fast as before ([#65](https://github.com/cameroncooke/AXe/issues/65)).
- `axe mirror --udid <UDID>` hosts one booted simulator for the free AXe Mirror app on iPhone and iPad, which shows the simulator's screen live and sends touches back. The screen is streamed as HEVC video at up to 60 frames a second with a bitrate that adapts to the link, and the viewer's touches (one or two fingers) and its Home, app switcher and Lock buttons are replayed on the simulator. The command prints one JSON line per event and runs until Ctrl+C. Connections are encrypted from end to end and go directly between the two devices when they can, through a relay when they cannot. When macOS keeps `axe` off the local network, the host says so (event `warning`, code `localNetworkBlocked`) and puts a viewer on the same network on the relay. It needs an Apple silicon Mac with macOS 14.5 or later. The app's source is in `AXeMirror/` and can be built without the App Store. See [Mirror](README.md#mirror-a-simulator-on-your-iphone-or-ipad).
- `axe mirror pair` shows a one-time code, as text and as a QR code in the terminal, for the app to scan or type; it works once and for ten minutes. Only paired viewers can connect. `axe mirror viewers` lists them and `axe mirror unpair <name or ID>` removes one.
- `axe mirror --udid <UDID> --demo --demo-app <bundle ID>` runs a public demo host: any viewer may connect without pairing, one at a time, and is kept inside one app, with the hardware buttons off, touches from the top and bottom edges dropped and the bitrate capped. The host checks which app is in front and, when it is another, drops the visitor's touches and brings the app back. A demo host uses its own key.
- The source of the AXe Mirror app for iPhone and iPad is in [AXeMirror/](AXeMirror/README.md). It shares its protocol files with `axe mirror`.

### Changed
- AXe is now licensed under the GNU General Public License version 3 only (GPL-3.0-only) instead of the MIT License. Running `axe` to test an app does not put that app under the GPL; distributing AXe, or software that contains its code, must follow the GPL, and a commercial licence is available for closed-source use. Releases up to and including v2.0.4, and all source published before this change, remain available under the MIT License. The licence and third-party notices now ship in AXe's resource bundle under `licenses/axe`. See [Licence](README.md#licence).
- `axe type` now types on the simulator's own hardware keyboard layout instead of always sending US key positions, so text arrives as written on German, French, British and other keyboards, including characters that need Option or a dead key. Before, `yz@` arrived as `zy“` on a German keyboard and `#` as `£` on a British one. AXe reads the layout from the simulator's keyboard settings and the key positions from the layout data in its runtime. This covers `type` on every simulator route (plain, `--input-mode selected`, `--agent`), batch type steps and `serve`. `--layout <name>` names a layout and `--layout us` sends US key positions as before. On a physical device `--layout <name>` types on that layout too, with the layout data of the closest installed simulator runtime; a device does not report the keyboard in use, so it keeps US positions by default and refuses `--layout auto`. ([#81](https://github.com/cameroncooke/AXe/issues/81), reported with a first implementation in [#95](https://github.com/cameroncooke/AXe/pull/95) by [@scriptease](https://github.com/scriptease))
- `axe --output json describe-ui` now takes as long as plain `describe-ui`, about 45 ms less on a Settings screen, with the same output.

### Fixed
- On an Apple TV simulator, AXe now fails at once with `unsupportedDevice` and says it supports iPhone and iPad simulators. Before, `describe-ui`, `tap`, `swipe` and `touch` waited 60 s and then said the simulator was still starting, and `displays`, `screenshot`, `record-video` and `stream-video` printed internal errors. AXe has never supported tvOS; `key` and `button` still send their input as before ([#69](https://github.com/cameroncooke/AXe/issues/69), reported by [@ashwin-raghuraman](https://github.com/ashwin-raghuraman)).
- On the iPhone Duo with iOS 27.1, `hinge read`, `hinge set`, agent input and the plain screenshot no longer fail with "Motion sample reports invalid angle or velocity". That runtime reports no velocity with any hinge sample; AXe now reads it as 0 and still refuses a sample whose angle is invalid ([#87](https://github.com/cameroncooke/AXe/issues/87), reported by [@WingCH](https://github.com/WingCH)).
- On the iPhone Duo Home screen, agent captures no longer list every icon, Dock item and status bar control twice. SpringBoard lists the windows of both screens, and AXe now leaves out the windows sized to the screen that is off, so a ref names one control. On a 27.2 Duo the agent capture took 0.22 s instead of 0.37 s folded and 0.29 s instead of 0.40 s open. Folded Home-screen icon taps that were refused as `targetCovered` now go through. ([#87](https://github.com/cameroncooke/AXe/issues/87))
- An agent tap no longer goes through when its tap point lands on bare background instead of the control. SpringBoard on the iPhone Duo can keep an icon's frame from the other screen's layout, so the frame's centre can be empty wallpaper; AXe now refuses that tap with `targetCovered` and sends nothing, where a copy on the screen that is off used to send a tap that did nothing. ([#87](https://github.com/cameroncooke/AXe/issues/87))
- Physical devices on Macs that hide network connections from AXe no longer fail with "The CoreDevice service directory port was not found" and nothing to do about it. AXe found the port with `netstat`, which listed no connections to an ad hoc signed AXe on two Macs with macOS 27.2.1 and an endpoint-security agent, and then with a system log scan that took 8 to 41 s and found nothing for a tunnel older than a day. AXe now reads the port with `nettop` in about 70 ms and no longer scans the log. When that also fails, the error prints one line to paste in Terminal that finds the port and saves it with `axe device-port` ([#91](https://github.com/cameroncooke/AXe/issues/91), reported by [@pbush25](https://github.com/pbush25) and [@Jonathanm10](https://github.com/Jonathanm10)).
- On the iPhone Duo's open screen in landscape, and on an iPad in landscape, Home-screen frames now match what is on screen, so agent taps on Dock icons, Home-screen icons and the search button go through instead of being refused as `targetCovered`. SpringBoard reports those frames in the screen's unrotated portrait coordinates while apps report rotated ones; AXe now rotates SpringBoard's frames. ([#87](https://github.com/cameroncooke/AXe/issues/87))
- On the iPhone Duo, captures no longer list Home-screen icons from the other screen. SpringBoard hands one screen's icon list the other screen's icons, with that screen's positions; AXe now asks each Home-screen button which screen it is on and leaves out the others. Those icons cannot be named on the screen where they appear, because accessibility does not list them there; tap them by coordinates from a screenshot with the capture's snapshot ID. ([#87](https://github.com/cameroncooke/AXe/issues/87))
- Plain `describe-ui`, `tap --id` and `tap --label` on the iPhone Duo now read only the active screen, as agent mode does, so each Home-screen control appears once with frames that match the screen. Plain `describe-ui` took 0.24 s instead of 0.35 s folded and 0.28 s instead of 0.36 s open. ([#87](https://github.com/cameroncooke/AXe/issues/87))
- When an agent swipe, drag or pinch is refused because AXe cannot place its start point inside the chosen area, the message no longer says the screen moved. It names the gesture, and it says to use coordinates only once a fresh screenshot shows the start point is on that area. ([#87](https://github.com/cameroncooke/AXe/issues/87))

## [v2.0.0]

### Physical iPhone and iPad support

AXe now automates connected iPhones and iPads as well as simulators. Pass a device's hardware UDID to the same commands you use on a simulator: screenshots, accessibility reads, taps (by point or by `--id`, `--label` or `--value`), swipes, drags, `draw`, gestures, typing, keys, buttons, batches, `rotate`, `settings`, `record-video` and `stream-video`, including native H.264 with `--format h264`.

```bash
axe list-devices
axe doctor --udid "$DEVICE_UDID"     # pairing, Developer Mode, disk image, lock state
axe describe-ui --udid "$DEVICE_UDID"
axe tap --id "$ELEMENT_ID" --wait-timeout 15 --udid "$DEVICE_UDID"
```

Pair the device in Xcode, turn on Developer Mode and keep it unlocked; AXe never does any of these for you. `button lock` needs `--allow-lock`, and a command a device cannot run fails with `unsupportedOnDevice`. Reading a device's screen takes about 1 second plus 44 ms per element. See [Physical iPhone and iPad](README.md#physical-iphone-and-ipad) and [docs/device-support.md](docs/device-support.md).

### iPhone Duo support

Every input, read and capture command works on the dual-screen iPhone Duo simulator, on whichever screen is active, in any fold and orientation. New commands show the screens and move the hinge:

```bash
axe displays --udid "$UDID"               # each screen's role, size, orientation and the hinge angle
axe hinge set tabletop --udid "$UDID"     # 0...180, or closed, tabletop, open
axe rotate left --udid "$UDID"            # also works on physical devices
```

`--input-mode selected` with `--screen-id` and `--screen-uuid` refuses to act if a different screen becomes active, and `record-video --follow-active-display` records one movie through folds and rotations. See [Displays, hinge and rotation](README.md#displays-hinge-and-rotation) and the [device reference](agent-plugin/skills/axe/references/device-reference.md).

### Agent mode

Add `--agent` to `describe-ui`, `tap`, `type`, `swipe`, `drag`, the key commands, `slider`, `touch`, `gesture double-tap`, `gesture pinch` and `batch` so an AI agent can drive the UI with every action checked. A capture returns compact rows with a ref for each control. An action names a ref, AXe checks the control is still there, sends the input and returns the new screen, so an agent needs no separate read after each action.

```bash
axe describe-ui --agent --view navigation --udid "$UDID"
axe tap --agent --snapshot-id "$SNAPSHOT_ID" --ref e9 --udid "$UDID"
axe type 'Ada' --agent --focus --snapshot-id "$SNAPSHOT_ID" --ref e18 --udid "$UDID"
```

`batch --agent` fills a form in one call, and a refusal sends no input and carries a typed code. Agent mode needs no model or API key. See [Agent mode](README.md#agent-mode) and the [agent reference](agent-plugin/skills/axe/references/agent-reference.md).

### Structured output and error codes

Put `--output json` before a command to get one JSON result with a typed payload, or a typed error code instead of a message to parse. Simulators and devices share one set of error codes, and JSON Schema files describe every result.

```
$ axe --output json tap --id no-such-element --udid "$UDID"
{"command":"tap","data":{},"didError":true,"error":{"code":"elementNotFound","message":"No accessibility element matched --id 'no-such-element'. …"},…}
```

Text output is shorter and consistent too: state commands print their state, input commands print nothing except `tap`, `slider` and `batch`, and errors read as plain sentences. `--verbose` adds the full detail without changing the exit status. See [Output and errors](README.md#output-and-errors) and [schemas/](schemas/).

### Added

- Added `axe settings` for simulators and devices to change appearance, text size, accessibility settings, VoiceOver, simulated location and the simulator status bar (Xcode 27 or later). See [Settings](README.md#settings).
- Added `axe draw` to move one finger through up to 1,000 points. See [Swipes, gestures and drawing](README.md#swipes-gestures-and-drawing).
- Added long press, double tap and two-finger tap to `tap` (`--hold`, `--count 2`, `--touches 2`), on a point or an element. See [Taps, typing and keys](README.md#taps-typing-and-keys).
- Added `--until-id` and `--until-label` to scroll presets and `swipe`, which scroll until an element is on screen, plus `--distance`, `--inside-id` and `--inside-label` for scroll presets.
- Added the `pinch`, `double-tap`, `rotate`, `two-finger-tap`, `two-finger-hold` and `two-finger-swipe` gestures, a `swipe-from-top-right-corner` preset that opens Control Centre, and `--edge-inset` for edge swipes.
- Added `drag --hold` to rest the finger before moving, for reordering a list.
- Added `slider --endpoint minimum|maximum`.
- Added `shutdown` for one simulator and `clipboard copy --stdin` to put text in a simulator's clipboard. See [Simulator shutdown and clipboard](README.md#simulator-shutdown-and-clipboard).
- Added the experimental `axe agent "<goal>"` command, which works towards a plain-language goal one checked action at a time using TypeSafe AI's Jev model. See [docs/agent.md](docs/agent.md).
- Added Claude Code and Codex plugin marketplaces, so the AXe skill stays updated as releases ship ([#64](https://github.com/cameroncooke/AXe/pull/64) by [@tal](https://github.com/tal)). See [AI skill](README.md#ai-skill).

### Changed

- Simulator input and screen reads are much faster than in v1.8.0 (measured on an iPhone 18 Pro simulator): a tap takes about 0.08 s instead of about 1 s, a drag 0.9 s instead of 2.5 s, and `describe-ui` 0.3 s instead of 1.1 to 1.9 s.
- Every command's `--help` is rewritten with a short description, examples and one-line option help, and help that was wrong is corrected.
- The AXe skill that `axe init` installs is rewritten around agent mode.

### Fixed

- Fixed a command sent straight after `button home` on Xcode 27.2 failing with `DTUHID guest barrier timed out`.
- Fixed a command intermittently failing with `setsockopt(SO_RCVTIMEO) failed: Invalid argument`.
- Fixed `touch` leaving a finger held down after a `--delay` over 10 seconds, or after `touch --down` was left without `--up`.
- Fixed an uncaught Objective-C exception crashing AXe; it now prints the exception and exits with 70 ([#77](https://github.com/cameroncooke/AXe/pull/77) by [@sbadakhc](https://github.com/sbadakhc)).
- Fixed an accessibility read in the first seconds after boot breaking accessibility until the simulator was rebooted ([#68](https://github.com/cameroncooke/AXe/pull/68)).
- Fixed gesture presets on iPads and large iPhones acting on a 390×844 corner of the screen instead of the whole screen.
- Fixed `stream-video` sending PNG data as JPEG frames, and MJPEG streams whose frame boundaries did not match their header.
- Fixed `axe init` leaving out the skill's reference files.
- Fixed `tap` printing its error twice when a selector matched nothing, and `batch` hiding a step's validation message.
- Fixed `touch --help` examples using options that do not exist ([#80](https://github.com/cameroncooke/AXe/pull/80) by [@demrom](https://github.com/demrom)).

Various other internal improvements to stability, performance, and code quality.

### Removed

- Building from source no longer clones IDB: its frameworks are in `Packages/IDBKit`, and the `IDB_CHECKOUT_DIR`, `IDB_GIT_URL`, `IDB_GIT_REF` and `IDB_UPSTREAM_BASE_REF` build settings are gone.

## [v1.8.0] - 2026-07-20

### Added

- Added Xcode 27 and iOS 27 simulator automation through Device Hub without requiring Simulator.app, while retaining Xcode 26 support ([#60](https://github.com/cameroncooke/AXe/pull/60) by [@jkaunert](https://github.com/jkaunert)). See [Xcode compatibility](README.md#xcode-compatibility).

### Changed

- Strengthened release supply-chain integrity with immutable, verified IDB sources and stricter validation of release inputs and signing identities.

### Fixed

- Fixed BGRA video streams ignoring the requested `--fps` value and running at an uncapped frame rate.
- Fixed release archives failing strict Gatekeeper verification because of embedded filesystem metadata.
- Fixed commands exposing low-level simulator errors instead of actionable failure messages.

Various other internal improvements to stability, performance, and code quality.

## [v1.7.1] - 2026-06-02

### Added

- Added AxePlayground alert, sheet, context menu, modal navigation, and long-scroll fixtures for UI automation regression coverage.

## [v1.7.0] - 2026-05-11

### Added

- Added `axe slider --id/--label --value 0...100` for selector-based slider setting with orientation-aware HID dragging and AXValue tolerance verification/failure reporting.
- Added `axe drag --start-x/--start-y --end-x/--end-y` for raw point-to-point low-level HID drag validation using explicit touch move events.

### Changed

- Changed `axe slider` to use the shared composite low-level HID drag path with AXValue tolerance verification instead of retrying with correction gestures.

### Fixed

- Fixed `describe-ui` and selector-based `tap --label` exposing and activating real SwiftUI `TabView` tab items, navigation search fields, toolbar segmented picker items, and generated navigation back buttons from the CoreSimulator accessibility bridge. Also fixed selector decoding when the accessibility tree contains numeric `AXValue` fields such as sliders.
- Fixed `tap`, `touch`, `swipe`, and matching batch steps dispatching logical UI coordinates directly to FBSimulatorHIDEvent without landscape rotation or letterbox correction, causing interactions to land in the wrong location in rotated landscape simulators and portrait-hardware landscape-only apps. AXe now detects the simulator UI orientation automatically instead of requiring callers to pass landscape flags ([#5](https://github.com/cameroncooke/AXe/issues/5) by [@Nitewriter](https://github.com/Nitewriter))
- Fixed selector-based `tap` and batch tap steps so UIKit `UISwitch` and SwiftUI `Toggle` controls can be activated reliably, including when a matched row or label contains a single switch/toggle control. Added `--tap-style` so switch/toggle taps can use physical touch automatically while normal taps keep the simulator `tapAt` path by default ([#46](https://github.com/cameroncooke/AXe/pull/46)).
- Fixed element comparison in `AccessibilityTargetResolver` to prevent distinct elements with the same type and frame but lacking labels/values from being incorrectly identified as identical during ancestor tree traversal.

## [v1.6.0] - 2026-04-05

### Added

- Added `--value` targeting for `tap`, allowing elements to be matched by their accessibility value in addition to `--id` and `--label`. Added `--element-type` filtering to narrow matches by element type (e.g., button, text field) ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).
- Added `--wait-timeout` and `--poll-interval` options to `tap` for waiting until a matching element appears before tapping ([#40](https://github.com/cameroncooke/AXe/pull/40) by [@andresdefi](https://github.com/andresdefi)).

### Fixed

- Fixed `describe-ui` to expose and implement the documented `--point` option in command help and runtime behavior ([#38](https://github.com/cameroncooke/AXe/issues/38))

## [v1.5.0] - 2026-03-04

### Added

- Added `batch` command for executing ordered multi-step interaction workflows in a single invocation, with sequential execution that supports multi-screen flows, built-in `sleep` delays, accessibility caching, and configurable text submission strategies ([#25](https://github.com/cameroncooke/AXe/pull/25)). See [BATCHING.md](BATCHING.md).
- Added `axe init` command to install, uninstall, or print the AXe skill for AI clients (`claude`, `agents`) or a custom destination ([#25](https://github.com/cameroncooke/AXe/pull/25)).

### Fixed

- Fixed Homebrew installation on Intel Macs by producing architecture-specific release artifacts ([#27](https://github.com/cameroncooke/AXe/pull/27), [#21](https://github.com/cameroncooke/AXe/issues/21))
- Fixed `tap --label` resolving ambiguous matches by preferring actionable elements over read-only ones ([#28](https://github.com/cameroncooke/AXe/pull/28))

## [v1.4.0] - 2026-02-08

### Added

- AxePlayground Touch Control now shows long-press count and last long-press coordinates, making gesture automation easier to validate.

### Fixed

- Improved long-press reliability for `axe touch`: `--down --up --delay` now consistently behaves like a real press-and-hold gesture.

## [v1.3.0] - 2026-01-28

- Add `key-combo` command for atomic modifier+key presses (e.g., Cmd+A, Cmd+Shift+Z) Thanks to @jpsim for the contribution!

## [v1.2.0] - 2025-12-19

-Add support for screenshot capture to PNG
-Add tap by label or accessibility id in addition to existing x/y coordinates
-Fix FBProcess duplication warnings

Special thanks to @aliceisjustplaying and @onevcat for their execellent contributions!

## [v1.1.1] - 2025-09-22

-Pin IDB version to address access control issues on new versions


## [v1.1.0] - 2025-09-21

- Add support for streaming and video capture (thanks to @pepicrft for the contribution!)


## [v1.0.0] - 2025-06-01

- Initial release of AXe
- Complete CLI tool for iOS Simulator automation
- Support for tap, swipe, type, key, touch, button, and gesture commands
- Built on Meta's idb frameworks with Swift async/await
- Comprehensive test suite with AxePlaygroundApp
- Gesture presets and timing controls
- Accessibility API integration

## [v0.1.1] - 2025-09-21
- README updates

## [v0.1.0] - 2025-05-27

- Initial release of AXe
