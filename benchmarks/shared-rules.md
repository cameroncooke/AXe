Use only the assigned CLI for UI automation on the selected warm simulator.
Use its public compact agent mode. Use a broader public view when needed to read
facts. Choose the workflow yourself; no tool-call sequence is required.

One Bash call must contain one CLI invocation. Do not use pipes, joined commands,
sleep, loops, substitutions or background jobs. Native public batch commands are
allowed. Use returned UI state to verify effects, not a command success message.

Do not read or change app source, storage, databases or preferences. Do not use
another UI tool, MCP server, AppleScript or desktop input. Do not create, boot,
erase or delete a simulator. Do not install packages or run parallel jobs.

The harness builds, installs and launches the app before the measured task
starts; the task measures UI interaction only. Do not build, install, launch or
terminate apps. Preparation outside the task only removes an exact previous
benchmark record through normal UI; it does not complete any task requirement.

Follow all instructions in the original task, including its read-only final
verification. Observe every required value in the app. Never substitute an
assistant claim for a returned UI fact.

If an image is needed, use the assigned tool's screenshot command and Read the
image path it returns. If a public read or screenshot command writes to stdout,
you may redirect that output once to a new file inside the run directory (PNG
for images, JSON or text for UI reads) and Read it. Do not copy, convert or move
images. You may Read files the assigned tool writes and names in its output,
such as screenshots, snapshots or session files, and returned tool-output
overflow files. You may Write a public batch input file in the run directory.
Do not read or write unrelated files.
