function Get-RequestNetworkLeaseRoot {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    Join-Path $BrokerRoot 'State\NetworkLeases'
}

function Get-RequestNetworkLeaseInventory {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $leaseRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $BrokerRoot
    if (-not (Test-Path -LiteralPath $leaseRoot -PathType Container -ErrorAction Stop)) {
        throw "The authoritative request-network lease inventory is missing: $leaseRoot"
    }
    $requestIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $adapterOwners = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    @(
        Get-ChildItem -LiteralPath $leaseRoot -Filter '*.json' -File -ErrorAction Stop | ForEach-Object {
            $leasePath = $_.FullName
            try {
                $state = Get-Content -Raw -LiteralPath $leasePath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $state) { throw 'The lease record is empty.' }
                foreach ($field in @('RequestId', 'VmName', 'VmId', 'AdapterName', 'Status', 'OwnerProcessId', 'OwnerProcessStartUtc')) {
                    $property = $state.PSObject.Properties[$field]
                    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                        throw "The lease record is missing its required $field ownership field."
                    }
                }
                $requestId = [string]$state.RequestId
                $vmName = [string]$state.VmName
                $adapterName = [string]$state.AdapterName
                if ($adapterName -notlike 'CodexRequestNet-*') { throw 'The lease record names an unmanaged adapter.' }
                if ([string]$state.Status -notin @('Reserved', 'AdapterSecured', 'Connected', 'GuestNetworkReady', 'CleanupFailed')) {
                    throw "The lease record has an unsupported ownership status: $($state.Status)"
                }
                if ($state.OwnerProcessId -is [bool] -or ($state.OwnerProcessId -isnot [int] -and $state.OwnerProcessId -isnot [long]) -or [int64]$state.OwnerProcessId -le 0) {
                    throw 'The lease record has an invalid owner process identity.'
                }
                try {
                    [void][DateTime]::Parse([string]$state.OwnerProcessStartUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                }
                catch { throw 'The lease record has an invalid owner process start identity.' }
                if (-not $requestIds.Add($requestId)) { throw "The request-network lease owner '$requestId' is ambiguous." }
                if (-not $adapterOwners.Add($vmName + "`n" + $adapterName)) {
                    throw "The request-network adapter '$adapterName' on VM '$vmName' has ambiguous lease ownership."
                }
                if ($state.PSObject.Properties['StatePath']) {
                    if (-not [string]::Equals([string]$state.StatePath, $leasePath, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "The request-network lease '$leasePath' contains an unexpected StatePath owner."
                    }
                    $state.StatePath = $leasePath
                }
                else {
                    $state | Add-Member -NotePropertyName StatePath -NotePropertyValue $leasePath
                }
                $state
            }
            catch { throw "Could not validate request-network lease '$leasePath': $($_.Exception.Message)" }
        }
    )
}

function Get-RequestNetworkDefaultPolicy {
    [pscustomobject][ordered]@{
        FormatVersion = 1
        DefaultProfile = 'None'
        IsolatedTestNet = [pscustomobject][ordered]@{
            Enabled = $true
            SwitchPrefix = 'Codex-Harness-TestNet'
            NetworkPrefix = '10.254.0.0/24'
        }
        InternetOnly = [pscustomobject][ordered]@{
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
        TrustedLan = [pscustomobject][ordered]@{
            Enabled = $false
            AllowedSwitches = @()
        }
    }
}

function Get-RequestNetworkPolicy {
    param([Parameter(Mandatory = $true)] $Config)

    $policy = Get-RequestNetworkObjectPropertyValue -Value $Config -Name 'RequestNetworkPolicy'
    if (-not $policy) {
        $policy = Get-RequestNetworkDefaultPolicy
        $null = Assert-RequestNetworkPolicySchema -Policy $policy
        return $policy
    }
    if ([int]$policy.FormatVersion -ne 1) {
        throw "Unsupported request-network policy version: $($policy.FormatVersion)"
    }
    if (-not [string]::Equals([string]$policy.DefaultProfile, 'None', [StringComparison]::Ordinal)) {
        throw 'RequestNetworkPolicy.DefaultProfile must remain None.'
    }
    $null = Assert-RequestNetworkPolicySchema -Policy $policy
    $policy
}

function Assert-RequestNetworkPolicyEnabledFlags {
    param([Parameter(Mandatory = $true)] $Policy)

    foreach ($profileName in @('IsolatedTestNet', 'InternetOnly', 'TrustedLan')) {
        $settings = Get-RequestNetworkObjectPropertyValue -Value $Policy -Name $profileName
        if (-not $settings) {
            throw "RequestNetworkPolicy.$profileName is missing."
        }
        $enabled = Get-RequestNetworkObjectPropertyValue -Value $settings -Name 'Enabled'
        if ($enabled -isnot [bool]) {
            throw "RequestNetworkPolicy.$profileName.Enabled must be an exact JSON Boolean."
        }
    }
    $true
}

function Assert-RequestNetworkExactProperties {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)] [string[]] $Expected,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $actual = @(Get-RequestNetworkObjectPropertyNames -Value $Value | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if (($actual -join "`n") -ne ($expectedSorted -join "`n")) {
        throw "$Context must contain exactly these properties: $($Expected -join ', ')."
    }
}

function Assert-RequestNetworkExactInteger {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Context,
        [long] $Minimum = [long]::MinValue,
        [long] $Maximum = [long]::MaxValue
    )

    $isInteger = $null -ne $Value -and $Value -isnot [bool] -and (
        $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    )
    if (-not $isInteger) { throw "$Context must be an exact JSON integer." }
    try {
        $numeric = [decimal]$Value
        if ($numeric -lt [decimal]$Minimum -or $numeric -gt [decimal]$Maximum) {
            throw 'outside bounds'
        }
    }
    catch { throw "$Context must be an integer between $Minimum and $Maximum." }
    [long]$Value
}

function Assert-RequestNetworkPolicySchema {
    param([Parameter(Mandatory = $true)] $Policy)

    Assert-RequestNetworkExactProperties -Value $Policy -Expected @('FormatVersion', 'DefaultProfile', 'IsolatedTestNet', 'InternetOnly', 'TrustedLan') -Context 'RequestNetworkPolicy'
    $formatVersion = Assert-RequestNetworkExactInteger -Value $Policy.FormatVersion -Context 'RequestNetworkPolicy.FormatVersion' -Minimum 1 -Maximum 1
    if ($formatVersion -ne 1) { throw "Unsupported request-network policy version: $($Policy.FormatVersion)" }
    if (-not [string]::Equals([string]$Policy.DefaultProfile, 'None', [StringComparison]::Ordinal)) {
        throw 'RequestNetworkPolicy.DefaultProfile must remain None.'
    }
    $null = Assert-RequestNetworkPolicyEnabledFlags -Policy $Policy

    $isolated = $Policy.IsolatedTestNet
    Assert-RequestNetworkExactProperties -Value $isolated -Expected @('Enabled', 'SwitchPrefix', 'NetworkPrefix') -Context 'RequestNetworkPolicy.IsolatedTestNet'
    if ([string]::IsNullOrWhiteSpace([string]$isolated.SwitchPrefix) -or [string]$isolated.SwitchPrefix -notmatch '^[A-Za-z0-9._-]{1,80}$') {
        throw 'RequestNetworkPolicy.IsolatedTestNet.SwitchPrefix is invalid.'
    }
    $null = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$isolated.NetworkPrefix) -Context 'RequestNetworkPolicy.IsolatedTestNet.NetworkPrefix'

    $internet = $Policy.InternetOnly
    $internetProperties = @(
        'Enabled', 'SwitchName', 'SwitchId', 'NatName', 'NatPrefix', 'ExternalIPInterfaceAddressPrefix',
        'InternalRoutingDomainId', 'TcpFilteringBehavior', 'UdpFilteringBehavior', 'UdpInboundRefresh',
        'TcpEstablishedConnectionTimeout', 'TcpTransientConnectionTimeout', 'UdpIdleSessionTimeout',
        'IcmpQueryTimeout', 'GatewayAddress', 'PrefixLength', 'PrimaryVlanId', 'SecondaryVlanId',
        'DnsServers', 'DenyRemotePrefixes'
    )
    Assert-RequestNetworkExactProperties -Value $internet -Expected $internetProperties -Context 'RequestNetworkPolicy.InternetOnly'
    if ($internet.UdpInboundRefresh -isnot [bool]) { throw 'RequestNetworkPolicy.InternetOnly.UdpInboundRefresh must be an exact JSON Boolean.' }
    $null = Assert-RequestNetworkExactInteger -Value $internet.PrefixLength -Context 'RequestNetworkPolicy.InternetOnly.PrefixLength' -Minimum 24 -Maximum 24
    $null = Get-RequestNetworkExpectedNatPolicy -Settings $internet
    if ([bool]$internet.Enabled) {
        foreach ($name in @('SwitchName', 'SwitchId', 'NatName', 'NatPrefix', 'GatewayAddress')) {
            if ([string]::IsNullOrWhiteSpace([string]$internet.$name)) { throw "Enabled InternetOnly requires $name." }
        }
        try { [void][Guid]::Parse([string]$internet.SwitchId) } catch { throw 'InternetOnly.SwitchId must be a valid GUID.' }
        $network = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$internet.NatPrefix) -Context 'RequestNetworkPolicy.InternetOnly.NatPrefix'
        if ([string]$internet.GatewayAddress -notmatch ('^' + [regex]::Escape($network.Base) + '\.(?:[1-9]|[1-9]\d|1\d\d|2[0-4]\d|25[0-4])$')) {
            throw 'Enabled InternetOnly requires a usable /24 gateway address in NatPrefix.'
        }
        $null = Get-RequestNetworkInternetVlanSettings -Settings $internet
        $dnsServers = @($internet.DnsServers)
        if ($dnsServers.Count -lt 1) { throw 'Enabled InternetOnly requires at least one public IPv4 DNS server.' }
        $canonicalDenies = @(Get-RequestNetworkCanonicalInternetDenyPrefixes)
        foreach ($dnsServer in $dnsServers) {
            try { $dnsAddress = [Net.IPAddress]::Parse([string]$dnsServer) } catch { throw "InternetOnly DNS server is not an IP address: $dnsServer" }
            if ($dnsAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
                @($canonicalDenies | Where-Object { $_ -notlike '*:*' -and (Test-RequestNetworkIPv4InPrefix -Address ([string]$dnsServer) -Prefix $_) }).Count -gt 0) {
                throw "InternetOnly DNS server must be a public IPv4 address: $dnsServer"
            }
        }
        foreach ($prefix in @($internet.DenyRemotePrefixes)) {
            $null = ConvertTo-RequestNetworkCanonicalAclAddress -Address ([string]$prefix)
        }
    }

    $trusted = $Policy.TrustedLan
    Assert-RequestNetworkExactProperties -Value $trusted -Expected @('Enabled', 'AllowedSwitches') -Context 'RequestNetworkPolicy.TrustedLan'
    $allowed = @($trusted.AllowedSwitches | Where-Object { $null -ne $_ })
    if ($allowed.Count -gt 1 -or ([bool]$trusted.Enabled -and $allowed.Count -ne 1)) {
        throw 'TrustedLan requires exactly one broker-pinned allowed switch when enabled and permits at most one while disabled.'
    }
    foreach ($entry in $allowed) {
        Assert-RequestNetworkExactProperties -Value $entry -Expected @('Name', 'Id', 'NetAdapterInterfaceGuid', 'NetAdapterInterfaceDescription', 'AllowManagementOS') -Context 'RequestNetworkPolicy.TrustedLan.AllowedSwitches[]'
        if ([string]::IsNullOrWhiteSpace([string]$entry.Name) -or ([string]$entry.Name).Length -gt 128 -or
            [string]::IsNullOrWhiteSpace([string]$entry.NetAdapterInterfaceDescription) -or $entry.AllowManagementOS -isnot [bool]) {
            throw 'TrustedLan allowed switch has an invalid name, physical-interface description, or AllowManagementOS value.'
        }
        foreach ($guidField in @('Id', 'NetAdapterInterfaceGuid')) {
            try { [void][Guid]::Parse([string]$entry.$guidField) } catch { throw "TrustedLan allowed switch $guidField must be a valid GUID." }
        }
    }
    $true
}

function Get-RequestNetworkObjectPropertyNames {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-RequestNetworkObjectPropertyValue {
    param(
        $Value,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Get-RequestNetworkHash {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-RequestNetworkInstallationScope {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $canonicalRoot = [IO.Path]::GetFullPath($BrokerRoot).TrimEnd('\').ToUpperInvariant()
    (Get-RequestNetworkHash -Value $canonicalRoot).Substring(0, 10)
}

function Test-RequestNetworkOwnerAlive {
    param($State)

    if (-not $State -or [int]$State.OwnerProcessId -le 0) { return $false }
    $process = Get-Process -Id ([int]$State.OwnerProcessId) -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$State.OwnerProcessStartUtc)) { return $false }
    try {
        $rawStart = $State.OwnerProcessStartUtc
        $expected = if ($rawStart -is [DateTime]) {
            ([DateTime]$rawStart).ToUniversalTime()
        }
        elseif ($rawStart -is [DateTimeOffset]) {
            ([DateTimeOffset]$rawStart).UtcDateTime
        }
        else {
            [DateTime]::Parse([string]$rawStart, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 2
    }
    catch { $false }
}

function Test-RequestNetworkLeaseActive {
    param($State)

    if (-not $State -or [string]$State.Status -notin @('Reserved', 'AdapterSecured', 'Connected', 'GuestNetworkReady')) {
        return $false
    }
    Test-RequestNetworkOwnerAlive -State $State
}

function Test-RequestNetworkIPv4PrefixCovered {
    param(
        [Parameter(Mandatory = $true)] [string] $CandidatePrefix,
        [Parameter(Mandatory = $true)] [string] $CoveringPrefix
    )

    $prefixPattern = '\A(?<address>[0-9.]+)/(?<length>[0-9]{1,2})\z'
    $candidateMatch = [regex]::Match($CandidatePrefix, $prefixPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $coverMatch = [regex]::Match($CoveringPrefix, $prefixPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $candidateMatch.Success -or -not $coverMatch.Success) { return $false }
    $candidateAddress = [string]$candidateMatch.Groups['address'].Value
    $candidateLength = [int]$candidateMatch.Groups['length'].Value
    $coverLength = [int]$coverMatch.Groups['length'].Value
    if ([string]$candidateMatch.Groups['length'].Value -cne $candidateLength.ToString([Globalization.CultureInfo]::InvariantCulture) -or
        [string]$coverMatch.Groups['length'].Value -cne $coverLength.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        return $false
    }
    if ($candidateLength -lt 0 -or $candidateLength -gt 32 -or $coverLength -lt 0 -or $coverLength -gt 32 -or $coverLength -gt $candidateLength) {
        return $false
    }
    Test-RequestNetworkIPv4InPrefix -Address $candidateAddress -Prefix $CoveringPrefix
}

function Test-RequestNetworkBidirectionalDirections {
    param([string[]] $Directions)

    ($Directions.Count -eq 1 -and $Directions[0] -eq 'Both') -or
        ($Directions.Count -eq 2 -and $Directions -contains 'Inbound' -and $Directions -contains 'Outbound')
}

function Get-RequestNetworkIpAclAddressType {
    param([Parameter(Mandatory = $true)] [string] $Address)

    if ([string]::Equals($Address, '0.0.0.0/0', [StringComparison]::OrdinalIgnoreCase)) { return 'WildcardIPv4' }
    if ([string]::Equals($Address, '::/0', [StringComparison]::OrdinalIgnoreCase)) { return 'WildcardIPv6' }
    if ($Address.Contains(':')) { return 'IPv6' }
    'IPv4'
}

function ConvertTo-RequestNetworkCanonicalAclAddress {
    param(
        [string] $Address,
        [Parameter(Mandatory = $true)] [string] $AddressType
    )

    if ($AddressType -in @('Mac', 'WildcardMac')) {
        if ([string]::Equals($Address, 'ANY', [StringComparison]::OrdinalIgnoreCase)) { return 'ANY' }
        return (($Address -replace '[:-]', '').ToUpperInvariant())
    }
    $Address
}

function Get-RequestNetworkInternetVlanSettings {
    param([Parameter(Mandatory = $true)] $Settings)

    foreach ($property in @('PrimaryVlanId', 'SecondaryVlanId')) {
        if (-not (Get-RequestNetworkObjectPropertyNames -Value $Settings | Where-Object { $_ -eq $property })) {
            throw "InternetOnly policy is missing the pinned $property value."
        }
        $value = Get-RequestNetworkObjectPropertyValue -Value $Settings -Name $property
        $null = Assert-RequestNetworkExactInteger -Value $value -Context "InternetOnly.$property" -Minimum 1 -Maximum 4094
    }
    $primary = [int](Get-RequestNetworkObjectPropertyValue -Value $Settings -Name 'PrimaryVlanId')
    $secondary = [int](Get-RequestNetworkObjectPropertyValue -Value $Settings -Name 'SecondaryVlanId')
    if ($primary -eq $secondary) { throw 'InternetOnly.PrimaryVlanId and SecondaryVlanId must be different.' }
    [pscustomobject][ordered]@{
        PrimaryVlanId = $primary
        SecondaryVlanId = $secondary
    }
}

function Get-RequestNetworkInternetExtendedAclWeights {
    [pscustomobject][ordered]@{
        DefaultDenyWeight = 100
        SourceTcpAllowWeight = 10000
        SourceUdpAllowWeight = 10001
        DenyPrefixWeightBase = 20000
        MaximumWeight = 65535
        StatelessIdleSessionTimeout = 0
    }
}

function Get-RequestNetworkInternetExtendedAclRules {
    param(
        [Parameter(Mandatory = $true)] $Runtime
    )

    $localAddress = [string]$Runtime.EnforcedLocalAddress
    if ($localAddress -notmatch '^(?<address>[^/]+)/32$') {
        throw 'InternetOnly extended ACLs require an exact guest IPv4 /32 source address.'
    }
    try {
        $parsedLocalAddress = [Net.IPAddress]::Parse([string]$Matches.address)
        if ($parsedLocalAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'not IPv4' }
    }
    catch { throw 'InternetOnly extended ACLs require an exact guest IPv4 /32 source address.' }
    $weights = Get-RequestNetworkInternetExtendedAclWeights
    $runtimeWeights = Get-RequestNetworkObjectPropertyValue -Value $Runtime -Name 'ExtendedAclWeights'
    if ($runtimeWeights) {
        foreach ($property in @('DefaultDenyWeight', 'SourceTcpAllowWeight', 'SourceUdpAllowWeight', 'DenyPrefixWeightBase', 'MaximumWeight', 'StatelessIdleSessionTimeout')) {
            $expectedWeight = [int]$weights.$property
            $actualWeight = Get-RequestNetworkObjectPropertyValue -Value $runtimeWeights -Name $property
            if ($null -eq $actualWeight -or [int]$actualWeight -ne $expectedWeight) {
                throw "InternetOnly extended ACL weight '$property' is not the broker-pinned value."
            }
        }
    }
    $statefulIdleTimeout = [int]$Runtime.ExtendedAclIdleSessionTimeout
    if ($statefulIdleTimeout -lt 10 -or $statefulIdleTimeout -gt 300) {
        throw 'InternetOnly extended ACL stateful idle timeout is outside the broker safety bound.'
    }
    $prefixes = [string[]]@(
        @($Runtime.DenyRemotePrefixes | ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    )
    [Array]::Sort($prefixes, [StringComparer]::OrdinalIgnoreCase)
    if ($prefixes.Count -gt ([int]$weights.MaximumWeight - [int]$weights.DenyPrefixWeightBase + 1)) {
        throw 'InternetOnly has too many denied prefixes for its bounded extended-ACL weight range.'
    }

    $rules = New-Object Collections.Generic.List[object]
    $defaultIdleTimeout = [int]$weights.StatelessIdleSessionTimeout
    $defaultWeight = [int]$weights.DefaultDenyWeight
    $rules.Add([pscustomobject][ordered]@{
        Direction = 'Outbound'; Action = 'Deny'; LocalIPAddress = 'ANY'; RemoteIPAddress = 'ANY'
        LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'ANY'; Weight = $defaultWeight
        Stateful = $false; IdleSessionTimeout = $defaultIdleTimeout; IsolationID = 0
    })
    $rules.Add([pscustomobject][ordered]@{
        Direction = 'Inbound'; Action = 'Deny'; LocalIPAddress = 'ANY'; RemoteIPAddress = 'ANY'
        LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'ANY'; Weight = $defaultWeight
        Stateful = $false; IdleSessionTimeout = $defaultIdleTimeout; IsolationID = 0
    })

    for ($index = 0; $index -lt $prefixes.Count; $index++) {
        $prefix = [string]$prefixes[$index]
        # A mixed IPv4 local address and IPv6 remote prefix is not a valid
        # 5-tuple. The default ANY/ANY deny already covers IPv6; use ANY for
        # the explicit IPv6 deny so the rule remains valid and auditable.
        $ruleLocalAddress = if ($prefix.Contains(':')) { 'ANY' } else { $localAddress }
        $rules.Add([pscustomobject][ordered]@{
            Direction = 'Outbound'; Action = 'Deny'; LocalIPAddress = $ruleLocalAddress; RemoteIPAddress = $prefix
            LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'ANY'; Weight = ([int]$weights.DenyPrefixWeightBase + $index)
            Stateful = $false; IdleSessionTimeout = $defaultIdleTimeout; IsolationID = 0
        })
    }

    $rules.Add([pscustomobject][ordered]@{
        Direction = 'Outbound'; Action = 'Allow'; LocalIPAddress = $localAddress; RemoteIPAddress = 'ANY'
        LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'TCP'; Weight = [int]$weights.SourceTcpAllowWeight
        Stateful = $true; IdleSessionTimeout = $statefulIdleTimeout; IsolationID = 0
    })
    $rules.Add([pscustomobject][ordered]@{
        Direction = 'Outbound'; Action = 'Allow'; LocalIPAddress = $localAddress; RemoteIPAddress = 'ANY'
        LocalPort = 'ANY'; RemotePort = 'ANY'; Protocol = 'UDP'; Weight = [int]$weights.SourceUdpAllowWeight
        Stateful = $true; IdleSessionTimeout = $statefulIdleTimeout; IsolationID = 0
    })
    @($rules.ToArray())
}

function ConvertTo-RequestNetworkExtendedAclCanonicalValue {
    param(
        [AllowNull()] [string] $Value,
        [switch] $Upper
    )

    if ($null -eq $Value) { return '' }
    $normalized = $Value.Trim()
    if ($Upper) { return $normalized.ToUpperInvariant() }
    $normalized
}

function ConvertTo-RequestNetworkExtendedAclDirection {
    param([Parameter(Mandatory = $true)] $Value)

    switch -CaseSensitive ([string]$Value) {
        '1' { 'Inbound'; break }
        'Inbound' { 'Inbound'; break }
        '2' { 'Outbound'; break }
        'Outbound' { 'Outbound'; break }
        default { throw "The Hyper-V provider returned an unsupported extended-ACL direction: $Value" }
    }
}

function ConvertTo-RequestNetworkExtendedAclAction {
    param([Parameter(Mandatory = $true)] $Value)

    switch -CaseSensitive ([string]$Value) {
        '1' { 'Allow'; break }
        'Allow' { 'Allow'; break }
        '2' { 'Deny'; break }
        'Deny' { 'Deny'; break }
        default { throw "The Hyper-V provider returned an unsupported extended-ACL action: $Value" }
    }
}

function Assert-RequestNetworkInternetVlan {
    param(
        [Parameter(Mandatory = $true)] $Adapter,
        [Parameter(Mandatory = $true)] [int] $PrimaryVlanId,
        [Parameter(Mandatory = $true)] [int] $SecondaryVlanId,
        [ValidateSet('Isolated', 'Promiscuous')] [string] $PrivateVlanMode = 'Isolated',
        [switch] $ManagementOS
    )

    if ($PrimaryVlanId -lt 1 -or $PrimaryVlanId -gt 4094 -or $SecondaryVlanId -lt 1 -or $SecondaryVlanId -gt 4094 -or $PrimaryVlanId -eq $SecondaryVlanId) {
        throw 'InternetOnly requires two distinct private-VLAN IDs in the range 1 through 4094.'
    }
    $vlan = @(if ($ManagementOS) {
        Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapterName ([string]$Adapter.Name) -ErrorAction Stop
    }
    else {
        Get-VMNetworkAdapterVlan -VMNetworkAdapter $Adapter -ErrorAction Stop
    })
    if ($vlan.Count -ne 1) { throw 'InternetOnly requires exactly one VLAN setting for each pinned adapter.' }
    $setting = $vlan[0]
    if ([string]$setting.OperationMode -ne 'Private' -or [string]$setting.PrivateVlanMode -ne $PrivateVlanMode -or
        [int]$setting.PrimaryVlanId -ne $PrimaryVlanId) {
        throw "InternetOnly $PrivateVlanMode VLAN setting no longer matches the pinned primary and secondary VLAN IDs."
    }
    $secondaryList = @($setting.SecondaryVlanIdList | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
    if ($PrivateVlanMode -eq 'Isolated') {
        if (-not $setting.PSObject.Properties['SecondaryVlanId'] -or [int]$setting.SecondaryVlanId -ne $SecondaryVlanId -or $secondaryList.Count -ne 0) {
            throw 'InternetOnly isolated guest VLAN no longer matches the pinned secondary VLAN.'
        }
    }
    else {
        if ($secondaryList.Count -ne 1 -or [int]$secondaryList[0] -ne $SecondaryVlanId) {
            throw 'InternetOnly promiscuous gateway VLAN does not contain exactly the pinned secondary VLAN.'
        }
    }
    [pscustomobject][ordered]@{
        OperationMode = [string]$setting.OperationMode
        PrivateVlanMode = [string]$setting.PrivateVlanMode
        PrimaryVlanId = [int]$setting.PrimaryVlanId
        SecondaryVlanId = if ($setting.PSObject.Properties['SecondaryVlanId']) { [int]$setting.SecondaryVlanId } else { 0 }
        SecondaryVlanIdList = @($secondaryList | ForEach-Object { [int]$_ })
    }
}

function Assert-RequestNetworkInternetGatewayVlan {
    param(
        [Parameter(Mandatory = $true)] [string] $SwitchName,
        [Parameter(Mandatory = $true)] [string] $GatewayMacAddress,
        [Parameter(Mandatory = $true)] [int] $PrimaryVlanId,
        [Parameter(Mandatory = $true)] [int] $SecondaryVlanId
    )

    $normalizedGatewayMac = ($GatewayMacAddress -replace '[:-]', '').ToUpperInvariant()
    if ($normalizedGatewayMac -notmatch '^[0-9A-F]{12}$') { throw 'The InternetOnly lease does not contain a valid gateway MAC address.' }
    $managementAdapters = @(Get-VMNetworkAdapter -ManagementOS -SwitchName $SwitchName -ErrorAction Stop)
    if ($managementAdapters.Count -ne 1 -or
        -not [string]::Equals((([string]$managementAdapters[0].MacAddress) -replace '[:-]', ''), $normalizedGatewayMac, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The InternetOnly management-OS gateway adapter changed while the request was active.'
    }
    $vlan = Assert-RequestNetworkInternetVlan -Adapter $managementAdapters[0] -PrimaryVlanId $PrimaryVlanId -SecondaryVlanId $SecondaryVlanId -PrivateVlanMode Promiscuous -ManagementOS
    [pscustomobject][ordered]@{
        AdapterName = [string]$managementAdapters[0].Name
        MacAddress = [string]$managementAdapters[0].MacAddress
        Vlan = $vlan
    }
}

function Invoke-WithRequestNetworkMutex {
    param(
        [Parameter(Mandatory = $true)] [string] $Key,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )

    $mutexName = 'Global\CodexHarnessRequestNetwork-' + (Get-RequestNetworkHash -Value $Key).Substring(0, 24)
    $mutex = New-Object Threading.Mutex -ArgumentList $false, $mutexName
    $taken = $false
    try {
        try { $taken = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { throw "Timed out acquiring the request-network lock for '$Key'." }
        & $Operation
    }
    finally {
        if ($taken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-WithRequestNetworkLifecycleMutex {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [scriptblock] $Operation
    )

    $canonicalBrokerRoot = [IO.Path]::GetFullPath($BrokerRoot).TrimEnd('\').ToUpperInvariant()
    Invoke-WithRequestNetworkMutex -Key ('lifecycle:' + $canonicalBrokerRoot) -Operation $Operation
}

function Get-RequestNetworkCanonicalInternetDenyPrefixes {
    @(
        '0.0.0.0/8',
        '10.0.0.0/8',
        '100.64.0.0/10',
        '127.0.0.0/8',
        '169.254.0.0/16',
        '172.16.0.0/12',
        '192.0.0.0/24',
        '192.0.2.0/24',
        '192.168.0.0/16',
        '198.18.0.0/15',
        '198.51.100.0/24',
        '203.0.113.0/24',
        '224.0.0.0/4',
        '240.0.0.0/4',
        '::/0'
    )
}

function Get-RequestNetworkIPv4Prefix24 {
    param(
        [Parameter(Mandatory = $true)] [string] $Prefix,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    # Keep this parser deliberately stricter than IPAddress.Parse. Windows
    # accepts several equivalent spellings while policy/configuration needs a
    # single canonical representation for hashing, comparison, and audit.
    $match = [regex]::Match($Prefix, '\A(?<a>[0-9]{1,3})\.(?<b>[0-9]{1,3})\.(?<c>[0-9]{1,3})\.0/24\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "$Context must be a canonical IPv4 /24 prefix."
    }
    $octetTexts = @($match.Groups['a'].Value, $match.Groups['b'].Value, $match.Groups['c'].Value)
    $octets = New-Object Collections.Generic.List[int]
    foreach ($octetText in $octetTexts) {
        $octet = [int]$octetText
        if ($octet -lt 0 -or $octet -gt 255 -or $octet.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $octetText) {
            throw "$Context contains a noncanonical or invalid IPv4 octet."
        }
        $octets.Add($octet)
    }
    [pscustomobject][ordered]@{
        Prefix = $Prefix
        Base = ($octets.ToArray() -join '.')
    }
}

function Get-RequestNetworkExpectedGuestRoutePrefixes {
    param(
        [Parameter(Mandatory = $true)] [string] $NetworkPrefix,
        [Parameter(Mandatory = $true)] [string] $GuestAddress,
        [Parameter(Mandatory = $true)] [int] $PrefixLength
    )

    if ($PrefixLength -ne 24) { throw 'Request-network guest route attestation currently requires PrefixLength 24.' }
    $network = Get-RequestNetworkIPv4Prefix24 -Prefix $NetworkPrefix -Context 'Guest network prefix'
    $addressMatch = [regex]::Match($GuestAddress, '\A(?<a>[0-9]{1,3})\.(?<b>[0-9]{1,3})\.(?<c>[0-9]{1,3})\.(?<d>[0-9]{1,3})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $addressMatch.Success) { throw 'GuestAddress must be a canonical IPv4 address.' }
    $addressOctets = @($addressMatch.Groups['a'].Value, $addressMatch.Groups['b'].Value, $addressMatch.Groups['c'].Value, $addressMatch.Groups['d'].Value)
    $numericOctets = New-Object Collections.Generic.List[int]
    foreach ($octetText in $addressOctets) {
        $octet = [int]$octetText
        if ($octet -lt 0 -or $octet -gt 255 -or $octet.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $octetText) {
            throw 'GuestAddress must be a canonical IPv4 address.'
        }
        $numericOctets.Add($octet)
    }
    if ($numericOctets[0] -ne [int]$network.Base.Split('.')[0] -or
        $numericOctets[1] -ne [int]$network.Base.Split('.')[1] -or
        $numericOctets[2] -ne [int]$network.Base.Split('.')[2]) {
        throw 'GuestAddress is outside the configured guest network prefix.'
    }

    # Windows can materialize the connected prefix plus host, directed/global
    # broadcast, and IPv4 multicast /32-or-range routes. All are on-link and
    # deterministic from the assigned address; no other destination is part of
    # the request-network boundary.
    @(
        $network.Prefix
        ($GuestAddress + '/32')
        ("{0}.{1}.{2}.255/32" -f $numericOctets[0], $numericOctets[1], $numericOctets[2])
        '224.0.0.0/4'
        '255.255.255.255/32'
    ) | Select-Object -Unique
}

function Test-RequestNetworkIPv4InPrefix {
    param(
        [Parameter(Mandatory = $true)] [string] $Address,
        [Parameter(Mandatory = $true)] [string] $Prefix
    )

    $prefixMatch = [regex]::Match($Prefix, '\A(?<network>[0-9.]+)/(?<length>[0-9]{1,2})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $addressMatch = [regex]::Match($Address, '\A(?<a>[0-9]{1,3})\.(?<b>[0-9]{1,3})\.(?<c>[0-9]{1,3})\.(?<d>[0-9]{1,3})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $prefixMatch.Success -or -not $addressMatch.Success) { return $false }
    try {
        $addressBytes = @($addressMatch.Groups['a'].Value, $addressMatch.Groups['b'].Value, $addressMatch.Groups['c'].Value, $addressMatch.Groups['d'].Value) | ForEach-Object {
            $octet = [int]$_
            if ($octet -lt 0 -or $octet -gt 255 -or $octet.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $_) { throw 'noncanonical IPv4' }
            [byte]$octet
        }
        $networkParts = $prefixMatch.Groups['network'].Value.Split('.')
        if ($networkParts.Count -ne 4) { return $false }
        $networkBytes = @($networkParts | ForEach-Object {
            $octet = [int]$_
            if ($octet -lt 0 -or $octet -gt 255 -or $octet.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $_) { throw 'noncanonical IPv4' }
            [byte]$octet
        })
        $length = [int]$prefixMatch.Groups['length'].Value
        if ([string]$prefixMatch.Groups['length'].Value -cne $length.ToString([Globalization.CultureInfo]::InvariantCulture)) { return $false }
    }
    catch { return $false }
    if ($addressBytes.Count -ne 4 -or $networkBytes.Count -ne 4 -or $length -lt 0 -or $length -gt 32) { return $false }
    $fullBytes = [Math]::Floor($length / 8)
    for ($index = 0; $index -lt $fullBytes; $index++) {
        if ($addressBytes[$index] -ne $networkBytes[$index]) { return $false }
    }
    $remainingBits = $length % 8
    if ($remainingBits -gt 0) {
        $mask = [byte](256 - [Math]::Pow(2, 8 - $remainingBits))
        if (($addressBytes[$fullBytes] -band $mask) -ne ($networkBytes[$fullBytes] -band $mask)) { return $false }
    }
    $true
}

function Get-RequestNetworkInternetGuestAddress {
    param(
        [Parameter(Mandatory = $true)] [string] $NetworkBase,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $GatewayAddress,
        [Parameter(Mandatory = $true)] [string] $NatName,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $used = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [void]$used.Add($GatewayAddress)
    foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [string]$_.IPAddress })) { [void]$used.Add($address) }
    foreach ($lease in @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$lease.GuestAddress)) { [void]$used.Add([string]$lease.GuestAddress) }
    }
    foreach ($session in @(Get-NetNatSession -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.NatName, $NatName, [StringComparison]::Ordinal) })) {
        foreach ($property in @('InternalSourceAddress', 'InternalDestinationAddress')) {
            $value = [string]$session.$property
            if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$used.Add($value) }
        }
    }

    $hash = Get-RequestNetworkHash -Value $RequestId
    $seed = [Convert]::ToUInt32($hash.Substring(0, 8), 16)
    $candidateCount = 190
    for ($attempt = 0; $attempt -lt $candidateCount; $attempt++) {
        $lastOctet = 50 + (($seed + $attempt) % $candidateCount)
        $candidate = $NetworkBase + '.' + $lastOctet
        if ($used.Add($candidate)) { return $candidate }
    }
    throw 'InternetOnly could not allocate a request-unique guest address without an active lease or stale NAT session.'
}

function Resolve-RequestNetworkProfile {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [Parameter(Mandatory = $true)] $Config
    )

    $operation = [string](Get-RequestNetworkObjectPropertyValue -Value $Request -Name 'Operation')
    $reservedTopLevelProperties = @(
        'RequestNetworkPolicy', 'NetworkPolicy', 'NetworkProfile', 'NetworkCohort', 'NetworkSwitchName',
        'SwitchName', 'SwitchId', 'NatName', 'NatPrefix', 'GuestAddress', 'GatewayAddress', 'GatewayMacAddress',
        'GatewayInterfaceIndex', 'GatewayInterfaceGuid', 'PrefixLength', 'DnsServers', 'Routes', 'DenyRemotePrefixes',
        'NetAdapterInterfaceGuid', 'NetAdapterInterfaceDescription', 'AllowManagementOS'
    )
    $reservedTopLevelPresent = @(Get-RequestNetworkObjectPropertyNames -Value $Request | Where-Object { $_ -in $reservedTopLevelProperties })
    if ($reservedTopLevelPresent.Count -gt 0) {
        throw ('Network authority must be expressed only through the bounded Network object; reserved top-level properties are not accepted: ' + ($reservedTopLevelPresent -join ', '))
    }
    $network = Get-RequestNetworkObjectPropertyValue -Value $Request -Name 'Network'
    $profileValue = Get-RequestNetworkObjectPropertyValue -Value $network -Name 'Profile'
    $profile = if ($network -and -not [string]::IsNullOrWhiteSpace([string]$profileValue)) { [string]$profileValue } else { 'None' }
    if ($profile -notin @('None', 'IsolatedTestNet', 'InternetOnly', 'TrustedLan')) {
        throw "Unsupported request network profile: $profile"
    }

    if ($operation -eq 'RunGuestJob') {
        if ($profile -ne 'None') {
            throw 'RunGuestJob cannot request network access; use RunGuestJobNetworkV1.'
        }
    }
    elseif ($operation -eq 'RunGuestJobNetworkV1') {
        if (-not $network -or $profile -eq 'None') {
            throw 'RunGuestJobNetworkV1 requires an explicit non-None Network profile.'
        }
    }
    else {
        throw "Unsupported operation: $operation"
    }

    if ($network) {
        $allowedProperties = @('Profile', 'Cohort', 'AllowHostInputs')
        $unexpected = @(Get-RequestNetworkObjectPropertyNames -Value $network | Where-Object { $_ -notin $allowedProperties })
        if ($unexpected.Count -gt 0) {
            throw ('The request Network object contains unsupported properties: ' + ($unexpected -join ', '))
        }
        $cohortValue = Get-RequestNetworkObjectPropertyValue -Value $network -Name 'Cohort'
        $allowValue = Get-RequestNetworkObjectPropertyValue -Value $network -Name 'AllowHostInputs'
        if ($profileValue -isnot [string] -or ($null -ne $cohortValue -and $cohortValue -isnot [string]) -or
            $allowValue -isnot [bool]) {
            throw 'The request Network fields must use their exact string, null, and Boolean JSON types.'
        }
    }

    $cohort = if ($network) { [string]$cohortValue } else { '' }
    $allowHostInputs = [bool]($network -and $allowValue)
    $hostInputs = @(Get-RequestNetworkObjectPropertyValue -Value $Request -Name 'HostInputs')
    if ($profile -eq 'None') {
        if (-not [string]::IsNullOrWhiteSpace($cohort) -or $allowHostInputs) {
            throw 'The None network profile cannot include cohort or host-input acknowledgement fields.'
        }
        return [pscustomobject][ordered]@{
            RequestedProfile = 'None'
            EffectiveProfile = 'None'
            Cohort = $null
            RequestedSwitchName = $null
            Policy = Get-RequestNetworkPolicy -Config $Config
            Settings = $null
        }
    }

    if ($hostInputs.Count -gt 0 -and -not $allowHostInputs) {
        throw 'Network access with read-only host inputs requires explicit AllowHostInputs acknowledgement.'
    }
    if ($hostInputs.Count -gt 0 -and @($hostInputs | Where-Object { [string]$_.SelectedTransport -eq 'Share' }).Count -gt 0) {
        throw 'The scoped host-input Share transport cannot coexist with a general request network.'
    }

    $policy = Get-RequestNetworkPolicy -Config $Config
    $settings = Get-RequestNetworkObjectPropertyValue -Value $policy -Name $profile
    if (-not $settings -or (Get-RequestNetworkObjectPropertyValue -Value $settings -Name 'Enabled') -isnot [bool] -or -not $settings.Enabled) {
        throw "The $profile request network profile is disabled by the SYSTEM broker policy."
    }

    switch ($profile) {
        'IsolatedTestNet' {
            $cohort = $cohort.Trim()
            if ($cohort.Length -lt 1 -or $cohort.Length -gt 64 -or $cohort -notmatch '^[A-Za-z0-9._-]+$') {
                throw 'IsolatedTestNet requires a cohort of at most 64 letters, digits, dots, underscores, or hyphens.'
            }
            $null = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$settings.NetworkPrefix) -Context 'IsolatedTestNet.NetworkPrefix'
        }
        'InternetOnly' {
            if (-not [string]::IsNullOrWhiteSpace($cohort)) {
                throw 'InternetOnly does not accept a client-supplied cohort.'
            }
            $null = Get-RequestNetworkInternetVlanSettings -Settings $settings
        }
        'TrustedLan' {
            if (-not [string]::IsNullOrWhiteSpace($cohort)) { throw 'TrustedLan does not accept a cohort.' }
            $approved = @($settings.AllowedSwitches)
            if ($approved.Count -ne 1) { throw 'TrustedLan requires exactly one broker-pinned allowed switch.' }
            $switchName = [string]$approved[0].Name
            if ([string]::IsNullOrWhiteSpace($switchName) -or $switchName.Length -gt 128 -or $switchName.IndexOfAny([char[]](0..31)) -ge 0) {
                throw 'TrustedLan broker policy contains an invalid switch name.'
            }
            $approvedProperties = @(Get-RequestNetworkObjectPropertyNames -Value $approved[0])
            foreach ($requiredProperty in @('Name', 'Id', 'NetAdapterInterfaceGuid', 'NetAdapterInterfaceDescription', 'AllowManagementOS')) {
                if ($approvedProperties -notcontains $requiredProperty) {
                    throw "TrustedLan switch '$switchName' is missing its broker-pinned $requiredProperty value."
                }
            }
            if ((Get-RequestNetworkObjectPropertyValue -Value $approved[0] -Name 'AllowManagementOS') -isnot [bool]) {
                throw "TrustedLan switch '$switchName' has an invalid AllowManagementOS value."
            }
        }
    }

    [pscustomobject][ordered]@{
        RequestedProfile = $profile
        EffectiveProfile = $profile
        Cohort = if ($profile -eq 'IsolatedTestNet') { $cohort } else { $null }
        RequestedSwitchName = if ($profile -eq 'TrustedLan') { $switchName } else { $null }
        Policy = $policy
        Settings = $settings
    }
}

function Write-RequestNetworkLeaseState {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $Status
    )

    $Runtime.Status = $Status
    $Runtime.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path ([string]$Runtime.StatePath) -Value ([ordered]@{
        FormatVersion = 1
        RequestId = [string]$Runtime.RequestId
        WorkerId = [int]$Runtime.WorkerId
        VmName = [string]$Runtime.VmName
        VmId = [string]$Runtime.VmId
        Profile = [string]$Runtime.Profile
        InstallationScope = [string]$Runtime.InstallationScope
        CohortHash = [string]$Runtime.CohortHash
        Status = $Status
        OwnerProcessId = [int]$Runtime.OwnerProcessId
        OwnerProcessStartUtc = [string]$Runtime.OwnerProcessStartUtc
        AdapterName = [string]$Runtime.AdapterName
        AdapterMacAddress = [string]$Runtime.AdapterMacAddress
        SwitchName = [string]$Runtime.SwitchName
        SwitchId = [string]$Runtime.SwitchId
        SwitchType = [string]$Runtime.SwitchType
        SwitchOwned = [bool]$Runtime.SwitchOwned
        GuestAddress = [string]$Runtime.GuestAddress
        PrefixLength = [int]$Runtime.PrefixLength
        NetworkPrefix = [string]$Runtime.NetworkPrefix
        GatewayAddress = [string]$Runtime.GatewayAddress
        GatewayMacAddress = [string]$Runtime.GatewayMacAddress
        GatewayInterfaceIndex = [int]$Runtime.GatewayInterfaceIndex
        GatewayInterfaceGuid = [string]$Runtime.GatewayInterfaceGuid
        PrimaryVlanId = [int]$Runtime.PrimaryVlanId
        SecondaryVlanId = [int]$Runtime.SecondaryVlanId
        NatName = [string]$Runtime.NatName
        NatPrefix = [string]$Runtime.NatPrefix
        NatPolicy = $Runtime.NatPolicy
        DnsServers = @($Runtime.DnsServers)
        EnforcedLocalAddress = [string]$Runtime.EnforcedLocalAddress
        ExtendedAclIdleSessionTimeout = [int]$Runtime.ExtendedAclIdleSessionTimeout
        ExtendedAclWeights = $Runtime.ExtendedAclWeights
        AllowedRemoteAddress = [string]$Runtime.AllowedRemoteAddress
        AllowedRemoteMacAddress = [string]$Runtime.AllowedRemoteMacAddress
        DenyRemotePrefixes = @($Runtime.DenyRemotePrefixes)
        DefaultRouteAttestation = @((Get-RequestNetworkObjectPropertyValue -Value $Runtime -Name 'DefaultRouteAttestation'))
        ExpectedNetAdapterInterfaceGuid = [string]$Runtime.ExpectedNetAdapterInterfaceGuid
        ExpectedNetAdapterInterfaceDescription = [string]$Runtime.ExpectedNetAdapterInterfaceDescription
        ExpectedAllowManagementOS = $Runtime.ExpectedAllowManagementOS
        CreatedUtc = [string]$Runtime.CreatedUtc
        UpdatedUtc = [string]$Runtime.UpdatedUtc
        CleanupErrors = @($Runtime.CleanupErrors)
    })
}

function Assert-RequestNetworkPinnedSwitch {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Id,
        [Parameter(Mandatory = $true)] [ValidateSet('Internal', 'External', 'Private')] [string] $Type,
        [string] $ExpectedNetAdapterInterfaceGuid,
        [string] $ExpectedNetAdapterInterfaceDescription,
        [Nullable[bool]] $ExpectedAllowManagementOS
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Id)) {
        throw 'Enabled request-network infrastructure must pin both switch name and switch ID.'
    }
    $switches = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.Name, $Name, [StringComparison]::Ordinal)
    })
    if ($switches.Count -ne 1) { throw "Pinned request-network switch '$Name' was not found uniquely." }
    $switch = $switches[0]
    if (-not [string]::Equals([string]$switch.Id, $Id, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$switch.SwitchType, $Type, [StringComparison]::Ordinal)) {
        throw "Pinned request-network switch '$Name' no longer matches its approved ID and type."
    }
    if ($Type -eq 'External') {
        if ([string]::IsNullOrWhiteSpace($ExpectedNetAdapterInterfaceGuid) -or
            [string]::IsNullOrWhiteSpace($ExpectedNetAdapterInterfaceDescription) -or
            -not $PSBoundParameters.ContainsKey('ExpectedAllowManagementOS')) {
            throw 'A TrustedLan switch must pin its physical interface GUID, interface description, and management-OS sharing state.'
        }
        try {
            $expectedGuid = [Guid]::Parse($ExpectedNetAdapterInterfaceGuid)
            $actualGuid = [Guid]::Parse([string]$switch.NetAdapterInterfaceGuid)
        }
        catch { throw "Pinned TrustedLan switch '$Name' does not expose one valid physical interface GUID." }
        $descriptions = @($switch.NetAdapterInterfaceDescriptions | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($descriptions.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$switch.NetAdapterInterfaceDescription)) {
            $descriptions = @([string]$switch.NetAdapterInterfaceDescription)
        }
        if ([bool]$switch.EmbeddedTeamingEnabled -or $descriptions.Count -ne 1 -or
            $actualGuid -ne $expectedGuid -or
            -not [string]::Equals($descriptions[0], $ExpectedNetAdapterInterfaceDescription, [StringComparison]::Ordinal) -or
            [bool]$switch.AllowManagementOS -ne [bool]$ExpectedAllowManagementOS) {
            throw "Pinned TrustedLan switch '$Name' no longer matches its approved physical uplink or management-OS sharing state."
        }
    }
    $switch
}

function Get-RequestNetworkExpectedNatPolicy {
    param([Parameter(Mandatory = $true)] $Settings)

    $requiredProperties = @(
        'ExternalIPInterfaceAddressPrefix', 'InternalRoutingDomainId', 'TcpFilteringBehavior', 'UdpFilteringBehavior',
        'UdpInboundRefresh', 'TcpEstablishedConnectionTimeout', 'TcpTransientConnectionTimeout', 'UdpIdleSessionTimeout', 'IcmpQueryTimeout'
    )
    $properties = @(Get-RequestNetworkObjectPropertyNames -Value $Settings)
    foreach ($requiredProperty in $requiredProperties) {
        if ($properties -notcontains $requiredProperty) { throw "InternetOnly policy is missing the pinned NAT property $requiredProperty." }
    }
    if ([string]$Settings.TcpFilteringBehavior -ne 'AddressDependentFiltering' -or [string]$Settings.UdpFilteringBehavior -ne 'AddressDependentFiltering') {
        throw 'InternetOnly requires address-dependent TCP and UDP NAT filtering.'
    }
    if ($Settings.UdpInboundRefresh -isnot [bool] -or [bool]$Settings.UdpInboundRefresh) {
        throw 'InternetOnly requires UdpInboundRefresh=false so inbound packets cannot extend a UDP session.'
    }
    try { $null = [Guid]::Parse([string]$Settings.InternalRoutingDomainId) }
    catch { throw 'InternetOnly.InternalRoutingDomainId must be an exact GUID.' }
    foreach ($bound in @(
        @{ Name = 'TcpEstablishedConnectionTimeout'; Minimum = 60; Maximum = 3600 },
        @{ Name = 'TcpTransientConnectionTimeout'; Minimum = 10; Maximum = 300 },
        @{ Name = 'UdpIdleSessionTimeout'; Minimum = 10; Maximum = 300 },
        @{ Name = 'IcmpQueryTimeout'; Minimum = 1; Maximum = 60 }
    )) {
        $rawValue = Get-RequestNetworkObjectPropertyValue -Value $Settings -Name $bound.Name
        $value = Assert-RequestNetworkExactInteger -Value $rawValue -Context "InternetOnly.$($bound.Name)"
        if ($value -lt $bound.Minimum -or $value -gt $bound.Maximum) {
            throw "InternetOnly.$($bound.Name) is outside its broker safety bound."
        }
    }
    [pscustomobject][ordered]@{
        ExternalIPInterfaceAddressPrefix = [string]$Settings.ExternalIPInterfaceAddressPrefix
        InternalRoutingDomainId = [string]$Settings.InternalRoutingDomainId
        TcpFilteringBehavior = [string]$Settings.TcpFilteringBehavior
        UdpFilteringBehavior = [string]$Settings.UdpFilteringBehavior
        UdpInboundRefresh = [bool]$Settings.UdpInboundRefresh
        TcpEstablishedConnectionTimeout = [uint32]$Settings.TcpEstablishedConnectionTimeout
        TcpTransientConnectionTimeout = [uint32]$Settings.TcpTransientConnectionTimeout
        UdpIdleSessionTimeout = [uint32]$Settings.UdpIdleSessionTimeout
        IcmpQueryTimeout = [uint32]$Settings.IcmpQueryTimeout
    }
}

function Assert-RequestNetworkNatPolicy {
    param(
        [Parameter(Mandatory = $true)] $Nat,
        [Parameter(Mandatory = $true)] $ExpectedPolicy,
        [Parameter(Mandatory = $true)] [string] $ExpectedInternalPrefix
    )

    if (-not [bool]$Nat.Active -or
        -not [string]::Equals([string]$Nat.InternalIPInterfaceAddressPrefix, $ExpectedInternalPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$Nat.ExternalIPInterfaceAddressPrefix, [string]$ExpectedPolicy.ExternalIPInterfaceAddressPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$Nat.InternalRoutingDomainId, [string]$ExpectedPolicy.InternalRoutingDomainId, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$Nat.TcpFilteringBehavior -ne [string]$ExpectedPolicy.TcpFilteringBehavior -or
        [string]$Nat.UdpFilteringBehavior -ne [string]$ExpectedPolicy.UdpFilteringBehavior -or
        [bool]$Nat.UdpInboundRefresh -ne [bool]$ExpectedPolicy.UdpInboundRefresh -or
        [uint32]$Nat.TcpEstablishedConnectionTimeout -ne [uint32]$ExpectedPolicy.TcpEstablishedConnectionTimeout -or
        [uint32]$Nat.TcpTransientConnectionTimeout -ne [uint32]$ExpectedPolicy.TcpTransientConnectionTimeout -or
        [uint32]$Nat.UdpIdleSessionTimeout -ne [uint32]$ExpectedPolicy.UdpIdleSessionTimeout -or
        [uint32]$Nat.IcmpQueryTimeout -ne [uint32]$ExpectedPolicy.IcmpQueryTimeout) {
        throw 'The InternetOnly WinNAT instance no longer matches its exact active filtering, refresh, routing, prefix, and timeout policy.'
    }
    $true
}

function Get-RequestNetworkNatStaticMappings {
    param([Parameter(Mandatory = $true)] [string] $NatName)

    @(
        Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName 'MSFT_NetNatStaticMapping' -ErrorAction Stop |
            Where-Object { [string]::Equals([string]$_.NatName, $NatName, [StringComparison]::Ordinal) }
    )
}

function ConvertTo-RequestNetworkInternetDefaultRouteKey {
    param(
        [Parameter(Mandatory = $true)] $Attestation
    )

    foreach ($propertyName in @('AddressFamily', 'DestinationPrefix', 'InterfaceGuid', 'InterfaceDescription', 'InterfaceIndex', 'NextHop', 'RouteMetric', 'InterfaceMetric')) {
        if (-not $Attestation.PSObject.Properties[$propertyName]) {
            throw "InternetOnly default-route attestation is missing $propertyName."
        }
    }
    $addressFamily = [string]$Attestation.AddressFamily
    if ($addressFamily -notin @('IPv4', 'IPv6')) {
        throw "InternetOnly default-route attestation has an unsupported address family: $addressFamily."
    }
    $expectedPrefix = if ($addressFamily -eq 'IPv4') { '0.0.0.0/0' } else { '::/0' }
    if (-not [string]::Equals([string]$Attestation.DestinationPrefix, $expectedPrefix, [StringComparison]::Ordinal)) {
        throw 'InternetOnly default-route attestation has a noncanonical default destination prefix.'
    }
    try { $interfaceGuid = ([Guid]::Parse([string]$Attestation.InterfaceGuid)).ToString('D').ToUpperInvariant() }
    catch { throw 'InternetOnly default-route attestation has an invalid interface GUID.' }
    if ([string]::IsNullOrWhiteSpace([string]$Attestation.InterfaceDescription)) {
        throw 'InternetOnly default-route attestation has an empty interface description.'
    }
    try {
        if ($null -eq $Attestation.InterfaceIndex -or $Attestation.InterfaceIndex -is [bool] -or
            $null -eq $Attestation.RouteMetric -or $Attestation.RouteMetric -is [bool] -or
            $null -eq $Attestation.InterfaceMetric -or $Attestation.InterfaceMetric -is [bool]) {
            throw 'missing numeric identity'
        }
        $interfaceIndex = [int]$Attestation.InterfaceIndex
        $routeMetric = [int]$Attestation.RouteMetric
        $interfaceMetric = [int]$Attestation.InterfaceMetric
        if ([double]$interfaceIndex -ne [double]$Attestation.InterfaceIndex -or
            [double]$routeMetric -ne [double]$Attestation.RouteMetric -or
            [double]$interfaceMetric -ne [double]$Attestation.InterfaceMetric) {
            throw 'non-integral identity'
        }
    }
    catch { throw 'InternetOnly default-route attestation has a non-integer interface index or metric.' }
    if ($interfaceIndex -le 0 -or $routeMetric -lt 0 -or $interfaceMetric -lt 0) {
        throw 'InternetOnly default-route attestation has an invalid interface index or metric.'
    }
    $nextHop = [string]$Attestation.NextHop
    if ([string]::IsNullOrWhiteSpace($nextHop)) { throw 'InternetOnly default-route attestation has an empty next hop.' }
    try {
        $parsedNextHop = [Net.IPAddress]::Parse($nextHop)
        $requiredFamily = if ($addressFamily -eq 'IPv4') { [Net.Sockets.AddressFamily]::InterNetwork } else { [Net.Sockets.AddressFamily]::InterNetworkV6 }
        if ($parsedNextHop.AddressFamily -ne $requiredFamily) { throw 'address family mismatch' }
        $nextHop = $parsedNextHop.ToString()
    }
    catch { throw "InternetOnly default-route attestation has an invalid $addressFamily next hop." }
    ([pscustomobject][ordered]@{
        AddressFamily = $addressFamily
        DestinationPrefix = $expectedPrefix
        InterfaceGuid = $interfaceGuid
        InterfaceDescription = [string]$Attestation.InterfaceDescription
        InterfaceIndex = $interfaceIndex
        NextHop = $nextHop
        RouteMetric = $routeMetric
        InterfaceMetric = $interfaceMetric
    } | ConvertTo-Json -Compress -Depth 3)
}

function Get-RequestNetworkInternetDefaultRouteAttestation {
    $routes = @(
        Get-NetRoute -ErrorAction Stop | Where-Object {
            [string]$_.DestinationPrefix -in @('0.0.0.0/0', '::/0')
        }
    )
    if ($routes.Count -eq 0) {
        throw 'InternetOnly requires at least one host default route for its egress attestation.'
    }

    $attestations = New-Object Collections.Generic.List[object]
    foreach ($route in $routes) {
        $destinationPrefix = [string]$route.DestinationPrefix
        $addressFamily = if ($destinationPrefix -eq '0.0.0.0/0') { 'IPv4' } elseif ($destinationPrefix -eq '::/0') { 'IPv6' } else { throw 'InternetOnly encountered a noncanonical default route.' }
        $interfaceIndexValue = if ($route.PSObject.Properties['InterfaceIndex']) {
            $route.InterfaceIndex
        }
        elseif ($route.PSObject.Properties['ifIndex']) {
            $route.ifIndex
        }
        else {
            $null
        }
        try {
            $interfaceIndex = [int]$interfaceIndexValue
            if ([double]$interfaceIndex -ne [double]$interfaceIndexValue) { throw 'non-integral interface index' }
        }
        catch { throw "InternetOnly could not read the $addressFamily default route interface index." }
        if ($interfaceIndex -le 0) { throw "InternetOnly received an invalid $addressFamily default route interface index." }
        if (-not $route.PSObject.Properties['NextHop'] -or [string]::IsNullOrWhiteSpace([string]$route.NextHop)) {
            throw "InternetOnly could not read the $addressFamily default route next hop."
        }
        if (-not $route.PSObject.Properties['RouteMetric']) {
            throw "InternetOnly could not read the $addressFamily default route metric."
        }
        try {
            $routeMetric = [int]$route.RouteMetric
            if ([double]$routeMetric -ne [double]$route.RouteMetric) { throw 'non-integral route metric' }
        }
        catch { throw "InternetOnly received an invalid $addressFamily default route metric." }
        if ($routeMetric -lt 0) { throw "InternetOnly received a negative $addressFamily default route metric." }

        $ipInterfaces = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily $addressFamily -ErrorAction Stop)
        if ($ipInterfaces.Count -ne 1 -or -not $ipInterfaces[0].PSObject.Properties['InterfaceMetric']) {
            throw "InternetOnly could not resolve exactly one $addressFamily interface metric for default route interface $interfaceIndex."
        }
        try {
            $interfaceMetric = [int]$ipInterfaces[0].InterfaceMetric
            if ([double]$interfaceMetric -ne [double]$ipInterfaces[0].InterfaceMetric) { throw 'non-integral interface metric' }
        }
        catch { throw "InternetOnly received an invalid $addressFamily interface metric." }
        if ($interfaceMetric -lt 0) { throw "InternetOnly received a negative $addressFamily interface metric." }

        $adapters = @(Get-NetAdapter -InterfaceIndex $interfaceIndex -IncludeHidden -ErrorAction Stop)
        if ($adapters.Count -ne 1) {
            throw "InternetOnly could not resolve exactly one host adapter for $addressFamily default route interface $interfaceIndex."
        }
        $adapter = $adapters[0]
        if (-not $adapter.PSObject.Properties['InterfaceGuid'] -or [string]::IsNullOrWhiteSpace([string]$adapter.InterfaceGuid) -or
            -not $adapter.PSObject.Properties['InterfaceDescription'] -or [string]::IsNullOrWhiteSpace([string]$adapter.InterfaceDescription)) {
            throw "InternetOnly default route interface $interfaceIndex has incomplete host adapter identity."
        }
        try { $interfaceGuid = ([Guid]::Parse([string]$adapter.InterfaceGuid)).ToString('D').ToUpperInvariant() }
        catch { throw "InternetOnly default route interface $interfaceIndex has an invalid host adapter GUID." }

        $attestation = [pscustomobject][ordered]@{
            AddressFamily = $addressFamily
            DestinationPrefix = $destinationPrefix
            InterfaceGuid = $interfaceGuid
            InterfaceDescription = [string]$adapter.InterfaceDescription
            InterfaceIndex = $interfaceIndex
            NextHop = [string]$route.NextHop
            RouteMetric = $routeMetric
            InterfaceMetric = $interfaceMetric
        }
        $null = ConvertTo-RequestNetworkInternetDefaultRouteKey -Attestation $attestation
        $attestations.Add($attestation)
    }
    @($attestations.ToArray() | Sort-Object AddressFamily, InterfaceGuid, InterfaceDescription, InterfaceIndex, NextHop, RouteMetric, InterfaceMetric)
}

function Assert-RequestNetworkInternetDefaultRouteAttestation {
    param(
        [Parameter(Mandatory = $true)] $ExpectedAttestation
    )

    $expected = @($ExpectedAttestation)
    if ($expected.Count -eq 0) {
        throw 'InternetOnly lease is missing its pinned host default-route egress attestation.'
    }
    $expectedKeys = @($expected | ForEach-Object { ConvertTo-RequestNetworkInternetDefaultRouteKey -Attestation $_ } | Sort-Object)
    $current = @(Get-RequestNetworkInternetDefaultRouteAttestation)
    $currentKeys = @($current | ForEach-Object { ConvertTo-RequestNetworkInternetDefaultRouteKey -Attestation $_ } | Sort-Object)
    if ($expectedKeys.Count -ne $currentKeys.Count) {
        throw 'InternetOnly host default-route egress identity changed while the request was active.'
    }
    for ($index = 0; $index -lt $expectedKeys.Count; $index++) {
        if (-not [string]::Equals([string]$expectedKeys[$index], [string]$currentKeys[$index], [StringComparison]::Ordinal)) {
            throw 'InternetOnly host default-route egress identity changed while the request was active.'
        }
    }
    [pscustomobject][ordered]@{
        Attested = $true
        DefaultRouteCount = $current.Count
        DefaultRouteAttestation = @($current)
    }
}

function New-RequestNetworkRuntime {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Definition,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [int] $WorkerId
    )

    if ([string]$Definition.EffectiveProfile -eq 'None') { return $null }
    Import-Module Hyper-V -ErrorAction Stop
    $leaseRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $BrokerRoot
    New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $installationScope = Get-RequestNetworkInstallationScope -BrokerRoot $BrokerRoot
    $profile = [string]$Definition.EffectiveProfile
    $switch = $null
    $switchOwned = $false
    $cohortHash = $null
    $guestAddress = $null
    $prefixLength = 0
    $gatewayAddress = $null
    $gatewayMacAddress = $null
    $gatewayInterfaceIndex = 0
    $gatewayInterfaceGuid = $null
    $primaryVlanId = 0
    $secondaryVlanId = 0
    $natName = $null
    $natPrefix = $null
    $natPolicy = $null
    $dnsServers = @()
    $enforcedLocalAddress = $null
    $extendedAclIdleSessionTimeout = 0
    $extendedAclWeights = Get-RequestNetworkInternetExtendedAclWeights
    $allowedRemoteAddress = $null
    $allowedRemoteMacAddress = $null
    $denyRemotePrefixes = @()
    $expectedNetAdapterInterfaceGuid = $null
    $expectedNetAdapterInterfaceDescription = $null
    $expectedAllowManagementOS = $null
    $internetNetworkBase = $null
    $networkPrefix = $null
    $defaultRouteAttestation = @()

    if ($profile -eq 'IsolatedTestNet') {
        $cohortHash = (Get-RequestNetworkHash -Value ([string]$Definition.Cohort)).Substring(0, 16)
        $prefix = [string]$Definition.Settings.SwitchPrefix
        if ($prefix.Length -lt 1 -or $prefix.Length -gt 80 -or $prefix -notmatch '^[A-Za-z0-9._-]+$') {
            throw 'IsolatedTestNet.SwitchPrefix is invalid.'
        }
        $switchName = $prefix + '-' + $installationScope + '-' + $cohortHash.Substring(0, 10)
        $ownershipMarker = 'CodexHarnessRequestNetwork:' + $installationScope + ':' + $cohortHash
        $switch = Invoke-WithRequestNetworkMutex -Key ('switch:' + $switchName) -Operation {
            $existing = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
                [string]::Equals([string]$_.Name, $switchName, [StringComparison]::Ordinal)
            })
            if ($existing.Count -gt 1) { throw "Managed isolated switch '$switchName' did not resolve uniquely." }
            $existing = $existing | Select-Object -First 1
            if ($existing -and ([string]$existing.SwitchType -ne 'Private' -or [string]$existing.Notes -ne $ownershipMarker)) {
                throw "Managed isolated switch '$switchName' has an unexpected type or ownership marker."
            }
            if (-not $existing) {
                $existing = New-VMSwitch -Name $switchName -SwitchType Private -Notes $ownershipMarker -ErrorAction Stop
            }
            $existing
        }
        $switchOwned = $true
        $network = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$Definition.Settings.NetworkPrefix) -Context 'IsolatedTestNet.NetworkPrefix'
        $guestAddress = $network.Base + '.' + (100 + $WorkerId)
        $prefixLength = 24
        $networkPrefix = [string]$network.Prefix
    }
    elseif ($profile -eq 'InternetOnly') {
        $settings = $Definition.Settings
        $vlanSettings = Get-RequestNetworkInternetVlanSettings -Settings $settings
        $primaryVlanId = [int]$vlanSettings.PrimaryVlanId
        $secondaryVlanId = [int]$vlanSettings.SecondaryVlanId
        $switch = Assert-RequestNetworkPinnedSwitch -Name ([string]$settings.SwitchName) -Id ([string]$settings.SwitchId) -Type Internal
        if (-not $switch.PSObject.Properties['AllowManagementOS'] -or -not [bool]$switch.AllowManagementOS) {
            throw 'InternetOnly requires the pinned internal switch to allow the management operating system.'
        }
        if ([int]$settings.PrefixLength -ne 24) { throw 'InternetOnly currently requires PrefixLength 24.' }
        $network = Get-RequestNetworkIPv4Prefix24 -Prefix ([string]$settings.NatPrefix) -Context 'InternetOnly.NatPrefix'
        $allNats = @(Get-NetNat -ErrorAction Stop)
        $nat = @($allNats | Where-Object { [string]::Equals([string]$_.Name, [string]$settings.NatName, [StringComparison]::Ordinal) })
        if ($allNats.Count -ne 1 -or $nat.Count -ne 1 -or -not [string]::Equals([string]$nat[0].InternalIPInterfaceAddressPrefix, [string]$settings.NatPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'InternetOnly requires the approved NAT to be the host''s sole WinNAT instance with its exact pinned prefix.'
        }
        $natPolicy = Get-RequestNetworkExpectedNatPolicy -Settings $settings
        $null = Assert-RequestNetworkNatPolicy -Nat $nat[0] -ExpectedPolicy $natPolicy -ExpectedInternalPrefix ([string]$settings.NatPrefix)
        if (@(Get-RequestNetworkNatStaticMappings -NatName ([string]$settings.NatName)).Count -gt 0) {
            throw 'InternetOnly requires an outbound-only NAT with no static inbound mappings.'
        }
        $nonHarnessAdapters = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.SwitchName, [string]$switch.Name, [StringComparison]::Ordinal) -and [string]$_.Name -notlike 'CodexRequestNet-*'
        })
        if ($nonHarnessAdapters.Count -gt 0) {
            throw 'InternetOnly requires a dedicated internal switch with no non-harness VM adapters.'
        }
        $gatewayAddress = [string]$settings.GatewayAddress
        if ($gatewayAddress -notmatch ('^' + [regex]::Escape($network.Base) + '\.(?:[1-9]|[1-9]\d|1\d\d|2[0-4]\d|25[0-4])$')) {
            throw 'InternetOnly.GatewayAddress must be a usable address in NatPrefix.'
        }
        if (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.IPAddress, $gatewayAddress, [StringComparison]::Ordinal)
        }).Count -lt 1) {
            throw 'The approved InternetOnly gateway address is not assigned on the host.'
        }
        $managementAdapters = @(Get-VMNetworkAdapter -ManagementOS -SwitchName ([string]$switch.Name) -ErrorAction Stop)
        if ($managementAdapters.Count -ne 1) { throw 'The approved InternetOnly internal switch does not have exactly one management-OS adapter.' }
        $null = Assert-RequestNetworkInternetVlan -Adapter $managementAdapters[0] -PrimaryVlanId $primaryVlanId -SecondaryVlanId $secondaryVlanId -PrivateVlanMode Promiscuous -ManagementOS
        $gatewayMacAddress = (([string]$managementAdapters[0].MacAddress) -replace '[:-]', '').ToUpperInvariant()
        if ($gatewayMacAddress -notmatch '^[0-9A-F]{12}$') { throw 'The InternetOnly gateway adapter returned an invalid MAC address.' }
        $matchingHostAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            (([string]$_.MacAddress) -replace '[:-]', '').ToUpperInvariant() -eq $gatewayMacAddress
        })
        if ($matchingHostAdapters.Count -ne 1) { throw 'The InternetOnly management-OS adapter did not map uniquely to a host network interface.' }
        $gatewayInterfaceIndex = [int]$matchingHostAdapters[0].ifIndex
        $gatewayInterfaceGuid = [string]$matchingHostAdapters[0].InterfaceGuid
        $gatewayAddresses = @(Get-NetIPAddress -InterfaceIndex $gatewayInterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.IPAddress, $gatewayAddress, [StringComparison]::Ordinal)
        })
        if ($gatewayAddresses.Count -ne 1) { throw 'The InternetOnly gateway address is not pinned to the approved switch management interface.' }
        $internetNetworkBase = [string]$network.Base
        $networkPrefix = [string]$network.Prefix
        $natName = [string]$settings.NatName
        $natPrefix = [string]$settings.NatPrefix
        $prefixLength = 24
        $extendedAclIdleSessionTimeout = [int]$natPolicy.UdpIdleSessionTimeout
        $dnsServers = @($settings.DnsServers | ForEach-Object { [string]$_ })
        if ($dnsServers.Count -lt 1) {
            throw 'InternetOnly requires at least one broker-approved IPv4 DNS server.'
        }
        $canonicalDenies = @(Get-RequestNetworkCanonicalInternetDenyPrefixes)
        foreach ($dnsServer in $dnsServers) {
            try { $dnsAddress = [Net.IPAddress]::Parse($dnsServer) } catch { throw "InternetOnly DNS server is not an IP address: $dnsServer" }
            if ($dnsAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
                @($canonicalDenies | Where-Object { $_ -notlike '*:*' -and (Test-RequestNetworkIPv4InPrefix -Address $dnsServer -Prefix $_) }).Count -gt 0) {
                throw "InternetOnly DNS server must be a public IPv4 address: $dnsServer"
            }
        }
        $defaultRouteAttestation = @(Get-RequestNetworkInternetDefaultRouteAttestation)
        # Snapshot every current host route except the default plus every host
        # IPv4 address. Publicly numbered host/VPN/corporate routes are therefore
        # denied too; a route layout that would consume most of the Internet fails
        # closed instead of silently exposing it. The explicitly configured list
        # remains available for non-on-link LAN or environment-specific ranges.
        $hostRoutePrefixes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            -not [string]::Equals([string]$_.DestinationPrefix, '0.0.0.0/0', [StringComparison]::Ordinal)
        } | ForEach-Object { [string]$_.DestinationPrefix })
        $hostAddressPrefixes = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { ([string]$_.IPAddress) + '/32' })
        $denyRemotePrefixes = @($canonicalDenies + @($settings.DenyRemotePrefixes | ForEach-Object { [string]$_ }) + @($natPrefix) + $hostRoutePrefixes + $hostAddressPrefixes |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        [Array]::Sort($denyRemotePrefixes, [StringComparer]::OrdinalIgnoreCase)
    }
    elseif ($profile -eq 'TrustedLan') {
        $approved = @($Definition.Settings.AllowedSwitches)
        if ($approved.Count -ne 1) { throw 'TrustedLan policy did not resolve to one approved switch.' }
        $expectedNetAdapterInterfaceGuid = [string]$approved[0].NetAdapterInterfaceGuid
        $expectedNetAdapterInterfaceDescription = [string]$approved[0].NetAdapterInterfaceDescription
        $expectedAllowManagementOS = [bool]$approved[0].AllowManagementOS
        $switch = Assert-RequestNetworkPinnedSwitch -Name ([string]$approved[0].Name) -Id ([string]$approved[0].Id) -Type External `
            -ExpectedNetAdapterInterfaceGuid $expectedNetAdapterInterfaceGuid `
            -ExpectedNetAdapterInterfaceDescription $expectedNetAdapterInterfaceDescription `
            -ExpectedAllowManagementOS $expectedAllowManagementOS
    }

    $runtime = [pscustomobject][ordered]@{
        StatePath = Join-Path $leaseRoot ($RequestId + '.json')
        RequestId = $RequestId
        WorkerId = $WorkerId
        VmName = $VmName
        VmId = [string]$vm.Id
        Profile = $profile
        InstallationScope = $installationScope
        CohortHash = $cohortHash
        Status = 'Reserved'
        OwnerProcessId = $PID
        OwnerProcessStartUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        AdapterName = 'CodexRequestNet-' + $RequestId.Substring([Math]::Max(0, $RequestId.Length - 12))
        AdapterMacAddress = $null
        SwitchName = [string]$switch.Name
        SwitchId = [string]$switch.Id
        SwitchType = [string]$switch.SwitchType
        SwitchOwned = $switchOwned
        GuestAddress = $guestAddress
        PrefixLength = $prefixLength
        NetworkPrefix = $networkPrefix
        GatewayAddress = $gatewayAddress
        GatewayMacAddress = $gatewayMacAddress
        GatewayInterfaceIndex = $gatewayInterfaceIndex
        GatewayInterfaceGuid = $gatewayInterfaceGuid
        NatName = $natName
        NatPrefix = $natPrefix
        NatPolicy = $natPolicy
        DnsServers = $dnsServers
        EnforcedLocalAddress = $enforcedLocalAddress
        AllowedRemoteAddress = $allowedRemoteAddress
        AllowedRemoteMacAddress = $allowedRemoteMacAddress
        DenyRemotePrefixes = $denyRemotePrefixes
        PrimaryVlanId = $primaryVlanId
        SecondaryVlanId = $secondaryVlanId
        ExtendedAclIdleSessionTimeout = $extendedAclIdleSessionTimeout
        ExtendedAclWeights = $extendedAclWeights
        ExpectedNetAdapterInterfaceGuid = $expectedNetAdapterInterfaceGuid
        ExpectedNetAdapterInterfaceDescription = $expectedNetAdapterInterfaceDescription
        ExpectedAllowManagementOS = $expectedAllowManagementOS
        DefaultRouteAttestation = @($defaultRouteAttestation)
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        CleanupErrors = @()
    }
    if ($switchOwned) {
        Invoke-WithRequestNetworkMutex -Key ('switch:' + [string]$runtime.SwitchName) -Operation {
            $current = @(Get-VMSwitch -ErrorAction Stop | Where-Object {
                [string]::Equals([string]$_.Name, [string]$runtime.SwitchName, [StringComparison]::Ordinal)
            })
            if ($current.Count -gt 1) { throw "Managed isolated switch '$($runtime.SwitchName)' did not resolve uniquely before lease reservation." }
            $current = $current | Select-Object -First 1
            if (-not $current) {
                $current = New-VMSwitch -Name ([string]$runtime.SwitchName) -SwitchType Private -Notes ('CodexHarnessRequestNetwork:' + [string]$runtime.InstallationScope + ':' + [string]$runtime.CohortHash) -ErrorAction Stop
            }
            if ([string]$current.SwitchType -ne 'Private' -or [string]$current.Notes -ne ('CodexHarnessRequestNetwork:' + [string]$runtime.InstallationScope + ':' + [string]$runtime.CohortHash)) {
                throw "Managed isolated switch '$($runtime.SwitchName)' changed before its lease was reserved."
            }
            $runtime.SwitchId = [string]$current.Id
            Write-RequestNetworkLeaseState -Runtime $runtime -Status 'Reserved'
        }
    }
    elseif ($profile -eq 'InternetOnly') {
        Invoke-WithRequestNetworkMutex -Key ('internet-address:' + [string]$runtime.SwitchId) -Operation {
            $runtime.GuestAddress = Get-RequestNetworkInternetGuestAddress -NetworkBase $internetNetworkBase -RequestId $RequestId -GatewayAddress $gatewayAddress -NatName $natName -BrokerRoot $BrokerRoot
            $runtime.EnforcedLocalAddress = [string]$runtime.GuestAddress + '/32'
            Write-RequestNetworkLeaseState -Runtime $runtime -Status 'Reserved'
        }
    }
    else {
        Write-RequestNetworkLeaseState -Runtime $runtime -Status 'Reserved'
    }
    $runtime
}

function Assert-RequestNetworkAdapterEnforcement {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] $Adapter
    )

    if ([string]$Adapter.MacAddressSpoofing -ne 'Off' -or [string]$Adapter.DhcpGuard -ne 'On' -or [string]$Adapter.RouterGuard -ne 'On') {
        throw 'The request adapter no longer has its required spoofing, DHCP, and router guards.'
    }
    if ([string]$Runtime.Profile -eq 'InternetOnly') {
        $basicAcls = @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $Adapter -ErrorAction Stop)
        if ($basicAcls.Count -ne 0) {
            throw 'InternetOnly must not use basic IP/MAC ACLs whose cross-address-type precedence is undefined.'
        }
        $extendedAcls = @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $Adapter -ErrorAction Stop)
        $expectedRules = @(Get-RequestNetworkInternetExtendedAclRules -Runtime $Runtime)
        if ($extendedAcls.Count -ne $expectedRules.Count) {
            throw "The InternetOnly adapter has $($extendedAcls.Count) extended ACLs; expected exactly $($expectedRules.Count)."
        }
        $matched = New-Object 'Collections.Generic.HashSet[int]'
        foreach ($expected in $expectedRules) {
            $found = -1
            for ($index = 0; $index -lt $extendedAcls.Count; $index++) {
                if ($matched.Contains($index)) { continue }
                $actual = $extendedAcls[$index]
                if ((ConvertTo-RequestNetworkExtendedAclDirection -Value $actual.Direction) -ne [string]$expected.Direction -or
                    (ConvertTo-RequestNetworkExtendedAclAction -Value $actual.Action) -ne [string]$expected.Action -or
                    (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$actual.LocalIPAddress) -Upper) -ne (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$expected.LocalIPAddress) -Upper) -or
                    (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$actual.RemoteIPAddress) -Upper) -ne (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$expected.RemoteIPAddress) -Upper) -or
                    (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$actual.LocalPort) -Upper) -ne (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$expected.LocalPort) -Upper) -or
                    (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$actual.RemotePort) -Upper) -ne (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$expected.RemotePort) -Upper) -or
                    (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$actual.Protocol) -Upper) -ne (ConvertTo-RequestNetworkExtendedAclCanonicalValue -Value ([string]$expected.Protocol) -Upper) -or
                    [int]$actual.Weight -ne [int]$expected.Weight -or
                    [bool]$actual.Stateful -ne [bool]$expected.Stateful -or
                    [int]$actual.IdleSessionTimeout -ne [int]$expected.IdleSessionTimeout -or
                    [int]$actual.IsolationID -ne [int]$expected.IsolationID) {
                    continue
                }
                $found = $index
                break
            }
            if ($found -lt 0) {
                throw "The InternetOnly adapter is missing its exact $($expected.Direction) $($expected.Action) extended ACL for $($expected.LocalIPAddress) -> $($expected.RemoteIPAddress) ($($expected.Protocol), weight $($expected.Weight))."
            }
            [void]$matched.Add($found)
        }
        $null = Assert-RequestNetworkInternetVlan -Adapter $Adapter -PrimaryVlanId ([int]$Runtime.PrimaryVlanId) -SecondaryVlanId ([int]$Runtime.SecondaryVlanId) -PrivateVlanMode Isolated
        return [pscustomobject][ordered]@{
            InstalledAclCount = 0
            InstalledExtendedAclCount = $extendedAcls.Count
            InstalledVlan = $true
        }
    }
    $installedExtendedAcls = @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $Adapter -ErrorAction Stop)
    if ($installedExtendedAcls.Count -ne 0) {
        throw 'A non-InternetOnly request adapter contains an unexpected extended ACL.'
    }
    $installedAcls = @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $Adapter -ErrorAction Stop)
    $expectedAcls = New-Object Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.EnforcedLocalAddress)) {
        $expectedAcls.Add([pscustomobject][ordered]@{ Side = 'Local'; Address = [string]$Runtime.EnforcedLocalAddress; AddressType = 'IPv4'; Action = 'Allow' })
        $expectedAcls.Add([pscustomobject][ordered]@{ Side = 'Local'; Address = '0.0.0.0/0'; AddressType = 'WildcardIPv4'; Action = 'Deny' })
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteAddress)) {
        $expectedAcls.Add([pscustomobject][ordered]@{
            Side = 'Remote'; Address = [string]$Runtime.AllowedRemoteAddress
            AddressType = (Get-RequestNetworkIpAclAddressType -Address ([string]$Runtime.AllowedRemoteAddress))
            Action = 'Allow'
        })
    }
    foreach ($prefix in @($Runtime.DenyRemotePrefixes)) {
        $expectedAcls.Add([pscustomobject][ordered]@{
            Side = 'Remote'; Address = [string]$prefix
            AddressType = (Get-RequestNetworkIpAclAddressType -Address ([string]$prefix))
            Action = 'Deny'
        })
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteMacAddress)) {
        $expectedAcls.Add([pscustomobject][ordered]@{ Side = 'Remote'; Address = [string]$Runtime.AllowedRemoteMacAddress; AddressType = 'Mac'; Action = 'Allow' })
        $expectedAcls.Add([pscustomobject][ordered]@{ Side = 'Remote'; Address = 'ANY'; AddressType = 'WildcardMac'; Action = 'Deny' })
    }
    if ([string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteAddress) -xor [string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteMacAddress)) {
        throw 'The InternetOnly gateway ACL policy must pin both its IPv4 address and MAC address.'
    }

    $matchedAclCount = 0
    foreach ($expectedAcl in $expectedAcls) {
        $expectedAddress = ConvertTo-RequestNetworkCanonicalAclAddress -Address ([string]$expectedAcl.Address) -AddressType ([string]$expectedAcl.AddressType)
        $aclGroup = @($installedAcls | Where-Object {
            $actualAddress = if ([string]$expectedAcl.Side -eq 'Local') { [string]$_.LocalAddress } else { [string]$_.RemoteAddress }
            $actualAddressType = if ([string]$expectedAcl.Side -eq 'Local') { [string]$_.LocalAddressType } else { [string]$_.RemoteAddressType }
            $otherAddress = if ([string]$expectedAcl.Side -eq 'Local') { [string]$_.RemoteAddress } else { [string]$_.LocalAddress }
            [string]::Equals(
                (ConvertTo-RequestNetworkCanonicalAclAddress -Address $actualAddress -AddressType $actualAddressType),
                $expectedAddress,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals($actualAddressType, [string]$expectedAcl.AddressType, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$_.Action, [string]$expectedAcl.Action, [StringComparison]::Ordinal) -and
            [string]::IsNullOrWhiteSpace($otherAddress)
        })
        $directions = @($aclGroup | ForEach-Object { [string]$_.Direction })
        if (-not (Test-RequestNetworkBidirectionalDirections -Directions $directions)) {
            throw "The request adapter is missing its exact bidirectional $($expectedAcl.Side) $($expectedAcl.AddressType) $($expectedAcl.Action) ACL for $($expectedAcl.Address)."
        }
        $matchedAclCount += $aclGroup.Count
    }
    if ($matchedAclCount -ne $installedAcls.Count) {
        throw 'The request adapter contains an unexpected or overriding ACL outside the exact broker policy.'
    }
    [pscustomobject][ordered]@{
        InstalledAclCount = $installedAcls.Count
        InstalledExtendedAclCount = 0
        InstalledVlan = $false
    }
}

function Prepare-RequestVmNetwork {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    Import-Module Hyper-V -ErrorAction Stop
    Remove-ManagedRequestNetworkAdapters -VmName $VmName -BrokerRoot $BrokerRoot | Out-Null
    Add-VMNetworkAdapter -VMName $VmName -Name ([string]$Runtime.AdapterName) -DeviceNaming On -ErrorAction Stop | Out-Null
    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name ([string]$Runtime.AdapterName) -ErrorAction Stop
    Set-VMNetworkAdapter -VMNetworkAdapter $adapter -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On -ErrorAction Stop
    foreach ($existingAcl in @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -ErrorAction Stop)) {
        Remove-VMNetworkAdapterAcl -InputObject $existingAcl -ErrorAction Stop
    }
    foreach ($existingExtendedAcl in @(Get-VMNetworkAdapterExtendedAcl -VMNetworkAdapter $adapter -ErrorAction Stop)) {
        Remove-VMNetworkAdapterExtendedAcl -InputObject $existingExtendedAcl -ErrorAction Stop
    }
    if ([string]$Runtime.Profile -eq 'InternetOnly') {
        # The guest VLAN is configured before the adapter is connected. This
        # keeps the port isolated even if a later policy step fails closed.
        Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -Isolated -PrimaryVlanId ([int]$Runtime.PrimaryVlanId) -SecondaryVlanId ([int]$Runtime.SecondaryVlanId) -ErrorAction Stop
        foreach ($rule in @(Get-RequestNetworkInternetExtendedAclRules -Runtime $Runtime | Sort-Object Direction, Weight)) {
            $parameters = @{
                VMNetworkAdapter = $adapter
                Action = [string]$rule.Action
                Direction = [string]$rule.Direction
                LocalIPAddress = [string]$rule.LocalIPAddress
                RemoteIPAddress = [string]$rule.RemoteIPAddress
                LocalPort = [string]$rule.LocalPort
                RemotePort = [string]$rule.RemotePort
                Weight = [int]$rule.Weight
                Stateful = [bool]$rule.Stateful
                IsolationID = [int]$rule.IsolationID
                ErrorAction = 'Stop'
            }
            if ([bool]$rule.Stateful) {
                $parameters.IdleSessionTimeout = [int]$rule.IdleSessionTimeout
            }
            if ([string]$rule.Protocol -ne 'ANY') { $parameters.Protocol = [string]$rule.Protocol }
            Add-VMNetworkAdapterExtendedAcl @parameters | Out-Null
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.EnforcedLocalAddress)) {
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -LocalIPAddress ([string]$Runtime.EnforcedLocalAddress) -Direction Both -Action Allow -ErrorAction Stop | Out-Null
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -LocalIPAddress '0.0.0.0/0' -Direction Both -Action Deny -ErrorAction Stop | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteAddress)) {
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -RemoteIPAddress ([string]$Runtime.AllowedRemoteAddress) -Direction Both -Action Allow -ErrorAction Stop | Out-Null
        }
        foreach ($prefix in @($Runtime.DenyRemotePrefixes)) {
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -RemoteIPAddress ([string]$prefix) -Direction Both -Action Deny -ErrorAction Stop | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AllowedRemoteMacAddress)) {
            $gatewayMacForAcl = (([string]$Runtime.AllowedRemoteMacAddress) -replace '(.{2})(?!$)', '$1-')
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -RemoteMacAddress $gatewayMacForAcl -Direction Both -Action Allow -ErrorAction Stop | Out-Null
            Add-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -RemoteMacAddress 'ANY' -Direction Both -Action Deny -ErrorAction Stop | Out-Null
        }
    }
    $enforcement = Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $adapter
    $Runtime.AdapterMacAddress = [string]$adapter.MacAddress
    Write-RequestNetworkLeaseState -Runtime $Runtime -Status 'AdapterSecured'
    [pscustomobject][ordered]@{
        AdapterName = [string]$adapter.Name
        MacAddress = [string]$adapter.MacAddress
        SwitchName = $null
        Guards = [ordered]@{ MacAddressSpoofing = 'Off'; DhcpGuard = 'On'; RouterGuard = 'On' }
        DenyRemotePrefixes = @($Runtime.DenyRemotePrefixes)
        EnforcedLocalAddress = [string]$Runtime.EnforcedLocalAddress
        PrimaryVlanId = [int]$Runtime.PrimaryVlanId
        SecondaryVlanId = [int]$Runtime.SecondaryVlanId
        AllowedRemoteAddress = [string]$Runtime.AllowedRemoteAddress
        AllowedRemoteMacAddress = [string]$Runtime.AllowedRemoteMacAddress
        InstalledAclCount = [int]$enforcement.InstalledAclCount
        InstalledExtendedAclCount = [int]$enforcement.InstalledExtendedAclCount
        ConnectedAfterEnforcement = $false
    }
}

function Assert-RequestNetworkLeasedAttachments {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $leases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)
    $attachments = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.SwitchName, [string]$Runtime.SwitchName, [StringComparison]::Ordinal)
    })
    foreach ($attachment in $attachments) {
        $matchingLeases = @($leases | Where-Object {
            [string]::Equals([string]$_.SwitchId, [string]$Runtime.SwitchId, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$_.VmName, [string]$attachment.VMName, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$_.AdapterName, [string]$attachment.Name, [StringComparison]::Ordinal)
        })
        if ([string]$attachment.Name -notlike 'CodexRequestNet-*' -or $matchingLeases.Count -ne 1) {
            throw "The $($Runtime.Profile) switch has an adapter that is not bound to one active broker lease."
        }
        if ([string]$matchingLeases[0].Status -notin @('Connected', 'GuestNetworkReady') -or -not (Test-RequestNetworkOwnerAlive -State $matchingLeases[0])) {
            throw "The $($Runtime.Profile) switch has an adapter whose broker lease is stale or not in a connected state."
        }
        $attachedVm = @(Get-VM -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.Name, [string]$attachment.VMName, [StringComparison]::Ordinal)
        })
        if ($attachedVm.Count -ne 1 -or -not [string]::Equals([string]$attachedVm[0].Id, [string]$matchingLeases[0].VmId, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The $($Runtime.Profile) switch has an adapter whose VM identity no longer matches its lease."
        }
    }
    $attachments.Count
}

function Assert-RequestNetworkHostPolicyCurrent {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $vm = @(Get-VM -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.Name, [string]$Runtime.VmName, [StringComparison]::Ordinal)
    })
    if ($vm.Count -ne 1 -or -not [string]::Equals([string]$vm[0].Id, [string]$Runtime.VmId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The request-network VM identity no longer matches its lease.'
    }
    $switch = if ([string]$Runtime.Profile -eq 'TrustedLan') {
        Assert-RequestNetworkPinnedSwitch -Name ([string]$Runtime.SwitchName) -Id ([string]$Runtime.SwitchId) -Type External `
            -ExpectedNetAdapterInterfaceGuid ([string]$Runtime.ExpectedNetAdapterInterfaceGuid) `
            -ExpectedNetAdapterInterfaceDescription ([string]$Runtime.ExpectedNetAdapterInterfaceDescription) `
            -ExpectedAllowManagementOS ([bool]$Runtime.ExpectedAllowManagementOS)
    }
    else {
        Assert-RequestNetworkPinnedSwitch -Name ([string]$Runtime.SwitchName) -Id ([string]$Runtime.SwitchId) -Type ([string]$Runtime.SwitchType)
    }
    if ([string]$Runtime.Profile -eq 'IsolatedTestNet') {
        $expectedMarker = 'CodexHarnessRequestNetwork:' + [string]$Runtime.InstallationScope + ':' + [string]$Runtime.CohortHash
        if ([string]$switch.Notes -ne $expectedMarker) { throw 'The isolated request switch ownership marker changed.' }
    }
    $adapter = @(Get-VMNetworkAdapter -VMName ([string]$Runtime.VmName) -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.Name, [string]$Runtime.AdapterName, [StringComparison]::Ordinal)
    })
    if ($adapter.Count -ne 1 -or
        -not [string]::Equals([string]$adapter[0].SwitchName, [string]$Runtime.SwitchName, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$adapter[0].MacAddress, [string]$Runtime.AdapterMacAddress, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The connected request adapter no longer matches its lease.'
    }
    $enforcement = Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $adapter[0]
    $attachmentCount = if ([string]$Runtime.Profile -in @('IsolatedTestNet', 'InternetOnly')) {
        Assert-RequestNetworkLeasedAttachments -Runtime $Runtime -BrokerRoot $BrokerRoot
    }
    else { $null }
    $routeCount = 0
    $hostAddressCount = 0
    $gatewayVlan = $null
    $defaultRouteCheck = $null
    if ([string]$Runtime.Profile -eq 'InternetOnly') {
        if (-not $switch.PSObject.Properties['AllowManagementOS'] -or -not [bool]$switch.AllowManagementOS) {
            throw 'InternetOnly requires the pinned internal switch to allow the management operating system.'
        }
        $vlanIds = [pscustomobject]@{
            PrimaryVlanId = [int]$Runtime.PrimaryVlanId
            SecondaryVlanId = [int]$Runtime.SecondaryVlanId
        }
        if ($vlanIds.PrimaryVlanId -lt 1 -or $vlanIds.PrimaryVlanId -gt 4094 -or
            $vlanIds.SecondaryVlanId -lt 1 -or $vlanIds.SecondaryVlanId -gt 4094 -or
            $vlanIds.PrimaryVlanId -eq $vlanIds.SecondaryVlanId) {
            throw 'The InternetOnly lease does not contain two distinct valid private-VLAN IDs.'
        }
        $gatewayVlan = Assert-RequestNetworkInternetGatewayVlan -SwitchName ([string]$Runtime.SwitchName) -GatewayMacAddress ([string]$Runtime.GatewayMacAddress) -PrimaryVlanId $vlanIds.PrimaryVlanId -SecondaryVlanId $vlanIds.SecondaryVlanId
        if (-not (@($Runtime.DenyRemotePrefixes | Where-Object { [string]::Equals([string]$_, [string]$Runtime.NatPrefix, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 1)) {
            throw 'The InternetOnly NAT prefix is not explicitly present in the adapter deny policy.'
        }
        $allNats = @(Get-NetNat -ErrorAction Stop)
        $nat = @($allNats | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.NatName, [StringComparison]::Ordinal) })
        if ($allNats.Count -ne 1 -or $nat.Count -ne 1 -or
            -not [string]::Equals([string]$nat[0].InternalIPInterfaceAddressPrefix, [string]$Runtime.NatPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The sole approved InternetOnly NAT changed while the request was active.'
        }
        $null = Assert-RequestNetworkNatPolicy -Nat $nat[0] -ExpectedPolicy $Runtime.NatPolicy -ExpectedInternalPrefix ([string]$Runtime.NatPrefix)
        if (@(Get-RequestNetworkNatStaticMappings -NatName ([string]$Runtime.NatName)).Count -gt 0) {
            throw 'An inbound static mapping appeared on the InternetOnly NAT.'
        }
        $defaultRouteCheck = Assert-RequestNetworkInternetDefaultRouteAttestation -ExpectedAttestation (Get-RequestNetworkObjectPropertyValue -Value $Runtime -Name 'DefaultRouteAttestation')
        $hostAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            (([string]$_.MacAddress) -replace '[:-]', '') -eq (([string]$Runtime.GatewayMacAddress) -replace '[:-]', '')
        })
        if ($hostAdapters.Count -ne 1 -or [int]$hostAdapters[0].ifIndex -ne [int]$Runtime.GatewayInterfaceIndex -or
            -not [string]::Equals([string]$hostAdapters[0].InterfaceGuid, [string]$Runtime.GatewayInterfaceGuid, [StringComparison]::OrdinalIgnoreCase) -or
            @(Get-NetIPAddress -InterfaceIndex ([int]$Runtime.GatewayInterfaceIndex) -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
                [string]::Equals([string]$_.IPAddress, [string]$Runtime.GatewayAddress, [StringComparison]::Ordinal)
            }).Count -ne 1) {
            throw 'The InternetOnly gateway IP, interface, and MAC pin changed while the request was active.'
        }
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Where-Object { [string]$_.DestinationPrefix -ne '0.0.0.0/0' })
        $hostAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
        $routeCount = $routes.Count
        $hostAddressCount = $hostAddresses.Count
        foreach ($route in $routes) {
            $matchingDenyPrefixes = @($Runtime.DenyRemotePrefixes | Where-Object {
                $_ -notlike '*:*' -and (Test-RequestNetworkIPv4PrefixCovered -CandidatePrefix ([string]$route.DestinationPrefix) -CoveringPrefix ([string]$_))
            })
            if ($matchingDenyPrefixes.Count -eq 0) { throw "A host IPv4 route appeared outside the InternetOnly deny policy: $($route.DestinationPrefix)" }
        }
        foreach ($hostAddress in $hostAddresses) {
            $matchingDenyPrefixes = @($Runtime.DenyRemotePrefixes | Where-Object {
                $_ -notlike '*:*' -and (Test-RequestNetworkIPv4InPrefix -Address ([string]$hostAddress.IPAddress) -Prefix ([string]$_))
            })
            if ($matchingDenyPrefixes.Count -eq 0) { throw "A host IPv4 address appeared outside the InternetOnly deny policy: $($hostAddress.IPAddress)" }
        }
    }
    [pscustomobject][ordered]@{
        CheckedUtc = [DateTime]::UtcNow.ToString('o')
        Profile = [string]$Runtime.Profile
        SwitchId = [string]$Runtime.SwitchId
        AdapterName = [string]$Runtime.AdapterName
        InstalledAclCount = [int]$enforcement.InstalledAclCount
        InstalledExtendedAclCount = [int]$enforcement.InstalledExtendedAclCount
        PrimaryVlanId = [int]$Runtime.PrimaryVlanId
        SecondaryVlanId = [int]$Runtime.SecondaryVlanId
        GatewayVlan = $gatewayVlan
        DefaultRouteCount = if ($defaultRouteCheck) { [int]$defaultRouteCheck.DefaultRouteCount } else { 0 }
        DefaultRouteAttestation = if ($defaultRouteCheck) { @($defaultRouteCheck.DefaultRouteAttestation) } else { @() }
        LeasedAttachmentCount = $attachmentCount
        HostRouteCount = $routeCount
        HostAddressCount = $hostAddressCount
        BoundaryIntact = $true
    }
}

function Connect-RequestVmNetwork {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $vm = @(Get-VM -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.Name, $VmName, [StringComparison]::Ordinal)
    })
    if ($vm.Count -ne 1 -or -not [string]::Equals([string]$vm[0].Id, [string]$Runtime.VmId, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The request-network VM identity changed before connection.'
    }
    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name ([string]$Runtime.AdapterName) -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$adapter.SwitchName)) { throw 'The request adapter was connected before final policy verification.' }
    $null = Assert-RequestNetworkAdapterEnforcement -Runtime $Runtime -Adapter $adapter
    $approvedSwitch = if ([string]$Runtime.Profile -eq 'TrustedLan') {
        Assert-RequestNetworkPinnedSwitch -Name ([string]$Runtime.SwitchName) -Id ([string]$Runtime.SwitchId) -Type External `
            -ExpectedNetAdapterInterfaceGuid ([string]$Runtime.ExpectedNetAdapterInterfaceGuid) `
            -ExpectedNetAdapterInterfaceDescription ([string]$Runtime.ExpectedNetAdapterInterfaceDescription) `
            -ExpectedAllowManagementOS ([bool]$Runtime.ExpectedAllowManagementOS)
    }
    else {
        Assert-RequestNetworkPinnedSwitch -Name ([string]$Runtime.SwitchName) -Id ([string]$Runtime.SwitchId) -Type ([string]$Runtime.SwitchType)
    }
    if ([string]$Runtime.Profile -eq 'InternetOnly') {
        if (-not $approvedSwitch.PSObject.Properties['AllowManagementOS'] -or -not [bool]$approvedSwitch.AllowManagementOS) {
            throw 'InternetOnly requires the pinned internal switch to allow the management operating system.'
        }
        $null = Assert-RequestNetworkInternetGatewayVlan -SwitchName ([string]$Runtime.SwitchName) -GatewayMacAddress ([string]$Runtime.GatewayMacAddress) -PrimaryVlanId ([int]$Runtime.PrimaryVlanId) -SecondaryVlanId ([int]$Runtime.SecondaryVlanId)
    }
    Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -VMSwitch $approvedSwitch -ErrorAction Stop | Out-Null
    $connected = Get-VMNetworkAdapter -VMName $VmName -Name ([string]$Runtime.AdapterName) -ErrorAction Stop
    if (-not [string]::Equals([string]$connected.SwitchName, [string]$Runtime.SwitchName, [StringComparison]::Ordinal)) {
        throw 'The request network adapter did not connect to the approved switch.'
    }
    Write-RequestNetworkLeaseState -Runtime $Runtime -Status 'Connected'
    $hostPolicyCheck = Assert-RequestNetworkHostPolicyCurrent -Runtime $Runtime -BrokerRoot $BrokerRoot
    [pscustomobject][ordered]@{
        AdapterName = [string]$connected.Name
        MacAddress = [string]$connected.MacAddress
        SwitchName = [string]$connected.SwitchName
        ConnectedAfterEnforcement = $true
        HostPolicyCheck = $hostPolicyCheck
    }
}

function Reset-GuestRequestNetworkResidue {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] $Policy,
        [scriptblock] $ActivityCheck
    )

    if ($ActivityCheck) { & $ActivityCheck }
    $internetOnly = Get-RequestNetworkObjectPropertyValue -Value $Policy -Name 'InternetOnly'
    $gatewayAddress = [string](Get-RequestNetworkObjectPropertyValue -Value $internetOnly -Name 'GatewayAddress')
    if ([string]::IsNullOrWhiteSpace($gatewayAddress)) {
        return [pscustomobject][ordered]@{
            Attempted = $false
            Success = $true
            GatewayAddress = $null
            RemovedPersistentDefaultRouteCount = 0
            RemainingPersistentDefaultRouteCount = 0
        }
    }
    try {
        $parsedGateway = [Net.IPAddress]::Parse($gatewayAddress)
        if ($parsedGateway.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'not IPv4' }
        $gatewayAddress = $parsedGateway.ToString()
    }
    catch { throw 'InternetOnly.GatewayAddress is not a valid IPv4 address for guest residue cleanup.' }

    $remoteJob = Invoke-Command -Session $Session -AsJob -ErrorAction Stop -ScriptBlock {
        param($PinnedGatewayAddress)

        function Get-BrokerOwnedPersistentDefaultRoute {
            $routeErrors = @()
            $routes = @(
                Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue -ErrorVariable +routeErrors |
                    Where-Object {
                        [string]::Equals([string]$_.NextHop, $PinnedGatewayAddress, [StringComparison]::Ordinal)
                    }
            )
            $unexpectedErrors = @($routeErrors | Where-Object {
                $fullyQualifiedErrorId = [string]$_.FullyQualifiedErrorId
                $category = [string]$_.CategoryInfo.Category
                $reason = [string]$_.CategoryInfo.Reason
                $targetName = [string]$_.CategoryInfo.TargetName
                -not (
                    $fullyQualifiedErrorId.StartsWith('CmdletizationQuery_NotFound', [StringComparison]::Ordinal) -and
                    $fullyQualifiedErrorId.EndsWith(',Get-NetRoute', [StringComparison]::Ordinal) -and
                    [string]::Equals($category, 'ObjectNotFound', [StringComparison]::Ordinal) -and
                    [string]::Equals($reason, 'CimJobException', [StringComparison]::Ordinal) -and
                    $targetName -in @('IPv4', 'MSFT_NetRoute')
                )
            })
            if ($unexpectedErrors.Count -gt 0) {
                throw ('Persistent guest route inventory failed: ' + (($unexpectedErrors | ForEach-Object { $_.Exception.Message }) -join '; '))
            }
            $routes
        }

        $matchingRoutes = @(
            Get-BrokerOwnedPersistentDefaultRoute
        )
        foreach ($route in $matchingRoutes) {
            Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
        }
        $remainingRoutes = @(
            Get-BrokerOwnedPersistentDefaultRoute
        )
        if ($remainingRoutes.Count -ne 0) {
            throw 'The exact broker-owned InternetOnly persistent default route remained after guest cleanup.'
        }
        [pscustomobject][ordered]@{
            Attempted = $true
            Success = $true
            GatewayAddress = $PinnedGatewayAddress
            RemovedPersistentDefaultRouteCount = $matchingRoutes.Count
            RemainingPersistentDefaultRouteCount = $remainingRoutes.Count
        }
    } -ArgumentList $gatewayAddress | Select-Object -Last 1
    try {
        while ([string]$remoteJob.State -in @('NotStarted', 'Running')) {
            if ($ActivityCheck) { & $ActivityCheck }
            $null = Wait-Job -Job $remoteJob -Timeout 1
        }
        if ($ActivityCheck) { & $ActivityCheck }
        $result = Receive-Job -Job $remoteJob -Wait -ErrorAction Stop | Select-Object -Last 1
        if (-not $result -or -not [bool]$result.Success -or [int]$result.RemainingPersistentDefaultRouteCount -ne 0) {
            throw 'Guest request-network residue cleanup did not produce a positive zero-residue attestation.'
        }
        $result
    }
    finally {
        if ([string]$remoteJob.State -in @('NotStarted', 'Running')) { Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue }
        Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-GuestRequestNetwork {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] $Runtime,
        [scriptblock] $ActivityCheck
    )

    if ($ActivityCheck) { & $ActivityCheck }
    $expectedConnectedPrefixes = if ([string]$Runtime.Profile -ne 'TrustedLan') {
        @(Get-RequestNetworkExpectedGuestRoutePrefixes -NetworkPrefix ([string]$Runtime.NetworkPrefix) -GuestAddress ([string]$Runtime.GuestAddress) -PrefixLength ([int]$Runtime.PrefixLength))
    }
    else { @() }
    $guestFirewallRuleName = if ([string]$Runtime.Profile -eq 'IsolatedTestNet') {
        'CodexHarness-Isolated-' + (Get-RequestNetworkHash -Value ([string]$Runtime.RequestId)).Substring(0, 24)
    }
    else { '' }
    $remoteJob = Invoke-Command -Session $Session -AsJob -ErrorAction Stop -ScriptBlock {
        param($ExpectedMac, $Profile, $GuestAddress, $PrefixLength, $GatewayAddress, $GatewayMacAddress, $DnsServers, $ExpectedConnectedPrefixes, $NetworkPrefix, $GuestFirewallRuleName)

        $normalizedMac = $ExpectedMac -replace '[:-]', ''
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $adapter = $null
        do {
            $matchingAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
                (([string]$_.MacAddress) -replace '[:-]', '') -eq $normalizedMac
            })
            if ($matchingAdapters.Count -gt 1) { throw "Guest request-network MAC did not resolve uniquely: $ExpectedMac" }
            $adapter = $matchingAdapters | Select-Object -First 1
            if (-not $adapter) { Start-Sleep -Milliseconds 250 }
        } while (-not $adapter -and [DateTime]::UtcNow -lt $deadline)
        if (-not $adapter) { throw "Guest request-network adapter did not appear: $ExpectedMac" }
        Enable-NetAdapter -InputObject $adapter -Confirm:$false -ErrorAction Stop | Out-Null
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Forwarding Disabled -WeakHostSend Disabled -WeakHostReceive Disabled -ErrorAction Stop | Out-Null

        if ($Profile -eq 'TrustedLan') {
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            ipconfig.exe /renew ([string]$adapter.InterfaceAlias) | Out-Null
        }
        else {
            Disable-NetAdapterBinding -InterfaceDescription ([string]$adapter.InterfaceDescription) -ComponentID ms_tcpip6 -ErrorAction Stop | Out-Null
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop | Out-Null
            foreach ($route in @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })) {
                Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction Stop
            }
            foreach ($address in @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction Stop
            }
            $addressParameters = @{
                InterfaceIndex = [int]$adapter.ifIndex
                IPAddress = [string]$GuestAddress
                PrefixLength = [int]$PrefixLength
                AddressFamily = 'IPv4'
                ErrorAction = 'Stop'
            }
            New-NetIPAddress @addressParameters | Out-Null
            if ($Profile -eq 'InternetOnly') {
                $normalizedGatewayMac = ($GatewayMacAddress -replace '[:-]', '').ToUpperInvariant()
                if ($normalizedGatewayMac -notmatch '^[0-9A-F]{12}$') { throw 'InternetOnly received an invalid pinned gateway MAC address.' }
                $formattedGatewayMac = ($normalizedGatewayMac -replace '(.{2})(?!$)', '$1-')
            }
            else {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
        }

        $readyDeadline = [DateTime]::UtcNow.AddSeconds(45)
        $addresses = @()
        do {
            $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
                $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*'
            })
            if ($addresses.Count -eq 0) { Start-Sleep -Milliseconds 250 }
        } while ($addresses.Count -eq 0 -and [DateTime]::UtcNow -lt $readyDeadline)
        if ($addresses.Count -eq 0) { throw "Guest $Profile network did not obtain a preferred IPv4 address." }

        $isolatedInboundFirewallRule = $null
        if ($Profile -eq 'IsolatedTestNet') {
            if ([string]::IsNullOrWhiteSpace($GuestFirewallRuleName) -or $GuestFirewallRuleName -notmatch '^CodexHarness-Isolated-[0-9a-f]{24}$') {
                throw 'IsolatedTestNet received an invalid broker-owned guest firewall rule name.'
            }
            $existingRules = @(Get-NetFirewallRule -Name $GuestFirewallRuleName -ErrorAction SilentlyContinue)
            if ($existingRules.Count -gt 1) { throw 'The broker-owned isolated guest firewall rule did not resolve uniquely before creation.' }
            if ($existingRules.Count -eq 1) {
                Remove-NetFirewallRule -InputObject $existingRules[0] -ErrorAction Stop
            }
            New-NetFirewallRule -Name $GuestFirewallRuleName -DisplayName $GuestFirewallRuleName `
                -Description 'Ephemeral broker-owned same-cohort ingress for an isolated executable test.' `
                -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol Any `
                -InterfaceAlias ([string]$adapter.InterfaceAlias) -LocalAddress $GuestAddress -RemoteAddress $NetworkPrefix -ErrorAction Stop | Out-Null

            $createdRules = @(Get-NetFirewallRule -Name $GuestFirewallRuleName -ErrorAction Stop)
            if ($createdRules.Count -ne 1) { throw 'The broker-owned isolated guest firewall rule did not resolve uniquely after creation.' }
            $addressFilters = @($createdRules[0] | Get-NetFirewallAddressFilter -ErrorAction Stop)
            $interfaceFilters = @($createdRules[0] | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
            $localAddresses = @($addressFilters | ForEach-Object { @($_.LocalAddress) } | ForEach-Object { [string]$_ })
            $remoteAddresses = @($addressFilters | ForEach-Object { @($_.RemoteAddress) } | ForEach-Object { [string]$_ })
            $interfaceAliases = @($interfaceFilters | ForEach-Object { @($_.InterfaceAlias) } | ForEach-Object { [string]$_ })
            if ([string]$createdRules[0].Enabled -ne 'True' -or
                [string]$createdRules[0].Direction -ne 'Inbound' -or
                [string]$createdRules[0].Action -ne 'Allow' -or
                $addressFilters.Count -ne 1 -or $interfaceFilters.Count -ne 1 -or
                $localAddresses.Count -ne 1 -or -not [string]::Equals($localAddresses[0], $GuestAddress, [StringComparison]::OrdinalIgnoreCase) -or
                $remoteAddresses.Count -ne 1 -or -not [string]::Equals($remoteAddresses[0], $NetworkPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $interfaceAliases.Count -ne 1 -or -not [string]::Equals($interfaceAliases[0], [string]$adapter.InterfaceAlias, [StringComparison]::Ordinal)) {
                throw 'IsolatedTestNet did not attest its exact broker-owned same-cohort guest firewall boundary.'
            }
            $isolatedInboundFirewallRule = [ordered]@{
                Name = [string]$createdRules[0].Name
                Direction = [string]$createdRules[0].Direction
                Action = [string]$createdRules[0].Action
                Enabled = [string]$createdRules[0].Enabled
                InterfaceAlias = [string]$interfaceAliases[0]
                LocalAddress = [string]$localAddresses[0]
                RemoteAddress = [string]$remoteAddresses[0]
                Protocol = 'Any'
                Scope = 'DisposableGuestRun'
            }
        }

        $gatewayNeighbors = @()
        if ($Profile -eq 'InternetOnly') {
            # Address configuration can reset the neighbor table while the new address
            # transitions to Preferred. Pin the gateway only after that transition, and
            # do not expose broker-approved DNS until the exact pin is attested.
            Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $GatewayAddress -ErrorAction SilentlyContinue |
                Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
            New-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $GatewayAddress -LinkLayerAddress $formattedGatewayMac -State Permanent -ErrorAction Stop | Out-Null

            $gatewayNeighborAttested = $false
            $gatewayNeighborQueryError = $null
            $neighborDeadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                try {
                    $gatewayNeighbors = @(Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $GatewayAddress -ErrorAction Stop)
                    $gatewayNeighborQueryError = $null
                }
                catch {
                    $gatewayNeighbors = @()
                    $gatewayNeighborQueryError = [pscustomobject][ordered]@{
                        Type = $_.Exception.GetType().FullName
                        FullyQualifiedErrorId = [string]$_.FullyQualifiedErrorId
                    }
                }
                if ($gatewayNeighbors.Count -eq 1) {
                    $observedGatewayMac = (([string]$gatewayNeighbors[0].LinkLayerAddress) -replace '[:-]', '').ToUpperInvariant()
                    $observedGatewayStateName = [string]$gatewayNeighbors[0].State
                    $observedGatewayStateValue = $null
                    try { $observedGatewayStateValue = [int]$gatewayNeighbors[0].State } catch { $observedGatewayStateValue = $null }
                    $gatewayStateIsPermanent = (
                        [string]::Equals($observedGatewayStateName, 'Permanent', [StringComparison]::Ordinal) -or
                        $observedGatewayStateValue -eq 6
                    )
                    $gatewayNeighborAttested = (
                        [string]::Equals([string]$gatewayNeighbors[0].IPAddress, $GatewayAddress, [StringComparison]::Ordinal) -and
                        $observedGatewayMac -eq $normalizedGatewayMac -and
                        $gatewayStateIsPermanent
                    )
                }
                if (-not $gatewayNeighborAttested -and [DateTime]::UtcNow -lt $neighborDeadline) {
                    Start-Sleep -Milliseconds 250
                }
            } while (-not $gatewayNeighborAttested -and [DateTime]::UtcNow -lt $neighborDeadline)

            if (-not $gatewayNeighborAttested) {
                $neighborSummary = @($gatewayNeighbors | ForEach-Object {
                    $stateValue = $null
                    try { $stateValue = [int]$_.State } catch { $stateValue = $null }
                    [ordered]@{
                        IPAddress = [string]$_.IPAddress
                        LinkLayerAddress = [string]$_.LinkLayerAddress
                        StateName = [string]$_.State
                        StateValue = $stateValue
                        StateType = if ($null -ne $_.State) { $_.State.GetType().FullName } else { $null }
                    }
                })
                $diagnostic = [ordered]@{
                    ExpectedIPAddress = [string]$GatewayAddress
                    ExpectedLinkLayerAddress = [string]$formattedGatewayMac
                    InterfaceIndex = [int]$adapter.ifIndex
                    ObservedCount = [int]$gatewayNeighbors.Count
                    Observed = $neighborSummary
                    QueryError = $gatewayNeighborQueryError
                } | ConvertTo-Json -Depth 6 -Compress
                throw "InternetOnly did not attest the permanent pinned gateway neighbor after bounded convergence. Exact observation: $diagnostic"
            }
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $GatewayAddress -PolicyStore ActiveStore -RouteMetric 256 -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($DnsServers) -ErrorAction Stop
        }

        $allAddresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop)
        $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object DestinationPrefix, NextHop, RouteMetric)
        $defaultRoutes = @($routes | Where-Object DestinationPrefix -eq '0.0.0.0/0')
        $connectedRoutes = @($routes | Where-Object { [string]$_.DestinationPrefix -in @($ExpectedConnectedPrefixes) })
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { @($_.ServerAddresses) })
        $ipv6Bindings = @(Get-NetAdapterBinding -InterfaceDescription ([string]$adapter.InterfaceDescription) -ComponentID ms_tcpip6 -ErrorAction Stop)
        if ($Profile -ne 'TrustedLan') {
            if ($allAddresses.Count -ne 1 -or $addresses.Count -ne 1 -or
                -not [string]::Equals([string]$addresses[0].IPAddress, $GuestAddress, [StringComparison]::Ordinal) -or
                [int]$addresses[0].PrefixLength -ne [int]$PrefixLength) {
                throw "$Profile did not attest exactly the configured IPv4 address and prefix."
            }
            if ($ipv6Bindings.Count -ne 1 -or [bool]$ipv6Bindings[0].Enabled) {
                throw "$Profile did not attest a disabled IPv6 binding."
            }
            $networkRouteCount = @($connectedRoutes | Where-Object { [string]$_.DestinationPrefix -eq [string]$ExpectedConnectedPrefixes[0] }).Count
            $invalidConnectedRoutes = @($connectedRoutes | Where-Object {
                [string]$_.NextHop -notin @('', '0.0.0.0', 'On-link')
            })
            $unexpectedRoutes = @($routes | Where-Object {
                $destination = [string]$_.DestinationPrefix
                if ($destination -eq '0.0.0.0/0' -and $Profile -eq 'InternetOnly') { return $false }
                if ($destination -in @($ExpectedConnectedPrefixes) -and [string]$_.NextHop -in @('', '0.0.0.0', 'On-link')) { return $false }
                $true
            })
            if ($networkRouteCount -lt 1 -or $invalidConnectedRoutes.Count -gt 0 -or $unexpectedRoutes.Count -gt 0) {
                $routeSummary = @($routes | ForEach-Object { [string]$_.DestinationPrefix + ' via ' + [string]$_.NextHop }) -join '; '
                throw "$Profile did not attest only the expected connected subnet routes. Exact routes: $routeSummary"
            }
        }
        if ($Profile -eq 'IsolatedTestNet') {
            if ($defaultRoutes.Count -ne 0) { throw 'IsolatedTestNet unexpectedly acquired a default route.' }
            if ($dns.Count -ne 0) { throw 'IsolatedTestNet unexpectedly retained an IPv4 DNS server.' }
        }
        if ($Profile -eq 'InternetOnly') {
            if ($defaultRoutes.Count -ne 1 -or -not [string]::Equals([string]$defaultRoutes[0].NextHop, $GatewayAddress, [StringComparison]::Ordinal)) {
                throw 'InternetOnly did not attest exactly one approved default route.'
            }
            if ($dns.Count -ne @($DnsServers).Count -or @($DnsServers | Where-Object { $dns -notcontains [string]$_ }).Count -gt 0) {
                throw 'InternetOnly did not attest exactly the broker-approved DNS server set.'
            }
            $gatewayNeighbors = @(Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $GatewayAddress -ErrorAction Stop)
            $finalGatewayStateName = if ($gatewayNeighbors.Count -eq 1) { [string]$gatewayNeighbors[0].State } else { $null }
            $finalGatewayStateValue = $null
            if ($gatewayNeighbors.Count -eq 1) {
                try { $finalGatewayStateValue = [int]$gatewayNeighbors[0].State } catch { $finalGatewayStateValue = $null }
            }
            if ($gatewayNeighbors.Count -ne 1 -or
                -not [string]::Equals([string]$gatewayNeighbors[0].IPAddress, $GatewayAddress, [StringComparison]::Ordinal) -or
                (([string]$gatewayNeighbors[0].LinkLayerAddress) -replace '[:-]', '').ToUpperInvariant() -ne $normalizedGatewayMac -or
                (-not [string]::Equals($finalGatewayStateName, 'Permanent', [StringComparison]::Ordinal) -and $finalGatewayStateValue -ne 6)) {
                throw 'InternetOnly lost the attested permanent pinned gateway neighbor before guest launch.'
            }
        }
        [pscustomobject][ordered]@{
            Profile = $Profile
            InterfaceAlias = [string]$adapter.Name
            InterfaceIndex = [int]$adapter.ifIndex
            MacAddress = [string]$adapter.MacAddress
            IPv4Addresses = @($addresses | ForEach-Object { [ordered]@{ Address = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
            Routes = @($routes | ForEach-Object { [ordered]@{ DestinationPrefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; RouteMetric = [int]$_.RouteMetric } })
            ConnectedRoutes = @($connectedRoutes | ForEach-Object { [ordered]@{ DestinationPrefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; RouteMetric = [int]$_.RouteMetric } })
            DefaultRoutes = @($defaultRoutes | ForEach-Object { [ordered]@{ DestinationPrefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; RouteMetric = [int]$_.RouteMetric } })
            DnsServers = @($dns)
            IPv6BindingEnabled = if ($ipv6Bindings.Count -eq 1) { [bool]$ipv6Bindings[0].Enabled } else { $null }
            GatewayNeighbor = if ($Profile -eq 'InternetOnly') {
                [ordered]@{
                    IPAddress = [string]$gatewayNeighbors[0].IPAddress
                    LinkLayerAddress = [string]$gatewayNeighbors[0].LinkLayerAddress
                    StateName = [string]$finalGatewayStateName
                    StateValue = [int]$finalGatewayStateValue
                }
            }
            else { $null }
            IsolatedInboundFirewallRule = $isolatedInboundFirewallRule
            BoundaryAttested = $true
        }
    } -ArgumentList ([string]$Runtime.AdapterMacAddress), ([string]$Runtime.Profile), ([string]$Runtime.GuestAddress), ([int]$Runtime.PrefixLength), ([string]$Runtime.GatewayAddress), ([string]$Runtime.GatewayMacAddress), @($Runtime.DnsServers), @($expectedConnectedPrefixes), ([string]$Runtime.NetworkPrefix), $guestFirewallRuleName | Select-Object -Last 1
    try {
        while ([string]$remoteJob.State -in @('NotStarted', 'Running')) {
            if ($ActivityCheck) { & $ActivityCheck }
            $null = Wait-Job -Job $remoteJob -Timeout 1
        }
        if ($ActivityCheck) { & $ActivityCheck }
        $result = Receive-Job -Job $remoteJob -Wait -ErrorAction Stop | Select-Object -Last 1
        if (-not $result -or -not [bool]$result.BoundaryAttested) { throw 'The guest request-network boundary did not produce a positive attestation.' }
    }
    finally {
        if ([string]$remoteJob.State -in @('NotStarted', 'Running')) { Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue }
        Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
    }
    Write-RequestNetworkLeaseState -Runtime $Runtime -Status 'GuestNetworkReady'
    $result
}

function ConvertFrom-RequestNetworkLeaseState {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string] $StatePath
    )

    [pscustomobject][ordered]@{
        StatePath = $StatePath
        RequestId = [string]$State.RequestId
        WorkerId = [int]$State.WorkerId
        VmName = [string]$State.VmName
        VmId = [string]$State.VmId
        Profile = [string]$State.Profile
        InstallationScope = [string]$State.InstallationScope
        CohortHash = [string]$State.CohortHash
        Status = [string]$State.Status
        OwnerProcessId = [int]$State.OwnerProcessId
        OwnerProcessStartUtc = [string]$State.OwnerProcessStartUtc
        AdapterName = [string]$State.AdapterName
        AdapterMacAddress = [string]$State.AdapterMacAddress
        SwitchName = [string]$State.SwitchName
        SwitchId = [string]$State.SwitchId
        SwitchType = [string]$State.SwitchType
        SwitchOwned = [bool]$State.SwitchOwned
        GuestAddress = [string]$State.GuestAddress
        PrefixLength = [int]$State.PrefixLength
        NetworkPrefix = [string]$State.NetworkPrefix
        GatewayAddress = [string]$State.GatewayAddress
        GatewayMacAddress = [string]$State.GatewayMacAddress
        GatewayInterfaceIndex = [int]$State.GatewayInterfaceIndex
        GatewayInterfaceGuid = [string]$State.GatewayInterfaceGuid
        PrimaryVlanId = [int]$State.PrimaryVlanId
        SecondaryVlanId = [int]$State.SecondaryVlanId
        NatName = [string]$State.NatName
        NatPrefix = [string]$State.NatPrefix
        NatPolicy = $State.NatPolicy
        DnsServers = @($State.DnsServers)
        EnforcedLocalAddress = [string]$State.EnforcedLocalAddress
        ExtendedAclIdleSessionTimeout = [int]$State.ExtendedAclIdleSessionTimeout
        ExtendedAclWeights = if (Get-RequestNetworkObjectPropertyValue -Value $State -Name 'ExtendedAclWeights') { Get-RequestNetworkObjectPropertyValue -Value $State -Name 'ExtendedAclWeights' } else { Get-RequestNetworkInternetExtendedAclWeights }
        AllowedRemoteAddress = [string]$State.AllowedRemoteAddress
        AllowedRemoteMacAddress = [string]$State.AllowedRemoteMacAddress
        DenyRemotePrefixes = @($State.DenyRemotePrefixes)
        DefaultRouteAttestation = @((Get-RequestNetworkObjectPropertyValue -Value $State -Name 'DefaultRouteAttestation'))
        ExpectedNetAdapterInterfaceGuid = [string]$State.ExpectedNetAdapterInterfaceGuid
        ExpectedNetAdapterInterfaceDescription = [string]$State.ExpectedNetAdapterInterfaceDescription
        ExpectedAllowManagementOS = if ($null -ne $State.ExpectedAllowManagementOS) { [Nullable[bool]]([bool]$State.ExpectedAllowManagementOS) } else { $null }
        CreatedUtc = [string]$State.CreatedUtc
        UpdatedUtc = [string]$State.UpdatedUtc
        CleanupErrors = @($State.CleanupErrors)
    }
}

function Get-RequestNetworkAdapterLeaseOwnership {
    param(
        [object[]] $LeaseInventory,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $VmId,
        [Parameter(Mandatory = $true)] [string] $AdapterName
    )

    $matches = @($LeaseInventory | Where-Object {
        $_ -and [string]::Equals([string]$_.VmName, $VmName, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$_.AdapterName, $AdapterName, [StringComparison]::Ordinal)
    })
    if ($matches.Count -gt 1) {
        throw "Managed adapter '$AdapterName' on VM '$VmName' has ambiguous lease ownership."
    }
    if ($matches.Count -eq 0) { return $null }
    if (-not [string]::Equals([string]$matches[0].VmId, $VmId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed adapter '$AdapterName' on VM '$VmName' has a lease for a different VM identity."
    }
    $matches[0]
}

function Remove-ManagedRequestNetworkAdapters {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    # Read the SYSTEM-only lease inventory before looking at or mutating any
    # adapter. An unreadable or structurally ambiguous inventory is an explicit
    # fail-closed condition; a name prefix alone never proves ownership.
    $leases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)
    $vmMatches = @(Get-VM -Name $VmName -ErrorAction Stop)
    if ($vmMatches.Count -ne 1) { throw "Managed VM '$VmName' did not resolve uniquely for adapter cleanup." }
    $vmId = [string]$vmMatches[0].Id
    if ([string]::IsNullOrWhiteSpace($vmId)) { throw "Managed VM '$VmName' has no authoritative identity for adapter cleanup." }
    $adapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Where-Object { $_.Name -like 'CodexRequestNet-*' })
    $plans = New-Object Collections.Generic.List[object]
    $skippedActive = New-Object Collections.Generic.List[string]

    # Complete ownership preflight happens before the first disconnect or
    # removal. This keeps a single ambiguous adapter from allowing name-based
    # cleanup of a different adapter in the same VM.
    foreach ($adapter in $adapters) {
        $owner = Get-RequestNetworkAdapterLeaseOwnership -LeaseInventory $leases -VmName $VmName -VmId $vmId -AdapterName ([string]$adapter.Name)
        if ($owner -and (Test-RequestNetworkLeaseActive -State $owner)) {
            $skippedActive.Add([string]$adapter.Name)
            continue
        }
        $plans.Add($adapter)
    }

    $removed = New-Object Collections.Generic.List[string]
    $errors = New-Object Collections.Generic.List[string]
    foreach ($adapter in $plans) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.SwitchName)) {
                Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter -ErrorAction Stop | Out-Null
            }
            $remaining = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$adapter.Name, [StringComparison]::Ordinal) })
            if ($remaining.Count -gt 1) { throw "Managed adapter '$($adapter.Name)' no longer resolves uniquely." }
            if ($remaining.Count -eq 1) { Remove-VMNetworkAdapter -VMNetworkAdapter $remaining[0] -ErrorAction Stop }
            if (@(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$adapter.Name, [StringComparison]::Ordinal) }).Count -ne 0) {
                throw "Managed adapter '$($adapter.Name)' still exists after removal."
            }
            $removed.Add([string]$adapter.Name)
        }
        catch { $errors.Add($_.Exception.Message) }
    }
    if ($errors.Count -gt 0) { throw ('Managed request-network adapter cleanup failed: ' + ($errors -join ' | ')) }
    [pscustomobject][ordered]@{
        Success = $true
        Errors = @()
        RemovedAdapters = $removed.ToArray()
        SkippedActiveAdapters = $skippedActive.ToArray()
    }
}

function Remove-RequestNetworkRuntime {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [switch] $SuppressErrors
    )

    $errors = New-Object Collections.Generic.List[string]
    $disconnected = $false
    $adapterRemoved = $false
    $switchRemoved = $false
    $stateDeleted = $false
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Runtime.RequestId) -or
            [string]::IsNullOrWhiteSpace([string]$Runtime.VmName) -or
            [string]::IsNullOrWhiteSpace([string]$Runtime.VmId) -or
            [string]::IsNullOrWhiteSpace([string]$Runtime.AdapterName)) {
            throw 'The request-network runtime is missing its authoritative lease identity.'
        }
        $leaseRoot = [IO.Path]::GetFullPath((Get-RequestNetworkLeaseRoot -BrokerRoot $BrokerRoot)).TrimEnd('\') + '\'
        $statePath = [IO.Path]::GetFullPath([string]$Runtime.StatePath)
        if (-not $statePath.StartsWith($leaseRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The request-network runtime state path is outside the authoritative broker lease root.'
        }
        $leases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)
        $owner = Get-RequestNetworkAdapterLeaseOwnership -LeaseInventory $leases -VmName ([string]$Runtime.VmName) -VmId ([string]$Runtime.VmId) -AdapterName ([string]$Runtime.AdapterName)
        if (-not $owner -or -not [string]::Equals([string]$owner.RequestId, [string]$Runtime.RequestId, [StringComparison]::Ordinal)) {
            throw 'The request-network adapter is not owned by the exact runtime lease; cleanup refused to mutate it.'
        }
        $currentVm = @(Get-VM -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.VmName, [StringComparison]::Ordinal) })
        if ($currentVm.Count -gt 1) { throw 'The leased VM name no longer resolves uniquely.' }
        if ($currentVm.Count -eq 1 -and -not [string]::Equals([string]$currentVm[0].Id, [string]$Runtime.VmId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The leased VM name now identifies a different VM; cleanup refused to mutate it.'
        }
        if ($currentVm.Count -eq 0) {
            $disconnected = $true
            $adapterRemoved = $true
        }
        else {
            $adapters = @(Get-VMNetworkAdapter -VMName ([string]$Runtime.VmName) -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.AdapterName, [StringComparison]::Ordinal) })
            if ($adapters.Count -gt 1) { throw 'The leased adapter name no longer resolves uniquely.' }
            if ($adapters.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$adapters[0].SwitchName)) {
                Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -ErrorAction Stop | Out-Null
            }
            $remaining = @(Get-VMNetworkAdapter -VMName ([string]$Runtime.VmName) -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.AdapterName, [StringComparison]::Ordinal) })
            if ($remaining.Count -gt 1) { throw 'The leased adapter name no longer resolves uniquely after disconnect.' }
            $disconnected = $remaining.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$remaining[0].SwitchName)
            if (-not $disconnected) { throw 'The request adapter remained connected after disconnect.' }
        }
    }
    catch { $errors.Add("Disconnect: $($_.Exception.Message)") }

    if ($disconnected -and -not $adapterRemoved) {
        try {
            $adapters = @(Get-VMNetworkAdapter -VMName ([string]$Runtime.VmName) -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.AdapterName, [StringComparison]::Ordinal) })
            if ($adapters.Count -gt 1) { throw 'The leased adapter name no longer resolves uniquely before removal.' }
            if ($adapters.Count -eq 1) { Remove-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -ErrorAction Stop }
            $adapterRemoved = @(Get-VMNetworkAdapter -VMName ([string]$Runtime.VmName) -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.AdapterName, [StringComparison]::Ordinal) }).Count -eq 0
            if (-not $adapterRemoved) { throw 'The disconnected request adapter still exists.' }
        }
        catch { $errors.Add("Adapter removal: $($_.Exception.Message)") }
    }

    if ($errors.Count -eq 0 -and [bool]$Runtime.SwitchOwned) {
            try {
                $switchRemoved = [bool](Invoke-WithRequestNetworkMutex -Key ('switch:' + [string]$Runtime.SwitchName) -Operation {
                    $otherLease = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot | Where-Object {
                        $_ -and -not [string]::Equals([string]$_.RequestId, [string]$Runtime.RequestId, [StringComparison]::Ordinal) -and
                        [string]::Equals([string]$_.SwitchId, [string]$Runtime.SwitchId, [StringComparison]::OrdinalIgnoreCase)
                    })
                    $attached = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.SwitchName, [string]$Runtime.SwitchName, [StringComparison]::Ordinal) })
                    if ($otherLease.Count -eq 0 -and $attached.Count -eq 0) {
                        $managedSwitch = @(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$Runtime.SwitchName, [StringComparison]::Ordinal) })
                        if ($managedSwitch.Count -gt 1) { throw 'The leased isolated switch name no longer resolves uniquely.' }
                        if ($managedSwitch.Count -eq 0) { return $true }
                        $expectedMarker = 'CodexHarnessRequestNetwork:' + [string]$Runtime.InstallationScope + ':' + [string]$Runtime.CohortHash
                        if (-not [string]::Equals([string]$managedSwitch[0].Id, [string]$Runtime.SwitchId, [StringComparison]::OrdinalIgnoreCase) -or [string]$managedSwitch[0].Notes -ne $expectedMarker) {
                            throw 'The leased isolated switch identity changed; cleanup refused to mutate it.'
                        }
                        Remove-VMSwitch -VMSwitch $managedSwitch[0] -Force -ErrorAction Stop
                        return @(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Id, [string]$Runtime.SwitchId, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
                    }
                    $false
                })
            }
            catch { $errors.Add("Switch cleanup: $($_.Exception.Message)") }
    }
    if ($errors.Count -eq 0) {
        try {
            if (Test-Path -LiteralPath ([string]$Runtime.StatePath) -PathType Leaf -ErrorAction Stop) {
                Remove-Item -LiteralPath ([string]$Runtime.StatePath) -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath ([string]$Runtime.StatePath) -PathType Leaf -ErrorAction Stop) { throw 'The request-network lease file still exists after deletion.' }
            $stateDeleted = $true
        }
        catch { $errors.Add("Lease deletion: $($_.Exception.Message)") }
    }
    $Runtime.CleanupErrors = $errors.ToArray()
    if ($errors.Count -gt 0) {
        try { Write-RequestNetworkLeaseState -Runtime $Runtime -Status 'CleanupFailed' } catch { }
    }
    $result = [pscustomobject][ordered]@{
        Success = $errors.Count -eq 0
        Errors = $errors.ToArray()
        Disconnected = $disconnected
        AdapterRemoved = $adapterRemoved
        SwitchRemoved = $switchRemoved
        StateDeleted = $stateDeleted
    }
    if (-not $result.Success -and -not $SuppressErrors) {
        throw ('Request-network cleanup failed: ' + ($result.Errors -join ' | '))
    }
    $result
}

function Get-RequestNetworkManagedVmNames {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $configPath = Join-Path $BrokerRoot 'Private\config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return @() }
    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        @((@($config.PoolWorkers | ForEach-Object { [string]$_.VmName }) + @([string]$config.VmName)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }
    catch { throw "Could not read the managed VM inventory for request-network recovery: $($_.Exception.Message)" }
}

function Get-InstalledRequestNetworkPolicy {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)

    $configPath = Join-Path $BrokerRoot 'Private\config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return Get-RequestNetworkDefaultPolicy }
    try {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        Get-RequestNetworkPolicy -Config $config
    }
    catch { throw "Could not read the installed request-network policy for orphan recovery: $($_.Exception.Message)" }
}

function Recover-OrphanedRequestNetworkResources {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [string] $ExcludeRequestId
    )

    $leaseRoot = Get-RequestNetworkLeaseRoot -BrokerRoot $BrokerRoot
    $recovered = New-Object Collections.Generic.List[object]
    # Establish one complete, SYSTEM-owned inventory before any orphan
    # mutation. A missing, unreadable, malformed, or ambiguous lease record is
    # never treated as proof that a matching adapter is orphaned.
    $authoritativeLeases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot)
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $leaseRoot -Filter '*.json' -File -ErrorAction Stop)) {
        try {
            $state = @($authoritativeLeases | Where-Object {
                $_ -and [string]::Equals([string]$_.StatePath, [string]$stateFile.FullName, [StringComparison]::OrdinalIgnoreCase)
            }) | Select-Object -First 1
            if (-not $state) { throw "The authoritative lease inventory has no entry for '$($stateFile.FullName)'." }
            if (-not [string]::IsNullOrWhiteSpace($ExcludeRequestId) -and [string]::Equals([string]$state.RequestId, $ExcludeRequestId, [StringComparison]::Ordinal)) { continue }
            # A live owner protects only an active request. CleanupFailed and
            # other terminal lease records are recovery work even when the
            # broker PID is still alive (for example after a cleanup exception
            # was caught and the broker moved on to its next request).
            if (Test-RequestNetworkLeaseActive -State $state) { continue }
            $runtime = ConvertFrom-RequestNetworkLeaseState -State $state -StatePath $stateFile.FullName
            $cleanup = Remove-RequestNetworkRuntime -Runtime $runtime -BrokerRoot $BrokerRoot -SuppressErrors
            $recovered.Add([pscustomobject][ordered]@{ RequestId = $runtime.RequestId; Success = [bool]$cleanup.Success; Errors = @($cleanup.Errors) })
        }
        catch {
            $recovered.Add([pscustomobject][ordered]@{ RequestId = [IO.Path]::GetFileNameWithoutExtension($stateFile.Name); Success = $false; Errors = @($_.Exception.Message) })
        }
    }

    try { $remainingLeases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot) }
    catch {
        $recovered.Add([pscustomobject][ordered]@{ RequestId = $null; Success = $false; Errors = @($_.Exception.Message) })
        throw ('Request-network orphan recovery could not establish an authoritative lease inventory: ' + $_.Exception.Message)
    }

    $adapterPlans = New-Object Collections.Generic.List[object]
    foreach ($vmName in @(Get-RequestNetworkManagedVmNames -BrokerRoot $BrokerRoot)) {
        $vmMatches = @(Get-VM -Name $vmName -ErrorAction Stop)
        if ($vmMatches.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$vmMatches[0].Id)) {
            throw "Managed VM '$vmName' did not resolve uniquely for owner-bound orphan cleanup."
        }
        $vmId = [string]$vmMatches[0].Id
        foreach ($adapter in @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { $_.Name -like 'CodexRequestNet-*' })) {
            $owner = Get-RequestNetworkAdapterLeaseOwnership -LeaseInventory $remainingLeases -VmName $vmName -VmId $vmId -AdapterName ([string]$adapter.Name)
            # Any authoritative owner, including a terminal lease whose
            # cleanup previously failed, protects the adapter from a second
            # name-based deletion pass. Only an exact no-owner match is an
            # orphan candidate.
            if ($owner) { continue }
            $adapterPlans.Add([pscustomobject][ordered]@{ VmName = $vmName; Adapter = $adapter })
        }
    }
    foreach ($plan in $adapterPlans) {
        $adapter = $plan.Adapter
        $vmName = [string]$plan.VmName
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.SwitchName)) { Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter -ErrorAction Stop | Out-Null }
            $remainingAdapter = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$adapter.Name, [StringComparison]::Ordinal) })
            if ($remainingAdapter.Count -gt 1) { throw "Orphaned managed adapter '$($adapter.Name)' no longer resolves uniquely." }
            if ($remainingAdapter.Count -eq 1) { Remove-VMNetworkAdapter -VMNetworkAdapter $remainingAdapter[0] -ErrorAction Stop }
            if (@(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$adapter.Name, [StringComparison]::Ordinal) }).Count -ne 0) {
                throw "Orphaned managed adapter '$($adapter.Name)' still exists after removal."
            }
            $recovered.Add([pscustomobject][ordered]@{ RequestId = $null; Success = $true; Errors = @() })
        }
        catch { $recovered.Add([pscustomobject][ordered]@{ RequestId = $null; Success = $false; Errors = @($_.Exception.Message) }) }
    }

    $policy = Get-InstalledRequestNetworkPolicy -BrokerRoot $BrokerRoot
    $isolatedPolicy = Get-RequestNetworkObjectPropertyValue -Value $policy -Name 'IsolatedTestNet'
    $switchPrefix = [string](Get-RequestNetworkObjectPropertyValue -Value $isolatedPolicy -Name 'SwitchPrefix')
    $installationScope = Get-RequestNetworkInstallationScope -BrokerRoot $BrokerRoot
    if (-not [string]::IsNullOrWhiteSpace($switchPrefix)) {
        foreach ($switch in @(Get-VMSwitch -ErrorAction Stop | Where-Object {
            $_.Name -like ($switchPrefix + '-' + $installationScope + '-*') -and
            [string]$_.SwitchType -eq 'Private' -and
            [string]$_.Notes -like ('CodexHarnessRequestNetwork:' + $installationScope + ':*')
        })) {
            $leased = @($remainingLeases | Where-Object { $_ -and [string]::Equals([string]$_.SwitchId, [string]$switch.Id, [StringComparison]::OrdinalIgnoreCase) })
            $attached = @(Get-VMNetworkAdapter -All -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.SwitchName, [string]$switch.Name, [StringComparison]::Ordinal) })
            if ($leased.Count -gt 0 -or $attached.Count -gt 0) { continue }
            try {
                Invoke-WithRequestNetworkMutex -Key ('switch:' + [string]$switch.Name) -Operation {
                    $current = @(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.Name, [string]$switch.Name, [StringComparison]::Ordinal) })
                    $currentLeases = @(Get-RequestNetworkLeaseInventory -BrokerRoot $BrokerRoot | Where-Object { $_ -and [string]::Equals([string]$_.SwitchId, [string]$switch.Id, [StringComparison]::OrdinalIgnoreCase) })
                    $currentAttachments = @(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Where-Object { [string]::Equals([string]$_.SwitchName, [string]$switch.Name, [StringComparison]::Ordinal) })
                    if ($currentLeases.Count -eq 0 -and $currentAttachments.Count -eq 0 -and $current.Count -eq 1 -and [string]$current[0].Id -eq [string]$switch.Id -and [string]$current[0].Notes -eq [string]$switch.Notes) {
                        Remove-VMSwitch -VMSwitch $current[0] -Force -ErrorAction Stop
                    }
                }
                $recovered.Add([pscustomobject][ordered]@{ RequestId = $null; Success = $true; Errors = @() })
            }
            catch { $recovered.Add([pscustomobject][ordered]@{ RequestId = $null; Success = $false; Errors = @($_.Exception.Message) }) }
        }
    }
    $result = $recovered.ToArray()
    $failures = @($result | Where-Object { -not [bool]$_.Success })
    if ($failures.Count -gt 0) {
        $messages = @($failures | ForEach-Object { @($_.Errors) -join ' | ' })
        throw ('Request-network orphan recovery failed closed: ' + ($messages -join ' | '))
    }
    $result
}
