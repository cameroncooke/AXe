# Clipboard staging

Use `axe clipboard copy --stdin --udid <UUID>` to stage exact UTF-8 bytes in one booted simulator's general clipboard. It does not insert text. This standalone public CoreDevice route has no agent, selected-screen or batch options. Existing `type` keeps its US HID keyboard mapping.

Supply 1...65536 bytes, then close stdin. AXe preserves line endings and combining characters; it does not trim or normalize. Empty, oversized or invalid UTF-8 input rejects before a copy. Only an exact existing Booted simulator UUID is accepted. Names, `booted` and `all` aliases reject. No implicit boot occurs.

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UUID>
```

AXe sends one public `devicectl device pasteboard copy` with the bytes on stdin, then one `paste` readback and compares bytes in memory. Both use the public eight-second tool timeout and a 30-second owned-child bound. No request is retried and no other transport is used. Child streams stay bounded and private. Stdin waits for EOF without a deadline, but observes signal/task cancellation. SIGINT/SIGTERM cancel and await the owned operation; the source stops and reaps a running child. Parent termination and SIGKILL cleanup are not guaranteed.

Success prints `Copied N bytes to the clipboard of <udid> (sha256 …)`; `axe --output json` returns `{udid, bytes, sha256}`. No payload or clipboard content is printed. A copy that may have changed the clipboard without a matching readback fails with `actionOutcomeUnknown`. A successful result proves the readback at that time; another app/device can change it afterward. Before/after Booted-state checks do not prove an unchanged boot identity.

Copy replaces a potentially shared Mac/device clipboard. AXe does not read old content for backup or restore it. Failure after a copy can leave the clipboard changed. Preserve the failure and inspect state before another write; never replay automatically. Raw child output and arbitrary error content are suppressed.

For actual app insertion, focus and inspect the field, then use separate current UI actions. Get a fresh capture after clipboard changes. AXe has no general menu classifier or automatic Paste command. Do not use Cmd+V as a fallback. Verify destination text and app callbacks separately. The shared clipboard stays replaced without old-content backup.
