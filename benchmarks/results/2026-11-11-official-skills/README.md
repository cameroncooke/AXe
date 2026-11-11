# Agent UI benchmark: AXe, RocketSim and FlowDeck (11 November 2026)

An AI agent (Claude Code with `claude-sonnet-5-5`) completed three UI tasks in three iOS apps on a simulator, three times each with each tool. Each tool ran with its own official agent skill, unedited, and the measured task covered UI interaction only.

AXe was the fastest on every app and used the fewest calls on every app. It returned the least text on Weather and Contacts and the same as RocketSim on Reminders. It passed 9 of 9 runs. All 27 runs completed their task correctly; where the automatic grader could not confirm a fact from the tool's output, the cause is given under [Grades](#grades).

## Results

Averages of 3 runs. The percentage is how much more (or less) a tool used than AXe.

| Task | Measure | AXe | RocketSim 16.8.0 | FlowDeck 1.34.0 |
| --- | --- | --- | --- | --- |
| Weather | Time | 65 s | 100 s (+54%) | 129 s (+99%) |
| | Calls | 14.3 | 21.3 (+49%) | 34.7 (+142%) |
| | Returned text | 7.4k tokens | 14.0k (+88%) | 31.7k (+326%) |
| Contacts | Time | 65 s | 158 s (+144%) | 181 s (+179%) |
| | Calls | 10.0 | 30.0 (+200%) | 48.7 (+387%) |
| | Returned text | 8.8k tokens | 14.4k (+64%) | 22.3k (+155%) |
| Reminders | Time | 65 s | 97 s (+49%) | 87 s (+34%) |
| | Calls | 17.0 | 17.3 (+2%) | 24.0 (+41%) |
| | Returned text | 10.6k tokens | 10.5k (−1%) | 21.4k (+101%) |

Ranges, images and per-run figures are in [`results.json`](results.json). Images were not counted as tokens. FlowDeck read 6.7 images per run on Weather and 10.0 on Contacts, RocketSim 4.0 on Contacts, and AXe none.

## Grades

| Tool | Grader | Manual review of every transcript |
| --- | --- | --- |
| AXe | 9 of 9 passed | All 9 correct; no screenshots used |
| RocketSim | 8 of 9 passed, 1 unverified | All 9 correct |
| FlowDeck | 6 of 9 passed, 3 unverified | All 9 correct |

"Unverified" means the result on screen was right but the tool's text output never showed it; the agent confirmed it from a screenshot or an `assert` step. The grader accepts only facts it can read in the tool's returned UI state, the same rule for every tool. No run failed.

- **RocketSim, one Contacts run:** the agent confirmed the saved name and company only in a screenshot.
- **FlowDeck, all three Weather runs:** FlowDeck's accessibility tree never contains the Weather app's visibility card, and in two runs not the precipitation card either. AXe's and RocketSim's trees show both cards in every run.

Details of each run are in [`manual-review.md`](manual-review.md).

## Disclosures

- **FlowDeck's official skill contains the Weather task.** Its `resources/ui.md`, and the CLI's `batch --examples`, include a worked example that matches this benchmark's Weather task, with its control names and expected answers ("11°", "78%", "10.7 mm", "Lightning"). It was used unedited, as every skill was, so FlowDeck's Weather result is not a blind test.
- **Grader fixes.** The grader was corrected after the run, while the transcripts were being audited, so that it reads FlowDeck's and RocketSim's documented output correctly; the full list is under [Method](#method). Every fix applies to all three tools and has a test. All runs were regraded from their saved evidence, with no UI replayed. No AXe grade changed. Both the grade as run and the regraded grade are in `results.json`.
- **The benchmark is AXe's.** It lives in the AXe repository. It uses the original tasks and model runner, and AXe's maintainers wrote the grader.

## Method

- **Tasks:** [`../../tasks/`](../../tasks/), with the rules every agent receives in [`../../shared-rules.md`](../../shared-rules.md). Each app (Weather, Contacts, Reminders) is a fixed task with exact expected values. Each task ends with a read-only verification.
- **Skills:**
  - AXe: the skill `axe init` installs (`Skills/CLI/axe`).
  - FlowDeck: the pack `flowdeck ai install-skill --agent claude` installs for version 1.34.0.
  - RocketSim: the skill bundled in RocketSim 16.8.0 (`RocketSim.app/Contents/Resources/Agent-Skill/rocketsim`).

  Each report records the SHA-256 of the skill tree the agent received.
- **Instructions:** identical for every tool apart from the tool's name and path. The benchmark measures UI interaction only, the app is already running, run the assigned binary where the skill writes the tool's name, and target the benchmark simulator.
- **Setup outside the clock:** the harness builds and installs Weather and launches each app before the agent starts. It also removes the previous run's Contacts or Reminders record through the app's own UI. Before each Reminders job it resets Reminders' first-opened date: on this simulator runtime, Reminders otherwise breaks its own list refresh about seven days after first launch, for every tool (see `docs/release-readiness.md`, Phase 13).
- **Order:** the runs alternate by repeat: AXe, FlowDeck and RocketSim on Weather, then Reminders, then Contacts, three times over.
- **Grading:** a fact counts only when the tool's returned UI state shows it. A screenshot or the agent's own claim does not count. Procedure rules are checked too: no input after verification, one contact or list created, only the assigned tool used.
- **Grader fixes made after the run** (commit `ec2ed3e22`, tests in [`../../test_fair_grading.py`](../../test_fair_grading.py)):
  - FlowDeck's session files hold the tree as a bare list, and the grader dates that evidence to the read.
  - FlowDeck's `screen --output` receipt names the screenshot it wrote.
  - RocketSim's nav rows carry labels but no values, so they count as showing no value rather than an empty one.
  - RocketSim's text snapshots inside a `do` batch count as evidence.
  - A saved email row may carry its type ("home, …"), as the phone row already could.
  - A setting tapped after its last read is graded unverified, not failed.
  - The action whose own reply first shows the details screen marks the start of read-only verification.
- **Manual review:** every transcript went through [`review/audit.py`](review/audit.py), which lists commands run, files read and written, permission refusals and state-changing tool commands. Then every run that did not pass was read by hand, together with the screenshots the agent saw, extracted with [`review/extract_images.py`](review/extract_images.py).

## Environment

| | |
| --- | --- |
| Agent | Claude Code 2.1.281, model `claude-sonnet-5-5`, 900 s limit per task |
| AXe | `v1.8.0-422-g15fa2cf68`, built from a clean checkout of commit `15fa2cf68` |
| FlowDeck | 1.34.0 (build 815522), the latest release; skill SHA-256 in `results.json` |
| RocketSim | 16.8.0 (build 339), the latest release on its feed and the App Store |
| Simulator | iPhone 18 Pro, iOS 27.2 (24B5110a), 402 × 874 points |
| Xcode | 27.2 beta 3 (27B5038j) |
| Host | Mac17,7, macOS 26.6.2 (25G83), arm64 |
| Tokens | o200k_base (tiktoken 0.12.0), counting all text the tool returned; images separate |

## Reproducing

1. Check out commit `ec2ed3e22`, or any later commit that keeps the same task, rule and grader hashes (`results.json` → `contract`).
2. Run `./benchmarks/run setup`, then copy `benchmarks/config.example.json` to `benchmarks/config.local.json`. Set your Xcode path, a booted iPhone 18 Pro simulator on iOS 27.2, and the paths to FlowDeck and RocketSim, and set `allowTestRecordCleanup` to `true`.
3. Open RocketSim, then run:

   ```sh
   ./benchmarks/run run --tools axe flowdeck rocketsim --repeat 3 --rerun-competitors
   ```

4. Results land in `benchmarks/artifacts/<run>/`, one `report.json` per run, plus the full transcript and evidence. Regrade with `benchmarks/rescore.py <report.json> --output <file>`.

Model output varies between runs, so expect different figures from run to run. A different host, runtime or tool version also counts as a separate comparison.

## What is in this folder, and what is not

- **Committed here:**
  - this report;
  - [`results.json`](results.json), with every run's metrics, both grades, the checks that did not pass, the skill hash, and SHA-256 checksums of its report, regraded report and transcript;
  - [`manual-review.md`](manual-review.md);
  - [`report.html`](report.html), the source of the published results page;
  - the two review scripts.
- **Not committed:** the transcripts, screenshots, raw reports and built binaries, about 570 MB. They are kept outside the repository in `e2e-results/benchmark-final/` and match the checksums in `results.json`. FlowDeck's skill pack is not redistributed; its SHA-256 identifies the copy used.
