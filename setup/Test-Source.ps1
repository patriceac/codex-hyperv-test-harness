[CmdletBinding()]
param([switch] $SkipIsoSmoke)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Join-Path $repositoryRoot 'src\Software'
$parseFailures = New-Object Collections.Generic.List[object]
foreach ($script in @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notlike (Join-Path $repositoryRoot 'artifacts\*') })) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) {
        $parseFailures.Add([pscustomobject]@{ Path = $script.FullName; Line = $error.Extent.StartLineNumber; Message = $error.Message })
    }
}
if ($parseFailures.Count -gt 0) { throw "PowerShell source contains $($parseFailures.Count) parse error(s): $($parseFailures | ConvertTo-Json -Compress)" }

$built = @(& (Join-Path $PSScriptRoot 'Build-Canaries.ps1') -CanaryRoot (Join-Path $softwareRoot 'Canaries'))
if ($built.Count -ne 4 -or @($built | Where-Object { -not (Test-Path -LiteralPath $_.Output -PathType Leaf) }).Count -gt 0) {
    throw 'The four C# canaries were not rebuilt successfully.'
}
$guestTool = & (Join-Path $softwareRoot 'Harness\Build-GuestTools.ps1')
if (-not (Test-Path -LiteralPath $guestTool.Output -PathType Leaf)) { throw 'The guest input probe was not rebuilt successfully.' }

$isoSmoke = $null
if (-not $SkipIsoSmoke) {
    $artifactRoot = Join-Path $repositoryRoot 'artifacts\source-test'
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
    $isoPath = Join-Path $artifactRoot 'imapi-smoke.iso'
    & (Join-Path $softwareRoot 'Harness\New-DataIso.ps1') -SourceDirectory (Join-Path $softwareRoot 'Canaries') -DestinationIso $isoPath -VolumeName 'CODEXSEED' | Out-Null
    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    try {
        $volume = $mounted | Get-Volume | Select-Object -First 1
        $expected = Join-Path ($volume.DriveLetter + ':\') 'PoolCanary.cs'
        if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw 'The native IMAPI ISO did not preserve its source tree.' }
        $isoSmoke = [pscustomobject]@{ Success = $true; Length = [long](Get-Item -LiteralPath $isoPath).Length; Sha256 = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash }
    }
    finally { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null }
}

$excluded = @('Test-HostInputHostIntegration.ps1','Test-HyperVPoolConcurrency.ps1')
$testResults = New-Object Collections.Generic.List[object]
$deterministicTests = @(
    Get-ChildItem -LiteralPath (Join-Path $softwareRoot 'Harness\tests') -File -Filter '*.ps1' | Where-Object Name -notin $excluded
    Get-Item -LiteralPath (Join-Path $softwareRoot 'Recovery\Test-RecoveryInstallContract.ps1') -ErrorAction Stop
) | Sort-Object FullName
foreach ($test in $deterministicTests) {
    $output = @(& $test.FullName)
    $summary = $null
    if ($output.Count -gt 0) {
        $last = $output | Select-Object -Last 1
        if ($last -is [string]) { try { $summary = $last | ConvertFrom-Json } catch { } }
        elseif ($last.PSObject.Properties['Success']) { $summary = $last }
    }
    if ($summary -and $summary.PSObject.Properties['Success'] -and -not [bool]$summary.Success) { throw "Deterministic test failed: $($test.Name)" }
    $testResults.Add([pscustomobject][ordered]@{
        Name = $test.Name
        Success = $true
        ScenarioCount = if ($summary -and $summary.PSObject.Properties['ScenarioCount']) { [int]$summary.ScenarioCount } else { 1 }
        Metrics = if ($summary -and $summary.PSObject.Properties['Metrics']) { $summary.Metrics } else { $null }
    })
}

$result = [pscustomobject][ordered]@{
    Success = $true
    ParsedPowerShellFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter '*.ps1').Count
    BuiltCanaries = $built
    BuiltGuestTool = $guestTool
    NativeIsoSmoke = $isoSmoke
    DeterministicTestFiles = $testResults.Count
    DeterministicScenarios = [int](($testResults | Measure-Object -Property ScenarioCount -Sum).Sum)
    Tests = $testResults.ToArray()
}
$result | ConvertTo-Json -Depth 20
