# Explicit physical-host control

Use this mode only after the user explicitly asks to run or control the named artifact on the physical host. The ordinary and subsequent default remains Hyper-V. Do not translate generic wording such as "run it" into a host override, and never fall back to this path after a broker or VM failure.

The controller is an on-demand process in the current interactive user session; it is not a SYSTEM service and installs no persistent host agent. It cannot operate session 0, the Windows lock screen, or the UAC secure desktop. It may also be unable to drive an application running at a higher integrity level.

## Run

Use the same action shapes documented in the main skill:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HostExecutableTest.ps1" `
  -ArtifactPath 'D:\build\trusted-host-app' `
  -ExecutableRelativePath 'TrustedHostApp.exe' `
  -ActionsPath 'D:\build\host-actions.json' `
  -HostExecutionAuthorized
```

`-HostExecutionAuthorized` is an internal fail-closed signal, not wording the user must provide. Pass it only when the current request explicitly authorizes physical-host execution for this artifact and test. `-ValidateOnly` validates paths, tokens, actions, and the fixed interaction policy without displaying the halo or launching the artifact. It still compiles and loads `HostControlNative.cs`, and reports the engine, .NET runtime, and reference mode in `NativeBootstrap`; this keeps the real native bootstrap covered under both current PowerShell 7/.NET and Windows PowerShell 5.1.

The host runner accepts `wait_window`, `focus_window`, `click_control`, `click_relative`, `type_text`, `wait`, `wait_result_file`, `wait_process_exit`, and `screenshot`. `{PAYLOAD}` resolves to the artifact directory and `{OUTDIR}` to the request result directory. `wait_result_file` and `AssertResultFile` remain confined below `{OUTDIR}`. Host mode has no VM payload, read-only-host-input transport, network profile, worker lease, or OS rollback.

## User-visible control lease

- One thin, continuous fuchsia frame with a soft inward glow appears around every attached display for five seconds before the application launches. Its frame bands do not overlap, so the corners cannot accumulate into solid blocks.
- During that initial five-second grace period, ordinary mouse and keyboard activity does not pause the countdown or turn the halo amber. Physical `Escape` still cancels immediately.
- After the grace period expires, physical mouse movement, mouse buttons, wheel input, or keyboard input pauses the action sequence immediately. Controller-generated input is marked and ignored by the physical-input detector.
- The halo turns amber while paused. After ten uninterrupted seconds without physical input, the controller brings the tracked application back to the foreground, verifies that focus belongs to its process tree, turns the halo fuchsia, and continues.
- Physical `Escape` cancels and is swallowed so it is not also delivered to the application.
- The halo uses non-activating, click-through windows and requests Windows capture protection. The runner keeps its own evidence clean by copying only the controlled app bounds; when full exclusion is unavailable, it briefly suppresses only the halo windows for that copy. The JSON records both the capture method and whether OS-level protection was available.
- The halo disappears on completion, cancellation, or failure. The application process tree is closed unless `-LeaveRunning` was explicitly selected for the requested workflow.

Synthetic input is global to the interactive session even though the runner verifies the intended foreground process immediately before injection. Stop and report a focus-restoration failure; never type or click into an unverified foreground window. Host execution exposes the application to the real user profile, files, registry, credentials, devices, network, and persistence mechanisms. Use it for trusted software or a genuinely host-only test, not merely for convenience.

The JSON result records the five/ten-second policy, grace-versus-post-grace input behavior, continuous frame geometry, monitor count, OS capture-protection state, user-pause count, focus-restoration count, total paused time, action log (including screenshot capture method), assertion, and process cleanup under `%LOCALAPPDATA%\Codex\HostControl\Results` unless `-ResultsRoot` was selected.
