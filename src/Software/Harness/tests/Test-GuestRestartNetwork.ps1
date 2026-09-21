[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'RequestNetwork.ps1')
$checks = New-Object Collections.Generic.List[string]
function Check($Name, [bool] $Value) { if (-not $Value) { throw $Name }; $checks.Add($Name) }
# Execute the actual remote gate with synthetic Windows network cmdlets.
function Invoke-Command { param($VmName, $Credential, $ScriptBlock, $ArgumentList) & $ScriptBlock @ArgumentList }
function Get-CimInstance { [pscustomobject]@{ LastBootUpTime = [DateTime]::Parse($script:state.Boot).ToUniversalTime() } }
function Get-NetAdapter { $script:state.Adapters }
function Get-NetIPAddress { $script:state.Addresses }
function Get-NetRoute { $script:state.Routes }
function Get-DnsClientServerAddress { [pscustomobject]@{ InterfaceIndex = 19; ServerAddresses = $script:state.Dns } }
function Get-NetAdapterBinding { [pscustomobject]@{ Enabled = $script:state.IPv6 } }
function Get-NetIPInterface { [pscustomobject]@{ InterfaceIndex = 19; Dhcp = 'Disabled'; Forwarding = 'Disabled'; WeakHostSend = 'Disabled'; WeakHostReceive = 'Disabled' } }
function Get-NetConnectionProfile { [pscustomobject]@{ InterfaceIndex = 19; NetworkCategory = $script:state.Category } }
function Get-NetFirewallProfile { [pscustomobject]@{ Enabled = 'True'; DefaultInboundAction = 'Block'; DisabledInterfaceAliases = $script:state.Aliases } }
function Set-NetConnectionProfile { param($InterfaceIndex, $NetworkCategory) $script:mutations++; $script:state.Category = $NetworkCategory }
function Set-NetFirewallProfile { param($Name, $DisabledInterfaceAliases) $script:mutations++; $script:state.Aliases = $DisabledInterfaceAliases }
$runtime = [pscustomobject]@{ Profile = 'IsolatedTestNet'; AdapterMacAddress = '00155D000001'; GuestAddress = '10.254.0.101'; PrefixLength = 24 }
$initial = [pscustomobject]@{ BoundaryAttested = $true; InterfaceAlias = 'Ethernet 3'; InterfaceIndex = 19; Routes = @([pscustomobject]@{ DestinationPrefix = '10.254.0.0/24'; NextHop = '0.0.0.0' }) }
$boot = '2026-01-01T00:03:00Z'
function Reset-State {
    $script:mutations = 0
    $script:state = @{
        Boot = $boot; Category = 'Private'; Aliases = @('Ethernet 3'); Dns = @(); IPv6 = $false
        Adapters = @([pscustomobject]@{ InterfaceAlias = 'Ethernet 3'; ifIndex = 19; MacAddress = '00-15-5D-00-00-01'; Status = 'Up' })
        Addresses = @([pscustomobject]@{ InterfaceIndex = 19; IPAddress = '10.254.0.101'; PrefixLength = 24; AddressState = 'Preferred' })
        Routes = @([pscustomobject]@{ InterfaceIndex = 19; DestinationPrefix = '10.254.0.0/24'; NextHop = '0.0.0.0' })
    }
}
Reset-State
$receipt = Confirm-GuestRequestNetworkAfterBoot -Runtime $runtime -InitialAttestation $initial -ExpectedBootTimeUtc $boot
Check 'unchanged-boot-network-is-read-only' ($receipt.Succeeded -and $mutations -eq 0 -and $receipt.Before -and $receipt.After)
Reset-State; $state.Category = 'Public'; $state.Aliases = @()
$receipt = Confirm-GuestRequestNetworkAfterBoot -Runtime $runtime -InitialAttestation $initial -ExpectedBootTimeUtc $boot
Check 'only-owned-category-and-exemption-restored-with-observations' ($receipt.Succeeded -and $mutations -eq 2 -and $receipt.Before.Profiles[0].NetworkCategory -eq 'Public' -and $receipt.After.Profiles[0].NetworkCategory -eq 'Private' -and $receipt.Restored.Count -eq 2)
foreach ($fault in @('boot','address','route','dns','ipv6','foreign-interface','foreign-exemption')) {
    Reset-State; $state.Category = 'Public'
    switch ($fault) {
        boot { $state.Boot = '2026-01-01T00:04:00Z' }
        address { $state.Addresses[0].IPAddress = '10.254.0.102' }
        route { $state.Routes[0].DestinationPrefix = '0.0.0.0/0' }
        dns { $state.Dns = @('10.254.0.1') }
        ipv6 { $state.IPv6 = $true }
        foreign-interface { $state.Adapters += [pscustomobject]@{ InterfaceAlias = 'Foreign'; ifIndex = 20; MacAddress = '00155D000002'; Status = 'Up' } }
        foreign-exemption { $state.Aliases = @('Foreign') }
    }
    $receipt = Confirm-GuestRequestNetworkAfterBoot -Runtime $runtime -InitialAttestation $initial -ExpectedBootTimeUtc $boot
    Check ($fault + '-fails-before-mutation-with-evidence') (-not $receipt.Succeeded -and $mutations -eq 0 -and $receipt.Error -and $receipt.Before -and $receipt.After)
}
[pscustomobject]@{ Success = $true; ScenarioCount = $checks.Count; Checks = $checks.ToArray() } | ConvertTo-Json -Depth 5
