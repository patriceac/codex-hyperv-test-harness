[CmdletBinding()]
param(
    [string] $RepositoryRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-FailClosedExternalProfiles {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    Assert-True ([int]$Policy.FormatVersion -eq 1) "$Context has the wrong policy format version."
    Assert-True ([string]$Policy.DefaultProfile -eq 'None') "$Context does not default to None."
    Assert-True ([bool]$Policy.IsolatedTestNet.Enabled) "$Context does not enable IsolatedTestNet."
    Assert-True ([string]$Policy.IsolatedTestNet.SwitchPrefix -eq 'Codex-Harness-TestNet') "$Context has the wrong isolated switch prefix."
    Assert-True ([string]$Policy.IsolatedTestNet.NetworkPrefix -eq '10.254.0.0/24') "$Context has the wrong isolated guest network."
    Assert-True (-not [bool]$Policy.InternetOnly.Enabled) "$Context enables InternetOnly without pinned infrastructure."
    foreach ($name in @('SwitchName', 'SwitchId', 'NatName', 'NatPrefix', 'GatewayAddress')) {
        Assert-True ([string]::IsNullOrEmpty([string]$Policy.InternetOnly.$name)) "$Context infers InternetOnly field $name."
    }
    Assert-True ([int]$Policy.InternetOnly.PrefixLength -eq 24) "$Context has the wrong InternetOnly prefix length."
    Assert-True ([int]$Policy.InternetOnly.PrimaryVlanId -eq 0 -and [int]$Policy.InternetOnly.SecondaryVlanId -eq 0) "$Context infers enabled private-VLAN IDs."
    Assert-True ([string]$Policy.InternetOnly.TcpFilteringBehavior -eq 'AddressDependentFiltering' -and [string]$Policy.InternetOnly.UdpFilteringBehavior -eq 'AddressDependentFiltering') "$Context does not require address-dependent NAT filtering."
    Assert-True ($Policy.InternetOnly.UdpInboundRefresh -is [bool] -and -not [bool]$Policy.InternetOnly.UdpInboundRefresh) "$Context permits inbound UDP session refresh."
    Assert-True ([string]$Policy.InternetOnly.InternalRoutingDomainId -eq '{00000000-0000-0000-0000-000000000000}' -and [string]::IsNullOrEmpty([string]$Policy.InternetOnly.ExternalIPInterfaceAddressPrefix)) "$Context does not pin the NAT routing-domain and external-prefix policy."
    Assert-True ([int]$Policy.InternetOnly.TcpEstablishedConnectionTimeout -eq 1800 -and [int]$Policy.InternetOnly.TcpTransientConnectionTimeout -eq 120 -and [int]$Policy.InternetOnly.UdpIdleSessionTimeout -eq 120 -and [int]$Policy.InternetOnly.IcmpQueryTimeout -eq 30) "$Context does not pin NAT session timeouts."
    Assert-True (@($Policy.InternetOnly.DnsServers).Count -eq 0) "$Context infers InternetOnly DNS servers."
    Assert-True (@($Policy.InternetOnly.DenyRemotePrefixes).Count -eq 0) "$Context infers InternetOnly deny prefixes."
    Assert-True (-not [bool]$Policy.TrustedLan.Enabled) "$Context enables TrustedLan without approval."
    Assert-True (@($Policy.TrustedLan.AllowedSwitches).Count -eq 0) "$Context infers a TrustedLan switch."
}

$configurationPath = Join-Path $RepositoryRoot 'setup\New-HarnessConfiguration.ps1'
$brokerPath = Join-Path $RepositoryRoot 'src\Software\Harness\HostBroker.ps1'
$requestNetworkPath = Join-Path $RepositoryRoot 'src\Software\Harness\RequestNetwork.ps1'
$installerPath = Join-Path $RepositoryRoot 'src\Software\Harness\Install-PoolHostBroker.ps1'
$poolBrokerPath = Join-Path $RepositoryRoot 'src\Software\Harness\PoolBroker.ps1'
$poolLifecyclePath = Join-Path $RepositoryRoot 'src\Software\Harness\PoolLifecycle.ps1'
$auditPath = Join-Path $RepositoryRoot 'src\Software\Harness\Audit-HyperVTestPool.ps1'
$recoveryVerifierPath = Join-Path $RepositoryRoot 'src\Software\Recovery\Test-CodexHyperVRecovery.ps1'
$scenarios = New-Object Collections.Generic.List[string]

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-request-network-propagation-' + [Guid]::NewGuid().ToString('N'))
try {
    $outputPath = Join-Path $testRoot 'harness-config.json'
    $installRoot = Join-Path $testRoot 'install'
    $null = & $configurationPath -InstallRoot $installRoot -OutputPath $outputPath
    $layout = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-True ([string]$layout.NetworkPolicy -eq 'DisconnectedExceptEphemeralReadOnlyHostInput') 'The legacy network policy changed.'
    Assert-FailClosedExternalProfiles -Policy $layout.RequestNetworkPolicy -Context 'New harness configuration'
    $scenarios.Add('layout-policy-is-versioned-and-fail-closed')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$tokens = $null
$parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Install-PoolHostBroker.ps1 has a parse error.'
$fallbackFunction = @($installerAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-FailClosedRequestNetworkPolicy'
}, $true))
Assert-True ($fallbackFunction.Count -eq 1) 'The backward-compatible request-network policy factory is missing or ambiguous.'
. ([scriptblock]::Create($fallbackFunction[0].Extent.Text))
$fallbackPolicy = [pscustomobject](New-FailClosedRequestNetworkPolicy)
Assert-FailClosedExternalProfiles -Policy $fallbackPolicy -Context 'Backward-compatible broker fallback'
$scenarios.Add('legacy-layout-fallback-disables-external-profiles')

$installerText = Get-Content -LiteralPath $installerPath -Raw
Assert-True ($installerText.Contains("'RequestNetwork.ps1'")) 'Broker installation does not copy and hash RequestNetwork.ps1.'
Assert-True ($installerText.Contains("`$layout.PSObject.Properties['RequestNetworkPolicy']") -and $installerText.Contains('RequestNetworkPolicy = $requestNetworkPolicy')) 'Broker installation does not propagate the layout request-network policy.'
Assert-True (-not $fallbackFunction[0].Extent.Text.Contains('Default Switch') -and -not $fallbackFunction[0].Extent.Text.Contains('New-NetNat')) 'The fallback policy infers host networking.'
$scenarios.Add('installer-copies-module-and-private-policy')

$brokerText = Get-Content -LiteralPath $brokerPath -Raw
$requestNetworkText = Get-Content -LiteralPath $requestNetworkPath -Raw
$brokerSessionIndex = $brokerText.IndexOf('$session = Open-GuestSessionReliable', [StringComparison]::Ordinal)
$brokerResidueCleanupIndex = $brokerText.IndexOf('Reset-GuestRequestNetworkResidue -Session $session -Policy $requestNetworkDefinition.Policy', [StringComparison]::Ordinal)
$brokerNetworkConnectIndex = $brokerText.IndexOf('Connect-RequestVmNetwork -Runtime $requestNetworkRuntime', [StringComparison]::Ordinal)
$brokerGuestInitializeIndex = $brokerText.IndexOf('Initialize-GuestRequestNetwork -Session $session -Runtime $requestNetworkRuntime', [StringComparison]::Ordinal)
Assert-True (
    $brokerSessionIndex -ge 0 -and
    $brokerResidueCleanupIndex -gt $brokerSessionIndex -and
    $brokerNetworkConnectIndex -gt $brokerResidueCleanupIndex -and
    $brokerGuestInitializeIndex -gt $brokerNetworkConnectIndex -and
    $brokerText.Contains('ResidueCleanup = $requestNetworkResidueCleanup')
) 'HostBroker does not normalize exact guest network residue before connect-last or persist its attestation.'
$scenarios.Add('broker-normalizes-guest-network-residue-before-connect-last')

$poolBrokerText = Get-Content -LiteralPath $poolBrokerPath -Raw
$orphanRecoveryCalls = [regex]::Matches($poolBrokerText, 'Recover-OrphanedRequestNetworkResources\s+-BrokerRoot\s+\$BrokerRoot')
Assert-True ($orphanRecoveryCalls.Count -ge 2) 'Pool broker does not recover request networking at startup and periodically.'
Assert-True ($poolBrokerText.Contains('$nextRequestNetworkCleanupUtc') -and $poolBrokerText.Contains('[DateTime]::UtcNow.AddSeconds(2)')) 'Pool broker has no bounded request-network recovery cadence.'
$scenarios.Add('pool-broker-recovers-network-orphans')

$poolLifecycleText = Get-Content -LiteralPath $poolLifecyclePath -Raw
Assert-True ($poolLifecycleText.Contains('Recover-OrphanedRequestNetworkResources -BrokerRoot $BrokerRoot')) 'Pool lifecycle does not recover request-network leases.'
Assert-True ($poolLifecycleText.Contains('Remove-ManagedRequestNetworkAdapters -VmName $vmName -BrokerRoot $BrokerRoot')) 'Pool lifecycle does not remove managed request adapters.'
Assert-True ($poolLifecycleText.Contains("`$_.Name -like 'CodexHostInput-*'")) 'Pool lifecycle no longer removes host-input adapters.'
$modeStopIndex = $poolLifecycleText.IndexOf("if (`$Mode -eq 'Stop')", [StringComparison]::Ordinal)
$firstIsolationCall = $poolLifecycleText.LastIndexOf('    Reset-WorkerNetworkIsolation', $modeStopIndex, [StringComparison]::Ordinal)
$secondIsolationCall = $poolLifecycleText.IndexOf('    Reset-WorkerNetworkIsolation', $modeStopIndex, [StringComparison]::Ordinal)
$startVmIndex = $poolLifecycleText.IndexOf('    Start-VM -Name $vmName', $modeStopIndex, [StringComparison]::Ordinal)
Assert-True ($modeStopIndex -gt 0 -and $firstIsolationCall -gt 0 -and $firstIsolationCall -lt $modeStopIndex) 'Pool Stop can exit before request-network cleanup.'
Assert-True ($secondIsolationCall -gt $modeStopIndex -and $secondIsolationCall -lt $startVmIndex) 'Pool worker restart does not repeat the disconnected-network gate.'
Assert-True ($poolLifecycleText.Contains('$connected.Count -gt 0')) 'Pool lifecycle does not verify that every adapter is disconnected.'
$scenarios.Add('pool-lifecycle-cleans-before-stop-and-restart')

$hostLifecycleLocks = [regex]::Matches($brokerText, 'Invoke-WithRequestNetworkLifecycleMutex\s+-BrokerRoot\s+\$BrokerRoot\s+-Operation')
$poolLifecycleLocks = [regex]::Matches($poolBrokerText, 'Invoke-WithRequestNetworkLifecycleMutex\s+-BrokerRoot\s+\$BrokerRoot\s+-Operation')
Assert-True (
    $requestNetworkText.Contains('function Invoke-WithRequestNetworkLifecycleMutex') -and
    $requestNetworkText.Contains("Invoke-WithRequestNetworkMutex -Key ('lifecycle:' + `$canonicalBrokerRoot)") -and
    $hostLifecycleLocks.Count -ge 6 -and
    $poolLifecycleLocks.Count -ge 2 -and
    $poolLifecycleText.Contains('Invoke-WithRequestNetworkLifecycleMutex -BrokerRoot $BrokerRoot -Operation')
) 'Request creation, adapter mutation, cleanup, and orphan recovery are not serialized across broker processes.'
$scenarios.Add('request-network-lifecycle-mutations-are-cross-process-serialized')

$auditText = Get-Content -LiteralPath $auditPath -Raw
foreach ($requiredAuditContract in @(
    "'RequestNetwork.ps1'",
    "'State\NetworkLeases'",
    "'CodexRequestNet-*'",
    'NoRequestNetworkLeases',
    'NoManagedRequestNetworkAdapters',
    'NoManagedRequestNetworkSwitches',
    'SourceNetworkDisconnected',
    'RequestNetworkPolicyVersioned',
    'InternetOnlyPolicyPinned',
    'TrustedLanPolicyPinned',
    'NetAdapterInterfaceGuid',
    'Get-RequestNetworkNatStaticMappings',
    'Assert-RequestNetworkInternetVlan',
    '-PrivateVlanMode Promiscuous',
    '-ManagementOS',
    'InternetOnlyPolicyAudit',
    'GatewayVlanError',
    '-not [bool]$_.IsManagementOs',
    'AttachedAdapters',
    'AllWorkerNetworksDisconnected',
    'RequestNetworkLeaseFileCount',
    'ManagedRequestNetworkAdapterCount',
    'ManagedRequestNetworkSwitchCount',
    'Get-RequestNetworkPolicy -Config $brokerConfig',
    'Get-RequestNetworkIPv4Prefix24',
    'Get-VMNetworkAdapter -All -ErrorAction Stop',
    '$allVmNetworkAdapters'
)) {
    Assert-True ($auditText.Contains($requiredAuditContract)) "Pool audit is missing request-network contract: $requiredAuditContract"
}
$scenarios.Add('pool-audit-rejects-network-residue')

$recoveryVerifierText = Get-Content -LiteralPath $recoveryVerifierPath -Raw
foreach ($requiredRecoveryPath in @(
    'Software\Setup\Update-RequestNetworking.ps1',
    'Software\Harness\RequestNetwork.ps1',
    'Software\Harness\tests\Test-RequestNetworkingUpdateContract.ps1',
    'Software\Harness\tests\Test-RequestNetworkPropagation.ps1',
    'Software\Harness\tests\Test-RequestNetworkSafety.ps1',
    'Software\Harness\tests\Test-RunnerContractValidation.ps1',
    'Software\Skill\SKILL.md',
    'Software\Skill\scripts\Invoke-HyperVExecutableTest.ps1',
    'Software\Canaries\NetworkBoundaryCanary.cs',
    'Software\Canaries\NetworkBoundaryCanary.exe'
)) {
    Assert-True ($recoveryVerifierText.Contains("'$requiredRecoveryPath'")) "Recovery verification does not require $requiredRecoveryPath."
}
$scenarios.Add('recovery-bundle-requires-complete-network-source-runtime-and-canary')

foreach ($path in @($configurationPath, $brokerPath, $installerPath, $poolBrokerPath, $poolLifecyclePath, $auditPath, $recoveryVerifierPath, $PSCommandPath)) {
    $parseTokens = $null
    $parseIssues = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$parseTokens, [ref]$parseIssues)
    Assert-True ($parseIssues.Count -eq 0) "PowerShell parse failure in $path"
}
$scenarios.Add('owned-powershell-parses')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
