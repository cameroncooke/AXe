sim-use keyboard detector adaptation

Upstream: https://github.com/lycorp-jp/sim-use
Commit: c02295edfd2f442249b869096dda3dc7bfcd308d
Source: Sources/iOSSimBackend/A11y/SoftKeyboardDetector.swift
Copyright 2026 LY Corporation
Licence: Apache License 2.0

AXe's AgentModeKeyboardObservation.swift adapts the upstream key signal sets
and thresholds. AXe reports likelyVisible or unknown, counts distinct IDs,
labels and Latin letters, excludes inherited hidden nodes, applies current
logical display bounds, and reuses the existing bounded agent snapshot.
No missing signal is reported as proof that the keyboard is hidden.

LICENSE and NOTICE in this folder reproduce the pinned upstream root files
without changes. The upstream NOTICE describes sim-use and its origin.
These files are copied into AXe's resource bundle. This attribution applies
to the adapted keyboard detector; AXe's root MIT licence is unchanged.
