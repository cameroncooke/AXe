# Mirror a simulator to an iPhone or iPad

`axe mirror` hosts one booted simulator for the AXe Mirror app on iPhone and iPad, where a person sees the screen live and touches it. Use it when the user wants to see or touch a simulator from a phone or tablet, or to pair a device. It is not a way for you to read or drive the app: keep using agent mode for that. Needs an Apple silicon Mac with macOS 14.5 or later; simulators only. No `--agent`.

## Pair a viewer

```bash
axe mirror pair            # code and QR code in the terminal
axe mirror pair --json     # JSON lines instead of the QR code
```

- Shows a one-time code (`XXXXX-XXXXX`), and the same code as a QR code, for the user to scan or type in the app. It works once, for ten minutes.
- Blocks until a viewer pairs or the code expires. Run it in the background and read its output, or ask the user to run it in their own terminal, where they can scan the QR code.
- `--json`: a `code` line (`code`, `link`, `expires`, `relay`), then a `paired` line (`viewer`, `name`). Give the user the code to type.
- `--name <NAME>`: the name the app shows for this Mac. The host does not have to be running.
- A paired viewer can see and touch any simulator this Mac hosts, so pair only when the user asks.

## Host a simulator

```bash
axe mirror --udid <UDID>
```

- Long-running: it runs until SIGINT (Ctrl+C) or SIGTERM. Start it in the background and read its output; never wait for it to exit.
- One JSON line per event on stdout, logs on stderr. In order: `relays`, `endpoint` (`hostID`), `ready` (`udid`, `relay`); then for each viewer `viewerConnected`, `streaming` (`width`, `height`), `path` (`kind`: `direct` or `relay`) and `viewerDisconnected`; `stopped` at exit. Every value is a string.
- `ready`: a paired viewer can connect now. Tell the user to tap this Mac in the app.
- `refused` (`viewer`, `reason`): a viewer that is not paired tried to connect; pair it first. `error` (`message`): report it.
- `warning` with `code` `localNetworkBlocked`: macOS is keeping this process off the local network, so a viewer on the same network goes through the relay: it reconnects once when it arrives and its stream is slower. Viewers on other networks are not affected. Tell the user to allow the app `axe` runs from (their terminal, or the app you run in) in System Settings > Privacy & Security > Local Network. The host asks macOS again when the next viewer on the same network connects, so it does not need restarting.
- One viewer at a time. The viewer's touches (one or two fingers) and its Home, app switcher and Lock buttons act on the simulator, so take a new agent capture before your own next input.

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

- Public: any viewer may connect without pairing, one at a time. It is kept inside that one app: no hardware buttons, no touches that start at the top or bottom edge, a capped bitrate. It uses its own key.
- Start one only when the user asks for a demo host.

## Network

- Encrypted from end to end. The devices connect directly when they can and through a relay when they cannot.
- `--relay-url <URL>` on `mirror` and `mirror pair` uses that relay and no other.
