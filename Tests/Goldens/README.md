# Compatibility Goldens

Each child directory is one explicit Xcode/runtime matrix cell. The directory name must identify the selected Xcode and simulator runtime builds, for example `xcode-26.5-17F42_ios-26.5-23F77`.

Regenerate a cell with the exact release-shaped payload and a booted simulator containing AxePlayground:

```bash
scripts/regenerate-goldens.sh \
  --axe /absolute/path/to/axe \
  --developer-dir /Applications/Xcode-26.5.0.app/Contents/Developer \
  --udid SIMULATOR_UDID \
  --matrix-id xcode-26.5-17F42_ios-26.5-23F77 \
  --update
```

Use `--check` with the same arguments to regenerate into a temporary directory and compare it with the checked-in cell.

Each cell has three parts:

- `contract.json` records stable matrix identity: schema version, Xcode version/build, runtime build, and fixture.
- `stable/` records argv, stdout, stderr, stdin where applicable, and exit status. It covers help and unknown-option behavior for every public subcommand, plus command-specific typed validation, stdin, and output-path contracts. Hierarchy values are intentionally excluded because labels, frames, and identifiers can be fixture- or host-specific; `stable/hierarchy/schema-types.json` records normalized JSON paths and types.
- `provenance.json` records volatile run identity: exact AXe payload SHA-256, simulator UDID/device name, and the SHA-256 of the stable contract. `--check` validates the newly generated provenance but compares only `contract.json` and `stable/`, so a different simulator or byte-identical rebuilt payload does not create golden churn.

The local release matrix script must write `AXE_MATRIX_EVIDENCE_PATH` using schema version 1. The release gate accepts exactly the required Xcode 26.5/iOS 26.5 and Xcode 27 Beta 3/iOS 27 cells, binds them to `AXE_PAYLOAD_SHA256`, and verifies retained patch hashes against the repository:

```json
{
  "schema_version": 1,
  "result": "pass",
  "source": {"axe_commit": "40-character commit SHA"},
  "payload": {"sha256": "64-character payload SHA-256"},
  "archives": {"universal_sha256": "64-character archive SHA-256"},
  "idb": {
    "sha": "40-character pinned IDB SHA",
    "retained_patches": [
      {"path": "patches/idb/e682506/example.patch", "sha256": "64-character patch SHA-256"}
    ]
  },
  "cells": [
    {
      "xcode": {"version": "26.5", "build": "17F42"},
      "runtime": {"platform": "iOS", "version": "26.5", "build": "23F77"},
      "simulator": {"udid": "simulator UDID", "device_type": "iPhone model"},
      "commands": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"},
      "media": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"},
      "goldens": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"}
    },
    {
      "xcode": {"version": "27.0 Beta 3", "build": "27A5218g"},
      "runtime": {"platform": "iOS", "version": "27.0", "build": "24A5380g"},
      "simulator": {"udid": "simulator UDID", "device_type": "iPhone model"},
      "commands": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"},
      "media": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"},
      "goldens": {"result": "pass", "artifact_sha256": "64-character evidence SHA-256"}
    }
  ]
}
```
