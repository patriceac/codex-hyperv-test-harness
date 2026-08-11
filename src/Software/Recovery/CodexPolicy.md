<!-- BEGIN CODEX HYPERV TEST HARNESS -->
## Isolated executable testing

- By default, do not launch, install, or interactively test an application-under-test on the physical Windows host. Route native Windows artifacts through the `hyperv-test-executables` skill and its Hyper-V SYSTEM broker.
- Browser-only behavior may be tested in a browser. The user may explicitly override isolation for a named artifact and test; scope that override to the request.
- Trusted build tools and unit-test runners may run on the host only when they do not launch the application-under-test or interact with the host desktop.
- Submit the canonical artifact path. Do not pre-copy payloads, target worker VMs, restore checkpoints, or manage the pool directly.
- Keep workers network-disconnected unless a test explicitly requires network access. Never silently fall back to host execution.
<!-- END CODEX HYPERV TEST HARNESS -->
