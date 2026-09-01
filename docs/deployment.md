# Harness software releases

`setup\Deploy-HarnessRelease.ps1` is the canonical entry point for publishing an ordinary committed harness software release to an existing installation. It replaces ad hoc sequences of source copying, broker repair, guest-agent replacement, repeated canaries, and repeated recovery hashing with one resumable transaction.

It does not install a new harness, service Windows or .NET images, change request networking, restart the host, or authorize `ForceRebuild`. Use the setup and image-maintenance approval workflows for those operations.

## Review the immutable plan

Resolve the stable SDK version during read-only review, then run:

```powershell
$release = @{
    InstallRoot = '<EXISTING_NON_ROOT_INSTALL_DIRECTORY>'
    CandidateCommit = '<EXACT_40_CHARACTER_HEAD_COMMIT>'
    GuestUpdateSwitchName = '<APPROVED_TEMPORARY_UPDATE_SWITCH>'
    DotNetChannel = '10.0'
    ExpectedDotNetSdkVersion = '<EXACT_STABLE_VERSION>'
    TargetUserProfile = '<TARGET_PROFILE>'
    TargetUserSid = '<TARGET_SID>'
}
& .\setup\Deploy-HarnessRelease.ps1 @release -PlanOnly
```

PlanOnly performs no mutation. It binds the candidate to a clean exact Git commit, the installed configuration hash, the target account, the selected SDK metadata, and hashes of the three guest-resident harness files. It also runs the existing component PlanOnly paths and reports queue readiness. Review `DeploymentId`, `PlanSha256`, `Operations`, `GuestBaselineUpdateRequired`, `RecoveryBaselineExportMode`, `RecoveryReuseReadiness`, and the approval boundary.

After the first successful guest-baseline promotion, a small local provenance receipt under `Live\Setup` records the hashes actually promoted into the baseline. Future plans compare against that receipt, so copying newer source into `Software` cannot incorrectly make an unfinished guest update appear complete.

The current architecture does not provide a separately named live shadow broker and worker pool. The plan therefore calls its pre-promotion step `PrePromotionQualification` and explicitly reports `LiveShadowPoolAvailable = false`. That step proves parsing, builds, deterministic tests, exact invocation contracts, and the public payload; live behavior is accepted immediately after promotion in disposable workers. Do not describe this as a live shadow deployment.

## Apply once

After the live mutation plan is explicitly approved, rerun the same values with the exact plan hash:

```powershell
& .\setup\Deploy-HarnessRelease.ps1 @release -Apply -ExpectedPlanSha256 '<PLAN_SHA256>'
```

Apply and resume execute under Windows PowerShell 5.1, the harness's supported privileged runtime. If started from PowerShell 7, the controller relaunches itself in `powershell.exe`; a non-elevated caller still sees only the one required UAC prompt.

Ordinary language such as “do it,” “proceed,” or “apply that plan” is sufficient approval when it clearly refers to the displayed exact plan; no magic phrase is required. The controller requests elevation once and owns these checkpoints:

1. `CandidateQualification` — one complete deterministic source suite and public audit.
2. `LiveReadiness` — an empty-queue guest-baseline preflight when guest files changed.
3. `SourcePromotion` — sanitized source publication with duplicate smoke and recovery work deferred.
4. `GuestBaselinePromotion` — when required, one baseline update and one disposable-pool rebuild. Otherwise source promotion refreshes the pool once.
5. `IsolatedAcceptance` — legacy launch, an accented UI Automation Name click with no AutomationId, exact `WIN+LEFT` keyboard evidence with before/after screenshots, and an expected-guest-power-off/no-replay probe.
6. `RecoveryRefresh` — one final local recovery creation and integrity verification, only after acceptance. `FullExport` exports and hashes the complete baseline. `ReuseCurrent` keeps the receipt-backed unchanged baseline as NTFS hard links and hashes only the new recovery delta.
7. `Finalization` — exact-commit and public-payload revalidation plus the terminal receipt.

The strict pre- and post-acceptance pool audits each run inside a short, owned broker-maintenance drain. That boundary stops warm workers, completes payload garbage collection, restores the exact broker ACL after Hyper-V's transient disk grants, captures the audit, and then releases maintenance. The four application tests themselves run with normal pool scheduling between those two drains.

State, logs, and receipts live below `Live\Setup\Deployments\<DeploymentId>`. They are private local deployment evidence and must never be committed.

`ReuseCurrent` is selected only when the plan detects no guest-baseline change and `Recovery\Current\manifest.json` exists. Apply then requires the same baseline VM and canonical checkpoint IDs, a structurally valid Current bundle, and a matching successful refresh or deep-verification receipt. It never falls back silently to a full 50+ GB export; drift stops the immutable plan for review. Unchanged software files are rehashed and hard-linked when possible, while changed files are copied and hashed. A full export remains mandatory for first recovery creation, a missing Current generation, and every intentional Windows/.NET or canonical-checkpoint update.

Hard-linked `Current` and `Previous` directories remain complete namespace views and either one materializes as a standalone full bundle when copied to another volume. On the local NTFS volume they share unchanged physical clusters, so this preserves release rollback but is not a second physical copy against media corruption. Use periodic independent deep verification and an external copy when that additional failure boundary is required.

## Resume and fix forward

For an interruption or retry with the unchanged commit and plan, reuse completed checkpoints:

```powershell
& .\setup\Deploy-HarnessRelease.ps1 @release `
    -ResumeDeploymentId '<DEPLOYMENT_ID>' `
    -ExpectedPlanSha256 '<PLAN_SHA256>'
```

A failed phase records `NeedsFixForward`; the controller does not automatically restore checkpoints, rebuild a known-good pool again, or repeat recovery hashing. Diagnose the failed boundary and resume the same plan when the source is unchanged. If a source correction is required, commit it, generate a new plan with `-SupersedesDeploymentId '<FAILED_DEPLOYMENT_ID>'`, and apply that reviewed successor. Rollback remains an explicit hard-boundary decision for destructive, security, configuration, or data-integrity failures.

Push only after the terminal receipt reports `ReadyToPush = true`, rerunning `setup\Test-PublicRepository.ps1` immediately before the public push as required by repository policy.
