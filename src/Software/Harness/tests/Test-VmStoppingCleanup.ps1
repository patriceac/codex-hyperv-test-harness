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
[pscustomobject]@{Success=$true;ScenarioCount=2}
