# Security model

## Trust boundaries

- **User/Codex client:** may submit artifacts and automation actions through the runtime skill.
- **SYSTEM broker:** validates the contract and performs privileged Hyper-V, VHD, ACL, queue, and cleanup operations.
- **Disposable guest:** runs untrusted applications on an interactive virtual desktop. It is not a security boundary against a hostile Windows kernel exploit, but it prevents ordinary applications and UI automation from touching the physical desktop.
- **Read-only host input:** a caller-selected host path may be exposed to one guest run as read-only. There is intentionally no fixed allowlist; the broker must enforce read-only access and request-scoped teardown.

Workers are network-disconnected by default. The host-input transport creates only the narrow ephemeral connectivity needed for its read-only path. Tests that need general network access must request it explicitly and should be treated as a broader trust decision.

Baseline servicing is a separate, approval-gated exception. Only the canonical baseline may connect to the exact Hyper-V switch named in the reviewed plan, and only while obtaining Microsoft Windows updates. .NET installers are downloaded on the host from approved Microsoft HTTPS metadata, checked against the published SHA-512 value and a valid Microsoft Authenticode signature, then copied through PowerShell Direct. The updater disconnects every baseline adapter before checkpoint creation and verifies that all workers remain disconnected. It excludes preview updates, drivers, feature-version upgrades, and preview SDKs.

## Privileged material

The locally generated guest credential is stored in ACL-restricted files and is embedded in the local unattended seed ISO. Both are recovery secrets even though the VM is disposable. Never publish either. The baseline export and VHDX cache may also contain application data and screenshots.

The public repository contains source only. `setup\Test-PublicRepository.ps1` enforces the release boundary.

## Host override

The installed Codex policy defaults native application testing to Hyper-V, but the user remains in control. A clear request to test a named artifact on the physical host overrides isolation for that named test only. The runtime does not require a magic phrase and does not carry the override forward.
