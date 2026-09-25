[CmdletBinding()]
param([string] $SourceRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$contractPath = Join-Path $SourceRoot '..\Skill\scripts\RequestGroupContract.ps1'
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) { throw "Request-group contract is missing: $contractPath" }
. $contractPath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock] $Operation, [string] $Scenario)
    $rejected = $false
    try { & $Operation }
    catch { $rejected = $true }
    if (-not $rejected) { throw "$Scenario was accepted unexpectedly." }
}

$scenarios = New-Object Collections.Generic.List[string]
$legacy = [pscustomobject]@{ Operation = 'RunGuestJob'; Job = [pscustomobject]@{} }
Assert-True ($null -eq (Get-RequestGroupDefinition -Request $legacy -MaxWorkers 4)) 'A legacy single request was reclassified as a group.'
$scenarios.Add('legacy-single-request-remains-ungrouped')

$groupId = '0123456789abcdef0123456789abcdef'
$valid = [pscustomobject]@{
    Operation = 'RunGuestJobGroupV1'
    Group = [pscustomobject]@{ Id = $groupId; Size = 2; Operation = 'RunGuestJob' }
}
$definition = Get-RequestGroupDefinition -Request $valid -MaxWorkers 4
Assert-True ([string]$definition.Id -ceq $groupId -and [int]$definition.Size -eq 2 -and [string]$definition.Operation -ceq 'RunGuestJob') 'A valid group definition was not preserved exactly.'
$scenarios.Add('valid-group-wrapper-preserves-definition')

$supportedOperations = @('RunGuestJob','RunGuestJobNetworkV1','RunGuestJobSetupV1','RunGuestJobSystemPromptsV1','RunGuestJobSetupSystemPromptsV1','RunGuestJobPowerTestV1','RunGuestInstallerV2')
foreach ($operation in $supportedOperations) {
    $supportedRequest = [pscustomobject]@{ Operation = 'RunGuestJobGroupV1'; Group = [pscustomobject]@{ Id = $groupId; Size = 2; Operation = $operation } }
    $supportedDefinition = Get-RequestGroupDefinition -Request $supportedRequest -MaxWorkers 4
    Assert-True ([string]$supportedDefinition.Operation -ceq $operation) "Group metadata rejected or rewrote legacy operation '$operation'."
}
$scenarios.Add('groups-preserve-every-supported-single-worker-operation')

Assert-Rejected -Scenario 'group member count above pool maximum' -Operation {
    $tooLarge = [pscustomobject]@{ Operation = 'RunGuestJobGroupV1'; Group = [pscustomobject]@{ Id = $groupId; Size = 5; Operation = 'RunGuestJob' } }
    Get-RequestGroupDefinition -Request $tooLarge -MaxWorkers 4
}
$scenarios.Add('group-larger-than-pool-is-rejected')

Assert-Rejected -Scenario 'malformed group id' -Operation {
    $badId = [pscustomobject]@{ Operation = 'RunGuestJobGroupV1'; Group = [pscustomobject]@{ Id = 'not-a-guid'; Size = 2; Operation = 'RunGuestJob' } }
    Get-RequestGroupDefinition -Request $badId -MaxWorkers 4
}
$scenarios.Add('group-id-must-be-lowercase-guid-n')

Assert-Rejected -Scenario 'group wrapper without metadata' -Operation {
    Get-RequestGroupDefinition -Request ([pscustomobject]@{ Operation = 'RunGuestJobGroupV1' }) -MaxWorkers 4
}
$scenarios.Add('group-wrapper-requires-metadata')

Assert-Rejected -Scenario 'group metadata without wrapper operation' -Operation {
    Get-RequestGroupDefinition -Request ([pscustomobject]@{ Operation = 'RunGuestJob'; Group = $valid.Group }) -MaxWorkers 4
}
$scenarios.Add('group-metadata-requires-wrapper-operation')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 6
