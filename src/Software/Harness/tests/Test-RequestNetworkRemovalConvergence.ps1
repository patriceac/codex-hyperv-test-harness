$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'RequestNetwork.ps1')
$script:rdReads = 0
$script:rdStaleReads = 2
function Get-VM { param($ErrorAction) [pscustomobject]@{ Name = 'test-only' } }
function Get-VMNetworkAdapter {
    param([Parameter(ValueFromPipeline = $true)] $VM)
    process {
        $script:rdReads++
        # A peer may use the same adapter name and must not block cleanup.
        [pscustomobject]@{ VMName = 'peer'; Name = 'CodexRequestNet-same'; SwitchName = 'isolated' }
        if ($script:rdReads -le $script:rdStaleReads) {
            [pscustomobject]@{ VMName = 'departing'; Name = 'CodexRequestNet-same'; SwitchName = 'isolated' }
        }
    }
}
if (-not (Wait-RequestNetworkAdapterAbsent -VmName 'departing' -AdapterName 'CodexRequestNet-same')) { throw 'Removal did not converge.' }
if ($script:rdReads -ne 3) { throw 'Removal did not wait for the stale global inventory or incorrectly waited on the peer.' }
$script:rdReads = 0
$script:rdStaleReads = [int]::MaxValue
$rdRejected = $false
try { Wait-RequestNetworkAdapterAbsent -VmName 'departing' -AdapterName 'CodexRequestNet-same' -TimeoutSeconds 1 | Out-Null }
catch { $rdRejected = $_.Exception.Message -like '*remained visible*' }
if (-not $rdRejected) { throw 'A persistently visible adapter was accepted.' }
[pscustomobject]@{ Success = $true; ScenarioCount = 2; RealHyperVCommands = $false } | ConvertTo-Json
