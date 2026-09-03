# Network and read-only host inputs

Read this reference before adding `-ReadOnlyHostInput`, selecting a non-`None` network profile, or interpreting their evidence. The broker owns every switch, adapter, firewall, route, credential, and lease. The client exposes no switch-selection parameter and must not create or modify network infrastructure.

## Read-only host inputs

Declare auxiliary files or directories with:

```powershell
-ReadOnlyHostInput @{ Name = 'media'; Path = 'D:\Netflix'; Mode = 'Auto' }
```

Any absolute local path explicitly supplied for the run is eligible; there is no persistent allowlist. Names are case-insensitively unique. Refer to an input as `{HOSTINPUT:media}` in arguments or ordinary string-valued actions; the `HOSTINPUT:` prefix is uppercase.

Transport modes:

- `Auto` selects an unchanged warm VHDX cache, a small cold/incremental VHDX update, or an ephemeral read-only host share for cold or substantially changed large data.
- `Vhdx` forces a frozen, guest-read-only snapshot with local-disk semantics.
- `Share` forces a read-only but live host view. Host-side changes may become visible during the run, and reading a cloud placeholder may hydrate it on the host.

Neither transport lets the application modify the declared input. `ArtifactPath` is never converted to a host share and retains its canonical immutable-payload behavior.

A shared input gets a random per-request SMB share and local credential over a worker-specific internal Hyper-V switch containing only the VM and its host endpoint. Dedicated RFC 1918 `/30` links allow host VPN/LAN kill-switch policy to recognize the route without providing LAN or Internet reachability. IP forwarding and weak-host routing are disabled. One host firewall exception permits encrypted SMB only on TCP 445 at that worker-specific address; the normal BlockInbound profile rejects other inbound traffic.

The share grants read-only access even when source ACLs are writable. A temporary read/execute ACE may be added for the ephemeral principal; cleanup deletes the principal before removing that ACE, so interrupted cleanup cannot leave usable access. File inputs use a same-volume hard-link projection rather than copying contents. The broker reconciles shares, accounts, permissions, projections, adapters, and leases after cancellation, worker failure, or restart.

## Network profiles

General networking is opt-in with `-NetworkProfile`. Omit it or use `None` for the disconnected default. Non-`None` requests use the versioned `RunGuestJobNetworkV1` contract so an older broker rejects, rather than ignores, the request.

### IsolatedTestNet

`IsolatedTestNet` requires `-NetworkCohort <NON_SECRET_LABEL>`. Only concurrent requests in the same explicitly named cohort may share its private VM-only switch. The broker exempts only the disposable request adapter from the guest firewall for cohort protocols. The switch has no host, LAN, or Internet route.

### InternetOnly

`InternetOnly` accepts no cohort or switch override; the broker selects pinned internal infrastructure. It stays disabled until all of the following are pinned and live-tested: the host's sole WinNAT with no static mappings; the internal gateway's `Promiscuous` private-VLAN pair and each guest's matching `Isolated` pair; exact weighted stateful extended ACLs that deny unsolicited and non-TCP/UDP traffic by default; peer layer-2 isolation; expected gateway Ethernet/ARP exchange; and denial of IPv6, host IP, LAN, and inbound access.

This profile is not the Hyper-V `Default Switch`. It does not claim its required host gateway is invisible at raw layer 2. Do not describe it as proven without current positive Internet evidence plus negative host, private/LAN, inbound, and IPv6 evidence from the installed pinned switch/NAT policy.

### TrustedLan

`TrustedLan` accepts no switch selector. Broker policy must contain exactly one external switch pinned by name, ID, physical-interface GUID/description, and management-OS sharing state. This deliberately grants the guest full reachable-LAN exposure; state that scope before using it.

### Network plus host input

Combining a non-`None` profile with `-ReadOnlyHostInput` requires `-AllowNetworkWithHostInputs`. Explicit `Mode=Share` remains incompatible and is rejected. `Mode=Auto` is forced to immutable guest-read-only VHDX transport. Without the flag, reject the combined request.

A source update does not create or enable switches, NAT, firewall rules, or allowlists. If a requested profile is disabled, stop and explain that setup needs the setup-harness informed-consent plan, preflight, and separate approval before host mutation. Never substitute another switch.

## Examples

```powershell
# Two concurrent requests may communicate only when they use this same cohort.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\service-a' `
  -NetworkProfile IsolatedTestNet `
  -NetworkCohort 'contract-test-42'

# Broker-selected pinned Internet-only infrastructure.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\internet-client' `
  -NetworkProfile InternetOnly

# Broker-selected, explicitly full-LAN exposure.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\lan-client' `
  -NetworkProfile TrustedLan

# Networking forces Auto host input to VHDX; Share is forbidden.
& "$env:USERPROFILE\.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1" `
  -ArtifactPath 'D:\build\internet-client' `
  -NetworkProfile InternetOnly `
  -AllowNetworkWithHostInputs `
  -ReadOnlyHostInput @{ Name = 'fixtures'; Path = 'D:\fixtures'; Mode = 'Auto' }
```

## Evidence and cleanup

The broker records a per-request network lease before VM-adapter mutation, connects the approved adapter last, verifies the boundary before launching the application, disconnects first during cleanup, and publishes cleanup evidence before recycling. It refuses workers with pre-existing connected adapters. An auxiliary share uses a separate request-scoped adapter that is also removed before recycle.

For each host input, verify the requested mode and `SelectedTransport`. A shared input must report `ReadOnly=true`, `BytesExposedWithoutCopy`, its isolated switch, and successful cleanup. A cached input must report cache/hash/sync timing and deletion of its disposable child.

For a non-`None` network profile, require evidence of the requested/effective profile, approved switch name and ID, adapter enforcement and connect-last sequence, host-policy checks, exact guest-side boundary attestation, cleanup success, final disconnected adapters, and deleted lease. With host inputs, verify that `Auto` selected VHDX and `Share` was not used.
