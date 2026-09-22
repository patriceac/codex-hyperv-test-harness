# Harness software releases

`setup\Deploy-HarnessRelease.ps1` is the canonical entry point for publishing an ordinary committed harness software release to an existing installation. It replaces ad hoc sequences of source copying, broker repair, guest-agent replacement, repeated canaries, and repeated recovery hashing with one resumable transaction. Ordinary releases are authorized by default: a successful immutable plan proceeds directly to Apply without another conversational approval.

It does not install a new harness, service Windows or .NET images, change request networking, restart the host, or perform `ForceRebuild`. Use the separate setup, networking, and image-maintenance workflows for those operations; they are also standing-authorized when they are within the requested task and their exact plans succeed.

## Review the immutable plan

Resolve the stable SDK version during read-only review, then run:

```powershell
$release = @{
    InstallRoot = '<EXISTING_NON_ROOT_INSTALL_DIRECTORY>'
    CandidateCommit = '<EXACT_40_CHARACTER_HEAD_COMMIT>'
    GuestUpdateSwitchName = '<CONFIGURED_TEMPORARY_UPDATE_SWITCH>'
    DotNetChannel = '10.0'
    ExpectedDotNetSdkVersion = '<EXACT_STABLE_VERSION>'
    TargetUserProfile = '<TARGET_PROFILE>'
    TargetUserSid = '<TARGET_SID>'
}
& .\setup\Deploy-HarnessRelease.ps1 @release -PlanOnly
```

PlanOnly performs no mutation. It binds the candidate to a clean exact Git commit, the installed configuration hash, the target account, the selected SDK metadata, and hashes of the four guest-resident harness files. It also runs the existing component PlanOnly paths and reports queue readiness. Inspect `DeploymentId`, `PlanSha256`, `Operations`, `GuestBaselineUpdateRequired`, `RecoveryBaselineExportMode`, `RecoveryReuseReadiness`, `ApplyReady`, `DefaultAuthorization`, and the authorization boundary. Stop on failure, drift, or expanded scope; otherwise continue directly to Apply.

After the first successful guest-baseline promotion, a small local provenance receipt under `Live\Setup` records the hashes actually promoted into the baseline. Future plans compare against that receipt, so copying newer source into `Software` cannot incorrectly make an unfinished guest update appear complete.

Baseline promotion sets and verifies non-expiring account/password policy only for the disposable guest automation account. Guest readiness attests that policy before accepting work. An already-expired legacy account may reject both PowerShell Direct and an interactive password change. Recover only the managed baseline account under an exact-target, backed-up recovery plan that preserves its protected credential. The controller then verifies the policy, seals the corrected baseline, replaces the workers, and performs one full recovery refresh. This does not alter host account policy.

The current architecture does not provide a separately named live shadow broker and worker pool. The plan therefore calls its pre-promotion step `PrePromotionQualification` and explicitly reports `LiveShadowPoolAvailable = false`. That step proves parsing, builds, deterministic tests, exact invocation contracts, and the public payload; live behavior is accepted immediately after promotion in disposable workers. Do not describe this as a live shadow deployment.

## Apply once

After a successful ordinary release plan, rerun the same values immediately with the exact plan hash:

```powershell
& .\setup\Deploy-HarnessRelease.ps1 @release -Apply -ExpectedPlanSha256 '<PLAN_SHA256>'
```

Apply and resume execute under Windows PowerShell 5.1, the harness's supported privileged runtime. If started from PowerShell 7, the controller relaunches itself in `powershell.exe`; a non-elevated caller still sees only the one required UAC prompt.

No additional user confirmation is required between PlanOnly and Apply. The request to change or publish ordinary harness software carries standing authorization for this release path. The controller may still trigger the single Windows UAC prompt required for elevation and owns these checkpoints:

1. `CandidateQualification` — one complete deterministic source suite and public audit.
2. `LiveReadiness` — an empty-queue guest-baseline preflight when guest files changed.
3. `SourcePromotion` — sanitized source publication with duplicate smoke and recovery work deferred.
4. `GuestBaselinePromotion` — when required, one baseline update and one disposable-pool rebuild. Otherwise source promotion refreshes the pool once.
5. `IsolatedAcceptance` — eight live paths covering legacy launch, accented UI Automation names, `WIN+LEFT`, expected power-off, system prompts, automatic/manual restart, installed-app shutdown with payload-token setup, and diagnostic retention after a deliberate restart-phase failure.
6. `RecoveryRefresh` — one final local recovery creation and integrity verification, only after acceptance. `FullExport` exports and hashes the complete baseline. `ReuseCurrent` keeps the receipt-backed unchanged baseline as NTFS hard links and hashes only the new recovery delta.
7. `Finalization` — exact-commit and public-payload revalidation plus the terminal receipt.

The strict pre- and post-acceptance pool audits each run inside a short, owned broker-maintenance drain. That boundary stops warm workers, completes payload garbage collection, restores the exact broker ACL after Hyper-V's transient disk grants, captures the audit, and then releases maintenance. Eight acceptance paths run with normal pool scheduling between those drains. The restart path also owns one peer request on a distinct worker in the same IsolatedTestNet cohort: challenge/response traffic must succeed after both automatic and manual sign-in, with before/after guest network observations retained and no late network repair. Both autonomous RunOnce starts must observe the Private firewall profile and sole isolated interface exemption. It captures the signed-out VM before manual credential input. The failure canary must return its false phase marker and nested resume file while preserving the failed broker result and proving no continuation was submitted.

State, logs, and receipts live below `Live\Setup\Deployments\<DeploymentId>`. They are private local deployment evidence and must never be committed.
The cross-guest acceptance requires at least two configured workers; planning reports insufficient capacity before deployment.

`ReuseCurrent` is selected only when the plan detects no guest-baseline change and `Recovery\Current\manifest.json` exists. Apply then requires the same baseline VM and canonical checkpoint IDs, a structurally valid Current bundle, and a matching successful refresh or deep-verification receipt. It never falls back silently to a full 50+ GB export; drift stops the immutable plan for review. Unchanged software files are rehashed and hard-linked when possible, while changed files are copied and hashed. A full export remains mandatory for first recovery creation, a missing Current generation, and every intentional Windows/.NET or canonical-checkpoint update.

Hard-linked `Current` and `Previous` directories remain complete namespace views and either one materializes as a standalone full bundle when copied to another volume. On the local NTFS volume they share unchanged physical clusters, so this preserves release rollback but is not a second physical copy against media corruption. Use periodic independent deep verification and an external copy when that additional failure boundary is required.

## Resume and fix forward

For an interruption or retry with the unchanged commit and plan, reuse completed checkpoints:

```powershell
& .\setup\Deploy-HarnessRelease.ps1 @release `
    -ResumeDeploymentId '<DEPLOYMENT_ID>' `
    -ExpectedPlanSha256 '<PLAN_SHA256>'
```

A failed phase records `NeedsFixForward`; the controller does not automatically restore checkpoints, rebuild a known-good pool again, or repeat recovery hashing. Diagnose the failed boundary and resume the same plan when the source is unchanged. If a source correction is required, commit it, generate a new plan with `-SupersedesDeploymentId '<FAILED_DEPLOYMENT_ID>'`, and apply that successful successor without another confirmation. Rollback remains a separate fingerprinted hard-boundary workflow for destructive, security, configuration, or data-integrity failures; when it is within the requested task, its successful exact plan proceeds under standing authorization.

Push only after the terminal receipt reports `ReadyToPush = true`, rerunning `setup\Test-PublicRepository.ps1` immediately before the public push as required by repository policy.
