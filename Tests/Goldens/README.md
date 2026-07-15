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

The checked-in cells record configurations on which AXe compatibility was validated. Their exact Xcode and runtime build identifiers are provenance, not build or release requirements. Add a new matrix directory when validating another supported configuration; do not replace an existing cell to broaden the claimed support range.
