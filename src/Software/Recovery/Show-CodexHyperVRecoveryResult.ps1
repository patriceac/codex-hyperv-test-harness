[CmdletBinding()]
param(
    [string] $BundleRoot,
    [string] $StatusPath,
    [string] $StatePath,
    [string] $LogPath,
    [string] $ExpectedBundleId,
    [Parameter(Mandatory = $true)] [string] $ExpectedAttemptId,
    [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 14400,
    [ValidateRange(50, 60000)] [int] $PollIntervalMilliseconds = 1000,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Codex Hyper-V Recovery' } catch { }

if (-not [string]::IsNullOrWhiteSpace($BundleRoot)) {
    $BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
    $manifestPath = Join-Path $BundleRoot 'manifest.json'
    $configPath = Join-Path $BundleRoot 'Software\harness-config.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Recovery manifest is missing: $manifestPath" }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Recovery configuration is missing: $configPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $recoveryStateRoot = Join-Path ([string]$config.LiveRoot) 'RecoveryInstall'
    $ExpectedBundleId = [string]$manifest.BundleId
    $StatusPath = Join-Path $recoveryStateRoot 'install-status.json'
    $StatePath = Join-Path $recoveryStateRoot 'state.json'
    $LogPath = Join-Path $recoveryStateRoot 'install.log'
}

foreach ($requiredValue in @{
    StatusPath = $StatusPath
    StatePath = $StatePath
    LogPath = $LogPath
    ExpectedBundleId = $ExpectedBundleId
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
        throw "$($requiredValue.Key) is required when BundleRoot is not supplied."
    }
}
try { [void][Guid]::ParseExact($ExpectedAttemptId, 'N') } catch { throw "Invalid recovery-attempt ID: $ExpectedAttemptId" }

function Read-RecoveryJson {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $null }
}

function Test-ExpectedRecoveryObject {
    param($Value)
    $Value -and
        [string]$Value.BundleId -eq $ExpectedBundleId -and
        [string]$Value.AttemptId -eq $ExpectedAttemptId
}

function Write-ResultFooter {
    Write-Host "Status: $StatusPath"
    Write-Host "Log:    $LogPath"
}

Write-Host ''
Write-Host 'CODEX HYPER-V RECOVERY' -ForegroundColor Cyan
Write-Host 'Waiting for the unattended SYSTEM restoration to finish...'
Write-Host ''

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$lastPhase = $null
$terminalStateSeenUtc = $null
$exitCode = 1
$finished = $false

while (-not $finished -and [DateTime]::UtcNow -lt $deadline) {
    $status = Read-RecoveryJson -Path $StatusPath
    if (Test-ExpectedRecoveryObject -Value $status) {
        if ([bool]$status.Success) {
            Write-Host 'READY - Codex Hyper-V harness installation completed successfully.' -ForegroundColor Green
            $exitCode = 0
        }
        else {
            Write-Host 'FAILED - Codex Hyper-V harness installation did not complete.' -ForegroundColor Red
            $exitCode = 1
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$status.Message)) { Write-Host ([string]$status.Message) }
        Write-ResultFooter
        $finished = $true
        break
    }

    $state = Read-RecoveryJson -Path $StatePath
    if (Test-ExpectedRecoveryObject -Value $state) {
        $phase = [string]$state.Phase
        if ($phase -ne $lastPhase) {
            $lastPhase = $phase
            $phaseMessage = [string]$state.Message
            Write-Host ("[{0}] {1} - {2}" -f [DateTime]::Now.ToString('HH:mm:ss'), $phase, $phaseMessage)
        }
        if ($phase -in @('Ready', 'Failed')) {
            if (-not $terminalStateSeenUtc) { $terminalStateSeenUtc = [DateTime]::UtcNow }
            elseif (([DateTime]::UtcNow - $terminalStateSeenUtc).TotalSeconds -ge 3) {
                if ($phase -eq 'Ready') {
                    Write-Host 'READY - Codex Hyper-V harness installation completed successfully.' -ForegroundColor Green
                    $exitCode = 0
                }
                else {
                    Write-Host 'FAILED - Codex Hyper-V harness installation did not complete.' -ForegroundColor Red
                    $exitCode = 1
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$state.Message)) { Write-Host ([string]$state.Message) }
                Write-ResultFooter
                $finished = $true
                break
            }
        }
        else { $terminalStateSeenUtc = $null }
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}

if (-not $finished) {
    Write-Host 'FAILED - Timed out waiting for the recovery result.' -ForegroundColor Red
    Write-ResultFooter
    $exitCode = 1
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Press any key to close this window.'
    try { [void][Console]::ReadKey($true) }
    catch { [void](Read-Host) }
}

exit $exitCode
