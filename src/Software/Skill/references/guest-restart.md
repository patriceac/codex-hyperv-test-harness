# Restart continuation and sign-in fixtures

Use `-GuestRestartPlanPath <local-json>` for an application that restarts Windows. This selects `RunGuestJobPowerTestV1`; ordinary requests are unchanged. A request retains one worker lease, its payload paths, `{OUTDIR}`, network profile and cohort until final evidence/cleanup. The harness never issues the restart. It launches the initial executable once and each explicitly declared continuation at most once after a different observed Windows boot. A continuation should observe the product resumed by its own startup mechanism. It must not relaunch that product unless that is explicitly the intended test.

Pass a final `-AssertResultFile '{OUTDIR}\final.json'` and optional JSON assertion. The final assertion applies after the last continuation. Omitted initial actions and empty continuation actions wait for that phase's result marker. Every nonfinal phase must atomically write and close a distinct marker before restarting. The broker checks its assertion and that its timestamp belongs to the preceding phase and predates the new boot.

```json
{
  "FormatVersion": 1,
  "Boots": [{
    "ExpectedSignIn": "Manual",
    "BootTimeoutSeconds": 180,
    "SignedOutObservationSeconds": 15,
    "BeforeRestart": {
      "ResultFile": "{OUTDIR}\\before-boot-1.json",
      "JsonPointer": "/passed",
      "EqualsJson": "true"
    },
    "Continuation": {
      "ExecutableRelativePath": "Lab.exe",
      "ExecutableSha256": "<EXACT_UPPERCASE_SHA256_FROM_CANONICAL_PAYLOAD>",
      "Arguments": "after-restart --out \"{OUTDIR}\"",
      "Actions": []
    }
  }]
}
```

One to four boots are allowed. `Automatic` requires zero signed-out observation seconds; the application must establish its own sign-in. `Manual` requires 10–3900 seconds of observed signed-out console state, then the broker enters the managed guest credential once through the Hyper-V virtual keyboard. No autologon is enabled for manual input. Boot/sign-in transition timeout is 30–900 seconds, separate from the requested signed-out interval. All work stays within the original execution timeout (maximum 7200 seconds), and existing cancellation remains authoritative. Unknown observation is never treated as signed out. Unexpected boots, sign-in, interrupted delivery, or broker/agent recovery fail terminally; they never replay a power action.

Before setup/initial launch, only the disposable guest loses baseline `AutoAdminLogon`, `AutoLogonCount`, registry/LSA `DefaultPassword`, and automatic restart sign-on. Preboot evidence positively identifies an unencrypted OS volume, TPM-only encryption, or fully encrypted clear-key provisioning with protection off and no configured key protectors; clear-key provisioning is not encryption-at-rest protection. It also checks login-banner/smart-card policy. Unsupported or unknown preboot state fails the restart fixture. PowerShell Direct observes boot identity and the WTS console user independently of the interactive agent. A signed-out VM framebuffer is captured before manual password input.

`None` and `IsolatedTestNet` are supported. Host inputs, system-prompt handling and `ExpectGuestPowerOff` cannot be combined with this contract. Existing `GuestSetup` may install/provision the app and exact guest firewall rules before its initial launch; it is not repeated after boots. Installed-app shutdown instead uses `GuestSetup` plus the unchanged expected-power-off contract.

For `IsolatedTestNet`, prelaunch setup persists Private classification for identifying and unidentified networks only inside the disposable guest with its sole connected leased adapter. This Network List Manager policy applies during boot, before autonomous startup. Each new signed-in boot must pass a bounded read-only network check before continuation; `GuestRestart.NetworkChecks` retains the boot, policy and before/after state. Category, exemption, address, route, DNS, IPv6 or interface drift fails at `GuestRestartNetwork` without late repair, changing product rules or replaying a phase. Release acceptance observes the active Private firewall profile from both autonomous RunOnce starts; firewall prompts are never accepted by this path.

## Protected credential input

Opt in with `-GuestCredentialFixture` only when the test must enter the disposable account's real password into a product dialog. It can be used on a controller request without a restart plan. `{GUEST_CREDENTIAL_FILE}` resolves in arguments, continuation arguments and guest-setup arguments to a request-private file outside payload/evidence directories. Its ACL grants only the guest SID and SYSTEM access. It is discarded with the OS child.

The UTF-8 JSON fields are `FormatVersion:1`, `UserName`, `UserSid`, `PoolBaselineId`, `Protection:"DPAPI CurrentUser"`, and `ProtectedPassword` (base64). Decrypt with Windows `ProtectedData.Unprotect`, null entropy, `DataProtectionScope.CurrentUser`; decode UTF-8. Keep the plaintext in memory solely for the intended password control, then clear its buffers. Never place it in argv, logs, screenshots, results or copied evidence.

Managed workers authenticated by this broker and cloned from the same `PoolBaselineId` share the automation account/SID and protected baseline credential. A peer test must compare the target's non-secret `UserSid`, `UserName` and `PoolBaselineId` before using its local fixture for that target; this guarantee does not cover an account changed by test setup or the product. Non-secret metadata and preboot evidence are returned in `GuestPowerFixture` / `broker-guest-power-fixture.json`. `GuestRestart` / `broker-guest-restart.json` records ordered boots, phase delivery, marker times and sign-in observations; require `GuestRestartContractProven=true` plus the ordinary harness/test success and cleanup proof.
