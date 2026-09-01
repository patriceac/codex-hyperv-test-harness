<!-- BEGIN CODEX HYPERV TEST HARNESS -->
## Isolated executable testing

- By default, do not launch, install, or interactively test an application-under-test on the physical Windows host. Route native Windows artifacts through the `hyperv-test-executables` skill and its Hyper-V SYSTEM broker.
- This includes `.exe` and `.msi` files, Electron and packaged desktop apps, CLI artifacts, installers, and scripts when the script itself is under test. Browser-only behavior may be tested in a browser.
- The user may explicitly override isolation for a named test by asking to run that artifact on the physical host. Scope the override to that artifact and request only.
- For an explicitly authorized physical-host application test, prefer the guarded host controller provided by `hyperv-test-executables` over general computer-use tools whenever it supports the required interaction.
- Trusted build tools and non-application unit-test runners may run on the host when they do not launch the application-under-test or interact with the host desktop.
- Submit the canonical artifact path to the skill. Do not pre-copy payloads, target a worker VM, restore checkpoints, or manage pool VMs directly.
- Keep test VMs network-disconnected unless a test explicitly requires network access. Never silently fall back to host execution.
<!-- END CODEX HYPERV TEST HARNESS -->
