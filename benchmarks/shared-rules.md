Use only the assigned CLI for UI automation on the selected warm simulator.
Use its public compact agent mode. Use a broader public view when needed to read
facts. Choose the workflow yourself; no tool-call sequence is required.

One Bash call must contain one CLI invocation. Do not use pipes, joined commands,
sleep, loops, substitutions or background jobs. Native public batch commands are
allowed. Use returned UI state to verify effects, not a command success message.

Do not read or change app source, storage, databases or preferences. Do not use
another UI tool, MCP server, AppleScript or desktop input. Do not create, boot,
erase or delete a simulator. Do not install packages or run parallel jobs.

Build, install and launch Weather during the measured task with the supplied
commands. Launch Contacts or Reminders during the measured task. Preparation
outside the task only removes an exact previous benchmark record through normal
UI and terminates the app; it does not complete any task requirement.

Follow all instructions in the original task, including its read-only final
verification. Observe every required value in the app. Never substitute an
assistant claim for a returned UI fact.

If an image is needed, use the assigned tool's screenshot command and Read the
image path it returns. If its public screenshot command writes PNG to stdout,
redirect that output once to a new PNG file inside the run directory and Read it.
Do not copy, convert or move images. You may Read returned
public tool-output overflow files. You may Write a public batch input file in
the run directory. Do not read or write unrelated files.
