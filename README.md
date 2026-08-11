# Codex Hyper-V Test Harness

A source-only, recoverable backend for testing Windows executables in isolated Hyper-V workers while the physical desktop is locked or in use.

The repository contains the broker, guest agent, elastic pool of up to four VMs, immutable payload-VHDX cache, disposable differencing-disk lifecycle, evidence capture, read-only host-input transport, runtime Codex skill, and rebuild automation. It deliberately contains **no Windows image, VM disk, credential, executable build output, or activation material**.

## Rebuild after losing everything local

Give Codex this prompt:

> Clone `https://github.com/patriceac/codex-hyperv-test-harness`, read its root `AGENTS.md` and `$setup-hyperv-harness` skill, run the public-safety and plan checks, then rebuild and verify the Hyper-V executable-test backend. Use `D:\Disk\VMs\Codex-Harness` unless that drive is unavailable. Do not configure Windows activation or licensing.

Or do it manually from an Administrator-capable Windows account:

```powershell
git clone https://github.com/patriceac/codex-hyperv-test-harness
cd codex-hyperv-test-harness
.\INSTALL.cmd
```

`INSTALL.cmd` pauses before closing. Save open work before starting: if Hyper-V is disabled, the installer registers a narrow resume task and restarts Windows automatically unless `-NoRestart` is supplied. The installer requests elevation once, downloads the current official x64 multi-edition Windows 11 ISO through Microsoft's own download page, validates the media, finds `EditionId=Professional`, installs Windows 11 Pro unattended, builds the worker pool, installs the SYSTEM broker and Codex skill, performs its own elevated audit and isolated visual canary, and creates a faster local recovery bundle.

Windows activation and licensing are intentionally outside this project. The guest may remain unactivated until the user handles licensing.

## Defaults

| Setting | Default |
|---|---:|
| Install root | `D:\Disk\VMs\Codex-Harness` |
| Maximum workers | 4 |
| Memory per VM | 8 GiB |
| Virtual processors per VM | 4 |
| Guest display | 1920 × 1080 |
| Idle shutdown | 10 minutes |
| Warm-spare rule | keep one ready VM while leases exist, up to four workers |
| Worker network | disconnected except a scoped, ephemeral read-only host-input path when requested |

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
- The Windows 11 Pro image index is discovered from the downloaded `install.wim` or `install.esd`; it is never hard-coded.
- The pool is generated from a clean baseline into one immutable base plus disposable worker children.
- Application payloads continue to originate at the caller's canonical `ArtifactPath`. The broker incrementally synchronizes them into immutable cached VHDX parents and attaches a disposable differencing child per run instead of recursively copying payloads through PowerShell Direct.

## Two recovery levels

1. **Cold rebuild from GitHub:** this repository plus Microsoft's current Windows 11 media reconstructs the entire backend. It is slower but survives loss of every local backup.
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
