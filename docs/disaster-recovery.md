# Disaster recovery

## When the local recovery bundle is gone

The GitHub repository is the recovery seed. It does not need the original VHDX, checkpoint, ISO, password, or broker state.

On a reimaged Windows 11 Pro, Enterprise, or Education host:

1. Install Codex. The repository is public, so read-only inspection and cloning do not require a GitHub token.
2. Give Codex the informed-consent prompt in the README. Codex must inspect the public instructions without cloning, explain the complete rebuild and its risks, ask for the user's configuration, present an exact proposal, and wait. No drive or resource profile is assumed.
3. After the user explicitly approves that proposal, Codex may clone the repository and run only the public audit and plan-only preflight with the chosen values. Review their exact output and give a second explicit approval before any mutating installation step.
4. Save open work, then allow the approved Windows elevation. If Hyper-V is newly enabled, the installer restarts automatically unless the user selected `-NoRestart`. When a new baseline is required, the installer temporarily connects only that VM to the explicitly approved switch, converges the approved non-preview Windows Update scope, resolves and verifies the approved stable .NET SDK, performs an SDK build smoke test, and disconnects the VM before checkpoint creation.
5. Monitor `<chosen-install-root>\Live\Setup\setup-state.json`. A registered SYSTEM task owns post-restart continuation; do not launch a competing installer.
6. Require `Phase=Ready` and `Success=true` in `<chosen-install-root>\Live\Setup\setup-result.json`. Those terminal states are published only after the internal privileged audit and isolated canary pass. Run `setup\Verify.ps1 -InstallRoot <chosen-install-root>` for a later independent recheck.

The longest steps are the Microsoft ISO download, unattended Windows installation, repeated guest update/reboot passes, .NET SDK verification, base VHDX conversion, and local recovery export. They are resumable at the host-feature boundary, while expensive completed media and baseline work are reused on a normal rerun.

## If the fast local bundle survives

Use its `INSTALL.cmd`. That path imports the prepared baseline rather than downloading and reinstalling Windows, rebuilds the disposable pool, installs the broker and skill, audits the result, and runs a canary. Its command files pause before exit.

## Activation

Neither recovery path enters a key, signs into a Microsoft account, transfers a license, or claims that Windows is activated. The source rebuild chooses Windows 11 Pro because the automation baseline requires that edition; activation is a separate user-owned step.

## Safe reruns

- A matching baseline checkpoint is reused. Use the separately approved sequential image-maintenance workflow when that baseline itself must be updated; an ordinary source refresh does not silently change it.
- The official ISO cache is reused only after signature, edition, and SHA-256 checks.
- The broker and runtime skill are refreshed from the repository source.
- `-ForceRebuild` removes the harness's named VMs and baseline storage. Do not use it merely to retry a transient failure.
