# Dedicated Remote Debugger acceptance pool

This optional pool tests a managed Remote Debugger installation without elevating its visible application or changing the shared harness image. It uses a separately copied, known local recovery export, separately named worker VMs, its own broker task and storage root, and a protected `BrokerInstanceId` namespace. The global Codex broker location remains unchanged.

The dedicated baseline contains the existing Windows and guest-agent environment. Product provisioning occurs in each disposable guest, before the normal payload job. This permits tests against different signed application builds while keeping every run independent.

## Review and installation

`setup/Install-RemoteDebuggerAcceptancePool.ps1` owns the dedicated setup. Use its `PlanOnly` mode first, review the exact source and recovery fingerprints, target names, resource allocation, publisher pin, approved executable hashes, and preservation checks, then authorize the corresponding apply operation. Apply must match the reviewed plan hash and refuse existing target assets rather than replacing them.

No Windows media is downloaded, no guest update network is required, and neither the shared baseline nor its worker registrations are replaced. The known recovery credential is copied as an opaque administrator-protected file during setup. Do not log or publish it. All images, credentials, plan outputs, application binaries, test results, and screenshots remain local and outside Git.

The dedicated network policy enables only disconnected jobs and private `IsolatedTestNet` cohorts. Internet, trusted-LAN profiles, and read-only host-input attachments are unavailable to provisioned jobs.

## Provisioned job contract

The runner accepts `GuestSetupProfile=RemoteDebuggerProvisionV1`, `GuestSetupExecutableRelativePath`, and `GuestSetupExecutableSha256`. It verifies the source fixture path and hash before submission. It serializes the new `RunGuestJobProvisionedV1` operation and this bounded object:

```json
{
  "RemoteDebuggerProvisionV1": {
    "FixtureRelativePath": "release\\RemoteDebugger.exe",
    "ExpectedSha256": "<64 hexadecimal characters>"
  }
}
```

Older brokers reject the new operation. Ordinary jobs omit the object and retain their existing behavior. The protected broker configuration must explicitly enable the profile, pin the publisher's SHA-256 fingerprint, and allowlist each accepted executable SHA-256. The request supplies no administrator command, script, account, installer argument, or executable outside the payload. Both `ResetToBaseline` and `StopAfter` must be exact Boolean `true`.

After validating the request and payload, the broker uses its administrator PowerShell Direct session to verify and stage the exact approved fixture and invoke the fixed `cli platform-provision` command inside the disposable guest. It validates the managed binary, product receipt, registered user, and LocalSystem service. The normal job remains the payload Lab executable running in the interactive user's medium-integrity session. Lab launches the protected managed product and verifies the resulting process identity.

This is evidence for an administrator-provisioned deployment. It does not simulate or prove a person's first interactive UAC consent.

## Evidence and observation

Provisioning writes a protected receipt under `C:\CodexGuest\Provisioning\<request-id>\remote-debugger-provisioning.json`. The registered user can read it. This location is separate from the outbox because GuestAgent recreates the outbox when starting a job. Lab validates the receipt and copies it into its collected evidence.

A separate, bounded administrator Direct session continuously records read-only Windows power requests, Remote Debugger firewall rules, and Remote Debugger service state in `remote-debugger-observation.json` beside that receipt. Its commands and paths are fixed in the harness; requests cannot supply observation commands. The observer stops at job completion or the request deadline, and broker cleanup closes its job and session. Lab requires fresh observations and retains the snapshots used for its assertions, including a post-exit observation for sleep-request release.

Required acceptance covers automatic private-network access, normal-user managed launch, automatic maintenance after pairing, direct viewing and input, tray restore, termination, upgrade, downgrade, same-version binary replacement, rollback, and exact controller/client binary equality. Existing real-time pairing-code and disconnect-lifetime tests remain distinct evidence. A successful harness run alone does not prove these application assertions; inspect both `HarnessSucceeded` and `TestPassed`, together with cleanup and evidence-copy results.
