[CmdletBinding()]
param(
    [string] $SourceRoot,
    [string] $BrokerRoot,
    [string] $PoolDefinitionPath,
    [string] $StatusPath,
    [string] $ConfigPath,
    [string] $ClientSid
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$layout.HarnessSourceRoot }
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($PoolDefinitionPath)) { $PoolDefinitionPath = Join-Path $SourceRoot 'pool-definition.json' }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-broker-install-status.json' }
if ([string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($ClientSid) } catch { throw "Invalid client SID: $ClientSid" }
$taskName = [string]$layout.BrokerTaskName
$maintenancePath = Join-Path $BrokerRoot 'State\maintenance.json'
$backupRoot = Join-Path $BrokerRoot ('InstallBackup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
$maintenanceCreated = $false
$taskStateCaptured = $false
$taskExistedBefore = $false
$taskWasRunningBefore = $false
$taskRegistrationAttempted = $false
$previousTaskXml = $null
$installationMutationStarted = $false
$credentialExistedBefore = $false
$installCommitted = $false
$rollbackSucceeded = $false
$installedFiles = @('HostBroker.ps1', 'PayloadCache.ps1', 'HostInputShare.ps1', 'RequestNetwork.ps1', 'LiveEvidence.ps1', 'PoolCommon.ps1', 'PoolBroker.ps1', 'PoolLifecycle.ps1', 'HostWorker.ps1')
$backedUpNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function New-FailClosedRequestNetworkPolicy {
    [ordered]@{
        FormatVersion = 1
        DefaultProfile = 'None'
        IsolatedTestNet = [ordered]@{
            Enabled = $true
            SwitchPrefix = 'Codex-Harness-TestNet'
            NetworkPrefix = '10.254.0.0/24'
        }
        InternetOnly = [ordered]@{
            Enabled = $false
            SwitchName = ''
            SwitchId = ''
            NatName = ''
            NatPrefix = ''
            ExternalIPInterfaceAddressPrefix = ''
            InternalRoutingDomainId = '{00000000-0000-0000-0000-000000000000}'
            TcpFilteringBehavior = 'AddressDependentFiltering'
            UdpFilteringBehavior = 'AddressDependentFiltering'
            UdpInboundRefresh = $false
            TcpEstablishedConnectionTimeout = 1800
            TcpTransientConnectionTimeout = 120
            UdpIdleSessionTimeout = 120
            IcmpQueryTimeout = 30
            GatewayAddress = ''
            PrefixLength = 24
            PrimaryVlanId = 0
            SecondaryVlanId = 0
            DnsServers = @()
            DenyRemotePrefixes = @()
        }
        TrustedLan = [ordered]@{
            Enabled = $false
            AllowedSwitches = @()
        }
    }
}

function Write-InstallStatus {
    param([bool] $Success, [string] $Message, $Verification)

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StatusPath) | Out-Null
    [ordered]@{
        Success = $Success
        Message = $Message
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        BrokerRoot = $BrokerRoot
        TaskName = $taskName
        Verification = $Verification
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

function Set-BrokerAcl {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [ValidateSet('None', 'Read', 'ReadExecute', 'Modify')] [string] $ClientMode,
        [switch] $ClientInherits,
        [string] $OwnerSid = 'S-1-5-32-544',
        [switch] $PreserveOwner
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot secure missing broker path: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $clientSidObject = [Security.Principal.SecurityIdentifier]::new($ClientSid)
    if (-not $PreserveOwner) { $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid)) }
    $containerInheritance = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    $clientInheritance = if ($item.PSIsContainer -and $ClientInherits) { $containerInheritance } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $containerInheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    if ($ClientMode -ne 'None') {
        $clientRights = switch ($ClientMode) {
            'Read' { [Security.AccessControl.FileSystemRights]::Read }
            'ReadExecute' { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
            'Modify' { [Security.AccessControl.FileSystemRights]::Modify }
        }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($clientSidObject, $clientRights, $clientInheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    if ($item.PSIsContainer) { [IO.Directory]::SetAccessControl($item.FullName, $acl) }
    else { [IO.File]::SetAccessControl($item.FullName, $acl) }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $argumentList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'),
            '-SourceRoot', ('"' + $SourceRoot + '"'),
            '-BrokerRoot', ('"' + $BrokerRoot + '"'),
            '-PoolDefinitionPath', ('"' + $PoolDefinitionPath + '"'),
            '-StatusPath', ('"' + $StatusPath + '"'),
            '-ConfigPath', ('"' + $layout.ConfigPath + '"'),
            '-ClientSid', $ClientSid
        )
        $elevated = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        if ($elevated.ExitCode -ne 0) {
            throw "The elevated pool broker installation exited with code $($elevated.ExitCode)."
        }
        return
    }
    Import-Module Hyper-V
    if (-not (Test-Path -LiteralPath $PoolDefinitionPath -PathType Leaf)) {
        throw "Pool definition is missing: $PoolDefinitionPath"
    }
    $definition = Get-Content -Raw -LiteralPath $PoolDefinitionPath | ConvertFrom-Json
    if ([int]$definition.FormatVersion -ne 1 -or [int]$definition.PoolSize -lt 1 -or [int]$definition.PoolSize -gt 4) {
        throw 'The pool definition format or size is invalid.'
    }
    if (-not (Test-Path -LiteralPath ([string]$definition.BaseVhdx) -PathType Leaf) -or -not (Get-Item -LiteralPath ([string]$definition.BaseVhdx) -Force).IsReadOnly) {
        throw 'The pool definition does not reference an immutable base VHDX.'
    }
    foreach ($worker in @($definition.Workers)) {
        if (-not (Get-VM -Name ([string]$worker.VmName) -ErrorAction SilentlyContinue)) {
            throw "Pool VM is missing: $($worker.VmName)"
        }
    }
    foreach ($name in $installedFiles) {
        $source = Join-Path $SourceRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required pool broker source file is missing: $source"
        }
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "$name has a PowerShell parse error: $($parseErrors[0].Message)"
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $maintenancePath) | Out-Null
    [ordered]@{
        Status = 'MaintenanceRequested'
        Reason = 'Installing the elastic Hyper-V pool broker.'
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $maintenancePath -Encoding UTF8
    $maintenanceCreated = $true

    $processingRoot = Join-Path $BrokerRoot 'Processing'
    $drainDeadline = [DateTime]::UtcNow.AddMinutes(20)
    while (@(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0 -and [DateTime]::UtcNow -lt $drainDeadline) {
        Start-Sleep -Seconds 1
    }
    if (@(Get-ChildItem -LiteralPath $processingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Timed out waiting for active executable tests to drain before pool broker installation.'
    }

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskStateCaptured = $true
    $taskExistedBefore = $null -ne $task
    $taskWasRunningBefore = $taskExistedBefore -and $task.State -eq 'Running'
    if ($taskExistedBefore) { $previousTaskXml = Export-ScheduledTask -TaskName $taskName -ErrorAction Stop }
    if ($task -and $task.State -eq 'Running') {
        $poolDrainDeadline = [DateTime]::UtcNow.AddMinutes(10)
        do {
            $workerStates = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'State\PoolWorkers') -Filter 'worker-*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
                try { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } catch { $null }
            } | Where-Object { $null -ne $_ })
            $busyWorkers = @($workerStates | Where-Object { $_.Status -notin @('Off', 'Faulted') })
            $runningVms = @($definition.Workers | Where-Object {
                $vm = Get-VM -Name ([string]$_.VmName) -ErrorAction SilentlyContinue
                $vm -and $vm.State -ne 'Off'
            })
            if ($busyWorkers.Count -eq 0 -and $runningVms.Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $poolDrainDeadline)
        if ($busyWorkers.Count -gt 0 -or $runningVms.Count -gt 0) {
            throw 'Timed out waiting for the maintenance policy to stop pool workers before broker installation.'
        }
    }
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($task -and $task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline)
    }

    $privateRoot = Join-Path $BrokerRoot 'Private'
    $requestNetworkLeaseRoot = Join-Path $BrokerRoot 'State\NetworkLeases'
    $liveEvidenceRoot = Join-Path $BrokerRoot 'LiveEvidence'
    $liveEvidenceRequestRoot = Join-Path $liveEvidenceRoot 'Requests'
    $liveEvidenceProcessingRoot = Join-Path $liveEvidenceRoot 'Processing'
    $liveEvidenceResponseRoot = Join-Path $liveEvidenceRoot 'Responses'
    $userWritable = @('Requests', 'Processing', 'Archive', 'Results', 'Staging', 'PayloadManifests', 'Cancellations', 'Cancelled') | ForEach-Object { Join-Path $BrokerRoot $_ }
    $systemWritable = @(
        (Join-Path $BrokerRoot 'State'),
        (Join-Path $BrokerRoot 'PayloadCache'),
        (Join-Path $BrokerRoot 'PayloadCacheTemp'),
        (Join-Path $BrokerRoot 'PayloadMounts'),
        (Join-Path $BrokerRoot 'PayloadChildren'),
        (Join-Path $BrokerRoot 'Pool')
    )
    New-Item -ItemType Directory -Force -Path $BrokerRoot, $privateRoot, $backupRoot | Out-Null
    New-Item -ItemType Directory -Force -Path ($userWritable + $systemWritable) | Out-Null
    New-Item -ItemType Directory -Force -Path $requestNetworkLeaseRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $liveEvidenceRoot, $liveEvidenceRequestRoot, $liveEvidenceProcessingRoot, $liveEvidenceResponseRoot | Out-Null

    # Establish a canonical DACL before any credential or configuration file is
    # created. Set-Acl replaces every prior explicit rule, so a reused install
    # root cannot retain an unrelated allow ACE.
    Set-BrokerAcl -Path $BrokerRoot -ClientMode ReadExecute
    foreach ($directory in $userWritable) { Set-BrokerAcl -Path $directory -ClientMode Modify -ClientInherits }
    foreach ($directory in $systemWritable) { Set-BrokerAcl -Path $directory -ClientMode ReadExecute -ClientInherits }
    foreach ($publicStateName in @('broker-state.json', 'pool-state.json')) {
        $publicStatePath = Join-Path (Join-Path $BrokerRoot 'State') $publicStateName
        if (Test-Path -LiteralPath $publicStatePath -PathType Leaf) {
            # Atomic replacement preserves the destination DACL. Normalize
            # reused status files while the old broker is stopped so queue
            # diagnostics remain readable after an in-place reinstall.
            Set-BrokerAcl -Path $publicStatePath -ClientMode Read
        }
    }
    Set-BrokerAcl -Path $requestNetworkLeaseRoot -ClientMode None
    Set-BrokerAcl -Path $liveEvidenceRoot -ClientMode ReadExecute
    Set-BrokerAcl -Path $liveEvidenceRequestRoot -ClientMode Modify -ClientInherits
    Set-BrokerAcl -Path $liveEvidenceProcessingRoot -ClientMode None
    Set-BrokerAcl -Path $liveEvidenceResponseRoot -ClientMode Read -ClientInherits
    Set-BrokerAcl -Path $privateRoot -ClientMode None
    Set-BrokerAcl -Path $backupRoot -ClientMode None

    foreach ($name in $installedFiles) {
        $destination = Join-Path $BrokerRoot $name
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Copy-Item -LiteralPath $destination -Destination (Join-Path $backupRoot $name) -Force
            [void]$backedUpNames.Add($name)
        }
    }
    $configPath = Join-Path $privateRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupRoot 'config.json') -Force
        [void]$backedUpNames.Add('config.json')
    }
    $credentialSource = Join-Path $SourceRoot 'private\guest-credential.json'
    $credentialDestination = Join-Path $privateRoot 'guest-credential.json'
    $credentialExistedBefore = Test-Path -LiteralPath $credentialDestination -PathType Leaf

    $installationMutationStarted = $true
    foreach ($name in $installedFiles) {
        $source = Join-Path $SourceRoot $name
        $destination = Join-Path $BrokerRoot $name
        $staged = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.new'
        Copy-Item -LiteralPath $source -Destination $staged -Force
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash) {
            throw "Staged hash mismatch for $name."
        }
        Move-Item -LiteralPath $staged -Destination $destination -Force
    }

    if (-not (Test-Path -LiteralPath $credentialDestination -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $credentialSource -PathType Leaf)) {
            throw 'The protected guest credential is missing.'
        }
        Copy-Item -LiteralPath $credentialSource -Destination $credentialDestination -Force
    }
    Set-BrokerAcl -Path $credentialDestination -ClientMode None

    $requestNetworkPolicy = if ($layout.PSObject.Properties['RequestNetworkPolicy'] -and $null -ne $layout.RequestNetworkPolicy) {
        $layout.RequestNetworkPolicy
    }
    else {
        [pscustomobject](New-FailClosedRequestNetworkPolicy)
    }
    if ([int]$requestNetworkPolicy.FormatVersion -ne 1) {
        throw "Unsupported request-network policy version: $($requestNetworkPolicy.FormatVersion)"
    }
    . (Join-Path $SourceRoot 'RequestNetwork.ps1')
    $null = Assert-RequestNetworkPolicySchema -Policy $requestNetworkPolicy

    $config = [ordered]@{
        VmName = [string]$definition.Workers[0].VmName
        BaselineName = [string]$definition.SourceCheckpointName
        PoolEnabled = $true
        PoolMaxWorkers = [int]$definition.PoolSize
        PoolWarmAhead = 1
        PoolIdleTimeoutSeconds = [int]$layout.PoolIdleTimeoutSeconds
        PoolLifecycleConcurrency = [int]$layout.PoolLifecycleConcurrency
        PoolFaultRecoveryBaseSeconds = 5
        PoolFaultRecoveryMaxSeconds = 600
        PoolRoot = [string]$definition.PoolRoot
        PoolBaseVhdx = [string]$definition.BaseVhdx
        PoolWorkers = @($definition.Workers)
        PayloadCacheMaxAgeDays = 30
        PayloadCacheMaxBytes = [long]64GB
        PayloadCacheTargetBytes = [long]56GB
        PayloadCacheMaxChainDepth = 8
        HostInputSwitchPrefix = 'Codex-Harness-HostInput'
        HostInputColdShareThresholdBytes = [long]1GB
        HostInputIncrementalShareThresholdBytes = [long]256MB
        RequestNetworkPolicy = $requestNetworkPolicy
        ClientSid = $ClientSid
        InstalledUtc = [DateTime]::UtcNow.ToString('o')
    }
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
    Set-BrokerAcl -Path $configPath -ClientMode None

    Set-BrokerAcl -Path $BrokerRoot -ClientMode ReadExecute
    foreach ($directory in $userWritable) {
        Set-BrokerAcl -Path $directory -ClientMode Modify -ClientInherits
    }
    foreach ($directory in $systemWritable) {
        Set-BrokerAcl -Path $directory -ClientMode ReadExecute -ClientInherits
    }
    Set-BrokerAcl -Path $requestNetworkLeaseRoot -ClientMode None
    Set-BrokerAcl -Path $liveEvidenceRoot -ClientMode ReadExecute
    Set-BrokerAcl -Path $liveEvidenceRequestRoot -ClientMode Modify -ClientInherits
    Set-BrokerAcl -Path $liveEvidenceProcessingRoot -ClientMode None
    Set-BrokerAcl -Path $liveEvidenceResponseRoot -ClientMode Read -ClientInherits
    Set-BrokerAcl -Path $privateRoot -ClientMode None
    foreach ($name in $installedFiles) {
        Set-BrokerAcl -Path (Join-Path $BrokerRoot $name) -ClientMode Read
    }
    foreach ($privateFile in Get-ChildItem -LiteralPath $privateRoot -File) {
        Set-BrokerAcl -Path $privateFile.FullName -ClientMode None
    }

    $brokerScript = Join-Path $BrokerRoot 'HostBroker.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$brokerScript`" -BrokerRoot `"$BrokerRoot`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $principalTask = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskRegistrationAttempted = $true
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principalTask -Description 'Runs isolated Windows executable tests across the elastic Hyper-V worker pool.' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $statePath = Join-Path $BrokerRoot 'State\broker-state.json'
    $fatalStatePath = Join-Path $BrokerRoot 'State\broker-fatal.json'
    $startedUtc = [DateTime]::UtcNow
    $readyDeadline = $startedUtc.AddSeconds(90)
    $verification = $null
    do {
        Start-Sleep -Milliseconds 300
        if (Test-Path -LiteralPath $fatalStatePath -PathType Leaf) {
            $fatalFile = Get-Item -LiteralPath $fatalStatePath
            if ($fatalFile.LastWriteTimeUtc -ge $startedUtc.AddSeconds(-2)) {
                $fatal = Get-Content -Raw -LiteralPath $fatalStatePath | ConvertFrom-Json
                throw "Pool broker startup failed: $($fatal.Error)"
            }
        }
        try {
            $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            $processAlive = $null -ne (Get-Process -Id ([int]$state.ProcessId) -ErrorAction SilentlyContinue)
            $heartbeatUtc = [DateTime]::Parse([string]$state.HeartbeatUtc).ToUniversalTime()
            $verification = [ordered]@{
                Status = [string]$state.Status
                PoolIdleTimeoutSeconds = [int]$config.PoolIdleTimeoutSeconds
                ProcessId = [int]$state.ProcessId
                ProcessAlive = $processAlive
                IdentitySid = [string]$state.IdentitySid
                SessionId = [int]$state.SessionId
                HeartbeatUtc = $heartbeatUtc.ToString('o')
                HeartbeatFresh = $heartbeatUtc -ge $startedUtc.AddSeconds(-2)
            }
        }
        catch { $verification = $null }
    } while ((-not $verification -or -not $verification.ProcessAlive -or -not $verification.HeartbeatFresh -or $verification.IdentitySid -ne 'S-1-5-18' -or $verification.SessionId -ne 0) -and [DateTime]::UtcNow -lt $readyDeadline)
    if (-not $verification -or -not $verification.ProcessAlive -or -not $verification.HeartbeatFresh -or $verification.IdentitySid -ne 'S-1-5-18' -or $verification.SessionId -ne 0) {
        throw 'The pool broker did not publish a verified SYSTEM heartbeat.'
    }

    Write-InstallStatus -Success $true -Message 'The elastic Hyper-V pool broker was installed and started.' -Verification $verification
    Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction Stop
    $maintenanceCreated = $false
    $installCommitted = $true
    if (Test-Path -LiteralPath $backupRoot -PathType Container) {
        # Backup cleanup is deliberately post-commit and non-fatal. A cleanup
        # failure must not enter rollback after a verified broker is live and
        # its success record is durable.
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    $installationError = $_.Exception
    $rollbackError = $null
    try {
        if ($taskRegistrationAttempted) {
            $replacementTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($replacementTask -and $replacementTask.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
                $stopDeadline = [DateTime]::UtcNow.AddSeconds(20)
                do {
                    Start-Sleep -Milliseconds 250
                    $replacementTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                } while ($replacementTask -and $replacementTask.State -eq 'Running' -and [DateTime]::UtcNow -lt $stopDeadline)
                if ($replacementTask -and $replacementTask.State -eq 'Running') { throw 'Rollback could not stop the replacement SYSTEM broker task.' }
            }
            if ($replacementTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Rollback could not unregister the replacement SYSTEM broker task.' }
        }
        if ($installationMutationStarted) {
            foreach ($name in $installedFiles) {
                $destination = Join-Path $BrokerRoot $name
                $backup = Join-Path $backupRoot $name
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    Copy-Item -LiteralPath $backup -Destination $destination -Force
                }
                elseif (-not $backedUpNames.Contains($name) -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
                    Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
                }
            }
            $configBackup = Join-Path $backupRoot 'config.json'
            if (Test-Path -LiteralPath $configBackup -PathType Leaf) {
                Copy-Item -LiteralPath $configBackup -Destination (Join-Path $BrokerRoot 'Private\config.json') -Force
            }
            elseif (-not $backedUpNames.Contains('config.json') -and (Test-Path -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') -PathType Leaf)) {
                Remove-Item -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') -Force -ErrorAction Stop
            }
            if (-not $credentialExistedBefore -and (Test-Path -LiteralPath (Join-Path $BrokerRoot 'Private\guest-credential.json') -PathType Leaf)) {
                Remove-Item -LiteralPath (Join-Path $BrokerRoot 'Private\guest-credential.json') -Force -ErrorAction Stop
            }
        }
        if ($taskStateCaptured -and $taskExistedBefore -and $taskRegistrationAttempted) {
            Register-ScheduledTask -TaskName $taskName -Xml $previousTaskXml -Force -ErrorAction Stop | Out-Null
        }
        if ($taskStateCaptured -and $taskExistedBefore) {
            $restoredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $restoredTask) { throw 'Rollback did not restore the pre-existing SYSTEM broker task.' }
            $restoredTaskXml = Export-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if (-not [string]::Equals(([xml]$restoredTaskXml).OuterXml, ([xml]$previousTaskXml).OuterXml, [StringComparison]::Ordinal)) {
                throw 'Rollback did not restore the exact pre-existing SYSTEM broker task definition.'
            }
            if ($taskWasRunningBefore) {
                if ($restoredTask.State -ne 'Running') { Start-ScheduledTask -TaskName $taskName -ErrorAction Stop }
                $startDeadline = [DateTime]::UtcNow.AddSeconds(20)
                do {
                    Start-Sleep -Milliseconds 250
                    $restoredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                } while ($restoredTask -and $restoredTask.State -ne 'Running' -and [DateTime]::UtcNow -lt $startDeadline)
                if (-not $restoredTask -or $restoredTask.State -ne 'Running') { throw 'Rollback restored the prior task definition but not its running state.' }
            }
        }
        elseif ($taskStateCaptured -and (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
            throw 'Rollback left a SYSTEM broker task behind after a fresh installation failure.'
        }
        $rollbackSucceeded = $true
    }
    catch { $rollbackError = $_.Exception }
    $failureMessage = $installationError.Message
    if ($rollbackError) { $failureMessage += " Rollback also failed: $($rollbackError.Message)" }
    Write-InstallStatus -Success $false -Message $failureMessage -Verification $null
    if ($rollbackError) { throw [InvalidOperationException]::new($failureMessage, $installationError) }
    throw $installationError
}
finally {
    # A failed rollback deliberately leaves maintenance.json in place. It is
    # the last fail-closed barrier preventing a partially restored broker from
    # accepting work. Only a durable commit or a verified rollback may clear it.
    if ($maintenanceCreated -and ($installCommitted -or $rollbackSucceeded)) {
        Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction SilentlyContinue
    }
    if ($rollbackSucceeded -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
