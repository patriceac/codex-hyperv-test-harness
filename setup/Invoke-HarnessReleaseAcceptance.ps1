[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [string] $EvidenceRoot,
    [string] $ClientSid,
    [switch] $InvocationPreflightOnly
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw 'InstallRoot must be a specific non-root directory.' }

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        [IO.File]::Delete($temporaryPath)
        [IO.File]::Delete($backupPath)
    }
}

function New-HarnessReleaseAcceptanceInvocations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SoftwareRoot,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $canaryRoot = Join-Path $SoftwareRoot 'Canaries'
    @(
        [pscustomobject][ordered]@{
            Name = 'LegacyLaunch'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'PoolCanary.exe'
                ActionsPath = Join-Path $canaryRoot 'smoke-actions.json'
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        },
        [pscustomobject][ordered]@{
            Name = 'KeyboardInput'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'HarnessContractCanary.exe'
                Arguments = '--result "{OUTDIR}\keyboard-result.json" --delay-ms 2500 --stay-ms 6500'
                ActionsPath = Join-Path $canaryRoot 'release-keyboard-actions.json'
                AssertResultFile = '{OUTDIR}\keyboard-result.json'
                AssertResultJsonPointer = '/passed'
                AssertResultEqualsJson = 'true'
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        },
        [pscustomobject][ordered]@{
            Name = 'ExpectedGuestPowerOff'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'ShutdownProbe.exe'
                Arguments = '--marker "{OUTDIR}\shutdown-marker.json" --delay-ms 3000'
                AssertResultFile = '{OUTDIR}\shutdown-marker.json'
                AssertResultJsonPointer = '/passed'
                AssertResultEqualsJson = 'true'
                ExpectGuestPowerOff = $true
                GuestPowerOffRecoveryTimeoutSeconds = 180
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        }
    )
}

if ($InvocationPreflightOnly) {
    $preview = @(New-HarnessReleaseAcceptanceInvocations -SoftwareRoot (Join-Path $InstallRoot 'Software') -BrokerRoot (Join-Path $InstallRoot 'Live\Broker'))
    [pscustomobject][ordered]@{
        Success = $preview.Count -eq 3
        NoMutationPerformed = $true
        TestNames = @($preview.Name)
        Invocations = $preview
    }
    return
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator rights are required for release acceptance.'
}
if ([string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($ClientSid) } catch { throw "Invalid client SID: $ClientSid" }

$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Harness configuration is missing: $configPath" }
. (Join-Path $InstallRoot 'Software\Harness\HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $configPath
$softwareRoot = [string]$layout.SoftwareRoot
$brokerRoot = [string]$layout.BrokerRoot
$definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
$runner = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
$maintenancePath = Join-Path $brokerRoot 'State\maintenance.json'
$poolStatePath = Join-Path $brokerRoot 'State\pool-state.json'
$brokerStatePath = Join-Path $brokerRoot 'State\broker-state.json'
$payloadGcStatePath = Join-Path $brokerRoot 'State\payload-cache-gc.json'
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $InstallRoot ('Live\Setup\ReleaseAcceptance\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not ($EvidenceRoot + '\').StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceRoot must remain below InstallRoot.'
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
Import-Module Hyper-V
$poolDefinition = Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json
$workerVmNames = @($poolDefinition.Workers | ForEach-Object { [string]$_.VmName })

function Invoke-PoolAudit {
    param([Parameter(Mandatory = $true)] [string] $Name)

    $statusPath = Join-Path $EvidenceRoot ($Name + '.json')
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Audit-HyperVTestPool.ps1') `
        -DefinitionPath $definitionPath `
        -BrokerRoot $brokerRoot `
        -StatusPath $statusPath `
        -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) `
        -ConfigPath $configPath `
        -ClientSid $ClientSid
    $audit = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw "The $Name release audit failed." }
    $statusPath
}

function Read-JsonIfPresent {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $null }
}

function Get-ReleaseAuditMaintenanceSnapshot {
    param([Parameter(Mandatory = $true)] [DateTime] $RequestedUtc)

    $poolState = Read-JsonIfPresent -Path $poolStatePath
    $brokerState = Read-JsonIfPresent -Path $brokerStatePath
    $payloadGcState = Read-JsonIfPresent -Path $payloadGcStatePath
    $processingCount = @(Get-ChildItem -LiteralPath (Join-Path $brokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    $workerStates = if ($poolState) { @($poolState.Workers) } else { @() }
    $nonOffWorkerStates = @($workerStates | Where-Object { [string]$_.Status -ne 'Off' })
    $vmStates = @(foreach ($vmName in $workerVmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{
            VmName = $vmName
            Present = $null -ne $vm
            State = if ($vm) { [string]$vm.State } else { 'Missing' }
        }
    })
    $runningVmNames = @($vmStates | Where-Object { -not $_.Present -or $_.State -ne 'Off' } | ForEach-Object { [string]$_.VmName })
    $brokerHeartbeatUtc = [DateTime]::MinValue
    if ($brokerState -and -not [string]::IsNullOrWhiteSpace([string]$brokerState.HeartbeatUtc)) {
        try { $brokerHeartbeatUtc = [DateTime]::Parse([string]$brokerState.HeartbeatUtc).ToUniversalTime() } catch { }
    }
    $gcStartedUtc = [DateTime]::MinValue
    if ($payloadGcState -and -not [string]::IsNullOrWhiteSpace([string]$payloadGcState.StartedUtc)) {
        try { $gcStartedUtc = [DateTime]::Parse([string]$payloadGcState.StartedUtc).ToUniversalTime() } catch { }
    }
    $heartbeatFresh = $brokerHeartbeatUtc -ge [DateTime]::UtcNow.AddSeconds(-5)
    $maintenanceObserved = $poolState -and [bool]$poolState.MaintenanceActive -and [string]$brokerState.Status -eq 'Maintenance' -and $heartbeatFresh
    $workerStatesOff = $workerStates.Count -eq $workerVmNames.Count -and $nonOffWorkerStates.Count -eq 0
    $workerVmsOff = $vmStates.Count -eq $workerVmNames.Count -and $runningVmNames.Count -eq 0
    $maintenanceCleanupCompleted = $payloadGcState -and [string]$payloadGcState.Status -eq 'Completed' -and $gcStartedUtc -ge $RequestedUtc

    [pscustomobject][ordered]@{
        Ready = $maintenanceObserved -and $processingCount -eq 0 -and $workerStatesOff -and $workerVmsOff -and $maintenanceCleanupCompleted
        ObservedUtc = [DateTime]::UtcNow.ToString('o')
        RequestedUtc = $RequestedUtc.ToString('o')
        ProcessingCount = $processingCount
        MaintenanceObserved = [bool]$maintenanceObserved
        BrokerStatus = if ($brokerState) { [string]$brokerState.Status } else { $null }
        BrokerHeartbeatUtc = if ($brokerHeartbeatUtc -eq [DateTime]::MinValue) { $null } else { $brokerHeartbeatUtc.ToString('o') }
        WorkerStatesOff = [bool]$workerStatesOff
        NonOffWorkerStates = @($nonOffWorkerStates | ForEach-Object { [pscustomobject]@{ WorkerId = [int]$_.WorkerId; Status = [string]$_.Status } })
        WorkerVmsOff = [bool]$workerVmsOff
        NonOffOrMissingVmNames = $runningVmNames
        MaintenanceCleanupCompleted = [bool]$maintenanceCleanupCompleted
        PayloadCleanupStatus = if ($payloadGcState) { [string]$payloadGcState.Status } else { $null }
        PayloadCleanupStartedUtc = if ($gcStartedUtc -eq [DateTime]::MinValue) { $null } else { $gcStartedUtc.ToString('o') }
    }
}

function Invoke-PoolAuditUnderMaintenance {
    param([Parameter(Mandatory = $true)] [string] $Name)

    if (Test-Path -LiteralPath $maintenancePath -PathType Leaf) {
        throw "Cannot start the $Name release audit because another broker maintenance owner is active."
    }
    $ownerToken = [Guid]::NewGuid().ToString('N')
    $requestedUtc = [DateTime]::UtcNow
    $markerCreated = $false
    try {
        Write-JsonAtomic -Path $maintenancePath -Value ([ordered]@{
            Status = 'MaintenanceRequested'
            Reason = "Draining the pool for the strict $Name release audit."
            RequestedUtc = $requestedUtc.ToString('o')
            RequestedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            Owner = 'HarnessReleaseAcceptance'
            OwnerToken = $ownerToken
        })
        $markerCreated = $true

        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        $snapshot = $null
        do {
            $marker = Read-JsonIfPresent -Path $maintenancePath
            if (-not $marker -or [string]$marker.OwnerToken -cne $ownerToken) {
                throw "The $Name release audit lost ownership of broker maintenance."
            }
            $snapshot = Get-ReleaseAuditMaintenanceSnapshot -RequestedUtc $requestedUtc
            if ([bool]$snapshot.Ready) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $snapshot -or -not [bool]$snapshot.Ready) {
            $details = if ($snapshot) { $snapshot | ConvertTo-Json -Depth 8 -Compress } else { 'no maintenance snapshot' }
            throw "Timed out draining broker maintenance for the $Name release audit: $details"
        }

        $maintenanceEvidencePath = Join-Path $EvidenceRoot ($Name + '-maintenance.json')
        Write-JsonAtomic -Path $maintenanceEvidencePath -Value $snapshot
        $auditPath = Invoke-PoolAudit -Name $Name
        [pscustomobject][ordered]@{
            AuditPath = $auditPath
            MaintenanceEvidencePath = $maintenanceEvidencePath
        }
    }
    finally {
        if ($markerCreated) {
            $currentMarker = Read-JsonIfPresent -Path $maintenancePath
            if ($currentMarker -and [string]$currentMarker.OwnerToken -ceq $ownerToken) {
                Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $maintenancePath -PathType Leaf) {
                throw "The $Name release audit did not remove a maintenance marker now owned by another operation."
            }
        }
    }
}

function Invoke-AcceptanceTest {
    param([Parameter(Mandatory = $true)] $Definition)

    $requiredPaths = @([string]$Definition.Parameters['ArtifactPath'])
    if ($Definition.Parameters.ContainsKey('ActionsPath')) {
        $requiredPaths += [string]$Definition.Parameters['ActionsPath']
    }
    foreach ($requiredPath in $requiredPaths) {
        if (-not [string]::IsNullOrWhiteSpace($requiredPath) -and -not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Release acceptance input is missing: $requiredPath"
        }
    }
    $parameters = $Definition.Parameters
    $output = @(& $runner @parameters)
    $json = $output | Select-Object -Last 1
    if ($null -eq $json) { throw "$($Definition.Name) returned no summary." }
    $summary = if ($json -is [string]) { $json | ConvertFrom-Json } else { $json }
    if (-not [bool]$summary.Success -or -not [bool]$summary.PayloadChildDeleted -or [string]$summary.VmFinalState -ne 'Off') {
        throw "$($Definition.Name) did not satisfy the isolated harness contract: $($summary.Error)"
    }
    $summary
}

$startedUtc = [DateTime]::UtcNow
$preAudit = Invoke-PoolAuditUnderMaintenance -Name 'pre-acceptance-audit'
$preAuditPath = [string]$preAudit.AuditPath
$invocations = @(New-HarnessReleaseAcceptanceInvocations -SoftwareRoot $softwareRoot -BrokerRoot $brokerRoot)
$results = [ordered]@{}
foreach ($invocation in $invocations) {
    $results[[string]$invocation.Name] = Invoke-AcceptanceTest -Definition $invocation
}

$legacy = $results.LegacyLaunch
if (-not (Test-Path -LiteralPath (Join-Path ([string]$legacy.ResultPath) 'recovery-smoke.png') -PathType Leaf)) {
    throw 'Legacy launch acceptance did not return its screenshot.'
}

$keyboard = $results.KeyboardInput
foreach ($fileName in @('keyboard-before.png', 'keyboard-after.png')) {
    if (-not (Test-Path -LiteralPath (Join-Path ([string]$keyboard.ResultPath) $fileName) -PathType Leaf)) {
        throw "Keyboard acceptance did not return $fileName."
    }
}
$keyboardGuest = Get-Content -LiteralPath ([string]$keyboard.GuestResultPath) -Raw | ConvertFrom-Json
$keyboardActions = @($keyboardGuest.Actions | Where-Object { [string]$_.Type -eq 'send_keys' })
if ($keyboardActions.Count -ne 1 -or
    -not [bool]$keyboardActions[0].Success -or
    [string]$keyboardActions[0].Details.KeySpec -ne 'WIN+LEFT' -or
    (@($keyboardActions[0].Details.VirtualKeyCodes) -join ',') -ne '0x5B,0x25') {
    throw 'Keyboard acceptance did not prove the exact WIN+LEFT key chord and virtual-key sequence.'
}

$shutdown = $results.ExpectedGuestPowerOff
if (-not [bool]$shutdown.ExpectedGuestPowerOffContractProven -or
    -not [bool]$shutdown.ExpectedGuestPowerOffContractSatisfied -or
    [bool]$shutdown.ApplicationRelaunchedByHarnessAfterGuestPowerOff) {
    throw 'Expected-guest-power-off acceptance did not prove ordered shutdown and no replay.'
}

$postAudit = Invoke-PoolAuditUnderMaintenance -Name 'post-acceptance-audit'
$postAuditPath = [string]$postAudit.AuditPath
[pscustomobject][ordered]@{
    Success = $true
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    EvidenceRoot = $EvidenceRoot
    PreAuditPath = $preAuditPath
    PreAuditMaintenanceEvidencePath = [string]$preAudit.MaintenanceEvidencePath
    PostAuditPath = $postAuditPath
    PostAuditMaintenanceEvidencePath = [string]$postAudit.MaintenanceEvidencePath
    Tests = @($invocations | ForEach-Object {
        $summary = $results[[string]$_.Name]
        [pscustomobject][ordered]@{
            Name = [string]$_.Name
            RequestId = [string]$summary.RequestId
            ResultPath = [string]$summary.ResultPath
            Success = [bool]$summary.Success
        }
    })
}
