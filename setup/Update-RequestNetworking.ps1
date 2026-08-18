[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [string] $PolicyPath,
    [ValidateSet('None', 'InternetOnly', 'IsolatedTestNet', 'TrustedLan')] [string[]] $DesiredProfiles = @('None', 'InternetOnly', 'IsolatedTestNet', 'TrustedLan'),
    [string] $InternetSwitchName = 'Codex Test NAT',
    [string] $InternetNatName = 'Codex Test NAT',
    [string] $InternetNatPrefix = '172.30.250.0/24',
    [string] $InternetGatewayAddress = '172.30.250.1',
    [ValidateRange(1, 4094)] [int] $InternetPrimaryVlanId = 2500,
    [ValidateRange(1, 4094)] [int] $InternetSecondaryVlanId = 2501,
    [string[]] $InternetDnsServers = @('1.1.1.1', '1.0.0.1'),
    [string] $TrustedLanSwitchName = 'Codex Trusted LAN',
    [string] $TrustedLanPhysicalAdapterName = 'Wi-Fi',
    [string] $TargetUserProfile,
    [string] $TargetUserSid,
    [switch] $PlanOnly,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $ApprovedPlanFingerprint,
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallRoot) -or [IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) {
    throw 'InstallRoot must be a specific non-root directory.'
}
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\')
$checkoutHarnessRoot = Join-Path $repositoryRoot 'src\Software\Harness'
$checkoutSkillRoot = Join-Path $repositoryRoot 'src\Software\Skill'
$installedSoftwareRoot = Join-Path $InstallRoot 'Software'
$installedConfigPath = Join-Path $installedSoftwareRoot 'harness-config.json'
$installedSetupRoot = Join-Path $installedSoftwareRoot 'Setup'

if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = $env:USERPROFILE }
$TargetUserProfile = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($TargetUserSid)) { $TargetUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
if ($InternetPrimaryVlanId -eq $InternetSecondaryVlanId) { throw 'InternetOnly requires distinct primary and secondary VLAN IDs.' }
if ($DesiredProfiles -notcontains 'None') { throw 'None must remain available as the default request profile.' }
if (@($DesiredProfiles | Select-Object -Unique).Count -ne @($DesiredProfiles).Count) { throw 'DesiredProfiles contains a duplicate value.' }

function Test-RequestNetworkingAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RequestNetworkingSha256Text {
    param([Parameter(Mandatory = $true)] [string] $Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RequestNetworkingFileHash {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Write-RequestNetworkingJsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true) }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RequestNetworkingMirror {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy.exe $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Rollback mirror failed with robocopy exit code $LASTEXITCODE from '$Source' to '$Destination'." }
}

function Assert-RequestNetworkingPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ([string]::Equals($full, $rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not (($full + '\').StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Context must remain below $rootFull."
    }
    $full
}

function Read-RequestNetworkingPolicy {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Request-network policy file is missing: $full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Request-network policy input cannot be a reparse point.' }
    if (($full + '\').StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The host-specific request-network policy must remain outside the public repository.'
    }
    $policy = Get-Content -Raw -LiteralPath $full -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $null = Assert-RequestNetworkPolicySchema -Policy $policy
    $policy
}

function Get-RequestNetworkingSourceIdentity {
    $relativePaths = @(
        'HostBroker.ps1',
        'PoolBroker.ps1',
        'PoolLifecycle.ps1',
        'Install-PoolHostBroker.ps1',
        'Audit-HyperVTestPool.ps1',
        'RequestNetwork.ps1'
    )
    $hashes = [ordered]@{}
    foreach ($relativePath in $relativePaths) {
        $hashes[$relativePath] = Get-RequestNetworkingFileHash -Path (Join-Path $checkoutHarnessRoot $relativePath)
    }
    $hashes['Skill\SKILL.md'] = Get-RequestNetworkingFileHash -Path (Join-Path $checkoutSkillRoot 'SKILL.md')
    $hashes['Skill\scripts\Invoke-HyperVExecutableTest.ps1'] = Get-RequestNetworkingFileHash -Path (Join-Path $checkoutSkillRoot 'scripts\Invoke-HyperVExecutableTest.ps1')
    $hashes['Setup\Update-RequestNetworking.ps1'] = Get-RequestNetworkingFileHash -Path $PSCommandPath
    $hashes['Setup\Prepare-RequestNetworkInfrastructure.ps1'] = Get-RequestNetworkingFileHash -Path (Join-Path $PSScriptRoot 'Prepare-RequestNetworkInfrastructure.ps1')
    $hashes
}

function Get-RequestNetworkingQueueState {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    [pscustomobject][ordered]@{
        Queued = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        Processing = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        NetworkLeases = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'State\NetworkLeases') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
    }
}

function Get-RequestNetworkingInfrastructureInspection {
    param($Policy)

    $errors = New-Object Collections.Generic.List[string]
    $natInventory = @()
    $staticMappings = @()
    $switchInventory = @()
    $physicalAdapter = $null
    $routes = @()
    try {
        $natInventory = @(Get-NetNat -ErrorAction Stop | Sort-Object Name | ForEach-Object {
            [ordered]@{
                Name = [string]$_.Name
                Active = [bool]$_.Active
                InternalIPInterfaceAddressPrefix = [string]$_.InternalIPInterfaceAddressPrefix
                ExternalIPInterfaceAddressPrefix = [string]$_.ExternalIPInterfaceAddressPrefix
                InternalRoutingDomainId = [string]$_.InternalRoutingDomainId
                TcpFilteringBehavior = [string]$_.TcpFilteringBehavior
                UdpFilteringBehavior = [string]$_.UdpFilteringBehavior
                UdpInboundRefresh = [bool]$_.UdpInboundRefresh
                TcpEstablishedConnectionTimeout = [uint32]$_.TcpEstablishedConnectionTimeout
                TcpTransientConnectionTimeout = [uint32]$_.TcpTransientConnectionTimeout
                UdpIdleSessionTimeout = [uint32]$_.UdpIdleSessionTimeout
                IcmpQueryTimeout = [uint32]$_.IcmpQueryTimeout
            }
        })
        if (-not [string]::IsNullOrWhiteSpace($InternetNatName)) {
            $staticMappings = @(Get-RequestNetworkNatStaticMappings -NatName $InternetNatName | ForEach-Object {
                [ordered]@{ NatName = [string]$_.NatName; Protocol = [string]$_.Protocol; ExternalIPAddress = [string]$_.ExternalIPAddress; ExternalPort = [int]$_.ExternalPort }
            })
        }
    }
    catch { $errors.Add('WinNAT inventory: ' + $_.Exception.Message) }
    try {
        $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object { [string]$_.DestinationPrefix -in @('0.0.0.0/0', '::/0') } | Sort-Object DestinationPrefix,InterfaceIndex,NextHop | ForEach-Object {
            $route = $_
            $addressFamily = if ([string]$route.DestinationPrefix -eq '0.0.0.0/0') { 'IPv4' } else { 'IPv6' }
            $ipInterface = @(Get-NetIPInterface -InterfaceIndex ([int]$route.InterfaceIndex) -AddressFamily $addressFamily -ErrorAction Stop)
            $adapter = @(Get-NetAdapter -InterfaceIndex ([int]$route.InterfaceIndex) -IncludeHidden -ErrorAction Stop)
            if ($ipInterface.Count -ne 1 -or $adapter.Count -ne 1) { throw "Default route interface $($route.InterfaceIndex) did not resolve uniquely." }
            [ordered]@{
                AddressFamily = $addressFamily
                DestinationPrefix = [string]$route.DestinationPrefix
                InterfaceGuid = [string]$adapter[0].InterfaceGuid
                InterfaceDescription = [string]$adapter[0].InterfaceDescription
                InterfaceIndex = [int]$route.InterfaceIndex
                NextHop = [string]$route.NextHop
                RouteMetric = [int]$route.RouteMetric
                InterfaceMetric = [int]$ipInterface[0].InterfaceMetric
            }
        })
    }
    catch { $errors.Add('Default-route inventory: ' + $_.Exception.Message) }
    try {
        $physicalMatches = @(Get-NetAdapter -Name $TrustedLanPhysicalAdapterName -IncludeHidden -ErrorAction Stop)
        if ($physicalMatches.Count -ne 1) { throw "Physical adapter '$TrustedLanPhysicalAdapterName' did not resolve uniquely." }
        $physicalAdapter = [ordered]@{
            Name = [string]$physicalMatches[0].Name
            InterfaceGuid = [string]$physicalMatches[0].InterfaceGuid
            InterfaceDescription = [string]$physicalMatches[0].InterfaceDescription
            Status = [string]$physicalMatches[0].Status
        }
    }
    catch { $errors.Add('TrustedLan physical adapter inventory: ' + $_.Exception.Message) }
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $switchInventory = @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name | ForEach-Object {
            $descriptions = @($_.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ })
            [ordered]@{
                Name = [string]$_.Name
                Id = [string]$_.Id
                SwitchType = [string]$_.SwitchType
                AllowManagementOS = if ($_.PSObject.Properties['AllowManagementOS']) { [bool]$_.AllowManagementOS } else { $null }
                NetAdapterInterfaceGuid = [string]$_.NetAdapterInterfaceGuid
                NetAdapterInterfaceDescriptions = $descriptions
                EmbeddedTeamingEnabled = [bool]$_.EmbeddedTeamingEnabled
            }
        })
    }
    catch { $errors.Add('Hyper-V switch inventory: ' + $_.Exception.Message) }

    $policyVerified = $false
    if ($Policy) {
        try {
            if ([bool]$Policy.InternetOnly.Enabled) {
                $internetSwitch = Assert-RequestNetworkPinnedSwitch -Name ([string]$Policy.InternetOnly.SwitchName) -Id ([string]$Policy.InternetOnly.SwitchId) -Type Internal
                if (-not $internetSwitch.PSObject.Properties['AllowManagementOS'] -or -not [bool]$internetSwitch.AllowManagementOS) {
                    throw 'InternetOnly internal switch does not allow the management OS.'
                }
                $allNats = @(Get-NetNat -ErrorAction Stop)
                $matchingNat = @($allNats | Where-Object { [string]::Equals([string]$_.Name, [string]$Policy.InternetOnly.NatName, [StringComparison]::Ordinal) })
                if ($allNats.Count -ne 1 -or $matchingNat.Count -ne 1) { throw 'InternetOnly policy does not resolve to the host sole WinNAT instance.' }
                $expectedNatPolicy = Get-RequestNetworkExpectedNatPolicy -Settings $Policy.InternetOnly
                $null = Assert-RequestNetworkNatPolicy -Nat $matchingNat[0] -ExpectedPolicy $expectedNatPolicy -ExpectedInternalPrefix ([string]$Policy.InternetOnly.NatPrefix)
                if (@(Get-RequestNetworkNatStaticMappings -NatName ([string]$Policy.InternetOnly.NatName)).Count -ne 0) { throw 'InternetOnly NAT has a static inbound mapping.' }
                $managementAdapters = @(Get-VMNetworkAdapter -ManagementOS -SwitchName ([string]$Policy.InternetOnly.SwitchName) -ErrorAction Stop)
                if ($managementAdapters.Count -ne 1) { throw 'InternetOnly switch does not have exactly one management-OS adapter.' }
                $null = Assert-RequestNetworkInternetVlan -Adapter $managementAdapters[0] -PrimaryVlanId ([int]$Policy.InternetOnly.PrimaryVlanId) -SecondaryVlanId ([int]$Policy.InternetOnly.SecondaryVlanId) -PrivateVlanMode Promiscuous -ManagementOS
                if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.IPAddress, [string]$Policy.InternetOnly.GatewayAddress, [StringComparison]::Ordinal) }).Count -lt 1) {
                    throw 'InternetOnly gateway address is not assigned on the host.'
                }
            }
            if ([bool]$Policy.TrustedLan.Enabled) {
                $trusted = @($Policy.TrustedLan.AllowedSwitches)
                if ($trusted.Count -ne 1) { throw 'TrustedLan policy does not have exactly one pinned switch.' }
                $null = Assert-RequestNetworkPinnedSwitch -Name ([string]$trusted[0].Name) -Id ([string]$trusted[0].Id) -Type External `
                    -ExpectedNetAdapterInterfaceGuid ([string]$trusted[0].NetAdapterInterfaceGuid) `
                    -ExpectedNetAdapterInterfaceDescription ([string]$trusted[0].NetAdapterInterfaceDescription) `
                    -ExpectedAllowManagementOS ([bool]$trusted[0].AllowManagementOS)
            }
            $policyVerified = $true
        }
        catch { $errors.Add('Proposed policy infrastructure: ' + $_.Exception.Message) }
    }

    [pscustomobject][ordered]@{
        Administrator = Test-RequestNetworkingAdministrator
        Nat = $natInventory
        StaticMappingsForProposedNat = $staticMappings
        Switches = $switchInventory
        TrustedLanPhysicalAdapter = $physicalAdapter
        DefaultRoutes = $routes
        ProposedPolicyVerified = $policyVerified
        Errors = $errors.ToArray()
    }
}

function Get-RequestNetworkingPlan {
    param($Layout, $Policy)

    $sourceIdentity = Get-RequestNetworkingSourceIdentity
    $queueState = Get-RequestNetworkingQueueState -BrokerRoot ([string]$Layout.BrokerRoot)
    $infrastructure = Get-RequestNetworkingInfrastructureInspection -Policy $Policy
    $currentConfigHash = Get-RequestNetworkingFileHash -Path $installedConfigPath
    $policyJson = if ($Policy) { $Policy | ConvertTo-Json -Depth 30 -Compress } else { $null }
    $policyHash = if ($policyJson) { Get-RequestNetworkingSha256Text -Text $policyJson } else { $null }
    $approvalReady = $null -ne $Policy -and [bool]$infrastructure.ProposedPolicyVerified -and $queueState.Queued -eq 0 -and $queueState.Processing -eq 0 -and $queueState.NetworkLeases -eq 0
    $fingerprintIdentity = [ordered]@{
        FormatVersion = 1
        InstallRoot = $InstallRoot
        CurrentConfigSha256 = $currentConfigHash
        PolicySha256 = $policyHash
        SourceSha256 = $sourceIdentity
        Infrastructure = [ordered]@{
            Nat = @($infrastructure.Nat)
            StaticMappingsForProposedNat = @($infrastructure.StaticMappingsForProposedNat)
            Switches = @($infrastructure.Switches)
            TrustedLanPhysicalAdapter = $infrastructure.TrustedLanPhysicalAdapter
            DefaultRoutes = @($infrastructure.DefaultRoutes)
        }
        Queue = $queueState
        TargetUserSid = $TargetUserSid
    }
    $planFingerprint = if ($approvalReady) { Get-RequestNetworkingSha256Text -Text ($fingerprintIdentity | ConvertTo-Json -Depth 30 -Compress) } else { $null }
    [pscustomobject][ordered]@{
        PlanOnly = [bool]$PlanOnly
        NoMutationPerformed = [bool]$PlanOnly
        ApprovalReady = $approvalReady
        PlanFingerprint = $planFingerprint
        InstallRoot = $InstallRoot
        RepositoryRoot = $repositoryRoot
        CurrentConfigurationSha256 = $currentConfigHash
        CurrentRequestNetworkPolicy = if ($Layout.PSObject.Properties['RequestNetworkPolicy']) { $Layout.RequestNetworkPolicy } else { $null }
        DesiredProfileAvailability = @($DesiredProfiles)
        RequestedIntent = [ordered]@{
            DefaultProfile = 'None'
            InternetOnly = [ordered]@{
                SwitchName = $InternetSwitchName
                NatName = $InternetNatName
                NatPrefix = $InternetNatPrefix
                GatewayAddress = $InternetGatewayAddress
                PrimaryVlanId = $InternetPrimaryVlanId
                SecondaryVlanId = $InternetSecondaryVlanId
                DnsServers = @($InternetDnsServers)
            }
            IsolatedTestNet = [ordered]@{ NetworkPrefix = '10.254.0.0/24'; SwitchPrefix = 'Codex-Harness-TestNet'; CohortRequired = $true }
            TrustedLan = [ordered]@{ SwitchName = $TrustedLanSwitchName; PhysicalAdapterName = $TrustedLanPhysicalAdapterName; FullLanExposure = $true }
        }
        ProposedPolicySupplied = $null -ne $Policy
        ProposedPolicySha256 = $policyHash
        ProposedPolicy = $Policy
        SourceSha256 = $sourceIdentity
        Queue = $queueState
        Infrastructure = $infrastructure
        PersistentHostChangesOnApply = @(
            'Overlay the reviewed request-network broker source into the installed Software tree.',
            'Replace only RequestNetworkPolicy in the installed v1 harness configuration.',
            'Transactionally reinstall and restart the ACL-restricted SYSTEM broker.',
            'Refresh the target user runtime skill after broker verification.'
        )
        InfrastructureProvisioningIncluded = $false
        DeferredLiveWork = @(
            'Create or reconfigure any missing pinned internal/external switch, WinNAT, gateway address, or private-VLAN state under a separately approved exact infrastructure plan.',
            'Run positive and negative canaries for all four profiles, mixed concurrency, cancellation, timeout, and broker/worker interruption.',
            'Run the privileged idle-pool audit, refresh local recovery once, and deep-hash verify it.'
        )
        FingerprintIdentity = $fingerprintIdentity
    }
}

function Start-RequestNetworkingElevatedSelf {
    $arguments = @(
        '-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-InstallRoot', ('"' + $InstallRoot + '"'), '-PolicyPath', ('"' + ([IO.Path]::GetFullPath($PolicyPath)) + '"'),
        '-ApprovedPlanFingerprint', $ApprovedPlanFingerprint, '-TargetUserProfile', ('"' + $TargetUserProfile + '"'),
        '-TargetUserSid', $TargetUserSid, '-InternetSwitchName', ('"' + $InternetSwitchName + '"'),
        '-InternetNatName', ('"' + $InternetNatName + '"'), '-InternetNatPrefix', $InternetNatPrefix,
        '-InternetGatewayAddress', $InternetGatewayAddress, '-InternetPrimaryVlanId', $InternetPrimaryVlanId,
        '-InternetSecondaryVlanId', $InternetSecondaryVlanId, '-TrustedLanSwitchName', ('"' + $TrustedLanSwitchName + '"'),
        '-TrustedLanPhysicalAdapterName', ('"' + $TrustedLanPhysicalAdapterName + '"'), '-NoElevation'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Elevated request-network update exited with code $($process.ExitCode)." }
}

if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) { throw "Installed harness configuration is missing: $installedConfigPath" }
. (Join-Path $checkoutHarnessRoot 'HarnessPaths.ps1')
. (Join-Path $checkoutHarnessRoot 'RequestNetwork.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $installedConfigPath
$policy = Read-RequestNetworkingPolicy -Path $PolicyPath
$plan = Get-RequestNetworkingPlan -Layout $layout -Policy $policy

if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 30
    return
}

if (-not $policy) { throw 'A fully populated local -PolicyPath is required for mutation.' }
if ([string]::IsNullOrWhiteSpace($ApprovedPlanFingerprint)) { throw 'Pass the exact fingerprint from an elevated, approval-ready -PlanOnly result.' }
if (-not [bool]$plan.ApprovalReady -or [string]::IsNullOrWhiteSpace([string]$plan.PlanFingerprint)) {
    throw 'The current policy/infrastructure plan is not approval-ready; no mutation was performed.'
}
if (-not [string]::Equals([string]$plan.PlanFingerprint, $ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The approved request-network plan fingerprint no longer matches current source, configuration, queue, routes, or host infrastructure.'
}
if (-not (Test-RequestNetworkingAdministrator)) {
    if ($NoElevation) { throw 'Request-network policy deployment requires administrator rights.' }
    Start-RequestNetworkingElevatedSelf
    return
}

$installedHarnessRoot = Assert-RequestNetworkingPathWithinRoot -Path ([string]$layout.HarnessSourceRoot) -Root $InstallRoot -Context 'HarnessSourceRoot'
$installedSkillSourceRoot = Assert-RequestNetworkingPathWithinRoot -Path ([string]$layout.SkillSourceRoot) -Root $InstallRoot -Context 'SkillSourceRoot'
$poolDefinitionPath = Join-Path $installedHarnessRoot 'pool-definition.json'
if (-not (Test-Path -LiteralPath $poolDefinitionPath -PathType Leaf)) { throw "Installed pool definition is missing: $poolDefinitionPath" }
$skillDestination = Join-Path $TargetUserProfile '.agents\skills\hyperv-test-executables'
$backupRoot = Join-Path ([string]$layout.LiveRoot) ('Setup\RequestNetworkUpdateBackup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$backupRoot = Assert-RequestNetworkingPathWithinRoot -Path $backupRoot -Root $InstallRoot -Context 'Request-network rollback root'
$installedSourceMutated = $false
$skillExisted = Test-Path -LiteralPath $skillDestination -PathType Container

try {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $installedConfigPath -Destination (Join-Path $backupRoot 'harness-config.json') -Force
    Copy-Item -LiteralPath $installedHarnessRoot -Destination (Join-Path $backupRoot 'Harness') -Recurse -Force
    Copy-Item -LiteralPath $installedSkillSourceRoot -Destination (Join-Path $backupRoot 'SkillSource') -Recurse -Force
    if ($skillExisted) { Copy-Item -LiteralPath $skillDestination -Destination (Join-Path $backupRoot 'UserSkill') -Recurse -Force }

    # Arm rollback before the first installed-file mutation. A failed or
    # interrupted overlay can otherwise leave a mixed source tree even though
    # the configuration write was never reached.
    $installedSourceMutated = $true
    Copy-Item -Path (Join-Path $checkoutHarnessRoot '*') -Destination $installedHarnessRoot -Recurse -Force
    Copy-Item -Path (Join-Path $checkoutSkillRoot '*') -Destination $installedSkillSourceRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $installedSetupRoot | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $installedSetupRoot 'Update-RequestNetworking.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Prepare-RequestNetworkInfrastructure.ps1') -Destination (Join-Path $installedSetupRoot 'Prepare-RequestNetworkInfrastructure.ps1') -Force
    $installedConfig = Get-Content -Raw -LiteralPath $installedConfigPath | ConvertFrom-Json
    $installedConfig | Add-Member -NotePropertyName RequestNetworkPolicy -NotePropertyValue $policy -Force
    Write-RequestNetworkingJsonAtomic -Path $installedConfigPath -Value $installedConfig

    $statusPath = Join-Path ([string]$layout.BrokerRoot) 'State\Management\request-network-broker-install.json'
    & (Join-Path $installedHarnessRoot 'Install-PoolHostBroker.ps1') -SourceRoot $installedHarnessRoot -BrokerRoot ([string]$layout.BrokerRoot) -PoolDefinitionPath $poolDefinitionPath -StatusPath $statusPath -ConfigPath $installedConfigPath -ClientSid $TargetUserSid

    New-Item -ItemType Directory -Force -Path $skillDestination | Out-Null
    Copy-Item -Path (Join-Path $installedSkillSourceRoot '*') -Destination $skillDestination -Recurse -Force
    $auditStatusPath = Join-Path ([string]$layout.BrokerRoot) 'State\Management\request-network-pool-audit.json'
    & (Join-Path $installedHarnessRoot 'Audit-HyperVTestPool.ps1') -BrokerRoot ([string]$layout.BrokerRoot) -ConfigPath $installedConfigPath -StatusPath $auditStatusPath -ClientSid $TargetUserSid
    $audit = Get-Content -Raw -LiteralPath $auditStatusPath | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw 'The post-deployment privileged pool audit failed.' }

    [pscustomobject][ordered]@{
        Success = $true
        PlanFingerprint = $ApprovedPlanFingerprint.ToLowerInvariant()
        InstallRoot = $InstallRoot
        RequestNetworkPolicy = $policy
        BrokerInstallStatusPath = $statusPath
        Audit = $audit
        RollbackMaterialPath = $backupRoot
        RecoveryRefreshRequired = $true
        LiveProfileCanariesRequired = $true
    } | ConvertTo-Json -Depth 30
}
catch {
    $failure = $_.Exception.Message
    if ($installedSourceMutated) {
        try {
            Copy-Item -LiteralPath (Join-Path $backupRoot 'harness-config.json') -Destination $installedConfigPath -Force
            Invoke-RequestNetworkingMirror -Source (Join-Path $backupRoot 'Harness') -Destination $installedHarnessRoot
            Invoke-RequestNetworkingMirror -Source (Join-Path $backupRoot 'SkillSource') -Destination $installedSkillSourceRoot
            if ($skillExisted) {
                Invoke-RequestNetworkingMirror -Source (Join-Path $backupRoot 'UserSkill') -Destination $skillDestination
            }
            elseif (Test-Path -LiteralPath $skillDestination -PathType Container) {
                $validatedSkillDestination = Assert-RequestNetworkingPathWithinRoot -Path $skillDestination -Root $TargetUserProfile -Context 'Runtime skill rollback path'
                Remove-Item -LiteralPath $validatedSkillDestination -Recurse -Force
            }
            # The installer can fail after partially changing the task or
            # broker files. Always reinstall the restored source/config, even
            # when the forward installer did not return successfully.
            & (Join-Path $installedHarnessRoot 'Install-PoolHostBroker.ps1') -SourceRoot $installedHarnessRoot -BrokerRoot ([string]$layout.BrokerRoot) -PoolDefinitionPath $poolDefinitionPath -ConfigPath $installedConfigPath -ClientSid $TargetUserSid
        }
        catch { $failure += ' Rollback also failed: ' + $_.Exception.Message }
    }
    throw "Request-network update failed: $failure Rollback material remains at '$backupRoot'."
}
