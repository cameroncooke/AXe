# Physical device support

Working plan for running AXe commands against a physical iPhone or iPad. Tick items as they land.

- Design: [AXe Physical Device Support Design](https://claude.ai/artifact/CWSMBBHmBK4gPALxZ5vtJ1)
- CLI surface and decisions: [AXe Device CLI Structure](https://claude.ai/artifact/1bERuSnxTYxzAGLdJamE3H)
- Wire formats: [device-protocols.md](device-protocols.md)

Rules that apply to every phase:

- Same commands and flags; `--udid` decides simulator or device. Anything a phone cannot do fails with `unsupportedOnDevice`.
- AXe never pairs, enables Developer Mode, mounts disk images or unlocks. It detects each and prints the fix.
- Protocol code is written from `device-protocols.md` and our own captures, never ported from GPL code (pymobiledevice3).
- `devicectl` is read only through its JSON file output, accepting both the `properties` shape and the older `connectionProperties`/`deviceProperties` shape.

## Phase 1: connection, listing, screenshot

- [ ] `devicectl` JSON reader for both shapes, with fixture tests
- [ ] Target resolver: simulator set first, then CoreDevice devices; `targetNotFound` names both
- [ ] RSD port discovery (`remoted` socket, `remotepairingd` log fallback) and a held RSD session
- [ ] XPC wire encoder/decoder and HTTP/2 RemoteXPC client, with fixture tests
- [ ] `axe list-devices` (text and JSON, readiness blockers)
- [ ] `axe doctor --udid` for devices (six requirements) and simulators
- [ ] `axe screenshot --udid <device>` through `screencaptureservice`
- [ ] Proven on a phone: `list-devices`, `doctor`, `screenshot`

## Phase 2: input

- [ ] `hid.indigo` client: digitizer (with `pointTwo`, `edge`), keyboard, button messages
- [ ] Display size and orientation from `deviceinfo`; landscape coordinate conversion
- [ ] Route tap, swipe, drag, touch, gesture, type, key, key-sequence, key-combo, button and batch to the device
- [ ] `rotate` on devices through `devicecontrol`
- [ ] Refusals: `--semantic-press`, `swipe-from-right-edge`, `side-button`, `apple-pay`; `lock` needs `--allow-lock`
- [ ] Proven on a phone: tap, swipe, type, home, rotate

## Phase 3: UI state from tree dumps

- [ ] DTX client and `remoteAXService` reader (InitialDump plus AdditionalData pair, resend after 2.5 s)
- [ ] One AXPTranslator token router shared by the simulator and device dispatchers
- [ ] Tree-dump dispatcher; `describe-ui`, `--point`, element targeting, polling
- [ ] Fail fast with `treeUnavailable` when a web alert blocks accessibility
- [ ] Proven on a phone: describe-ui, tap by id, polling

## Phase 4: device broker and live requests

- [ ] Per-device broker holding RSD, HID and accessibility, with the pushed tree cache
- [ ] Forward translator cache misses through `processDataFromHost:`; `--semantic-press`

## Phase 5: video

- [ ] `stream-video` by screenshots, then RTP/H.264 through `displayservice`
- [ ] `record-video`

## Phase 6: docs and hardening

- [ ] Skill `physical-device-reference.md` in both skill copies; SKILL.md links; `npx skill-check`
- [ ] README, help strings ("simulator or device"), CHANGELOG
- [ ] Multiple devices, sharing with Xcode Device Hub, older CoreDevice JSON fixtures
