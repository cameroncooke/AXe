# AXe 2.0 promo video

An 89-second 1080p60 film built with [Remotion](https://remotion.dev). Output: `out/axe-v2-promo.mp4`.

```sh
npm install
node make-music.mjs     # writes public/music.wav (original, synthesised)
npm run studio          # preview and scrub
npm run render          # about 4 minutes
```

Render without music: add `--props='{"music":false}'`.

## What is real

| Scene | Footage | Source |
| --- | --- | --- |
| Speed | Figures only | CHANGELOG v2.0.0, "Changed": v1.8.0 against v2.0.0 on an iPhone 18 Pro simulator. The tap race plays in real time (1 s against 0.08 s). |
| Agent mode | `public/agent.mp4`, `src/agent-log.json` | The benchmark's Weather app on an iPhone 18 Pro simulator, driven by `axe … --agent`. The terminal prints the logged commands and replies. Played at 1.8×. |
| Benchmark | Figures only | `benchmarks/results/2026-11-11-official-skills/README.md`. |
| iPhone Duo | `public/duo-outer.mp4`, `public/duo-inner.mp4` | Both screens of the iPhone Duo simulator while AXe taps Settings and moves the hinge. Played at 2×. The device body is a CSS 3D model; the fold animation is timed to the real hinge commands. |
| Real devices | `public/car-device.mp4`, `src/car.json` | An iPhone 16 Pro Max painting `scripts/fixtures/sketch-car.json` through `scripts/sketch_picture.py`: 163 `axe draw` strokes in 341 s, shown as a 52× time-lapse. The status bar's "back to app" breadcrumb is masked. |

Device bodies are illustrations; every screen inside them is a recording. Scene lengths are the constants at the top of each scene in `src/scenes.tsx`; if they change, update `CUTS` and `DUR` in `make-music.mjs`.
