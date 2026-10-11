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
[pscustomobject]@{Success=$true;ScenarioCount=3}
