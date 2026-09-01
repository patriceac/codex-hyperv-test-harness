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

- One thin, continuous fuchsia frame with a soft inward glow appears around every attached display for six seconds of unpaused countdown before the application launches. Its frame bands do not overlap, so the corners cannot accumulate into solid blocks.
- Before creating either visual guard, the dedicated UI thread must enter Windows `PerMonitorV2` mode. DWM bounds, monitor bounds, and overlay placement therefore share physical-pixel coordinates at scaled settings such as 125%; failure to establish that mode stops the host run.
- After the verified application window appears, a cooler-violet rounded outline identifies the controlled target. Its crisp two-pixel core and restrained inward fade stay inside the visible window bounds. The three visual bands are repositioned in one atomic batch, and their regions are rebuilt only for a real size or corner-shape change; a fast-moving window therefore cannot leave independently positioned band frames behind. The outline remains click-through and non-activating. It hides whenever another application owns the foreground, so it never stays painted over an unrelated foreground window. Maximized or edge-to-edge windows use square inner corners so the outline remains visible without spilling off-screen.
- During the first three seconds of the initial warning countdown, ordinary mouse and keyboard activity is ignored for pause purposes and cannot turn the halo amber. Physical `Escape` still cancels immediately.
- During the final three seconds, physical mouse movement, mouse buttons, wheel input, or keyboard input pauses the countdown immediately and turns the screen halo amber. The remaining warning time is preserved. The same input pauses the action sequence after launch. Controller-generated input is marked and ignored by the physical-input detector.
- After ten uninterrupted seconds without physical input, a warning-phase pause returns to the remaining fuchsia countdown. After launch, the controller instead brings the tracked application back to the foreground, verifies that focus belongs to its process tree, restores the active visual intensity, and continues. The controlled-window outline keeps its violet identity color at reduced intensity while paused only when the controlled application still owns the foreground.
- Physical `Escape` cancels and is swallowed so it is not also delivered to the application.
- Both visual guards use non-activating, click-through windows and request Windows capture protection. The runner keeps its own evidence clean by copying only the controlled app bounds; when full exclusion is unavailable, it briefly suppresses only the visual-guard windows for that copy. The JSON records both the capture method and whether OS-level protection was available.
- A per-interactive-session lease fails closed before any halo appears if another physical-host controller is already active. The halo disappears and the lease is released on completion, cancellation, or failure. The application process tree is closed unless `-LeaveRunning` was explicitly selected for the requested workflow.

Synthetic input is global to the interactive session even though the runner verifies the intended foreground process immediately before injection. Stop and report a focus-restoration failure; never type or click into an unverified foreground window. Host execution exposes the application to the real user profile, files, registry, credentials, devices, network, and persistence mechanisms. Use it for trusted software or a genuinely host-only test, not merely for convenience.

The JSON result records the six-second warning, its three-second ignored and three-second pause-eligible phases, the ten-second idle-resume policy, foreground-only controlled-window visibility, continuous frame geometry, monitor count, OS capture-protection state, user-pause count, focus-restoration count, total paused time, action log (including screenshot capture method), assertion, and process cleanup under `%LOCALAPPDATA%\Codex\HostControl\Results` unless `-ResultsRoot` was selected.
