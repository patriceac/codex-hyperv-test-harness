[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [ValidateRange(1, 4)] [int] $PoolSize = 4,
    [ValidateRange(2, 64)] [int] $VmMemoryGiB = 8,
    [ValidateRange(1, 64)] [int] $VmProcessorCount = 4,
    [ValidateRange(60, 86400)] [int] $IdleTimeoutSeconds = 600,
    [ValidateRange(1024, 7680)] [int] $DisplayWidth = 1920,
    [ValidateRange(768, 4320)] [int] $DisplayHeight = 1080,
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallRoot) -or [IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) {
    throw 'InstallRoot must be a specific non-root directory.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $InstallRoot 'Software\harness-config.json' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

$configuration = [ordered]@{
    FormatVersion = 1
    InstallRoot = $InstallRoot
    LiveRoot = Join-Path $InstallRoot 'Live'
    BaselineRoot = Join-Path $InstallRoot 'Live\Baseline'
    BrokerRoot = Join-Path $InstallRoot 'Live\Broker'
    SoftwareRoot = Join-Path $InstallRoot 'Software'
    HarnessSourceRoot = Join-Path $InstallRoot 'Software\Harness'
    SkillSourceRoot = Join-Path $InstallRoot 'Software\Skill'
    RecoveryRoot = Join-Path $InstallRoot 'Recovery'
    BaselineVmName = 'Codex-Harness-Baseline'
    BaselineCheckpointName = 'Clean-Windows11-Harness'
    PoolVmPrefix = 'Codex-Harness'
    PoolSize = $PoolSize
    PoolIdleTimeoutSeconds = $IdleTimeoutSeconds
    PoolLifecycleConcurrency = 2
    VmMemoryBytes = [long]$VmMemoryGiB * 1GB
    VmProcessorCount = $VmProcessorCount
    GuestDisplayWidth = $DisplayWidth
    GuestDisplayHeight = $DisplayHeight
    BrokerTaskName = 'Codex Hyper-V Broker'
    BrokerLocationPointer = Join-Path $env:ProgramData 'CodexHyperVBroker\location.json'
    RecoveryResumeTaskName = 'Codex Hyper-V Recovery Resume'
    RecoveryGenerations = 2
    NetworkPolicy = 'DisconnectedExceptEphemeralReadOnlyHostInput'
    RequestNetworkPolicy = [ordered]@{
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

$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$temporary = $OutputPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
try {
    $configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
[pscustomobject]$configuration
