---
name: hyperv-test-executables
description: Test Windows application artifacts in the isolated Hyper-V harness. Use automatically for .exe/.msi, Electron, packaged desktop or CLI apps, installers, Windows integration, or native UI testing when a browser is not faithful. For explicit named host tests, use computer use instead; never use this harness on the physical host.
---

# Hyper-V executable testing

Keep applications-under-test off the physical host by default. Build on the host when useful, then submit the canonical build output to the SYSTEM broker. Never relocate the normal output, pre-copy it into broker staging, select a worker VM, restore checkpoints, or manage pool VMs directly.

## Route the test

1. Use browser automation for a pure web application only when it can faithfully test the requested behavior.
2. Honor an explicit user request to run or control a named artifact on the physical host. Natural wording such as "run this on the host" or "test it locally, not in Hyper-V" is sufficient; scope the override to that artifact and test. Do not infer it from generic wording such as "run it." For that test, give precedence to the computer-use skill and its tools. Never use this harness on the physical host. If computer use is unavailable, report that limitation.
3. Otherwise use this skill for every application-under-test, including `.exe` and `.msi` files, packaged CLI/desktop apps, Electron, WebView2, tray behavior, installers, Windows integration, and VM network-boundary testing. Electron is native testing, not the browser exception.
4. Never silently fall back to physical-host execution. Stop and report a broker, VM, or capability failure.

Trusted compilers, linkers, package managers, linters, and non-application test runners may run on the host when they do not launch the application-under-test or interact with the host desktop.

## Load only the guidance needed

Do not preload every reference.

- For interaction actions, result assertions, reserved tokens, screenshots, or locked-host proof, read [artifact invocation and actions](references/artifact-and-actions.md).
- For any auxiliary host input or non-default networking, read [network and host inputs](references/network-and-host-inputs.md) before constructing the request.
- For an application expected to shut down its disposable guest, read [expected guest power-off](references/expected-guest-power-off.md). That mode has a distinct no-replay evidence contract.
- For shared queue use, a long request, live evidence, cancellation, or deadline behavior, read [queue, observation, and cancellation](references/queue-observation-and-cancellation.md).
- For payload-cache behavior, pool internals, lifecycle recovery, or performance diagnosis, read [broker, pool, and cache internals](references/broker-pool-and-cache.md).
- Before claiming any test result, read [verification and reporting](references/verification-and-reporting.md) and apply the sections relevant to the request.

## Run the artifact

Use `scripts/Invoke-HyperVExecutableTest.ps1`.

- For a standalone executable, pass its file path with `-ArtifactPath`.
- For Electron or another multi-file package, pass its directory with `-ArtifactPath` and the executable path relative to that directory with `-ExecutableRelativePath`.
- Pass application arguments with `-Arguments`. In arguments and ordinary string-valued actions, `{PAYLOAD}` resolves to the attached payload root and `{OUTDIR}` to the persistent guest evidence directory. Do not assume guest drive letters.
- Omit `-ActionsPath` for a basic launch-and-screenshot smoke test. Supply an actions JSON file for interaction.
- General networking is opt-in. Omit `-NetworkProfile` or use `None` for a disconnected VM. Never substitute or create networking when the requested profile is unavailable.
- Add `-RequireHostLocked` only when the test specifically requires proof that the workstation remained locked. VM isolation itself does not require locking the host.
- Queue and execution deadlines are independent. Their defaults are 30 and 15 minutes respectively; waiting in the FIFO queue does not consume the execution budget.

Basic package example:

```powershell
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\MyElectronApp' `
  -ExecutableRelativePath 'MyElectronApp.exe' `
  -Arguments '--fixture "{PAYLOAD}\fixture-project"' `
  -ActionsPath 'D:\build\vm-actions.json'
```

`ArtifactPath` is the stable payload-cache identity. The broker fingerprints the tree, reuses stored SHA-256 values for unchanged files, creates an immutable cached generation when needed, and gives each request its own disposable child. PowerShell Direct carries control JSON and evidence, not application payload trees.

The broker owns isolation, queueing, worker selection, payload transport, optional networking, evidence collection, process-tree cleanup, VM power-off, and child deletion. Do not bypass those boundaries.

## Finish with evidence

Treat harness execution and application evaluation as separate facts. A clean smoke run without an assertion proves the harness path ran; it does not establish application acceptance. When behavior matters, use an application-produced result assertion and retain the requested screenshots or files.

Before reporting success, apply [verification and reporting](references/verification-and-reporting.md), visually inspect relevant screenshots, and state what was actually evaluated. Stop and explain if the test requires physical hardware, drivers, host services, or another capability the isolated VM does not provide.
