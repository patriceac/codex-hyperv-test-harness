# Codex operating instructions

This repository rebuilds a privileged Hyper-V executable-test backend. Use the repo-local `$setup-hyperv-harness` skill for installation, recovery, verification, or troubleshooting.

## Safety and scope

- Never commit or upload a Windows ISO, seed ISO, VHD/VHDX/AVHDX, exported VM, VM state, executable build output, guest credential, broker request/result/evidence, screenshot, or host-input content.
- Run `setup\Test-PublicRepository.ps1` before any public push. Treat a failed rule as a release blocker.
- Do not activate Windows, enter a product key, sign into a Microsoft account, or make licensing claims. Installation selects Windows 11 Pro; activation and licensing belong to the user.
- Do not run application-under-test executables on the physical host. Once installed, use the `hyperv-test-executables` skill. Browser-faithful tests may use a browser.
- Do not directly manipulate pool VMs for ordinary tests. Submit the canonical `ArtifactPath` to the broker and let it manage payload VHDX caching, differencing children, worker leases, recycling, evidence, and cleanup.
- Treat `-ForceRebuild` as destructive. Use it only when the user explicitly authorizes replacing this harness's named VMs.
- Preserve unrelated user files, Hyper-V VMs, virtual switches, Codex instructions, and skills. The installer updates only its managed policy block.

## Informed-consent gate

- Begin installation or disaster recovery in review-only mode. Before cloning or making any local change, use read-only access to explain the architecture, prerequisites, downloads, resource footprint, persistent host changes, security boundaries, reboot behavior, recovery output, verification, licensing boundary, and destructive possibilities.
- Ask the user for an exact non-root install directory, pool size, VM memory and processor count, display size, idle timeout, language, target account, restart preference, local-recovery preference, preservation requirements, the temporary guest-update switch, the stable .NET channel/version, and the Windows Update scope. Show a suggested/reference answer and its tradeoff for every question, and allow the user to accept the complete reference profile while naming only exceptions. Do not assume that `D:` or another drive exists; offer an explicitly authorized read-only capacity inventory when the user wants a storage recommendation. Reference values may be accepted by the user but never silently selected.
- Present the complete proposed configuration and effects. Configuration answers are not approval. Stop and wait for explicit approval before cloning, downloading, or running local commands.
- After approval, run only the public audit and plan-only preflight with the selected values passed explicitly. Show their results and obtain a second explicit approval before elevation, feature enablement, media download, reboot, task registration, VM/VHDX work, broker installation, Codex changes, or any other mutation.
- A later `-ForceRebuild` decision remains a separate destructive approval. Neither earlier confirmation authorizes replacement of existing harness assets.

## Rebuild workflow

1. Complete the informed-consent gate and record every selected parameter.
2. After the first approval, run `setup\Test-PublicRepository.ps1` and `setup\Install.ps1 -PlanOnly` with an explicit `-InstallRoot` and the selected sizing, display, timeout, language, restart, recovery, temporary guest-update switch, .NET channel, and approved exact stable SDK version.
3. Show the exact plan. After the second approval, run `setup\Install.ps1` with the same explicit parameters; never use an unparameterized command in a Codex-guided rebuild.
4. If Hyper-V must be enabled, let the registered `SYSTEM` task resume after restart. Read `<chosen-install-root>\Live\Setup\setup-state.json`; do not restart the installation from scratch while it is active.
5. Require the `Ready` terminal state and run `setup\Verify.ps1 -InstallRoot <chosen-install-root>`.
6. Use `setup\Refresh-LocalRecovery.ps1 -InstallRoot <chosen-install-root>` after intentional baseline or harness changes.

## Ordinary software release deployment

- Use `setup\Deploy-HarnessRelease.ps1` as the canonical owner for an ordinary committed source, broker, skill, canary, or guest-agent release to an existing harness. Do not replace it with an ad hoc chain of installer, guest-update, canary, and recovery commands.
- Run its exact `-PlanOnly` path first and obtain explicit approval before `-Apply`. Clear ordinary wording that refers to the displayed plan is sufficient; do not demand a magic approval phrase.
- Resume the same immutable plan from its completed checkpoints. Prefer a linked fix-forward plan over rollback for ordinary source defects. Rollback and `ForceRebuild` remain separately approved hard-boundary operations.
- The controller owns one final broad source suite, three isolated live acceptance paths, and one recovery refresh. Do not repeat the full suite or deep-hash recovery after each successful sub-step.
- Keep the controller and its contract tests current when the deployment topology or acceptance boundary changes. Do not claim a live shadow pool until one is actually implemented and verified.

The installer must resolve the current x64 multi-edition Windows 11 ISO through Microsoft's official download page, validate Microsoft media, enumerate `install.wim` or `install.esd`, and select the sole `EditionId=Professional` image. Never replace this with a fixed release URL, third-party mirror, hard-coded image index, or activation automation.

For a newly built baseline, the installer must use only the explicitly approved temporary Hyper-V switch, apply applicable non-preview Microsoft software/security/quality/Defender updates without drivers or a feature-version upgrade, resolve the stable .NET SDK from Microsoft's official release metadata, verify SHA-512 and Microsoft Authenticode, and disconnect networking before the clean checkpoint. A guided plan pins the resolved SDK version so a release change stops for renewed review.

## Image maintenance

- Treat `setup\Update-Images.ps1` as a baseline-and-pool rebuild: use the same proposal, preflight, and second-approval gates.
- Use `-PlanOnly` first with the exact install root, temporary update switch, stable .NET channel/version, target account, and recovery-preservation choice.
- Service the canonical baseline first, then replace and boot-verify workers one at a time. Keep the canonical checkpoint, prior worker registrations, pool disks, and `Recovery\Current` available for rollback until their replacements verify.
- Refresh and deep-hash-verify local recovery after the pool audit and isolated canary. Preserve the older `Recovery\Previous` in a dated local archive when the approved plan requires it.
- A public GitHub disaster-recovery update contains source and documentation only. Run the public audit again before an explicitly approved push; never publish downloaded SDK installers, update payloads, images, credentials, logs, or evidence.
