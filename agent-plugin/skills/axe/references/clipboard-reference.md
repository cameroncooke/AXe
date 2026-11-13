# Clipboard staging

```bash
printf '%s' 'AXe sample' | axe clipboard copy --stdin --udid <UUID>
```

- Stages exact UTF-8 bytes in one booted simulator's general clipboard; does not insert text.
- Standalone public CoreDevice route: no agent, selected-screen or batch options. `type` sends key presses instead; see its `--layout`.
- Supply 1...65536 bytes, then close stdin. Empty, oversized or invalid UTF-8 input rejects before a copy. Line endings and combining characters are kept; no trimming or normalizing.
- `--udid` must be an exact existing Booted simulator UUID; names and the `booted` and `all` aliases reject. No implicit boot.

## How it copies

- One public `devicectl device pasteboard copy` with the bytes on stdin, then one `paste` readback compared byte for byte in memory.
- Both use the public 8-second tool timeout and a 30-second owned-child bound. No retry, no other transport.
- Child streams stay bounded and private; raw child output and arbitrary error content are suppressed.
- Stdin waits for EOF with no deadline but observes signal/task cancellation. SIGINT/SIGTERM cancel and await the owned operation; the source stops and reaps a running child. Parent termination and SIGKILL cleanup are not guaranteed.

## Output and failures

- Success prints `Copied N bytes to the clipboard of <udid> (sha256 …)`; `axe --output json` returns `{udid, bytes, sha256}`. No payload or clipboard content is printed.
- A copy that may have changed the clipboard without a matching readback fails with `actionOutcomeUnknown`.
- Success proves the readback at that time; another app or device can change it afterward. Before/after Booted-state checks do not prove an unchanged boot identity.
- The copy replaces a potentially shared Mac/device clipboard and stays replaced: AXe neither backs up nor restores old content.
- Failure after a copy can leave the clipboard changed. Preserve the failure and inspect state before another write; never replay automatically.

## Inserting into an app

- Focus and inspect the field, then use separate current UI actions. Take a fresh capture after clipboard changes.
- No general menu classifier or automatic Paste command. Do not use Cmd+V as a fallback.
- Verify destination text and app callbacks separately.
