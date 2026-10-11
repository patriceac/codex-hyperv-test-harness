$ErrorActionPreference='Stop'
$source=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\HostBroker.ps1'),[ref]$null,[ref]$null)
$function=$source.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-TestVm'},$true)
. ([scriptblock]::Create($function.Extent.Text))
function Get-VM { [pscustomobject]@{State='Stopping'} }
function Stop-VM { throw 'A second power operation was issued while the VM was already stopping.' }
function Wait-TestVmOff {
    param($VmName,$TimeoutSeconds)
    if($VmName -ne 'synthetic' -or $TimeoutSeconds -ne 60){throw 'Pending shutdown did not use the bounded Off-state verification.'}
    $script:waits++
}
$script:waits=0
Stop-TestVm -VmName synthetic
Stop-TestVm -VmName synthetic -Immediate
if($script:waits -ne 2){throw 'Both cleanup modes must verify an already-stopping VM reaches Off.'}
$script:vmState='Running'
$script:shutdownRequests=0
function Get-VM { [pscustomobject]@{State=$script:vmState} }
function Stop-VM {
    [CmdletBinding()]
    param([string]$Name,[switch]$TurnOff,[switch]$Force,[switch]$AsJob)
    if($Name -ne 'synthetic' -or $TurnOff -or $Force -or -not $AsJob){throw 'Graceful cleanup must request the supported asynchronous guest shutdown.'}
    $script:shutdownRequests++
    $script:vmState='Off'
}
function Start-Sleep { throw 'The supported shutdown request should have reached Off without fallback polling.' }
Stop-TestVm -VmName synthetic
if($script:shutdownRequests -ne 1 -or $script:waits -ne 2){throw 'Graceful cleanup did not complete its single shutdown request.'}
# Run the actual request finalizer through its power-off boundary. Evidence is
# already copied; closing Direct and failed advisory writes must not start a
# competing guest shutdown or prevent the disposable worker reaching Off.
$finalizer=$source.Find({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Finally -and $node.Finally.Statements[0].Extent.Text -like '$brokerCleanupStartedUtc*'},$true).Finally
$cleanupStatements=foreach($statement in $finalizer.Statements){
    $statement.Extent.Text
    if($statement -is [Management.Automation.Language.IfStatementAst] -and $statement.Clauses[0].Item1.Extent.Text -eq '$Request.StopAfter'){break}
}
$Request=[pscustomobject]@{StopAfter=$true}
$session='synthetic-session'; $vmName='synthetic'; $success=$true
$liveEvidenceContext=$requestNetworkRuntime=$guestRestartStarted=$installerStarted=$systemPromptRuntime=$null
$evidenceWarnings=New-Object 'System.Collections.Generic.List[string]'
$script:sessionClosed=$false; $script:vmState='Running'; $script:shutdownRequests=0; $script:guestShutdownRequests=0
function Remove-PSSession { $script:sessionClosed=$true }
function Invoke-Command { $script:guestShutdownRequests++; throw 'A duplicate guest shutdown was requested.' }
function Write-BrokerState { throw 'Synthetic advisory write failure.' }
function Write-RequestState { throw 'Synthetic advisory write failure.' }
function Stop-VM {
    [CmdletBinding()]
    param([string]$Name,[switch]$TurnOff,[switch]$Force,[switch]$AsJob)
    if($Name -ne 'synthetic' -or -not $script:sessionClosed -or -not $TurnOff -or -not $Force -or $AsJob){throw 'Request cleanup must close Direct and issue one immediate worker power-off.'}
    $script:shutdownRequests++; $script:vmState='Off'
}
function Wait-TestVmOff { if($script:vmState -ne 'Off'){throw 'Worker cleanup did not verify Off.'} }
& ([scriptblock]::Create(($cleanupStatements -join "`n")))
if(-not $success -or $script:guestShutdownRequests -ne 0 -or $script:shutdownRequests -ne 1 -or $script:vmState -ne 'Off' -or $evidenceWarnings.Count -ne 2){throw 'Request cleanup did not preserve the result and stop the worker exactly once despite advisory write failures.'}
[pscustomobject]@{Success=$true;ScenarioCount=4}
