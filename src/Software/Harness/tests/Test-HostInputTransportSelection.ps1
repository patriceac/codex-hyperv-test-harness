[CmdletBinding()]
param(
    [string] $RunnerPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($RunnerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }

function Import-RunnerFunction {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Runner function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
    $definition
}

function Assert-Selection {
    param(
        [string] $Expected,
        [string] $Mode = 'Auto',
        [bool] $Warm = $false,
        [long] $TotalBytes = 1,
        [long] $CandidateBytes = 1,
        [int] $CandidateCount = 1,
        [int] $FileCount = 1,
        [int] $ReparsePointCount = 0,
        [string] $Scenario
    )
    $inventory = [pscustomobject]@{
        TotalBytes = $TotalBytes
        CandidateBytes = $CandidateBytes
        CandidateCount = $CandidateCount
        ReparsePointCount = $ReparsePointCount
    }
    $actual = Select-HostInputTransport -RequestedMode $Mode -WarmCache $Warm -Inventory $inventory -FileCount $FileCount -ColdShareThresholdBytes 1GB -IncrementalShareThresholdBytes 256MB
    if ([string]$actual.Transport -ne $Expected) { throw "$Scenario selected $($actual.Transport), expected $Expected." }
}

$selectionFunction = Import-RunnerFunction -Name 'Select-HostInputTransport'
$inventoryFunction = Import-RunnerFunction -Name 'Get-PayloadSourceInventory'
$payloadIdFunction = Import-RunnerFunction -Name 'Get-PayloadId'
$scenarios = New-Object Collections.Generic.List[string]

$applicationId = Get-PayloadId -CanonicalArtifactPath 'D:\same-source' -IsDirectory $true
$hostInputId = Get-PayloadId -CanonicalArtifactPath 'D:\same-source' -IsDirectory $true -CacheScope ReadOnlyHostInput
if ($applicationId -eq $hostInputId) { throw 'Read-only host inputs collide with the canonical ArtifactPath cache namespace.' }
$scenarios.Add('read-only-cache-namespace-isolated')

Assert-Selection -Expected Share -Mode Share -Scenario 'explicit share'
$scenarios.Add('explicit-share')
Assert-Selection -Expected Vhdx -Mode Vhdx -Scenario 'explicit VHDX'
$scenarios.Add('explicit-vhdx')
Assert-Selection -Expected Share -TotalBytes 2GB -CandidateBytes 2GB -Scenario 'cold large input'
$scenarios.Add('cold-large-selects-share')
Assert-Selection -Expected Vhdx -TotalBytes 128MB -CandidateBytes 128MB -Scenario 'cold small input'
$scenarios.Add('cold-small-selects-vhdx')
Assert-Selection -Expected Vhdx -Warm $true -TotalBytes 100GB -CandidateBytes 0 -CandidateCount 0 -Scenario 'warm unchanged input'
$scenarios.Add('warm-unchanged-selects-vhdx')
Assert-Selection -Expected Vhdx -Warm $true -TotalBytes 100GB -CandidateBytes 8MB -CandidateCount 2 -Scenario 'warm incremental input'
$scenarios.Add('warm-small-change-selects-vhdx')
Assert-Selection -Expected Share -Warm $true -TotalBytes 100GB -CandidateBytes 2GB -CandidateCount 3 -Scenario 'warm substantially changed input'
$scenarios.Add('warm-large-change-selects-share')
Assert-Selection -Expected Share -TotalBytes 1 -CandidateBytes 1 -ReparsePointCount 1 -Scenario 'reparse input'
$scenarios.Add('reparse-selects-share')
Assert-Selection -Expected Share -TotalBytes 0 -CandidateBytes 0 -CandidateCount 0 -FileCount 0 -Scenario 'empty input'
$scenarios.Add('empty-selects-share')

if ($inventoryFunction.Body.Extent.Text -match '(?i)Get-FileHash|ComputeHash|FileStream.*Read') {
    throw 'Cheap host-input inventory unexpectedly reads or hashes file contents.'
}
$scenarios.Add('selection-inventory-is-metadata-only')

$runnerText = Get-Content -Raw -LiteralPath $RunnerPath
$inventoryPosition = $runnerText.IndexOf('Get-PayloadSourceInventory -Artifact $inputItem', [StringComparison]::Ordinal)
$selectionPosition = $runnerText.IndexOf('Select-HostInputTransport -RequestedMode', [StringComparison]::Ordinal)
$manifestPosition = $runnerText.IndexOf('Get-PayloadManifest -Artifact $inputItem', [StringComparison]::Ordinal)
if ($inventoryPosition -lt 0 -or $selectionPosition -le $inventoryPosition -or $manifestPosition -le $selectionPosition) {
    throw 'The runner does not select host-input transport before candidate hashing.'
}
$scenarios.Add('transport-selected-before-candidate-hashing')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
