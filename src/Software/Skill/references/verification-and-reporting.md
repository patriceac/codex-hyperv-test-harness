# Verification and reporting

Read this reference before claiming a Hyper-V application test succeeded. Report the evidence actually obtained; do not turn an unevaluated smoke run into an application pass.

## Common result semantics

Treat the runner's `HarnessSucceeded`, `TestEvaluated`, and nullable `TestPassed` as separate facts.

- `HarnessSucceeded=true` means the isolated execution/evidence/cleanup path succeeded.
- `TestEvaluated=true` means a declared application assertion was evaluated.
- When evaluated, require `TestPassed=true` before claiming application success.
- Without an application assertion, a successful smoke run has `TestEvaluated=false` and `TestPassed=null`.
- `Success` and `OverallSucceeded` are false when harness execution fails or a declared assertion fails. The broker's legacy `Success` field remains a harness-layer result.

Require `broker-result.json` to report `HarnessSucceeded=true`, identify `PoolWorkerId`, and record `VmFinalState=Off` before asynchronous OS recycling. Guest `result.json` must also report `HarnessSucceeded=true`.

Require `ProcessCleanup.Success=true`. Review any broker `EvidenceWarnings`. Skipped optional diagnostics are degraded evidence and must be disclosed; missing requested or terminal evidence is a failure.

Confirm requested screenshots and application-produced files exist in the returned result directory. Visually inspect relevant screenshots with the local image viewer; existence alone does not prove the UI behavior.

Require `PayloadChildDeleted=true`, verify the recorded child path no longer exists, and verify no payload child remains attached to the worker.

When locked-host proof was requested, require both lock-evidence fields to be true. Prefer `LockSignal=WTSSessionInfoEx` with `WtsSessionFlags=0`; `LogonUI` is fallback evidence because it can disappear while Windows remains locked.

## Mode-specific checks

- For any host input or non-`None` network profile, apply the evidence and cleanup requirements in [network and host inputs](network-and-host-inputs.md).
- For `-ExpectGuestPowerOff`, apply every required observation in [expected guest power-off](expected-guest-power-off.md). Its application-controlled marker is not proof of the shutdown caller against a hostile guest.
- For live evidence, cancellation, or queue/deadline claims, use the exact result semantics in [queue, observation, and cancellation](queue-observation-and-cancellation.md).
- For payload-cache performance claims, use the counters in [broker, pool, and cache internals](broker-pool-and-cache.md).

## Report precisely

State:

1. The canonical artifact and build identity tested.
2. Whether the harness succeeded.
3. Whether application behavior was evaluated and, if so, whether it passed.
4. The interaction, assertion, network/input, power-off, or locked-host scope actually exercised.
5. Relevant screenshot and application-evidence locations and what visual inspection established.
6. Cleanup outcome, warnings, skipped evidence, retries, or remaining limitations.

Do not claim a network boundary without current positive and negative evidence for the selected profile. Do not claim physical-host isolation for guarded host control. Stop and explain when the VM cannot faithfully exercise required hardware, drivers, host services, or another host-only capability.
