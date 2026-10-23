# Follow-active-display recording

Source candidate only. Build, existing checks and native movie verification are pending.

Use record-video --follow-active-display to keep one movie across measured active-panel, orientation and hinge changes on one boot. The first frame fixes the canvas; later upright frames fit with black bars. Existing paired-screen recording still stops on context changes. Raw recording and selected streams retain their routes.

The command retries only typed lock-busy or transition reads after cleanup. No lease is held during retry sleep. Capture uses the existing native feed, child ownership and same-frame context checks; it does not accept a frame across a detected change. Boot changes and uncertain cleanup remain fatal. The recording follows the display, not an app PID. It does not promise smooth animation or all intermediate poses. See the skill recording reference for exact bounds.

## Required manual proof

1. Start one recording on owned Duo outer portrait. Wait for an accepted frame, then use the normal public open command once. Require an accepted inner frame; rotate once and require another accepted frame. Stop normally.
2. Decode the completed MP4. Confirm fixed dimensions, upright visible controls, black bars rather than stretch or crop, and increasing timestamps across the gaps. Compare accepted first/last measured context with the real display observations.
3. Require all owned capture descendants to exit, temporary movie removal and one final movie only after encoder completion. Check receipt gap/change counts against captured logs; they count observations, not every physical transition.
4. Check mixed-screen options and wrong boot refusal without a successful output. Check existing destination protection. Preserve the actual failure and do not retry app/device actions automatically.
5. Run existing fixed-screen recording and legacy option checks to confirm unchanged behavior. An earlier fixed-pose pass does not prove this new candidate.

Only root runs build/native work, one process at a time under the existing resource guard. Do not change endpoint timeouts or memory thresholds. Native framework source and wire versions are unchanged. Security scan remains UNVERIFIED per Cam.
