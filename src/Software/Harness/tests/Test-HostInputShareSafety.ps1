[CmdletBinding()]
param(
    [string] $SourceRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $SourceRoot 'HostInputShare.ps1'
$hostBrokerPath = Join-Path $SourceRoot 'HostBroker.ps1'
$payloadCachePath = Join-Path $SourceRoot 'PayloadCache.ps1'
$guestAgentPath = Join-Path $SourceRoot 'seed\guest\GuestAgent.ps1'
. $modulePath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scenarios = New-Object Collections.Generic.List[string]
$moduleText = Get-Content -Raw -LiteralPath $modulePath
$brokerText = Get-Content -Raw -LiteralPath $hostBrokerPath
$payloadCacheText = Get-Content -Raw -LiteralPath $payloadCachePath
$guestText = Get-Content -Raw -LiteralPath $guestAgentPath

Assert-True ($moduleText.Contains("SwitchType Internal") -and $moduleText.Contains("Forwarding Disabled")) 'Host-input networking is not host-only with forwarding disabled.'
Assert-True ($moduleText.Contains("LocalPort 445") -and $moduleText.Contains("Action Allow")) 'Host firewall SMB confinement is incomplete.'
Assert-True (-not $moduleText.Contains("New-NetFirewallRule -DisplayName (`$network.FirewallPrefix + ' TCP deny") -and -not $moduleText.Contains("New-NetFirewallRule -DisplayName (`$network.FirewallPrefix + ' UDP deny")) 'Redundant explicit deny rules could overmatch the internal-switch ingress.'
Assert-True ($moduleText.Contains('LocalAddress $network.HostAddress') -and -not $moduleText.Contains('InterfaceAlias $managementAdapter.Name -Protocol')) 'Host firewall rules are not address-scoped to the worker endpoint.'
Assert-True ($moduleText.Contains("'172.31.255.'") -and -not $moduleText.Contains("'192.0.2.'")) 'Host-only worker links must use an unused RFC1918 slice so VPN LAN policy can permit them.'
Assert-True ($moduleText.Contains('Get-VMNetworkAdapterAcl') -and $moduleText.Contains('Remove-VMNetworkAdapterAcl -InputObject')) 'Stale VM adapter ACL cleanup is missing.'
Assert-True (-not $moduleText.Contains('Add-VMNetworkAdapterAcl')) 'Client Hyper-V IP ACLs would block required ARP neighbor discovery on the dedicated internal switch.'
Assert-True (-not $moduleText.Contains("LocalIPAddress (`$Runtime.GuestAddress + '/32') -RemoteIPAddress")) 'A Hyper-V ACL rule illegally mixes local and remote address types.'
Assert-True ($moduleText.Contains('Enable-NetAdapter -InputObject $adapter') -and -not $moduleText.Contains('Enable-NetAdapter -InterfaceIndex')) 'Guest adapter enablement uses an unsupported parameter set.'
Assert-True ($moduleText.Contains("AddressState -eq 'Preferred'") -and $moduleText.Contains('Find-NetRoute -InterfaceIndex') -and $moduleText.Contains('for ($connectAttempt = 1; $connectAttempt -le 8')) 'Guest network readiness and bounded SMB retries are incomplete.'
Assert-True ($moduleText.Contains('HostMacAddress') -and $moduleText.Contains('New-NetNeighbor -InterfaceIndex $adapter.ifIndex') -and $moduleText.Contains('-State Permanent')) 'Request-scoped host neighbor pinning is missing.'
$scenarios.Add('host-only-network-and-port-confinement')

Assert-True ($moduleText.Contains('Temporary = $true') -and $moduleText.Contains('ReadAccess = $runtime.Username') -and $moduleText.Contains('EncryptData = $true') -and $moduleText.Contains('IsolatedTransport')) 'The SMB share is not ephemeral, read-only, encrypted, and isolated.'
Assert-True (-not $moduleText.Contains('FullAccess =') -and -not $moduleText.Contains('ChangeAccess =')) 'The host-input share grants write-capable share permissions.'
Assert-True ($moduleText.Contains('Add-HostInputReadAce -Path $projectionPath -Sid $sid -IsDirectory $false')) 'Single-file zero-copy projections do not grant the ephemeral account directory traversal.'
$scenarios.Add('share-permission-is-read-only')

Assert-True ($brokerText.Contains('Resolve-GuestPayloadRoot -Session $session -PayloadId $inputRuntime.Manifest.PayloadId -ContentKey $inputRuntime.Manifest.ContentKey -ReadOnly')) 'Cached host-input VHDX disks are not resolved read-only.'
Assert-True ($payloadCacheText.Contains('Set-Disk -Number $disk.Number -IsReadOnly $true -ErrorAction Stop')) 'The guest disk resolver does not enforce read-only host-input disks.'
Assert-True ($payloadCacheText.Contains('Set-ReadOnlyHostInputPayloadAcl') -and $payloadCacheText.Contains("S-1-5-32-545") -and $payloadCacheText.Contains("ReadOnlyAclVersion")) 'The cached host-input filesystem does not enforce a versioned Users read-only ACL.'
Assert-True ($brokerText.Contains("CacheScope -ne 'Application'") -and $brokerText.Contains("CacheScope -ne 'ReadOnlyHostInput'")) 'Application and read-only host-input cache scopes are not broker-enforced.'
$scenarios.Add('cached-vhdx-input-is-read-only')

$stateFunction = (Get-Command Write-HostInputLeaseState).ScriptBlock.ToString()
Assert-True (-not $stateFunction.Contains('Password =') -and -not $stateFunction.Contains('[string]$Runtime.Password')) 'Ephemeral SMB credentials are persisted in broker state.'
$scenarios.Add('credentials-never-persisted')

Assert-True ($moduleText.Contains('PurgeAccessRules') -and $moduleText.Contains('Remove-LocalUser') -and $moduleText.Contains('Recover-OrphanedHostInputResources')) 'Temporary identity or ACL recovery is missing.'
Assert-True ($brokerText.Contains('Recover-OrphanedHostInputResources') -and $brokerText.Contains("`$failureStage = 'CleaningHostInputs'")) 'Broker cleanup/recovery integration is missing.'
$scenarios.Add('crash-recoverable-account-share-and-acl')

Assert-True ($guestText.IndexOf('Dismount-GuestHostInputs -MountedInputs', [StringComparison]::Ordinal) -lt $guestText.IndexOf('Write-JsonAtomic -Path $resultFile', [StringComparison]::Ordinal)) 'Guest result is published before host-input drives are unmapped.'
Assert-True ($guestText.Contains("`$failureKind = 'HostInputCleanup'")) 'Guest mapping cleanup failure is not classified.'
$scenarios.Add('guest-unmaps-before-terminal-result')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-host-input-cleanup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$statePath = Join-Path $testRoot 'lease.json'
[IO.File]::WriteAllText($statePath, '{}')
$script:cleanupCalls = New-Object Collections.Generic.List[string]
function Get-VM { $null }
function Remove-SmbShare { param([string] $Name, [switch] $Force, [switch] $Confirm, $ErrorAction) $script:cleanupCalls.Add("share:$Name") }
function Remove-LocalUser { param([string] $Name, $ErrorAction) $script:cleanupCalls.Add("account:$Name") }
function Remove-HostInputReadAce { param([string] $Path, [string] $Sid) $script:cleanupCalls.Add("acl:$Path") }
try {
    $runtime = [pscustomobject][ordered]@{
        StatePath = $statePath
        RequestId = 'request'
        WorkerId = 1
        VmName = 'vm'
        Status = 'Ready'
        OwnerProcessId = 1
        OwnerProcessStartUtc = [DateTime]::UtcNow.ToString('o')
        AccountName = 'CHVROTEST'
        AccountSid = 'S-1-5-21-1-2-3-1001'
        Username = $null
        Password = $null
        VmAdapterName = $null
        SwitchName = 'switch'
        HostAddress = '172.31.255.241'
        GuestAddress = '172.31.255.242'
        Network = $null
        Inputs = @([pscustomobject]@{ Name='data'; HostPath=$testRoot; SharePath=$testRoot; ShareName='CHVRO_TEST'; GuestSubPath=''; AclPath=$testRoot; ProjectionPath=$null; ShareCreated=$true; AclAdded=$true })
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        CleanupErrors = @()
    }
    $cleanup = Remove-HostInputShareRuntime -Runtime $runtime -BrokerRoot $testRoot
    Assert-True $cleanup.Success 'Synthetic host-input cleanup failed.'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'Successful cleanup retained its lease state.'
    Assert-True (($script:cleanupCalls -join ',') -eq "share:CHVRO_TEST,account:CHVROTEST,acl:$testRoot") 'Cleanup did not revoke share, then account, then ACL.'
    $scenarios.Add('cleanup-order-revokes-access-first')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
