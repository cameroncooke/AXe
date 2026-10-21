# Public Duo pinch matrix

18 October 2026. Isolated wire8 CLI and matching libraries only. Production source is unchanged. Each direction uses one fresh reference, a manual selected-image review, fresh selected AX lookup, one gesture, real app contact/recognizer readback, and an awaited broker exit.

| Active screen | Measured UI rotation | Pinch in | Pinch out | Evidence |
|---|---:|---|---|---|
| Inner3, open180 | 0 | Passed | Passed | [V1 archive](evidence/2026-10-18-duo-public-pinch-inner0-v1/README.md) |
| Inner3, open180 | 90 | Passed | Passed | [V2 archive](evidence/2026-10-18-duo-public-pinch-inner-rotations-v2/README.md) |
| Inner3, open180 | 180 | Passed | Passed | [V2 archive](evidence/2026-10-18-duo-public-pinch-inner-rotations-v2/README.md) |
| Inner3, open180 | 270 | Passed | Passed | [V2 archive](evidence/2026-10-18-duo-public-pinch-inner-rotations-v2/README.md) |
| Outer1, closed0 | 0 | Passed | Passed | [V2 outer archive](evidence/2026-10-18-duo-public-pinch-outer-rotations-v2/README.md) |
| Outer1, closed0 | 90 | Passed | Passed | [V2 outer archive](evidence/2026-10-18-duo-public-pinch-outer-rotations-v2/README.md) |
| Outer1, closed0 | 180 | Setup blocked | Not run | Device Hub command left measured UI90 |
| Outer1, closed0 | 270 | Passed | Passed | [V2 outer archive](evidence/2026-10-18-duo-public-pinch-outer-rotations-v2/README.md) |

V2 inner90 commands: `python3 -B /private/tmp/axe-duo-public-pinch-matrix-v2-20261018/run-public-pinch-v2.py --contract /private/tmp/axe-duo-public-pinch-matrix-v2-20261018/main-inner90-in-enabled-v1.json --out /private/tmp/axe-duo-public-pinch-matrix-v2-20261018/main-inner90-in-v1-1`; session48904, terminal26e039, exit0. The separate out case uses main-inner90-out-enabled-v1.json and main-inner90-out-v1-1; session8717, terminal747ff6, exit0.

Both directions passed contact delivery and the real pinch recognizer at0.6s and5s. This does not prove exact scale, timing, every event sample, other gesture routes, transition races, another boot/profile, or general UI support. The V1 inner0 cases remain distinct from V2 pose-admission evidence.

Four rejection cases passed at inner0: wrong ID/UUID pair, inactive outer pair, later second-contact endpoint outside the screen, and scale1. All sent zero input; [evidence](evidence/2026-10-18-duo-public-pinch-negatives-v1/README.md).

V2 inner180: in session37252/terminal05660b, out session48212/terminal8c904b, both exit0. V2 inner270: in session50330/terminalcf6937, out session24973/terminal433a19, both exit0. Each uses the same command above with its exact pose/direction in the contract and output names. Main saved all six collector/action terminal records in main-tool-terminal-records-inner-v1.json under the V2 proof root.

Main verified all804 inner-rotation archive payloads. Folding from inner UI0 activated outer1 with measured UI270. The initial outer0 collector stopped before input (session24133/terminalade516, exit2; five read/setup children0/reaped). This is a setup mismatch, not a failed outer0 gesture. A new reference admitted actual outer270; pinch-in passed session55259/terminalf073e1, exit0. The out case is separate.

Outer270 pinch-out passed separately: session96835/terminal2d2648, exit0. After one Device Hub rotation, a new collector measured outer0. Pinch-in passed session6116/terminal4921bb and pinch-out passed session12620/terminalee86c8, both exit0. Each used its own fresh reference and selected-image review. The outer0 in case uses version2 paths because the earlier version1 setup mismatch is retained. Outer90 then passed: in session46200/terminal1de8a4, out session86275/terminal0cbe49, both exit0.

The next Device Hub Rotate Right command changed the visible device pose but did not produce measured UI180. Its collector stopped before input: session79432/terminal70a5b0, exit2; measured outer UI90. Both the saved active-display report and guest CAD read agree. A later menu Rotate Right command produced measured UI270 (separate read terminal0c1dbf, exit0). The cause and a valid way to obtain outer UI180 remain open. The fixture declares all four supported interface orientations; that declaration does not establish runtime acceptance.

Main independently verified all857 outer archive payloads. The six outer actions contain66 clean command exits and six clean broker exits. The two setup stops contain ten clean read/setup exits and no input. Together with the separate inner evidence,14 positive public pinch cases passed at seven measured poses; the eighth pose remains open.
