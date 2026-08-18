# Testing and canary provenance

## PoolCanary

`src\Software\Canaries\PoolCanary.cs` is the source for the tiny WinForms application used by pool concurrency, installation smoke, recovery smoke, and manual visual checks. It displays `ISOLATED WORKER READY`, states that it launched from the disposable payload VHDX, and closes automatically. It performs no filesystem, registry, process-spawn, or network work.

The earlier local harness retained only `PoolCanary.exe` in its canonical canary directory even though the original C# source survived in a development scratch directory. This repository restores that source as canonical and forbids committed executable output. `setup\Build-Canaries.ps1` rebuilds it and the three other canaries locally.

The guest `InputProbe.exe` had the same source-provenance gap. Its C# source and guest installer are now published; `Build-GuestTools.ps1` compiles it before seed creation and reliability testing.

## Test layers

1. `setup\Test-PublicRepository.ps1` enforces the public source boundary.
2. `setup\Test-Source.ps1` parses every PowerShell file, compiles four canaries plus the guest probe, creates and mounts an IMAPI ISO, and runs deterministic scenarios across guided-recovery consent and reference configuration, image-maintenance approval/pinning/sequential-replacement contracts, queue atomicity, canonical broker ACL enforcement and audit, fail-closed installation rollback, lifecycle truthfulness, cancellation/reporting, guest protocol, evidence retries, warm-spare behavior, pool fault recovery, host-input safety, token expansion, metadata-only payload fingerprint reuse, transport selection, and runner contract validation.
3. `Get-OfficialWindows11Iso.ps1 -ResolveOnly` proves that the current Microsoft page can issue an x64 multi-edition link without downloading eight gigabytes in routine source CI.
4. `setup\Verify.ps1` runs the privileged installed-pool audit and a visual canary through the Hyper-V broker. It never launches the canary on the physical host.
5. Live host-input and four-way concurrency tests remain installed under `Software\Harness\tests`; they require an actual Hyper-V pool and are not suitable for GitHub-hosted CI.

GitHub Actions runs layers 1 and 2. A release should also have current local evidence for layers 3 and 4.

## Network-profile expectations

Pure web behavior should be tested browser-first when that is faithful. Hyper-V tests remain required for native shells, tray behavior, installers, WebView2, Windows integration, and claims about the VM network boundary.

Deterministic source tests must cover the `None` compatibility default, `RunGuestJobNetworkV1` for every non-`None` request, runner schema validation, rejection of caller switch selection and raw network configuration, isolated cohort constraints, exactly one broker-pinned `TrustedLan` switch, host-input `Share` rejection, `Auto`-to-VHDX selection, lease-before-connect ordering, connect-last/disconnect-first lifecycle reporting, cancellation, retry, and orphan reconciliation. They must also prove that terminal result publication follows verified adapter cleanup and that an old broker rejects rather than downgrades a network request.

Live proof is separate. For each enabled profile, exercise both an allowed path and every promised denied path, then cancel or interrupt a run and verify that the VM is off, every adapter is disconnected, and its lease is gone. `IsolatedTestNet` needs positive same-cohort communication plus negative host/LAN/Internet and cross-installation checks. `InternetOnly` needs two concurrent guests; positive public TCP plus UDP/DNS; negative direct guest-to-guest IP, ICMP, TCP, UDP, ARP, broadcast, multicast, and raw-Ethernet paths; confirmation that only the expected Ethernet/ARP exchange with the promiscuous host gateway remains; source-IP/MAC and VLAN-tag spoof attempts; negative host IP, RFC 1918/LAN, NAT-prefix, unsolicited-inbound, IPv6, route-change, and stale-state checks; and exact guest-isolated/gateway-promiscuous private-VLAN attestation against the sole pinned internal-switch NAT. `TrustedLan` needs verification of the logical switch, single physical uplink, management-OS sharing state, and an explicit record of full LAN exposure. Also retain a `None` regression and concurrent-profile isolation test.

`InternetOnly` is not the Hyper-V `Default Switch` and must not be called proven from source inspection or deterministic tests. It requires current live positive and negative evidence from the installed configuration. This source update alone enables no live network-profile infrastructure.
