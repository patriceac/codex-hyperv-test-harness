[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $ClientSid,
    [string] $StatusPath,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'vm-profile-update-status.json' }
try { [void][Security.Principal.SecurityIdentifier]::new($ClientSid) } catch { throw "Invalid client SID: $ClientSid" }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($NoElevation) { throw 'Updating the harness VM profile requires administrator rights.' }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-ConfigPath', ('"' + $layout.ConfigPath + '"'),
        '-ClientSid', $ClientSid,
        '-StatusPath', ('"' + $StatusPath + '"'),
        '-NoElevation'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

$startedUtc = [DateTime]::UtcNow
function Write-ProfileStatus {
    param([bool] $Success, [string] $Message, $Details)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StatusPath) | Out-Null
    [ordered]@{
        Success = $Success
        Message = $Message
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Details = $Details
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

try {
    Import-Module Hyper-V -ErrorAction Stop
    $baselineName = [string]$layout.BaselineVmName
    $baseline = Get-VM -Name $baselineName -ErrorAction Stop
    if ($baseline.State -ne 'Off') { Stop-VM -Name $baselineName -TurnOff -Force -ErrorAction Stop | Out-Null }
    Set-VMProcessor -VMName $baselineName -Count ([int]$layout.VmProcessorCount) -ErrorAction Stop
    Set-VMMemory -VMName $baselineName -DynamicMemoryEnabled $false -StartupBytes ([long]$layout.VmMemoryBytes) -ErrorAction Stop
    Set-VMVideo -VMName $baselineName -HorizontalResolution ([int]$layout.GuestDisplayWidth) -VerticalResolution ([int]$layout.GuestDisplayHeight) -ResolutionType Single -ErrorAction Stop
    Get-VMNetworkAdapter -VMName $baselineName -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue

    $definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Initialize-HyperVTestPool.ps1') `
        -SourceVmName $baselineName `
        -BaselineName ([string]$layout.BaselineCheckpointName) `
        -PoolSize ([int]$layout.PoolSize) `
        -PoolVmPrefix ([string]$layout.PoolVmPrefix) `
        -BrokerRoot ([string]$layout.BrokerRoot) `
        -DefinitionPath $definitionPath `
        -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-provision-status.json') `
        -ConfigPath $layout.ConfigPath `
        -ForceRecreate

    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Install-PoolHostBroker.ps1') `
        -SourceRoot ([string]$layout.HarnessSourceRoot) `
        -BrokerRoot ([string]$layout.BrokerRoot) `
        -PoolDefinitionPath $definitionPath `
        -StatusPath (Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-broker-install-status.json') `
        -ConfigPath $layout.ConfigPath `
        -ClientSid $ClientSid

    $auditPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-audit-status.json'
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Audit-HyperVTestPool.ps1') `
        -DefinitionPath $definitionPath `
        -BrokerRoot ([string]$layout.BrokerRoot) `
        -StatusPath $auditPath `
        -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) `
        -ConfigPath $layout.ConfigPath

    $definition = Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The rebuilt pool failed its elevated audit.' }
    $baselineMemory = Get-VMMemory -VMName $baselineName -ErrorAction Stop
    $baselineVideo = Get-VMVideo -VMName $baselineName -ErrorAction Stop
    $details = [ordered]@{
        BaselineVmName = $baselineName
        BaselineMemoryBytes = [long]$baselineMemory.Startup
        BaselineDynamicMemoryEnabled = [bool]$baselineMemory.DynamicMemoryEnabled
        BaselineDisplayWidth = [int]$baselineVideo.HorizontalResolution
        BaselineDisplayHeight = [int]$baselineVideo.VerticalResolution
        BaselineDisplayResolutionType = [string]$baselineVideo.ResolutionType
        PoolSize = [int]$definition.PoolSize
        PoolMemoryBytes = [long]$definition.VmMemoryBytes
        PoolDisplayWidth = [int]$definition.GuestDisplayWidth
        PoolDisplayHeight = [int]$definition.GuestDisplayHeight
        AuditPath = $auditPath
    }
    Write-ProfileStatus -Success $true -Message 'The baseline and four-worker pool use the configured VM hardware profile.' -Details $details
}
catch {
    Write-ProfileStatus -Success $false -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
    throw
}
