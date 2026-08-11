# Disaster recovery

## When the local recovery bundle is gone

The GitHub repository is the recovery seed. It does not need the original VHDX, checkpoint, ISO, password, or broker state.

On a reimaged Windows 11 Pro, Enterprise, or Education host:

1. Install Codex and sign into GitHub if needed. The repository is public, so cloning does not require a token.
2. Ask Codex to clone the repository and follow the root `AGENTS.md` plus `$setup-hyperv-harness` skill. The prompt in the README is sufficient.
3. Save open work, then approve the single Windows elevation prompt. If Hyper-V is newly enabled, the installer restarts automatically unless `-NoRestart` was supplied.
4. Monitor `D:\Disk\VMs\Codex-Harness\Live\Setup\setup-state.json`. A registered SYSTEM task owns post-restart continuation; do not launch a competing installer.
5. Require `Phase=Ready` and `Success=true` in `setup-result.json`. Those terminal states are published only after the internal privileged audit and isolated canary pass. `VERIFY.cmd` is available as a later independent recheck and requests a separate elevation.

The longest steps are the Microsoft ISO download, unattended Windows installation, base VHDX conversion, and local recovery export. They are resumable at the host-feature boundary, while expensive completed media and baseline work are reused on a normal rerun.

## If the fast local bundle survives

Use its `INSTALL.cmd`. That path imports the prepared baseline rather than downloading and reinstalling Windows, rebuilds the disposable pool, installs the broker and skill, audits the result, and runs a canary. Its command files pause before exit.

## Activation

Neither recovery path enters a key, signs into a Microsoft account, transfers a license, or claims that Windows is activated. The source rebuild chooses Windows 11 Pro because the automation baseline requires that edition; activation is a separate user-owned step.

## Safe reruns

- A matching baseline checkpoint is reused.
- The official ISO cache is reused only after signature, edition, and SHA-256 checks.
- The broker and runtime skill are refreshed from the repository source.
- `-ForceRebuild` removes the harness's named VMs and baseline storage. Do not use it merely to retry a transient failure.
