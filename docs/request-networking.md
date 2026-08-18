# Request-scoped networking

The harness exposes four request-time profiles while keeping `None` as the compatibility default. A test opts into one profile; it never supplies network infrastructure or policy.

| Profile | Request arguments | Boundary |
|---|---|---|
| `None` | no network arguments, or `-NetworkProfile None` | No general network adapter. The separate ephemeral read-only host-input share remains available. |
| `InternetOnly` | `-NetworkProfile InternetOnly` | Public IPv4 TCP/UDP through one exact internal switch and the host's sole mapping-free WinNAT; host, LAN/private, peer, unsolicited inbound, non-TCP/UDP, and IPv6 paths are denied. |
| `IsolatedTestNet` | `-NetworkProfile IsolatedTestNet -NetworkCohort '<LABEL>'` | Requests with the same explicit cohort share an installation-scoped private VM-only switch. No host endpoint, gateway, DNS, LAN, or Internet route exists. |
| `TrustedLan` | `-NetworkProfile TrustedLan` | Full reachability offered by one broker-pinned external switch, including LAN and usually router-provided Internet. It does not promise to inherit a host VPN. |

The runner has no switch-selection parameter. `TrustedLan` policy must contain exactly one switch pinned by its Hyper-V name and ID, one physical adapter GUID and description, and the approved management-OS sharing state. `InternetOnly` similarly pins its switch, NAT, prefix, gateway, VLAN pair, DNS, filtering behavior, and timeouts. Requests cannot provide switch names or IDs, NAT, addresses, routes, VLANs, DNS, or firewall rules.

Every non-`None` request uses `RunGuestJobNetworkV1`. This makes an older broker reject the request instead of ignoring a new field and accidentally running under a different boundary.

## Lifecycle

The broker writes a SYSTEM-only lease before it mutates a VM. It creates the request adapter disconnected, applies guards, private-VLAN state, and the exact weighted extended ACL set, revalidates the pinned host infrastructure, then connects the adapter last. Guest configuration and attestation complete before the application starts.

During `InternetOnly`, the broker periodically verifies the NAT, switch, gateway, VLAN and ACL state, current host routes and addresses, and the complete default-route interface identity. A VPN/default-route change fails closed rather than silently changing the approved egress boundary.

Cleanup reverses the order: disconnect first, remove the adapter and lease, verify every VM adapter is disconnected, and only then publish terminal evidence or recycle the worker. Startup and periodic orphan reconciliation use exact VM/adapter lease ownership; a managed-looking name alone never authorizes deletion.

Combining general networking with `-ReadOnlyHostInput` requires `-AllowNetworkWithHostInputs`. Explicit `Mode=Share` is rejected, and `Mode=Auto` is forced to the immutable read-only VHDX transport.

## Source defaults and host policy

Fresh generic configuration records:

- `DefaultProfile=None`;
- `IsolatedTestNet` enabled with `10.254.0.0/24` and installation-scoped private switches;
- `InternetOnly` disabled until exact internal-switch/NAT infrastructure is pinned;
- `TrustedLan` disabled until one exact external switch and physical uplink are pinned.

Enabling the latter two is a separate privileged backend-policy update. Host-specific policy JSON, fingerprints, deployment receipts, and endpoint inventories stay outside Git.

Run the non-elevated discovery preflight with explicit intent:

```powershell
& .\setup\Test-PublicRepository.ps1
& .\setup\Update-RequestNetworking.ps1 `
  -InstallRoot '<EXACT_INSTALL_ROOT>' `
  -InternetSwitchName 'Codex Test NAT' `
  -InternetNatName 'Codex Test NAT' `
  -InternetNatPrefix '172.30.250.0/24' `
  -InternetGatewayAddress '172.30.250.1' `
  -InternetPrimaryVlanId 2500 `
  -InternetSecondaryVlanId 2501 `
  -TrustedLanSwitchName 'Codex Trusted LAN' `
  -TrustedLanPhysicalAdapterName 'Wi-Fi' `
  -PlanOnly
```

This call never elevates or writes. If Hyper-V identity is unavailable to the unelevated account, it reports that limitation and returns no approval fingerprint. An elevated read-only pass, separately approved, must resolve exact switch, management-adapter, NAT, gateway, VLAN, physical-uplink, route, and idle-pool identities. A fully populated local policy can then be supplied with `-PolicyPath`; only an approval-ready plan receives a fingerprint.

When the pinned switches, gateway PVLAN, or WinNAT are not yet prepared, first run the reusable infrastructure planner with preselected switch GUIDs:

```powershell
& .\setup\Prepare-RequestNetworkInfrastructure.ps1 `
  -InstallRoot '<EXACT_INSTALL_ROOT>' `
  -InternetSwitchId '<PRESELECTED-INTERNAL-SWITCH-GUID>' `
  -TrustedLanSwitchId '<PRESELECTED-EXTERNAL-SWITCH-GUID>' `
  -TrustedLanPhysicalAdapterName '<EXACT-PHYSICAL-ADAPTER-NAME>' `
  -PlanOnly
```

Run that approval-ready plan elevated but still read-only, review its exact fingerprint, then pass the fingerprint without PlanOnly. Preparation creates only missing named infrastructure, writes the private policy under the installed Live\Setup tree, and stops for the separate transactional broker-policy plan. A failed preparation removes only objects created by that transaction and restores a gateway VLAN it changed from untagged. It never removes or repurposes an unrelated switch, NAT, VM adapter, route, or firewall rule. Creating an external switch with management-OS sharing can briefly interrupt the host uplink.

Applying that exact fingerprint overlays the reviewed broker source, replaces only `RequestNetworkPolicy` in the installed v1 configuration, transactionally reinstalls the broker, refreshes the runtime skill, runs the privileged idle-pool audit, and retains the rollback snapshot through live acceptance and recovery refresh. It deliberately does not create or reconfigure switches, NAT, firewall, VLAN, or gateway state; those are separate host-infrastructure mutations in the reviewed live plan.

## Live acceptance

Source tests establish schema, lifecycle, policy, cleanup, and canary behavior, but do not prove a live network boundary. Before calling the profiles ready:

1. retain a `None` regression;
2. prove same-cohort communication and different-cohort/host/LAN/Internet denial for `IsolatedTestNet`;
3. prove public TCP and UDP/DNS plus host/LAN/private/peer/inbound/IPv6/spoof/route-drift denial for two concurrent `InternetOnly` workers;
4. prove the exact logical and physical switch identity and intended LAN reachability for `TrustedLan`;
5. run mixed-profile concurrency, cancellation, timeout, broker interruption, and worker recycle cases;
6. finish with an idle pool audit showing no lease, managed adapter, owned cohort switch, or connected worker adapter;
7. refresh local recovery once, deep-hash verify it, and run the public audit before any separately approved source push.

No baseline image, worker disk, Windows Update state, .NET SDK, checkpoint, or VM operating-system configuration changes are required.
