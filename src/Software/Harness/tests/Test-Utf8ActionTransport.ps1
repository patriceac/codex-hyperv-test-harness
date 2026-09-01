[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$runnerPath = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
$actionsFixturePath = Join-Path $softwareRoot 'Canaries\release-utf8-actions.json'
$guestAgentPath = Join-Path $harnessRoot 'seed\guest\GuestAgent.ps1'
$canaryPath = Join-Path $softwareRoot 'Canaries\HarnessContractCanary.cs'
$accentedControlName = 'Approuver le pilote et d' + [char]0x00E9 + 'bloquer la file'
$scenarios = New-Object Collections.Generic.List[string]

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)] [string] $Value)
    '"' + $Value.Replace('"', '\"') + '"'
}

$runtimeJsonPaths = @(
    $runnerPath,
    (Join-Path $softwareRoot 'Skill\scripts\HyperVBrokerLocation.ps1'),
    (Join-Path $softwareRoot 'Skill\scripts\Get-HyperVExecutableTestQueue.ps1'),
    (Join-Path $softwareRoot 'Skill\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1'),
    (Join-Path $harnessRoot 'HostBroker.ps1'),
    (Join-Path $harnessRoot 'PoolBroker.ps1'),
    (Join-Path $harnessRoot 'PoolCommon.ps1'),
    (Join-Path $harnessRoot 'HostWorker.ps1'),
    (Join-Path $harnessRoot 'PoolLifecycle.ps1'),
    (Join-Path $harnessRoot 'PayloadCache.ps1'),
    (Join-Path $harnessRoot 'HostInputShare.ps1'),
    (Join-Path $harnessRoot 'RequestNetwork.ps1'),
    (Join-Path $harnessRoot 'LiveEvidence.ps1'),
    $guestAgentPath,
    (Join-Path $harnessRoot 'seed\guest\GuestLiveEvidence.ps1'),
    (Join-Path $repositoryRoot 'setup\Invoke-HarnessReleaseAcceptance.ps1'),
    (Join-Path $repositoryRoot 'setup\Deploy-HarnessRelease.ps1')
)

foreach ($requiredPath in @($runtimeJsonPaths + @($actionsFixturePath, $canaryPath))) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "UTF-8 transport test input is missing: $requiredPath" }
}

$jsonReadCount = 0
$jsonWriteCount = 0
foreach ($path in $runtimeJsonPaths) {
    foreach ($match in @(Select-String -LiteralPath $path -Pattern 'Get-Content.*ConvertFrom-Json')) {
        $jsonReadCount++
        Assert-True ($match.Line -match '-Encoding\s+UTF8(?:\s|\||$)') "JSON read is not explicitly UTF-8 at $path`:$($match.LineNumber)."
    }
    foreach ($match in @(Select-String -LiteralPath $path -Pattern 'ConvertTo-Json.*Set-Content')) {
        $jsonWriteCount++
        Assert-True ($match.Line -match 'Set-Content.*-Encoding\s+UTF8(?:\s|$)') "JSON write is not explicitly UTF-8 at $path`:$($match.LineNumber)."
    }
}
Assert-True ($jsonReadCount -gt 20 -and $jsonWriteCount -gt 5) 'The UTF-8 transport audit did not inspect the expected runtime JSON boundaries.'
$scenarios.Add('runtime-json-file-boundaries-declare-utf8')

$fixtureDocument = Get-Content -LiteralPath $actionsFixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
$fixtureActions = @()
foreach ($fixtureAction in $fixtureDocument) { $fixtureActions += $fixtureAction }
$fixtureClicks = @($fixtureActions | Where-Object { [string]$_.type -eq 'click_control' })
Assert-True ($fixtureClicks.Count -eq 1 -and
    [string]$fixtureClicks[0].name -ceq $accentedControlName -and
    $fixtureClicks[0].PSObject.Properties.Name -notcontains 'automationId') 'The release fixture does not select the exact accented control exclusively by UI Automation Name.'
$scenarios.Add('release-fixture-uses-accented-name-without-automation-id')

$guestAgentSource = Get-Content -LiteralPath $guestAgentPath -Raw -Encoding UTF8
$canarySource = Get-Content -LiteralPath $canaryPath -Raw -Encoding UTF8
Assert-True ($guestAgentSource.Contains("Get-GuestOptionalPropertyValue -InputObject `$action -PropertyName 'automationId'") -and
    $guestAgentSource.Contains("Get-GuestOptionalPropertyValue -InputObject `$action -PropertyName 'name'") -and
    $guestAgentSource.Contains('RequestedAutomationId = $requestedAutomationId') -and
    $guestAgentSource.Contains('RequestedName = $requestedName') -and
    $guestAgentSource.Contains('MatchedName = $matchedName')) 'Guest click evidence does not record requested and matched UI Automation selectors.'
Assert-True ($canarySource.Contains('Approuver le pilote et d\u00E9bloquer la file') -and
    $canarySource.Contains('require-click') -and
    $canarySource.Contains('clickedControlName')) 'The contract canary does not require and attest the accented named-control click.'
$scenarios.Add('guest-and-canary-publish-name-click-evidence')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-utf8-action-' + [Guid]::NewGuid().ToString('N'))
$producer = $null
$desktopProducer = $null
try {
    foreach ($relative in @('Requests', 'Processing', 'Results', 'PayloadManifests', 'PayloadCache', 'Cancellations', 'Cancelled')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $testRoot $relative) | Out-Null
    }
    $artifactPath = Join-Path $testRoot 'never-run.exe'
    [IO.File]::WriteAllBytes($artifactPath, [byte[]](0, 1, 2, 3))
    $bomlessActionsPath = Join-Path $testRoot 'actions-utf8-no-bom.json'
    $fixtureText = Get-Content -LiteralPath $actionsFixturePath -Raw -Encoding UTF8
    [IO.File]::WriteAllText($bomlessActionsPath, $fixtureText, (New-Object Text.UTF8Encoding($false, $true)))
    $fixtureBytes = [IO.File]::ReadAllBytes($bomlessActionsPath)
    Assert-True ($fixtureBytes.Length -gt 3 -and -not ($fixtureBytes[0] -eq 0xEF -and $fixtureBytes[1] -eq 0xBB -and $fixtureBytes[2] -eq 0xBF)) 'The producer fixture unexpectedly contains a UTF-8 BOM.'

    $desktopPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $desktopPowerShellPath -PathType Leaf)) { throw "Windows PowerShell 5.1 is missing: $desktopPowerShellPath" }
    # Elevated release qualification may not inherit a user-local PowerShell 7 path. The
    # BOM-less transport proof stays mandatory; use the real runner whenever pwsh is visible.
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $producerMode = 'PowerShell7Runner'
        $producerInfo = New-Object Diagnostics.ProcessStartInfo
        $producerInfo.FileName = [string]$pwshCommand.Source
        $producerInfo.Arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Quote-ProcessArgument $runnerPath),
            '-ArtifactPath', (Quote-ProcessArgument $artifactPath),
            '-ActionsPath', (Quote-ProcessArgument $bomlessActionsPath),
            '-BrokerRoot', (Quote-ProcessArgument $testRoot),
            '-QueueTimeoutSeconds', '300',
            '-ExecutionTimeoutSeconds', '60'
        ) -join ' '
        $producerInfo.UseShellExecute = $false
        $producerInfo.CreateNoWindow = $true
        $producer = [Diagnostics.Process]::Start($producerInfo)

        $queuedFile = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline) {
            $queuedFile = Get-ChildItem -LiteralPath (Join-Path $testRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($queuedFile) { break }
            $producer.Refresh()
            if ($producer.HasExited) { throw "PowerShell 7 producer exited before queueing the request: $($producer.ExitCode)" }
            Start-Sleep -Milliseconds 100
        }
        if (-not $queuedFile) { throw 'PowerShell 7 producer did not queue the BOM-less UTF-8 action request.' }
    }
    else {
        $producerMode = 'RuntimeIndependentBomlessUtf8'
        $queuedPath = Join-Path (Join-Path $testRoot 'Requests') 'synthetic-request.json'
        $syntheticRequest = [ordered]@{
            Job = [ordered]@{
                actions = @($fixtureActions)
            }
        }
        $syntheticJson = $syntheticRequest | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($queuedPath, $syntheticJson, (New-Object Text.UTF8Encoding($false, $true)))
        $queuedFile = Get-Item -LiteralPath $queuedPath
    }

    $queuedBytes = [IO.File]::ReadAllBytes($queuedFile.FullName)
    Assert-True ($queuedBytes.Length -gt 3 -and -not ($queuedBytes[0] -eq 0xEF -and $queuedBytes[1] -eq 0xBB -and $queuedBytes[2] -eq 0xBF)) 'The queued request unexpectedly contains a UTF-8 BOM.'

    $pathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($queuedFile.FullName))
    $nameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($accentedControlName))
    $consumerScript = @"
`$ErrorActionPreference = 'Stop'
`$path = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pathBase64'))
`$expected = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$nameBase64'))
`$request = Get-Content -LiteralPath `$path -Raw -Encoding UTF8 | ConvertFrom-Json
`$clicks = @(`$request.Job.actions | Where-Object { [string]`$_.type -eq 'click_control' })
if (`$clicks.Count -ne 1 -or [string]`$clicks[0].name -cne `$expected -or `$clicks[0].PSObject.Properties.Name -contains 'automationId') {
    throw 'Windows PowerShell 5.1 did not decode the queued accented Name exactly.'
}
"@
    $encodedConsumer = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($consumerScript))
    & $desktopPowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedConsumer
    if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell 5.1 consumer rejected the queued UTF-8 action request with exit code $LASTEXITCODE." }
    $scenarios.Add('bomless-request-roundtrips-through-windows-powershell-51')

    $desktopRoot = Join-Path $testRoot 'windows-powershell-runner'
    foreach ($relative in @('Requests', 'Processing', 'Results', 'PayloadManifests', 'PayloadCache', 'Cancellations', 'Cancelled')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $desktopRoot $relative) | Out-Null
    }
    $desktopProducerInfo = New-Object Diagnostics.ProcessStartInfo
    $desktopProducerInfo.FileName = $desktopPowerShellPath
    $desktopProducerInfo.Arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $runnerPath),
        '-ArtifactPath', (Quote-ProcessArgument $artifactPath),
        '-ActionsPath', (Quote-ProcessArgument $bomlessActionsPath),
        '-BrokerRoot', (Quote-ProcessArgument $desktopRoot),
        '-QueueTimeoutSeconds', '300',
        '-ExecutionTimeoutSeconds', '60'
    ) -join ' '
    $desktopProducerInfo.UseShellExecute = $false
    $desktopProducerInfo.CreateNoWindow = $true
    $desktopProducer = [Diagnostics.Process]::Start($desktopProducerInfo)

    $desktopQueuedFile = $null
    $desktopDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $desktopDeadline) {
        $desktopQueuedFile = Get-ChildItem -LiteralPath (Join-Path $desktopRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($desktopQueuedFile) { break }
        $desktopProducer.Refresh()
        if ($desktopProducer.HasExited) { throw "Windows PowerShell 5.1 runner exited before accepting the name-only action: $($desktopProducer.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    if (-not $desktopQueuedFile) { throw 'Windows PowerShell 5.1 runner did not queue the name-only action request.' }
    $desktopRequest = Get-Content -LiteralPath $desktopQueuedFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $desktopClicks = @($desktopRequest.Job.actions | Where-Object { [string]$_.type -eq 'click_control' })
    Assert-True ($desktopClicks.Count -eq 1 -and
        [string]$desktopClicks[0].name -ceq $accentedControlName -and
        $desktopClicks[0].PSObject.Properties.Name -notcontains 'automationId') 'Windows PowerShell 5.1 did not accept the exact name-only click_control action.'
    $scenarios.Add('windows-powershell-51-runner-accepts-name-only-click-control')
}
finally {
    if ($producer) {
        try {
            $producer.Refresh()
            if (-not $producer.HasExited) { $producer.Kill() }
            [void]$producer.WaitForExit(5000)
        }
        catch { }
        $producer.Dispose()
    }
    if ($desktopProducer) {
        try {
            $desktopProducer.Refresh()
            if (-not $desktopProducer.HasExited) { $desktopProducer.Kill() }
            [void]$desktopProducer.WaitForExit(5000)
        }
        catch { }
        $desktopProducer.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
    Metrics = [ordered]@{
        RuntimeJsonReads = $jsonReadCount
        RuntimeJsonWrites = $jsonWriteCount
        AccentedControlName = $accentedControlName
        ProducerMode = $producerMode
    }
} | ConvertTo-Json -Depth 8
