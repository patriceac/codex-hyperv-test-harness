[CmdletBinding()]
param(
    [string] $QueueScript
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($QueueScript)) { $QueueScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Get-HyperVExecutableTestQueue.ps1' }

function Write-TestJson {
    param([string] $Path, $Value)
    if ($Path -like '*pool-state.json') { $Value['UpdatedUtc'] = [DateTime]::UtcNow.ToString('o') }
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-QueueState {
    param([string] $Root)
    $raw = & $QueueScript -BrokerRoot $Root
    ($raw -join [Environment]::NewLine) | ConvertFrom-Json
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$workRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\work'))
$root = Join-Path $workRoot ('codex-queue-maintenance-' + [Guid]::NewGuid().ToString('N'))
foreach ($relative in @('Requests', 'Processing', 'Results', 'State')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $relative) | Out-Null
}
$scenarios = New-Object Collections.Generic.List[string]
try {
    Write-TestJson -Path (Join-Path $root 'State\broker-state.json') -Value ([ordered]@{
        Status = 'PoolActive'
        ProcessId = $PID
        HeartbeatUtc = [DateTime]::UtcNow.ToString('o')
    })
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value ([ordered]@{
        MaxWorkers = 4
        WarmAhead = 1
        RunningCount = 1
        ReadyCount = 0
        Workers = @(
            [ordered]@{ WorkerId = 1; Status = 'Leased'; OsClean = $false; RequestId = 'request-leased' },
            [ordered]@{ WorkerId = 2; Status = 'Off'; OsClean = $true; RequestId = $null },
            [ordered]@{ WorkerId = 3; Status = 'Off'; OsClean = $true; RequestId = $null },
            [ordered]@{ WorkerId = 4; Status = 'Off'; OsClean = $true; RequestId = $null }
        )
    })

    $normal = Read-QueueState -Root $root
    Assert-True (-not $normal.MaintenanceActive -and $normal.WarmSparePolicyApplicable -and $normal.WarmSpareInvariantViolation -and $normal.InvariantViolation) 'A real warm-spare violation was not reported outside maintenance.'
    $scenarios.Add('warm-spare-violation-reported-normally')

    Write-TestJson -Path (Join-Path $root 'State\maintenance.json') -Value ([ordered]@{ Status = 'MaintenanceRequested'; CreatedUtc = [DateTime]::UtcNow.ToString('o') })
    $maintenance = Read-QueueState -Root $root
    Assert-True ($maintenance.MaintenanceActive -and -not $maintenance.WarmSparePolicyApplicable -and -not $maintenance.WarmSpareInvariantViolation -and -not $maintenance.InvariantViolation) 'Intentional maintenance did not suppress only the warm-spare warning.'
    Assert-True (-not $maintenance.PoolWarmSpareInvariantSatisfied) 'Maintenance reporting hid the raw unsatisfied spare metric.'
    $scenarios.Add('maintenance-suppresses-warm-spare-alarm')

    Write-TestJson -Path (Join-Path $root 'Processing\orphaned-request.json') -Value ([ordered]@{
        RequestId = 'orphaned-request'
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        QueueTimeoutSeconds = 1800
        ExecutionTimeoutSeconds = 900
    })
    $orphaned = Read-QueueState -Root $root
    Assert-True ($orphaned.MaintenanceActive -and $orphaned.OrphanedProcessing -and $orphaned.InvariantViolation) 'Maintenance incorrectly suppressed an orphaned-processing violation.'
    $scenarios.Add('maintenance-keeps-unrelated-alarms')

    $poolPath = Join-Path $root 'State\pool-state.json'
    $validPoolJson = Get-Content -LiteralPath $poolPath -Raw
    & {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($QueueScript, [ref]$tokens, [ref]$errors)
        $reader = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-JsonSafe' }, $true)
        . ([scriptblock]::Create($reader.Extent.Text))
        $script:readCalls = 0; $script:retryWaits = @(); $script:readFailureLimit = 2
        function Get-Content { param($LiteralPath, [switch]$Raw, $Encoding)
            $script:readCalls++
            if ($script:readCalls -le $script:readFailureLimit) { throw [IO.IOException]::new('Synthetic sharing violation') }
            $validPoolJson
        }
        function Start-Sleep { param($Milliseconds) $script:retryWaits += $Milliseconds }
        $read = Read-JsonSafe -Path $poolPath
        Assert-True ($read.MaxWorkers -eq 4 -and $script:readCalls -eq 3 -and ($script:retryWaits -join ',') -eq '50,100') 'A brief sharing violation was not retried.'
        $script:readCalls = 0; $script:retryWaits = @(); $script:readFailureLimit = 5
        $read = Read-JsonSafe -Path $poolPath
        Assert-True ($null -eq $read -and $script:readCalls -eq 5 -and ($script:retryWaits -join ',') -eq '50,100,150,200') 'A persistent sharing violation escaped its bounded retry limit.'
    }
    foreach ($badJson in @('{', 'null')) {
        Set-Content -LiteralPath $poolPath -Value $badJson -Encoding UTF8
        $unknown = Read-QueueState -Root $root
        Assert-True ($unknown.HealthReasons -contains 'PoolStateUnavailable' -and $null -eq $unknown.PoolMaxWorkers -and -not $unknown.OrphanedProcessing -and -not $unknown.InvariantViolation -and $null -eq $unknown.PoolWarmSpareInvariantSatisfied) 'An unavailable pool snapshot manufactured an invariant violation or known capacity.'
    }
    Set-Content -LiteralPath $poolPath -Value $validPoolJson -Encoding UTF8
    Assert-True ((Read-QueueState -Root $root).OrphanedProcessing) 'Snapshot recovery hid a real orphan.'
    $scenarios.Add('sharing-retry-and-unknown-snapshot-health')

    Remove-Item -LiteralPath (Join-Path $root 'Processing\orphaned-request.json'), (Join-Path $root 'State\maintenance.json')
    $workers = @(1..4 | ForEach-Object { [ordered]@{WorkerId=$_;Status='Off';OsClean=$true;FaultRecoveryAttempts=0} })
    $workers[0].Status = 'Recycling'; $workers[0].FaultRecoveryAttempts = 6
    $workers[1].Status = 'Faulted'; $workers[1].FaultRecoveryAttempts = 5
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    Write-TestJson -Path (Join-Path $root 'Requests\waiting.json') -Value @{CreatedUtc=[DateTime]::UtcNow.AddMinutes(-3).ToString('o')}
    $degraded = Read-QueueState -Root $root
    Assert-True ($degraded.BrokerHealthy -and -not $degraded.PlatformHealthy -and $degraded.QueuedDemandStalled -and $degraded.HealthReasons -contains 'RepeatedLifecycleFailure') 'A live heartbeat hid failed recycling and stalled demand.'
    $scenarios.Add('live-broker-does-not-hide-degraded-pool')

    $workers[0].Status = 'Starting'; $workers[0].FaultRecoveryAttempts = 0
    $workers[1].Status = 'Off'; $workers[1].FaultRecoveryAttempts = 0
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    Write-TestJson -Path (Join-Path $root 'Requests\waiting.json') -Value @{CreatedUtc=[DateTime]::UtcNow.ToString('o')}
    $starting = Read-QueueState -Root $root
    Assert-True ($starting.PlatformHealthy -and -not $starting.QueuedDemandStalled) 'Normal bounded cold startup raised a stall alarm.'
    Remove-Item -LiteralPath (Join-Path $root 'Requests\waiting.json')
    $workers[0].Status = 'Off'
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    Assert-True ((Read-QueueState -Root $root).PlatformHealthy) 'An idle off pool was incorrectly degraded.'
    $scenarios.Add('normal-startup-and-idle-pool-remain-healthy')

    $workers[0].Status = 'Recycling'
    $workers[0].ProcessStartUtc = [DateTime]::UtcNow.AddMinutes(-6).ToString('o')
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    $stuck = Read-QueueState -Root $root
    Assert-True (-not $stuck.PlatformHealthy -and $stuck.HealthReasons -contains 'LifecycleDeadlineExceeded') 'A stuck lifecycle escaped detection without queued demand.'
    $scenarios.Add('lifecycle-stall-is-detected-without-demand')

    $workers[0].Status = 'Faulted'; $workers[0].FaultRecoveryAttempts = 1
    $workers[0].LastFailureReason = 'GuestAuthenticationFailed: expired synthetic account'
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    Assert-True ((Read-QueueState -Root $root).HealthReasons -contains 'GuestAccountUnavailable') 'The first authentication failure was hidden until repeated retries.'
    $scenarios.Add('account-failure-is-detected-immediately')
    $workers[0].Status = 'Starting'; $workers[0].FaultRecoveryAttempts = 0
    $workers[0].ProcessStartUtc = [DateTime]::UtcNow.ToString('o')
    Write-TestJson -Path (Join-Path $root 'State\pool-state.json') -Value @{MaxWorkers=4;ReadyCount=0;Workers=$workers}
    Assert-True ((Read-QueueState -Root $root).PlatformHealthy) 'Historical authentication evidence raised a new alarm after successful recovery.'
    $scenarios.Add('recovered-account-history-does-not-trigger-new-alarms')
}
finally {
    if ([IO.Path]::GetFullPath($root).StartsWith($workRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -ErrorAction SilentlyContinue }
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
