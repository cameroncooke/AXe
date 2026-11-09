# Device settings

`axe settings` works on a booted simulator or a connected iPhone or iPad (needs Xcode 27+). No `--agent`. Take a new agent capture after any change: the UI redraws.

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

`set` options: `--appearance light|dark`, `--text-size` (`extra-small`...`extra-extra-extra-large`, `accessibility-medium`...`accessibility-extra-extra-extra-large`), `--increase-contrast`, `--reduce-motion`, `--reduce-transparency`, `--show-borders` (`on|off`), `--liquid-glass clear|tinted`, `--liquid-glass-opacity 0...1`, `--color-filter off|grayscale|protanopia|deuteranopia|tritanopia`, `--color-filter-intensity 0.25...1`, `--voiceover on|off`. It prints the resulting settings, so no `show` is needed after it. Values print in the spelling `set` accepts. An accessibility text size also turns on Larger Accessibility Sizes, which a later standard size leaves on.

JSON `data.result`: `{udid, appearance, textSize, increaseContrast, reduceMotion, reduceTransparency, showBorders, liquidGlass: {style?, opacity}, colorFilter: {enabled, type?, intensity?}, voiceOver}`. Unreported settings are omitted.

Restore what you change. Turn VoiceOver and colour filters off when done: VoiceOver changes how every touch works. Simulated location lasts until `location clear`.

Errors: `targetNotFound`, `notBooted`, `settingUnsupported` (device, OS or Xcode lacks it; iOS 27.2 has no Liquid Glass style, and physical devices have no status bar overrides), `invalidArguments`, `settingFailed` (devicectl's message). Nothing changes when validation fails.
