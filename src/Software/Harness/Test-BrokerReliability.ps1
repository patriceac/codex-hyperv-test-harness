param(
    [ValidateRange(1, 20)] [int] $Count = 5,
    [switch] $RequireHostLocked,
    [string] $BrokerRoot,
    [string] $PayloadPath,
    [string] $ReportPath,
    [ValidateRange(60, 900)] [int] $TimeoutSeconds = 480,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($PayloadPath)) { $PayloadPath = Join-Path ([string]$layout.HarnessSourceRoot) 'seed\guest\InputProbe.exe' }

if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) {
    throw "Probe executable not found: $PayloadPath"
}

$requestsRoot = Join-Path $BrokerRoot 'Requests'
$resultsRoot = Join-Path $BrokerRoot 'Results'
$manifestRoot = Join-Path $BrokerRoot 'PayloadManifests'
foreach ($requiredRoot in @($requestsRoot, $resultsRoot, $manifestRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "Broker directory not found: $requiredRoot"
    }
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $suffix = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $ReportPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name "broker-reliability-$suffix.json"
}

$runner = @(
    (Join-Path $env:USERPROFILE '.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1'),
    (Join-Path $env:USERPROFILE '.codex\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $runner) { throw 'The Hyper-V executable runner is not installed under .agents\skills or .codex\skills.' }
$runs = New-Object System.Collections.Generic.List[object]
$startedUtc = [DateTime]::UtcNow

for ($index = 1; $index -le $Count; $index++) {
    $requestId = $null
    $typedText = 'VM-GATE-' + $index + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    $resultPath = $null
    $brokerResultPath = $null
    $probeResultPath = $null
    $runStartedUtc = [DateTime]::UtcNow
    $success = $false
    $errorMessage = $null
    $brokerResult = $null
    $probeResult = $null

    Write-Host "[$index/$Count] Submitting the canonical probe ArtifactPath"
    try {
        $actionsJson = @(
            [ordered]@{ type = 'wait_window'; timeoutMs = 20000 },
            [ordered]@{ type = 'click_relative'; x = 328; y = 180 },
            [ordered]@{ type = 'type_text'; text = $typedText },
            [ordered]@{ type = 'screenshot'; name = 'before-click.png' },
            [ordered]@{ type = 'click_relative'; x = 328; y = 244 },
            [ordered]@{ type = 'wait'; ms = 1000 },
            [ordered]@{ type = 'screenshot'; name = 'after-click.png' }
        ) | ConvertTo-Json -Depth 8 -Compress
        $runnerOutput = & $runner -ArtifactPath $PayloadPath -Arguments '--result "{OUTDIR}\probe-result.json"' -ActionsJson $actionsJson -AssertResultFile '{OUTDIR}\probe-result.json' -RequireHostLocked:$RequireHostLocked -ExecutionTimeoutSeconds $TimeoutSeconds -BrokerRoot $BrokerRoot
        $runnerSummary = $runnerOutput | Select-Object -Last 1 | ConvertFrom-Json
        if (-not $runnerSummary.Success) {
            throw "Runner failed: $($runnerSummary.Error)"
        }
        $requestId = [string]$runnerSummary.RequestId
        $resultPath = [string]$runnerSummary.ResultPath
        $brokerResultPath = [string]$runnerSummary.BrokerResultPath
        $probeResultPath = Join-Path $resultPath 'probe-result.json'

        $brokerResult = Get-Content -Raw -LiteralPath $brokerResultPath | ConvertFrom-Json
        if (-not $brokerResult.Success) {
            throw "Broker failed: $($brokerResult.Error)"
        }
        if ([string]$brokerResult.VmFinalState -ne 'Off') {
            throw "VM final state was '$($brokerResult.VmFinalState)', expected 'Off'."
        }
        if (-not (Test-Path -LiteralPath $probeResultPath -PathType Leaf)) {
            throw 'Probe result is missing.'
        }

        $probeResult = Get-Content -Raw -LiteralPath $probeResultPath | ConvertFrom-Json
        if (-not $probeResult.keyboardReceived -or -not $probeResult.mouseClicked) {
            throw 'The probe did not confirm both keyboard and mouse input.'
        }
        if ([string]$probeResult.keyboardText -ne $typedText) {
            throw 'The probe keyboard text did not match the submitted value.'
        }
        foreach ($screenshotName in @('before-click.png', 'after-click.png')) {
            $screenshotPath = Join-Path $resultPath $screenshotName
            if (-not (Test-Path -LiteralPath $screenshotPath -PathType Leaf)) {
                throw "Screenshot is missing: $screenshotName"
            }
        }

        $success = $true
        Write-Host "[$index/$Count] PASS $requestId"
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "[$index/$Count] FAIL $requestId - $errorMessage"
    }

    $runs.Add([ordered]@{
        Index = $index
        RequestId = $requestId
        Success = $success
        Error = $errorMessage
        StartedUtc = $runStartedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        ResultPath = $resultPath
        VmFinalState = if ($brokerResult) { [string]$brokerResult.VmFinalState } else { $null }
        KeyboardReceived = if ($probeResult) { [bool]$probeResult.keyboardReceived } else { $false }
        MouseClicked = if ($probeResult) { [bool]$probeResult.mouseClicked } else { $false }
        KeyboardTextMatched = if ($probeResult) { [string]$probeResult.keyboardText -eq $typedText } else { $false }
    })
}

$passed = @($runs | Where-Object { $_.Success }).Count
$report = [ordered]@{
    Success = $passed -eq $Count
    RequireHostLocked = [bool]$RequireHostLocked
    RequestedRuns = $Count
    PassedRuns = $passed
    FailedRuns = $Count - $passed
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Runs = $runs.ToArray()
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10

if (-not $report.Success) {
    exit 1
}
