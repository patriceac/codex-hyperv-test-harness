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

## Rebuild workflow

1. Run `setup\Test-PublicRepository.ps1` and `setup\Install.ps1 -PlanOnly`.
2. Run `INSTALL.cmd`, or `setup\Install.ps1` when a terminal is preferred. The default install root is `D:\Disk\VMs\Codex-Harness`; pass `-InstallRoot` to change it.
3. If Hyper-V must be enabled, let the registered `SYSTEM` task resume after restart. Read `Live\Setup\setup-state.json`; do not restart the installation from scratch while it is active.
4. Require the `Ready` terminal state and run `VERIFY.cmd`.
5. Use `REFRESH-LOCAL-RECOVERY.cmd` after intentional baseline or harness changes.

The installer must resolve the current x64 multi-edition Windows 11 ISO through Microsoft's official download page, validate Microsoft media, enumerate `install.wim` or `install.esd`, and select the sole `EditionId=Professional` image. Never replace this with a fixed release URL, third-party mirror, hard-coded image index, or activation automation.
