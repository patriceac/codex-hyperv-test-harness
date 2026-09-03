# Expected guest power-off

Read this reference only when the application is expected to shut down its exclusively owned disposable worker. This is an explicit evidence and recovery contract, not a synonym for ordinary process exit.

## Request contract

Use `-ExpectGuestPowerOff` only when no external administrator intervention can race the test. Prefer `-NetworkProfile None` for shutdown qualification.

This mode requires `-AssertResultFile` below `{OUTDIR}\`. `-AssertResultJsonPointer` and `-AssertResultEqualsJson` remain an optional pair. `-GuestPowerOffRecoveryTimeoutSeconds` accepts 30 through 600 seconds and defaults to 180. Omit both power-off parameters for the ordinary launch, action, timeout, evidence, retry, and cleanup behavior.

Before calling the real guest command `shutdown.exe /s /t 0`, the application must atomically publish and close its marker below `{OUTDIR}`: write a temporary file in the same directory, flush and close it, then replace or rename it to the final path. Its last-write time must precede the later recovery boot; a post-boot marker fails as `ResultFileNotPrePowerOff`. The marker and timestamp are application-controlled evidence, not an attestation against a hostile guest.

When actions are omitted, this contract selects a marker-oriented `wait_result_file` action instead of ordinary launch screenshots. An explicit actions file is still executed as written. Guest live capture is unavailable in this mode.

Example, assuming the probe writes `{"passed":true}` atomically and then shuts down Windows:

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

## No-replay recovery boundary

After the guest agent confirms the application process, the host records an application-era VM `Running` observation and must later observe `Off` before broker cleanup. That ordering and `VmFinalState=Off` do not prove which in-guest process requested shutdown; attribution assumes exclusive worker ownership and no external administrator intervention.

The exact path closes its parent guest session, records the durable ambiguity/no-replay boundary, submits one watchdog-bounded child operation, and thereafter uses killable read-only probes. Once `Off` is observed, the broker revokes request networking and any ephemeral host-input share, proves no adapter remains connected, then boots the same disposable worker once without networking solely to finalize and copy the persisted marker through a unique stable evidence stage.

The harness never resubmits or relaunches the application after the durable boundary. Recovery has its own bounded timeout; cancellation and the original execution deadline remain authoritative. If interruption occurs after the ambiguity marker exists, fail terminally instead of replaying the application.

## Required evidence

Before claiming the contract passed, require:

- `ExpectedGuestPowerOffContractProven=true`;
- `GuestPowerOffBeforeCleanup=true`;
- ordered application-era `Running` and host-observed `Off` timestamps;
- `GuestPowerOffEvidenceRecoveryMode=ControlledReboot`;
- `ApplicationRelaunchedByHarnessAfterGuestPowerOff=false`;
- when the marker exists, `ResultFileEvidence.PredatesRecoveryBoot=true`;
- final cleanup and disconnected-adapter evidence required by the ordinary verification contract.

A missing, empty, or false marker is an evaluated application failure (`HarnessSucceeded=true`, `TestEvaluated=true`, `TestPassed=false`) when recovery and cleanup succeeded. An ordering, recovery, or cleanup failure makes `HarnessSucceeded=false`.
