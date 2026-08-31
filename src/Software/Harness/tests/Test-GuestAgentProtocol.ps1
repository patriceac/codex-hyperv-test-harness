[CmdletBinding()]
param([string] $GuestAgentPath)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($GuestAgentPath)) {
    $GuestAgentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'seed\guest\GuestAgent.ps1'
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($GuestAgentPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }

function Import-GuestFunction {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Guest function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

foreach ($name in @(
    'Write-JsonAtomic',
    'Write-AgentState',
    'Resolve-GuestOutputPath',
    'Resolve-JsonPointerValue',
    'Test-IsJsonNumber',
    'Test-JsonValuesEqual',
    'Test-GuestResultAssertion',
    'Test-ExpectedGuestPowerOffJob',
    'Get-GuestResultFileEvidence',
    'Get-GuestBootTimeUtc',
    'Get-CachedGuestBootTimeUtc',
    'ConvertTo-GuestUtcInstant',
    'Get-ExpectedGuestPowerOffBootEvidence',
    'Get-RedactedGuestActionSummary',
    'Dismount-GuestHostInputs',
    'Complete-ExpectedGuestPowerOffJob',
    'Repair-InterruptedGuestJobs',
    'Wait-GuestResultFile',
    'Get-GuestProcessTree',
    'Capture-Screen'
)) {
    Import-GuestFunction -Name $name
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-guest-protocol-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$scenarios = New-Object Collections.Generic.List[string]
try {
    $resultPath = Join-Path $testRoot 'result.json'
    [ordered]@{ passed = $true; nested = [ordered]@{ 'a/b' = @(1, 2, 3) } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    $pass = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/passed' -ExpectedJson 'true'
    Assert-True $pass.Passed 'A typed boolean JSON assertion did not pass.'
    $scenarios.Add('typed-json-boolean-pass')

    $failure = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/passed' -ExpectedJson 'false'
    Assert-True (-not $failure.Passed -and $failure.FailureKind -eq 'TestAssertion') 'A false JSON assertion was not classified as TestAssertion.'
    $scenarios.Add('typed-json-boolean-failure')

    $escaped = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/nested/a~1b/1' -ExpectedJson '2'
    Assert-True $escaped.Passed 'RFC 6901 slash escaping or array traversal failed.'
    $scenarios.Add('json-pointer-escape-and-array')

    $missing = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/missing' -ExpectedJson 'true'
    Assert-True (-not $missing.Passed -and $missing.FailureKind -eq 'JsonPointerMissing') 'A missing JSON pointer was not classified correctly.'
    $scenarios.Add('missing-json-pointer')

    $presentWait = Wait-GuestResultFile -Path $resultPath -TimeoutMilliseconds 500
    Assert-True ($presentWait.Found -and $presentWait.Length -gt 0) 'wait_result_file did not recognize existing non-empty evidence.'
    $missingWait = Wait-GuestResultFile -Path (Join-Path $testRoot 'never-created.json') -TimeoutMilliseconds 300
    Assert-True (-not $missingWait.Found -and $missingWait.ElapsedMilliseconds -ge 250 -and $missingWait.ElapsedMilliseconds -lt 1500) 'wait_result_file did not honor its bounded timeout.'
    $scenarios.Add('wait-result-file-bounded')

    Assert-True (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{ expectGuestPowerOff = $true })) 'An exact Boolean expected-power-off contract was not recognized.'
    Assert-True (-not (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{ expectGuestPowerOff = 'true' }))) 'A string expected-power-off value was treated as an exact Boolean.'
    Assert-True (-not (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{ expectGuestPowerOff = 1 }))) 'A numeric expected-power-off value was treated as an exact Boolean.'
    Assert-True (-not (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{ expectGuestPowerOff = $false }))) 'A false expected-power-off contract was enabled.'
    Assert-True (-not (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{ ExpectGuestPowerOff = $true }))) 'A request-level property name was accepted as the guest-job contract.'
    Assert-True (-not (Test-ExpectedGuestPowerOffJob -Job ([pscustomobject]@{}))) 'A missing expected-power-off contract was enabled.'
    $scenarios.Add('expected-power-off-requires-exact-boolean')

    $recoveryRoot = Join-Path $testRoot 'power-off-recovery'
    $recoveryInbox = Join-Path $recoveryRoot 'Inbox'
    $recoveryProcessing = Join-Path $recoveryRoot 'Processing'
    $recoveryCompleted = Join-Path $recoveryRoot 'Completed'
    $recoveryOutbox = Join-Path $recoveryRoot 'Outbox'
    foreach ($directory in @($recoveryInbox, $recoveryProcessing, $recoveryCompleted, $recoveryOutbox)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $script:syntheticCurrentBootUtc = [DateTime]'2026-08-31T00:40:00Z'
    Set-Item -LiteralPath Function:\script:Get-GuestBootTimeUtc -Value {
        ([DateTime]$script:syntheticCurrentBootUtc).ToUniversalTime()
    }
    $script:guestBootTimeUtc = $null
    $script:statePath = Join-Path $recoveryRoot 'agent-state.json'
    Write-AgentState -Status 'SyntheticBootState'
    $firstAgentState = Get-Content -Raw -LiteralPath $script:statePath | ConvertFrom-Json
    $script:syntheticCurrentBootUtc = [DateTime]'2026-08-31T01:00:00Z'
    Write-AgentState -Status 'SyntheticBootStateCached'
    $secondAgentState = Get-Content -Raw -LiteralPath $script:statePath | ConvertFrom-Json
    function Convert-TestBootValueToUtc {
        param($Value)
        if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
        ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
    }
    $firstStateBootUtc = Convert-TestBootValueToUtc -Value $firstAgentState.GuestBootTimeUtc
    $secondStateBootUtc = Convert-TestBootValueToUtc -Value $secondAgentState.GuestBootTimeUtc
    $expectedStateBootUtc = ([DateTimeOffset]::Parse('2026-08-31T00:40:00Z', [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
    Assert-True ($firstStateBootUtc -eq $expectedStateBootUtc -and $secondStateBootUtc -eq $firstStateBootUtc) 'Agent state does not expose one stable boot epoch for recovery freshness checks.'
    $script:syntheticCurrentBootUtc = [DateTime]'2026-08-31T00:40:00Z'
    $scenarios.Add('agent-state-exposes-stable-guest-boot-time')
    function Write-SyntheticPowerOffLease {
        param(
            [Parameter(Mandatory = $true)] [string] $OutputPath,
            [Parameter(Mandatory = $true)] [string] $JobId,
            [string] $GuestBootTimeUtc = '2026-08-31T00:00:00Z'
        )
        [ordered]@{
            JobId = $JobId
            ProcessId = 3988
            StartedUtc = '2026-08-31T00:30:53.3843571Z'
            GuestBootTimeUtc = $GuestBootTimeUtc
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputPath 'lease.json') -Encoding UTF8
    }
    function Set-SyntheticPreRecoveryMarkerTime {
        param([Parameter(Mandatory = $true)] [string] $Path)
        (Get-Item -LiteralPath $Path -Force).LastWriteTimeUtc = [DateTime]'2026-08-31T00:20:00Z'
    }

    $passingJobId = 'expected-power-off-pass'
    $passingOutput = Join-Path $recoveryOutbox $passingJobId
    New-Item -ItemType Directory -Force -Path $passingOutput | Out-Null
    Set-Content -LiteralPath (Join-Path $passingOutput 'preserve-me.txt') -Value 'sentinel' -Encoding UTF8
    $passingMarker = Join-Path $passingOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true; mode = 'immediate' } | ConvertTo-Json | Set-Content -LiteralPath $passingMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $passingMarker
    Write-SyntheticPowerOffLease -OutputPath $passingOutput -JobId $passingJobId
    $passingJob = [ordered]@{
        id = $passingJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @([ordered]@{ type = 'wait_result_file'; path = '{OUTDIR}\shutdown-marker.json' })
    }
    $passingJobFile = Join-Path $recoveryProcessing ($passingJobId + '.json')
    $passingJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $passingJobFile -Encoding UTF8

    $passingSummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    $passingResult = Get-Content -Raw -LiteralPath (Join-Path $passingOutput 'result.json') | ConvertFrom-Json
    Assert-True ($passingSummary.ExpectedJobsRecovered -eq 1 -and $passingSummary.LegacyJobsRequeued -eq 0) 'The expected power-off job was not recovered in place.'
    Assert-True (-not (Test-Path -LiteralPath $passingJobFile) -and (Test-Path -LiteralPath (Join-Path $recoveryCompleted ($passingJobId + '.json')))) 'The recovered expected power-off job did not move from Processing to Completed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $recoveryInbox ($passingJobId + '.json')))) 'The expected power-off job was incorrectly requeued for relaunch.'
    Assert-True ((Test-Path -LiteralPath $passingMarker) -and (Test-Path -LiteralPath (Join-Path $passingOutput 'preserve-me.txt'))) 'Expected power-off recovery did not preserve OUTDIR evidence.'
    Assert-True ($passingResult.Success -and $passingResult.HarnessSucceeded -and $passingResult.TestEvaluated -and $passingResult.TestPassed -and $passingResult.OverallSucceeded) 'A valid persisted shutdown marker did not produce an honestly successful result.'
    Assert-True ($passingResult.ExpectGuestPowerOff -and $passingResult.GuestPowerOffEvidenceRecoveryMode -eq 'ControlledReboot' -and -not $passingResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff) 'The recovered result omitted the expected-power-off recovery contract.'
    Assert-True ($passingResult.ProcessCleanup.Success -and $passingResult.ProcessCleanup.SatisfiedByGuestPowerCycle -and -not $passingResult.ProcessCleanup.Attempted) 'Power-cycle process cleanup was not represented honestly.'
    Assert-True ($passingResult.ResultFileEvidence.Length -gt 0 -and $passingResult.ResultFileEvidence.Sha256 -eq (Get-FileHash -LiteralPath $passingMarker -Algorithm SHA256).Hash -and $passingResult.ResultFileEvidence.LastWriteUtc) 'Recovered marker metadata is incomplete or incorrect.'
    Assert-True ($passingResult.RecoveryCompletedUtc -and $passingResult.ExpectedGuestPowerOffRecovery.OutputDirectoryPreserved -and -not $passingResult.ExpectedGuestPowerOffRecovery.ApplicationRelaunchedByHarness) 'Recovery timestamps or harness no-relaunch metadata are missing.'
    $scenarios.Add('expected-power-off-processing-recovers-without-relaunch')

    $passingResultPath = Join-Path $passingOutput 'result.json'
    $passingHashBeforeRestart = (Get-FileHash -LiteralPath $passingResultPath -Algorithm SHA256).Hash
    $idempotentSummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    $passingHashAfterRestart = (Get-FileHash -LiteralPath $passingResultPath -Algorithm SHA256).Hash
    $passingResultAfterRestart = Get-Content -Raw -LiteralPath $passingResultPath | ConvertFrom-Json
    Assert-True ($idempotentSummary.ExpectedJobsAlreadyComplete -eq 1 -and $passingHashAfterRestart -eq $passingHashBeforeRestart) 'A later agent restart rewrote an internally validated recovered result.'
    Assert-True ($passingResultAfterRestart.HarnessSucceeded -and $passingResultAfterRestart.TestPassed -and $passingResultAfterRestart.GuestPowerOffEvidenceRecoveryMode -eq 'ControlledReboot') 'A later agent restart clobbered a successful recovered result.'
    $scenarios.Add('expected-power-off-recovery-is-idempotent')

    $staleAgentErrorPath = Join-Path $passingOutput 'agent-error.json'
    [ordered]@{ Success = $false; Error = 'stale transient recovery failure' } | ConvertTo-Json | Set-Content -LiteralPath $staleAgentErrorPath -Encoding UTF8
    $passingHashBeforeStaleErrorRepair = (Get-FileHash -LiteralPath $passingResultPath -Algorithm SHA256).Hash
    $staleErrorSummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    Assert-True (
        $staleErrorSummary.ExpectedJobsAlreadyComplete -eq 1 -and
        -not (Test-Path -LiteralPath $staleAgentErrorPath) -and
        (Get-FileHash -LiteralPath $passingResultPath -Algorithm SHA256).Hash -eq $passingHashBeforeStaleErrorRepair
    ) 'A stale recovery agent-error survived a validated idempotent success or caused the terminal result to be rewritten.'
    $scenarios.Add('validated-recovery-removes-stale-agent-error')

    $script:forgedCleanupCalls = 0
    $script:forgedCleanupDriveLetters = @()
    Set-Item -LiteralPath Function:\script:Dismount-GuestHostInputs -Value {
        param([object[]] $MountedInputs)
        $script:forgedCleanupCalls++
        $script:forgedCleanupDriveLetters += @($MountedInputs | ForEach-Object { [string]$_.DriveLetter })
        [pscustomobject][ordered]@{
            Attempted = @($MountedInputs).Count -gt 0
            Success = $true
            Errors = @()
            UnmountedCount = @($MountedInputs).Count
        }
    }
    $forgedJobId = 'expected-power-off-forged-recovery'
    $forgedOutput = Join-Path $recoveryOutbox $forgedJobId
    New-Item -ItemType Directory -Force -Path $forgedOutput | Out-Null
    $forgedMarker = Join-Path $forgedOutput 'shutdown-marker.json'
    [ordered]@{ passed = $false } | ConvertTo-Json | Set-Content -LiteralPath $forgedMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $forgedMarker
    Write-SyntheticPowerOffLease -OutputPath $forgedOutput -JobId $forgedJobId
    [ordered]@{
        JobId = $forgedJobId
        Success = $true
        HarnessSucceeded = $true
        TestEvaluated = $true
        TestPassed = $true
        OverallSucceeded = $true
        FailureKind = $null
        TestFailureKind = $null
        TestFailureMessage = $null
        TestAssertion = [ordered]@{ Passed = $true }
        Error = $null
        GuestBootTimeUtc = '2026-08-31T00:00:00Z'
        RecoveryCompletedUtc = '2099-01-01T00:00:00Z'
        ExpectGuestPowerOff = $true
        GuestPowerOffEvidenceRecoveryMode = 'ControlledReboot'
        ApplicationRelaunchedByHarnessAfterGuestPowerOff = $false
        ResultFileEvidence = [ordered]@{ Exists = $true; Length = 999; Sha256 = 'FORGED' }
        ProcessCleanup = [ordered]@{ SatisfiedByGuestPowerCycle = $true }
        HostInputCleanup = [ordered]@{ Success = $false }
        Actions = @()
        ExpectedGuestPowerOffRecovery = [ordered]@{
            Mode = 'ControlledReboot'
            ApplicationRelaunchedByHarness = $false
            BootEvidence = [ordered]@{
                OriginalBootTimeSource = 'Lease'
                ControlledRebootProven = $true
                CurrentBootTimeUtc = '2099-01-01T00:00:00Z'
            }
        }
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $forgedOutput 'result.json') -Encoding UTF8
    $forgedJob = [ordered]@{
        id = $forgedJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        hostInputs = @([ordered]@{ Name = 'source'; DriveLetter = 'Q'; Username = 'u'; Password = 'forged-proof-secret' })
        actions = @()
    }
    $forgedJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($forgedJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $forgedResultRaw = Get-Content -Raw -LiteralPath (Join-Path $forgedOutput 'result.json')
    $forgedResult = $forgedResultRaw | ConvertFrom-Json
    Assert-True ($script:forgedCleanupCalls -gt 0 -and $script:forgedCleanupDriveLetters -contains 'Q' -and $forgedResult.HostInputCleanup.Success) 'AUT-forged recovery fields bypassed real persisted host-input cleanup.'
    Assert-True ($forgedResult.HarnessSucceeded -and $forgedResult.TestEvaluated -and -not $forgedResult.TestPassed -and $forgedResult.TestFailureKind -eq 'TestAssertion') 'AUT-forged recovery fields bypassed recovered marker re-evaluation.'
    Assert-True ([string]$forgedResult.RecoveryCompletedUtc -ne '2099-01-01T00:00:00Z' -and $forgedResultRaw -notlike '*forged-proof-secret*') 'AUT-forged recovery timestamp or private job data survived trusted recovery finalization.'
    $scenarios.Add('expected-power-off-forged-result-cannot-bypass-reverification')

    $deferredJobId = 'expected-power-off-same-boot'
    $deferredOutput = Join-Path $recoveryOutbox $deferredJobId
    New-Item -ItemType Directory -Force -Path $deferredOutput | Out-Null
    $deferredMarker = Join-Path $deferredOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $deferredMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $deferredMarker
    Write-SyntheticPowerOffLease -OutputPath $deferredOutput -JobId $deferredJobId
    $deferredJob = [ordered]@{
        id = $deferredJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @()
    }
    $deferredProcessingFile = Join-Path $recoveryProcessing ($deferredJobId + '.json')
    $deferredJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $deferredProcessingFile -Encoding UTF8
    $script:syntheticCurrentBootUtc = [DateTime]'2026-08-31T00:00:00Z'
    $deferredSummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    Assert-True ($deferredSummary.ExpectedJobsDeferred -ge 1 -and (Test-Path -LiteralPath $deferredProcessingFile) -and -not (Test-Path -LiteralPath (Join-Path $deferredOutput 'result.json'))) 'A same-boot supervisor restart finalized or moved the expected power-off job.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $recoveryInbox ($deferredJobId + '.json'))) -and (Test-Path -LiteralPath (Join-Path $deferredOutput 'lease.json'))) 'A same-boot expected power-off job was requeued or lost its boot-epoch lease.'
    $script:syntheticCurrentBootUtc = [DateTime]'2026-08-31T00:40:00Z'
    $laterBootSummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    $laterBootResult = Get-Content -Raw -LiteralPath (Join-Path $deferredOutput 'result.json') | ConvertFrom-Json
    Assert-True ($laterBootSummary.ExpectedJobsRecovered -eq 1 -and $laterBootResult.HarnessSucceeded -and $laterBootResult.ExpectedGuestPowerOffRecovery.BootEvidence.ControlledRebootProven) 'The deferred job did not finalize after a strictly later boot epoch.'
    Assert-True (-not (Test-Path -LiteralPath $deferredProcessingFile) -and (Test-Path -LiteralPath (Join-Path $recoveryCompleted ($deferredJobId + '.json')))) 'Later-boot recovery did not move the deferred job to Completed.'
    $scenarios.Add('expected-power-off-same-boot-defers-until-later-boot')

    $missingJobId = 'expected-power-off-missing'
    $missingOutput = Join-Path $recoveryOutbox $missingJobId
    New-Item -ItemType Directory -Force -Path $missingOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $missingOutput -JobId $missingJobId
    Set-Content -LiteralPath (Join-Path $missingOutput 'preserve-me.txt') -Value 'sentinel' -Encoding UTF8
    $missingJob = [ordered]@{
        id = $missingJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @()
    }
    $missingJobFile = Join-Path $recoveryCompleted ($missingJobId + '.json')
    $missingJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingJobFile -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $missingResult = Get-Content -Raw -LiteralPath (Join-Path $missingOutput 'result.json') | ConvertFrom-Json
    Assert-True ($missingResult.Success -and $missingResult.HarnessSucceeded -and $missingResult.TestEvaluated -and -not $missingResult.TestPassed -and -not $missingResult.OverallSucceeded) 'A missing shutdown marker was misclassified as a harness failure or success.'
    Assert-True ($null -eq $missingResult.FailureKind -and $missingResult.TestFailureKind -eq 'ResultFileMissing' -and -not $missingResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff) 'A missing shutdown marker lacks the typed test-failure/no-relaunch result.'
    Assert-True (Test-Path -LiteralPath (Join-Path $missingOutput 'preserve-me.txt')) 'Completed-job recovery deleted prior OUTDIR evidence.'
    $scenarios.Add('expected-power-off-missing-marker-is-test-failure')

    $emptyJobId = 'expected-power-off-empty'
    $emptyOutput = Join-Path $recoveryOutbox $emptyJobId
    New-Item -ItemType Directory -Force -Path $emptyOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $emptyOutput -JobId $emptyJobId
    New-Item -ItemType File -Force -Path (Join-Path $emptyOutput 'shutdown-marker.json') | Out-Null
    $emptyJob = [ordered]@{
        id = $emptyJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        actions = @()
    }
    $emptyJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($emptyJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $emptyResult = Get-Content -Raw -LiteralPath (Join-Path $emptyOutput 'result.json') | ConvertFrom-Json
    Assert-True ($emptyResult.HarnessSucceeded -and $emptyResult.TestEvaluated -and -not $emptyResult.TestPassed -and $emptyResult.TestFailureKind -eq 'ResultFileEmpty') 'An empty shutdown marker was not a typed test failure.'
    $scenarios.Add('expected-power-off-empty-marker-is-test-failure')

    $falseJobId = 'expected-power-off-false'
    $falseOutput = Join-Path $recoveryOutbox $falseJobId
    New-Item -ItemType Directory -Force -Path $falseOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $falseOutput -JobId $falseJobId
    $falseMarker = Join-Path $falseOutput 'shutdown-marker.json'
    [ordered]@{ passed = $false } | ConvertTo-Json | Set-Content -LiteralPath $falseMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $falseMarker
    $falseJob = [ordered]@{
        id = $falseJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @()
    }
    $falseJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($falseJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $falseResult = Get-Content -Raw -LiteralPath (Join-Path $falseOutput 'result.json') | ConvertFrom-Json
    Assert-True ($falseResult.Success -and $falseResult.HarnessSucceeded -and $falseResult.TestEvaluated -and -not $falseResult.TestPassed -and $falseResult.TestFailureKind -eq 'TestAssertion') 'A false persisted assertion was misclassified as an infrastructure failure.'
    $scenarios.Add('expected-power-off-false-assertion-is-test-failure')

    $postBootMarkerJobId = 'expected-power-off-post-boot-marker'
    $postBootMarkerOutput = Join-Path $recoveryOutbox $postBootMarkerJobId
    New-Item -ItemType Directory -Force -Path $postBootMarkerOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $postBootMarkerOutput -JobId $postBootMarkerJobId
    $postBootMarkerPath = Join-Path $postBootMarkerOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $postBootMarkerPath -Encoding UTF8
    (Get-Item -LiteralPath $postBootMarkerPath -Force).LastWriteTimeUtc = [DateTime]'2026-08-31T01:00:00Z'
    $postBootMarkerJob = [ordered]@{
        id = $postBootMarkerJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        actions = @()
    }
    $postBootMarkerJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($postBootMarkerJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $postBootMarkerResult = Get-Content -Raw -LiteralPath (Join-Path $postBootMarkerOutput 'result.json') | ConvertFrom-Json
    Assert-True (
        $postBootMarkerResult.HarnessSucceeded -and $postBootMarkerResult.TestEvaluated -and
        -not $postBootMarkerResult.TestPassed -and
        [string]$postBootMarkerResult.TestFailureKind -eq 'ResultFileNotPrePowerOff' -and
        $postBootMarkerResult.ResultFileEvidence.PredatesRecoveryBoot -is [bool] -and
        -not [bool]$postBootMarkerResult.ResultFileEvidence.PredatesRecoveryBoot
    ) 'A marker created after the controlled recovery boot was accepted as pre-power-off application evidence.'
    $scenarios.Add('post-recovery-boot-marker-is-rejected')

    $existingJobId = 'expected-power-off-existing-result'
    $existingOutput = Join-Path $recoveryOutbox $existingJobId
    New-Item -ItemType Directory -Force -Path $existingOutput | Out-Null
    $existingMarker = Join-Path $existingOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $existingMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $existingMarker
    Write-SyntheticPowerOffLease -OutputPath $existingOutput -JobId $existingJobId
    $existingActions = @([pscustomobject][ordered]@{ Type = 'wait_result_file'; Index = 1; Success = $true; TestPassed = $true })
    [ordered]@{
        JobId = $existingJobId
        Success = $true
        HarnessSucceeded = $true
        TestEvaluated = $true
        TestPassed = $true
        OverallSucceeded = $true
        FailureKind = $null
        TestFailureKind = $null
        TestFailureMessage = $null
        TestAssertion = [ordered]@{ Passed = $true }
        Error = $null
        StartedUtc = '2026-08-31T00:30:53Z'
        CompletedUtc = '2026-08-31T00:30:55Z'
        GuestBootTimeUtc = '2026-08-31T00:00:00Z'
        ProcessCleanup = [ordered]@{ Attempted = $false; Success = $true; DeferredUntilGuestPowerOffRecovery = $true }
        HostInputCleanup = [ordered]@{ Attempted = $false; Success = $true; DeferredUntilGuestPowerOffRecovery = $true }
        Actions = $existingActions
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $existingOutput 'result.json') -Encoding UTF8
    $privateTypedText = 'sensitive-text-must-not-enter-recovery-evidence'
    $existingJob = [ordered]@{
        id = $existingJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @(
            [ordered]@{ type = 'type_text'; text = $privateTypedText },
            [ordered]@{ type = 'wait_result_file'; path = '{OUTDIR}\shutdown-marker.json' }
        )
    }
    $existingJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($existingJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $existingResultRaw = Get-Content -Raw -LiteralPath (Join-Path $existingOutput 'result.json')
    $existingResult = $existingResultRaw | ConvertFrom-Json
    Assert-True ($existingResult.Success -and $existingResult.HarnessSucceeded -and $existingResult.TestPassed -and $existingResult.OverallSucceeded) 'Recovery changed a passing ordinary pre-power-off result.'
    Assert-True ($existingResult.GuestPowerOffEvidenceRecoveryMode -eq 'ControlledReboot' -and -not $existingResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff -and $existingResult.RecoveryCompletedUtc) 'An ordinary pre-power-off result was not enriched with controlled-reboot attestations.'
    Assert-True (($existingResult.Actions | ConvertTo-Json -Depth 8 -Compress) -eq ($existingActions | ConvertTo-Json -Depth 8 -Compress)) 'Existing action evidence changed during recovery enrichment.'
    Assert-True ($existingResult.ProcessCleanup.SatisfiedByGuestPowerCycle -and $existingResult.PrePowerOffProcessCleanup.DeferredUntilGuestPowerOffRecovery) 'Existing-result recovery did not replace deferred process cleanup with power-cycle proof.'
    Assert-True ($existingResult.PrePowerOffHostInputCleanup.DeferredUntilGuestPowerOffRecovery -and $existingResult.HostInputCleanup.Success) 'Existing-result recovery did not preserve prior cleanup metadata and record the real recovery cleanup.'
    Assert-True ($existingResult.ExpectedGuestPowerOffRecovery.RequestedActions.Count -eq 2 -and $existingResult.ExpectedGuestPowerOffRecovery.RequestedActions.Items[0].Type -eq 'type_text' -and $existingResultRaw -notlike ('*' + $privateTypedText + '*')) 'Recovery evidence copied raw action values instead of a bounded redacted summary.'
    $existingRecoveryLease = Get-Content -Raw -LiteralPath (Join-Path $existingOutput 'lease.json') | ConvertFrom-Json
    Assert-True ($existingRecoveryLease.RecoveryResultSha256 -eq (Get-FileHash -LiteralPath (Join-Path $existingOutput 'result.json') -Algorithm SHA256).Hash -and $existingRecoveryLease.RecoveryMarkerSha256 -eq (Get-FileHash -LiteralPath (Join-Path $existingOutput 'shutdown-marker.json') -Algorithm SHA256).Hash -and -not $existingRecoveryLease.ApplicationRelaunchedByHarnessAfterGuestPowerOff) 'Existing-result recovery did not retain a result/marker-bound no-relaunch completion proof.'
    $scenarios.Add('expected-power-off-existing-result-enriched-without-relaunch')

    $existingMarkerFailureId = 'expected-power-off-existing-marker-fails'
    $existingMarkerFailureOutput = Join-Path $recoveryOutbox $existingMarkerFailureId
    New-Item -ItemType Directory -Force -Path $existingMarkerFailureOutput | Out-Null
    $existingMarkerFailureMarker = Join-Path $existingMarkerFailureOutput 'shutdown-marker.json'
    [ordered]@{ passed = $false } | ConvertTo-Json | Set-Content -LiteralPath $existingMarkerFailureMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $existingMarkerFailureMarker
    Write-SyntheticPowerOffLease -OutputPath $existingMarkerFailureOutput -JobId $existingMarkerFailureId
    [ordered]@{
        JobId = $existingMarkerFailureId; Success = $true; HarnessSucceeded = $true; TestEvaluated = $true; TestPassed = $true; OverallSucceeded = $true
        FailureKind = $null; TestFailureKind = $null; TestFailureMessage = $null; TestAssertion = [ordered]@{ Passed = $true }; Error = $null
        GuestBootTimeUtc = '2026-08-31T00:00:00Z'; Actions = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $existingMarkerFailureOutput 'result.json') -Encoding UTF8
    $existingMarkerFailureJob = [ordered]@{
        id = $existingMarkerFailureId; expectGuestPowerOff = $true; assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'; assertResultEqualsJson = 'true'; actions = @()
    }
    $existingMarkerFailureJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($existingMarkerFailureId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $existingMarkerFailureResult = Get-Content -Raw -LiteralPath (Join-Path $existingMarkerFailureOutput 'result.json') | ConvertFrom-Json
    Assert-True ($existingMarkerFailureResult.HarnessSucceeded -and $existingMarkerFailureResult.TestEvaluated -and -not $existingMarkerFailureResult.TestPassed -and -not $existingMarkerFailureResult.OverallSucceeded -and $existingMarkerFailureResult.TestFailureKind -eq 'TestAssertion') 'Recovered marker re-evaluation failed to turn a stale pre-power-off pass into a typed test failure.'
    $scenarios.Add('expected-power-off-existing-result-rechecks-marker')

    $existingFalseId = 'expected-power-off-existing-false-stays-false'
    $existingFalseOutput = Join-Path $recoveryOutbox $existingFalseId
    New-Item -ItemType Directory -Force -Path $existingFalseOutput | Out-Null
    $existingFalseMarker = Join-Path $existingFalseOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $existingFalseMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $existingFalseMarker
    Write-SyntheticPowerOffLease -OutputPath $existingFalseOutput -JobId $existingFalseId
    [ordered]@{
        JobId = $existingFalseId; Success = $true; HarnessSucceeded = $true; TestEvaluated = $true; TestPassed = $false; OverallSucceeded = $false
        FailureKind = $null; TestFailureKind = 'PrePowerOffFailure'; TestFailureMessage = 'preserve this failure'; TestAssertion = $null; Error = $null
        GuestBootTimeUtc = '2026-08-31T00:00:00Z'; Actions = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $existingFalseOutput 'result.json') -Encoding UTF8
    $existingFalseJob = [ordered]@{ id = $existingFalseId; expectGuestPowerOff = $true; assertResultFile = '{OUTDIR}\shutdown-marker.json'; actions = @() }
    $existingFalseJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($existingFalseId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $existingFalseResult = Get-Content -Raw -LiteralPath (Join-Path $existingFalseOutput 'result.json') | ConvertFrom-Json
    Assert-True ($existingFalseResult.HarnessSucceeded -and $existingFalseResult.TestEvaluated -and -not $existingFalseResult.TestPassed -and $existingFalseResult.TestFailureKind -eq 'PrePowerOffFailure') 'Recovery incorrectly changed an existing test failure into a pass.'
    $scenarios.Add('expected-power-off-existing-failure-cannot-turn-pass')

    $invalidJobId = 'expected-power-off-invalid-contract'
    $invalidOutput = Join-Path $recoveryOutbox $invalidJobId
    New-Item -ItemType Directory -Force -Path $invalidOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $invalidOutput -JobId $invalidJobId
    $invalidJob = [ordered]@{ id = $invalidJobId; expectGuestPowerOff = $true; actions = @() }
    $invalidJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($invalidJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $invalidResult = Get-Content -Raw -LiteralPath (Join-Path $invalidOutput 'result.json') | ConvertFrom-Json
    Assert-True (-not $invalidResult.Success -and -not $invalidResult.HarnessSucceeded -and -not $invalidResult.TestEvaluated -and $invalidResult.FailureKind -eq 'ExpectedGuestPowerOffRecoveryContract') 'A malformed expected-power-off contract was not kept separate from an evaluated test failure.'
    $scenarios.Add('expected-power-off-malformed-contract-is-harness-failure')

    $reservedJobId = 'expected-power-off-reserved-marker'
    $reservedOutput = Join-Path $recoveryOutbox $reservedJobId
    New-Item -ItemType Directory -Force -Path $reservedOutput | Out-Null
    Write-SyntheticPowerOffLease -OutputPath $reservedOutput -JobId $reservedJobId
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reservedOutput 'result.json') -Encoding UTF8
    $reservedJob = [ordered]@{
        id = $reservedJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\result.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        actions = @()
    }
    $reservedJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($reservedJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $reservedResult = Get-Content -Raw -LiteralPath (Join-Path $reservedOutput 'result.json') | ConvertFrom-Json
    Assert-True (-not $reservedResult.HarnessSucceeded -and -not $reservedResult.TestEvaluated -and $reservedResult.FailureKind -eq 'ExpectedGuestPowerOffRecoveryContract' -and $reservedResult.Error -like '*reserved guest protocol file*') 'A root-level reserved protocol filename was accepted as the application marker.'
    $scenarios.Add('expected-power-off-reserved-marker-rejected')

    $script:recoveryCleanupDefinitions = @()
    Set-Item -LiteralPath Function:\script:Dismount-GuestHostInputs -Value {
        param([object[]] $MountedInputs)
        $script:recoveryCleanupDefinitions += @($MountedInputs)
        [pscustomobject][ordered]@{
            Attempted = @($MountedInputs).Count -gt 0
            Success = $true
            Errors = @()
            UnmountedCount = @($MountedInputs).Count
        }
    }
    $hostInputJobId = 'expected-power-off-host-input-cleanup'
    $hostInputOutput = Join-Path $recoveryOutbox $hostInputJobId
    New-Item -ItemType Directory -Force -Path $hostInputOutput | Out-Null
    $hostInputMarker = Join-Path $hostInputOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $hostInputMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $hostInputMarker
    Write-SyntheticPowerOffLease -OutputPath $hostInputOutput -JobId $hostInputJobId
    $hostInputJob = [ordered]@{
        id = $hostInputJobId
        expectGuestPowerOff = $true
        assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'
        assertResultEqualsJson = 'true'
        hostInputs = @([ordered]@{
            Name = 'source'
            DriveLetter = 'Q'
            RemotePath = '\\192.0.2.1\CHVRO_SYNTHETIC'
            Username = 'synthetic-user'
            Password = 'ephemeral-secret-must-not-enter-result'
            GuestSubPath = 'src'
        })
        actions = @()
    }
    $hostInputJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($hostInputJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $hostInputResultRaw = Get-Content -Raw -LiteralPath (Join-Path $hostInputOutput 'result.json')
    $hostInputResult = $hostInputResultRaw | ConvertFrom-Json
    Assert-True ($script:recoveryCleanupDefinitions.Count -ge 1 -and $script:recoveryCleanupDefinitions.DriveLetter -contains 'Q') 'Expected power-off recovery did not route persisted host-input mappings through Dismount-GuestHostInputs.'
    Assert-True ($hostInputResult.HarnessSucceeded -and $hostInputResult.HostInputCleanup.Attempted -and $hostInputResult.HostInputCleanup.Success -and $hostInputResult.HostInputCleanup.UnmountedCount -eq 1) 'Successful persisted host-input cleanup was not recorded honestly.'
    Assert-True (-not $hostInputResult.HostInputCleanup.PSObject.Properties['SatisfiedByGuestPowerCycle'] -and $hostInputResult.HostInputs[0].DriveLetter -eq 'Q') 'Host-input cleanup was incorrectly claimed as power-cycle-only or omitted its sanitized mapping.'
    Assert-True ($hostInputResultRaw -notlike '*ephemeral-secret-must-not-enter-result*' -and $hostInputResultRaw -notlike '*synthetic-user*') 'Recovery evidence serialized an ephemeral host-input credential.'
    $scenarios.Add('expected-power-off-host-input-cleanup-real-and-redacted')

    Set-Item -LiteralPath Function:\script:Dismount-GuestHostInputs -Value {
        param([object[]] $MountedInputs)
        [pscustomobject][ordered]@{
            Attempted = @($MountedInputs).Count -gt 0
            Success = $false
            Errors = @('synthetic persisted mapping survived')
            UnmountedCount = 0
        }
    }
    $hostInputFailureJobId = 'expected-power-off-host-input-failure'
    $hostInputFailureOutput = Join-Path $recoveryOutbox $hostInputFailureJobId
    New-Item -ItemType Directory -Force -Path $hostInputFailureOutput | Out-Null
    $hostInputFailureMarker = Join-Path $hostInputFailureOutput 'shutdown-marker.json'
    [ordered]@{ passed = $true } | ConvertTo-Json | Set-Content -LiteralPath $hostInputFailureMarker -Encoding UTF8
    Set-SyntheticPreRecoveryMarkerTime -Path $hostInputFailureMarker
    Write-SyntheticPowerOffLease -OutputPath $hostInputFailureOutput -JobId $hostInputFailureJobId
    $hostInputFailureJob = [ordered]@{
        id = $hostInputFailureJobId; expectGuestPowerOff = $true; assertResultFile = '{OUTDIR}\shutdown-marker.json'
        assertResultJsonPointer = '/passed'; assertResultEqualsJson = 'true'
        hostInputs = @([ordered]@{ Name = 'source'; DriveLetter = 'Q'; Username = 'u'; Password = 'p' }); actions = @()
    }
    $hostInputFailureJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recoveryCompleted ($hostInputFailureJobId + '.json')) -Encoding UTF8
    Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox | Out-Null
    $hostInputFailureResult = Get-Content -Raw -LiteralPath (Join-Path $hostInputFailureOutput 'result.json') | ConvertFrom-Json
    Assert-True (-not $hostInputFailureResult.HarnessSucceeded -and $hostInputFailureResult.TestEvaluated -and $hostInputFailureResult.TestPassed -and $hostInputFailureResult.FailureKind -eq 'HostInputCleanup' -and -not $hostInputFailureResult.OverallSucceeded) 'Persisted host-input cleanup failure was not a guest harness failure separate from the marker test.'
    $scenarios.Add('expected-power-off-host-input-cleanup-failure-is-harness-failure')

    $legacyJobId = 'legacy-orphan'
    $legacyOutput = Join-Path $recoveryOutbox $legacyJobId
    New-Item -ItemType Directory -Force -Path $legacyOutput | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyOutput 'prior.txt') -Value 'prior' -Encoding UTF8
    $legacyJob = [ordered]@{ id = $legacyJobId; expectGuestPowerOff = 'true'; actions = @() }
    $legacyProcessingFile = Join-Path $recoveryProcessing ($legacyJobId + '.json')
    $legacyJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyProcessingFile -Encoding UTF8
    $legacySummary = Repair-InterruptedGuestJobs -InboxRoot $recoveryInbox -ProcessingRoot $recoveryProcessing -CompletedRoot $recoveryCompleted -OutboxRoot $recoveryOutbox
    Assert-True ($legacySummary.LegacyJobsRequeued -eq 1 -and (Test-Path -LiteralPath (Join-Path $recoveryInbox ($legacyJobId + '.json'))) -and -not (Test-Path -LiteralPath $legacyProcessingFile)) 'Legacy orphan recovery no longer requeues interrupted jobs exactly once.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyOutput 'result.json'))) 'A non-Boolean expected-power-off value entered recovery instead of the legacy retry path.'
    $scenarios.Add('legacy-orphan-requeue-unchanged')

    $completeRecoveryAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-ExpectedGuestPowerOffJob' }, $true)) | Select-Object -First 1
    $completeRecoveryText = $completeRecoveryAst.Extent.Text
    Assert-True ($completeRecoveryText -notlike '*Start-Process*') 'Expected power-off recovery can relaunch the application.'
    Assert-True ($completeRecoveryText -notmatch 'Remove-Item\s+[^\r\n]*-Recurse') 'Expected power-off recovery can delete OUTDIR recursively.'
    Assert-True ($completeRecoveryText -like '*Dismount-GuestHostInputs -MountedInputs $hostInputDefinitions*' -and $completeRecoveryText -like '*Get-RedactedGuestActionSummary*' -and $completeRecoveryText -notlike '*RequestedActions = @($Job.actions)*') 'Expected power-off recovery omits real host-input cleanup or can serialize raw actions.'

    $invokeGuestJobAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GuestJob' }, $true)) | Select-Object -First 1
    $invokeGuestJobText = $invokeGuestJobAst.Extent.Text
    Assert-True ($invokeGuestJobText -like '*if ($process -and -not $expectGuestPowerOff)*Stop-GuestProcessTree*') 'Ordinary finalization does not guard process-tree cleanup from the expected-power-off contract.'
    Assert-True ($invokeGuestJobText -like '*if ($expectGuestPowerOff)*DeferredUntilGuestPowerOffRecovery = $true*else*Dismount-GuestHostInputs*') 'Ordinary finalization can dismount host inputs before the expected power cycle.'
    Assert-True ($invokeGuestJobText -like '*if (-not $expectGuestPowerOff)*Remove-Item -LiteralPath $leasePath*' -and $invokeGuestJobText -like '*GuestBootTimeUtc = $guestBootTimeUtc*') 'Expected power-off finalization does not preserve a boot-epoch lease.'
    $legacyEnvelopeStart = $invokeGuestJobText.IndexOf('$resultEnvelope = [ordered]@{', [StringComparison]::Ordinal)
    $legacyEnvelopeEnd = $invokeGuestJobText.IndexOf('if ($expectGuestPowerOff)', $legacyEnvelopeStart + 1, [StringComparison]::Ordinal)
    Assert-True (
        $legacyEnvelopeStart -ge 0 -and $legacyEnvelopeEnd -gt $legacyEnvelopeStart -and
        -not $invokeGuestJobText.Substring($legacyEnvelopeStart, $legacyEnvelopeEnd - $legacyEnvelopeStart).Contains('GuestBootTimeUtc') -and
        $invokeGuestJobText.Substring($legacyEnvelopeEnd).Contains("`$resultEnvelope['GuestBootTimeUtc'] = `$guestBootTimeUtc")
    ) 'The ordinary legacy result envelope still exposes the opt-in GuestBootTimeUtc recovery field.'
    $scenarios.Add('legacy-result-omits-power-off-boot-field')
    $scenarios.Add('expected-power-off-recovery-static-no-relaunch-or-early-cleanup')

    $syntheticProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 10; Name = 'wrapper.exe'; ExecutablePath = 'C:\payload\wrapper.exe' },
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'electron.exe'; ExecutablePath = 'C:\payload\electron.exe' },
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = 'node.exe'; ExecutablePath = 'C:\payload\node.exe' },
        [pscustomobject]@{ ProcessId = 103; ParentProcessId = 102; Name = 'helper.exe'; ExecutablePath = 'C:\payload\helper.exe' },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 10; Name = 'unrelated.exe'; ExecutablePath = 'C:\Windows\unrelated.exe' }
    )
    $processTree = @(Get-GuestProcessTree -RootProcessId 100 -ProcessSnapshot $syntheticProcesses)
    Assert-True ($processTree.Count -eq 4) 'Process-tree discovery omitted descendants or included an unrelated process.'
    Assert-True (($processTree.ProcessId -join ',') -eq '103,102,101,100') 'Process-tree discovery was not deepest-child-first.'
    Assert-True (($processTree.Depth -join ',') -eq '3,2,1,0') 'Process-tree depth calculation was incorrect.'
    $orphanTree = @(Get-GuestProcessTree -RootProcessId 100 -ProcessSnapshot @($syntheticProcesses | Where-Object ProcessId -ne 100))
    Assert-True (($orphanTree.ProcessId -join ',') -eq '103,102,101') 'Detached descendants were not discoverable after their root process exited.'
    $scenarios.Add('process-tree-discovers-detached-descendants')

    $cleanupIndex = $invokeGuestJobText.LastIndexOf('$processCleanup = Stop-GuestProcessTree', [StringComparison]::Ordinal)
    $leaseRemovalIndex = $invokeGuestJobText.LastIndexOf('Remove-Item -LiteralPath $leasePath', [StringComparison]::Ordinal)
    $resultWriteIndex = $invokeGuestJobText.LastIndexOf('Write-JsonAtomic -Path $resultFile', [StringComparison]::Ordinal)
    Assert-True ($cleanupIndex -ge 0 -and $cleanupIndex -lt $leaseRemovalIndex -and $leaseRemovalIndex -lt $resultWriteIndex) 'The guest publishes completion before verified process-tree cleanup.'
    Assert-True ($invokeGuestJobText -like '*ProcessCleanup = $processCleanup*') 'The guest result omits process-tree cleanup evidence.'
    $scenarios.Add('process-tree-cleanup-precedes-terminal-result')

    function Wait-CaptureDesktopReady {
        param([int] $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ Ready = $true; Error = $null; SessionId = 1; Width = 1920; Height = 1080 }
    }
    $script:captureAttempt = 0
    function Invoke-ScreenCaptureHelper {
        param([string] $Path, [string] $ErrorPath, [int] $TimeoutMilliseconds)
        $script:captureAttempt++
        if ($script:captureAttempt -lt 3) {
            return [pscustomobject][ordered]@{ Success = $false; Error = 'synthetic invalid handle'; TimedOut = $false }
        }
        [pscustomobject][ordered]@{ Success = $true; Error = $null; TimedOut = $false }
    }
    $capture = Capture-Screen -Path (Join-Path $testRoot 'synthetic.png') -TimeoutMilliseconds 5000 -Attempts 5
    Assert-True ($capture.Attempts -eq 3 -and $capture.AttemptLog.Count -eq 3) 'Capture retry did not recover on the third attempt.'
    Assert-True ($capture.ElapsedMilliseconds -ge 1400 -and $capture.ElapsedMilliseconds -lt 5000) 'Capture retry did not use bounded exponential backoff.'
    $scenarios.Add('capture-exponential-retry-recovers')

    function Invoke-ScreenCaptureHelper {
        param([string] $Path, [string] $ErrorPath, [int] $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ Success = $false; Error = 'synthetic invalid handle'; TimedOut = $false }
    }
    $captureFailure = $null
    try { Capture-Screen -Path (Join-Path $testRoot 'failure.png') -TimeoutMilliseconds 3000 -Attempts 2 | Out-Null }
    catch { $captureFailure = $_.Exception.Message }
    Assert-True ($captureFailure -like '[[]CAPTURE_INFRASTRUCTURE[]]*' -and $captureFailure -like '*after 2 attempts*') 'Persistent capture failure was not classified for worker replay.'
    $scenarios.Add('capture-failure-classified')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
