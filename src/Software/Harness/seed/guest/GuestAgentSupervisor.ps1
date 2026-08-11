$ErrorActionPreference = 'Continue'

$agentRoot = 'C:\CodexGuest'
$agentScript = Join-Path $agentRoot 'GuestAgent.ps1'
$statePath = Join-Path $agentRoot 'supervisor-state.json'

function Write-SupervisorState {
    param(
        [Parameter(Mandatory = $true)] [string] $Status,
        [Nullable[int]] $AgentProcessId = $null,
        [Nullable[int]] $AgentExitCode = $null,
        [string] $ErrorMessage = $null
    )

    $temporaryPath = $statePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    $state = [ordered]@{
        Ready = $true
        Status = $Status
        SupervisorProcessId = $PID
        AgentProcessId = if ($null -ne $AgentProcessId) { [int]$AgentProcessId } else { $null }
        AgentExitCode = if ($null -ne $AgentExitCode) { [int]$AgentExitCode } else { $null }
        Error = $ErrorMessage
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        UserInteractive = [Environment]::UserInteractive
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8 -ErrorAction Stop
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($statePath)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $statePath, $backupPath, $true)
                }
                else { [IO.File]::Move($temporaryPath, $statePath) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\CodexGuestAgentSupervisor', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    while ($true) {
        $agentProcess = $null
        try {
            if (-not (Test-Path -LiteralPath $agentScript -PathType Leaf)) {
                Write-SupervisorState -Status 'WaitingForAgentScript' -ErrorMessage "Guest agent script not found: $agentScript"
                Start-Sleep -Seconds 2
                continue
            }

            $agentProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy', 'Bypass',
                '-File', $agentScript
            ) -WindowStyle Hidden -PassThru
            Write-SupervisorState -Status 'Running' -AgentProcessId $agentProcess.Id
            $agentProcess.WaitForExit()
            $exitCode = $agentProcess.ExitCode
            Write-SupervisorState -Status 'Restarting' -AgentProcessId $agentProcess.Id -AgentExitCode $exitCode
        }
        catch {
            Write-SupervisorState -Status 'Restarting' -AgentProcessId $(if ($agentProcess) { $agentProcess.Id } else { $null }) -ErrorMessage $_.Exception.Message
        }
        finally {
            if ($agentProcess) {
                $agentProcess.Dispose()
            }
        }
        Start-Sleep -Seconds 2
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
