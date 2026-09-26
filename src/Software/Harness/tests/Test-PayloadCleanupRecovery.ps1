$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$harnessRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $harnessRoot 'PayloadCache.ps1')
$brokerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $harnessRoot 'HostBroker.ps1'), [ref]$null, [ref]$null)
. ([scriptblock]::Create($brokerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-TerminalJsonAtomic'}, $true).Extent.Text))
$testRoot = Join-Path $harnessRoot ('..\..\..\work\payload-cleanup-' + [Guid]::NewGuid().ToString('N'))
$resultsPath = Join-Path $testRoot 'Results'
$payloadChildrenPath = Join-Path $testRoot 'Children'
$payloadLeasePath = Join-Path $testRoot 'Leases'
$requestPath = Join-Path $testRoot 'Requests'
$processingPath = Join-Path $testRoot 'Processing'
function Assert-PathInsideRoot { param($Path, $Root, $Purpose) $Path }
function Read-BrokerJsonWithRetry { param($Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Get-VM { [CmdletBinding()] param($Name) [pscustomobject]@{State=$script:vmState} }
function Get-VMHardDiskDrive { [CmdletBinding()] param($VMName) if ($script:attached) { [pscustomobject]@{Path=$script:childPath} } }
$checks = 0
foreach ($case in @('clean','child','lease','queued','processing','running','attached','wrong-child','wrong-request','unreadable')) {
    $id = 'cleanup-' + $case
    $root = Join-Path $resultsPath $id
    $null = New-Item -ItemType Directory -Path $root
    $script:childPath = Join-Path $payloadChildrenPath ($id + '.vhdx')
    $originalPath = Join-Path $root 'broker-result.json'
    $receiptPath = Join-Path $root 'cleanup-recovery.json'
    $original = @{RequestId=$id;VmName='worker';FailureKind='HarnessCleanup';HarnessSucceeded=$false;TestPassed=$true;PayloadChildDeleted=$false;PayloadChildVhdx=$script:childPath}
    if ($case -eq 'wrong-child') { $original.PayloadChildVhdx = Join-Path $payloadChildrenPath 'other.vhdx' }
    if ($case -eq 'wrong-request') { $original.RequestId = 'other-request' }
    $original | ConvertTo-Json | Set-Content -LiteralPath $originalPath -Encoding UTF8
    if ($case -eq 'unreadable') { '{' | Set-Content -LiteralPath $originalPath -Encoding UTF8 }
    $before = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash
    $script:vmState = if ($case -eq 'running') { 'Running' } else { 'Off' }
    $script:attached = $case -eq 'attached'
    $residue = switch ($case) { child {$script:childPath} lease {Join-Path $payloadLeasePath ($id+'.json')} queued {Join-Path $requestPath ($id+'.json')} processing {Join-Path $processingPath ($id+'.json')} }
    if ($residue) { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $residue) -Force; '' | Set-Content -LiteralPath $residue }
    $caught = $false
    try { Publish-RecoveredPayloadCleanup -RequestId $id -VmName @('worker') } catch { if ($case -ne 'unreadable') { throw }; $caught=$true }
    if ($case -eq 'clean') {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if (-not $receipt.PayloadCleanupRecovered -or -not $receipt.PayloadChildDetached -or -not $receipt.PayloadLeaseDeleted -or $receipt.OriginalResult.Sha256 -cne $before -or $receipt.OriginalResult.HarnessSucceeded -or -not $receipt.OriginalResult.TestPassed) { throw 'Recovery receipt lost its verified scope or original verdict binding.' }
        $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
        Publish-RecoveredPayloadCleanup -RequestId $id -VmName @('worker')
        if ((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -cne $receiptHash) { throw 'An existing recovery receipt was overwritten.' }
    } elseif ((Test-Path -LiteralPath $receiptPath) -or ($case -eq 'unreadable' -and -not $caught)) { throw "Unverified cleanup published a receipt: $case" }
    if ((Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -cne $before) { throw 'Historical failure evidence changed.' }
    $checks++
}
[pscustomobject]@{Success=$true;ScenarioCount=$checks} | ConvertTo-Json
