# Codex Hyper-V Test Harness

A source-only, recoverable backend for testing Windows executables in isolated Hyper-V workers while the physical desktop is locked or in use.

The repository contains the broker, guest agent, elastic pool of up to four VMs, immutable payload-VHDX cache, disposable differencing-disk lifecycle, evidence capture, read-only host-input transport, runtime Codex skill, and rebuild automation. It deliberately contains **no Windows image, VM disk, credential, executable build output, or activation material**.

## Choose the faithful test boundary

Use a browser first for a pure web application when browser automation can faithfully exercise the requested behavior. Use this Hyper-V harness for native shells, tray behavior, installers, WebView2, Windows integration, or proof of a VM network boundary. Electron remains a native-shell test even when its content is web-based.

When the user explicitly overrides isolation for one named artifact and test, the installed runtime skill also contains an on-demand physical-host controller. It gives a five-second thin, continuous fuchsia halo warning on every display; ordinary mouse or keyboard activity does not pause that grace period. After it expires, physical input pauses control, which resumes after ten idle seconds only after refocusing the tracked application. Physical `Escape` cancels at any time. This path is never an automatic fallback and provides no VM, filesystem, credential, network, or rollback isolation; see the runtime skill's [host-control contract](src/Software/Skill/references/host-control.md).

Workers use the `None` network profile by default. A request may explicitly ask for one of these named profiles; the SYSTEM broker, not the client, remains the authorization boundary:

| Profile | Intended boundary |
|---|---|
| `None` | No general network adapter connection. This is the compatibility default. |
| `IsolatedTestNet` | An explicitly named cohort on a private VM-only switch, with no host, LAN, or Internet route. |
| `InternetOnly` | Outbound TCP/UDP through the host's sole, pinned, mapping-free WinNAT. A pinned private-VLAN pair isolates guest ports from peer guests at layer 2; the host gateway remains the necessary promiscuous Ethernet/ARP endpoint. Weighted stateful extended ACLs bind the guest source address, deny host IP/private destinations and unsolicited inbound traffic, and block everything else. Disabled until that exact policy is reviewed, configured, and live-verified. It is not the Hyper-V `Default Switch`. |
| `TrustedLan` | Full exposure to an external switch pinned by name, ID, single physical-interface GUID/description, and management-OS sharing state. Disabled until deliberately configured and verified. |

Non-`None` requests use the versioned `RunGuestJobNetworkV1` operation so an older broker rejects them instead of silently running with different connectivity. Clients may select only an approved profile and, for `IsolatedTestNet`, a cohort; they cannot select a switch or supply raw NAT, DNS, route, or firewall configuration. `TrustedLan` resolves the policy's sole pinned external switch entirely inside the broker. See [request networking](docs/request-networking.md) for the fingerprinted infrastructure and broker-policy deployment workflows, and the [runtime skill](src/Software/Skill/SKILL.md) for request examples.

This source contract does not enable or create live profile infrastructure. Adding switches, NAT, firewall policy, or allowlists remains part of the setup-harness informed-consent workflow, including a reviewed plan and separate approval before host mutation. See [request-scoped networking](docs/request-networking.md) for the exact request contract, lifecycle, preflight, and live acceptance matrix.

## Rebuild after losing everything local

Give Codex this prompt:

> I want to evaluate and possibly rebuild the isolated Hyper-V executable-test backend from `https://github.com/patriceac/codex-hyperv-test-harness`.
>
> Begin in review-only mode. Before cloning, downloading files, running local commands, requesting elevation, or changing this computer, inspect the public `README.md`, root `AGENTS.md`, `.agents/skills/setup-hyperv-harness/SKILL.md`, and `docs/disaster-recovery.md` through read-only web access.
>
> First explain in detailed, plain language what the proposed system does and what installing it would change. Cover Hyper-V enablement; official Windows 11 ISO acquisition and validation; unattended unactivated Windows 11 Pro installation; baseline-only temporary update networking; non-preview Windows Update convergence; stable .NET SDK metadata, hash, and signature validation; VM, VHDX, checkpoint, scheduled-task, SYSTEM-broker, local-credential, Codex skill/policy, payload-cache, networking, evidence, recovery-bundle, validation, cleanup, retry, disk-space, memory, time, elevation, and possible reboot behavior. Explain what remains isolated, what data is not published, what is never activated or licensed automatically, and when an existing harness could be replaced or removed.
>
> Then ask me one compact set of configuration questions, including the exact non-root installation directory. For every item, show the suggested/reference answer below plus a short reason or tradeoff. Tell me I may reply "use the reference profile" and list only my exceptions:
>
> - Installation directory — suggested layout: `<user-selected-large-local-fixed-drive>:\VMs\Codex-Harness`, with at least 200 GiB free. Do not assume that `D:` or any other drive exists. If I do not know which drive to use, offer to perform a read-only fixed-drive and free-space inventory, and ask permission before running it.
> - Pool size — suggested: 4 workers, for maximum supported concurrency and warm-spare behavior; reduce it on a resource-constrained host.
> - Memory — suggested: 8 GiB per VM, or up to 32 GiB when all four workers are running, plus host overhead.
> - Virtual processors — suggested: 4 per VM; reduce this if the host has few logical processors.
> - Display — suggested: 1920 by 1080.
> - Idle shutdown — suggested: 600 seconds (10 minutes), balancing quick reuse against idle resource use.
> - Guest language — suggested: `Auto`, so the installer chooses the host user's language when Microsoft offers it.
> - Target Windows account — suggested: the current account that will use Codex; choose another account only deliberately.
> - Restart behavior — suggested: allow the automatic restart after open work is saved (`NoRestart = false`); choose `NoRestart = true` to control the timing manually.
> - Local recovery bundle — suggested: create it (`SkipLocalRecoveryBundle = false`) when disk capacity permits; it consumes substantial space and contains sensitive VM material, but makes later recovery much faster.
> - Preservation — suggested: preserve every existing VM and file and keep `ForceRebuild = false`; replacement requires a separate, explicit destructive approval.
> - Temporary guest-update switch — suggested: `Default Switch`, used only by the baseline while Windows and .NET are updated; workers remain disconnected, and the baseline is disconnected before sealing.
> - Runtime request networking — suggested: keep `None` as the default, permit explicit installation-scoped `IsolatedTestNet` cohorts, and leave `InternetOnly` and `TrustedLan` disabled until a separate exact host-policy proposal and live positive/negative verification are approved. The temporary update switch never authorizes runtime networking.
> - .NET SDK — suggested: stable LTS channel `10.0`, pinned to the exact latest stable SDK version resolved from Microsoft's official release metadata during review; do not install previews.
> - Windows Update — suggested: applicable non-preview Microsoft software, security, quality, and Defender updates for the installed feature version; exclude optional drivers and feature-version upgrades.
>
> After I answer, present an exact proposed configuration, paths, resource totals, named machine changes, downloads, security boundaries, destructive possibilities, and verification plan. Treat my answers as preferences, not authorization. Stop and wait for my explicit approval of that proposal.
>
> Only after that approval may you clone the repository and run its public-safety audit and `-PlanOnly` preflight, using every chosen value explicitly. Show me the resulting plan and any discrepancy. Obtain a second explicit approval before any elevation, Hyper-V enablement, ISO or large-file download, reboot, scheduled-task registration, VM or VHDX creation/replacement, broker installation, Codex policy/skill change, or other mutation. Never configure Windows activation or licensing.

Or perform the same review manually, choose the configuration yourself, and use explicit values from an Administrator-capable Windows account:

```powershell
git clone https://github.com/patriceac/codex-hyperv-test-harness
cd codex-hyperv-test-harness
$parameters = @{
    InstallRoot = 'E:\HyperV\Codex-Harness' # Replace with your chosen non-root directory.
    PoolSize = 4
    VmMemoryGiB = 8
    VmProcessorCount = 4
    DisplayWidth = 1920
    DisplayHeight = 1080
    IdleTimeoutSeconds = 600
    Language = 'Auto'
    GuestUpdateSwitchName = 'Default Switch'
    DotNetChannel = '10.0'
    ExpectedDotNetSdkVersion = '<VERSION_RESOLVED_DURING_REVIEW>'
}
.\setup\Install.ps1 @parameters -PlanOnly
# Review the plan before running the next line.
.\setup\Install.ps1 @parameters
```

`INSTALL.cmd` remains available as a pausing wrapper, but guided recovery must pass the user's selected values explicitly instead of relying on its compatibility defaults. Save open work before the approved installation starts: if Hyper-V is disabled, the installer registers a narrow resume task and restarts Windows automatically unless `-NoRestart` is supplied. The installer requests elevation once, downloads the current official x64 multi-edition Windows 11 ISO through Microsoft's own download page, validates the media, finds `EditionId=Professional`, installs Windows 11 Pro unattended, builds the worker pool, installs the SYSTEM broker and Codex skill, performs its own elevated audit and isolated visual canary, and creates a faster local recovery bundle.

Windows activation and licensing are intentionally outside this project. The guest may remain unactivated until the user handles licensing.

## Reference profile and compatibility defaults

Codex-guided recovery must ask the user to choose every value. The entries below describe the project's established profile and the fallback retained for manual script compatibility; they are not consent to use them.

| Setting | Reference or compatibility value |
|---|---:|
| Install root | User-selected non-root directory; bare scripts retain `D:\Disk\VMs\Codex-Harness` only for compatibility |
| Maximum workers | 4 |
| Memory per VM | 8 GiB |
| Virtual processors per VM | 4 |
| Guest display | 1920 × 1080 |
| Idle shutdown | 10 minutes |
| Temporary guest-update switch | Explicitly approved `Default Switch` |
| .NET SDK | Stable `10.0` channel, exact version pinned during review |
| Windows Update | Non-preview software/security/quality/Defender updates; no driver or feature-version upgrade |
| Warm-spare rule | keep one ready VM while leases exist, up to four workers |
| Worker network | `None` by default; explicitly authorized request-scoped profiles only, plus the separate scoped read-only host-input path |

Override the location or sizing from PowerShell:

```powershell
.\setup\Install.ps1 -InstallRoot 'E:\HyperV\Codex-Harness' -VmMemoryGiB 8 -PoolSize 4
```

Inspect the exact plan without elevation or mutation:

```powershell
.\setup\Install.ps1 -PlanOnly
```

## What gets rebuilt from source

- All C# canaries and the guest input probe are compiled locally with the signed Windows .NET Framework compiler.
- The guest seed ISO is produced with Windows IMAPI; Python is not required.
- A random throwaway guest credential is generated locally and ACL-restricted.
- A new cold-rebuild baseline temporarily uses only the approved Hyper-V switch, converges applicable non-preview Microsoft updates, downloads the approved stable .NET SDK from official metadata, verifies SHA-512 and Microsoft Authenticode, performs a local SDK build smoke test, and disconnects networking before checkpoint creation.
- The Windows 11 Pro image index is discovered from the downloaded `install.wim` or `install.esd`; it is never hard-coded.
- The pool is generated from a clean baseline into one immutable base plus disposable worker children.
- Application payloads continue to originate at the caller's canonical `ArtifactPath`. The broker incrementally synchronizes them into immutable cached VHDX parents and attaches a disposable differencing child per run instead of recursively copying payloads through PowerShell Direct.

## Two recovery levels

1. **Cold rebuild from GitHub:** this repository plus Microsoft's current Windows 11 media and update services reconstructs the entire backend, including the reviewed stable .NET SDK policy. It is slower and may not be byte-identical because Microsoft media and updates advance, but it survives loss of every local backup.
2. **Fast local recovery:** `REFRESH-LOCAL-RECOVERY.cmd` exports the prepared baseline and current software into `Recovery\Current`, retains one previous generation, and verifies checksums. That bundle is intentionally too large and too sensitive for GitHub.

Successful installation already includes the privileged audit and isolated canary. `VERIFY.cmd` is an optional independent recheck after meaningful host changes; it pauses before closing and requests its own elevation.

## Repository map

```text
.agents/skills/setup-hyperv-harness/   Codex-guided reconstruction workflow
setup/                                 installer, media resolver, verification, public audit
src/Software/Harness/                  broker, pool, payload cache, guest agent, tests
src/Software/Skill/                    runtime hyperv-test-executables skill
src/Software/Canaries/                 source and action fixtures; no checked-in binaries
src/Software/Recovery/                 fast local recovery generator and installer
docs/                                  architecture, security, recovery, maintenance, diagnosis
```

Start with [Disaster recovery](docs/disaster-recovery.md), [Architecture](docs/architecture.md), [Payload-cache performance](docs/payload-cache.md), [Security model](docs/security-model.md), and [Testing/provenance](docs/testing.md).

## Public-release guardrail

Before publishing, run:

```powershell
.\setup\Test-PublicRepository.ps1
```

The check rejects VM/media formats, executable outputs, private/generated state, large files, literal user-profile paths, and common secret formats. GitHub Actions repeats the source checks on every push and pull request.

Licensed under the [MIT License](LICENSE).
