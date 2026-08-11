[CmdletBinding()]
param(
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $BrokerRoot,
    [string] $StatusPath,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) {
    $pointerPath = Join-Path $env:ProgramData 'CodexHyperVBroker\location.json'
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) { throw 'Pass -BrokerRoot or install the broker location pointer first.' }
    $BrokerRoot = [string](Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json).BrokerRoot
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($NoElevation) { throw 'Host-input integration verification requires administrator rights.' }
    if ([string]::IsNullOrWhiteSpace($StatusPath)) {
        $StatusPath = Join-Path $BrokerRoot 'State\Management\host-input-integration-status.json'
    }
    $arguments = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"'),
        '-SourceRoot',('"' + $SourceRoot + '"'),'-BrokerRoot',('"' + $BrokerRoot + '"'),
        '-StatusPath',('"' + $StatusPath + '"'),'-NoElevation'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    $StatusPath = Join-Path $BrokerRoot 'State\Management\host-input-integration-status.json'
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StatusPath) | Out-Null
$requestId = 'hostinput-integration-' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $BrokerRoot (Join-Path 'State\HostInputIntegrationData' $requestId)
$runtime = $null
$success = $false
$details = $null
$message = $null
try {
    . (Join-Path $SourceRoot 'HostBroker.ps1') -BrokerRoot $BrokerRoot -LibraryOnly
    $config = Get-Content -Raw -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') | ConvertFrom-Json
    $worker = @($config.PoolWorkers | Sort-Object WorkerId) | Select-Object -First 1
    if (-not $worker) { throw 'No configured pool worker is available.' }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $testRoot 'readable.txt'), 'read-only host input integration probe')
    $runtime = New-HostInputShareRuntime -BrokerRoot $BrokerRoot -Config $config -RequestId $requestId -VmName ([string]$worker.VmName) -WorkerId ([int]$worker.WorkerId) -Inputs @(
        [pscustomobject]@{ Name = 'probe'; HostPath = $testRoot }
    )
    $entry = @($runtime.Inputs) | Select-Object -First 1
    $share = Get-SmbShare -Name ([string]$entry.ShareName) -ErrorAction Stop
    $access = @(Get-SmbShareAccess -Name ([string]$entry.ShareName) -ErrorAction Stop)
    $account = Get-LocalUser -Name ([string]$runtime.AccountName) -ErrorAction Stop
    $stateText = Get-Content -Raw -LiteralPath ([string]$runtime.StatePath)
    if ([string]$share.Path -ne [string]$testRoot) { throw 'The share does not expose the exact requested path.' }
    if (@($access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.AccessRight -eq 'Read' }).Count -ne 1 -or
        @($access | Where-Object { $_.AccessRight -in @('Change','Full') -and $_.AccessControlType -eq 'Allow' }).Count -ne 0) {
        throw 'The ephemeral SMB share is not read-only.'
    }
    if (-not $account -or $stateText.Contains([string]$runtime.Password)) { throw 'The ephemeral account is missing or its secret was persisted.' }
    $cleanup = Remove-HostInputShareRuntime -Runtime $runtime -BrokerRoot $BrokerRoot
    $runtime = $null
    if (-not $cleanup.Success -or
        (Get-SmbShare -Name ([string]$entry.ShareName) -ErrorAction SilentlyContinue) -or
        (Get-LocalUser -Name ([string]$account.Name) -ErrorAction SilentlyContinue)) {
        throw 'Ephemeral share/account cleanup was incomplete.'
    }
    $network = Get-HostInputNetworkDefinition -Config $config -WorkerId ([int]$worker.WorkerId)
    $switch = Get-VMSwitch -Name ([string]$network.SwitchName) -ErrorAction Stop
    if ([string]$switch.SwitchType -ne 'Internal') { throw 'The host-input switch is not internal.' }
    $success = $true
    $message = 'Host-side read-only share, identity, ACL, network, and cleanup integration passed.'
    $details = [ordered]@{
        RequestId = $requestId
        ShareReadOnly = $true
        CredentialPersisted = $false
        CleanupSucceeded = $true
        SwitchName = [string]$switch.Name
        SwitchType = [string]$switch.SwitchType
        HostAddress = [string]$network.HostAddress
        GuestAddress = [string]$network.GuestAddress
    }
}
catch {
    $message = $_.Exception.Message
    throw
}
finally {
    if ($runtime) {
        try { Remove-HostInputShareRuntime -Runtime $runtime -BrokerRoot $BrokerRoot -SuppressErrors | Out-Null } catch { }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-JsonAtomic -Path $StatusPath -Value ([ordered]@{
        Success = $success
        Message = $message
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Details = $details
    })
}

$details | ConvertTo-Json -Depth 8
