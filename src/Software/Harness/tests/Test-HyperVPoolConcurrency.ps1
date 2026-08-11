[CmdletBinding()]
param(
    [string] $ArtifactPath,
    [ValidateRange(2, 4)] [int] $JobCount = 4,
    [ValidateRange(30000, 240000)] [int] $HoldMilliseconds = 150000,
    [string] $BrokerRoot,
    [string] $OutputRoot,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $sourceRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { $ArtifactPath = Join-Path ([string]$layout.SoftwareRoot) 'Canaries\PoolCanary.exe' }
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $BrokerRoot ('Results\Management\pool-concurrency-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')) }
$runner = @(
    (Join-Path $env:USERPROFILE '.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1'),
    (Join-Path $env:USERPROFILE '.codex\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $runner) { throw 'The Hyper-V executable runner is not installed under .agents\skills or .codex\skills.' }
$poolStatePath = Join-Path $BrokerRoot 'State\pool-state.json'
$actionsPath = Join-Path $OutputRoot 'actions.json'
$statusPath = Join-Path $OutputRoot 'status.json'
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
@(
    [ordered]@{ type = 'wait_window'; timeoutMs = 30000 },
    [ordered]@{ type = 'screenshot'; name = 'concurrent-start.png'; timeoutMs = 30000; attempts = 5 },
    [ordered]@{ type = 'wait'; ms = $HoldMilliseconds },
    [ordered]@{ type = 'screenshot'; name = 'concurrent-end.png'; timeoutMs = 30000; attempts = 5 }
) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $actionsPath -Encoding UTF8

$processes = New-Object Collections.Generic.List[object]
$timeline = New-Object Collections.Generic.List[object]
$lastSignature = $null
$maxRunning = 0
$maxActive = 0
$sawFourLeased = $false
$startedUtc = [DateTime]::UtcNow

for ($index = 1; $index -le $JobCount; $index++) {
    $stdout = Join-Path $OutputRoot ('job-{0:D2}.stdout.txt' -f $index)
    $stderr = Join-Path $OutputRoot ('job-{0:D2}.stderr.txt' -f $index)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $runner + '"'),
        '-ArtifactPath', ('"' + $ArtifactPath + '"'),
        '-ActionsPath', ('"' + $actionsPath + '"'),
        '-QueueTimeoutSeconds', '900',
        '-ExecutionTimeoutSeconds', '360'
    )
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $processes.Add([pscustomobject]@{ Index = $index; Process = $process; StdOut = $stdout; StdErr = $stderr })
    Start-Sleep -Milliseconds 150
}

$deadline = [DateTime]::UtcNow.AddMinutes(10)
while ([DateTime]::UtcNow -lt $deadline) {
    $allExited = $true
    foreach ($entry in $processes) {
        $entry.Process.Refresh()
        if (-not $entry.Process.HasExited) { $allExited = $false }
    }
    if (Test-Path -LiteralPath $poolStatePath -PathType Leaf) {
        try {
            $pool = Get-Content -Raw -LiteralPath $poolStatePath | ConvertFrom-Json
            $workerSignature = @($pool.Workers | Sort-Object WorkerId | ForEach-Object { '{0}:{1}:{2}' -f $_.WorkerId, $_.Status, $_.RequestId }) -join ','
            $signature = "$($pool.RunningCount)|$($pool.ActiveCount)|$workerSignature"
            $maxRunning = [Math]::Max($maxRunning, [int]$pool.RunningCount)
            $maxActive = [Math]::Max($maxActive, [int]$pool.ActiveCount)
            if (@($pool.Workers | Where-Object Status -in @('Leased', 'RunCompleted')).Count -eq 4) {
                $sawFourLeased = $true
            }
            if ($signature -ne $lastSignature) {
                $timeline.Add([pscustomobject][ordered]@{
                    TimestampUtc = [DateTime]::UtcNow.ToString('o')
                    RunningCount = [int]$pool.RunningCount
                    ActiveCount = [int]$pool.ActiveCount
                    ReadyCount = [int]$pool.ReadyCount
                    QueueDepth = [int]$pool.QueueDepth
                    Workers = @($pool.Workers | Sort-Object WorkerId | ForEach-Object {
                        [ordered]@{ WorkerId = [int]$_.WorkerId; Status = [string]$_.Status; RequestId = [string]$_.RequestId }
                    })
                })
                $lastSignature = $signature
            }
        }
        catch { }
    }
    if ($allExited) { break }
    Start-Sleep -Milliseconds 250
}

$jobResults = New-Object Collections.Generic.List[object]
foreach ($entry in $processes) {
    $entry.Process.Refresh()
    if (-not $entry.Process.HasExited) {
        Stop-Process -Id $entry.Process.Id -Force -ErrorAction SilentlyContinue
    }
    $stdoutText = if (Test-Path -LiteralPath $entry.StdOut) { Get-Content -Raw -LiteralPath $entry.StdOut } else { '' }
    $requestId = $null
    if ($stdoutText -match 'Submitted\s+(executable-test-[A-Za-z0-9_-]+)') { $requestId = $Matches[1] }
    $brokerResult = $null
    if ($requestId) {
        $brokerResultPath = Join-Path (Join-Path (Join-Path $BrokerRoot 'Results') $requestId) 'broker-result.json'
        if (Test-Path -LiteralPath $brokerResultPath -PathType Leaf) {
            $brokerResult = Get-Content -Raw -LiteralPath $brokerResultPath | ConvertFrom-Json
        }
    }
    $jobResults.Add([pscustomobject][ordered]@{
        Index = [int]$entry.Index
        ProcessExitCode = if ($entry.Process.HasExited) { [int]$entry.Process.ExitCode } else { $null }
        RequestId = $requestId
        Success = [bool]($brokerResult -and $brokerResult.Success)
        WorkerId = if ($brokerResult) { [int]$brokerResult.PoolWorkerId } else { $null }
        VmName = if ($brokerResult) { [string]$brokerResult.VmName } else { $null }
        ParentVhdx = if ($brokerResult) { [string]$brokerResult.PayloadParentVhdx } else { $null }
        ChildVhdx = if ($brokerResult) { [string]$brokerResult.PayloadChildVhdx } else { $null }
        ChildDeleted = [bool]($brokerResult -and $brokerResult.PayloadChildDeleted)
        CacheHit = [bool]($brokerResult -and $brokerResult.PayloadCacheHit)
        FilesHashed = if ($brokerResult) { [int]$brokerResult.PayloadFilesHashed } else { $null }
        HashesReused = if ($brokerResult) { [int]$brokerResult.PayloadHashesReused } else { $null }
        ResultPath = if ($requestId) { Join-Path (Join-Path $BrokerRoot 'Results') $requestId } else { $null }
        StdOut = $entry.StdOut
        StdErr = $entry.StdErr
    })
}

$workerIds = @($jobResults | Where-Object Success | ForEach-Object WorkerId | Sort-Object -Unique)
$parents = @($jobResults | Where-Object Success | ForEach-Object ParentVhdx | Sort-Object -Unique)
$success = @($jobResults | Where-Object { -not $_.Success -or -not $_.ChildDeleted -or $_.ProcessExitCode -ne 0 }).Count -eq 0 -and
    $workerIds.Count -eq $JobCount -and
    $parents.Count -eq 1 -and
    $maxRunning -eq $JobCount -and
    $maxActive -eq $JobCount -and
    $sawFourLeased
$status = [ordered]@{
    Success = $success
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    JobCount = $JobCount
    HoldMilliseconds = $HoldMilliseconds
    MaxRunningCount = $maxRunning
    MaxActiveCount = $maxActive
    SawFourLeased = $sawFourLeased
    DistinctWorkerIds = $workerIds
    DistinctParentVhdx = $parents
    Results = $jobResults.ToArray()
    Timeline = $timeline.ToArray()
}
$status | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statusPath -Encoding UTF8
$status | ConvertTo-Json -Depth 20
if (-not $success) { exit 1 }
