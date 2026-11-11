# Manual review

Every one of the 27 transcripts went through [`review/audit.py`](review/audit.py). Every run the grader did not pass was then read call by call, together with the screenshots the agent saw. Run IDs match `results.json`.

## Findings across all runs

- No run read app source, app storage, preferences or databases.
- No run used another automation tool, or ran a shell command outside its assigned tool.
- No run wrote outside its run folder.
- FlowDeck runs read FlowDeck's session files (`~/.flowdeck/automation/sessions/…`) and its temporary snapshots (`$TMPDIR/flowdeck-snapshot-*.png`). The tool writes those files and names them in its own output. The rules allow it.
- RocketSim's agent never passed `--udid`, although every agent was told to target the simulator explicitly. RocketSim then acts on the booted simulator. Only the benchmark simulator was booted, and RocketSim's replies name its ID.
- The add, delete and clear taps in Contacts runs are form editing: adding phone and email rows, clearing a field, removing an extra empty row. The grader confirms exactly one contact with the right fields in every run it passed. The one unverified run is covered below.
- Reminders: every run created one list with the three reminders. The Reminders runs below pass.

## Runs the grader did not pass

### RocketSim, Contacts, `axe-bench-contacts-rocketsim-d429ea450b23` — correct, unverified

After saving, the agent read the card with RocketSim's `nav` mode, which lists only controls. That read shows the phone (`mobile, 55 5010 4242`) and the email row (`home, mcp.contact.benchmark@example.com`), but not the contact's name or company. Without the name, the grader cannot tie those rows to this contact. The agent's final screenshot shows the saved card correctly: MCP Contact Benchmark, XcodeBuildMCP Benchmark, the phone and the email.

### FlowDeck, Weather, `axe-bench-weather-flowdeck-6e27f47590ec` — correct, unverified

- **Settings:** all seven settings are correct. The last tree the agent read was taken before it tapped Reduce transparency; it then checked with a screenshot, which shows the switch on.
- **Main screen:** FlowDeck's tree does not contain the precipitation or visibility cards. The screenshot shows 78% and 9.7 km.
- **Details screen:** read through FlowDeck's session tree, and passes.

### FlowDeck, Weather, `axe-bench-weather-flowdeck-fc895e1b7766` — correct, unverified

FlowDeck's tree does not contain the precipitation or visibility cards; the screenshot shows 78% and 9.7 km. Everything else passes, including the details screen, which the agent opened with a tap whose own reply contains the details tree.

### FlowDeck, Weather, `axe-bench-weather-flowdeck-25de0e165b46` — correct, unverified

- **Settings:** all seven were set in one batch, and the batch's returned tree confirms them.
- **Search:** the London result was read from the tree.
- **Main screen:** confirmed with screenshots, plus two `assert` steps that passed for "9.7 km" and "78%". The screenshot shows London, 11°, 78% and 9.7 km.
- **Details screen:** read by screenshot only. It shows 78%, 10.7 mm, 6 hrs, 14 km and None.
- **Saved location:** the agent tapped `+` on the London search result, which saved London as a location. The task forbids changes only after the details screen, so this is not a rule break. Every later Weather run, for every tool, still shows London as not saved and 7 saved locations, so nothing carried over.

## Grades the regrade changed

- FlowDeck Contacts, all three runs: unverified → passed. The saved card's email row reads `home, mcp.contact.benchmark@example.com`, and the grader had required the address alone.
- FlowDeck Weather `6e27f47590ec`: failed → unverified. Its session-file reads now count as evidence. Reduce transparency was tapped after its last read, so it is unverified rather than failed.
- RocketSim Weather `f3bd041c8adc`: unverified → passed. RocketSim's `interact focus`, inside a `do` batch, is now understood, so the typed "London" is recorded.
- RocketSim Reminders `ff11b0fcac3c`: unverified → passed. Its final read was an `elements` call inside `do`, which returns RocketSim's compact text form.
- No AXe run changed. All nine passed before and after.
