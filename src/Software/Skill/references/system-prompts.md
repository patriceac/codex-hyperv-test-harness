# System-prompt acceptance

Read this reference only when the application-under-test is expected to display a startup UAC consent prompt or a Windows Firewall network-access prompt inside its disposable VM.

Opt in explicitly:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\PromptedApp.exe' `
  -AcceptUacPrompt `
  -AcceptWindowsFirewallPrompt `
  -WindowsFirewallProfiles Private `
  -SystemPromptTimeoutSeconds 120 `
  -AssertResultFile '{OUTDIR}\result.json'
```

The runner binds the request to the payload manifest's exact executable path and SHA-256. The broker accepts prompts in the declared order: startup UAC first, then Windows Firewall. UAC input is sent through the Hyper-V virtual keyboard because the secure desktop is intentionally outside the guest agent's UI Automation and `SendInput` desktop. The broker accepts only a new, unique `consent.exe` observed while the guest agent's exact `Start-Process` call is still blocked; afterward it requires the exact hashed application process and an elevated token.

For a Windows Firewall prompt, the broker requires the exact application process first, then a new, unique Windows firewall UX host. It creates only enabled inbound `Allow` rules for the exact application path and the requested `Private` and/or `Public` profiles, verifies them, and dismisses the stale notification. It never disables the firewall, changes UAC policy, accepts a generic prompt, or creates an `Any program` rule.

Both modes are fail-closed and versioned. They cannot be combined with `-ExpectGuestPowerOff` or `-GuestSetupProfile`. A requested prompt that never appears, appears more than once, has the wrong ordering, outlives its timeout, or fails its executable/token/rule verification fails the harness run. Results include ordered acceptance evidence plus before/after VM framebuffer screenshots. These switches never authorize prompts on the physical host.

`WindowsFirewallProfiles` defaults to `Private` and accepts only unique `Private` and `Public` values. A firewall prompt still depends on Windows actually presenting one. `IsolatedTestNet` deliberately exempts its request adapter from the Private firewall and therefore is not a suitable live proof of the native firewall prompt.
