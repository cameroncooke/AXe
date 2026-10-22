# Ordinary touch checkpoint: 22 October 2026

Isolated recovery checkpoint only. No main integration or push.

The matched arm64 native frameworks and CLI built. The existing selected-input filter passed 173 checks in 19 suites. Exact commands and resource records: /Volumes/Developer/AXe/build_products/verification/touch-owned-parts-20261022/build-and-fixture-progress.json. Candidate CLI SHA256: ccb813f1decb62f97254a7227d4dc9706ee5291ca105f642b05b72145f676be7.

Manual simulator proof used the rebuilt normal UIKit fixture, SHA256 81c140600868d473af21ba8e02bcf8bde8cf0876827a2142d62e24064cc9c6d0, on owned ordinary iPhone 098FE01B-F022-4F1F-A00A-2D398BB77346 in portrait. A complete touch produced one button action. Separate down at P, down at Q and up at R produced BEGIN(P), MOVE(Q), END(R) on one contact and one completed pan. Both cases ended with zero held contacts. No extra MOVE at R was sent. Exact commands and app traces are in ordinary-iphone/proof-v2/verification.json under the evidence root. ordinary-iphone/guard-v2/result.json records exit 0, no new crash and peaks of 7.443/6.730/0.155 GiB for app/simulator/command memory. Owned broker cleanup and simulator shutdown passed.

Duo input remains unaccepted. The old runtime missed ordinary inner-landscape touch; its selected comparison was refused as busy. A reordered baseline stopped during rotation on a new owned-guest PosterBoard crash, before candidate touch. The guest remains off. No speculative simulator repair or uncertain-input replay was applied.

Remaining verification: Duo complete/separate touch, default/zero/long delay, fold/rotation during held and idle touch, explicit-token separation, orphan UP, 60-second idle release, client loss/signals, direct native unmatched touch/key/button UP and balanced key/button streams. Batch is unchanged. Security scan remains UNVERIFIED by Cam instruction.
