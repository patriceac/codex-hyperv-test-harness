---
name: hyperv-test-executables
description: Run and interactively test Windows application artifacts in the isolated Hyper-V test VM, including .exe files, Electron apps, installers, packaged desktop or CLI apps, and keyboard, mouse, or screenshot tests. Use by default whenever Codex would launch an application-under-test and its behavior cannot be tested faithfully in a browser, unless the user explicitly directs physical-host execution for the named test. Do not use for browser-only testing or for trusted host build tools that are not themselves under test.
---

# Hyper-V executable testing

Keep the application-under-test off the physical host by default. Build on the host when useful, then expose the canonical `ArtifactPath` through the SYSTEM broker's incremental VHDX cache. Never relocate or rewrite the normal project output.

## Route the test

1. Use a browser when it can faithfully exercise the requested behavior.
2. Honor an explicit user request to run, install, or interactively test a named artifact on the physical host. Natural wording such as "run this on the host" or "test it locally, not in Hyper-V" is sufficient; acknowledge it briefly and proceed without requiring a magic phrase or additional confirmation. Scope the override to that artifact and test only, and do not infer it from generic wording such as "run it."
3. Otherwise use this skill for every application-under-test. Treat Electron as a native desktop application; a Chromium-based shell is not the browser exception.
4. Never silently fall back to host execution. Report a broker or VM failure instead.

Trusted compilers, linkers, package managers, linters, and non-application test runners may run on the host. Outside an explicit host override, do not launch the built application, installer, CLI artifact, or packaged desktop process there.

## Run an artifact

Use `scripts/Invoke-HyperVExecutableTest.ps1`.

- For a standalone executable, pass its file path with `-ArtifactPath`.
- For Electron or another multi-file package, pass the package directory with `-ArtifactPath` and the executable path relative to that directory with `-ExecutableRelativePath`.
- `ArtifactPath` remains the canonical payload location and stable cache identity. The runner enumerates paths plus cheap size/write-time fingerprints, reuses stored SHA-256 values for unchanged files, and hashes only additions or likely-change candidates. Do not pre-copy a package into broker staging.
- Pass application arguments with `-Arguments`. In arguments and string-valued action fields such as `type_text.text`, `{PAYLOAD}` resolves to the root of the attached application payload and `{OUTDIR}` resolves to the persistent guest evidence directory. Do not assume either guest drive letter.
- Declare auxiliary host files or directories with `-ReadOnlyHostInput @{ Name = 'media'; Path = 'D:\Netflix'; Mode = 'Auto' }`. No persistent allowlist is used: any absolute local path supplied for that run is eligible. Refer to it as `{HOSTINPUT:media}` in arguments or ordinary string-valued actions. Names are case-insensitively unique; the `HOSTINPUT:` prefix remains uppercase.
- `Mode=Auto` selects an unchanged warm VHDX cache, a small cold/incremental VHDX cache update, or an ephemeral read-only host share for cold or substantially changed large data. `Mode=Share` and `Mode=Vhdx` force either route. `ArtifactPath` is never converted to a host share and retains its canonical immutable payload behavior.
- Reserved tokens are uppercase and validated before queueing. Unknown tokens, lowercase spellings, and tokens in structural fields such as an action `type` or screenshot evidence `name` are rejected. `-AssertResultFile` continues to require `{OUTDIR}\` and does not accept `{PAYLOAD}`.
- Use `-AssertResultFile` to require an application-produced result. To evaluate its content, add `-AssertResultJsonPointer '/passed' -AssertResultEqualsJson 'true'`. The pointer follows RFC 6901 and the expected value is typed JSON, not a string expression.
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

An actions file is a JSON array. Supported action shapes are:

```json
[
  { "type": "wait_window", "timeoutMs": 30000 },
  { "type": "focus_window" },
  { "type": "click_control", "automationId": "saveButton", "name": "Save", "timeoutMs": 10000 },
  { "type": "click_relative", "x": 320, "y": 180 },
  { "type": "type_text", "text": "{PAYLOAD}\\fixture-project" },
  { "type": "wait", "ms": 1000 },
  { "type": "wait_result_file", "path": "{OUTDIR}\\result.json", "timeoutMs": 300000 },
  { "type": "wait_process_exit", "timeoutMs": 300000, "expectedExitCode": 0 },
  { "type": "screenshot", "name": "result.png", "timeoutMs": 30000, "attempts": 5 }
]
```

`wait_result_file` is the preferred completion signal for Electron apps, installers, and launchers whose initial process may hand work to child processes. A matching JSON assertion is evaluated as soon as that file appears; a false assertion skips the remaining waits and input actions. Any later requested screenshots run immediately as diagnostic finalizers. `wait_process_exit` is appropriate when the lifetime and exit code of the directly launched process are authoritative.

Prefer stable UI Automation IDs with `click_control`; `name` is also supported. Automation IDs are provider-defined at runtime and may not match control names from source code, especially in WinForms or Electron. If lookup fails, use the element inventory in the guest error to select the actual runtime `name`/ID, or use a verified relative coordinate when the provider exposes no stable selector. Capture a screenshot before and after consequential interactions.

The runner validates the action schema before queueing and rejects evidence paths that escape the request output directory. Screenshot capture first proves that the input desktop, Explorer, DWM, and display geometry are ready, then uses fresh out-of-process helpers with bounded exponential retries. A persistent invalid-handle capture failure is classified as harness infrastructure: the request is replayed at most once on another clean worker while the failed worker recycles asynchronously. The result records the retry count and worker history.

The broker maintains immutable VHDX generations per canonical `ArtifactPath`. On a changed manifest it creates a cached differencing generation over the prior generation, applies only file and directory additions, changes, and deletions, verifies changed files, then seals that generation read-only. Unchanged files remain inherited from the prior generation. Every test gets another disposable differencing child on top; the VM launches from that child, then the broker powers off the VM, detaches the child, and deletes it. PowerShell Direct remains limited to small control JSON and evidence, not application payload trees.

Named read-only host inputs are independent of `ArtifactPath`. A shared input receives a per-request random SMB share and local credential over a worker-specific internal Hyper-V switch containing only that VM and its host endpoint. The private links use dedicated RFC 1918 `/30` subnets so host VPN LAN/kill-switch policy can recognize them without providing LAN or Internet reachability. IP forwarding and weak-host routing are disabled; one host firewall exception admits encrypted SMB only on TCP 445 at that worker-specific host address, while the normal BlockInbound profile continues to reject other inbound traffic. The share grants only read access even when the source ACL is writable. A temporary read/execute ACE may be added for the ephemeral principal, which is deleted before that ACE is removed so an interrupted cleanup cannot leave usable access. File inputs use a same-volume hard-link projection and do not copy their contents. Share mappings, accounts, permissions, projections, VM adapters, and leases are reconciled after cancellation, worker failure, or broker restart.

Shared input is read-only but live: host-side changes can become visible during a run and reading a cloud placeholder may hydrate it on the host. Use `Mode=Vhdx` for a frozen, guest-read-only view or when an application requires local-disk semantics. Neither transport permits the application to modify the declared host input.

In pool mode, several workers may pin the same immutable payload generation concurrently, but each request always receives its own writable child. Generation leases prevent cache GC or compaction until every child has been detached and deleted.

## Share the VM safely

The broker owns one FIFO queue and assigns requests across an elastic pool of up to four isolated VMs. Multiple Codex tasks may submit concurrently; they must not start or control pool VMs directly. The runner reports its request ID, assigned worker, and live queue position. While one to three workers are leased, the broker continuously keeps one additional clean worker ready or being readied. The idle reaper never stops the last ready spare while a lease remains; the four-worker ceiling and explicit maintenance drain are the only exceptions. Each released or unused worker otherwise has an independent ten-minute idle deadline.

Runner progress is driven primarily by the request's atomic `request-state.json`, not by the presence of its file in `Processing`. The lifecycle is reported as distinct `Submitted`, `Queued`, `Claimed`, `StagingGuestPayload`, `PreparingVm`, `StartingVm`/`WaitingForGuestAgent`, `LaunchingApplication`, `ApplicationRunning`, `GuestAction`, `CollectingEvidence`, `StoppingVm`, and terminal stages. Status/message duplicates are suppressed, while queue position, worker, process, and action changes remain visible. `ApplicationRunning` is published only after the guest agent's post-`Start-Process` lease confirms the application PID; guest-job submission alone remains `LaunchingApplication`. The final runner JSON includes the observed `LifecycleSequence`. With an older broker or a temporarily missing state file, the runner says only that the request was assigned and waits for lifecycle confirmation.

Shared JSON state is published through unique same-directory staging files and retrying filesystem replacement. Concurrent runner reads or independent worker writes therefore see a complete old or new document and cannot abort an application run with a destination-already-exists race. If a state read is transiently denied during replacement, the runner retains the last readable lifecycle stage instead of visibly regressing to `Assigned`; conservative assignment wording remains the initial fallback when no request state has ever been read.

Inspect the active request and queue without changing them:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Get-HyperVExecutableTestQueue.ps1"
```

Each queued or claimed entry includes `OwnershipStatus` plus the current per-request `Status`, `Message`, worker/application PID, and guest action fields when available. This separates queue ownership from actual execution progress.

Cancel a queued or running request by its reported ID:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Cancel-HyperVExecutableTest.ps1" `
  -RequestId 'executable-test-...'
```

A queued cancellation atomically removes the request so it cannot run later. A running cancellation signals its assigned worker, which powers off and enters isolated recycling before reuse. The broker also enforces both deadlines itself, so abandoned clients cannot leave stale work waiting or running indefinitely.

Terminal flags are intentionally distinct: an explicit queued cancel reports `Status=Cancelled`, `Cancelled=true`, and `QueueTimedOut=false`; an expired queue deadline reports `Status=QueueTimedOut`, `Cancelled=false`, and `QueueTimedOut=true`. Neither case starts the VM.

The broker reconciles interrupted submissions before retrying, reconnects dropped Hyper-V Direct sessions without launching the application twice, and safely requeues unfinished `Processing` requests after the affected VM has been recycled. VM-readiness probes run in disposable child processes so a stuck PowerShell Direct handshake cannot block cancellation or execution deadlines. The interactive guest agent is supervised; if it exits mid-job, its app lease and `Processing` request are recovered and rerun without overlapping application instances. Controlled broker and baseline updates drain active requests while preserving the FIFO queue.

Guest completion includes bounded, verified termination of the entire process tree rooted at the launched application, including detached Electron, Node, command-wrapper, and helper descendants. The guest publishes `result.json` only after this cleanup and records `ProcessCleanup` details in that result. Evidence collection then creates a stable guest-side snapshot before transferring anything to the host. Individually locked optional diagnostics are retried and, if still unavailable, reported through `EvidenceFilesSkipped`, `EvidenceSkippedFiles`, and `EvidenceWarnings`; they do not hide an otherwise valid terminal result. A missing `result.json`/`agent-error.json` remains a harness failure.

Faulted pool workers recover asynchronously without waiting for queue pressure. Consecutive lifecycle failures use worker-staggered exponential backoff capped at ten minutes, so a broken VM cannot spin continuously; successful readiness resets the backoff. Recovery remains subject to the existing lifecycle-concurrency limit and never weakens the warm-spare invariant.

Queue reporting keeps the raw warm-spare counts visible during maintenance but sets `WarmSparePolicyApplicable=false`; intentional maintenance drain alone therefore does not raise `InvariantViolation`. Concurrency and orphaned-processing violations remain active.

Payload cache garbage collection is automatic while the pool is fully idle and off. Generation leases allow several VMs to reuse one immutable parent while preventing cache deletion or chain compaction underneath any child. GC excludes queued, processing, leased, attached, and parent-referenced generations; evicts inactive entries older than 30 days; applies a 64 GiB high-water/56 GiB low-water LRU cap; removes abandoned temporary mounts and disposable children; and periodically flattens deep immutable generation chains. Do not delete VHDXs behind the broker. Inspect `State\payload-cache-gc.json` when cache reclamation matters.

## Verify and report

Require all of the following before claiming success:

- Treat the runner's `HarnessSucceeded`, `TestEvaluated`, and nullable `TestPassed` as separate facts. `Success` and `OverallSucceeded` are false when either harness execution fails or a declared application assertion fails. Without an application assertion, a successful smoke run has `TestEvaluated=false` and `TestPassed=null`.
- `broker-result.json` reports `HarnessSucceeded=true`, identifies `PoolWorkerId`, and records `VmFinalState` as `Off` before asynchronous OS recycling begins. Its legacy `Success` field remains the broker/harness-layer result.
- Guest `result.json` reports `HarnessSucceeded=true`; when `TestEvaluated=true`, require `TestPassed=true` before claiming application success.
- Guest `ProcessCleanup.Success` is true. Review non-empty broker `EvidenceWarnings`; skipped optional diagnostics are degraded evidence, while missing requested/terminal evidence still fails verification.
- Every reported host input has the expected `SelectedTransport`; shared inputs report `ReadOnly=true`, `BytesExposedWithoutCopy`, an isolated switch, and successful cleanup, while cached inputs report their cache/hash/sync timings and deleted disposable child.
- Requested screenshots and application-produced evidence exist in the returned result directory.
- `PayloadChildDeleted` is true, the recorded child path no longer exists, and no payload child remains attached to the VM.
- For performance claims, report `PayloadFilesHashed`, `PayloadHashesReused`, `PayloadFingerprintEnumerationMilliseconds`, `PayloadCandidateHashMilliseconds`, `PayloadCacheOperationMilliseconds`, and `PayloadVhdxSyncMilliseconds`. An unchanged repeat run should report a cache hit and zero files hashed.
- Visually inspect relevant screenshots with the local image viewer.
- When locked-host proof was requested, verify both lock-evidence fields are true and use `LockSignal=WTSSessionInfoEx` with `WtsSessionFlags=0`; `LogonUI` is fallback evidence only because it can disappear while Windows remains locked.

Each pool VM boots from a disposable OS differencing child of the sealed `Clean-Windows11-Harness` image. The broker refuses pre-existing connected network adapters. For a shared read-only host input it alone creates the request-scoped adapter described above, then removes it before the worker recycles. The harness uses guest session 1 for input, preserves evidence under its configured `Results` directory, powers the assigned worker off after evidence collection, and recreates its OS child asynchronously before reuse. The installed location pointer resolves the broker root after a host recovery. Do not connect networking or change the baseline implicitly. Stop and explain when a native test requires Internet/LAN access, physical hardware, drivers, other host services, or another capability the isolated VM does not provide.
