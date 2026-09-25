# Installer UAC V2

Use `-InstallerUacPlanPath` for a directly launched, initially medium-integrity installer that self-elevates the same original executable through UAC. Submit its canonical directory with `-ArtifactPath` and `-ExecutableRelativePath`; include a distinct diagnostic verifier executable in that directory. The runner binds the installer to its payload manifest. This mode is disconnected and cannot combine ordinary actions, screenshots, legacy system prompts, guest setup, host inputs, restart plans or legacy result assertions.

```json
{
  "FormatVersion": 2,
  "Decision": "Accept",
  "InitiatingUser": "StandardUser",
  "PromptTimeoutSeconds": 120,
  "ExpectedExitCode": 0,
  "Verifier": {
    "Purpose": "ReadOnlyObservation",
    "ExecutableRelativePath": "InstallerVerifier.exe",
    "ExecutableSha256": "REPLACE_WITH_EXACT_UPPERCASE_SHA256",
    "Arguments": ["{PHASE}", "{IDENTITY_FILE}", "{VERIFIER_OUTDIR}"],
    "TimeoutSeconds": 120,
    "ResultFile": "result.json",
    "JsonPointer": "/passed",
    "EqualsJson": true
  },
  "PrivilegedObservations": [
    {"Name": "ProductConfig", "Root": "AdministratorProfile", "RelativePath": "AppData\\Local\\Product\\config.json"}
  ]
}
```

`Decision` is `Accept` or `Decline`. `InitiatingUser` is `ManagedAdministrator` (the existing interactive administrator's filtered medium token) or `StandardUser` (a newly created non-administrator with a real interactive logon and a different disposable administrator). Standard mode performs one preparation reboot before testing. It creates actual profiles and binds their paths to account SIDs. Preparation disables automatic restart sign-in and locking within the disposable guest. Before either verifier or installer starts, a console-session helper must observe both an unlocked session and the `Default` input desktop; Explorer presence alone does not establish readiness after first sign-in. Request cancellation/deadline remains active; interrupted submissions are terminal and never replayed.

The verifier runs as the initiating user in separate `Before` and `After` output directories. It must exit zero and write the declared JSON file (maximum 1 MiB). A false JSON assertion or unexpected installer exit is a test failure; failure to establish identities, handle UAC or collect verification is a harness failure. Both phases finish before privileged process cleanup and VM disposal. Each identity file contains `RequestId`, `Phase`, `Identity.Initiator`, `Identity.ElevationAccount` (each `Name`, `QualifiedName`, `Sid`, `ProfilePath`) and `PrivilegedObservations`. Treat phases as independent observations; the controller retains its own Before receipt. `{PAYLOAD}` is also available in verifier arguments. No credential token is available.

`ReadOnlyObservation` declares diagnostic intent, not an OS sandbox for the verifier. Product status queries may use their normal mechanism, including demand-starting an already installed helper. The verifier must not install, repair, change configuration, request elevation or input credentials. Keep product-specific commands and expected behavior in the verifier, outside the harness.

Privileged observations permit at most 32 declared exact paths below `InitiatorProfile`, `AdministratorProfile` (standard mode only), `ProgramData` or `ProgramFiles`. They report `Name`, `Path`, `Status`, `Kind`, `OwnerSid`, `Sddl`, `Sha256`, `Length` and `ErrorCode`. Directory observation is nonrecursive. File observation returns metadata/hash, never contents (maximum 1 GiB). Only file/path-not-found means `Absent`; permission and sharing failures remain `AccessDenied`/`Unobservable`. Reparse traversal is refused. No target ACL is weakened. Private harness state is excluded.

Before input, the controller retains hash-verified handles for both executables and requires a fresh native UAC event naming the original executable and a live observed requester in its process tree. The event emitter must be the exact signed consent process in the initiating session. If Windows defers the prompt on the normal desktop, the handler may send an activation message to the single visible native interim window owned by that exact consent process. Message delivery alone does not establish prompt readiness. Credentials and decisions still require the attributed consent process in the secure desktop foreground and positively identified controls. Unknown, stale, ambiguous or mismatched prompts fail closed. Acceptance requires a separately observed elevated instance with the expected administrator SID; decline requires no such instance. This contract covers self-elevation of the same executable, not arbitrary child installer packages, auto-elevation, additional prompts or installer-triggered reboots.

Disposable passwords are generated inside the guest. A standard-account preparation password is removed from temporary autologon configuration before the first verifier runs. The administrator credential is machine-DPAPI protected in private guest state, decrypted only by the SYSTEM secure-desktop handler and erased before After. No credential is included in the request, process arguments, verifier identity, exported evidence or screenshots; all live capture is disabled for V2. Accounts and private state disappear with the disposable VM disk. These are broker-owned observations within the isolated guest, not cryptographically signed attestations or protection against malicious guest administrators.

Require `HarnessSucceeded`, `InstallerUacContractProven`, `TestEvaluated`, `TestPassed`, final VM `Off` and `PayloadChildDeleted`. The receipt includes process creation identities, session/token facts, the attributed prompt, decision, Before/After records and cleanup order. An explicit UAC decline is distinct from cancelling the broker request. Do not substitute pre-elevated wrapper tests for this contract.
