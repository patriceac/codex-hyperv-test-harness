<!-- BEGIN CODEX HYPERV TEST HARNESS -->
## Isolated executable testing

- By default, test applications-under-test through the `hyperv-test-executables` skill and its Hyper-V SYSTEM broker, not on the physical Windows host. This covers `.exe`/`.msi`, Electron and packaged desktop or CLI apps, installers, and scripts under test. Browser-faithful web tests and trusted build/unit-test tools may run on the host.
- A clear request to test a named artifact on the host is a test-scoped override; never infer it from generic wording such as "run it." For that explicitly authorized test, prefer the guarded host controller provided by `hyperv-test-executables` over general computer-use tools. Never fall back to host execution after a broker or VM failure.
- Submit the canonical artifact path. Do not pre-copy payloads or manage worker VMs, checkpoints, networking, transport, or cleanup directly. Keep test VMs disconnected unless the test explicitly needs an approved network profile.
<!-- END CODEX HYPERV TEST HARNESS -->
