# Device settings

`axe settings` works on a booted simulator or a connected iPhone or iPad, through devicectl (needs Xcode 27+). No `--agent`. After any change take a new agent capture: the UI redraws.

```bash
axe settings show --udid <UDID>
axe settings set --udid <UDID> --appearance dark --text-size extra-large --reduce-motion on
axe settings location set --latitude 51.5007 --longitude -0.1246 --udid <UDID>
axe settings location scenarios --udid <UDID>
axe settings location scenario "City Run" --udid <UDID>
axe settings location clear --udid <UDID>
axe settings status-bar preset screenshot --udid <UDID>   # also low-battery, no-service, charging
axe settings status-bar set --udid <UDID> --time 9:41 --wifi-bars 3 --cellular-bars 4 --battery-level 100 --battery-state charged
axe settings status-bar clear --udid <UDID>
```

`set` options:

- `--appearance light|dark`
- `--text-size`: `extra-small`...`extra-extra-extra-large`, `accessibility-medium`...`accessibility-extra-extra-extra-large`
- `--increase-contrast`, `--reduce-motion`, `--reduce-transparency`, `--show-borders`: `on|off`
- `--liquid-glass clear|tinted`, `--liquid-glass-opacity 0...1`
- `--color-filter off|grayscale|protanopia|deuteranopia|tritanopia`, `--color-filter-intensity 0.25...1` (not for grayscale)
- `--voiceover on|off`

`set` prints the resulting settings in the spelling it accepts; no `show` needed after it. Text size alone decides Larger Accessibility Sizes: an accessibility size turns it on, a standard size off, so setting the original size restores the device.

JSON `data.result`: `{udid, appearance, textSize, increaseContrast, reduceMotion, reduceTransparency, showBorders, liquidGlass: {style?, opacity}, colorFilter: {enabled, type?, intensity?}, voiceOver}`. Unreported settings are omitted.

## Restore

- Restore what you change. Turn VoiceOver and colour filters off when done: VoiceOver changes how every touch works.
- Turning VoiceOver on shows a one-time "VoiceOver Gestures" alert that stays, and blocks input, after VoiceOver is off again. Capture the screen and tap its OK button.
- Simulated location lasts until `location clear`.

## Errors

- `targetNotFound`, `notBooted`, `invalidArguments`.
- `settingUnsupported`: the device, OS or Xcode lacks it. iOS 27.2 offers one Liquid Glass style, so `--liquid-glass` is refused while `--liquid-glass-opacity` works. Status bar overrides are simulator-only.
- `settingFailed`: devicectl's message.
- A physical device that is not ready fails with its `doctor` check code.
- Nothing changes when validation fails.
