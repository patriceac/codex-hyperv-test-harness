# Codex Hyper-V Test Harness

A source-only, recoverable backend for testing Windows executables in isolated Hyper-V workers while the physical desktop is locked or in use.

The repository contains the broker, guest agent, elastic pool of up to four VMs, immutable payload-VHDX cache, disposable differencing-disk lifecycle, evidence capture, read-only host-input transport, runtime Codex skill, and rebuild automation. It deliberately contains **no Windows image, VM disk, credential, executable build output, or activation material**.

## Capabilities at a glance

| Area | Current contract |
|---|---|
| [Isolated native execution](docs/architecture.md) | An ACL-protected SYSTEM broker queues canonical artifacts into an elastic pool of zero to four disposable Windows 11 workers. Immutable payload parents and per-run differencing children preserve the caller's files, support concurrent reuse, and are detached and deleted during cleanup. |
| [Desktop automation](src/Software/Skill/references/artifact-and-actions.md) | Window wait/focus, UI Automation click by `AutomationId` or exact Unicode `Name`, verified relative click, text entry, allowlisted single-key/chord input, result-file and process-exit waits, JSON assertions, and screenshots. Request and action JSON uses explicit UTF-8 across the supported PowerShell 7 client to Windows PowerShell 5.1 broker/guest path. |
| [Live and terminal evidence](src/Software/Skill/references/queue-observation-and-cancellation.md) | Terminal results separate harness success from application-test success and record action, process-cleanup, payload, VM, network, and evidence state. A running request can provide a fresh screenshot plus explicitly allowlisted small `{OUTDIR}` files without changing its deadline or substituting stale evidence. |
| [Read-only host inputs](docs/security-model.md#trust-boundaries) | A caller-selected local file or directory can be exposed to one VM request through a scoped read-only Share or immutable VHDX transport. The broker owns teardown; combining host inputs with general networking requires an explicit acknowledgement and VHDX isolation. |
| [Request networking](docs/request-networking.md) | `None` remains the disconnected default. `IsolatedTestNet`, `InternetOnly`, and `TrustedLan` are explicit broker-authorized profiles with fail-closed versioning, pinned infrastructure, attestation, continuous policy checks, and disconnect-first cleanup; externally connected profiles remain disabled until separately configured and live-verified. |
| Physical-host tests | An explicit request for a named host test routes to computer use. The harness and its legacy host controller must never be used for physical-host testing. |
| [Intentional guest power-off](docs/testing.md#expected-power-off-contract) | An opt-in request may prove an application-era guest shutdown after an atomic result marker. The broker tears down networking, performs one networkless evidence-recovery boot, rejects post-boot markers, and never resubmits the job or relaunches the application. |
| [Release, maintenance, and recovery](docs/maintenance.md) | Immutable reviewed plans, resumable checkpoints, deterministic and isolated acceptance, transactional image maintenance, one final recovery refresh, retained previous recovery generation, and a source-only GitHub cold-rebuild path keep expensive work auditable and recoverable. |

## Choose the faithful test boundary

Use a browser first for a pure web application when browser automation can faithfully exercise the requested behavior. Use this Hyper-V harness for native shells, tray behavior, installers, WebView2, Windows integration, or proof of a VM network boundary. Electron remains a native-shell test even when its content is web-based.

For an explicitly requested named physical-host test, give precedence to computer use. The harness is reserved for isolated VM tests.

Workers use the `None` network profile by default. A request may explicitly ask for one of these named profiles; the SYSTEM broker, not the client, remains the authorization boundary:

| Profile | Intended boundary |
|---|---|
| `None` | No general network adapter connection. This is the compatibility default. |
| `IsolatedTestNet` | An explicitly named cohort on a private VM-only switch, with no host, LAN, or Internet route. |
| `InternetOnly` | Outbound TCP/UDP through the host's sole, pinned, mapping-free WinNAT. A pinned private-VLAN pair isolates guest ports from peer guests at layer 2; the host gateway remains the necessary promiscuous Ethernet/ARP endpoint. Weighted stateful extended ACLs bind the guest source address, deny host IP/private destinations and unsolicited inbound traffic, and block everything else. Disabled until that exact policy is reviewed, configured, and live-verified. It is not the Hyper-V `Default Switch`. |
| `TrustedLan` | Full exposure to an external switch pinned by name, ID, single physical-interface GUID/description, and management-OS sharing state. Disabled until deliberately configured and verified. |

Non-`None` requests use the versioned `RunGuestJobNetworkV1` operation so an older broker rejects them instead of silently running with different connectivity. Clients may select only an approved profile and, for `IsolatedTestNet`, a cohort; they cannot select a switch or supply raw NAT, DNS, route, or firewall configuration. `TrustedLan` resolves the policy's sole pinned external switch entirely inside the broker. See [request networking](docs/request-networking.md) for the fingerprinted infrastructure and broker-policy deployment workflows, and the runtime skill's [network and host-input reference](src/Software/Skill/references/network-and-host-inputs.md) for request examples.

This source contract does not enable or create live profile infrastructure. Adding switches, NAT, firewall policy, or allowlists remains part of the setup-harness informed-consent workflow, including a reviewed plan and separate approval before host mutation. See [request-scoped networking](docs/request-networking.md) for the exact request contract, lifecycle, preflight, and live acceptance matrix.

Applications that intentionally shut down their disposable guest may opt in with `-ExpectGuestPowerOff`. The application must atomically write a required `{OUTDIR}` result marker before calling the real guest `shutdown.exe /s /t 0`. Under the harness's exclusive-worker/no-external-intervention boundary, the broker records an application-era VM `Running` to `Off` transition before cleanup, revokes networking, and performs one networkless boot of the same disposable worker solely to finalize and copy marker evidence. The marker must predate that recovery boot, and the harness never resubmits the job or relaunches the application. Runs without the opt-in keep the legacy behavior unchanged. See the runtime skill's [expected guest power-off reference](src/Software/Skill/references/expected-guest-power-off.md) for the contract and isolated-VM example.

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

On an existing installation, PlanOnly reports the installed configuration and request-network-policy fingerprints. An ordinary source refresh must report `PreservedExisting`; the approved apply must include the exact reported `ExpectedExistingConfigurationSha256`. The full validated installed policy is then preserved atomically, including deliberately enabled `InternetOnly` or `TrustedLan` identities. Missing, malformed, incompatible, or changed configuration fails closed. `ResetRequestNetworkPolicy` is a separately reviewed and approved recovery path that intentionally replaces the installed policy with fail-closed external-profile defaults; it is not an ordinary refresh option.

Windows activation and licensing are intentionally outside this project. The guest may remain unactivated until the user handles licensing.

## Deploy an ordinary software release

For an existing installation, use the resumable [harness release controller](docs/deployment.md) instead of manually chaining source refresh, guest-baseline replacement, acceptance, and recovery commands. It binds a clean commit and installed configuration into an immutable PlanOnly result, applies through one elevated state machine, and runs four isolated acceptance paths: legacy launch, an accented UI Automation `Name` click without an `AutomationId`, screenshot-backed `WIN+LEFT` keyboard input, and expected guest power-off with no replay. Source qualification also proves that a BOM-less PowerShell 7 request containing accented text is read correctly by Windows PowerShell 5.1. The controller refreshes and verifies local recovery once at the end; when the canonical checkpoint is unchanged, it reuses the receipt-backed baseline export with NTFS hard links and writes only the software delta. Image servicing, networking changes, first installation, and `ForceRebuild` remain separate reviewed workflows.

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
2. **Fast local recovery:** `REFRESH-LOCAL-RECOVERY.cmd` fully exports the prepared baseline and current software into `Recovery\Current`, retains one previous generation, and verifies checksums. Ordinary software releases can instead reuse an unchanged, receipt-backed baseline through same-volume NTFS hard links and write only their delta. Each generation remains a complete bundle view, but shared local clusters are not independent protection against media corruption. The recovery material is intentionally too large and too sensitive for GitHub.

Both paths install the same marker-delimited harness policy fragment from `setup\AGENTS.block.md`. The repository and recovery bundle never capture the user's complete global `AGENTS.md`; installation merges only the harness-owned block and preserves unrelated personal instructions.

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

Start with [Disaster recovery](docs/disaster-recovery.md), [Software releases](docs/deployment.md), [Maintenance](docs/maintenance.md), [Architecture](docs/architecture.md), [Request networking](docs/request-networking.md), [Payload-cache performance](docs/payload-cache.md), [Security model](docs/security-model.md), and [Testing/provenance](docs/testing.md).

## Public-release guardrail

Before publishing, run:

```powershell
.\setup\Test-PublicRepository.ps1
```

The check rejects VM/media formats, executable outputs, private/generated state, large files, literal user-profile paths, and common secret formats. GitHub Actions repeats the source checks on every push and pull request.

Licensed under the [MIT License](LICENSE).
