# Input cancellation and accessibility failures: vendor review

Reviewed on 24 October 2026 at AXe `1a68126a20e151965fc9f603d1933d2ebb3c96ee`, with the existing local changes preserved.

## Result

The review gives one useful accessibility experiment and supports the existing input-cancellation fix. It does not establish a complete vendor solution which AXe can copy. Shared framework names do not mean the tools use the same versions or read paths.

This was a source and binary review. The installed CLIs ran only version/help commands. No app was launched, simulator action was sent, dependency was replaced, or production code was changed. The prior test failures remain failures. No new simulator acceptance is claimed.

## What the tools do

| Tool reviewed | Stop input when its caller closes | Accessibility connection failure | Lesson for AXe |
| --- | --- | --- | --- |
| FlowDeck CLI 1.33.0 `[fac60d]`, installed binary and frameworks | Has command-owner monitoring. Its normal gesture path sends a final touch-up. Release during a signal, fold or rotation is unproved. | The traced tree reader uses the older IDB CoreSimulator path. Failed HID sessions are discarded. One classified path repeats the gesture once; its numeric error classifier is not mapped to proof of zero delivered input. | Keep explicit ownership and release checks. Discard failed handles, but do not copy an input retry whose safety is unknown. |
| RocketSim 16.7.0 build 337, installed binary and frameworks | Compiled IPC code cancels work when a client disconnects. Browser pointer cancellation sends touch-up. The app's complete two-touch cleanup path remains unproved. | Its validator skips remote activation in one sandbox branch. Another branch attempts an existing CoreSimulator read after activation fails. This is a traced binary path, not a live recovery result. | Test that conditional read path in isolation. Keep touch release separate from closing a connection. |
| sim-use `c02295edfd2f442249b869096dda3dc7bfcd308d`, verified public HEAD | The daemon awaits the command without watching for client disconnection. Its timeout can return while an underlying send remains suspended. Physical release is unproved. | Its missing-object advice concerns a different AX error from our DTX channel closure. Its pinned IDB tree reader uses direct CoreSimulator AX. | Keep AXe's client-lifetime fix, explicit release and no-replay rules. Do not treat a timeout result as proof that input stopped. |

Detailed reports contain hashes, source lines, symbols, assembly addresses and limits:

- [FlowDeck](/Volumes/Developer/AXe/build_products/verification/vendor-failure-review-20261024/flowdeck/REPORT.md)
- [RocketSim](/Volumes/Developer/AXe/build_products/verification/vendor-failure-review-20261024/rocketsim/REPORT.md)
- [sim-use](/Volumes/Developer/AXe/build_products/verification/vendor-failure-review-20261024/sim-use/REPORT.md)

## The two current AXe issues

### 1. Closing a command must stop its input

AXe's reproduced defect is a missing client-lifetime scope on generic selected input. Other selected paths already use that scope. The isolated candidate applies the existing peer watcher to this remaining path.

The last complete run passed seven of eight cases. In the eighth, both original pinch contacts released, the owner returned ready and old input stopped. A later fresh action failed before input when its accessibility connection closed. Thus the remaining failed case contains a separate read failure; it does not show that the pinch contacts remained down.

Follow-up: the named `movingPinchInterrupt` case passed on the same candidate and warm Duo. It confirmed both original contacts ended, old input stopped, fresh discovery, exact typing and a real button callback. All eight input/signal combinations now have passing results across controlled runs. The two-file client-lifetime fix was integrated with byte-exact CLI5 postimages. The earlier whole-run failure remains saved; the full automated suite remains required. See the [scoped proof](/Volumes/Developer/AXe/build_products/verification/duo-complete-20261024/client-exit-integration-plan-v1/scoped-proof.json).

### 2. A failed accessibility activation can prevent the next read

The saved receipt records `DTXProxyChannel`, code 1, before input. It has zero enqueued events and no completed acquisition attempts. The failure occurs in the standard-read phase, which includes the released IDB activation step. The receipt does not identify a cause inside Apple's process.

RocketSim's conditional path suggests a narrow experiment: first identify an error caught directly from the activation call, then try one read through the existing CoreSimulator bridge before any input. The saved broad phase alone does not establish that exact substage. Require the expected app PID and unchanged boot, selected display, hinge and rotation context. A valid result must contain the actual controls. An empty root is not recovery.

This is not the previous unconditional removal experiment. That candidate failed all eight discovery cases with empty roots. Keep that failed evidence and retain the working reader. A conditional read is not yet a production fix. Do not add a new setup command, longer timeout, automatic service restart or repeated input from this research.

## Framework differences matter

AXe's released IDB pin is `604c51013438f0c3603b720a05a44b7c5b8f286d`. Its validator propagates activation failures. Its loader creates a short-lived remote session, loads accessibility and invalidates the session. It coalesces concurrent attempts but does not retain a completed success in that map.

sim-use pins `1f6943f8a2cc1ce449f031241818032adaea2079`. The reviewed validator checks device state, request support and framework loading, then uses the direct AX dispatcher. These Git histories have diverged. This is not evidence that upstream simply removed AXe's activation, or that replacing the dependency will fix this guest. Neither reviewed public version has RocketSim's exact conditional path.

HID remains the input transport in the traced simulator paths. These findings do not show that AXe needs an XCUITest test runner or an injected test app.

## What AXe should retain

- Release each owned touch and key, then wait for cleanup. A disconnected socket or successful command exit is insufficient.
- Never repeat input whose delivered effect is unknown. A new connection belongs to a new command.
- Check boot and session identity before cache reuse. Match invalidation to the session generation so an old callback cannot close a new session.
- Stop input when the selected display, hinge or rotation changes. Obtain a new tree before the next action. The vendor review did not prove stronger guarantees for a running gesture.
- Verify the real app state. A send acknowledgement or screenshot does not prove a control received input.

## Public evidence and limits

[RocketSim's CLI guide](https://www.rocketsim.app/docs/features/agentic-development/rocketsim-cli/) describes one device-service cache refresh and clear errors when accessibility is unavailable. This is not a promise to recover the specific DTX error or to release held input.

The [RocketSim changelog](https://www.rocketsim.app/changelog/) lists 16.7.1 as released and 16.8.0 as upcoming. The upcoming version fixes input routing on the open Duo screen. The installed 16.7.0 was not updated or used as proof of complete Duo support.

[FlowDeck's release notes](https://flowdeck.studio/changelog/iphone-duo-support-and-better-conversation-controls) claim improved recovery from delayed input. They do not define safe replay or held-input release. The installed 1.33.0 version was checked directly; the public notes cited here describe 1.32.0.

No vendor implementation was copied. This review does not close any pending live test, establish a performance ranking, or identify the root cause of Apple's intermittent connection closure.
