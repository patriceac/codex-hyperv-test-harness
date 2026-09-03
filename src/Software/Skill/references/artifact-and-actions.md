# Artifact invocation and actions

Read this reference when a VM test needs arguments, interaction, application-produced assertions, screenshots beyond the default smoke capture, or locked-host proof.

## Artifact and result contract

`ArtifactPath` remains the canonical payload location and stable cache identity. Do not pre-copy a package into broker staging. For a multi-file package, use `-ExecutableRelativePath` to identify the executable below the payload root.

In `-Arguments` and ordinary string-valued action fields:

- `{PAYLOAD}` resolves to the attached application payload root.
- `{OUTDIR}` resolves to the persistent guest evidence directory.
- `{HOSTINPUT:name}` resolves a declared auxiliary input; read [network and host inputs](network-and-host-inputs.md) before using it.

Reserved tokens are uppercase and validated before queueing. Unknown or lowercase token spellings are rejected. Tokens are not allowed in structural fields such as an action `type` or screenshot evidence `name`.

Use `-AssertResultFile` to require an application-produced result below `{OUTDIR}\`. It does not accept `{PAYLOAD}`. To evaluate JSON content, add `-AssertResultJsonPointer '/passed' -AssertResultEqualsJson 'true'`. The pointer follows RFC 6901 and the expected value is typed JSON, not a string expression.

Use `-RequireHostLocked` only when the test specifically needs proof that the physical workstation stayed locked. Ordinary VM runs remain isolated without touching the host desktop whether it is locked or unlocked.

## Actions schema

An actions file is a JSON array. Supported shapes are:

```json
[
  { "type": "wait_window", "timeoutMs": 30000 },
  { "type": "focus_window" },
  { "type": "click_control", "automationId": "saveButton", "name": "Save", "timeoutMs": 10000 },
  { "type": "click_relative", "x": 320, "y": 180 },
  { "type": "type_text", "text": "{PAYLOAD}\\fixture-project" },
  { "type": "send_keys", "keys": "WIN+LEFT", "holdMs": 75 },
  { "type": "wait", "ms": 1000 },
  { "type": "wait_result_file", "path": "{OUTDIR}\\result.json", "timeoutMs": 300000 },
  { "type": "wait_process_exit", "timeoutMs": 300000, "expectedExitCode": 0 },
  { "type": "screenshot", "name": "result.png", "timeoutMs": 30000, "attempts": 5 }
]
```

`wait_result_file` is the preferred completion signal for Electron apps, installers, and launchers whose initial process may hand work to child processes. A matching JSON assertion is evaluated as soon as the file appears. A false assertion skips remaining waits and input actions; later requested screenshots still run as diagnostic finalizers. Use `wait_process_exit` when the directly launched process lifetime and exit code are authoritative.

Prefer stable UI Automation IDs with `click_control`; `name` is also supported. Provider runtime IDs may differ from source-code control names, especially in WinForms and Electron. When lookup fails, use the guest error's element inventory to choose the actual runtime name/ID, or a verified relative coordinate when no stable selector exists. Capture screenshots before and after consequential interactions.

Use `send_keys` for one named key or chord after focusing the application. `keys` is an uppercase `+`-separated value such as `ENTER`, `ALT+F4`, `CTRL+SHIFT+S`, or `WIN+LEFT`; modifiers precede exactly one non-modifier. The allowlist covers `CTRL`, `ALT`, `SHIFT`, `WIN`, arrows, common navigation/editing keys, `F1`-`F12`, letters, and digits. Duplicate keys, arbitrary virtual-key numbers, scan codes, text, scripts, extra fields, and multiple non-modifier keys are rejected before queueing and again by broker and guest. `holdMs` defaults to 50 and is bounded from 10 through 2000. Evidence records canonical key names, allowlisted virtual-key codes, hold duration, and target window handle.

The runner validates action structure before queueing and rejects evidence paths that escape the request output directory. Screenshot capture first proves the interactive desktop, Explorer, DWM, and display geometry are ready, then uses fresh out-of-process helpers with bounded exponential retries. Persistent invalid-handle failure is harness infrastructure: the broker replays an ordinary request at most once on another clean worker while recycling the failed worker. Results record retry count and worker history.

For an application expected to power off its guest, use the separate [expected guest power-off](expected-guest-power-off.md) contract. Do not infer it from an ordinary process exit.
