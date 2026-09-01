---
name: hyperv-test-executables
description: Run and interactively test Windows application artifacts in the isolated Hyper-V test VM, including .exe files, Electron apps, installers, packaged desktop or CLI apps, keyboard, mouse, screenshot, and network-boundary tests. Use by default whenever Codex would launch an application-under-test and its behavior cannot be tested faithfully in a browser, unless the user explicitly directs physical-host execution for the named test. Do not use for browser-faithful pure web testing or for trusted host build tools that are not themselves under test.
---

# Hyper-V executable testing

Keep the application-under-test off the physical host by default. Build on the host when useful, then expose the canonical `ArtifactPath` through the SYSTEM broker's incremental VHDX cache. Never relocate or rewrite the normal project output.

## Route the test

1. Use a browser first for a pure web application when browser automation can faithfully exercise the requested behavior.
2. Honor an explicit user request to run, install, or interactively test a named artifact on the physical host. Natural wording such as "run this on the host" or "test it locally, not in Hyper-V" is sufficient; acknowledge it briefly and proceed without requiring a magic phrase or additional confirmation. Scope the override to that artifact and test only, and do not infer it from generic wording such as "run it." For scripted host UI control, read [host control](references/host-control.md) and use `scripts/Invoke-HostExecutableTest.ps1`; pass its internal authorization switch only after that explicit named override.
3. Otherwise use this skill for every application-under-test, including native shells, tray behavior, installers, WebView2, Windows integration, and proof of a VM network boundary. Treat Electron as a native desktop application; a Chromium-based shell is not the browser exception.
4. Never silently fall back to host execution. Report a broker or VM failure instead.

Trusted compilers, linkers, package managers, linters, and non-application test runners may run on the host. Outside an explicit host override, do not launch the built application, installer, CLI artifact, or packaged desktop process there.

The host controller gives a five-second thin, continuous fuchsia halo warning on every display before launch. After the verified application window appears, a separate cooler-violet outline identifies that exact controlled window with a crisp two-pixel core and restrained inward fade; it follows movement and resizing, dims while paused, and disappears when the window is unavailable. Its UI thread establishes `PerMonitorV2` before creating any overlay so scaled displays use the same physical-pixel coordinates as DWM; failure is terminal. Ordinary mouse or keyboard activity does not pause the initial grace period; after it expires, physical input pauses automation immediately. It resumes only after ten seconds without user input and restores the controlled application to the foreground first. Physical `Escape` cancels at any time. Both visual guards are click-through, non-activating, and excluded from evidence capture. These protections do not make host execution isolated.

The host runner supports both current PowerShell 7/.NET and Windows PowerShell 5.1. Its validation-only path compiles and loads the same native helper used by a real run, without displaying the halo or launching the artifact, so an engine-specific assembly-resolution failure cannot hide behind schema-only validation.

## Run an artifact

Use `scripts/Invoke-HyperVExecutableTest.ps1`.

- For a standalone executable, pass its file path with `-ArtifactPath`.
- For Electron or another multi-file package, pass the package directory with `-ArtifactPath` and the executable path relative to that directory with `-ExecutableRelativePath`.
- `ArtifactPath` remains the canonical payload location and stable cache identity. The runner enumerates paths plus cheap size/write-time fingerprints, reuses stored SHA-256 values for unchanged files, and hashes only additions or likely-change candidates. Do not pre-copy a package into broker staging.
- Pass application arguments with `-Arguments`. In arguments and string-valued action fields such as `type_text.text`, `{PAYLOAD}` resolves to the root of the attached application payload and `{OUTDIR}` resolves to the persistent guest evidence directory. Do not assume either guest drive letter.
- Declare auxiliary host files or directories with `-ReadOnlyHostInput @{ Name = 'media'; Path = 'D:\Netflix'; Mode = 'Auto' }`. No persistent allowlist is used: any absolute local path supplied for that run is eligible. Refer to it as `{HOSTINPUT:media}` in arguments or ordinary string-valued actions. Names are case-insensitively unique; the `HOSTINPUT:` prefix remains uppercase.
- `Mode=Auto` selects an unchanged warm VHDX cache, a small cold/incremental VHDX cache update, or an ephemeral read-only host share for cold or substantially changed large data. `Mode=Share` and `Mode=Vhdx` force either route. `ArtifactPath` is never converted to a host share and retains its canonical immutable payload behavior.
- General networking is opt-in with `-NetworkProfile`; omit it or use `None` for the disconnected compatibility default. Non-`None` requests use `RunGuestJobNetworkV1`, causing an older broker to reject them rather than ignore the network contract.
- `IsolatedTestNet` requires `-NetworkCohort <NON_SECRET_LABEL>`. Only concurrent requests in the same explicitly named cohort may share its private VM-only switch; the broker exempts only the disposable request adapter from the guest firewall for arbitrary cohort protocols, and the switch has no host, LAN, or Internet route.
- `InternetOnly` does not accept `-NetworkCohort`; the broker alone selects its pinned internal infrastructure. It is disabled until the host's sole WinNAT is pinned and has no static mappings, the internal gateway's `Promiscuous` private-VLAN pair and every guest's matching `Isolated` pair are pinned, exact weighted stateful extended ACLs default-deny unsolicited and non-TCP/UDP traffic, peer layer-2 isolation and the expected gateway Ethernet/ARP exchange are live-tested, and IPv6, host IP, LAN, and inbound denial are proven. It is not equivalent to the Hyper-V `Default Switch`, and it does not claim that its required host gateway is invisible at raw layer 2.
- `TrustedLan` accepts no switch selector. The broker policy must contain exactly one external switch pinned by name, ID, single physical-interface GUID/description, and management-OS sharing state. It deliberately gives the guest full reachable-LAN exposure; state that scope before using it.
- The runner exposes no switch-selection parameter. Requests cannot provide switch names or IDs, NAT, DNS, routes, firewall policy, or other network objects.
- Combining any non-`None` profile with `-ReadOnlyHostInput` requires `-AllowNetworkWithHostInputs`. An explicit `Mode=Share` remains incompatible and is rejected; `Mode=Auto` is forced to the immutable, guest-read-only VHDX transport. Without the flag, reject the combined request.
- A source update does not create or enable switches, NAT, firewall rules, or allowlists. If a requested profile is disabled, stop and explain that setup requires the setup-harness informed-consent plan, preflight, and separate approval before host mutation. Never substitute another switch.
- Reserved tokens are uppercase and validated before queueing. Unknown tokens, lowercase spellings, and tokens in structural fields such as an action `type` or screenshot evidence `name` are rejected. `-AssertResultFile` continues to require `{OUTDIR}\` and does not accept `{PAYLOAD}`.
- Use `-AssertResultFile` to require an application-produced result. To evaluate its content, add `-AssertResultJsonPointer '/passed' -AssertResultEqualsJson 'true'`. The pointer follows RFC 6901 and the expected value is typed JSON, not a string expression.
- Use `-ExpectGuestPowerOff` only when the application is expected to shut down an exclusively owned disposable worker with no external administrator intervention. It requires `-AssertResultFile` below `{OUTDIR}\`; `-AssertResultJsonPointer` and `-AssertResultEqualsJson` remain an optional pair. The exact path closes its parent guest session, makes one watchdog-bounded child submission, monitors through killable read-only probes, and does not offer guest live capture. `-GuestPowerOffRecoveryTimeoutSeconds` accepts 30 through 600 seconds and defaults to 180. Omit both power-off parameters for the unchanged legacy launch, action, timeout, evidence, and cleanup behavior.
- Omit actions for a basic launch-and-screenshot smoke test. For interaction, provide an actions JSON file with `-ActionsPath`.
- Add `-RequireHostLocked` only when the test specifically needs proof that the physical workstation stayed locked. Ordinary VM runs remain isolated without touching the host desktop whether it is locked or unlocked.
- The default queue deadline is 30 minutes and the execution deadline is 15 minutes. Override them independently with `-QueueTimeoutSeconds` and `-ExecutionTimeoutSeconds`; time spent waiting in line never consumes the execution budget.

Example:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\MyElectronApp' `
  -ExecutableRelativePath 'MyElectronApp.exe' `
  -ReadOnlyHostInput @{ Name = 'media'; Path = 'D:\Netflix'; Mode = 'Auto' } `
  -Arguments '--media "{HOSTINPUT:media}"' `
  -ActionsPath 'D:\build\vm-actions.json'
```

The example above uses the default `None` profile. Explicit profile examples are:

```powershell
# Two concurrently submitted requests may use the same private cohort.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\service-a' `
  -NetworkProfile IsolatedTestNet `
  -NetworkCohort 'contract-test-42'

# InternetOnly accepts no switch override; the broker selects pinned infrastructure.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\internet-client' `
  -NetworkProfile InternetOnly

# TrustedLan resolves the sole broker-approved switch from private policy.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\lan-client' `
  -NetworkProfile TrustedLan

# Auto cannot select Share when general networking is present; it becomes VHDX.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\internet-client' `
  -NetworkProfile InternetOnly `
  -AllowNetworkWithHostInputs `
  -ReadOnlyHostInput @{ Name = 'fixtures'; Path = 'D:\fixtures'; Mode = 'Auto' }
```

### Test an intentional guest shutdown

`-ExpectGuestPowerOff` is an explicit contract for an application expected to power off its isolated worker. Prefer `-NetworkProfile None` for shutdown qualification. Before calling the real guest command `shutdown.exe /s /t 0`, the application must atomically publish and close its required marker below `{OUTDIR}`: write a temporary file in the same directory, flush and close it, then replace or rename it to the final path. Its last-write time must precede the later recovery boot; a post-boot marker fails as `ResultFileNotPrePowerOff`. The file and its timestamp are application-controlled test evidence, not a hostile-guest security attestation. Omitting actions under this contract selects a marker-oriented `wait_result_file` action instead of the legacy launch screenshots; an explicit actions file is still enforced as written.

The example below assumes `ShutdownProbe.exe` accepts the shown marker argument, atomically writes `{"passed":true}` to that path, and then invokes `%SystemRoot%\System32\shutdown.exe /s /t 0` inside the disposable guest. The application is not launched on the physical host.

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\ShutdownProbe.exe' `
  -Arguments '--marker "{OUTDIR}\shutdown-result.json"' `
  -NetworkProfile None `
  -ExpectGuestPowerOff `
  -GuestPowerOffRecoveryTimeoutSeconds 180 `
  -AssertResultFile '{OUTDIR}\shutdown-result.json' `
  -AssertResultJsonPointer '/passed' `
  -AssertResultEqualsJson 'true'
```

After the guest agent confirms the application process, the host records an application-era VM `Running` observation and must later observe `Off` before broker cleanup begins. This ordering and a final `VmFinalState=Off` do not prove which in-guest process requested shutdown; attribution assumes exclusive worker ownership and no external administrator intervention. The exact path closes its parent session, records the durable ambiguity/no-replay boundary, makes exactly one bounded child submission, and uses killable read-only child probes thereafter. Once `Off` is observed, the broker revokes request networking and any ephemeral host-input share, verifies that no adapter remains connected, and boots that same disposable worker once without networking solely to finalize and copy the persisted marker through a unique stable evidence stage. Guest live capture is unavailable, and the harness never resubmits or relaunches after the durable boundary. Recovery has its own bounded timeout; cancellation and the execution deadline remain authoritative.

An actions file is a JSON array. Supported action shapes are:

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

`wait_result_file` is the preferred completion signal for Electron apps, installers, and launchers whose initial process may hand work to child processes. A matching JSON assertion is evaluated as soon as that file appears; a false assertion skips the remaining waits and input actions. Any later requested screenshots run immediately as diagnostic finalizers. `wait_process_exit` is appropriate when the lifetime and exit code of the directly launched process are authoritative.

Prefer stable UI Automation IDs with `click_control`; `name` is also supported. Automation IDs are provider-defined at runtime and may not match control names from source code, especially in WinForms or Electron. If lookup fails, use the element inventory in the guest error to select the actual runtime `name`/ID, or use a verified relative coordinate when the provider exposes no stable selector. Capture a screenshot before and after consequential interactions.

Use `send_keys` for one named key press or chord after the application window is focused. `keys` is a canonical uppercase `+`-separated value such as `ENTER`, `ALT+F4`, `CTRL+SHIFT+S`, or `WIN+LEFT`; modifiers must precede exactly one non-modifier key. The allowlist is limited to `CTRL`, `ALT`, `SHIFT`, `WIN`, arrows, common navigation/editing keys, `F1`-`F12`, letters, and digits. Duplicate keys, arbitrary virtual-key numbers, scan codes, text, scripts, extra fields, and chords with multiple non-modifier keys are rejected before queueing and again by the broker and guest. `holdMs` is optional, defaults to 50, and is bounded from 10 through 2000. The guest releases the chord in reverse order and records the canonical key names, allowlisted virtual-key codes, hold duration, and target window handle in `result.json` action evidence.

The runner validates the action schema before queueing and rejects evidence paths that escape the request output directory. Screenshot capture first proves that the input desktop, Explorer, DWM, and display geometry are ready, then uses fresh out-of-process helpers with bounded exponential retries. A persistent invalid-handle capture failure is classified as harness infrastructure: the request is replayed at most once on another clean worker while the failed worker recycles asynchronously. The result records the retry count and worker history.

The broker maintains immutable VHDX generations per canonical `ArtifactPath`. On a changed manifest it creates a cached differencing generation over the prior generation, applies only file and directory additions, changes, and deletions, verifies changed files, then seals that generation read-only. Unchanged files remain inherited from the prior generation. Every test gets another disposable differencing child on top; the VM launches from that child, then the broker powers off the VM, detaches the child, and deletes it. PowerShell Direct remains limited to small control JSON and evidence, not application payload trees.

Named read-only host inputs are independent of `ArtifactPath`. A shared input receives a per-request random SMB share and local credential over a worker-specific internal Hyper-V switch containing only that VM and its host endpoint. The private links use dedicated RFC 1918 `/30` subnets so host VPN LAN/kill-switch policy can recognize them without providing LAN or Internet reachability. IP forwarding and weak-host routing are disabled; one host firewall exception admits encrypted SMB only on TCP 445 at that worker-specific host address, while the normal BlockInbound profile continues to reject other inbound traffic. The share grants only read access even when the source ACL is writable. A temporary read/execute ACE may be added for the ephemeral principal, which is deleted before that ACE is removed so an interrupted cleanup cannot leave usable access. File inputs use a same-volume hard-link projection and do not copy their contents. Share mappings, accounts, permissions, projections, VM adapters, and leases are reconciled after cancellation, worker failure, or broker restart.

Shared input is read-only but live: host-side changes can become visible during a run and reading a cloud placeholder may hydrate it on the host. Use `Mode=Vhdx` for a frozen, guest-read-only view or when an application requires local-disk semantics. Neither transport permits the application to modify the declared host input.

In pool mode, several workers may pin the same immutable payload generation concurrently, but each request always receives its own writable child. Generation leases prevent cache GC or compaction until every child has been detached and deleted.

## Share the VM safely

The broker owns one FIFO queue and assigns requests across an elastic pool of up to four isolated VMs. Multiple Codex tasks may submit concurrently; they must not start or control pool VMs directly. The runner reports its request ID, assigned worker, and live queue position. While one to three workers are leased, the broker continuously keeps one additional clean worker ready or being readied. The idle reaper never stops the last ready spare while a lease remains; the four-worker ceiling and explicit maintenance drain are the only exceptions. Each released or unused worker otherwise has an independent ten-minute idle deadline.

Runner progress is driven primarily by the request's atomic `request-state.json`, not by the presence of its file in `Processing`. The lifecycle is reported as distinct `Submitted`, `Queued`, `Claimed`, `StagingGuestPayload`, `PreparingVm`, `StartingVm`/`WaitingForGuestAgent`, applicable `PreparingNetwork`/`VerifyingNetwork`, `LaunchingApplication`, `ApplicationRunning`, `GuestAction`, `CollectingEvidence`, `StoppingVm`, applicable `CleaningNetwork`, and terminal stages. Status/message duplicates are suppressed, while queue position, worker, process, action, and network changes remain visible. `ApplicationRunning` is published only after the guest agent's post-`Start-Process` lease confirms the application PID; guest-job submission alone remains `LaunchingApplication`. The final runner JSON includes the observed `LifecycleSequence`. With an older broker or a temporarily missing state file, the runner says only that the request was assigned and waits for lifecycle confirmation.

Shared JSON state is published through unique same-directory staging files and retrying filesystem replacement. Concurrent runner reads or independent worker writes therefore see a complete old or new document and cannot abort an application run with a destination-already-exists race. If a state read is transiently denied during replacement, the runner retains the last readable lifecycle stage instead of visibly regressing to `Assigned`; conservative assignment wording remains the initial fallback when no request state has ever been read.

Inspect the active request and queue without changing them:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Get-HyperVExecutableTestQueue.ps1"
```

Each queued or claimed entry includes `OwnershipStatus` plus the current per-request `Status`, `Message`, worker/application PID, and guest action fields when available. This separates queue ownership from actual execution progress.

## Observe a running request without changing it

Capture fresh live evidence through the broker with the exact request ID reported by the runner:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1" `
  -RequestId 'executable-test-...' `
  -GuestEvidencePath @('release-gate-progress.json', 'milestones\phase-2.png')
```

The screenshot is mandatory and always fresh for that invocation. `-GuestEvidencePath` is an optional per-capture allowlist of at most 16 literal relative paths below the active request's `{OUTDIR}`. Each requested file is limited to 4 MiB and all requested files together to 16 MiB. Absolute paths, wildcards, empty/`.`/`..` segments, alternate streams, traversal, directories, and any reparse-point traversal are rejected. `-CaptureTimeoutMilliseconds` accepts 3000 through 30000; `-WaitTimeoutSeconds` only controls how long the client waits for the broker response and never changes the original request's queue or execution deadline.

Live screenshots are supported only while the broker confirms both an application PID and lifecycle `ApplicationRunning` or `GuestAction` (including a `wait_result_file` guest action). Other outcomes are explicit:

- `RequestNotFound`: the ID is not queued, broker-owned/running, or terminal.
- `QueuedNotRunning`: the request is still waiting for a worker.
- `GuestDesktopNotReady`: the request is claimed or preparing, but no supported interactive application stage is confirmed.
- `RequestAlreadyTerminal`: result/evidence collection, cleanup, or another terminal stage has begun.
- `StaleWorkerRequestBinding`: the processing record, worker ID, worker operation, request state, or application PID no longer agrees.
- `ScreenshotInfrastructureFailure`: the interactive capture or its bounded verified transfer failed.
- `GuestEvidencePathRejected` / `GuestEvidenceUnavailable`: an optional file was unsafe, absent, too large, unstable while being copied, or otherwise unreadable.

A successful JSON response has `Status=Captured` and reports `CaptureId`, `RequestId`, `WorkerId`, `LifecycleStage`, `ApplicationProcessId`, guest capture time, width, height, SHA-256, the request-scoped `EvidencePath`, copied guest-file metadata, and `RequestRemainedActiveAfterCapture`. The atomically published directory is `Results\<RequestId>\live-evidence\<CaptureId>` below the installed broker root and contains `capture.json`, `live-evidence-result.json`, `live-screenshot.png`, and any requested files under `files\`. A classified non-success returns JSON with `Success=false`, a distinct `Status`/`FailureKind`, and no stale screenshot substituted as current evidence.

The client never opens a Hyper-V session, selects or manages a VM, injects keyboard/mouse input, changes networking, alters host inputs/payloads, or cancels/restarts/extends the request. The SYSTEM broker atomically claims the command, binds it to the current worker operation, relays only small control JSON over its existing Hyper-V Direct channel, and publishes only bounded hash-verified files. Capture state transitions are mutex-protected and the interactive guest agent services captures serially for its active request; publication uses a client-inaccessible broker staging tree plus an atomic same-volume rename into a request-scoped read-only directory, and terminal-evidence races resolve to either a complete capture directory or an explicit terminal/stale outcome.

Limitations: this is a screenshot plus small-file snapshot, not video or remote control. It cannot inspect a queued request, a pre-login desktop, a recovering guest agent, or a request already collecting terminal evidence. An application can change immediately after the post-capture liveness check; use `RequestRemainedActiveAfterCapture` as the bounded observation, not a future-running guarantee.

For a long `wait_result_file`, run the test in one terminal/task and observe it from another after the first terminal reports the request ID and `GuestAction ... wait_result_file`:

```powershell
# Terminal A: actions.json contains a long wait_result_file action.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\LongRunningApp' `
  -ExecutableRelativePath 'LongRunningApp.exe' `
  -ActionsPath 'D:\build\actions.json' `
  -ExecutionTimeoutSeconds 900

# Terminal B, while Terminal A is still waiting:
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1" `
  -RequestId 'executable-test-20260828T190000000Z-...' `
  -GuestEvidencePath 'release-gate-progress.json'
```

Repeat the Terminal B command to obtain another unique capture and compare capture times/hashes. Let Terminal A finish normally and verify its ordinary terminal evidence and worker cleanup independently.

Cancel a queued or running request by its reported ID:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Cancel-HyperVExecutableTest.ps1" `
  -RequestId 'executable-test-...'
```

A queued cancellation atomically removes the request so it cannot run later. A running cancellation signals its assigned worker, which disconnects any request-scoped network through its persisted lease, powers off, and enters isolated recycling before reuse. The broker also enforces both deadlines itself, so abandoned clients cannot leave stale work waiting or running indefinitely. Terminal evidence is not published until network cleanup has proved every adapter disconnected; startup and periodic orphan reconciliation finish cleanup after broker or worker interruption.

Terminal flags are intentionally distinct: an explicit queued cancel reports `Status=Cancelled`, `Cancelled=true`, and `QueueTimedOut=false`; an expired queue deadline reports `Status=QueueTimedOut`, `Cancelled=false`, and `QueueTimedOut=true`. Neither case starts the VM.

For ordinary requests, the broker reconciles interrupted submissions before retrying, reconnects dropped Hyper-V Direct sessions without launching the application twice, and safely requeues unfinished `Processing` requests after the affected VM has been recycled. VM-readiness probes run in disposable child processes so a stuck PowerShell Direct handshake cannot block cancellation or execution deadlines. The interactive guest agent is supervised; for an ordinary request, if it exits mid-job, its app lease and `Processing` request are recovered and rerun without overlapping application instances. An exact expected-power-off request is the exception: once its durable ambiguity marker exists, interruption fails terminally and neither broker nor guest recovery resubmits or relaunches it. Controlled broker and baseline updates drain active requests while preserving the FIFO queue.

Guest completion includes bounded, verified termination of the entire process tree rooted at the launched application, including detached Electron, Node, command-wrapper, and helper descendants. The guest publishes `result.json` only after this cleanup and records `ProcessCleanup` details in that result. Evidence collection then creates a stable guest-side snapshot before transferring anything to the host. Individually locked optional diagnostics are retried and, if still unavailable, reported through `EvidenceFilesSkipped`, `EvidenceSkippedFiles`, and `EvidenceWarnings`; they do not hide an otherwise valid terminal result. A missing `result.json`/`agent-error.json` remains a harness failure.

Faulted pool workers recover asynchronously without waiting for queue pressure. Consecutive lifecycle failures use worker-staggered exponential backoff capped at ten minutes, so a broken VM cannot spin continuously; successful readiness resets the backoff. Recovery remains subject to the existing lifecycle-concurrency limit and never weakens the warm-spare invariant.

Queue reporting keeps the raw warm-spare counts visible during maintenance but sets `WarmSparePolicyApplicable=false`; intentional maintenance drain alone therefore does not raise `InvariantViolation`. Concurrency and orphaned-processing violations remain active.

Payload cache garbage collection is automatic while the pool is fully idle and off. Generation leases allow several VMs to reuse one immutable parent while preventing cache deletion or chain compaction underneath any child. GC excludes queued, processing, leased, attached, and parent-referenced generations; evicts inactive entries older than 30 days; applies a 64 GiB high-water/56 GiB low-water LRU cap; removes abandoned temporary mounts and disposable children; and periodically flattens deep immutable generation chains. Do not delete VHDXs behind the broker. Inspect `State\payload-cache-gc.json` when cache reclamation matters.

## Verify and report

Require all of the following before claiming success:

- Treat the runner's `HarnessSucceeded`, `TestEvaluated`, and nullable `TestPassed` as separate facts. `Success` and `OverallSucceeded` are false when either harness execution fails or a declared application assertion fails. Without an application assertion, a successful smoke run has `TestEvaluated=false` and `TestPassed=null`.
- For `-ExpectGuestPowerOff`, require `ExpectedGuestPowerOffContractProven=true`, `GuestPowerOffBeforeCleanup=true`, ordered application-era `Running` and host-observed `Off` timestamps, `GuestPowerOffEvidenceRecoveryMode=ControlledReboot`, and `ApplicationRelaunchedByHarnessAfterGuestPowerOff=false`. When the marker exists, also require `ResultFileEvidence.PredatesRecoveryBoot=true`. These observations and application-controlled files do not prove the shutdown caller against a hostile guest; attribution assumes exclusive worker ownership and no external administrator intervention. A missing, empty, or false marker is an evaluated application failure (`HarnessSucceeded=true`, `TestEvaluated=true`, `TestPassed=false`) when recovery and cleanup themselves succeeded; an ordering, recovery, or cleanup failure makes `HarnessSucceeded=false`.
- `broker-result.json` reports `HarnessSucceeded=true`, identifies `PoolWorkerId`, and records `VmFinalState` as `Off` before asynchronous OS recycling begins. Its legacy `Success` field remains the broker/harness-layer result.
- Guest `result.json` reports `HarnessSucceeded=true`; when `TestEvaluated=true`, require `TestPassed=true` before claiming application success.
- Guest `ProcessCleanup.Success` is true. Review non-empty broker `EvidenceWarnings`; skipped optional diagnostics are degraded evidence, while missing requested/terminal evidence still fails verification.
- Every reported host input has the expected `SelectedTransport`; shared inputs report `ReadOnly=true`, `BytesExposedWithoutCopy`, an isolated switch, and successful cleanup, while cached inputs report their cache/hash/sync timings and deleted disposable child.
- For a non-`None` profile, require evidence for the requested/effective profile, approved switch name and ID, adapter enforcement and connect-last sequence, host-policy checks, exact guest-side boundary attestation, cleanup success, final disconnected adapters, and deleted lease. With host inputs, verify `Auto` selected VHDX and that `Share` was not used.
- Do not describe `InternetOnly` as proven without current live positive Internet evidence and negative host, private/LAN, inbound, and IPv6 evidence from the installed pinned switch/NAT policy. The Hyper-V `Default Switch` is not acceptable evidence for this profile.
- Requested screenshots and application-produced evidence exist in the returned result directory.
- `PayloadChildDeleted` is true, the recorded child path no longer exists, and no payload child remains attached to the VM.
- For performance claims, report `PayloadFilesHashed`, `PayloadHashesReused`, `PayloadFingerprintEnumerationMilliseconds`, `PayloadCandidateHashMilliseconds`, `PayloadCacheOperationMilliseconds`, and `PayloadVhdxSyncMilliseconds`. An unchanged repeat run should report a cache hit and zero files hashed.
- Visually inspect relevant screenshots with the local image viewer.
- When locked-host proof was requested, verify both lock-evidence fields are true and use `LockSignal=WTSSessionInfoEx` with `WtsSessionFlags=0`; `LogonUI` is fallback evidence only because it can disappear while Windows remains locked.

Each pool VM boots from a disposable OS differencing child of the sealed `Clean-Windows11-Harness` image. The broker refuses pre-existing connected network adapters. For an authorized network profile it records a per-request lease before VM-adapter mutation, connects the approved adapter last, verifies the boundary before launch, disconnects first during cleanup, and publishes cleanup evidence before recycling. For a shared read-only host input it alone creates the separate request-scoped adapter described above, then removes it before the worker recycles. The harness uses guest session 1 for input, preserves evidence under its configured `Results` directory, powers the assigned worker off after evidence collection, and recreates its OS child asynchronously before reuse. The installed location pointer resolves the broker root after a host recovery. Do not connect networking or change the baseline implicitly. Stop and explain when a requested profile is unavailable or a native test requires physical hardware, drivers, other host services, or another capability the isolated VM does not provide.
