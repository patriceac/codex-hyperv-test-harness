---
name: setup-hyperv-harness
description: Review, configure, rebuild, recover, verify, or diagnose the repository's isolated Windows executable-test backend on a Windows 11 Hyper-V host. Use for first-time installation, informed disaster-recovery planning after local backups are lost, migration to a new or reimaged device, official Windows 11 Pro media acquisition, pool or SYSTEM-broker repair, local recovery refresh, or readiness proof. Begin every install or rebuild with a read-only explanation, user-selected configuration, and explicit approval gates. Do not use this skill to run an application-under-test; use hyperv-test-executables after setup.
---

# Set up the Hyper-V test harness

Reconstruct the complete backend from published source and current official Microsoft media. Keep configuration choices, activation, licensing, and authorization entirely user-owned.

## Begin with informed consent

If the repository is not local, inspect its public `README.md`, root `AGENTS.md`, this skill, and `docs/disaster-recovery.md` through read-only web access. Do not clone or download it yet. If it is already local, resolve the repository root as three directories above this `SKILL.md` and read those files without running scripts. Read `references/rebuild-checklist.md` when installing or recovering, and `docs/troubleshooting.md` when diagnosing a failed or interrupted attempt.

Do not search for or reuse an unknown ISO, VHDX, credential, exported VM, or executable. The repository intentionally rebuilds those locally.

Before any clone, download, local command, elevation, or host mutation:

1. Explain in detailed, plain language the backend's purpose and architecture; Hyper-V and host prerequisites; official ISO resolution and validation; unattended unactivated Windows 11 Pro guest; VM/VHDX/checkpoint layout; SYSTEM broker and scheduled tasks; locally generated credential; installed Codex skill and managed policy block; network isolation and scoped read-only host input; payload cache; evidence; local recovery bundle; verification; retry and cleanup behavior; expected disk, memory, time, and reboot impact; licensing boundary; and every condition that could replace or remove existing harness assets.
2. Ask one compact group of questions for the exact non-root install directory, pool size from one to four, RAM and virtual processors per VM, display dimensions, idle timeout, guest language, target Windows account, automatic-restart preference, local-recovery-bundle preference, and existing assets that must be preserved. Do not assume a drive or path. Offer the established four-worker, 8-GiB, four-processor, 1920-by-1080, 600-second profile only as a recommendation the user may accept or change.
3. Present an exact proposal with paths, VM names, per-VM and total resources, downloads, persistent machine changes, security boundaries, destructive possibilities, and verification steps. State that answering the questions did not authorize execution. Stop and wait for explicit approval.

Do not treat a general request such as "restore it" or "set it up" as approval of the proposal. The approval must follow the explanation and proposed configuration.

## Run the read-only preflight after approval

After the user approves the proposal, clone the repository if needed. Run these from its root with every selected value made explicit:

```powershell
& .\setup\Test-PublicRepository.ps1
$parameters = @{
    InstallRoot = '<USER_SELECTED_NON_ROOT_DIRECTORY>'
    PoolSize = <1_TO_4>
    VmMemoryGiB = <GIB_PER_VM>
    VmProcessorCount = <PROCESSORS_PER_VM>
    DisplayWidth = <PIXELS>
    DisplayHeight = <PIXELS>
    IdleTimeoutSeconds = <SECONDS>
    Language = '<LANGUAGE_OR_AUTO>'
    TargetUserProfile = '<USER_SELECTED_WINDOWS_PROFILE_PATH>'
    TargetUserSid = '<USER_SELECTED_WINDOWS_ACCOUNT_SID>'
    NoRestart = <TRUE_OR_FALSE>
    SkipLocalRecoveryBundle = <TRUE_OR_FALSE>
}
& .\setup\Install.ps1 @parameters -PlanOnly
```

Report the exact command, selected values, resource totals, failed checks, and any discrepancy from the approved proposal. Do not silently redirect the install root or adjust sizing. Stop and obtain a second explicit approval before running a mutating command. The public audit and `-PlanOnly` preflight do not authorize the installation.

## Rebuild only after the second approval

Tell the user to save open work. Run `setup\Install.ps1` with the exact approved parameter set and restart/recovery switches. A human may use `INSTALL.cmd` as a pausing wrapper only when the same explicit arguments are supplied. Never invoke a bare installer command during Codex-guided setup. Keep the approved values unchanged through retries and resume.

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
& .\.agents\skills\setup-hyperv-harness\scripts\Get-RebuildStatus.ps1 -InstallRoot '<USER_SELECTED_NON_ROOT_DIRECTORY>'
```

Do not start a second copy while the state is progressing or the global install mutex is held. The final acceptance state is `Phase=Ready` plus `Success=true` in `setup-result.json`.

## Verify and hand off

Require `Phase=Ready`, `Success=true`, a successful embedded pool audit, and a successful isolated canary in `setup-result.json`. The installer does not publish Ready before these checks pass.

For an independent recheck after later host changes, run:

```powershell
& .\setup\Verify.ps1 -InstallRoot '<USER_SELECTED_NON_ROOT_DIRECTORY>'
```

The independent command requests its own elevation. State explicitly whether the fast local recovery bundle exists and whether it received structural or deep hash verification. Mention that the public GitHub repository remains the cold-rebuild source if the local bundle is lost.

## Destructive repair gate

Never infer permission for `-ForceRebuild`. It removes only this harness's named baseline and pool VMs, but use it only after the user explicitly authorizes replacement and you have verified their names and storage locations. Transient ISO, queue, broker, or resume failures do not justify it.

## Maintain

After intentional baseline or backend changes, run `setup\Refresh-LocalRecovery.ps1 -InstallRoot '<USER_SELECTED_NON_ROOT_DIRECTORY>'`. Before any public push, rerun `setup\Test-PublicRepository.ps1`; no media, VM state, binaries, credentials, request evidence, or personal profile data may enter Git.
