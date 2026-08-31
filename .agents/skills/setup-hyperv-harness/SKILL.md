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

1. Explain in detailed, plain language the backend's purpose and architecture; Hyper-V and host prerequisites; official ISO resolution and validation; unattended unactivated Windows 11 Pro guest; temporary baseline-only update networking; non-preview Windows Update servicing; stable .NET SDK resolution and verification; VM/VHDX/checkpoint layout; SYSTEM broker and scheduled tasks; locally generated credential; installed Codex skill and managed policy block; network isolation and scoped read-only host input; payload cache; evidence; local recovery bundle; verification; retry and cleanup behavior; expected disk, memory, time, and reboot impact; licensing boundary; and every condition that could replace or remove existing harness assets.
2. Ask one compact group of questions for the exact non-root install directory, pool size from one to four, RAM and virtual processors per VM, display dimensions, idle timeout, guest language, target Windows account, automatic-restart preference, local-recovery-bundle preference, existing assets that must be preserved, temporary guest-update switch, stable .NET channel and exact currently resolved SDK version, and Windows Update scope. For every question, show the suggested/reference answer below and a short reason or tradeoff. Tell the user they may answer "use the reference profile" and name only exceptions. Never silently select a suggestion.
3. Present an exact proposal with paths, VM names, per-VM and total resources, downloads, persistent machine changes, security boundaries, destructive possibilities, and verification steps. State that answering the questions did not authorize execution. Stop and wait for explicit approval.

Use these reference answers:

- Install root: `<user-selected-large-local-fixed-drive>:\VMs\Codex-Harness` with at least 200 GiB free. Do not assume a drive. If the user is unsure, offer an explicitly authorized read-only fixed-drive/free-space inventory before recommending a concrete path.
- Pool: four workers for maximum supported concurrency and warm-spare behavior; reduce it for a constrained host.
- Memory: 8 GiB per VM, up to 32 GiB for four simultaneously running workers plus host overhead.
- Processors: four virtual processors per VM; reduce this when host CPU capacity is limited.
- Display and idle policy: 1920 by 1080 and 600 seconds.
- Language and target: `Auto` and the current Windows account that will use Codex.
- Restart: allow automatic restart after work is saved (`NoRestart = false`); use `true` when the user wants to control timing.
- Recovery: create the large, sensitive, faster local bundle (`SkipLocalRecoveryBundle = false`) when capacity permits.
- Preservation: preserve all existing assets and keep `ForceRebuild = false`; replacement always needs separate destructive approval.
- Temporary guest-update switch: `Default Switch`, for baseline-only outbound Microsoft update access without connecting workers; select another named switch only deliberately.
- .NET: current stable LTS channel `10.0`, with the exact latest SDK version resolved from Microsoft's official release metadata during read-only planning; do not select previews.
- Windows Update: applicable non-preview Microsoft software, security, quality, and Defender updates for the installed Windows 11 feature version; exclude optional drivers and feature-version upgrades.

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
    GuestUpdateSwitchName = '<EXPLICIT_HYPERV_SWITCH>'
    DotNetChannel = '<STABLE_CHANNEL>'
    ExpectedDotNetSdkVersion = '<EXACT_VERSION_RESOLVED_DURING_REVIEW>'
    TargetUserProfile = '<USER_SELECTED_WINDOWS_PROFILE_PATH>'
    TargetUserSid = '<USER_SELECTED_WINDOWS_ACCOUNT_SID>'
    NoRestart = <TRUE_OR_FALSE>
    SkipLocalRecoveryBundle = <TRUE_OR_FALSE>
}
& .\setup\Install.ps1 @parameters -PlanOnly
```

Report the exact command, selected values, resource totals, failed checks, and any discrepancy from the approved proposal. Do not silently redirect the install root or adjust sizing. Stop and obtain a second explicit approval before running a mutating command. The public audit and `-PlanOnly` preflight do not authorize the installation.

For an existing installation, also report `Configuration.ExistingConfigurationSha256`, `RequestNetworkPolicyDisposition`, and `RequestNetworkPolicySha256`. An ordinary source refresh must say `PreservedExisting`; add the exact reviewed configuration hash as `ExpectedExistingConfigurationSha256` to the approved apply parameters. The installer revalidates that fingerprint before staging and preserves the complete schema-valid installed `RequestNetworkPolicy`, including enabled-profile infrastructure identities. Drift, a missing configuration or policy, malformed JSON, an incompatible configuration identity, or an unsupported policy fails closed without replacing the configuration; existing Live, Recovery, Harness, or Setup state is never reclassified as a first installation merely because `harness-config.json` is absent. `ResetRequestNetworkPolicy` is never part of an ordinary refresh: it discards the installed request-network policy and restores fail-closed external-profile defaults, must appear in a new PlanOnly result as `ResetToFailClosed`, and requires separate explicit approval with the exact configuration fingerprint.

## Rebuild only after the second approval

Tell the user to save open work. Run `setup\Install.ps1` with the exact approved parameter set and restart/recovery switches. A human may use `INSTALL.cmd` as a pausing wrapper only when the same explicit arguments are supplied. Never invoke a bare installer command during Codex-guided setup. Keep the approved values unchanged through retries and resume.

The installer is authorized to:

- request administrator elevation;
- enable Hyper-V and register its narrowly scoped resume task;
- restart when Hyper-V enablement requires it, unless the user asked for `-NoRestart`;
- use signed Microsoft Edge headlessly to resolve Microsoft's current Windows 11 x64 multi-edition ISO;
- validate the ISO, select `EditionId=Professional`, install an unactivated guest unattended, and generate a random local guest credential;
- temporarily connect only the new baseline to the approved switch, converge applicable non-preview Windows updates, install the approved stable .NET SDK after SHA-512 and Microsoft signature verification, then disconnect networking before sealing;
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

For an ordinary source refresh, first run `setup\Install.ps1 -PlanOnly` with every selected value. If an existing configuration is detected, the plan must report `PreservedExisting`; copy its exact `ExistingConfigurationSha256` into `ExpectedExistingConfigurationSha256` for the separately approved apply. Never use `ResetRequestNetworkPolicy` to work around an unexpected validation failure. Review the installed configuration and renew the proposal; use the reset switch only when the user explicitly chooses to discard the installed runtime request-network policy and return `InternetOnly` and `TrustedLan` to disabled defaults.

Treat enabling or changing runtime request networking as a privileged broker-policy update, not as image maintenance and not as an ordinary test request. Keep `None` as the request default. The runner may choose `None`, `InternetOnly`, `IsolatedTestNet`, or `TrustedLan`, plus an isolated cohort where required; it never chooses a switch, NAT, address, DNS server, route, VLAN, or firewall rule. Enabled `TrustedLan` policy must contain exactly one external switch pinned by logical ID and physical-interface identity.

Begin with read-only inspection and an explicit source/public audit. If named switch, gateway PVLAN, or WinNAT infrastructure is missing, first run `setup\Prepare-RequestNetworkInfrastructure.ps1` with preselected switch GUIDs and `-PlanOnly`; report its exact elevated read-only fingerprint and stop for separate approval before applying it. That preparation may create only the reviewed named infrastructure, writes the private policy below the installed Live tree, and then stops. Next run `setup\Update-RequestNetworking.ps1 -InstallRoot '<EXACT_INSTALL_ROOT>' -PolicyPath '<LOCAL_UNTRACKED_POLICY_JSON>' -PlanOnly`, report its separately fingerprinted broker-policy plan and every unresolved elevated identity check, and stop for approval. Use only the same approved fingerprint for each apply. Neither plan-only path may write, create or change switches/NAT/firewall/VM adapters, restart the broker, run application canaries, or refresh recovery. If any identity or fingerprint changes, stop without mutation and renew review. A successful live update must drain the broker, preserve a rollback copy, deploy the broker policy transactionally, run positive and negative canaries for every enabled profile, prove cancellation/orphan cleanup and final worker disconnection, run the pool audit, refresh and deep-verify local recovery, and keep any public push as a separately approved source-only action.

For an intentional Windows/.NET baseline refresh, use `setup\Update-Images.ps1 -PlanOnly` with the exact existing install root, approved update switch, stable channel/version, target account, guest-restart mode, and recovery-preservation choice. Treat its canonical checkpoint and worker replacement as a rebuild: show the plan and obtain the second approval before elevation or downloads. Manual restart mode must apply a temporary scheduled-restart guard, report `ManualRebootPending`, restore all other transient state, and resume with `-AdoptCurrentBaseline` so the current guest disk is not replaced by the old checkpoint. The guard persists only while waiting for the user and its original values are restored after completion or cancellation. Use that same adoption flag when the user intentionally updated the current baseline by hand; it requires manual restart mode and retains the canonical checkpoint as rollback. A synchronous Windows Update operation must finish and WUA must report idle before cancellation or any restart decision. Only explicit Windows Update/CBS or verified installer signals authorize a restart; pending file renames alone do not. Launcher loss requests cooperative cancellation and must clean up networking, maintenance, broker, and touched pool state without force-killing the controller. The mutating run services the baseline, replaces and verifies workers sequentially, repairs the broker, runs the isolated canary, and deep-verifies the refreshed local recovery image. Source changes for GitHub cold recovery are audited and pushed only when that public mutation was included in the approved proposal.

If a transactional rollback occurs after the updated checkpoint, immutable base, four workers, and privileged pool audit have all succeeded, prefer a reviewed `-ResumeUpdateId <EXACT_FAILED_UPDATE_ID>` plan over repeating guest servicing. Resume requires manual restart mode, an off baseline, the unchanged archived rollback definition, the retained failed checkpoint as a direct child of the canonical checkpoint, a successful `ReadyToSeal` servicing record, and audited disconnected VHD parent links. It must not boot or service the baseline. Re-register and boot-verify the retained workers one at a time, promote and restore the retained checkpoint only after they all pass, and rerun broker audit, isolated canary, and deep recovery verification. Preserve the same rollback guarantees if resume fails.
