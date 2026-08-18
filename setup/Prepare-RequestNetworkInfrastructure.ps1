[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [Parameter(Mandatory = $true)] [string] $InternetSwitchId,
    [Parameter(Mandatory = $true)] [string] $TrustedLanSwitchId,
    [string] $InternetSwitchName = 'Codex Test NAT',
    [string] $InternetNatName = 'Codex Test NAT',
    [string] $InternetNatPrefix = '172.30.250.0/24',
    [string] $InternetGatewayAddress = '172.30.250.1',
    [ValidateRange(1, 4094)] [int] $InternetPrimaryVlanId = 2500,
    [ValidateRange(1, 4094)] [int] $InternetSecondaryVlanId = 2501,
    [string[]] $InternetDnsServers = @('1.1.1.1', '1.0.0.1'),
    [string] $TrustedLanSwitchName = 'Codex Trusted LAN',
    [string] $TrustedLanPhysicalAdapterName = 'Wi-Fi',
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
try { $internetGuid = [Guid]::Parse($InternetSwitchId) } catch { throw "InternetSwitchId is not a GUID: $InternetSwitchId" }
try { $trustedGuid = [Guid]::Parse($TrustedLanSwitchId) } catch { throw "TrustedLanSwitchId is not a GUID: $TrustedLanSwitchId" }
if ($internetGuid -eq $trustedGuid) { throw 'InternetOnly and TrustedLan require distinct switch IDs.' }
if ($InternetPrimaryVlanId -eq $InternetSecondaryVlanId) { throw 'InternetOnly requires distinct primary and secondary VLAN IDs.' }

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$harnessRoot = Join-Path $repositoryRoot 'src\Software\Harness'
$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
foreach ($required in @($configPath, (Join-Path $harnessRoot 'HarnessPaths.ps1'), (Join-Path $harnessRoot 'RequestNetwork.ps1'), (Join-Path $PSScriptRoot 'Update-RequestNetworking.ps1'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required source or configuration file is missing: $required" }
}
. (Join-Path $harnessRoot 'HarnessPaths.ps1')
. (Join-Path $harnessRoot 'RequestNetwork.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $configPath
if (-not [string]::Equals(([IO.Path]::GetFullPath([string]$layout.InstallRoot).TrimEnd('\')), $InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installed configuration does not belong to the selected InstallRoot.'
}

function Test-InfraAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InfraFileHash {
    param([Parameter(Mandatory = $true)] [string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-InfraTextHash {
    param([Parameter(Mandatory = $true)] [string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-InfraGuid {
    param([AllowNull()] $Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
    try { ([Guid]::Parse([string]$Value)).ToString('D').ToLowerInvariant() } catch { [string]$Value }
}

function Write-InfraJsonAtomic {
    param([string] $Path, $Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temporary + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $backup, $true) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Get-InfraQueue {
    $errors = New-Object Collections.Generic.List[string]
    $value = [ordered]@{ Queued = $null; Processing = $null; NetworkLeases = $null }
    foreach ($item in @(
        @{ Name = 'Queued'; Path = Join-Path ([string]$layout.BrokerRoot) 'Requests' },
        @{ Name = 'Processing'; Path = Join-Path ([string]$layout.BrokerRoot) 'Processing' },
        @{ Name = 'NetworkLeases'; Path = Join-Path ([string]$layout.BrokerRoot) 'State\NetworkLeases' }
    )) {
        try { $value[$item.Name] = @(Get-ChildItem -LiteralPath $item.Path -Filter '*.json' -File -ErrorAction Stop).Count }
        catch { $errors.Add("$($item.Name): $($_.Exception.Message)") }
    }
    [pscustomobject][ordered]@{ Value = [pscustomobject]$value; Errors = $errors.ToArray() }
}

function Get-InfraInspection {
    $errors = New-Object Collections.Generic.List[string]
    $switchInventory = @()
    $natInventory = @()
    $physicalIdentity = $null
    $routes = @()
    $internet = [ordered]@{
        SwitchExists = $false; SwitchExact = $false; SwitchCanCreate = $false
        GatewayExact = $false; GatewayCanCreate = $false
        VlanExact = $false; VlanCanConfigure = $false
        NatExists = $false; NatExact = $false; NatCanCreate = $false
    }
    $trusted = [ordered]@{ SwitchExists = $false; SwitchExact = $false; SwitchCanCreate = $false }
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $switches = @(Get-VMSwitch -ErrorAction Stop)
        $switchInventory = @($switches | Sort-Object Name | ForEach-Object {
            [ordered]@{
                Name = [string]$_.Name; Id = ConvertTo-InfraGuid $_.Id; SwitchType = [string]$_.SwitchType
                AllowManagementOS = if ($_.PSObject.Properties['AllowManagementOS']) { [bool]$_.AllowManagementOS } else { $null }
                NetAdapterInterfaceGuid = ConvertTo-InfraGuid $_.NetAdapterInterfaceGuid
                NetAdapterInterfaceDescriptions = @($_.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ })
                EmbeddedTeamingEnabled = [bool]$_.EmbeddedTeamingEnabled; Notes = [string]$_.Notes
            }
        })
        $internetByName = @($switches | Where-Object { [string]::Equals([string]$_.Name, $InternetSwitchName, [StringComparison]::Ordinal) })
        $internetById = @($switches | Where-Object { (ConvertTo-InfraGuid $_.Id) -eq $internetGuid.ToString('D').ToLowerInvariant() })
        if ($internetByName.Count -eq 0 -and $internetById.Count -eq 0) {
            $internet.SwitchCanCreate = $true
            $internet.GatewayCanCreate = $true
            $internet.VlanCanConfigure = $true
        }
        elseif ($internetByName.Count -eq 1 -and $internetById.Count -eq 1 -and $internetByName[0].Id -eq $internetById[0].Id) {
            $internet.SwitchExists = $true
            $candidate = $internetByName[0]
            $internet.SwitchExact = [string]$candidate.SwitchType -eq 'Internal' -and [bool]$candidate.AllowManagementOS -and -not [bool]$candidate.EmbeddedTeamingEnabled
            if (-not $internet.SwitchExact) { $errors.Add('Existing InternetOnly switch identity is not exact.') }
            $foreign = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object {
                [string]::Equals([string]$_.SwitchName, $InternetSwitchName, [StringComparison]::Ordinal) -and [string]$_.Name -notlike 'CodexRequestNet-*'
            })
            if ($foreign.Count -gt 0) { $errors.Add('InternetOnly switch has a non-request VM adapter.') }
            $management = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $InternetSwitchName -ErrorAction Stop)
            if ($management.Count -ne 1) { $errors.Add('InternetOnly switch does not have exactly one management adapter.') }
            else {
                $hostAdapter = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
                    (([string]$_.MacAddress) -replace '[:-]', '') -eq (([string]$management[0].MacAddress) -replace '[:-]', '')
                })
                if ($hostAdapter.Count -ne 1) { $errors.Add('InternetOnly management adapter does not map uniquely to the host.') }
                else {
                    $addresses = @(Get-NetIPAddress -InterfaceIndex ([int]$hostAdapter[0].ifIndex) -AddressFamily IPv4 -ErrorAction Stop)
                    $exact = @($addresses | Where-Object { [string]$_.IPAddress -eq $InternetGatewayAddress -and [int]$_.PrefixLength -eq 24 })
                    $unexpected = @($addresses | Where-Object { [string]$_.IPAddress -notlike '169.254.*' -and [string]$_.IPAddress -ne $InternetGatewayAddress })
                    $internet.GatewayExact = $exact.Count -eq 1 -and $unexpected.Count -eq 0
                    $internet.GatewayCanCreate = $false
                    if (-not $internet.GatewayExact) { $errors.Add('An existing InternetOnly switch must already have the exact gateway address.') }
                }
                try {
                    $null = Assert-RequestNetworkInternetVlan -Adapter $management[0] -PrimaryVlanId $InternetPrimaryVlanId -SecondaryVlanId $InternetSecondaryVlanId -PrivateVlanMode Promiscuous -ManagementOS
                    $internet.VlanExact = $true
                }
                catch {
                    $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $management[0] -ErrorAction Stop
                    $internet.VlanCanConfigure = [string]$vlan.OperationMode -eq 'Untagged'
                    if (-not $internet.VlanCanConfigure) { $errors.Add('InternetOnly gateway VLAN is neither exact nor untagged.') }
                }
            }
        }
        else { $errors.Add('InternetOnly switch name or ID collides with another switch.') }

        $physical = @(Get-NetAdapter -Name $TrustedLanPhysicalAdapterName -IncludeHidden -ErrorAction Stop)
        if ($physical.Count -ne 1) { $errors.Add('TrustedLan physical adapter did not resolve uniquely.') }
        else {
            $physicalIdentity = [ordered]@{
                Name = [string]$physical[0].Name; InterfaceGuid = ConvertTo-InfraGuid $physical[0].InterfaceGuid
                InterfaceDescription = [string]$physical[0].InterfaceDescription; Status = [string]$physical[0].Status
            }
            if ([string]$physicalIdentity.Status -ne 'Up') { $errors.Add('TrustedLan physical adapter is not up.') }
            $bound = @($switches | Where-Object {
                [string]$_.SwitchType -eq 'External' -and (ConvertTo-InfraGuid $_.NetAdapterInterfaceGuid) -eq [string]$physicalIdentity.InterfaceGuid
            })
            $trustedByName = @($switches | Where-Object { [string]::Equals([string]$_.Name, $TrustedLanSwitchName, [StringComparison]::Ordinal) })
            $trustedById = @($switches | Where-Object { (ConvertTo-InfraGuid $_.Id) -eq $trustedGuid.ToString('D').ToLowerInvariant() })
            if ($trustedByName.Count -eq 0 -and $trustedById.Count -eq 0) {
                $trusted.SwitchCanCreate = $bound.Count -eq 0
                if (-not $trusted.SwitchCanCreate) { $errors.Add('TrustedLan physical adapter is already bound to another external switch.') }
            }
            elseif ($trustedByName.Count -eq 1 -and $trustedById.Count -eq 1 -and $trustedByName[0].Id -eq $trustedById[0].Id) {
                $trusted.SwitchExists = $true
                $candidate = $trustedByName[0]
                $descriptions = @($candidate.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ })
                $trusted.SwitchExact = [string]$candidate.SwitchType -eq 'External' -and
                    (ConvertTo-InfraGuid $candidate.NetAdapterInterfaceGuid) -eq [string]$physicalIdentity.InterfaceGuid -and
                    $descriptions.Count -eq 1 -and [string]$descriptions[0] -eq [string]$physicalIdentity.InterfaceDescription -and
                    [bool]$candidate.AllowManagementOS -and -not [bool]$candidate.EmbeddedTeamingEnabled
                if (-not $trusted.SwitchExact) { $errors.Add('Existing TrustedLan switch identity is not exact.') }
            }
            else { $errors.Add('TrustedLan switch name or ID collides with another switch.') }
        }
    }
    catch { $errors.Add('Hyper-V inventory: ' + $_.Exception.Message) }

    try {
        $nats = @(Get-NetNat -ErrorAction Stop)
        $natInventory = @($nats | Sort-Object Name | ForEach-Object {
            [ordered]@{
                Name = [string]$_.Name; Active = [bool]$_.Active
                InternalIPInterfaceAddressPrefix = [string]$_.InternalIPInterfaceAddressPrefix
                ExternalIPInterfaceAddressPrefix = [string]$_.ExternalIPInterfaceAddressPrefix
                InternalRoutingDomainId = [string]$_.InternalRoutingDomainId
                TcpFilteringBehavior = [string]$_.TcpFilteringBehavior; UdpFilteringBehavior = [string]$_.UdpFilteringBehavior
                UdpInboundRefresh = [bool]$_.UdpInboundRefresh; TcpEstablishedConnectionTimeout = [uint32]$_.TcpEstablishedConnectionTimeout
                TcpTransientConnectionTimeout = [uint32]$_.TcpTransientConnectionTimeout; UdpIdleSessionTimeout = [uint32]$_.UdpIdleSessionTimeout
                IcmpQueryTimeout = [uint32]$_.IcmpQueryTimeout
            }
        })
        $matching = @($nats | Where-Object { [string]$_.Name -eq $InternetNatName })
        if ($matching.Count -eq 0 -and $nats.Count -eq 0) { $internet.NatCanCreate = $true }
        elseif ($matching.Count -eq 1 -and $nats.Count -eq 1) {
            $internet.NatExists = $true
            $expected = [pscustomobject][ordered]@{
                ExternalIPInterfaceAddressPrefix = ''; InternalRoutingDomainId = '{00000000-0000-0000-0000-000000000000}'
                TcpFilteringBehavior = 'AddressDependentFiltering'; UdpFilteringBehavior = 'AddressDependentFiltering'; UdpInboundRefresh = $false
                TcpEstablishedConnectionTimeout = 1800; TcpTransientConnectionTimeout = 120; UdpIdleSessionTimeout = 120; IcmpQueryTimeout = 30
            }
            try {
                $null = Assert-RequestNetworkNatPolicy -Nat $matching[0] -ExpectedPolicy $expected -ExpectedInternalPrefix $InternetNatPrefix
                $internet.NatExact = [bool]$matching[0].Active -and @(Get-RequestNetworkNatStaticMappings -NatName $InternetNatName).Count -eq 0
            }
            catch { $errors.Add('Existing InternetOnly NAT policy is not exact.') }
            if (-not $internet.NatExact) { $errors.Add('InternetOnly NAT is inactive or has a static mapping.') }
        }
        else { $errors.Add('InternetOnly requires the approved NAT to be the sole WinNAT instance.') }
    }
    catch { $errors.Add('WinNAT inventory: ' + $_.Exception.Message) }

    try {
        $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object { [string]$_.DestinationPrefix -in @('0.0.0.0/0', '::/0') } |
            Sort-Object DestinationPrefix,InterfaceIndex,NextHop | ForEach-Object {
                [ordered]@{ DestinationPrefix = [string]$_.DestinationPrefix; InterfaceIndex = [int]$_.InterfaceIndex; NextHop = [string]$_.NextHop; RouteMetric = [int]$_.RouteMetric }
            })
    }
    catch { $errors.Add('Default-route inventory: ' + $_.Exception.Message) }
    [pscustomobject][ordered]@{
        Administrator = Test-InfraAdministrator; Switches = $switchInventory; Nat = $natInventory
        DefaultRoutes = $routes; TrustedLanPhysicalAdapter = $physicalIdentity
        InternetOnly = [pscustomobject]$internet; TrustedLan = [pscustomobject]$trusted; Errors = $errors.ToArray()
    }
}

function Get-RequestNetworkInfrastructurePlan {
    $queue = Get-InfraQueue
    $inspection = Get-InfraInspection
    $intent = [ordered]@{
        DefaultProfile = 'None'
        InternetOnly = [ordered]@{
            SwitchName = $InternetSwitchName; SwitchId = $internetGuid.ToString('D').ToLowerInvariant()
            NatName = $InternetNatName; NatPrefix = $InternetNatPrefix; GatewayAddress = $InternetGatewayAddress
            PrimaryVlanId = $InternetPrimaryVlanId; SecondaryVlanId = $InternetSecondaryVlanId; DnsServers = @($InternetDnsServers)
        }
        IsolatedTestNet = [ordered]@{ SwitchPrefix = 'Codex-Harness-TestNet'; NetworkPrefix = '10.254.0.0/24' }
        TrustedLan = [ordered]@{
            SwitchName = $TrustedLanSwitchName; SwitchId = $trustedGuid.ToString('D').ToLowerInvariant()
            PhysicalAdapterName = $TrustedLanPhysicalAdapterName; AllowManagementOS = $true; FullLanExposure = $true
        }
    }
    $source = [ordered]@{
        PreparationScript = Get-InfraFileHash $PSCommandPath
        RequestNetworkModule = Get-InfraFileHash (Join-Path $harnessRoot 'RequestNetwork.ps1')
        UpdateScript = Get-InfraFileHash (Join-Path $PSScriptRoot 'Update-RequestNetworking.ps1')
    }
    $internetReady = (([bool]$inspection.InternetOnly.SwitchExact -and
        ([bool]$inspection.InternetOnly.GatewayExact -or [bool]$inspection.InternetOnly.GatewayCanCreate) -and
        ([bool]$inspection.InternetOnly.VlanExact -or [bool]$inspection.InternetOnly.VlanCanConfigure)) -or
        [bool]$inspection.InternetOnly.SwitchCanCreate) -and
        ([bool]$inspection.InternetOnly.NatExact -or [bool]$inspection.InternetOnly.NatCanCreate)
    $trustedReady = ([bool]$inspection.TrustedLan.SwitchExists -and [bool]$inspection.TrustedLan.SwitchExact) -or [bool]$inspection.TrustedLan.SwitchCanCreate
    $ready = [bool]$inspection.Administrator -and @($inspection.Errors).Count -eq 0 -and @($queue.Errors).Count -eq 0 -and
        [int]$queue.Value.Queued -eq 0 -and [int]$queue.Value.Processing -eq 0 -and [int]$queue.Value.NetworkLeases -eq 0 -and
        $internetReady -and $trustedReady
    $identity = [ordered]@{
        FormatVersion = 1; InstallRoot = $InstallRoot; ConfigurationSha256 = Get-InfraFileHash $configPath
        SourceSha256 = $source; Intent = $intent; Queue = $queue.Value; Infrastructure = $inspection
    }
    $fingerprint = if ($ready) { Get-InfraTextHash ($identity | ConvertTo-Json -Depth 30 -Compress) } else { $null }
    [pscustomobject][ordered]@{
        PlanOnly = [bool]$PlanOnly; NoMutationPerformed = [bool]$PlanOnly; ApprovalReady = $ready; PlanFingerprint = $fingerprint
        InstallRoot = $InstallRoot; Intent = $intent; Queue = $queue.Value; QueueErrors = $queue.Errors; Infrastructure = $inspection
        PersistentHostChangesOnApply = @(
            'Create only the exact missing Codex Test NAT internal switch when absent.',
            'Assign only 172.30.250.1/24 to its management adapter when absent.',
            'Create only the exact sole outbound Codex Test NAT WinNAT when absent.',
            'Apply the approved promiscuous 2500/2501 PVLAN to the InternetOnly gateway adapter.',
            'Create only the exact Codex Trusted LAN external switch on the pinned Wi-Fi adapter when absent; this can briefly interrupt host networking.',
            'Write a private policy below the installed Live\Setup tree for the separate transactional broker-policy plan.',
            'Preserve all unrelated switches, NATs, VMs, adapters, routes, and firewall rules.'
        )
        Rollback = 'A failed preparation removes only transaction-created objects and restores a changed gateway VLAN to untagged.'
        SourceSha256 = $source; FingerprintIdentity = $identity
    }
}

function Start-InfraElevatedSelf {
    $arguments = @(
        '-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
        '-InstallRoot', ('"' + $InstallRoot + '"'), '-InternetSwitchId', $internetGuid.ToString('D'),
        '-TrustedLanSwitchId', $trustedGuid.ToString('D'), '-InternetSwitchName', ('"' + $InternetSwitchName + '"'),
        '-InternetNatName', ('"' + $InternetNatName + '"'), '-InternetNatPrefix', $InternetNatPrefix,
        '-InternetGatewayAddress', $InternetGatewayAddress, '-InternetPrimaryVlanId', $InternetPrimaryVlanId,
        '-InternetSecondaryVlanId', $InternetSecondaryVlanId, '-TrustedLanSwitchName', ('"' + $TrustedLanSwitchName + '"'),
        '-TrustedLanPhysicalAdapterName', ('"' + $TrustedLanPhysicalAdapterName + '"'),
        '-ApprovedPlanFingerprint', $ApprovedPlanFingerprint, '-NoElevation'
    )
    foreach ($dns in @($InternetDnsServers)) { $arguments += '-InternetDnsServers'; $arguments += $dns }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "Elevated infrastructure preparation exited with code $($process.ExitCode)." }
}

$plan = Get-RequestNetworkInfrastructurePlan
if ($PlanOnly) { $plan | ConvertTo-Json -Depth 30; return }
if ([string]::IsNullOrWhiteSpace($ApprovedPlanFingerprint)) { throw 'Pass the exact fingerprint from an elevated, approval-ready -PlanOnly result.' }
if (-not [bool]$plan.ApprovalReady -or -not [string]::Equals([string]$plan.PlanFingerprint, $ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The approved infrastructure fingerprint no longer matches the current host, queue, source, or configuration.'
}
if (-not (Test-InfraAdministrator)) {
    if ($NoElevation) { throw 'Request-network infrastructure preparation requires administrator rights.' }
    Start-InfraElevatedSelf
    return
}

$transactionRoot = Join-Path ([string]$layout.LiveRoot) ('Setup\RequestNetworkInfrastructure-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$transactionRoot = [IO.Path]::GetFullPath($transactionRoot)
$livePrefix = [IO.Path]::GetFullPath([string]$layout.LiveRoot).TrimEnd('\') + '\'
if (-not (($transactionRoot + '\').StartsWith($livePrefix, [StringComparison]::OrdinalIgnoreCase))) { throw 'Transaction path escapes LiveRoot.' }
$journalPath = Join-Path $transactionRoot 'journal.json'
$policyPath = Join-Path $transactionRoot 'request-network-policy.json'
$resultPath = Join-Path $transactionRoot 'result.json'
$journal = [ordered]@{
    FormatVersion = 1; TransactionId = [Guid]::NewGuid().ToString('D'); ApprovedPlanFingerprint = $ApprovedPlanFingerprint.ToLowerInvariant()
    StartedUtc = [DateTime]::UtcNow.ToString('o'); State = 'Starting'; InternetSwitchCreated = $false
    GatewayAddressCreated = $false; GatewayVlanChangedFromUntagged = $false; NatCreated = $false; TrustedLanSwitchCreated = $false
    InternetSwitchWasAbsent = -not [bool]$plan.Infrastructure.InternetOnly.SwitchExists
    NatWasAbsent = -not [bool]$plan.Infrastructure.InternetOnly.NatExists
    TrustedLanSwitchWasAbsent = -not [bool]$plan.Infrastructure.TrustedLan.SwitchExists
}
Write-InfraJsonAtomic $journalPath $journal

try {
    Import-Module Hyper-V -ErrorAction Stop
    $internetSwitch = @(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]$_.Name -eq $InternetSwitchName })
    if ($internetSwitch.Count -eq 0) {
        $createInternet = @{ Name = $InternetSwitchName; Id = $internetGuid.ToString('D'); SwitchType = 'Internal'; Notes = 'CodexHarnessRequestNetwork:InternetOnly'; EnableEmbeddedTeaming = $false; ErrorAction = 'Stop' }
        $internetSwitch = @(New-VMSwitch @createInternet)
        $journal.InternetSwitchCreated = $true
        Write-InfraJsonAtomic $journalPath $journal
    }
    if ($internetSwitch.Count -ne 1 -or (ConvertTo-InfraGuid $internetSwitch[0].Id) -ne $internetGuid.ToString('D').ToLowerInvariant()) { throw 'Prepared InternetOnly switch identity is not exact.' }
    $management = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $InternetSwitchName -ErrorAction Stop)
    if ($management.Count -ne 1) { throw 'Prepared InternetOnly switch has no unique management adapter.' }
    $hostAdapter = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        (([string]$_.MacAddress) -replace '[:-]', '') -eq (([string]$management[0].MacAddress) -replace '[:-]', '')
    })
    if ($hostAdapter.Count -ne 1) { throw 'Prepared InternetOnly management adapter did not map uniquely.' }
    $gateway = @(Get-NetIPAddress -InterfaceIndex ([int]$hostAdapter[0].ifIndex) -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        [string]$_.IPAddress -eq $InternetGatewayAddress -and [int]$_.PrefixLength -eq 24
    })
    if ($gateway.Count -eq 0) {
        if (-not [bool]$journal.InternetSwitchCreated) { throw 'The approved existing InternetOnly switch lost its gateway address.' }
        Set-NetIPInterface -InterfaceIndex ([int]$hostAdapter[0].ifIndex) -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
        New-NetIPAddress -InterfaceIndex ([int]$hostAdapter[0].ifIndex) -AddressFamily IPv4 -IPAddress $InternetGatewayAddress -PrefixLength 24 -ErrorAction Stop | Out-Null
        $journal.GatewayAddressCreated = $true
        Write-InfraJsonAtomic $journalPath $journal
    }
    $nats = @(Get-NetNat -ErrorAction Stop)
    if (@($nats | Where-Object { [string]$_.Name -eq $InternetNatName }).Count -eq 0) {
        if ($nats.Count -ne 0) { throw 'A different WinNAT appeared after approval.' }
        New-NetNat -Name $InternetNatName -InternalIPInterfaceAddressPrefix $InternetNatPrefix -InternalRoutingDomainId ([Guid]::Empty) -ErrorAction Stop | Out-Null
        $journal.NatCreated = $true
        Write-InfraJsonAtomic $journalPath $journal
        $natPolicy = @{
            Name = $InternetNatName; TcpFilteringBehavior = 'AddressDependentFiltering'; UdpFilteringBehavior = 'AddressDependentFiltering'
            UdpInboundRefresh = $false; TcpEstablishedConnectionTimeout = 1800; TcpTransientConnectionTimeout = 120
            UdpIdleSessionTimeout = 120; IcmpQueryTimeout = 30; ErrorAction = 'Stop'
        }
        Set-NetNat @natPolicy | Out-Null
    }
    try {
        $null = Assert-RequestNetworkInternetVlan -Adapter $management[0] -PrimaryVlanId $InternetPrimaryVlanId -SecondaryVlanId $InternetSecondaryVlanId -PrivateVlanMode Promiscuous -ManagementOS
    }
    catch {
        $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $management[0] -ErrorAction Stop
        if ([string]$vlan.OperationMode -ne 'Untagged') { throw 'InternetOnly gateway VLAN changed after approval.' }
        Set-VMNetworkAdapterVlan -VMNetworkAdapter $management[0] -Promiscuous -PrimaryVlanId $InternetPrimaryVlanId -SecondaryVlanIdList ([string]$InternetSecondaryVlanId) -ErrorAction Stop
        $journal.GatewayVlanChangedFromUntagged = $true
        Write-InfraJsonAtomic $journalPath $journal
    }
    $trustedSwitch = @(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]$_.Name -eq $TrustedLanSwitchName })
    if ($trustedSwitch.Count -eq 0) {
        $createTrusted = @{
            Name = $TrustedLanSwitchName; Id = $trustedGuid.ToString('D'); NetAdapterName = $TrustedLanPhysicalAdapterName
            AllowManagementOS = $true; EnableEmbeddedTeaming = $false; Notes = 'CodexHarnessRequestNetwork:TrustedLan'; ErrorAction = 'Stop'
        }
        $trustedSwitch = @(New-VMSwitch @createTrusted)
        $journal.TrustedLanSwitchCreated = $true
        Write-InfraJsonAtomic $journalPath $journal
    }
    $physical = @(Get-NetAdapter -Name $TrustedLanPhysicalAdapterName -IncludeHidden -ErrorAction Stop)
    if ($trustedSwitch.Count -ne 1 -or $physical.Count -ne 1) { throw 'Prepared TrustedLan identity is ambiguous.' }
    $descriptions = @($trustedSwitch[0].NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ })
    if ((ConvertTo-InfraGuid $trustedSwitch[0].Id) -ne $trustedGuid.ToString('D').ToLowerInvariant() -or [string]$trustedSwitch[0].SwitchType -ne 'External' -or
        (ConvertTo-InfraGuid $trustedSwitch[0].NetAdapterInterfaceGuid) -ne (ConvertTo-InfraGuid $physical[0].InterfaceGuid) -or
        $descriptions.Count -ne 1 -or [string]$descriptions[0] -ne [string]$physical[0].InterfaceDescription -or
        -not [bool]$trustedSwitch[0].AllowManagementOS -or [bool]$trustedSwitch[0].EmbeddedTeamingEnabled) {
        throw 'Prepared TrustedLan switch identity is not exact.'
    }
    $policy = [pscustomobject][ordered]@{
        FormatVersion = 1; DefaultProfile = 'None'
        IsolatedTestNet = [ordered]@{ Enabled = $true; SwitchPrefix = 'Codex-Harness-TestNet'; NetworkPrefix = '10.254.0.0/24' }
        InternetOnly = [ordered]@{
            Enabled = $true; SwitchName = $InternetSwitchName; SwitchId = $internetGuid.ToString('D').ToLowerInvariant()
            NatName = $InternetNatName; NatPrefix = $InternetNatPrefix; ExternalIPInterfaceAddressPrefix = ''
            InternalRoutingDomainId = '{00000000-0000-0000-0000-000000000000}'
            TcpFilteringBehavior = 'AddressDependentFiltering'; UdpFilteringBehavior = 'AddressDependentFiltering'; UdpInboundRefresh = $false
            TcpEstablishedConnectionTimeout = 1800; TcpTransientConnectionTimeout = 120; UdpIdleSessionTimeout = 120; IcmpQueryTimeout = 30
            GatewayAddress = $InternetGatewayAddress; PrefixLength = 24; PrimaryVlanId = $InternetPrimaryVlanId; SecondaryVlanId = $InternetSecondaryVlanId
            DnsServers = @($InternetDnsServers); DenyRemotePrefixes = @()
        }
        TrustedLan = [ordered]@{
            Enabled = $true
            AllowedSwitches = @([ordered]@{
                Name = $TrustedLanSwitchName; Id = $trustedGuid.ToString('D').ToLowerInvariant()
                NetAdapterInterfaceGuid = ConvertTo-InfraGuid $physical[0].InterfaceGuid
                NetAdapterInterfaceDescription = [string]$physical[0].InterfaceDescription; AllowManagementOS = $true
            })
        }
    }
    $null = Assert-RequestNetworkPolicySchema $policy
    Write-InfraJsonAtomic $policyPath $policy
    $journal.State = 'PreparedForBrokerPolicyPlan'
    $journal.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Write-InfraJsonAtomic $journalPath $journal
    $result = [pscustomobject][ordered]@{
        Success = $true; State = $journal.State; TransactionId = $journal.TransactionId
        ApprovedPlanFingerprint = $journal.ApprovedPlanFingerprint; PrivatePolicyPath = $policyPath
        JournalPath = $journalPath; ResultPath = $resultPath
        InternetOnlySwitchId = $internetGuid.ToString('D').ToLowerInvariant(); TrustedLanSwitchId = $trustedGuid.ToString('D').ToLowerInvariant()
        TrustedLanPhysicalAdapterGuid = ConvertTo-InfraGuid $physical[0].InterfaceGuid
        BrokerPolicyDeploymentRequired = $true; LiveProfileCanariesRequired = $true; RecoveryRefreshRequired = $true
    }
    Write-InfraJsonAtomic $resultPath $result
    $result | ConvertTo-Json -Depth 20
}
catch {
    $failure = $_.Exception.Message
    try {
        if ([bool]$journal.TrustedLanSwitchCreated -or [bool]$journal.TrustedLanSwitchWasAbsent) {
            $owned = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
                [string]$_.Name -eq $TrustedLanSwitchName -and (ConvertTo-InfraGuid $_.Id) -eq $trustedGuid.ToString('D').ToLowerInvariant() -and
                [string]$_.Notes -eq 'CodexHarnessRequestNetwork:TrustedLan'
            })
            if ($owned.Count -eq 1) { Remove-VMSwitch -VMSwitch $owned[0] -Force -ErrorAction Stop }
        }
        if ([bool]$journal.GatewayVlanChangedFromUntagged) {
            $adapter = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $InternetSwitchName -ErrorAction Stop)
            if ($adapter.Count -eq 1) { Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter[0] -Untagged -ErrorAction Stop }
        }
        if ([bool]$journal.NatCreated -or [bool]$journal.NatWasAbsent) {
            $ownedNat = @(Get-NetNat -Name $InternetNatName -ErrorAction Stop)
            if ($ownedNat.Count -eq 1 -and [string]$ownedNat[0].InternalIPInterfaceAddressPrefix -eq $InternetNatPrefix) {
                Remove-NetNat -Name $InternetNatName -Confirm:$false -ErrorAction Stop
            }
        }
        if ([bool]$journal.GatewayAddressCreated) {
            Get-NetIPAddress -AddressFamily IPv4 -IPAddress $InternetGatewayAddress -ErrorAction Stop | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
        }
        if ([bool]$journal.InternetSwitchCreated -or [bool]$journal.InternetSwitchWasAbsent) {
            $owned = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
                [string]$_.Name -eq $InternetSwitchName -and (ConvertTo-InfraGuid $_.Id) -eq $internetGuid.ToString('D').ToLowerInvariant() -and
                [string]$_.Notes -eq 'CodexHarnessRequestNetwork:InternetOnly'
            })
            if ($owned.Count -eq 1) { Remove-VMSwitch -VMSwitch $owned[0] -Force -ErrorAction Stop }
        }
        $journal.State = 'RolledBack'
    }
    catch {
        $failure += ' Infrastructure rollback also failed: ' + $_.Exception.Message
        $journal.State = 'RollbackFailed'
    }
    $journal.Failure = $failure
    $journal.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Write-InfraJsonAtomic $journalPath $journal
    throw "Infrastructure preparation failed: $failure Transaction journal: '$journalPath'."
}
