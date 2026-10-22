# Clipboard staging

Use `axe clipboard copy --stdin --udid <UUID>` to stage exact UTF-8 bytes in one booted simulator's general clipboard. It does not insert text. This standalone public CoreDevice route has no agent, selected-screen or batch options. Existing `type` keeps its US HID keyboard mapping.

Supply 1...65536 bytes, then close stdin. AXe preserves line endings and combining characters; it does not trim or normalize. Empty, oversized or invalid UTF-8 input rejects before a copy. Only an exact existing Booted simulator UUID is accepted. Names, `booted` and `all` aliases reject. No implicit boot occurs.

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UUID>
```

AXe sends one public `devicectl device pasteboard copy` with the bytes on stdin, then one `paste` readback and compares bytes in memory. Both use the public eight-second tool timeout and a 30-second owned-child bound. No request is retried and no other transport is used. Child streams stay bounded and private. Stdin waits for EOF without a deadline, but observes signal/task cancellation. SIGINT/SIGTERM cancel and await the owned operation; a running child is stopped and reaped. Parent termination and SIGKILL cleanup are not guaranteed.

Success prints JSON with `source: "appleCoreDevicePasteboard"`, `operation: "copy"`, `outcome: "stagedAndVerified"`, `simulatorUDID`, `utf8Length`, `sha256`, `verified: true`, `inserted: false`, `clipboardReplaced: true` and `sharedClipboardMayChange: true`. No payload or clipboard content is printed. A successful receipt proves the readback at that time; another app/device can change it afterward. Before/after Booted-state checks do not prove an unchanged boot identity.

Copy replaces a potentially shared Mac/device clipboard. AXe does not read old content for backup or restore it. Failure after a copy can leave the clipboard changed. Preserve the failure and inspect state before another write; never replay automatically. Raw child output and arbitrary error content are suppressed.

For actual app insertion, focus and inspect the field, then use separate current UI actions. Get a fresh capture after clipboard changes. One controlled v6 fixture composition proved key101, a new explicit Paste Button ref and one guarded tap with exact destination bytes and one edit callback. It does not establish a general menu classifier, automatic Paste command or another app's behavior. Cmd+V delivery did not insert the recorded sample; do not use it as a fallback. Verify destination text and app callbacks separately. No new clipboard product command has native acceptance until it is built and run.
