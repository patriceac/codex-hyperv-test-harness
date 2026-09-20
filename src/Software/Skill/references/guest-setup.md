# Request-scoped guest setup

Use this contract when a native test needs one bounded elevated setup executable to finish successfully inside the disposable guest before the normal application starts. Product commands, receipts, installed paths, services, publishers, and behavioral assertions remain in the product's test scenario; the harness understands only the request-bound executable identity and execution result.

```powershell
$setup = 'D:\build\MyPackage\tools\Setup.exe'
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\MyPackage' `
  -ExecutableRelativePath 'tests\MyPackage.Lab.exe' `
  -GuestSetupExecutableRelativePath 'tools\Setup.exe' `
  -GuestSetupExecutableSha256 (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash `
  -GuestSetupArguments @('configure', '--test-mode') `
  -GuestSetupTimeoutSeconds 120 `
  -AssertResultFile '{OUTDIR}\result.json'
```

The versioned request operation is `RunGuestJobSetupV1`. The artifact must be a directory. The runner requires a traversal-free `.exe` path and exact SHA-256, then the broker independently binds both to exactly one canonical payload-manifest entry. Immediately before execution, the broker hashes the mounted file, copies only that executable into an ACL-protected per-request staging directory, hashes the copy, and runs it through the guest's administrator Hyper-V Direct session. A zero exit code is required before the normal medium-integrity application is submitted to the guest agent.

Arguments are an exact JSON string array: at most 16 values, 1024 characters each, and 4096 characters total. NUL and line breaks are rejected. The setup timeout is bounded from 5 through 600 seconds and remains inside the request's overall execution deadline. The staged executable is intentionally standalone; setup programs that need sidecar files should package them into one executable or make their own payload-relative data available through an explicit future contract rather than assuming the staging directory contains the artifact tree.

Guest setup permits only `None` and `IsolatedTestNet`. It cannot be combined with read-only host inputs, expected guest power-off, or system-prompt acceptance. It never accepts a UAC dialog: elevation comes only from the already protected SYSTEM broker's administrator guest session, and all changes disappear with the disposable OS child.

Successful evidence is written inside the VM to `C:\ProgramData\CodexHarness\GuestSetup\<RequestId>\guest-setup.json` for the application scenario to inspect and copied to `broker-guest-setup.json` in the terminal result. The version-1 object records the exact relative path, requested and staged SHA-256 values, arguments, timeout, process and timestamps, administrator identity, bounded stdout/stderr, truncation flags, exit code, and `Succeeded=true`. Product tests must independently evaluate any product-specific receipt or installed state.

The broker still owns request networking, process/evidence collection, VM power-off, payload-child deletion, network teardown, and worker recycling. A failed or timed-out setup prevents the normal application from launching and fails the harness request.
