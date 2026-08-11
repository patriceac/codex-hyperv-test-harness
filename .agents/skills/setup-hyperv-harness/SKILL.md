---
name: setup-hyperv-harness
description: Rebuild, recover, verify, or diagnose the repository's isolated Windows executable-test backend on a Windows 11 Hyper-V host. Use when a user needs first-time installation, disaster recovery after losing local VM backups, migration to a new or reimaged device, official Windows 11 Pro media acquisition, pool or SYSTEM-broker repair, local recovery refresh, or proof that the backend is ready. Do not use this skill to run an application-under-test; use hyperv-test-executables after setup.
---

# Set up the Hyper-V test harness

Reconstruct the complete backend from published source and current official Microsoft media. Keep activation and licensing entirely user-owned.

## Establish context

Resolve the repository root as three directories above this `SKILL.md`. Read the root `AGENTS.md`, then `docs/disaster-recovery.md`. Read `references/rebuild-checklist.md` when installing or recovering, and `docs/troubleshooting.md` when diagnosing a failed or interrupted attempt.

Do not search for or reuse an unknown ISO, VHDX, credential, exported VM, or executable. The repository intentionally rebuilds those locally.

## Preflight without mutation

Run these from the repository root:

```powershell
& .\setup\Test-PublicRepository.ps1
& .\setup\Install.ps1 -PlanOnly
```

Report failed required checks. The default root is `D:\Disk\VMs\Codex-Harness`. If `D:` is unavailable, choose a specific fixed local directory with at least 200 GiB free and pass `-InstallRoot`; do not silently redirect an existing installation.

## Rebuild

Run `INSTALL.cmd` for a human-visible one-click flow or `setup\Install.ps1` from an existing terminal. Tell the user to save open work because first-time Hyper-V enablement can restart Windows. Keep the same parameter values through retries. The expected defaults are four workers, 8 GiB each, four virtual processors, 1920 by 1080, and a 600-second idle timeout.

The installer is authorized to:

- request administrator elevation;
- enable Hyper-V and register its narrowly scoped resume task;
- restart when Hyper-V enablement requires it, unless the user asked for `-NoRestart`;
- use signed Microsoft Edge headlessly to resolve Microsoft's current Windows 11 x64 multi-edition ISO;
- validate the ISO, select `EditionId=Professional`, install an unactivated guest unattended, and generate a random local guest credential;
- create the named baseline and the configured one-to-four disposable worker VMs below the chosen install root;
- install the ACL-restricted SYSTEM broker, runtime skill, and managed Codex policy block;
- run the visual canary only through the newly installed Hyper-V broker;
- generate the faster local image-based recovery bundle.

It is not authorized to activate Windows, enter a key, sign into a Microsoft account, remove unrelated VMs, modify unrelated Codex instructions, or run test applications on the physical host.

## Resume correctly

If the process returns 3010 or `setup-state.json` says `RebootPending`, verify the `Codex Hyper-V Source Rebuild Resume` task and allow one restart. After restart, monitor state with:

```powershell
& .\.agents\skills\setup-hyperv-harness\scripts\Get-RebuildStatus.ps1
```

Do not start a second copy while the state is progressing or the global install mutex is held. The final acceptance state is `Phase=Ready` plus `Success=true` in `setup-result.json`.

## Verify and hand off

Require `Phase=Ready`, `Success=true`, a successful embedded pool audit, and a successful isolated canary in `setup-result.json`. The installer does not publish Ready before these checks pass.

For an independent recheck after later host changes, run `VERIFY.cmd`, or:

```powershell
& .\setup\Verify.ps1
```

The independent command requests its own elevation. State explicitly whether the fast local recovery bundle exists and whether it received structural or deep hash verification. Mention that the public GitHub repository remains the cold-rebuild source if the local bundle is lost.

## Destructive repair gate

Never infer permission for `-ForceRebuild`. It removes only this harness's named baseline and pool VMs, but use it only after the user explicitly authorizes replacement and you have verified their names and storage locations. Transient ISO, queue, broker, or resume failures do not justify it.

## Maintain

After intentional baseline or backend changes, run `REFRESH-LOCAL-RECOVERY.cmd`. Before any public push, rerun `setup\Test-PublicRepository.ps1`; no media, VM state, binaries, credentials, request evidence, or personal profile data may enter Git.
