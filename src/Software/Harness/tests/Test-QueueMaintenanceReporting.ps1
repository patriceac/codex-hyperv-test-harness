[CmdletBinding()]
param(
    [string] $QueueScript = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Get-HyperVExecutableTestQueue.ps1')
)

$ErrorActionPreference = 'Stop'

function Write-TestJson {
    param([string] $Path, $Value)
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-queue-maintenance-' + [Guid]::NewGuid().ToString('N'))
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
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
