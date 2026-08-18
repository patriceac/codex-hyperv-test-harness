[CmdletBinding()]
param(
    [string] $SourceRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    # Resolve this after parameter binding. Windows PowerShell 5.1 does not
    # reliably populate $PSScriptRoot while evaluating a default parameter.
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)] [string] $Scenario,
        [Parameter(Mandatory = $true)] [string] $ExpectedMessage,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )
    try {
        & $Operation
        throw "Scenario '$Scenario' unexpectedly succeeded."
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Scenario '$Scenario' returned the wrong error: $($_.Exception.Message)"
        }
    }
}

$modulePath = Join-Path $SourceRoot 'RequestNetwork.ps1'
$brokerPath = Join-Path $SourceRoot 'HostBroker.ps1'
$installerPath = Join-Path $SourceRoot 'Install-PoolHostBroker.ps1'
$auditPath = Join-Path $SourceRoot 'Audit-HyperVTestPool.ps1'
$moduleText = Get-Content -Raw -LiteralPath $modulePath
$brokerText = Get-Content -Raw -LiteralPath $brokerPath
$installerText = Get-Content -Raw -LiteralPath $installerPath
$auditText = Get-Content -Raw -LiteralPath $auditPath
. $modulePath

$policy = Get-RequestNetworkDefaultPolicy
$config = [pscustomobject]@{ RequestNetworkPolicy = $policy }
$scenarios = New-Object Collections.Generic.List[string]

$legacy = Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
    Operation = 'RunGuestJob'
    HostInputs = @()
}) -Config $config
Assert-True ($legacy.EffectiveProfile -eq 'None') 'A legacy request without Network did not default to None.'
$scenarios.Add('legacy-missing-network-means-none')

foreach ($malformedProfile in @('IsolatedTestNet', 'InternetOnly', 'TrustedLan')) {
    $malformedPolicy = Get-RequestNetworkDefaultPolicy
    $malformedPolicy.$malformedProfile.Enabled = 'false'
    Assert-Rejected -Scenario ("malformed Enabled flag $malformedProfile") -ExpectedMessage 'exact JSON Boolean' -Operation {
        Get-RequestNetworkPolicy -Config ([pscustomobject]@{ RequestNetworkPolicy = $malformedPolicy }) | Out-Null
    }
}
$scenarios.Add('every-profile-enabled-flag-requires-exact-boolean')

$malformedVersionPolicy = Get-RequestNetworkDefaultPolicy
$malformedVersionPolicy.FormatVersion = '1'
Assert-Rejected -Scenario 'string policy version' -ExpectedMessage 'exact JSON integer' -Operation {
    Get-RequestNetworkPolicy -Config ([pscustomobject]@{ RequestNetworkPolicy = $malformedVersionPolicy }) | Out-Null
}
$malformedTimeoutPolicy = Get-RequestNetworkDefaultPolicy
$malformedTimeoutPolicy.InternetOnly.TcpEstablishedConnectionTimeout = '1800'
Assert-Rejected -Scenario 'string NAT timeout' -ExpectedMessage 'exact JSON integer' -Operation {
    Get-RequestNetworkPolicy -Config ([pscustomobject]@{ RequestNetworkPolicy = $malformedTimeoutPolicy }) | Out-Null
}
$scenarios.Add('policy-version-and-numeric-fields-require-exact-integers')

Assert-Rejected -Scenario 'old operation cannot request connectivity' -ExpectedMessage 'use RunGuestJobNetworkV1' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJob'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'same-run'; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
Assert-Rejected -Scenario 'new operation cannot downgrade to none' -ExpectedMessage 'requires an explicit non-None' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'None'; Cohort = $null; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
$scenarios.Add('operation-version-fails-closed')

$isolated = Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
    Operation = 'RunGuestJobNetworkV1'
    HostInputs = @()
    Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'contract.test-42'; AllowHostInputs = $false }
}) -Config $config
Assert-True ($isolated.EffectiveProfile -eq 'IsolatedTestNet' -and $isolated.Cohort -eq 'contract.test-42') 'A valid isolated cohort did not resolve.'
$scenarios.Add('isolated-profile-resolves-only-explicit-cohort')

$installationRootA = Join-Path $SourceRoot 'contract-installation-a'
$installationRootB = Join-Path $SourceRoot 'contract-installation-b'
$installationScopeA = Get-RequestNetworkInstallationScope -BrokerRoot $installationRootA
$installationScopeARepeat = Get-RequestNetworkInstallationScope -BrokerRoot ($installationRootA.ToUpperInvariant())
$installationScopeB = Get-RequestNetworkInstallationScope -BrokerRoot $installationRootB
Assert-True (
    $installationScopeA -match '^[0-9a-f]{10}$' -and
    $installationScopeA -eq $installationScopeARepeat -and
    $installationScopeA -ne $installationScopeB
) 'Request-network installation scopes are not stable and distinct for separate broker roots.'
$cohortHash = (Get-RequestNetworkHash -Value 'contract.test-42').Substring(0, 16)
$expectedScopedSwitch = [string]$policy.IsolatedTestNet.SwitchPrefix + '-' + $installationScopeA + '-' + $cohortHash.Substring(0, 10)
Assert-True ($expectedScopedSwitch -like ('*-' + $installationScopeA + '-*') -and $expectedScopedSwitch -notlike ('*-' + $installationScopeB + '-*')) 'The cohort switch identity was not installation-scoped.'
Assert-True (
    $moduleText.Contains("`$switchName = `$prefix + '-' + `$installationScope + '-' + `$cohortHash.Substring(0, 10)") -and
    $moduleText.Contains("`$ownershipMarker = 'CodexHarnessRequestNetwork:' + `$installationScope + ':' + `$cohortHash") -and
    $moduleText.Contains('InstallationScope = [string]$Runtime.InstallationScope') -and
    $moduleText.Contains('CohortHash = [string]$Runtime.CohortHash')
) 'Isolated cohorts are not bound to the installation identity in switch and lease state.'
$scenarios.Add('isolated-cohort-is-installation-scoped')

Assert-Rejected -Scenario 'raw network field' -ExpectedMessage 'unsupported properties' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'safe'; SwitchName = 'caller-controlled'; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
Assert-Rejected -Scenario 'truthy string is not acknowledgement' -ExpectedMessage 'exact string, null, and Boolean JSON types' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @([pscustomobject]@{ SelectedTransport = 'Vhdx' })
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'safe'; AllowHostInputs = 'false' }
    }) -Config $config | Out-Null
}
$scenarios.Add('client-cannot-supply-raw-network-policy')

foreach ($reservedProperty in @('NetworkPolicy', 'NetworkProfile', 'NatName', 'DnsServers', 'DenyRemotePrefixes')) {
    $rawTopLevelRequest = [pscustomobject][ordered]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'safe'; AllowHostInputs = $false }
    }
    $rawTopLevelRequest | Add-Member -NotePropertyName $reservedProperty -NotePropertyValue 'raw'
    Assert-Rejected -Scenario ("reserved top-level field $reservedProperty") -ExpectedMessage 'reserved top-level properties are not accepted' -Operation {
        Resolve-RequestNetworkProfile -Request $rawTopLevelRequest -Config $config | Out-Null
    }
}
Assert-True ($moduleText.Contains('$reservedTopLevelProperties = @(') -and $moduleText.Contains('Network authority must be expressed only through the bounded Network object')) 'Raw top-level network policy fields are not rejected.'
$scenarios.Add('client-cannot-supply-top-level-network-policy')

Assert-Rejected -Scenario 'disabled InternetOnly' -ExpectedMessage 'disabled by the SYSTEM broker policy' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'InternetOnly'; Cohort = $null; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
Assert-Rejected -Scenario 'disabled TrustedLan' -ExpectedMessage 'disabled by the SYSTEM broker policy' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'TrustedLan'; Cohort = $null; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
$scenarios.Add('external-profiles-default-disabled')

$unpinnedTrustedPolicy = Get-RequestNetworkDefaultPolicy
$unpinnedTrustedPolicy.TrustedLan.Enabled = $true
$unpinnedTrustedPolicy.TrustedLan.AllowedSwitches = @([pscustomobject]@{ Name = 'External'; Id = [Guid]::NewGuid().ToString() })
Assert-Rejected -Scenario 'TrustedLan missing physical pin' -ExpectedMessage 'must contain exactly these properties' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @()
        Network = [pscustomobject]@{ Profile = 'TrustedLan'; Cohort = $null; AllowHostInputs = $false }
    }) -Config ([pscustomobject]@{ RequestNetworkPolicy = $unpinnedTrustedPolicy }) | Out-Null
}
$scenarios.Add('trusted-lan-requires-physical-uplink-pin')

$trustedRequest = [pscustomobject]@{
    Operation = 'RunGuestJobNetworkV1'
    HostInputs = @()
    Network = [pscustomobject]@{ Profile = 'TrustedLan'; Cohort = $null; AllowHostInputs = $false }
}
$validTrustedSwitch = [pscustomobject][ordered]@{
    Name = 'Broker Pinned External'
    Id = '{33333333-3333-3333-3333-333333333333}'
    NetAdapterInterfaceGuid = '{44444444-4444-4444-4444-444444444444}'
    NetAdapterInterfaceDescription = 'Physical uplink fixture'
    AllowManagementOS = $true
}
foreach ($switchCount in @(0, 2)) {
    $invalidTrustedPolicy = Get-RequestNetworkDefaultPolicy
    $invalidTrustedPolicy.TrustedLan.Enabled = $true
    $invalidTrustedPolicy.TrustedLan.AllowedSwitches = if ($switchCount -eq 0) { @() } else { @($validTrustedSwitch, $validTrustedSwitch) }
    Assert-Rejected -Scenario "TrustedLan policy with $switchCount switches" -ExpectedMessage 'exactly one broker-pinned allowed switch' -Operation {
        Resolve-RequestNetworkProfile -Request $trustedRequest -Config ([pscustomobject]@{ RequestNetworkPolicy = $invalidTrustedPolicy }) | Out-Null
    }
}
$validTrustedPolicy = Get-RequestNetworkDefaultPolicy
$validTrustedPolicy.TrustedLan.Enabled = $true
$validTrustedPolicy.TrustedLan.AllowedSwitches = @($validTrustedSwitch)
$trustedDefinition = Resolve-RequestNetworkProfile -Request $trustedRequest -Config ([pscustomobject]@{ RequestNetworkPolicy = $validTrustedPolicy })
Assert-True ([string]$trustedDefinition.RequestedSwitchName -eq [string]$validTrustedSwitch.Name) 'TrustedLan did not resolve its sole pinned switch entirely from broker policy.'
$scenarios.Add('trusted-lan-switch-is-sole-and-broker-selected')

Assert-Rejected -Scenario 'network plus input needs acknowledgement' -ExpectedMessage 'explicit AllowHostInputs' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @([pscustomobject]@{ SelectedTransport = 'Vhdx' })
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'safe'; AllowHostInputs = $false }
    }) -Config $config | Out-Null
}
Assert-Rejected -Scenario 'network plus share always rejected' -ExpectedMessage 'cannot coexist' -Operation {
    Resolve-RequestNetworkProfile -Request ([pscustomobject]@{
        Operation = 'RunGuestJobNetworkV1'
        HostInputs = @([pscustomobject]@{ SelectedTransport = 'Share' })
        Network = [pscustomobject]@{ Profile = 'IsolatedTestNet'; Cohort = 'safe'; AllowHostInputs = $true }
    }) -Config $config | Out-Null
}
$scenarios.Add('host-input-coexistence-is-explicit-and-vhdx-only')

$canonicalDenies = @(Get-RequestNetworkCanonicalInternetDenyPrefixes)
$expectedCanonicalDenies = @(
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
    '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
    '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24',
    '224.0.0.0/4', '240.0.0.0/4', '::/0'
)
Assert-True ((@($canonicalDenies | Sort-Object) -join '|') -eq (@($expectedCanonicalDenies | Sort-Object) -join '|')) 'InternetOnly canonical deny prefixes changed.'
Assert-True (
    $moduleText.Contains('function Get-RequestNetworkNatStaticMappings') -and
    $moduleText.Contains("Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName 'MSFT_NetNatStaticMapping'") -and
    $moduleText.Contains('Where-Object { [string]::Equals([string]$_.NatName, $NatName, [StringComparison]::Ordinal) }') -and
    $moduleText.Contains('requires an outbound-only NAT with no static inbound mappings')
) 'InternetOnly does not reject static inbound NAT mappings through the exact NAT-name-scoped source contract.'
Assert-True (
    $moduleText.Contains('Get-NetNatSession') -and
    $moduleText.Contains('InternalSourceAddress') -and
    $moduleText.Contains('InternalDestinationAddress') -and
    $moduleText.Contains('EnforcedLocalAddress') -and
    $moduleText.Contains('LocalIPAddress = $localAddress') -and
    $moduleText.Contains("Protocol = 'TCP'") -and
    $moduleText.Contains("Protocol = 'UDP'")
) 'InternetOnly does not isolate stale NAT sessions and enforce the assigned local address.'
Assert-True (Test-RequestNetworkIPv4PrefixCovered -CandidatePrefix '192.168.42.0/24' -CoveringPrefix '192.168.0.0/16') 'The route containment helper rejected a covered private route.'
Assert-True (-not (Test-RequestNetworkIPv4PrefixCovered -CandidatePrefix '203.0.113.0/24' -CoveringPrefix '192.168.0.0/16')) 'The route containment helper accepted an unrelated route.'
foreach ($nonCanonicalPrefix in @('010.254.0.0/24', '10.254.00.0/24', '10.254.0.00/24', '256.254.0.0/24', '10.254.0.0/024')) {
    Assert-Rejected -Scenario ("noncanonical IPv4 /24 $nonCanonicalPrefix") -ExpectedMessage 'IPv4' -Operation {
        Get-RequestNetworkIPv4Prefix24 -Prefix $nonCanonicalPrefix -Context 'test' | Out-Null
    }
}
$expectedGuestRoutes = @(Get-RequestNetworkExpectedGuestRoutePrefixes -NetworkPrefix '10.254.0.0/24' -GuestAddress '10.254.0.101' -PrefixLength 24)
Assert-True ($expectedGuestRoutes -contains '10.254.0.0/24' -and $expectedGuestRoutes -contains '10.254.0.101/32' -and $expectedGuestRoutes -contains '10.254.0.255/32' -and $expectedGuestRoutes -contains '224.0.0.0/4' -and $expectedGuestRoutes -contains '255.255.255.255/32') 'Expected Windows connected guest routes were not canonicalized.'
$scenarios.Add('canonical-ipv4-prefix-and-connected-route-shapes')

$defaultRouteSnapshot = & {
    function Get-NetRoute {
        [CmdletBinding()]
        param()
        [pscustomobject][ordered]@{ DestinationPrefix = '0.0.0.0/0'; InterfaceIndex = 12; NextHop = '192.0.2.1'; RouteMetric = 25 }
        [pscustomobject][ordered]@{ DestinationPrefix = '::/0'; InterfaceIndex = 15; NextHop = 'fe80::1'; RouteMetric = 30 }
    }
    function Get-NetIPInterface {
        [CmdletBinding()]
        param([int]$InterfaceIndex, [string]$AddressFamily)
        [pscustomobject]@{ InterfaceMetric = if ($InterfaceIndex -eq 12) { 10 } else { 20 } }
    }
    function Get-NetAdapter {
        [CmdletBinding()]
        param([int]$InterfaceIndex, [switch]$IncludeHidden)
        if ($InterfaceIndex -eq 12) {
            [pscustomobject]@{ InterfaceGuid = '{11111111-1111-1111-1111-111111111111}'; InterfaceDescription = 'Wi-Fi fixture' }
        }
        else {
            [pscustomobject]@{ InterfaceGuid = '{22222222-2222-2222-2222-222222222222}'; InterfaceDescription = 'VPN fixture adapter' }
        }
    }
    Get-RequestNetworkInternetDefaultRouteAttestation
}
Assert-True (@($defaultRouteSnapshot).Count -eq 2) 'InternetOnly did not snapshot the complete IPv4 and IPv6 default-route set.'
Assert-True (
    @($defaultRouteSnapshot | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.InterfaceGuid -eq '11111111-1111-1111-1111-111111111111' -and $_.InterfaceDescription -eq 'Wi-Fi fixture' -and [int]$_.InterfaceIndex -eq 12 -and $_.NextHop -eq '192.0.2.1' -and [int]$_.RouteMetric -eq 25 -and [int]$_.InterfaceMetric -eq 10 }).Count -eq 1 -and
    @($defaultRouteSnapshot | Where-Object { $_.AddressFamily -eq 'IPv6' -and $_.InterfaceGuid -eq '22222222-2222-2222-2222-222222222222' -and $_.InterfaceDescription -eq 'VPN fixture adapter' -and [int]$_.InterfaceIndex -eq 15 -and $_.NextHop -eq 'fe80::1' -and [int]$_.RouteMetric -eq 30 -and [int]$_.InterfaceMetric -eq 20 }).Count -eq 1
) 'InternetOnly default-route attestation omitted interface identity, next hop, or route/interface metrics.'
Assert-Rejected -Scenario 'default-route next-hop swap' -ExpectedMessage 'egress identity changed' -Operation {
    & {
        param($Expected)
        function Get-NetRoute {
            [CmdletBinding()]
            param()
            [pscustomobject][ordered]@{ DestinationPrefix = '0.0.0.0/0'; InterfaceIndex = 12; NextHop = '198.51.100.1'; RouteMetric = 25 }
            [pscustomobject][ordered]@{ DestinationPrefix = '::/0'; InterfaceIndex = 15; NextHop = 'fe80::1'; RouteMetric = 30 }
        }
        function Get-NetIPInterface {
            [CmdletBinding()]
            param([int]$InterfaceIndex, [string]$AddressFamily)
            [pscustomobject]@{ InterfaceMetric = if ($InterfaceIndex -eq 12) { 10 } else { 20 } }
        }
        function Get-NetAdapter {
            [CmdletBinding()]
            param([int]$InterfaceIndex, [switch]$IncludeHidden)
            if ($InterfaceIndex -eq 12) {
                [pscustomobject]@{ InterfaceGuid = '{11111111-1111-1111-1111-111111111111}'; InterfaceDescription = 'Wi-Fi fixture' }
            }
            else {
                [pscustomobject]@{ InterfaceGuid = '{22222222-2222-2222-2222-222222222222}'; InterfaceDescription = 'VPN fixture adapter' }
            }
        }
        Assert-RequestNetworkInternetDefaultRouteAttestation -ExpectedAttestation $Expected | Out-Null
    } $defaultRouteSnapshot
}
Assert-Rejected -Scenario 'default-route query failure' -ExpectedMessage 'default route inventory query failed' -Operation {
    & {
        param($Expected)
        function Get-NetRoute {
            [CmdletBinding()]
            param()
            throw 'default route inventory query failed'
        }
        Assert-RequestNetworkInternetDefaultRouteAttestation -ExpectedAttestation $Expected | Out-Null
    } $defaultRouteSnapshot
}
Assert-True (
    $moduleText.Contains('DefaultRouteAttestation = @(') -and
    $moduleText.Contains('Get-RequestNetworkInternetDefaultRouteAttestation') -and
    $moduleText.Contains('Assert-RequestNetworkInternetDefaultRouteAttestation') -and
    $moduleText.Contains('DefaultRouteCount')
) 'InternetOnly default-route attestation is not persisted and revalidated through runtime, cleanup, and recovery.'
$scenarios.Add('internet-only-default-egress-attestation-is-complete-and-fail-closed')

$natSettings = [pscustomobject][ordered]@{
    ExternalIPInterfaceAddressPrefix = '0.0.0.0/0'
    InternalRoutingDomainId = '{11111111-1111-1111-1111-111111111111}'
    TcpFilteringBehavior = 'AddressDependentFiltering'
    UdpFilteringBehavior = 'AddressDependentFiltering'
    UdpInboundRefresh = $false
    TcpEstablishedConnectionTimeout = 1800
    TcpTransientConnectionTimeout = 120
    UdpIdleSessionTimeout = 120
    IcmpQueryTimeout = 30
}
$expectedNatPolicy = Get-RequestNetworkExpectedNatPolicy -Settings $natSettings
Assert-True (
    [string]$expectedNatPolicy.ExternalIPInterfaceAddressPrefix -eq '0.0.0.0/0' -and
    [string]$expectedNatPolicy.InternalRoutingDomainId -eq $natSettings.InternalRoutingDomainId -and
    [string]$expectedNatPolicy.TcpFilteringBehavior -eq 'AddressDependentFiltering' -and
    [string]$expectedNatPolicy.UdpFilteringBehavior -eq 'AddressDependentFiltering' -and
    -not [bool]$expectedNatPolicy.UdpInboundRefresh -and
    [uint32]$expectedNatPolicy.TcpEstablishedConnectionTimeout -eq 1800 -and
    [uint32]$expectedNatPolicy.TcpTransientConnectionTimeout -eq 120 -and
    [uint32]$expectedNatPolicy.UdpIdleSessionTimeout -eq 120 -and
    [uint32]$expectedNatPolicy.IcmpQueryTimeout -eq 30
) 'The exact InternetOnly filtering, refresh, routing, and timeout policy was not normalized.'
$validNat = [pscustomobject][ordered]@{
    Active = $true
    InternalIPInterfaceAddressPrefix = '10.254.1.0/24'
    ExternalIPInterfaceAddressPrefix = '0.0.0.0/0'
    InternalRoutingDomainId = '{11111111-1111-1111-1111-111111111111}'
    TcpFilteringBehavior = 'AddressDependentFiltering'
    UdpFilteringBehavior = 'AddressDependentFiltering'
    UdpInboundRefresh = $false
    TcpEstablishedConnectionTimeout = 1800
    TcpTransientConnectionTimeout = 120
    UdpIdleSessionTimeout = 120
    IcmpQueryTimeout = 30
}
Assert-True (Assert-RequestNetworkNatPolicy -Nat $validNat -ExpectedPolicy $expectedNatPolicy -ExpectedInternalPrefix '10.254.1.0/24') 'The exact synthetic NAT policy was rejected.'
$invalidNat = [pscustomobject][ordered]@{}
foreach ($property in @($validNat.PSObject.Properties)) { $invalidNat | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$invalidNat.UdpInboundRefresh = $true
Assert-Rejected -Scenario 'NAT inbound refresh override' -ExpectedMessage 'exact active filtering, refresh, routing, prefix, and timeout policy' -Operation {
    Assert-RequestNetworkNatPolicy -Nat $invalidNat -ExpectedPolicy $expectedNatPolicy -ExpectedInternalPrefix '10.254.1.0/24' | Out-Null
}
$unsafeNatSettings = [pscustomobject][ordered]@{}
foreach ($property in @($natSettings.PSObject.Properties)) { $unsafeNatSettings | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$unsafeNatSettings.TcpTransientConnectionTimeout = 301
Assert-Rejected -Scenario 'NAT timeout outside broker bound' -ExpectedMessage 'outside its broker safety bound' -Operation {
    Get-RequestNetworkExpectedNatPolicy -Settings $unsafeNatSettings | Out-Null
}
Assert-True (
    $moduleText.Contains("`$allNats.Count -ne 1") -and
    $moduleText.Contains("`$nat.Count -ne 1") -and
    $moduleText.Contains("InternalIPInterfaceAddressPrefix, [string]`$settings.NatPrefix") -and
    $moduleText.Contains('Get-RequestNetworkNatStaticMappings -NatName') -and
    $moduleText.Contains('Assert-RequestNetworkHostPolicyCurrent')
) 'InternetOnly does not pin one sole mapping-free WinNAT, apply its exact policy, and revalidate host policy.'
$scenarios.Add('internet-boundary-denies-private-special-and-ipv6')
$scenarios.Add('internet-only-nat-policy-is-exact-and-mapping-free')

$aclRuntime = [pscustomobject]@{
    Profile = 'InternetOnly'
    EnforcedLocalAddress = '10.254.1.55/32'
    DenyRemotePrefixes = @('10.0.0.0/8', '192.168.0.0/16')
    PrimaryVlanId = 110
    SecondaryVlanId = 210
    ExtendedAclIdleSessionTimeout = 120
    ExtendedAclWeights = Get-RequestNetworkInternetExtendedAclWeights
}
$aclAdapter = [pscustomobject]@{
    Name = 'CodexRequestNet-fixture'
    MacAddressSpoofing = 'Off'
    DhcpGuard = 'On'
    RouterGuard = 'On'
}
$vlanFixture = [pscustomobject][ordered]@{
    OperationMode = 'Private'
    PrivateVlanMode = 'Isolated'
    PrimaryVlanId = 110
    SecondaryVlanId = 210
    SecondaryVlanIdList = @()
}
$validExtendedAcls = @(Get-RequestNetworkInternetExtendedAclRules -Runtime $aclRuntime)
$weights = Get-RequestNetworkInternetExtendedAclWeights
Assert-True (
    [int]$weights.StatelessIdleSessionTimeout -eq 0 -and
    (ConvertTo-RequestNetworkExtendedAclDirection -Value 1) -eq 'Inbound' -and
    (ConvertTo-RequestNetworkExtendedAclDirection -Value 2) -eq 'Outbound' -and
    (ConvertTo-RequestNetworkExtendedAclAction -Value 1) -eq 'Allow' -and
    (ConvertTo-RequestNetworkExtendedAclAction -Value 2) -eq 'Deny'
) 'The exact Hyper-V provider enum and stateless-timeout normalization changed.'
Assert-Rejected -Scenario 'unsupported extended ACL direction' -ExpectedMessage 'unsupported extended-ACL direction' -Operation {
    ConvertTo-RequestNetworkExtendedAclDirection -Value 3 | Out-Null
}
Assert-Rejected -Scenario 'unsupported extended ACL action' -ExpectedMessage 'unsupported extended-ACL action' -Operation {
    ConvertTo-RequestNetworkExtendedAclAction -Value 3 | Out-Null
}
$prefixDenyWeights = @($validExtendedAcls | Where-Object {
    $_.Direction -eq 'Outbound' -and $_.Action -eq 'Deny' -and $_.RemoteIPAddress -ne 'ANY'
} | ForEach-Object { [int]$_.Weight })
$allowWeights = @($validExtendedAcls | Where-Object Action -eq 'Allow' | ForEach-Object { [int]$_.Weight })
Assert-True (
    $validExtendedAcls.Count -eq 6 -and
    @($validExtendedAcls | Group-Object Direction, Weight | Where-Object Count -gt 1).Count -eq 0 -and
    ($prefixDenyWeights | Measure-Object -Minimum).Minimum -gt ($allowWeights | Measure-Object -Maximum).Maximum -and
    [int]$weights.DefaultDenyWeight -lt ($allowWeights | Measure-Object -Minimum).Minimum
) 'The weighted InternetOnly rule set does not preserve default deny, source allow, and higher-priority private-prefix deny ordering.'

$validAclResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl {
        [CmdletBinding()]
        param($VMNetworkAdapter)
    }
    function Get-VMNetworkAdapterExtendedAcl {
        [CmdletBinding()]
        param($VMNetworkAdapter)
        foreach ($acl in @($ExtendedFixture)) { $acl }
    }
    function Get-VMNetworkAdapterVlan {
        [CmdletBinding()]
        param($VMNetworkAdapter, [switch] $ManagementOS, [string] $VMNetworkAdapterName)
        $VlanFixture
    }
    Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter
} $validExtendedAcls $vlanFixture $aclRuntime $aclAdapter
Assert-True (
    [int]$validAclResult.InstalledAclCount -eq 0 -and
    [int]$validAclResult.InstalledExtendedAclCount -eq $validExtendedAcls.Count -and
    [bool]$validAclResult.InstalledVlan
) 'The exact synthetic private-VLAN and extended-ACL contract was not accepted.'

$providerNormalizedExtendedAcls = @($validExtendedAcls | ForEach-Object {
    $copy = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    $copy.Direction = if ([string]$copy.Direction -eq 'Inbound') { 1 } else { 2 }
    $copy.Action = if ([string]$copy.Action -eq 'Allow') { 1 } else { 2 }
    if (-not [bool]$copy.Stateful) { $copy.IdleSessionTimeout = 0 }
    [pscustomobject]$copy
})
$providerNormalizedResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter) }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter); @($ExtendedFixture) }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param($VMNetworkAdapter); $VlanFixture }
    Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter
} $providerNormalizedExtendedAcls $vlanFixture $aclRuntime $aclAdapter
Assert-True (
    [int]$providerNormalizedResult.InstalledExtendedAclCount -eq $providerNormalizedExtendedAcls.Count -and
    [bool]$providerNormalizedResult.InstalledVlan
) 'The exact Windows provider-normalized extended-ACL contract was not accepted.'
$scenarios.Add('internet-only-provider-normalized-acl-contract-is-exact')

$extraExtendedAcl = [pscustomobject][ordered]@{
    Direction = 'Outbound'; Action = 'Allow'; LocalIPAddress = '10.254.1.55/32'; RemoteIPAddress = '10.0.0.42/32'
    LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'TCP'; Weight = 65535
    Stateful = $true; IdleSessionTimeout = 120; IsolationID = 0
}
$extraAclResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter) }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter); @($ExtendedFixture) }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param($VMNetworkAdapter); $VlanFixture }
    try { Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter | Out-Null; $null }
    catch { $_.Exception.Message }
} @($validExtendedAcls + $extraExtendedAcl) $vlanFixture $aclRuntime $aclAdapter
Assert-True ([string]$extraAclResult -like '*extended ACLs; expected exactly*') 'An extra overriding extended ACL was not rejected by the exact multiset contract.'

$tamperedExtendedAcls = @($validExtendedAcls | ForEach-Object {
    $copy = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    [pscustomobject]$copy
})
$tamperedExtendedAcls[0].Weight = 65535
$tamperedAclResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter) }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter); @($ExtendedFixture) }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param($VMNetworkAdapter); $VlanFixture }
    try { Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter | Out-Null; $null }
    catch { $_.Exception.Message }
} $tamperedExtendedAcls $vlanFixture $aclRuntime $aclAdapter
Assert-True ([string]$tamperedAclResult -like '*missing its exact*extended ACL*') 'A same-count weight override was not rejected by the exact extended-ACL multiset contract.'

$invalidVlanFixture = [pscustomobject][ordered]@{
    OperationMode = 'Access'; PrivateVlanMode = ''; PrimaryVlanId = 110; SecondaryVlanId = 210; SecondaryVlanIdList = @()
}
$invalidVlanResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter) }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter); @($ExtendedFixture) }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param($VMNetworkAdapter); $VlanFixture }
    try { Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter | Out-Null; $null }
    catch { $_.Exception.Message }
} $validExtendedAcls $invalidVlanFixture $aclRuntime $aclAdapter
Assert-True ([string]$invalidVlanResult -like '*Isolated VLAN setting no longer matches*') 'A non-isolated guest VLAN was accepted.'

$basicAclResult = & {
    param($ExtendedFixture, $VlanFixture, $Runtime, $Adapter)
    function Get-VMNetworkAdapterAcl { [CmdletBinding()] param($VMNetworkAdapter); [pscustomobject]@{ Action = 'Allow' } }
    function Get-VMNetworkAdapterExtendedAcl { [CmdletBinding()] param($VMNetworkAdapter); @($ExtendedFixture) }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param($VMNetworkAdapter); $VlanFixture }
    try { Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $Adapter | Out-Null; $null }
    catch { $_.Exception.Message }
} $validExtendedAcls $vlanFixture $aclRuntime $aclAdapter
Assert-True ([string]$basicAclResult -like '*must not use basic IP/MAC ACLs*') 'InternetOnly accepted a basic ACL alongside the exact extended policy.'

$gatewayAdapter = [pscustomobject]@{ Name = 'Internet Gateway'; MacAddress = '00-15-5D-01-02-03' }
$gatewayVlanFixture = [pscustomobject][ordered]@{
    OperationMode = 'Private'; PrivateVlanMode = 'Promiscuous'; PrimaryVlanId = 110; SecondaryVlanIdList = @(210)
}
$gatewayVlanResult = & {
    param($Adapter, $VlanFixture)
    function Get-VMNetworkAdapter {
        [CmdletBinding()]
        param([switch] $ManagementOS, [string] $SwitchName)
        $Adapter
    }
    function Get-VMNetworkAdapterVlan {
        [CmdletBinding()]
        param([switch] $ManagementOS, [string] $VMNetworkAdapterName)
        $VlanFixture
    }
    Assert-RequestNetworkInternetGatewayVlan -SwitchName 'Internet Switch' -GatewayMacAddress '00155D010203' -PrimaryVlanId 110 -SecondaryVlanId 210
} $gatewayAdapter $gatewayVlanFixture
Assert-True ([string]$gatewayVlanResult.Vlan.PrivateVlanMode -eq 'Promiscuous' -and @($gatewayVlanResult.Vlan.SecondaryVlanIdList).Count -eq 1) 'The exact synthetic promiscuous gateway VLAN was rejected.'
$invalidGatewayVlan = [pscustomobject][ordered]@{
    OperationMode = 'Private'; PrivateVlanMode = 'Promiscuous'; PrimaryVlanId = 110; SecondaryVlanIdList = @(210, 211)
}
$gatewayVlanError = & {
    param($Adapter, $VlanFixture)
    function Get-VMNetworkAdapter { [CmdletBinding()] param([switch] $ManagementOS, [string] $SwitchName); $Adapter }
    function Get-VMNetworkAdapterVlan { [CmdletBinding()] param([switch] $ManagementOS, [string] $VMNetworkAdapterName); $VlanFixture }
    try {
        Assert-RequestNetworkInternetGatewayVlan -SwitchName 'Internet Switch' -GatewayMacAddress '00155D010203' -PrimaryVlanId 110 -SecondaryVlanId 210 | Out-Null
        $null
    }
    catch { $_.Exception.Message }
} $gatewayAdapter $invalidGatewayVlan
Assert-True ([string]$gatewayVlanError -like '*does not contain exactly the pinned secondary VLAN*') 'A promiscuous gateway with an extra secondary VLAN was accepted.'

Assert-True (
    $moduleText.Contains('$basicAcls.Count -ne 0') -and
    $moduleText.Contains('$extendedAcls.Count -ne $expectedRules.Count') -and
    $moduleText.Contains("New-Object 'Collections.Generic.HashSet[int]'") -and
    $moduleText.Contains('Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $Adapter -ErrorAction Stop') -and
    $moduleText.Contains('Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -Isolated') -and
    $moduleText.Contains('Assert-RequestNetworkInternetGatewayVlan') -and
    $moduleText.Contains('-PrivateVlanMode Promiscuous -ManagementOS')
) 'InternetOnly is not enforced as an exact zero-basic-ACL, exact extended-ACL, isolated-guest/promiscuous-gateway private-VLAN contract.'
$scenarios.Add('internet-only-pvlan-and-extended-acl-contract-is-exact')

$prepareStart = $moduleText.IndexOf('function Prepare-RequestVmNetwork', [StringComparison]::Ordinal)
$connectStart = $moduleText.IndexOf('function Connect-RequestVmNetwork', [StringComparison]::Ordinal)
$addDisconnected = $moduleText.IndexOf('Add-VMNetworkAdapter -VMName $VmName -Name ([string]$Runtime.AdapterName) -DeviceNaming On', $prepareStart, [StringComparison]::Ordinal)
$guard = $moduleText.IndexOf('Set-VMNetworkAdapter -VMNetworkAdapter $adapter -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On', $prepareStart, [StringComparison]::Ordinal)
$vlan = $moduleText.IndexOf('Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -Isolated', $prepareStart, [StringComparison]::Ordinal)
$acl = $moduleText.IndexOf('Add-VMNetworkAdapterExtendedAcl @parameters', $prepareStart, [StringComparison]::Ordinal)
$connect = $moduleText.IndexOf('Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -VMSwitch $approvedSwitch', $connectStart, [StringComparison]::Ordinal)
$prepareEnd = $moduleText.IndexOf('function Assert-RequestNetworkLeasedAttachments', $prepareStart, [StringComparison]::Ordinal)
Assert-True (
    $addDisconnected -ge 0 -and
    $guard -gt $addDisconnected -and
    $vlan -gt $guard -and
    $acl -gt $vlan -and
    $prepareEnd -gt $acl -and
    $moduleText.IndexOf('Connect-VMNetworkAdapter', $acl, [StringComparison]::Ordinal) -gt $prepareEnd -and
    $connectStart -gt $prepareEnd -and
    $connect -gt $connectStart
) 'The adapter is not prepared disconnected, guarded/filtered, and connected only by the final connection function.'
$reserve = $moduleText.IndexOf("Write-RequestNetworkLeaseState -Runtime `$runtime -Status 'Reserved'", [StringComparison]::Ordinal)
$brokerNewRuntime = $brokerText.IndexOf('New-RequestNetworkRuntime -BrokerRoot $BrokerRoot -Definition $requestNetworkDefinition', [StringComparison]::Ordinal)
$brokerPrepare = $brokerText.IndexOf('Prepare-RequestVmNetwork -Runtime $requestNetworkRuntime', [StringComparison]::Ordinal)
$brokerStartVm = $brokerText.IndexOf('Start-VM -Name $vmName', $brokerPrepare, [StringComparison]::Ordinal)
$brokerWaitGuest = $brokerText.IndexOf('Wait-GuestSession -VmName $vmName', $brokerStartVm, [StringComparison]::Ordinal)
$brokerGuestSession = $brokerText.IndexOf('$session = Open-GuestSessionReliable', $brokerPrepare, [StringComparison]::Ordinal)
$brokerResidueCleanup = $brokerText.IndexOf('Reset-GuestRequestNetworkResidue -Session $session -Policy $requestNetworkDefinition.Policy', $brokerGuestSession, [StringComparison]::Ordinal)
$brokerConnect = $brokerText.IndexOf('Connect-RequestVmNetwork -Runtime $requestNetworkRuntime', $brokerGuestSession, [StringComparison]::Ordinal)
$brokerInitGuest = $brokerText.IndexOf('Initialize-GuestRequestNetwork -Session $session -Runtime $requestNetworkRuntime', $brokerConnect, [StringComparison]::Ordinal)
Assert-True (
    $reserve -ge 0 -and
    $reserve -lt $prepareStart -and
    $brokerNewRuntime -ge 0 -and
    $brokerPrepare -gt $brokerNewRuntime -and
    $brokerStartVm -gt $brokerPrepare -and
    $brokerWaitGuest -gt $brokerStartVm -and
    $brokerGuestSession -gt $brokerWaitGuest -and
    $brokerResidueCleanup -gt $brokerGuestSession -and
    $brokerConnect -gt $brokerResidueCleanup -and
    $brokerInitGuest -gt $brokerConnect
) 'The lease-first, disconnected preparation, guest wait, connect-last sequence is not enforced.'
$scenarios.Add('lease-first-connect-last')

$cleanupStart = $moduleText.IndexOf('function Remove-RequestNetworkRuntime', [StringComparison]::Ordinal)
$cleanupVmIdentity = $moduleText.IndexOf('The leased VM name now identifies a different VM; cleanup refused to mutate it.', $cleanupStart, [StringComparison]::Ordinal)
$disconnect = $moduleText.IndexOf('Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter', $cleanupStart, [StringComparison]::Ordinal)
$remove = $moduleText.IndexOf('Remove-VMNetworkAdapter -VMNetworkAdapter $adapter', $cleanupStart, [StringComparison]::Ordinal)
$switchIdentity = $moduleText.IndexOf('The leased isolated switch identity changed; cleanup refused to mutate it.', $cleanupStart, [StringComparison]::Ordinal)
$leaseDelete = $moduleText.IndexOf("Remove-Item -LiteralPath ([string]`$Runtime.StatePath) -Force -ErrorAction Stop", $cleanupStart, [StringComparison]::Ordinal)
$leaseDeleteFailure = $moduleText.IndexOf('$errors.Add("Lease deletion:', $leaseDelete, [StringComparison]::Ordinal)
$cleanupFailedState = $moduleText.IndexOf("Write-RequestNetworkLeaseState -Runtime `$Runtime -Status 'CleanupFailed'", $leaseDeleteFailure, [StringComparison]::Ordinal)
Assert-True (
    $cleanupVmIdentity -ge $cleanupStart -and
    $disconnect -gt $cleanupVmIdentity -and
    $remove -gt $disconnect -and
    $switchIdentity -gt $remove -and
    $leaseDelete -gt $remove -and
    $leaseDeleteFailure -gt $leaseDelete -and
    $cleanupFailedState -gt $leaseDeleteFailure
) 'Request-network cleanup is not identity-bound, disconnect-first, and failure-reporting on lease deletion.'
$brokerCleanup = $brokerText.IndexOf('Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime', [StringComparison]::Ordinal)
$terminalResult = $brokerText.IndexOf("Write-JsonAtomic -Path (Join-Path `$ResultRoot 'broker-result.json')", [StringComparison]::Ordinal)
Assert-True (
    $brokerCleanup -ge 0 -and
    $terminalResult -gt $brokerCleanup -and
    $brokerText.Contains("`$failureStage = 'CleaningNetwork'") -and
    $brokerText.Contains('One or more VM network adapters remained connected after request cleanup.')
) 'The terminal broker result can be published before verified network cleanup.'
Assert-True ($moduleText.Contains('Recover-OrphanedRequestNetworkResources') -and $moduleText.Contains('The leased adapter name no longer resolves uniquely') -and $moduleText.Contains('The leased adapter name no longer resolves uniquely after disconnect')) 'Orphan recovery or adapter identity binding is missing.'
$recoveryStart = $moduleText.IndexOf('function Recover-OrphanedRequestNetworkResources', [StringComparison]::Ordinal)
$recoveryText = $moduleText.Substring($recoveryStart)
Assert-True (
    $recoveryText.Contains("Get-ChildItem -LiteralPath `$leaseRoot -Filter '*.json' -File -ErrorAction Stop") -and
    $recoveryText.Contains('Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop') -and
    $recoveryText.Contains('Get-VMSwitch -ErrorAction Stop') -and
    $recoveryText.Contains('Get-VMNetworkAdapter -All -ErrorAction Stop') -and
    $recoveryText.Contains('Request-network orphan recovery failed closed:')
) 'Orphan recovery can ignore an authoritative lease or Hyper-V inventory failure.'
$scenarios.Add('orphan-recovery-inventory-fails-closed')
$cleanupKindIndex = $brokerText.IndexOf("elseif (`$cleanupFailureObserved)", [StringComparison]::Ordinal)
$cleanupFailedIndex = $brokerText.IndexOf("`$cleanupFailed = -not `$success", $cleanupKindIndex, [StringComparison]::Ordinal)
$finalStatusIndex = $brokerText.IndexOf("`$finalStatus = if (`$applicationTestFailed)", $cleanupFailedIndex, [StringComparison]::Ordinal)
Assert-True (
    $cleanupKindIndex -gt 0 -and
    $cleanupFailedIndex -gt $cleanupKindIndex -and
    $finalStatusIndex -gt $cleanupFailedIndex -and
    $brokerText.Contains("elseif (`$cancelled) { 'Cancelled' } elseif (`$executionTimedOut) { 'ExecutionTimedOut' } elseif (`$cleanupFailed) { 'Failed' }")
) 'Typed cancellation/timeout status is not preserved while cleanup failure remains visible.'
$scenarios.Add('disconnect-first-cleanup-before-terminal-result')

Assert-True ($moduleText.Contains('CohortHash = [string]$Runtime.CohortHash') -and $moduleText.Contains('InstallationScope = [string]$Runtime.InstallationScope') -and -not $moduleText.Contains('Cohort = [string]$Runtime.Cohort')) 'The SYSTEM-only lease does not use sanitized cohort and installation identities.'
Assert-True (-not $moduleText.Contains('Password =') -and -not $moduleText.Contains('Credential =')) 'Request-network state contains credential-shaped fields.'
$scenarios.Add('lease-state-is-sanitized')

$leaseAclCalls = [regex]::Matches($installerText, 'Set-BrokerAcl\s+-Path\s+\$requestNetworkLeaseRoot\s+-ClientMode\s+None')
Assert-True (
    $installerText.Contains("`$requestNetworkLeaseRoot = Join-Path `$BrokerRoot 'State\NetworkLeases'") -and
    $leaseAclCalls.Count -ge 2 -and
    $auditText.Contains("Path = Join-Path `$BrokerRoot 'State\NetworkLeases'; ClientMode = 'None'; ClientInherits = `$false")
) 'The request-network lease root is not kept confidential from the client ACL and audited as such.'
$scenarios.Add('lease-root-is-system-confidential')

$ownerStartUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
Assert-True (Test-RequestNetworkOwnerAlive -State ([pscustomobject]@{ OwnerProcessId = $PID; OwnerProcessStartUtc = $ownerStartUtc })) 'A lease owned by the current process was not recognized as live.'
Assert-True (-not (Test-RequestNetworkOwnerAlive -State ([pscustomobject]@{ OwnerProcessId = $PID; OwnerProcessStartUtc = '' }))) 'A lease with incomplete owner identity can suppress orphan cleanup.'
Assert-True (-not (Test-RequestNetworkOwnerAlive -State ([pscustomobject]@{ OwnerProcessId = $PID; OwnerProcessStartUtc = ([DateTime]::UtcNow.AddHours(-1).ToString('o')) }))) 'A lease with a mismatched owner start identity was treated as live.'
Assert-True (Test-RequestNetworkLeaseActive -State ([pscustomobject]@{ Status = 'Connected'; OwnerProcessId = $PID; OwnerProcessStartUtc = $ownerStartUtc })) 'A live Connected lease was not treated as active.'
Assert-True (-not (Test-RequestNetworkLeaseActive -State ([pscustomobject]@{ Status = 'CleanupFailed'; OwnerProcessId = $PID; OwnerProcessStartUtc = $ownerStartUtc }))) 'A live CleanupFailed lease was incorrectly treated as active.'

$leaseRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-request-network-safety-' + [Guid]::NewGuid().ToString('N'))
$leaseStateRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $leaseRoot
New-Item -ItemType Directory -Force -Path $leaseStateRoot | Out-Null
try {
    $liveLeaseState = [pscustomobject][ordered]@{
        RequestId = 'live-request'
        VmName = 'worker-01'
        VmId = 'vm-live'
        AdapterName = 'CodexRequestNet-live'
        SwitchId = 'switch-live'
        Status = 'Connected'
        OwnerProcessId = $PID
        OwnerProcessStartUtc = $ownerStartUtc
    }
    $leaseRuntime = [pscustomobject]@{ SwitchName = 'switch-live'; SwitchId = 'switch-live'; Profile = 'IsolatedTestNet' }
    $leaseVm = [pscustomobject]@{ Name = 'worker-01'; Id = 'vm-live' }
    $leaseAdapter = [pscustomobject]@{ VMName = 'worker-01'; Name = 'CodexRequestNet-live'; SwitchName = 'switch-live' }
    $connectedLeaseCount = & {
        param($LeaseRoot, $Runtime, $Vm, $Adapter, $LeaseState)
        function Get-RequestNetworkLeaseInventory {
            [CmdletBinding()]
            param([string]$BrokerRoot)
            $LeaseState
        }
        function Get-VM {
            [CmdletBinding()]
            param([string]$Name)
            $Vm
        }
        function Get-VMNetworkAdapter {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline = $true)] $InputObject,
                [string]$VMName
            )
            process { $Adapter }
        }
        Assert-RequestNetworkLeasedAttachments -Runtime $Runtime -BrokerRoot $LeaseRoot
    } $leaseRoot $leaseRuntime $leaseVm $leaseAdapter $liveLeaseState
    Assert-True ([int]$connectedLeaseCount -eq 1) 'A live Connected lease did not prove ownership and adapter status.'
    $scenarios.Add('connected-lease-requires-live-owner-and-status')

    $reservedLeaseState = [pscustomobject][ordered]@{
        RequestId = 'reserved-request'
        VmName = 'worker-01'
        VmId = 'vm-live'
        AdapterName = 'CodexRequestNet-live'
        SwitchId = 'switch-live'
        Status = 'Reserved'
        OwnerProcessId = $PID
        OwnerProcessStartUtc = $ownerStartUtc
    }
    $staleStatusError = & {
        param($LeaseRoot, $Runtime, $Vm, $Adapter, $LeaseState)
        function Get-RequestNetworkLeaseInventory {
            [CmdletBinding()]
            param([string]$BrokerRoot)
            $LeaseState
        }
        function Get-VM {
            [CmdletBinding()]
            param([string]$Name)
            $Vm
        }
        function Get-VMNetworkAdapter {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline = $true)] $InputObject,
                [string]$VMName
            )
            process { $Adapter }
        }
        try {
            Assert-RequestNetworkLeasedAttachments -Runtime $Runtime -BrokerRoot $LeaseRoot | Out-Null
            $null
        }
        catch { $_.Exception.Message }
    } $leaseRoot $leaseRuntime $leaseVm $leaseAdapter $reservedLeaseState
    Assert-True ([string]$staleStatusError -like '*stale or not in a connected state*') 'A non-connected lease status was accepted for a live adapter.'
}
finally {
    Remove-Item -LiteralPath $leaseRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# A terminal cleanup lease must be retried even when it still carries the
# current process identity. Keep a live active lease beside it to prove that
# the recovery pass does not broaden into deleting an in-flight request.
$sameProcessRecoveryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-request-network-same-process-' + [Guid]::NewGuid().ToString('N'))
$sameProcessLeaseRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $sameProcessRecoveryRoot
New-Item -ItemType Directory -Force -Path $sameProcessLeaseRoot | Out-Null
$sameProcessActivePath = Join-Path $sameProcessLeaseRoot 'active.json'
$sameProcessFailedPath = Join-Path $sameProcessLeaseRoot 'cleanup-failed.json'
$sameProcessLeaseCommon = [ordered]@{
    WorkerId = 1
    VmName = 'worker-01'
    VmId = 'vm-01'
    Profile = 'IsolatedTestNet'
    InstallationScope = 'scope'
    CohortHash = 'cohort'
    AdapterName = 'CodexRequestNet-test'
    AdapterMacAddress = '00155D010203'
    SwitchName = 'switch'
    SwitchId = 'switch-id'
    SwitchType = 'Private'
    SwitchOwned = $false
    GuestAddress = '10.254.0.101'
    PrefixLength = 24
    NetworkPrefix = '10.254.0.0/24'
    GatewayAddress = ''
    GatewayMacAddress = ''
    GatewayInterfaceIndex = 0
    GatewayInterfaceGuid = ''
    PrimaryVlanId = 0
    SecondaryVlanId = 0
    NatName = ''
    NatPrefix = ''
    NatPolicy = $null
    DnsServers = @()
    EnforcedLocalAddress = ''
    ExtendedAclIdleSessionTimeout = 0
    ExtendedAclWeights = $null
    AllowedRemoteAddress = ''
    AllowedRemoteMacAddress = ''
    DenyRemotePrefixes = @()
    ExpectedNetAdapterInterfaceGuid = ''
    ExpectedNetAdapterInterfaceDescription = ''
    ExpectedAllowManagementOS = $null
    OwnerProcessId = $PID
    OwnerProcessStartUtc = $ownerStartUtc
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    CleanupErrors = @('first cleanup failed')
}
$activeLease = [ordered]@{ RequestId = 'active-same-process'; Status = 'Connected' } + $sameProcessLeaseCommon
$failedLease = [ordered]@{ RequestId = 'cleanup-failed-same-process'; Status = 'CleanupFailed' } + $sameProcessLeaseCommon
$activeLease['VmName'] = 'worker-active'
$activeLease['VmId'] = 'vm-active'
$activeLease['AdapterName'] = 'CodexRequestNet-active'
$activeLease | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sameProcessActivePath -Encoding UTF8
$failedLease | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sameProcessFailedPath -Encoding UTF8
try {
    $sameProcessRecovery = & {
        param($BrokerRoot, $ActivePath, $FailedPath)
        function Remove-RequestNetworkRuntime {
            [CmdletBinding()]
            param($Runtime, [string]$BrokerRoot, [switch]$SuppressErrors)
            Remove-Item -LiteralPath ([string]$Runtime.StatePath) -Force -ErrorAction Stop
            [pscustomobject]@{ Success = $true; Errors = @() }
        }
        function Get-VMSwitch {
            [CmdletBinding()]
            param([string]$Name)
            @()
        }
        $result = @(Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot)
        [pscustomobject][ordered]@{
            Result = $result
            ActiveStillPresent = Test-Path -LiteralPath $ActivePath -PathType Leaf
            FailedStillPresent = Test-Path -LiteralPath $FailedPath -PathType Leaf
        }
    } $sameProcessRecoveryRoot $sameProcessActivePath $sameProcessFailedPath
    Assert-True ([bool]$sameProcessRecovery.ActiveStillPresent) 'Same-process recovery removed a live active-request lease.'
    Assert-True (-not [bool]$sameProcessRecovery.FailedStillPresent) 'Same-process recovery did not retry a terminal CleanupFailed lease.'
    Assert-True (@($sameProcessRecovery.Result | Where-Object { $_.RequestId -eq 'cleanup-failed-same-process' -and $_.Success }).Count -eq 1) 'Same-process terminal cleanup retry did not report success.'
    $scenarios.Add('same-process-terminal-cleanup-retries-but-active-lease-survives')
}
finally {
    Remove-Item -LiteralPath $sameProcessRecoveryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Exercise preparation/recycle and orphan recovery against a deterministic
# in-memory Hyper-V inventory. The active lease owns one adapter on worker-01;
# a same-named adapter on worker-02 has no lease and is the only orphan that
# may be removed.
$ownershipRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-request-network-owner-bound-' + [Guid]::NewGuid().ToString('N'))
$ownershipLeaseRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $ownershipRoot
$ownershipConfigRoot = Join-Path $ownershipRoot 'Private'
$ownershipConfigPath = Join-Path $ownershipConfigRoot 'config.json'
New-Item -ItemType Directory -Force -Path $ownershipLeaseRoot,$ownershipConfigRoot | Out-Null
$ownershipState = [ordered]@{
    RequestId = 'owner-bound-live'
    VmName = 'worker-01'
    VmId = 'vm-01'
    AdapterName = 'CodexRequestNet-live'
    SwitchId = 'switch-live'
    Status = 'Connected'
    OwnerProcessId = $PID
    OwnerProcessStartUtc = $ownerStartUtc
}
$ownershipStatePath = Join-Path $ownershipLeaseRoot 'owner-bound-live.json'
$ownershipState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownershipStatePath -Encoding UTF8
[ordered]@{
    VmName = ''
    PoolWorkers = @([ordered]@{ VmName = 'worker-01' }, [ordered]@{ VmName = 'worker-02' })
    RequestNetworkPolicy = Get-RequestNetworkDefaultPolicy
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ownershipConfigPath -Encoding UTF8
$ownershipModel = @{
    Vms = @(
        [pscustomobject]@{ Name = 'worker-01'; Id = 'vm-01' },
        [pscustomobject]@{ Name = 'worker-02'; Id = 'vm-02' }
    )
    Adapters = New-Object Collections.ArrayList
    DisconnectCount = 0
    RemoveCount = 0
}
[void]$ownershipModel.Adapters.Add([pscustomobject]@{ VMName = 'worker-01'; Name = 'CodexRequestNet-live'; SwitchName = 'switch-live' })
[void]$ownershipModel.Adapters.Add([pscustomobject]@{ VMName = 'worker-02'; Name = 'CodexRequestNet-live'; SwitchName = 'switch-orphan' })
try {
    $ownershipResult = & {
        param($BrokerRoot, $Model)
        function Get-VM {
            [CmdletBinding()]
            param([string]$Name)
            if ([string]::IsNullOrWhiteSpace($Name)) { @($Model.Vms) } else { @($Model.Vms | Where-Object { $_.Name -eq $Name }) }
        }
        function Get-VMNetworkAdapter {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline = $true)] $InputObject,
                [string]$VMName,
                [switch]$All
            )
            process {
                if ($All) { @($Model.Adapters); return }
                $target = if (-not [string]::IsNullOrWhiteSpace($VMName)) { $VMName } elseif ($InputObject) { [string]$InputObject.Name } else { $null }
                if ([string]::IsNullOrWhiteSpace($target)) { @($Model.Adapters) } else { @($Model.Adapters | Where-Object { $_.VMName -eq $target }) }
            }
        }
        function Disconnect-VMNetworkAdapter {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)] $VMNetworkAdapter)
            $VMNetworkAdapter.SwitchName = ''
            $Model.DisconnectCount++
        }
        function Remove-VMNetworkAdapter {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)] $VMNetworkAdapter)
            [void]$Model.Adapters.Remove($VMNetworkAdapter)
            $Model.RemoveCount++
        }
        function Get-VMSwitch {
            [CmdletBinding()]
            param()
            @()
        }
        $recovery = @(Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot)
        $preparation = Remove-ManagedRequestNetworkAdapters -VmName 'worker-01' -BrokerRoot $BrokerRoot
        [pscustomobject][ordered]@{
            Recovery = $recovery
            Preparation = $preparation
            ActivePresent = @($Model.Adapters | Where-Object { $_.VMName -eq 'worker-01' -and $_.Name -eq 'CodexRequestNet-live' }).Count -eq 1
            OrphanPresent = @($Model.Adapters | Where-Object { $_.VMName -eq 'worker-02' -and $_.Name -eq 'CodexRequestNet-live' }).Count -eq 1
            DisconnectCount = [int]$Model.DisconnectCount
            RemoveCount = [int]$Model.RemoveCount
        }
    } $ownershipRoot $ownershipModel
    Assert-True ([bool]$ownershipResult.ActivePresent -and -not [bool]$ownershipResult.OrphanPresent) 'Owner-bound orphan recovery removed the active lease adapter or retained the unowned orphan.'
    Assert-True (@($ownershipResult.Recovery | Where-Object { $_.Success }).Count -eq 1) 'Owner-bound orphan recovery did not report the exact orphan cleanup.'
    Assert-True ([int]$ownershipResult.Preparation.SkippedActiveAdapters.Count -eq 1 -and [int]$ownershipResult.RemoveCount -eq 1) 'Preparation did not preserve an active lease adapter after recycle cleanup.'
    $scenarios.Add('active-lease-survives-preparation-and-owner-bound-orphan-recovery')

    $ambiguousState = $ownershipState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $ambiguousState.RequestId = 'owner-bound-ambiguous'
    $ambiguousPath = Join-Path $ownershipLeaseRoot 'owner-bound-ambiguous.json'
    $ambiguousState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ambiguousPath -Encoding UTF8
    $ambiguousError = & {
        param($BrokerRoot, $Model)
        function Get-VM { [CmdletBinding()] param([string]$Name); @($Model.Vms | Where-Object { [string]::IsNullOrWhiteSpace($Name) -or $_.Name -eq $Name }) }
        function Get-VMNetworkAdapter { [CmdletBinding()] param([string]$VMName); @($Model.Adapters | Where-Object { $_.VMName -eq $VMName }) }
        function Disconnect-VMNetworkAdapter { [CmdletBinding()] param($VMNetworkAdapter); throw 'unexpected disconnect' }
        function Remove-VMNetworkAdapter { [CmdletBinding()] param($VMNetworkAdapter); throw 'unexpected remove' }
        try { Remove-ManagedRequestNetworkAdapters -VmName 'worker-01' -BrokerRoot $BrokerRoot | Out-Null; $null } catch { $_.Exception.Message }
    } $ownershipRoot $ownershipModel
    Assert-True ([string]$ambiguousError -like '*ambiguous lease ownership*' -and [bool]$ownershipResult.ActivePresent) 'Ambiguous lease ownership did not fail closed before adapter mutation.'
    $scenarios.Add('ambiguous-lease-ownership-fails-closed')

    $missingInventoryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-request-network-owner-missing-' + [Guid]::NewGuid().ToString('N'))
    try {
        $missingError = & {
            param($BrokerRoot, $Model)
            function Get-VM { [CmdletBinding()] param([string]$Name); @($Model.Vms | Where-Object { $_.Name -eq $Name }) }
            function Get-VMNetworkAdapter { [CmdletBinding()] param([string]$VMName); @($Model.Adapters | Where-Object { $_.VMName -eq $VMName }) }
            function Disconnect-VMNetworkAdapter { [CmdletBinding()] param($VMNetworkAdapter); throw 'unexpected disconnect' }
            function Remove-VMNetworkAdapter { [CmdletBinding()] param($VMNetworkAdapter); throw 'unexpected remove' }
            try { Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot | Out-Null; $null } catch { $_.Exception.Message }
        } $missingInventoryRoot $ownershipModel
        Assert-True ([string]$missingError -like '*authoritative request-network lease inventory is missing*' -and [int]$ownershipModel.RemoveCount -eq 1) 'A missing authoritative lease inventory did not fail closed before orphan mutation.'
        $scenarios.Add('missing-lease-inventory-fails-closed')
    }
    finally {
        Remove-Item -LiteralPath $missingInventoryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $ownershipRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True (
    $moduleText.Contains("Status -notin @('Connected', 'GuestNetworkReady')") -and
    $moduleText.Contains('Test-RequestNetworkOwnerAlive -State $matchingLeases[0]')
) 'Connected request-network attachments are not bound to a live lease owner and status.'

Assert-True ($moduleText.Contains('BoundaryAttested = $true') -and $moduleText.Contains('did not attest exactly the configured IPv4 address and prefix') -and $moduleText.Contains('did not attest a disabled IPv6 binding') -and $moduleText.Contains('permanent pinned gateway neighbor')) 'Guest networking does not require exact address, IPv6, route, DNS, and neighbor attestation.'
Assert-True (
    $moduleText.Contains('Get-RequestNetworkExpectedGuestRoutePrefixes') -and
    $moduleText.Contains('$connectedRoutes') -and
    $moduleText.Contains('$unexpectedRoutes') -and
    $moduleText.Contains('did not attest only the expected connected subnet routes') -and
    $moduleText.Contains('Routes = @($routes') -and
    $moduleText.Contains('ConnectedRoutes = @($connectedRoutes')
) 'Guest route attestation does not reject extra routes or return the exact route set.'
$scenarios.Add('guest-routes-are-exact-and-returned')
$residueCleanupStart = $moduleText.IndexOf('function Reset-GuestRequestNetworkResidue', [StringComparison]::Ordinal)
$residuePersistentQuery = $moduleText.IndexOf("Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue -ErrorVariable +routeErrors", $residueCleanupStart, [StringComparison]::Ordinal)
$residueExactGateway = $moduleText.IndexOf('[string]::Equals([string]$_.NextHop, $PinnedGatewayAddress, [StringComparison]::Ordinal)', $residuePersistentQuery, [StringComparison]::Ordinal)
$residueNotFoundId = $moduleText.IndexOf("`$fullyQualifiedErrorId.StartsWith('CmdletizationQuery_NotFound'", $residueExactGateway, [StringComparison]::Ordinal)
$residueNotFoundCategory = $moduleText.IndexOf("[string]::Equals(`$category, 'ObjectNotFound'", $residueNotFoundId, [StringComparison]::Ordinal)
$residueNotFoundReason = $moduleText.IndexOf("[string]::Equals(`$reason, 'CimJobException'", $residueNotFoundCategory, [StringComparison]::Ordinal)
$residueNotFoundTarget = $moduleText.IndexOf("`$targetName -in @('IPv4', 'MSFT_NetRoute')", $residueNotFoundReason, [StringComparison]::Ordinal)
$residueUnexpectedFailure = $moduleText.IndexOf('$unexpectedErrors.Count -gt 0', $residueNotFoundTarget, [StringComparison]::Ordinal)
$residueRemove = $moduleText.IndexOf('Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop', $residueExactGateway, [StringComparison]::Ordinal)
$residueRequery = $moduleText.IndexOf('Get-BrokerOwnedPersistentDefaultRoute', $residueRemove, [StringComparison]::Ordinal)
Assert-True (
    $residueCleanupStart -ge 0 -and
    $residuePersistentQuery -gt $residueCleanupStart -and
    $residueExactGateway -gt $residuePersistentQuery -and
    $residueNotFoundId -gt $residueExactGateway -and
    $residueNotFoundCategory -gt $residueNotFoundId -and
    $residueNotFoundReason -gt $residueNotFoundCategory -and
    $residueNotFoundTarget -gt $residueNotFoundReason -and
    $residueUnexpectedFailure -gt $residueNotFoundTarget -and
    $residueRemove -gt $residueUnexpectedFailure -and
    $residueRequery -gt $residueRemove -and
    $brokerText.Contains('ResidueCleanup = $requestNetworkResidueCleanup')
) 'Guest residue cleanup is not limited to the exact broker-owned persistent InternetOnly default route or is not attested.'
$scenarios.Add('guest-persistent-route-residue-is-exact-and-attested')
$guestInitStart = $moduleText.IndexOf('function Initialize-GuestRequestNetwork', [StringComparison]::Ordinal)
$guestJob = $moduleText.IndexOf('Invoke-Command -Session $Session -AsJob -ErrorAction Stop', $guestInitStart, [StringComparison]::Ordinal)
$guestPreCheck = $moduleText.IndexOf('if ($ActivityCheck) { & $ActivityCheck }', $guestInitStart, [StringComparison]::Ordinal)
$guestWait = $moduleText.IndexOf('while ([string]$remoteJob.State -in @(''NotStarted'', ''Running''))', $guestJob, [StringComparison]::Ordinal)
$guestLoopCheck = $moduleText.IndexOf('if ($ActivityCheck) { & $ActivityCheck }', $guestWait, [StringComparison]::Ordinal)
$guestFinally = $moduleText.IndexOf('finally {', $guestWait, [StringComparison]::Ordinal)
$guestStop = $moduleText.IndexOf('Stop-Job -Job $remoteJob', $guestFinally, [StringComparison]::Ordinal)
$guestRemove = $moduleText.IndexOf('Remove-Job -Job $remoteJob -Force', $guestFinally, [StringComparison]::Ordinal)
Assert-True (
    $guestInitStart -ge 0 -and
    $guestPreCheck -gt $guestInitStart -and
    $guestPreCheck -lt $guestJob -and
    $guestJob -gt $guestPreCheck -and
    $guestWait -gt $guestJob -and
    $guestLoopCheck -gt $guestWait -and
    $guestFinally -gt $guestWait -and
    $guestStop -gt $guestFinally -and
    $guestRemove -gt $guestStop
) 'Guest network initialization is not cancellation-aware while the remote job is pending.'
$networkLoop = $brokerText.IndexOf('while ($true)', $brokerText.IndexOf('$nextNetworkHostPolicyCheckUtc', [StringComparison]::Ordinal), [StringComparison]::Ordinal)
$networkLoopCheck = $brokerText.IndexOf('if ($requestNetworkRuntime -and [DateTime]::UtcNow -ge $nextNetworkHostPolicyCheckUtc)', $networkLoop, [StringComparison]::Ordinal)
$networkLoopAssert = $brokerText.IndexOf('Assert-RequestNetworkHostPolicyCurrent -Runtime $requestNetworkRuntime -BrokerRoot $BrokerRoot', $networkLoopCheck, [StringComparison]::Ordinal)
$networkLoopRefresh = $brokerText.IndexOf('$nextNetworkHostPolicyCheckUtc = [DateTime]::UtcNow.AddSeconds(2)', $networkLoopAssert, [StringComparison]::Ordinal)
$networkSubmit = $brokerText.IndexOf('Write-JsonAtomic -Path $guestJobPath -Value $job', [StringComparison]::Ordinal)
$networkCleanup = $brokerText.IndexOf('Remove-RequestNetworkRuntime -Runtime $requestNetworkRuntime', [StringComparison]::Ordinal)
if (-not (
    $brokerText.Contains('Initialize-GuestRequestNetwork -Session $session -Runtime $requestNetworkRuntime -ActivityCheck $activityCheck') -and
    $networkLoop -gt 0 -and
    $networkLoopCheck -gt $networkLoop -and
    $networkLoopAssert -gt $networkLoopCheck -and
    $networkLoopRefresh -gt $networkLoopAssert -and
    $networkSubmit -gt 0 -and
    $networkLoop -gt $networkSubmit -and
    $brokerText.Contains('HostPolicyChecks =') -and
    $networkCleanup -gt $networkSubmit
)) {
    throw "Cancellation-aware guest setup or periodic host-policy revalidation is not integrated: loop=$networkLoop, check=$networkLoopCheck, assert=$networkLoopAssert, refresh=$networkLoopRefresh, submit=$networkSubmit, cleanup=$networkCleanup."
}
$scenarios.Add('continuous-boundary-and-guest-attestation')
$scenarios.Add('guest-init-cancellation-and-periodic-host-policy-checks')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
