[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$broker = Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($broker, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0].Message }
function Import-Function($Name) {
    $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    Set-Item -LiteralPath ('Function:script:' + $Name) -Value ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
}
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
foreach ($name in @('Save-GuestRestartFailureEvidence','Read-BrokerJsonWithRetry')) { Import-Function $name }
$workRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\work'))
$testRoot = Join-Path $workRoot ('restart-failure-' + [Guid]::NewGuid().ToString('N'))
$probePath = Join-Path $testRoot 'probes'
$ResultRoot = Join-Path $testRoot 'result'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
New-Item -ItemType Directory -Path $ResultRoot -Force | Out-Null
$script:transferCalls = 0
$script:transferError = $false
$script:publishedAcl = $false
function Set-HostLiveEvidencePublishedAcl {
    param($Path,$ClientSid)
    # The real broker is SYSTEM. Avoid reducing the unelevated test owner to
    # client-read before it can move its fixture; live acceptance verifies access.
    Check ($ClientSid -eq $sid -and (Test-Path -LiteralPath (Join-Path $Path 'product-data\restart-session.resume'))) 'Publication did not request client access for the verified stage.'
    $script:publishedAcl = $true
}
function Invoke-ExpectedPowerOffEvidenceTransferBounded {
    param($VmName,$RequestId,$ExecutionDeadlineUtc,$GuestOutbox,$HostResultRoot,[switch]$FailureDiagnostics)
    Check ($FailureDiagnostics -and $GuestOutbox -eq 'C:\CodexGuest\Outbox\synthetic' -and $HostResultRoot -eq $ResultRoot) 'Failure harvest lost its exact output binding.'
    $script:transferCalls++
    if ($script:transferError) { throw 'synthetic unavailable guest' }
    $stage = Join-Path $probePath ('EvidenceTransfers\' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $stage 'product-data') -Force | Out-Null
    '{"Ready":false}' | Set-Content -LiteralPath (Join-Path $stage 'before-restart.json')
    'resume-state' | Set-Content -LiteralPath (Join-Path $stage 'product-data\restart-session.resume')
    @{ CopiedFiles = @('before-restart.json','product-data\restart-session.resume'); SkippedFiles = @(); EnumerationErrors = @() } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'evidence-copy-manifest.json')
    [pscustomobject]@{HostStageRoot=$stage}
}
try {
    $guestRestartStarted = $true; $installerStarted = $false; $success = $false; $evidenceTransferSucceeded = $false
    $vmName = 'synthetic'; $requestId = 'synthetic'; $guestOutbox = 'C:\CodexGuest\Outbox\synthetic'; $Config = @{ClientSid=$sid}
    $failureKind = 'Cancelled'; $cancelled = $true; $guestResult = $null; $failureStage = 'GuestRestartContinuation'; $errorMessage = 'original cancellation'
    $gate = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '($guestRestartStarted -or $installerStarted) -and -not $success -and -not $evidenceTransferSucceeded' }, $true)
    Check ($null -ne $gate) 'Failure harvest cleanup gate is missing.'
    . ([scriptblock]::Create($gate.Extent.Text))
    Check ($transferCalls -eq 1 -and $failureEvidence.Retained -and -not $failureEvidence.Partial -and $failureEvidence.CopiedFiles -eq 2) 'Failure files were not retained once.'
    Check ((Get-Content -Raw -LiteralPath (Join-Path $ResultRoot 'failure-diagnostics\before-restart.json') | ConvertFrom-Json).Ready -eq $false) 'False marker was changed or discarded.'
    Check ((Get-Content -LiteralPath (Join-Path $ResultRoot 'failure-diagnostics\product-data\restart-session.resume')) -eq 'resume-state') 'Resume diagnostics were lost.'
    Check ($failureKind -eq 'Cancelled' -and $cancelled -and $null -eq $guestResult -and -not $success -and $failureStage -eq 'GuestRestartContinuation' -and $errorMessage -eq 'original cancellation') 'Diagnostic collection changed the original failure.'
    Check $publishedAcl 'Diagnostics were published without applying the client-read ACL.'
    $ResultRoot = Join-Path $testRoot 'unavailable'; New-Item -ItemType Directory -Path $ResultRoot | Out-Null
    $guestRestartStarted = $false; $installerStarted = $true
    $script:transferError = $true; $failureKind = 'Harness'; $cancelled = $false
    . ([scriptblock]::Create($gate.Extent.Text))
    Check (-not $failureEvidence.Retained -and $failureEvidence.Error -eq 'synthetic unavailable guest' -and $failureKind -eq 'Harness' -and -not $cancelled -and $null -eq $guestResult) 'Harvest failure replaced the original early failure.'
    foreach ($success in @($true,$false)) {
        $evidenceTransferSucceeded = -not $success
        . ([scriptblock]::Create($gate.Extent.Text))
    }
    Check ($transferCalls -eq 2) 'Successful or already-transferred requests collected duplicate diagnostics.'
    $text = Get-Content -Raw -LiteralPath $broker
    $cleanup = $text.IndexOf('if ($requestNetworkRuntime -and -not $requestNetworkCleanupPerformed)')
    Check ($cleanup -lt $gate.Extent.StartOffset -and $gate.Extent.StartOffset -lt $text.IndexOf('if ($Request.StopAfter -and $session)')) 'Harvest must follow network revocation and precede VM stop.'

    Import-Function 'Invoke-ExpectedPowerOffEvidenceTransferBounded'
    $script:started = $false; $script:stopped = $false
    function Assert-RequestActive { param($RequestId,$ExecutionDeadlineUtc) throw [OperationCanceledException]::new('cancelled') }
    function Start-ExpectedPowerOffEvidenceTransfer {
        param($VmName,$RequestId,$SnapshotId,$GuestOutbox,$HostResultRoot,$OutputPath,[switch]$FailureDiagnostics)
        Check $FailureDiagnostics 'Cleanup transfer lost bounded failure mode.'
        $script:started = $true
        $process = [pscustomobject]@{HasExited=$false}; $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
        [pscustomobject]@{Process=$process;LeasePath='synthetic'}
    }
    function Stop-GuestProbeProcess { param($Process,$LeasePath) $script:stopped = $true }
    $transferParameters = @{VmName='synthetic';RequestId='synthetic';ExecutionDeadlineUtc=[DateTime]::UtcNow.AddMinutes(-1);GuestOutbox=$guestOutbox;HostResultRoot=$ResultRoot;AttemptTimeoutSeconds=5}
    try { Invoke-ExpectedPowerOffEvidenceTransferBounded @transferParameters | Out-Null; throw 'Expected cancellation.' } catch { Check (-not $started) 'Ordinary transfer ignored cancellation.' }
    $watch = [Diagnostics.Stopwatch]::StartNew(); $bounded = $false
    try { Invoke-ExpectedPowerOffEvidenceTransferBounded @transferParameters -FailureDiagnostics | Out-Null } catch { $bounded = $_.Exception.Message -like '*exceeded 5 seconds*' }
    Check ($bounded -and $started -and $stopped -and $watch.Elapsed.TotalSeconds -lt 8) 'Cancelled request diagnostics lacked an independent bounded watchdog.'
    $script:started = $false; $transferParameters.GuestOutbox = 'C:\CodexGuest\Outbox\other-request'
    try { Invoke-ExpectedPowerOffEvidenceTransferBounded @transferParameters -FailureDiagnostics | Out-Null } catch { }
    Check (-not $started) 'Failure diagnostics accepted another request output.'
}
finally {
    if ([IO.Path]::GetFullPath($testRoot).StartsWith($workRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -ErrorAction SilentlyContinue }
}
[pscustomobject]@{Success=$true;ScenarioCount=4;Scenarios=@('failure-files-and-original-outcome','unavailable-guest-and-no-duplicate-harvest','independent-cleanup-watchdog','request-output-containment')} | ConvertTo-Json
