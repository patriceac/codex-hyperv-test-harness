# Security model

## Trust boundaries

- **User/Codex client:** may submit artifacts and automation actions through the runtime skill.
- **SYSTEM broker:** validates the contract and performs privileged Hyper-V, VHD, ACL, queue, and cleanup operations.
- **Disposable guest:** runs untrusted applications on an interactive virtual desktop. It is not a security boundary against a hostile Windows kernel exploit, but it prevents ordinary applications and UI automation from touching the physical desktop.
- **Read-only host input:** a caller-selected host path may be exposed to one guest run as read-only. There is intentionally no fixed allowlist; the broker must enforce read-only access and request-scoped teardown.

Workers are network-disconnected by default through the `None` profile. The host-input transport creates only the narrow ephemeral connectivity needed for its read-only path. General networking is always explicit and uses a named broker-authorized profile:

- `IsolatedTestNet` joins only an explicit test cohort on a private VM-only switch. Inside each disposable guest, only that request adapter is classified Private and an actively enforced inbound rule is bound to its exact interface, local address, and cohort subnet. It must not route to the host, LAN, or Internet.
- `InternetOnly` is disabled until a pinned internal switch and the host's sole WinNAT instance are approved. The NAT must be active, have no static inbound mappings, use the exact address-dependent TCP/UDP filtering policy with inbound UDP refresh disabled, and retain its pinned routing-domain, prefix, and timeout values. The switch gateway is the sole management-OS adapter and must use one exact `Promiscuous` private-VLAN pair; every request adapter uses the matching `Isolated` pair. This blocks peer-guest layer-2 traffic but necessarily leaves the host gateway reachable for Ethernet/ARP control traffic; it is not a raw-layer-2 host-isolation claim. Exact weighted extended ACLs give only the assigned guest IPv4 source stateful outbound TCP/UDP, put NAT/private/special/current-host destinations ahead of those allows, and default-deny inbound and outbound IP. Basic port ACLs must be empty, IPv6 is disabled in the guest, and the whole policy is revalidated while the request runs. It is not equivalent to, and must not silently select, the Hyper-V `Default Switch`.
- `TrustedLan` is disabled until the exact external switch name, ID, single physical-interface GUID/description, and management-OS sharing state are allowlisted. Switch Embedded Teaming is not accepted in the v1 profile. It intentionally exposes the guest to the full reachable LAN and must be described that way at request time.

Every non-`None` request uses `RunGuestJobNetworkV1`, so an older broker fails closed. The client cannot name a switch: only profile, optional isolated cohort, and host-input acknowledgement cross the request boundary. Raw switch/NAT/DNS/route/firewall objects are rejected, and enabled `TrustedLan` policy must resolve to exactly one broker-pinned external switch. Broker validation is authoritative even when the runtime skill already validated the request.

A read-only host input using `Share` cannot coexist with a general network profile. With explicit `-AllowNetworkWithHostInputs`, `Auto` is forced to the immutable VHDX transport; otherwise the combined request is rejected. This keeps the SMB-only internal adapter and a general-purpose adapter from sharing a guest network context.

An authorized run receives a persisted request-owned adapter lease in a SYSTEM/Administrators-only state directory. The broker creates the adapter disconnected, applies guards plus the exact VLAN and ACL policy, waits for the guest control channel, revalidates the host policy, and only then connects. Before launch the guest must attest its exact approved address, routes, DNS, gateway neighbor, and IPv6 state where applicable. The broker rechecks mutable host policy during long runs, disconnects first during cleanup, refuses name-only cleanup when VM or switch IDs changed, fails closed when its authoritative lease or Hyper-V inventory cannot be established, reconciles orphan leases after process or host interruption, and publishes terminal evidence only after proving final disconnection and lease deletion.

No switch, NAT, firewall policy, or profile allowlist is enabled merely by updating this source. Deployment remains subject to the setup-harness informed-consent proposal, plan-only preflight, and second approval before privileged host changes.

Baseline servicing is a separate, approval-gated exception. Only the canonical baseline may connect to the exact Hyper-V switch named in the reviewed plan, and only while obtaining Microsoft Windows updates. .NET installers are downloaded on the host from approved Microsoft HTTPS metadata, checked against the published SHA-512 value and a valid Microsoft Authenticode signature, then copied through PowerShell Direct. The updater disconnects every baseline adapter before checkpoint creation and verifies that all workers remain disconnected. It excludes preview updates, drivers, feature-version upgrades, and preview SDKs.

## Privileged material

The locally generated guest credential is stored in ACL-restricted files and is embedded in the local unattended seed ISO. Both are recovery secrets even though the VM is disposable. Never publish either. The baseline export and VHDX cache may also contain application data and screenshots.

The public repository contains source only. `setup\Test-PublicRepository.ps1` enforces the release boundary.

## Host override

The installed Codex policy defaults native application testing to Hyper-V, but the user remains in control. A clear request to test a named artifact on the physical host overrides isolation for that named test only. The runtime does not require a magic phrase and does not carry the override forward.
