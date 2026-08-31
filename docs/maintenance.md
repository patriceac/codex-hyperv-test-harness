# Maintenance

## Update Windows and .NET images

Treat a baseline image update as a controlled rebuild. Begin with the setup skill's proposal and approval gate, then run the source-only public audit and an exact non-mutating plan:

```powershell
$parameters = @{
    InstallRoot = '<EXISTING_NON_ROOT_INSTALL_DIRECTORY>'
    GuestUpdateSwitchName = '<EXPLICIT_HYPERV_SWITCH>'
    DotNetChannel = '10.0'
    ExpectedDotNetSdkVersion = '<EXACT_STABLE_VERSION_RESOLVED_DURING_REVIEW>'
    ExpectedDotNet8SdkVersion = '<APPROVED_8_X_SERVICING_VERSION>'
    ExpectedDotNet9SdkVersion = '<APPROVED_9_X_SERVICING_VERSION>'
    TargetUserProfile = '<TARGET_PROFILE>'
    TargetUserSid = '<TARGET_SID>'
    GuestRestartMode = 'Manual'
    PreserveRecoveryPrevious = $true
}
& .\setup\Test-PublicRepository.ps1
& .\setup\Update-Images.ps1 @parameters -PlanOnly
```

After the second explicit approval, rerun the same parameter set without `-PlanOnly`. The updater requires an empty queue and clean workers, restores the canonical baseline, temporarily connects only that baseline to the approved switch, converges applicable non-preview Microsoft software/security/quality/Defender updates, installs the approved stable .NET SDK after SHA-512 and Microsoft Authenticode verification, performs an SDK build smoke test, disconnects networking, and shuts down the guest. Each synchronous Windows Update operation must return and the Windows Update Agent installer must report idle before the updater checks cancellation or considers a restart. Automatic mode restarts only for an explicit Windows Update installation result, CBS/Windows Update reboot marker, or verified SDK-installer exit code; `PendingFileRenameOperations` alone is recorded but never authorizes an automatic restart.

With `GuestRestartMode = 'Manual'`, the updater applies a temporary guest policy guard against scheduled automatic restart. An explicit restart requirement produces `ManualRebootPending`; the updater restores transient network, broker, and maintenance state, retains only that guard, and waits. After the user restarts the guest, rerun the approved command with `AdoptCurrentBaseline = $true`. Adoption requires manual restart mode, preserves the current guest disk instead of restoring the canonical checkpoint, verifies rather than changes VM sizing, and keeps the old canonical checkpoint available as rollback. It is also the required mode when a baseline was intentionally updated by hand and that current state must be retained. An ordinary servicing failure never hard-powers the baseline off, and manual mode never restores a checkpoint behind the user's back; it leaves the current guest state available for inspection or an explicit recovery decision. The original guest policy values are restored after successful completion or cooperative cancellation; cleanup failure is reported rather than hidden.

Closing the visible launcher requests cooperative cancellation instead of force-killing the elevated controller. The controller finishes only the already-running synchronous operation, observes Windows Update idle, stops before a reboot or next forward mutation, disconnects temporary networking, removes the maintenance marker, restores the broker and any touched worker registrations, and exits. The cancellation contract includes an inert process-level test of launcher loss, bounded-operation completion, skipped next mutation, and cleanup; it does not manipulate a VM.

The updated checkpoint remains a candidate while a versioned immutable pool base is created. Workers are renamed to rollback registrations and replaced one at a time; each replacement is the only running worker while Windows build, .NET SDKs, interactive guest agent, reboot state, shutdown, and disconnected networking are verified. Only then is the candidate checkpoint promoted, the broker repaired, the pool audited, and the isolated canary run.

If a post-promotion client or verification failure rolls this transaction back but leaves the updated checkpoint and audited pool generation intact, do not repeat Windows Update. Review a new plan with the exact failed update identifier and then resume with the otherwise unchanged approved parameters plus `ResumeUpdateId = '<YYYYMMDDTHHMMSSFFFZ>'`. Resume is accepted only in manual guest-restart mode and only when the active definition still exactly matches the archived rollback definition, the baseline is off, the failed checkpoint is a direct child of the canonical rollback checkpoint, its `ReadyToSeal` servicing record proves the approved SDK and clean shutdown, and the privileged audit matches the immutable base and all four disconnected differencing disks. It does not boot or service the baseline. It re-registers and boot-verifies the retained workers sequentially, promotes and restores the retained checkpoint only after all four pass, then repeats broker audit, isolated canary, and recovery refresh. Any failure restores the original checkpoint, registrations, and broker definition while retaining the generation for diagnosis.

`Recovery\Current` remains untouched until live verification succeeds. The updater can archive the older `Recovery\Previous`, builds a staged image export, deep-hash verifies every recorded file, rotates the former Current to Previous, and promotes the new bundle atomically. Prior pool disks and the old definition remain local as a dated rollback generation; they are never published.

For GitHub disaster recovery, the same guest-servicing component runs only when a new baseline is built from official media. The public repository stores the resolver, servicing logic, tests, and documentation—not SDK installers, Windows updates, VM images, credentials, logs, or evidence.

## Refresh the fast local recovery image

Run `REFRESH-LOCAL-RECOVERY.cmd` after an intentional baseline, sizing, guest-agent, broker, or runtime-skill change. The command drains the queue, enters maintenance, stops workers, exports the baseline, snapshots current software and the sanitized Codex policy, computes checksums, verifies staging, rotates `Current` to `Previous`, and resumes the broker.

The recovery directory keeps two generations by default. Stale staging directories are garbage-collected. Payload cache garbage collection remains broker-managed and independent of recovery generation rotation.

## Verify

`VERIFY.cmd` performs the privileged pool audit, checks the broker pointer/task and installed skill, runs an isolated canary unless skipped, and structurally verifies the current recovery bundle. Pass `-DeepRecoveryVerification` to hash every recovery file; the default is intentionally faster for a multi-gigabyte baseline export.

## Update source

Pull or download a new repository revision, run the public-safety check, and run `setup\Install.ps1 -PlanOnly` with every selected value. For an existing installation, the plan reports the exact installed-configuration SHA-256 and must say `RequestNetworkPolicyDisposition = PreservedExisting`. After separate approval, rerun the same parameters without `-PlanOnly`, add that exact hash as `ExpectedExistingConfigurationSha256`, and do not use `-ForceRebuild`. The installer revalidates the fingerprint before source staging, excludes `harness-config.json` from source mirroring, and atomically replaces the configuration while preserving the complete schema-valid `RequestNetworkPolicy`. A matching baseline is reused while source, canaries, pool definition, broker, skill, audit, and local recovery are refreshed.

Configuration drift, malformed JSON, an incompatible configuration identity, and a missing configuration or missing/malformed installed request-network policy fail closed without rewriting the file. Existing Live, Recovery, Harness, or Setup state is not treated as a first installation when `harness-config.json` is absent. `ResetRequestNetworkPolicy` is an intentional recovery operation, not a refresh fallback: its PlanOnly result must say `ResetToFailClosed`, it needs a separately approved exact configuration fingerprint, and applying it disables `InternetOnly` and `TrustedLan` by replacing the installed policy with generic fail-closed defaults.
