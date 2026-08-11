# Testing and canary provenance

## PoolCanary

`src\Software\Canaries\PoolCanary.cs` is the source for the tiny WinForms application used by pool concurrency, installation smoke, recovery smoke, and manual visual checks. It displays `ISOLATED WORKER READY`, states that it launched from the disposable payload VHDX, and closes automatically. It performs no filesystem, registry, process-spawn, or network work.

The earlier local harness retained only `PoolCanary.exe` in its canonical canary directory even though the original C# source survived in a development scratch directory. This repository restores that source as canonical and forbids committed executable output. `setup\Build-Canaries.ps1` rebuilds it and the three other canaries locally.

The guest `InputProbe.exe` had the same source-provenance gap. Its C# source and guest installer are now published; `Build-GuestTools.ps1` compiles it before seed creation and reliability testing.

## Test layers

1. `setup\Test-PublicRepository.ps1` enforces the public source boundary.
2. `setup\Test-Source.ps1` parses every PowerShell file, compiles four canaries plus the guest probe, creates and mounts an IMAPI ISO, and runs 110 deterministic scenarios across guided-recovery consent and reference configuration, queue atomicity, canonical broker ACL enforcement and audit, fail-closed installation rollback, lifecycle truthfulness, cancellation/reporting, guest protocol, evidence retries, warm-spare behavior, pool fault recovery, host-input safety, token expansion, metadata-only payload fingerprint reuse, transport selection, and runner contract validation.
3. `Get-OfficialWindows11Iso.ps1 -ResolveOnly` proves that the current Microsoft page can issue an x64 multi-edition link without downloading eight gigabytes in routine source CI.
4. `setup\Verify.ps1` runs the privileged installed-pool audit and a visual canary through the Hyper-V broker. It never launches the canary on the physical host.
5. Live host-input and four-way concurrency tests remain installed under `Software\Harness\tests`; they require an actual Hyper-V pool and are not suitable for GitHub-hosted CI.

GitHub Actions runs layers 1 and 2. A release should also have current local evidence for layers 3 and 4.
