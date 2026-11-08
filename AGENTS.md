# Development Rules

## Code Quality
- No `Any` types unless absolutely necessary
- NEVER remove or downgrade code to fix type errors from outdated dependencies; upgrade the dependency instead
- Always ask before removing functionality or code that appears to be intentional
- Follow Swift best practices

## Commands
- NEVER commit unless user asks
- If 1Password signing fails for an authorized local commit, commit unsigned with `git -c commit.gpgsign=false commit ...`. Do not stop to ask for approval or change the stored Git signing settings.
- Skip signature verification for that unsigned commit and report that it is unsigned. All other required build, test and code checks still apply.

## GitHub
When reading issues:
- Always read all comments on the issue

## Tools
- GitHub CLI for issues/PRs
- When working on the skill sources in `Skills/CLI/axe/`, use the `skill-creator` skill workflow.

## Build and test
- `scripts/build.sh` (default, `dev`, `clean`) runs `rm -rf build_products build_derived_data`, and so does `scripts/build.sh frameworks-if-needed` (used by `make build`, `make test`, `make e2e`, `./test-runner.sh` and the benchmarks) whenever it rebuilds stale IDBKit frameworks. Never keep anything that must survive under `build_products/`.

## Performance
- An ordinary simulator interaction must be as fast as in the current release (the latest release tag). This applies to every input route, including selected and agent modes.
- An iPhone Duo interaction must be as fast as the same interaction on an ordinary simulator.
- Any slower result is a regression. Compare against the release binary, run on the same machine and simulator.

## Style
- Keep answers short and concise
- No emojis in commits, issues, PR comments, or code
- No fluff or cheerful filler text
- Technical prose only, be kind but direct (e.g., "Thanks @user" not "Thanks so much @user!")

## Docs
- If modifying or adding/removing commands/options, update README.md and the skill in `Skills/CLI/axe/`.

### Changelog
Location: `CHANGELOG.md`

#### Format
Use these sections under `## [Unreleased]`:
- `### Added` - New features
- `### Changed` - Changes to existing functionality
- `### Fixed` - Bug fixes
- `### Removed` - Removed features

#### Rules
- Before adding entries, read the full `[Unreleased]` section to see which subsections already exist
- New entries ALWAYS go under `## [Unreleased]` section
- Append to existing subsections (e.g., `### Fixed`), do not create duplicates
#### Attribution
- **Internal changes (from issues)**: `Fixed foo bar ([#123](https://github.com/cameroncooke/AXe/issues/123))`
- **External contributions**: `Added feature X ([#456](https://github.com/cameroncooke/AXe/pull/456) by [@username](https://github.com/username))`

## **CRITICAL** Tool Usage Rules **CRITICAL**
- NEVER use sed/cat to read a file or a range of a file. Always use the native read tool.
- You MUST read every file you modify in full before editing.
