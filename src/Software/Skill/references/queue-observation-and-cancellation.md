# Queue, observation, and cancellation

Read this reference when several tasks share the harness, a request may run for a long time, fresh mid-run evidence is needed, or a request must be cancelled.

## Shared queue

The broker owns one FIFO queue and assigns requests across an elastic pool of up to four isolated VMs. Multiple Codex tasks may submit concurrently; clients never start or control pool VMs. The runner reports request ID, assigned worker, and live queue position. Queue and execution deadlines are independent: the defaults are 30 and 15 minutes, and queue time never consumes the execution budget.

While one to three workers are leased, the broker keeps one additional clean worker ready or being readied. The idle reaper does not stop the last ready spare while a lease remains; the four-worker ceiling and explicit maintenance drain are the exceptions. Other released or unused workers have independent ten-minute idle deadlines.

Request progress comes primarily from atomic `request-state.json`, with distinct stages including `Submitted`, `Queued`, `Claimed`, `StagingGuestPayload`, `PreparingVm`, `StartingVm`/`WaitingForGuestAgent`, applicable network preparation/verification, `LaunchingApplication`, `ApplicationRunning`, `GuestAction`, `CollectingEvidence`, `StoppingVm`, applicable network cleanup, and terminal stages. `ApplicationRunning` appears only after the guest agent confirms the launched PID. The final result includes `LifecycleSequence`.

Inspect queue and active requests without changing them:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Get-HyperVExecutableTestQueue.ps1"
```

Each entry reports `OwnershipStatus` plus current request status/message, worker/application PID, and guest-action fields when available. With an old broker or temporarily unavailable state file, the runner reports only assignment and waits for confirmed lifecycle state.

## Fresh live evidence

Capture a fresh screenshot and optional small guest files for an active request:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1" `
  -RequestId 'executable-test-...' `
  -GuestEvidencePath @('release-gate-progress.json', 'milestones\phase-2.png')
```

The screenshot is mandatory and fresh for that invocation. `-GuestEvidencePath` is an optional allowlist of at most 16 literal relative paths below the active request's `{OUTDIR}`. Each file is limited to 4 MiB and the set to 16 MiB. Absolute paths, wildcards, empty/`.`/`..` segments, alternate streams, traversal, directories, and reparse-point traversal are rejected. `-CaptureTimeoutMilliseconds` accepts 3000 through 30000. `-WaitTimeoutSeconds` controls only the client wait for broker response; it never changes the original request deadlines.

Live capture works only when the broker confirms an application PID and lifecycle `ApplicationRunning` or `GuestAction`, including `wait_result_file`. Other outcomes are explicit:

- `RequestNotFound`
- `QueuedNotRunning`
- `GuestDesktopNotReady`
- `RequestAlreadyTerminal`
- `StaleWorkerRequestBinding`
- `ScreenshotInfrastructureFailure`
- `GuestEvidencePathRejected` or `GuestEvidenceUnavailable`

Success returns `Status=Captured`, a unique capture/request/worker identity, lifecycle and PID, guest capture time, dimensions, SHA-256, request-scoped `EvidencePath`, copied-file metadata, and `RequestRemainedActiveAfterCapture`. The result directory is `Results\<RequestId>\live-evidence\<CaptureId>` below the broker root and contains metadata, `live-screenshot.png`, and any requested `files\`. Failure returns `Success=false` with a distinct classification and never substitutes a stale screenshot.

The client cannot use observation to open a Hyper-V session, select/manage a VM, inject input, change networking or payloads, cancel/restart/extend the request, or alter deadlines. The broker binds a capture to the current worker operation, relays small control JSON over its existing Hyper-V Direct channel, and atomically publishes bounded hash-verified files. Terminal races yield either a complete capture directory or an explicit terminal/stale result.

This is a screenshot plus small-file snapshot, not video or remote control. It cannot inspect a queued request, pre-login desktop, recovering guest agent, or terminal evidence collection. `RequestRemainedActiveAfterCapture` is a bounded post-capture observation, not a future-running guarantee.

For a long `wait_result_file`, let the original runner remain active in one terminal/task. After it reports the request ID and `GuestAction ... wait_result_file`, capture from another terminal/task. Repeating the capture produces unique evidence; compare timestamps and hashes, then let the original request finish and verify its terminal evidence and cleanup independently.

## Cancellation

Cancel by the exact reported request ID:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Cancel-HyperVExecutableTest.ps1" `
  -RequestId 'executable-test-...'
```

A queued cancellation atomically removes the request so it cannot run later. A running cancellation signals its assigned worker, disconnects request-scoped networking through the persisted lease, powers off the VM, and places it into isolated recycling before reuse. Broker-enforced deadlines prevent abandoned clients from leaving stale queued or running work. Terminal evidence is withheld until network cleanup proves every adapter disconnected; startup and periodic reconciliation complete interrupted cleanup.

Terminal flags remain distinct: an explicit queued cancel reports `Status=Cancelled`, `Cancelled=true`, `QueueTimedOut=false`; an expired queue deadline reports `Status=QueueTimedOut`, `Cancelled=false`, `QueueTimedOut=true`. Neither starts a VM.
