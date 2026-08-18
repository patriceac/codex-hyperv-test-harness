[CmdletBinding()]
param(
    [string] $DefinitionPath,
    [string] $BrokerRoot,
    [string] $StatusPath,
    [ValidateRange(30, 3600)] [int] $ExpectedIdleTimeoutSeconds = 600,
    [string] $ConfigPath,
    [string] $ClientSid
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
. (Join-Path $PSScriptRoot 'RequestNetwork.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($DefinitionPath)) { $DefinitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json' }
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'pool-audit-status.json' }

function Test-SamePath {
    param(
        [AllowNull()] [string] $Left,
        [AllowNull()] [string] $Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    [string]::Equals(
        [IO.Path]::GetFullPath($Left),
        [IO.Path]::GetFullPath($Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ExplicitAllowRights {
    param(
        [Parameter(Mandatory = $true)] [Security.AccessControl.FileSystemSecurity] $Acl,
        [Parameter(Mandatory = $true)] [string] $Sid
    )

    [long]$rights = 0
    foreach ($rule in @($Acl.Access | Where-Object { -not $_.IsInherited -and $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow })) {
        try { $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { continue }
        if ($ruleSid -eq $Sid) { $rights = $rights -bor [long]$rule.FileSystemRights }
    }
    $rights
}

function Test-BrokerAclProfile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [ValidateSet('None', 'Read', 'ReadExecute', 'Modify')] [string] $ClientMode,
        [Parameter(Mandatory = $true)] [string] $ResolvedClientSid,
        [switch] $ClientInherits,
        [string[]] $AllowedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ Path = $Path; ClientMode = $ClientMode; Passed = $false; Error = 'Missing path' }
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    try { $ownerSid = $acl.Owner.Translate([Security.Principal.SecurityIdentifier]).Value }
    catch {
        try { $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $ownerSid = [string]$acl.Owner }
    }
    [long]$systemRights = Get-ExplicitAllowRights -Acl $acl -Sid 'S-1-5-18'
    [long]$adminRights = Get-ExplicitAllowRights -Acl $acl -Sid 'S-1-5-32-544'
    [long]$clientRights = Get-ExplicitAllowRights -Acl $acl -Sid $ResolvedClientSid

    function Get-RuleDescriptor {
        param([Security.AccessControl.FileSystemAccessRule] $Rule)
        try { $sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = [string]$Rule.IdentityReference.Value }
        [pscustomobject][ordered]@{
            Sid = $sid
            Rights = [string]$Rule.FileSystemRights
            RightsValue = [long]$Rule.FileSystemRights
            Type = [string]$Rule.AccessControlType
            TypeValue = [int]$Rule.AccessControlType
            InheritanceFlags = [string]$Rule.InheritanceFlags
            InheritanceFlagsValue = [int]$Rule.InheritanceFlags
            PropagationFlags = [string]$Rule.PropagationFlags
            PropagationFlagsValue = [int]$Rule.PropagationFlags
            Inherited = [bool]$Rule.IsInherited
            Key = "$sid|$([long]$Rule.FileSystemRights)|$([int]$Rule.AccessControlType)|$([int]$Rule.InheritanceFlags)|$([int]$Rule.PropagationFlags)|$([bool]$Rule.IsInherited)"
        }
    }

    $containerInheritance = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    $clientInheritance = if ($item.PSIsContainer -and $ClientInherits) { $containerInheritance } else { [Security.AccessControl.InheritanceFlags]::None }
    $expectedRules = New-Object Collections.Generic.List[object]
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.FileSystemRights]::FullControl, $containerInheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $expectedRules.Add((Get-RuleDescriptor -Rule $rule))
    }
    if ($ClientMode -ne 'None') {
        $expectedClientRights = switch ($ClientMode) {
            'Read' { [Security.AccessControl.FileSystemRights]::Read }
            'ReadExecute' { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
            'Modify' { [Security.AccessControl.FileSystemRights]::Modify }
        }
        $clientRule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($ResolvedClientSid), $expectedClientRights, $clientInheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $expectedRules.Add((Get-RuleDescriptor -Rule $clientRule))
    }
    $actualRules = @($acl.Access | ForEach-Object { Get-RuleDescriptor -Rule $_ })
    $expectedKeys = @($expectedRules | ForEach-Object Key)
    $actualKeys = @($actualRules | ForEach-Object Key)
    $missingRules = @($expectedRules | Where-Object { $_.Key -notin $actualKeys })
    $unexpectedRules = @($actualRules | Where-Object { $_.Key -notin $expectedKeys })
    $ruleCountMatches = $actualRules.Count -eq $expectedRules.Count
    $ownerAllowed = $ownerSid -in $AllowedOwnerSids
    $exactDescriptor = $acl.AreAccessRulesProtected -and $ownerAllowed -and $ruleCountMatches -and $missingRules.Count -eq 0 -and $unexpectedRules.Count -eq 0

    [pscustomobject][ordered]@{
        Path = $Path
        ClientMode = $ClientMode
        ClientInherits = [bool]$ClientInherits
        Passed = [bool]$exactDescriptor
        InheritanceProtected = [bool]$acl.AreAccessRulesProtected
        OwnerSid = $ownerSid
        OwnerAllowed = [bool]$ownerAllowed
        RuleCountMatches = [bool]$ruleCountMatches
        SystemRights = ([Security.AccessControl.FileSystemRights]$systemRights).ToString()
        AdministratorsRights = ([Security.AccessControl.FileSystemRights]$adminRights).ToString()
        ClientRights = ([Security.AccessControl.FileSystemRights]$clientRights).ToString()
        ClientRightsValue = $clientRights
        ExpectedAccessRules = $expectedRules.ToArray()
        MissingAccessRules = $missingRules
        UnexpectedAccessRules = $unexpectedRules
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $argumentList = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $PSCommandPath + '"'),
            '-DefinitionPath', ('"' + $DefinitionPath + '"'),
            '-BrokerRoot', ('"' + $BrokerRoot + '"'),
            '-StatusPath', ('"' + $StatusPath + '"'),
            '-ExpectedIdleTimeoutSeconds', [string]$ExpectedIdleTimeoutSeconds
        )
        if (-not [string]::IsNullOrWhiteSpace($ClientSid)) { $argumentList += @('-ClientSid', $ClientSid) }
        $elevated = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        if ($elevated.ExitCode -ne 0) {
            throw "The elevated pool audit exited with code $($elevated.ExitCode)."
        }
        return
    }

    Import-Module Hyper-V -ErrorAction Stop
    $definition = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json
    $basePath = [IO.Path]::GetFullPath([string]$definition.BaseVhdx)
    $payloadChildrenRoot = [IO.Path]::GetFullPath((Join-Path $BrokerRoot 'PayloadChildren'))
    $payloadChildPrefix = $payloadChildrenRoot.TrimEnd('\') + '\'

    $sourceVm = Get-VM -Name ([string]$definition.SourceVmName) -ErrorAction Stop
    $sourceCheckpoint = Get-VMSnapshot -VMName $sourceVm.Name -Name ([string]$definition.SourceCheckpointName) -ErrorAction Stop
    $sourceProcessor = Get-VMProcessor -VMName $sourceVm.Name -ErrorAction Stop
    $sourceMemory = Get-VMMemory -VMName $sourceVm.Name -ErrorAction Stop
    $sourceVideo = Get-VMVideo -VMName $sourceVm.Name -ErrorAction Stop
    $sourceNetworkAdapters = @(Get-VMNetworkAdapter -VMName $sourceVm.Name -ErrorAction Stop)
    $baseFile = Get-Item -LiteralPath $basePath -Force -ErrorAction Stop
    $baseVhd = Get-VHD -Path $basePath -ErrorAction Stop

    $workers = New-Object Collections.Generic.List[object]
    foreach ($workerDefinition in @($definition.Workers | Sort-Object WorkerId)) {
        $vm = Get-VM -Name ([string]$workerDefinition.VmName) -ErrorAction Stop
        $processor = Get-VMProcessor -VMName $vm.Name -ErrorAction Stop
        $memory = Get-VMMemory -VMName $vm.Name -ErrorAction Stop
        $video = Get-VMVideo -VMName $vm.Name -ErrorAction Stop
        $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction Stop)
        $drives = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop)
        $attachedPayloads = @($drives | Where-Object {
            $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).StartsWith($payloadChildPrefix, [StringComparison]::OrdinalIgnoreCase)
        })
        $osDrive = @($drives | Where-Object { Test-SamePath -Left ([string]$_.Path) -Right ([string]$workerDefinition.OsChildPath) }) | Select-Object -First 1
        $osVhd = if ($osDrive) { Get-VHD -Path ([string]$osDrive.Path) -ErrorAction Stop } else { $null }

        $workers.Add([pscustomobject][ordered]@{
            WorkerId = [int]$workerDefinition.WorkerId
            VmName = $vm.Name
            VmId = [string]$vm.Id
            State = [string]$vm.State
            Generation = [int]$vm.Generation
            ProcessorCount = [int]$processor.Count
            StartupMemoryBytes = [long]$memory.Startup
            DynamicMemoryEnabled = [bool]$memory.DynamicMemoryEnabled
            DisplayWidth = [int]$video.HorizontalResolution
            DisplayHeight = [int]$video.VerticalResolution
            DisplayResolutionType = [string]$video.ResolutionType
            NetworkAdapters = @($adapters | ForEach-Object {
                [ordered]@{
                    Name = $_.Name
                    SwitchName = [string]$_.SwitchName
                    Connected = -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName)
                    ManagedRequestNetwork = [string]$_.Name -like 'CodexRequestNet-*'
                }
            })
            DiskCount = $drives.Count
            OsChildPath = if ($osDrive) { [string]$osDrive.Path } else { $null }
            OsChildExists = Test-Path -LiteralPath ([string]$workerDefinition.OsChildPath) -PathType Leaf
            OsParentPath = if ($osVhd) { [string]$osVhd.ParentPath } else { $null }
            OsParentMatchesBase = $osVhd -and (Test-SamePath -Left ([string]$osVhd.ParentPath) -Right $basePath)
            AttachedPayloadChildren = @($attachedPayloads | ForEach-Object { [string]$_.Path })
        })
    }

    # Keep the residue audit authoritative for every VM on the host. The pool
    # definition is not an authority for Hyper-V inventory: an adapter left on
    # an unconfigured VM is still harness residue and must fail the audit.
    $allVms = @(Get-VM -ErrorAction Stop)
    $allVmNetworkAdapters = @(Get-VMNetworkAdapter -All -ErrorAction Stop)

    $payloadChildFiles = @(Get-ChildItem -LiteralPath $payloadChildrenRoot -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue)
    $payloadLeaseFiles = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'State\PayloadLeases') -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)
    $requestNetworkLeaseFiles = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'State\NetworkLeases') -Filter '*.json' -File -Force -ErrorAction Stop)
    $managedRequestNetworkAdapters = @($allVmNetworkAdapters | Where-Object { [string]$_.Name -like 'CodexRequestNet-*' })
    $requestNetworkInstallationScope = Get-RequestNetworkInstallationScope -BrokerRoot $BrokerRoot
    $managedRequestNetworkSwitches = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
        [string]$_.Notes -like ('CodexHarnessRequestNetwork:' + $requestNetworkInstallationScope + ':*')
    })
    $queuedFiles = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Requests') -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)
    $processingFiles = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Processing') -Filter '*.json' -File -Force -ErrorAction SilentlyContinue)
    $cacheEntries = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'PayloadCache') -Directory -Force -ErrorAction SilentlyContinue | Where-Object Name -Match '^[A-Fa-f0-9]{64}$')
    $gcPath = Join-Path $BrokerRoot 'State\payload-cache-gc.json'
    $gcState = if (Test-Path -LiteralPath $gcPath -PathType Leaf) { Get-Content -LiteralPath $gcPath -Raw | ConvertFrom-Json } else { $null }
    $brokerStatePath = Join-Path $BrokerRoot 'State\broker-state.json'
    $brokerState = if (Test-Path -LiteralPath $brokerStatePath -PathType Leaf) { Get-Content -LiteralPath $brokerStatePath -Raw | ConvertFrom-Json } else { $null }
    $configPath = Join-Path $BrokerRoot 'Private\config.json'
    $brokerConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $requestNetworkPolicy = $null
    $requestNetworkPolicyVersioned = $false
    try {
        # This is the shared runtime validator. In particular, a string such
        # as "false" is not a Boolean and therefore cannot enable a profile in
        # the audit path through PowerShell truthiness.
        $requestNetworkPolicy = Get-RequestNetworkPolicy -Config $brokerConfig
        $requestNetworkPolicyVersioned = $true
    }
    catch { $requestNetworkPolicy = $null }

    $isolatedPolicyValid = $false
    $internetPolicyValid = $false
    $trustedLanPolicyValid = $false
    if ($requestNetworkPolicyVersioned) {
        try {
            $isolatedSettings = Get-RequestNetworkObjectPropertyValue -Value $requestNetworkPolicy -Name 'IsolatedTestNet'
            $null = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$isolatedSettings.NetworkPrefix) -Context 'IsolatedTestNet.NetworkPrefix'
            $isolatedPolicyValid = -not $isolatedSettings.Enabled -or [string]$isolatedSettings.SwitchPrefix -match '^[A-Za-z0-9._-]{1,80}$'
        }
        catch { $isolatedPolicyValid = $false }
    }
    if ($requestNetworkPolicyVersioned -and $requestNetworkPolicy.InternetOnly.Enabled) {
        $internetSettings = Get-RequestNetworkObjectPropertyValue -Value $requestNetworkPolicy -Name 'InternetOnly'
        $null = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$internetSettings.NatPrefix) -Context 'InternetOnly.NatPrefix'
        $internetSwitches = @(Get-VMSwitch -Name ([string]$internetSettings.SwitchName) -ErrorAction Stop)
        $allInternetNats = @(Get-NetNat -ErrorAction Stop)
        $internetNats = @($allInternetNats | Where-Object { [string]::Equals([string]$_.Name, [string]$internetSettings.NatName, [StringComparison]::Ordinal) })
        $internetStaticMappings = @(Get-RequestNetworkNatStaticMappings -NatName ([string]$internetSettings.NatName))
        $internetNatPolicyValid = $false
        if ($internetNats.Count -eq 1) {
            try {
                $expectedNatPolicy = Get-RequestNetworkExpectedNatPolicy -Settings $internetSettings
                $internetNatPolicyValid = Assert-RequestNetworkNatPolicy -Nat $internetNats[0] -ExpectedPolicy $expectedNatPolicy -ExpectedInternalPrefix ([string]$internetSettings.NatPrefix)
            }
            catch { $internetNatPolicyValid = $false }
        }
        $internetVmAdapters = @($allVmNetworkAdapters | Where-Object {
            [string]::Equals([string]$_.SwitchName, [string]$internetSettings.SwitchName, [StringComparison]::Ordinal)
        })
        $internetManagementAdapters = @(Get-VMNetworkAdapter -ManagementOS -SwitchName ([string]$internetSettings.SwitchName) -ErrorAction Stop)
        $internetGatewayVlan = @(if ($internetManagementAdapters.Count -eq 1) {
            Get-VMNetworkAdapterVlan -VMNetworkAdapter $internetManagementAdapters[0] -ErrorAction Stop
        }
        else { @() })
        $internetGatewayMac = if ($internetManagementAdapters.Count -eq 1) { (([string]$internetManagementAdapters[0].MacAddress) -replace '[:-]', '').ToUpperInvariant() } else { '' }
        $internetHostAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            (([string]$_.MacAddress) -replace '[:-]', '').ToUpperInvariant() -eq $internetGatewayMac
        })
        $internetGatewayAddresses = @(if ($internetHostAdapters.Count -eq 1) {
            Get-NetIPAddress -InterfaceIndex ([int]$internetHostAdapters[0].ifIndex) -AddressFamily IPv4 -IPAddress ([string]$internetSettings.GatewayAddress) -ErrorAction Stop
        }
        else { @() })
        $internetPolicyValid =
            $internetSwitches.Count -eq 1 -and
            [string]$internetSwitches[0].SwitchType -eq 'Internal' -and
            [string]::Equals([string]$internetSwitches[0].Id, [string]$internetSettings.SwitchId, [StringComparison]::OrdinalIgnoreCase) -and
            $allInternetNats.Count -eq 1 -and $internetNats.Count -eq 1 -and
            [string]::Equals([string]$internetNats[0].InternalIPInterfaceAddressPrefix, [string]$internetSettings.NatPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            $internetNatPolicyValid -and
            $internetStaticMappings.Count -eq 0 -and
            @($internetVmAdapters | Where-Object { [string]$_.Name -notlike 'CodexRequestNet-*' }).Count -eq 0 -and
            $internetManagementAdapters.Count -eq 1 -and $internetHostAdapters.Count -eq 1 -and $internetGatewayAddresses.Count -eq 1 -and
            $internetGatewayVlan.Count -eq 1 -and
            [string]$internetGatewayVlan[0].OperationMode -eq 'Private' -and
            [string]$internetGatewayVlan[0].PrivateVlanMode -eq 'Promiscuous' -and
            [int]$internetGatewayVlan[0].PrimaryVlanId -eq [int]$internetSettings.PrimaryVlanId -and
            @($internetGatewayVlan[0].SecondaryVlanIdList).Count -eq 1 -and
            [int](@($internetGatewayVlan[0].SecondaryVlanIdList)[0]) -eq [int]$internetSettings.SecondaryVlanId -and
            [int]$internetSettings.PrimaryVlanId -ge 1 -and [int]$internetSettings.PrimaryVlanId -le 4094 -and
            [int]$internetSettings.SecondaryVlanId -ge 1 -and [int]$internetSettings.SecondaryVlanId -le 4094 -and
            [int]$internetSettings.PrimaryVlanId -ne [int]$internetSettings.SecondaryVlanId -and
            [int]$internetSettings.PrefixLength -eq 24 -and
            @($internetSettings.DnsServers).Count -gt 0
    }
    elseif ($requestNetworkPolicyVersioned) {
        $internetPolicyValid = $true
    }
    if ($requestNetworkPolicyVersioned -and $requestNetworkPolicy.TrustedLan.Enabled) {
        $allowedSwitches = @($requestNetworkPolicy.TrustedLan.AllowedSwitches)
        $trustedLanPolicyValid = $allowedSwitches.Count -gt 0
        foreach ($allowedSwitch in $allowedSwitches) {
            $matches = @(Get-VMSwitch -Name ([string]$allowedSwitch.Name) -ErrorAction Stop)
            $descriptions = @(if ($matches.Count -eq 1) {
                $matches[0].NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
            }
            else { @() })
            if ($descriptions.Count -eq 0 -and $matches.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$matches[0].NetAdapterInterfaceDescription)) {
                $descriptions = @([string]$matches[0].NetAdapterInterfaceDescription)
            }
            if ($matches.Count -ne 1 -or [string]$matches[0].SwitchType -ne 'External' -or
                -not [string]::Equals([string]$matches[0].Id, [string]$allowedSwitch.Id, [StringComparison]::OrdinalIgnoreCase) -or
                [bool]$matches[0].EmbeddedTeamingEnabled -or $descriptions.Count -ne 1 -or
                -not [string]::Equals([string]$matches[0].NetAdapterInterfaceGuid, [string]$allowedSwitch.NetAdapterInterfaceGuid, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$descriptions[0], [string]$allowedSwitch.NetAdapterInterfaceDescription, [StringComparison]::Ordinal) -or
                $allowedSwitch.AllowManagementOS -isnot [bool] -or [bool]$matches[0].AllowManagementOS -ne [bool]$allowedSwitch.AllowManagementOS) {
                $trustedLanPolicyValid = $false
            }
        }
    }
    elseif ($requestNetworkPolicyVersioned) {
        $trustedLanPolicyValid = $true
    }
    $resolvedClientSid = if (-not [string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid } elseif (-not [string]::IsNullOrWhiteSpace([string]$brokerConfig.ClientSid)) { [string]$brokerConfig.ClientSid } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    try { [void][Security.Principal.SecurityIdentifier]::new($resolvedClientSid) } catch { throw "Invalid broker client SID: $resolvedClientSid" }
    $brokerTask = Get-ScheduledTask -TaskName ([string]$layout.BrokerTaskName) -ErrorAction SilentlyContinue

    $installedFiles = @('HostBroker.ps1', 'PayloadCache.ps1', 'HostInputShare.ps1', 'RequestNetwork.ps1', 'PoolCommon.ps1', 'PoolBroker.ps1', 'PoolLifecycle.ps1', 'HostWorker.ps1')
    $privateRoot = Join-Path $BrokerRoot 'Private'
    $aclTargets = New-Object Collections.Generic.List[object]
    $aclTargets.Add([pscustomobject]@{ Path = $BrokerRoot; ClientMode = 'ReadExecute'; ClientInherits = $false })
    foreach ($name in @('Requests', 'Processing', 'Archive', 'Results', 'Staging', 'PayloadManifests', 'Cancellations', 'Cancelled')) {
        $aclTargets.Add([pscustomobject]@{ Path = Join-Path $BrokerRoot $name; ClientMode = 'Modify'; ClientInherits = $true })
    }
    $aclTargets.Add([pscustomobject]@{ Path = $privateRoot; ClientMode = 'None'; ClientInherits = $false })
    foreach ($path in @((Join-Path $BrokerRoot 'State'), (Join-Path $BrokerRoot 'PayloadCache'), (Join-Path $BrokerRoot 'PayloadCacheTemp'), (Join-Path $BrokerRoot 'PayloadMounts'), (Join-Path $BrokerRoot 'PayloadChildren'), (Join-Path $BrokerRoot 'Pool'))) {
        $aclTargets.Add([pscustomobject]@{ Path = $path; ClientMode = 'ReadExecute'; ClientInherits = $true })
    }
    $aclTargets.Add([pscustomobject]@{ Path = Join-Path $BrokerRoot 'State\NetworkLeases'; ClientMode = 'None'; ClientInherits = $false })
    foreach ($name in $installedFiles) {
        $aclTargets.Add([pscustomobject]@{ Path = Join-Path $BrokerRoot $name; ClientMode = 'Read'; ClientInherits = $false })
    }
    foreach ($privateFile in @(Get-ChildItem -LiteralPath $privateRoot -File -Force -ErrorAction Stop)) {
        $aclTargets.Add([pscustomobject]@{ Path = $privateFile.FullName; ClientMode = 'None'; ClientInherits = $false })
    }
    $aclResults = @($aclTargets | ForEach-Object { Test-BrokerAclProfile -Path $_.Path -ClientMode $_.ClientMode -ResolvedClientSid $resolvedClientSid -ClientInherits:([bool]$_.ClientInherits) })

    $checks = [ordered]@{
        SourceVmIdMatches = [string]$sourceVm.Id -eq [string]$definition.SourceVmId
        SourceCheckpointIdMatches = [string]$sourceCheckpoint.Id -eq [string]$definition.SourceCheckpointId
        SourceVmHardwareMatchesConfigured =
            [int]$sourceProcessor.Count -eq [int]$layout.VmProcessorCount -and
            [long]$sourceMemory.Startup -eq [long]$layout.VmMemoryBytes -and
            -not [bool]$sourceMemory.DynamicMemoryEnabled -and
            [int]$sourceVideo.HorizontalResolution -eq [int]$layout.GuestDisplayWidth -and
            [int]$sourceVideo.VerticalResolution -eq [int]$layout.GuestDisplayHeight -and
            [string]$sourceVideo.ResolutionType -eq 'Single'
        BaseExists = $baseFile.Exists
        BaseIsReadOnly = $baseFile.IsReadOnly
        BaseIsStandalone = [string]::IsNullOrWhiteSpace([string]$baseVhd.ParentPath)
        PoolSizeMatchesConfigured =
            [int]$definition.PoolSize -eq [int]$layout.PoolSize -and
            $workers.Count -eq [int]$layout.PoolSize -and
            [int]$definition.PoolSize -ge 1 -and [int]$definition.PoolSize -le 4
        AllWorkersOff = @($workers | Where-Object State -ne 'Off').Count -eq 0
        AllWorkersGenerationTwo = @($workers | Where-Object Generation -ne 2).Count -eq 0
        AllWorkersSizedAsConfigured = @($workers | Where-Object {
            $_.ProcessorCount -ne [int]$definition.VmProcessorCount -or
            $_.StartupMemoryBytes -ne [long]$definition.VmMemoryBytes -or
            $_.DynamicMemoryEnabled
        }).Count -eq 0
        AllWorkerDisplaysMatchConfiguredResolution = @($workers | Where-Object {
            $_.DisplayWidth -ne [int]$definition.GuestDisplayWidth -or
            $_.DisplayHeight -ne [int]$definition.GuestDisplayHeight -or
            $_.DisplayResolutionType -ne 'Single'
        }).Count -eq 0
        AllWorkerNetworksDisconnected = @($workers | ForEach-Object { $_.NetworkAdapters } | Where-Object Connected).Count -eq 0
        SourceNetworkDisconnected = @($sourceNetworkAdapters | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) }).Count -eq 0
        NoRequestNetworkLeases = $requestNetworkLeaseFiles.Count -eq 0
        NoManagedRequestNetworkAdapters = $managedRequestNetworkAdapters.Count -eq 0
        NoManagedRequestNetworkSwitches = $managedRequestNetworkSwitches.Count -eq 0
        AllOsChildrenUseSharedBase = @($workers | Where-Object { -not $_.OsChildExists -or -not $_.OsParentMatchesBase }).Count -eq 0
        NoAttachedPayloadChildren = @($workers | ForEach-Object { $_.AttachedPayloadChildren }).Count -eq 0
        NoPayloadChildFiles = $payloadChildFiles.Count -eq 0
        NoPayloadLeaseFiles = $payloadLeaseFiles.Count -eq 0
        QueueEmpty = $queuedFiles.Count -eq 0 -and $processingFiles.Count -eq 0
        GarbageCollectionCompleted = $gcState -and [string]$gcState.Status -eq 'Completed'
        BrokerTaskRunning = $brokerTask -and [string]$brokerTask.State -eq 'Running'
        BrokerHeartbeatPresent = $brokerState -and -not [string]::IsNullOrWhiteSpace([string]$brokerState.HeartbeatUtc)
        IdleTimeoutMatchesExpected = [int]$brokerConfig.PoolIdleTimeoutSeconds -eq $ExpectedIdleTimeoutSeconds
        RequestNetworkPolicyVersioned = $requestNetworkPolicyVersioned
        IsolatedTestNetPolicyValid = $isolatedPolicyValid
        InternetOnlyPolicyPinned = $internetPolicyValid
        TrustedLanPolicyPinned = $trustedLanPolicyValid
        BrokerAclsMatchPolicy = @($aclResults | Where-Object { -not $_.Passed }).Count -eq 0
    }
    $failedChecks = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object Key)

    $result = [ordered]@{
        Success = $failedChecks.Count -eq 0
        AuditedUtc = [DateTime]::UtcNow.ToString('o')
        DefinitionPath = $DefinitionPath
        BrokerRoot = $BrokerRoot
        Source = [ordered]@{
            VmName = $sourceVm.Name
            VmId = [string]$sourceVm.Id
            State = [string]$sourceVm.State
            CheckpointName = $sourceCheckpoint.Name
            CheckpointId = [string]$sourceCheckpoint.Id
            ProcessorCount = [int]$sourceProcessor.Count
            StartupMemoryBytes = [long]$sourceMemory.Startup
            DynamicMemoryEnabled = [bool]$sourceMemory.DynamicMemoryEnabled
            DisplayWidth = [int]$sourceVideo.HorizontalResolution
            DisplayHeight = [int]$sourceVideo.VerticalResolution
            DisplayResolutionType = [string]$sourceVideo.ResolutionType
            NetworkAdapters = @($sourceNetworkAdapters | ForEach-Object { [ordered]@{ Name = [string]$_.Name; SwitchName = [string]$_.SwitchName; Connected = -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) } })
        }
        Base = [ordered]@{
            Path = $basePath
            IsReadOnly = $baseFile.IsReadOnly
            VhdType = [string]$baseVhd.VhdType
            ParentPath = [string]$baseVhd.ParentPath
            FileSizeBytes = [long]$baseFile.Length
        }
        Workers = $workers.ToArray()
        Runtime = [ordered]@{
            QueueCount = $queuedFiles.Count
            ProcessingCount = $processingFiles.Count
            PayloadChildFileCount = $payloadChildFiles.Count
            PayloadLeaseFileCount = $payloadLeaseFiles.Count
            RequestNetworkLeaseFileCount = $requestNetworkLeaseFiles.Count
            ManagedRequestNetworkAdapterCount = $managedRequestNetworkAdapters.Count
            ManagedRequestNetworkSwitchCount = $managedRequestNetworkSwitches.Count
            CacheEntryCount = $cacheEntries.Count
            GarbageCollection = $gcState
            BrokerTaskState = if ($brokerTask) { [string]$brokerTask.State } else { 'Missing' }
            BrokerStatus = if ($brokerState) { [string]$brokerState.Status } else { 'Missing' }
            BrokerHeartbeatUtc = if ($brokerState) { [string]$brokerState.HeartbeatUtc } else { $null }
            PoolIdleTimeoutSeconds = [int]$brokerConfig.PoolIdleTimeoutSeconds
            ClientSid = $resolvedClientSid
            RequestNetworkPolicy = $requestNetworkPolicy
            AclChecks = $aclResults
        }
        Checks = $checks
        FailedChecks = $failedChecks
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    if (-not $result.Success) {
        throw "Pool audit failed: $($failedChecks -join ', ')."
    }
}
catch {
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        [ordered]@{
            Success = $false
            AuditedUtc = [DateTime]::UtcNow.ToString('o')
            Error = $_.Exception.Message
            ScriptStackTrace = $_.ScriptStackTrace
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    }
    throw
}
