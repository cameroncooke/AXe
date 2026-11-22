# Mirror a simulator to an iPhone or iPad

`axe mirror` hosts a simulator for the AXe Mirror app on iPhone and iPad, where a person sees the screen live and touches it. Use it when the user wants to see or touch a simulator from a phone or tablet, or to pair a device. It is not a way for you to read or drive the app: keep using agent mode for that. Needs an Apple silicon Mac with macOS 14.5 or later; simulators only. No `--agent`.

## Pair a viewer

```bash
axe mirror pair            # code and QR code in the terminal
axe mirror pair --json     # JSON lines instead of the QR code
```

- Shows a one-time code (`XXXXX-XXXXX`), and the same code as a QR code, for the user to scan or type in the app. It works once, for ten minutes.
- Blocks until a viewer pairs or the code expires. Run it in the background and read its output, or ask the user to run it in their own terminal, where they can scan the QR code.
- `--json`: a `code` line (`code`, `link`, `expires`, `relay`), then a `paired` line (`viewer`, `name`). Give the user the code to type.
- `--name <NAME>`: the name the app shows for this Mac. The host does not have to be running.
- A paired viewer can see and touch any simulator this Mac hosts, and on a host started without `--udid` it can boot, create, shut down and delete simulators, so pair only when the user asks.

## Host a simulator

```bash
axe mirror --udid <UDID>   # this booted simulator only
axe mirror                 # the user chooses, boots or creates a simulator in the app
```

- Use `--udid` when you know which simulator the user should see, such as the one you are testing on. Use plain `axe mirror` when the user wants to pick or make a simulator from their phone; see "Let the user choose" below.
- Long-running: it runs until SIGINT (Ctrl+C), SIGTERM or SIGHUP. Start it in the background and read its output; never wait for it to exit.
- One JSON line per event on stdout, logs on stderr. In order: `relays`, `endpoint` (`hostID`), `ready` (`udid`, `relay`); then for each viewer `viewerConnected`, `streaming` (`width`, `height`), `path` (`kind`: `direct` or `relay`) and `viewerDisconnected`; `stopped` at exit. Every value is a string. A viewer's events also carry `viewer` (its ID, as `axe mirror viewers --json` lists it) and `viewerName`, since several viewers can be connected at once.
- `ready`: a paired viewer can connect now. Tell the user to tap this Mac in the app.
- `refused` (`viewer`, `reason`): a viewer that is not paired tried to connect; pair it first. `error` (`message`): report it.
- `warning` with `code` `localNetworkBlocked`: macOS is keeping this process off the local network, so a viewer on the same network goes through the relay: it reconnects once when it arrives and its stream is slower. Viewers on other networks are not affected. Tell the user to allow the app `axe` runs from (their terminal, or the app you run in) in System Settings > Privacy & Security > Local Network. The host asks macOS again when the next viewer on the same network connects, so it does not need restarting.
- `rotated` (`udid`, `orientation`): the simulator's screen turned, by the viewer or anything else. Take a new capture before your next input: coordinates are in the new orientation.
- iPhone Duo host: the viewer can fold, open and turn the simulator and set its hinge angle. It never folds by itself: only when the user folds it in the app. One exception: a Duo that is shut with its inner screen still lit, which iOS often leaves it in after it has stood half open on the home screen, has its hinge opened to 8 degrees and shut again while a viewer is watching it, so that its outer screen lights; `screenChanged` follows. `screenChanged` (`udid`, `screen`: `outer` or `inner`): the other screen is now lit. `folded` (`udid`, `posture`: `closed`, `tabletop`, `book`, `open`, or `angle` for an angle set by hand): a fold the viewer asked for is done. `warning` with `code` `foldFailed`: it was not. After any of these, read `axe displays` and take a new capture before your next input.
- Any number of paired viewers at once, each with its own session: none takes another's place, each chooses its own simulator on a host without `--udid`, and each has its own Builds. On a `--udid` host, or when two choose the same simulator, they all see it and can all touch it. A viewer's touches (one or two fingers) and its Home, app switcher and Lock buttons act on the simulator, so take a new agent capture before your own next input.

## Let the user choose

Plain `axe mirror` opens no simulator at first. In the app the user sees a menu for this Mac, Simulators and Apps (tapping Apps lists the apps the Mac has builds of, on the menu itself); under Simulators they see its iPhone and iPad simulators, tap one (a shut-down one is booted first, which can take a minute) or create a new one from a name, a device and an iOS version. You learn which simulator they are on from the host's events, so keep reading them:

- `ready` has no `udid`. Tell the user to tap this Mac in the app and choose a simulator.
- `simulatorCreated` (`udid`, `name`, `model`, `os`): the user made a new simulator.
- `simulatorSelected` (`udid`, `name`): this simulator is booted and now on the user's screen. Use this `udid` for your own commands when the user says "use this simulator"; the app also lets them copy it and paste it to you.
- `simulatorReleased` (`udid`): the user left that simulator. It stays booted, also after the host stops, unless a `simulatorShutDown` follows; shut it down yourself with `axe shutdown --udid <UDID>` only if the user asks.
- `simulatorShutDown` and `simulatorDeleted` (`udid`, `name`): the user shut that simulator down or deleted it from the app. Stop using that `udid`; a deleted simulator is gone with everything in it.
- `unresponsive` (`udid`, `reason`): the simulator stopped answering; the app offers the user a restart. `simulatorRestarting` (`udid`, `name`): the user restarted it; apps running in it were closed, so wait for `simulatorSelected` and start your work in it again. `responsive` (`udid`): it answers again without a restart. Never restart it yourself unless the user asks.
- Builds to install: to put a build of the user's app on their own device, run `axe mirror build --project <project> --scheme <scheme> --notes "<what changed>" --json` (or `--workspace`), or `axe mirror publish <ipa> --json` for an IPA already signed for Ad Hoc distribution. AXe checks the IPA and refuses one iOS would not install, with the reason; fix that and build again. A running host offers the build in the AXe Mirror app within a few seconds, on the Mac's menu once the user taps Apps: with builds of one app the user sees that app's builds, newest first, and taps the build, then Install; with builds of several apps they tap the app first, or hold the app down and choose Install Latest Build; `--notes` is shown as the build's release notes, so write what changed for the person installing it. Host events: `buildsChanged` (`count`, `newest`): the build is on the user's screen. `installRequested` (`bundleID`, `name`, `version`, `build`): the build reached the device and was handed to iOS. That is not proof it installed: iOS installs it itself and neither end sees the result, so ask the user, or check the app's version another way. The build reaches the device over the mirror's own connection, so the user needs the AXe Mirror app open and connected to this host and nothing else: no VPN, no link to open. The first Install on a device opens a one-time setup in the app (a certificate the user installs and switches on in Settings; the app shows the taps as a video that floats over Settings), so tell the user to expect it. The JSON a publishing command prints has `devices_covered` and `devices_not_covered`, the names of this Mac's devices the build will and will not install on: if the user's device is not covered, say so, and that it must be registered with their developer account and the app built again with `--allow-provisioning-updates`. `axe mirror builds --json` lists what is published and how much room leftovers take. Manage the store with `--remove <id>` (repeatable), `--keep <n>` (newest n of each app), `--notes <id> "<text>"` and `--clean`; never remove a build the user did not ask you to. Removing a build does not uninstall it from a device.
- `macBusy` (`load`, `cpu`): this Mac has been overloaded for ten seconds (load per core over 1.5 with its processors nearly all in use); simulators may answer late or time out without being stuck, so expect slow commands. `macNotBusy` follows when it has been quiet for ten seconds.
- `warning` with `code` `viewerTooOld`: the user's app is older than 1.2 and cannot show the list. Tell them to update it, or host with `--udid`.

## Viewers

```bash
axe mirror viewers --json
axe mirror unpair <NAME_OR_ID>
```

- Only paired viewers can connect. `viewers --json` prints `{viewers: [{id, name, paired}]}`.
- `unpair` takes a name, an ID or the first six or more characters of an ID. A name that matches several viewers is refused; use the ID.

## Demo host

```bash
axe mirror --udid <UDID> --demo --demo-app <BUNDLE_ID>
```

- Needs `--udid`: a demo's visitors never get the list. Public: any viewer may connect without pairing, one at a time. It is kept inside that one app: no hardware buttons, no touches that start at the top or bottom edge, a capped bitrate, and touches are dropped and the app brought back whenever another app is in front. The app is started with `--launch-arg demo=1` for each visitor; the host stops with an `error` event if it cannot be started. It uses its own key.
- Start one only when the user asks for a demo host.

## Network

- Encrypted from end to end. The devices connect directly when they can and through a relay when they cannot.
- `--relay-url <URL>` on `mirror` and `mirror pair` uses that relay and no other.
