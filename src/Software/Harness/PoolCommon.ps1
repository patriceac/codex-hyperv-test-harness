function Write-PoolJsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else {
                    [IO.File]::Move($temporaryPath, $Path)
                }
                return
            }
            catch [IO.IOException] {
                if ($attempt -ge 20) { throw }
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge 20) { throw }
            }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PoolWorkerStateRoot {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    Join-Path $BrokerRoot 'State\PoolWorkers'
}

function Get-PoolWorkerStatePath {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId
    )

    Join-Path (Get-PoolWorkerStateRoot -BrokerRoot $BrokerRoot) ('worker-{0:D2}.json' -f $WorkerId)
}

function Get-PoolWorkerMutexName {
    param([Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId)

    'Global\CodexHyperVPoolWorker-{0:D2}' -f $WorkerId
}

function Read-PoolWorkerState {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId
    )

    $path = Get-PoolWorkerStatePath -BrokerRoot $BrokerRoot -WorkerId $WorkerId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    }
    catch {
        $null
    }
}

function Update-PoolWorkerState {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $Patch,
        [string] $ExpectedOperationId,
        [string] $ExpectedRequestId,
        [switch] $RequireExpectation
    )

    $mutex = New-Object Threading.Mutex($false, (Get-PoolWorkerMutexName -WorkerId $WorkerId))
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        }
        catch [Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) {
            throw "Timed out acquiring the state lock for Hyper-V worker $WorkerId."
        }

        $path = Get-PoolWorkerStatePath -BrokerRoot $BrokerRoot -WorkerId $WorkerId
        $current = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { $current = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { $current = $null }
        }
        if ($RequireExpectation) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedOperationId) -and
                -not [string]::Equals([string]$current.OperationId, $ExpectedOperationId, [StringComparison]::Ordinal)) {
                return $null
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRequestId) -and
                -not [string]::Equals([string]$current.RequestId, $ExpectedRequestId, [StringComparison]::Ordinal)) {
                return $null
            }
        }

        $merged = [ordered]@{}
        if ($current) {
            foreach ($property in $current.PSObject.Properties) {
                $merged[$property.Name] = $property.Value
            }
        }
        $merged.WorkerId = $WorkerId
        foreach ($key in $Patch.Keys) {
            $merged[[string]$key] = $Patch[$key]
        }
        $merged.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Write-PoolJsonAtomic -Path $path -Value $merged
        [pscustomobject]$merged
    }
    finally {
        if ($lockTaken) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

function Get-PoolWorkerDefinition {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 64)] [int] $WorkerId
    )

    $worker = @($Config.PoolWorkers | Where-Object { [int]$_.WorkerId -eq $WorkerId }) | Select-Object -First 1
    if (-not $worker) {
        throw "Pool worker $WorkerId is not present in broker configuration."
    }
    $worker
}

function Initialize-PoolWorkerStates {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config
    )

    $stateRoot = Get-PoolWorkerStateRoot -BrokerRoot $BrokerRoot
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    foreach ($worker in @($Config.PoolWorkers | Sort-Object { [int]$_.WorkerId })) {
        $workerId = [int]$worker.WorkerId
        $current = Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId
        if (-not $current) {
            Update-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId $workerId -Patch ([ordered]@{
                VmName = [string]$worker.VmName
                Status = 'Off'
                OsClean = $true
                OsGeneration = 1
                RequestId = $null
                OperationId = $null
                ProcessId = $null
                ProcessStartUtc = $null
                IdleDeadlineUtc = $null
                LastReleasedUtc = $null
                LastReadyUtc = $null
                LastError = $null
                FaultRecoveryAttempts = 0
                FaultRecoveryNotBeforeUtc = $null
            }) | Out-Null
        }
        elseif (-not [string]::Equals([string]$current.VmName, [string]$worker.VmName, [StringComparison]::Ordinal)) {
            throw "Pool worker $workerId state belongs to '$($current.VmName)', not '$($worker.VmName)'."
        }
    }
}

function Get-PoolWorkerStates {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config
    )

    @($Config.PoolWorkers | Sort-Object { [int]$_.WorkerId } | ForEach-Object {
        Read-PoolWorkerState -BrokerRoot $BrokerRoot -WorkerId ([int]$_.WorkerId)
    } | Where-Object { $null -ne $_ })
}

function Test-PoolProcessAlive {
    param(
        $ProcessId,
        $ProcessStartUtc
    )

    if ($null -eq $ProcessId -or [int]$ProcessId -le 0) {
        return $false
    }
    $process = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    if (-not $process) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ProcessStartUtc)) {
        try {
            $expected = [DateTime]::Parse([string]$ProcessStartUtc).ToUniversalTime()
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -gt 2) {
                return $false
            }
        }
        catch {
            return $false
        }
    }
    $true
}

function ConvertTo-PoolArgumentLiteral {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value)

    '"' + $Value.Replace('"', '\"') + '"'
}

function Get-PoolPowerShellExecutable {
    Join-Path $PSHOME 'powershell.exe'
}

function Get-PoolIdleDeadline {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [DateTime] $FromUtc = ([DateTime]::UtcNow)
    )

    $seconds = if ($Config.PoolIdleTimeoutSeconds) { [int]$Config.PoolIdleTimeoutSeconds } else { 600 }
    $seconds = [Math]::Max(30, [Math]::Min(3600, $seconds))
    $FromUtc.ToUniversalTime().AddSeconds($seconds)
}

function Get-PoolFaultRecoveryDelaySeconds {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $Attempt,
        [ValidateRange(1, 64)] [int] $WorkerId = 1
    )

    $baseSeconds = if ($Config.PoolFaultRecoveryBaseSeconds) { [int]$Config.PoolFaultRecoveryBaseSeconds } else { 5 }
    $maximumSeconds = if ($Config.PoolFaultRecoveryMaxSeconds) { [int]$Config.PoolFaultRecoveryMaxSeconds } else { 600 }
    $baseSeconds = [Math]::Max(1, [Math]::Min(300, $baseSeconds))
    $maximumSeconds = [Math]::Max($baseSeconds, [Math]::Min(3600, $maximumSeconds))
    $exponent = [Math]::Min(20, $Attempt - 1)
    $exponentialDelay = [long]$baseSeconds * [long][Math]::Pow(2, $exponent)
    $workerStagger = [Math]::Min(15, ([Math]::Max(1, $WorkerId) - 1) * 2)
    [int][Math]::Min($maximumSeconds, $exponentialDelay + $workerStagger)
}

function New-PoolFaultStatePatch {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $ErrorMessage,
        [DateTime] $FailureUtc = ([DateTime]::UtcNow)
    )

    $attempt = if ($State -and $State.FaultRecoveryAttempts) { [int]$State.FaultRecoveryAttempts + 1 } else { 1 }
    $workerId = if ($State -and $State.WorkerId) { [int]$State.WorkerId } else { 1 }
    $delaySeconds = Get-PoolFaultRecoveryDelaySeconds -Config $Config -Attempt $attempt -WorkerId $workerId
    [ordered]@{
        Status = 'Faulted'
        PendingLifecycleMode = $null
        OperationId = $null
        ProcessId = $null
        ProcessStartUtc = $null
        LifecycleMode = $null
        RequestId = $null
        IdleDeadlineUtc = $null
        OsClean = $false
        LastError = $ErrorMessage
        LastFailureUtc = $FailureUtc.ToUniversalTime().ToString('o')
        FaultRecoveryAttempts = $attempt
        FaultRecoveryNotBeforeUtc = $FailureUtc.ToUniversalTime().AddSeconds($delaySeconds).ToString('o')
    }
}

function Test-PoolWorkerFaultRecoveryEligible {
    param(
        [Parameter(Mandatory = $true)] $State,
        [DateTime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ([string]$State.Status -ne 'Faulted') {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$State.FaultRecoveryNotBeforeUtc)) {
        return $true
    }
    try {
        $notBeforeUtc = [DateTime]::Parse([string]$State.FaultRecoveryNotBeforeUtc).ToUniversalTime()
        return $NowUtc.ToUniversalTime() -ge $notBeforeUtc
    }
    catch {
        return $true
    }
}
