function Get-HostInputStateRoot {
    param([Parameter(Mandatory = $true)] [string] $BrokerRoot)
    Join-Path $BrokerRoot 'State\HostInputs'
}

function Get-HostInputNetworkDefinition {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [int] $WorkerId
    )

    $prefix = if (-not [string]::IsNullOrWhiteSpace([string]$Config.HostInputSwitchPrefix)) {
        [string]$Config.HostInputSwitchPrefix
    }
    else { 'Codex-Harness-HostInput' }
    $offset = ($WorkerId - 1) * 4
    [pscustomobject][ordered]@{
        WorkerId = $WorkerId
        SwitchName = '{0}-{1:D2}' -f $prefix, $WorkerId
        # Keep the host-only links in RFC1918 space. VPN kill-switch products
        # commonly permit RFC1918 LAN traffic while intentionally rejecting
        # TEST-NET ranges such as 192.0.2.0/24 at a higher-priority WFP layer.
        HostAddress = '172.31.255.' + (240 + $offset + 1)
        GuestAddress = '172.31.255.' + (240 + $offset + 2)
        PrefixLength = 30
        FirewallPrefix = 'Codex Harness Host Input {0:D2}' -f $WorkerId
    }
}

function New-HostInputRandomSecret {
    param([ValidateRange(16, 64)] [int] $ByteCount = 24)

    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    ([BitConverter]::ToString($bytes)).Replace('-', '') + 'aA1!'
}

function Test-HostInputOwnerAlive {
    param($State)

    if (-not $State -or [int]$State.OwnerProcessId -le 0) { return $false }
    $process = Get-Process -Id ([int]$State.OwnerProcessId) -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$State.OwnerProcessStartUtc)) { return $true }
    try {
        $expected = [DateTime]::Parse([string]$State.OwnerProcessStartUtc).ToUniversalTime()
        [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 2
    }
    catch { $false }
}

function Write-HostInputLeaseState {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $Status
    )

    $Runtime.Status = $Status
    $Runtime.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $sanitizedInputs = @(
        foreach ($input in @($Runtime.Inputs)) {
            [ordered]@{
                Name = [string]$input.Name
                HostPath = [string]$input.HostPath
                SharePath = [string]$input.SharePath
                ShareName = [string]$input.ShareName
                GuestSubPath = [string]$input.GuestSubPath
                AclPath = [string]$input.AclPath
                ProjectionPath = [string]$input.ProjectionPath
                ShareCreated = [bool]$input.ShareCreated
                AclAdded = [bool]$input.AclAdded
            }
        }
    )
    Write-JsonAtomic -Path ([string]$Runtime.StatePath) -Value ([ordered]@{
        FormatVersion = 1
        RequestId = [string]$Runtime.RequestId
        WorkerId = [int]$Runtime.WorkerId
        VmName = [string]$Runtime.VmName
        Status = $Status
        OwnerProcessId = [int]$Runtime.OwnerProcessId
        OwnerProcessStartUtc = [string]$Runtime.OwnerProcessStartUtc
        AccountName = [string]$Runtime.AccountName
        AccountSid = [string]$Runtime.AccountSid
        VmAdapterName = [string]$Runtime.VmAdapterName
        SwitchName = [string]$Runtime.SwitchName
        HostAddress = [string]$Runtime.HostAddress
        GuestAddress = [string]$Runtime.GuestAddress
        Inputs = $sanitizedInputs
        CreatedUtc = [string]$Runtime.CreatedUtc
        UpdatedUtc = [string]$Runtime.UpdatedUtc
        CleanupErrors = @($Runtime.CleanupErrors)
    })
}

function Add-HostInputReadAce {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [Security.Principal.SecurityIdentifier] $Sid,
        [Parameter(Mandatory = $true)] [bool] $IsDirectory
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $inheritance = if ($IsDirectory) {
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else { [Security.AccessControl.InheritanceFlags]::None }
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $Sid,
        [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize',
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Remove-HostInputReadAce {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Sid
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $securityId = [Security.Principal.SecurityIdentifier]::new($Sid)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $acl.PurgeAccessRules($securityId)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-HostInputProjectionRoot {
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $sourceRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($SourcePath)).TrimEnd('\')
    $brokerVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($BrokerRoot)).TrimEnd('\')
    if ([string]::Equals($sourceRoot, $brokerVolume, [StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $BrokerRoot 'HostInputProjections'
    }
    Join-Path ($sourceRoot + '\') '.CodexHyperVHostInputProjections'
}

function New-HostInputFileProjection {
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $projectionRoot = Get-HostInputProjectionRoot -SourcePath $SourcePath -BrokerRoot $BrokerRoot
    $safeLeaf = ($RequestId + '-' + $Name) -replace '[^A-Za-z0-9_-]', '_'
    $projectionPath = Join-Path $projectionRoot $safeLeaf
    New-Item -ItemType Directory -Force -Path $projectionPath | Out-Null
    $target = Join-Path $projectionPath ([IO.Path]::GetFileName($SourcePath))
    try {
        New-Item -ItemType HardLink -Path $target -Target $SourcePath -ErrorAction Stop | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $projectionPath -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not create a zero-copy hard-link projection for host input file '$SourcePath': $($_.Exception.Message)"
    }
    [pscustomobject][ordered]@{
        ProjectionPath = $projectionPath
        GuestSubPath = [IO.Path]::GetFileName($SourcePath)
    }
}

function Ensure-HostInputNetwork {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [int] $WorkerId
    )

    Import-Module Hyper-V -ErrorAction Stop
    Import-Module NetTCPIP -ErrorAction Stop
    Import-Module NetSecurity -ErrorAction Stop
    $network = Get-HostInputNetworkDefinition -Config $Config -WorkerId $WorkerId
    $switch = Get-VMSwitch -Name $network.SwitchName -ErrorAction SilentlyContinue
    if ($switch -and [string]$switch.SwitchType -ne 'Internal') {
        throw "Host-input switch exists with the wrong type: $($network.SwitchName)"
    }
    if (-not $switch) {
        $switch = New-VMSwitch -Name $network.SwitchName -SwitchType Internal -ErrorAction Stop
    }

    $managementAdapter = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $vmAdapter = Get-VMNetworkAdapter -ManagementOS -SwitchName $network.SwitchName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vmAdapter) {
            $normalizedMac = ([string]$vmAdapter.MacAddress) -replace '[:-]', ''
            $managementAdapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
                (([string]$_.MacAddress) -replace '[:-]', '') -eq $normalizedMac
            } | Select-Object -First 1
        }
        if (-not $managementAdapter) { Start-Sleep -Milliseconds 250 }
    } while (-not $managementAdapter -and [DateTime]::UtcNow -lt $deadline)
    if (-not $managementAdapter) {
        throw "The host adapter for internal switch '$($network.SwitchName)' did not appear."
    }

    Set-NetIPInterface -InterfaceIndex $managementAdapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -Forwarding Disabled -WeakHostSend Disabled -WeakHostReceive Disabled -ErrorAction SilentlyContinue | Out-Null
    foreach ($address in @(Get-NetIPAddress -InterfaceIndex $managementAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if (-not [string]::Equals([string]$address.IPAddress, [string]$network.HostAddress, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-NetIPAddress -InterfaceIndex $managementAdapter.ifIndex -AddressFamily IPv4 -IPAddress $network.HostAddress -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $managementAdapter.ifIndex -IPAddress $network.HostAddress -PrefixLength $network.PrefixLength -AddressFamily IPv4 -ErrorAction Stop | Out-Null
    }

    Get-NetFirewallRule -DisplayName ($network.FirewallPrefix + '*') -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    # Hyper-V internal-switch traffic can be classified against the virtual
    # switch ingress rather than the management adapter alias. Address-scope
    # every rule instead: each worker owns a unique /30, so this is both more
    # reliable and at least as narrow as an interface-name filter.
    # SMB is hosted by the kernel/System listener. Scope the exception to that
    # program as well as the worker's exact guest and host addresses; a generic
    # port-only rule is not sufficient at the WFP receive/accept layer on current
    # Windows 11 builds.
    New-NetFirewallRule -DisplayName ($network.FirewallPrefix + ' SMB allow') -Direction Inbound -Action Allow -Enabled True -Profile Any -Program 'System' -Protocol TCP -RemoteAddress $network.GuestAddress -LocalAddress $network.HostAddress -LocalPort 445 | Out-Null

    $network | Add-Member -NotePropertyName HostInterfaceAlias -NotePropertyValue ([string]$managementAdapter.Name) -Force
    $network | Add-Member -NotePropertyName HostMacAddress -NotePropertyValue ([string]$managementAdapter.MacAddress) -Force
    $network
}

function New-HostInputShareRuntime {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 4)] [int] $WorkerId,
        [Parameter(Mandatory = $true)] [object[]] $Inputs
    )

    if ($Inputs.Count -eq 0) { return $null }
    Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    Import-Module SmbShare -ErrorAction Stop
    $stateRoot = Get-HostInputStateRoot -BrokerRoot $BrokerRoot
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $statePath = Join-Path $stateRoot ($RequestId + '.json')
    $network = Ensure-HostInputNetwork -Config $Config -WorkerId $WorkerId
    $runtime = [pscustomobject][ordered]@{
        StatePath = $statePath
        RequestId = $RequestId
        WorkerId = $WorkerId
        VmName = $VmName
        Status = 'Creating'
        OwnerProcessId = $PID
        OwnerProcessStartUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        AccountName = $null
        AccountSid = $null
        Username = $null
        Password = New-HostInputRandomSecret
        VmAdapterName = 'CodexHostInput-' + $RequestId.Substring([Math]::Max(0, $RequestId.Length - 12))
        SwitchName = [string]$network.SwitchName
        HostAddress = [string]$network.HostAddress
        GuestAddress = [string]$network.GuestAddress
        Network = $network
        Inputs = @()
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        CleanupErrors = @()
    }
    Write-HostInputLeaseState -Runtime $runtime -Status 'CreatingAccount'
    try {
        $accountName = 'CHVRO' + (New-HostInputRandomSecret -ByteCount 16).Substring(0, 12)
        $securePassword = ConvertTo-SecureString -String $runtime.Password -AsPlainText -Force
        $account = New-LocalUser -Name $accountName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'Ephemeral Codex Hyper-V read-only input' -ErrorAction Stop
        $runtime.AccountName = $accountName
        $runtime.AccountSid = [string]$account.SID.Value
        $runtime.Username = "$env:COMPUTERNAME\$accountName"
        Write-HostInputLeaseState -Runtime $runtime -Status 'CreatingShares'

        $sid = [Security.Principal.SecurityIdentifier]::new($runtime.AccountSid)
        $shareSupportsIsolatedTransport = (Get-Command New-SmbShare).Parameters.ContainsKey('IsolatedTransport')
        $index = 0
        foreach ($input in $Inputs) {
            $index++
            $hostPath = [IO.Path]::GetFullPath([string]$input.HostPath)
            $sourceItem = Get-Item -LiteralPath $hostPath -Force -ErrorAction Stop
            $sharePath = $hostPath
            $projectionPath = $null
            $guestSubPath = ''
            if (-not $sourceItem.PSIsContainer) {
                $projection = New-HostInputFileProjection -SourcePath $hostPath -BrokerRoot $BrokerRoot -RequestId $RequestId -Name ([string]$input.Name)
                $sharePath = [string]$projection.ProjectionPath
                $projectionPath = [string]$projection.ProjectionPath
                $guestSubPath = [string]$projection.GuestSubPath
            }
            $entry = [pscustomobject][ordered]@{
                Name = [string]$input.Name
                HostPath = $hostPath
                SharePath = $sharePath
                ShareName = ('CHVRO_{0:D2}_{1}_{2:D2}' -f $WorkerId, ([Guid]::NewGuid().ToString('N').Substring(0, 12)), $index)
                GuestSubPath = $guestSubPath
                AclPath = $hostPath
                ProjectionPath = $projectionPath
                ShareCreated = $false
                AclAdded = $false
            }
            $runtime.Inputs += $entry
            Write-HostInputLeaseState -Runtime $runtime -Status 'CreatingShares'
            Add-HostInputReadAce -Path $hostPath -Sid $sid -IsDirectory ([bool]$sourceItem.PSIsContainer)
            $entry.AclAdded = $true
            if (-not [string]::IsNullOrWhiteSpace($projectionPath)) {
                # A file projection may live under the SYSTEM-only broker tree.
                # Grant only directory traversal on the disposable projection;
                # the source file's own explicit ACE remains the data boundary.
                Add-HostInputReadAce -Path $projectionPath -Sid $sid -IsDirectory $false
            }
            Write-HostInputLeaseState -Runtime $runtime -Status 'CreatingShares'
            $shareParameters = @{
                Name = $entry.ShareName
                Path = $sharePath
                Temporary = $true
                Description = "Ephemeral Codex Hyper-V read-only input $RequestId/$($entry.Name)"
                ConcurrentUserLimit = 1
                FolderEnumerationMode = 'AccessBased'
                CachingMode = 'None'
                ReadAccess = $runtime.Username
                EncryptData = $true
                ErrorAction = 'Stop'
            }
            if ($shareSupportsIsolatedTransport) { $shareParameters.IsolatedTransport = $true }
            New-SmbShare @shareParameters | Out-Null
            $entry.ShareCreated = $true
            Write-HostInputLeaseState -Runtime $runtime -Status 'SharesReady'
        }
        $runtime
    }
    catch {
        $creationError = $_
        try { Remove-HostInputShareRuntime -Runtime $runtime -BrokerRoot $BrokerRoot -SuppressErrors | Out-Null } catch { }
        throw $creationError
    }
}

function Connect-HostInputVmNetwork {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $VmName
    )

    Import-Module Hyper-V -ErrorAction Stop
    foreach ($old in @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'CodexHostInput-*' })) {
        Remove-VMNetworkAdapter -VMNetworkAdapter $old -ErrorAction SilentlyContinue
    }
    Add-VMNetworkAdapter -VMName $VmName -Name $Runtime.VmAdapterName -SwitchName $Runtime.SwitchName -DeviceNaming On -ErrorAction Stop | Out-Null
    $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $Runtime.VmAdapterName -ErrorAction Stop
    Set-VMNetworkAdapter -VMNetworkAdapter $adapter -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On -ErrorAction Stop
    foreach ($existingAcl in @(Get-VMNetworkAdapterAcl -VMNetworkAdapter $adapter -ErrorAction SilentlyContinue)) {
        Remove-VMNetworkAdapterAcl -InputObject $existingAcl -ErrorAction SilentlyContinue
    }
    # Client Hyper-V's IP ACLs also filter the ARP discovery required on an
    # internal switch, including when only a specific allow is present. Keep
    # this request adapter free of IP ACLs. The worker-specific switch contains
    # only this VM and its host adapter; forwarding and weak-host routing are
    # disabled, while the interface firewall permits only SMB from the assigned
    # guest /32 and blocks every other inbound protocol/port.
    Write-HostInputLeaseState -Runtime $Runtime -Status 'VmNetworkAttached'
    [pscustomobject][ordered]@{
        AdapterName = [string]$adapter.Name
        MacAddress = [string]$adapter.MacAddress
        HostAddress = [string]$Runtime.HostAddress
        GuestAddress = [string]$Runtime.GuestAddress
    }
}

function Initialize-GuestHostInputNetwork {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $MacAddress
    )

    $result = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($ExpectedMac, $GuestAddress, $HostAddress, $HostMacAddress, $PrefixLength)
        $normalizedMac = $ExpectedMac -replace '[:-]', ''
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        $adapter = $null
        do {
            $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
                (([string]$_.MacAddress) -replace '[:-]', '') -eq $normalizedMac
            } | Select-Object -First 1
            if (-not $adapter) { Start-Sleep -Milliseconds 250 }
        } while (-not $adapter -and [DateTime]::UtcNow -lt $deadline)
        if (-not $adapter) { throw "Guest host-input adapter did not appear: $ExpectedMac" }
        Enable-NetAdapter -InputObject $adapter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -Forwarding Disabled -WeakHostSend Disabled -WeakHostReceive Disabled -ErrorAction SilentlyContinue | Out-Null
        foreach ($address in @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if (-not [string]::Equals([string]$address.IPAddress, $GuestAddress, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        if (-not (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -IPAddress $GuestAddress -ErrorAction SilentlyContinue)) {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $GuestAddress -PrefixLength $PrefixLength -AddressFamily IPv4 -ErrorAction Stop | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue

        # New-NetIPAddress can return while Duplicate Address Detection still
        # marks the address Tentative. Socket creation during that interval
        # fails immediately with WSAENETUNREACH even though configuration is
        # otherwise correct. Wait for the adapter, address, and on-link route.
        $networkReadyDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $guestIp = $null
        $route = $null
        do {
            $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {
                (([string]$_.MacAddress) -replace '[:-]', '') -eq $normalizedMac
            } | Select-Object -First 1
            $guestIp = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -IPAddress $GuestAddress -ErrorAction SilentlyContinue | Select-Object -First 1
            $route = Find-NetRoute -InterfaceIndex $adapter.ifIndex -RemoteIPAddress $HostAddress -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'DestinationPrefix' } | Select-Object -First 1
            if ([string]$adapter.Status -eq 'Up' -and [string]$guestIp.AddressState -eq 'Preferred' -and $route) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $networkReadyDeadline)
        if ([string]$adapter.Status -ne 'Up' -or [string]$guestIp.AddressState -ne 'Preferred' -or -not $route) {
            $diagnostic = [ordered]@{
                AdapterStatus = [string]$adapter.Status
                MediaConnectionState = [string]$adapter.MediaConnectionState
                AddressState = [string]$guestIp.AddressState
                InterfaceIndex = [int]$adapter.ifIndex
                Routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object DestinationPrefix, NextHop, State)
            } | ConvertTo-Json -Depth 5 -Compress
            throw "Guest host-input network did not become routable: $diagnostic"
        }

        $normalizedHostMac = ($HostMacAddress -replace '[:-]', '').ToUpperInvariant()
        if ($normalizedHostMac -notmatch '^[0-9A-F]{12}$') {
            throw "Host-input management adapter returned an invalid MAC address: $HostMacAddress"
        }
        $formattedHostMac = ($normalizedHostMac -replace '(.{2})(?!$)', '$1-')
        Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $HostAddress -ErrorAction SilentlyContinue | Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
        New-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $HostAddress -LinkLayerAddress $formattedHostMac -State Permanent -ErrorAction Stop | Out-Null
        $hostNeighbor = Get-NetNeighbor -InterfaceIndex $adapter.ifIndex -IPAddress $HostAddress -ErrorAction Stop | Select-Object -First 1

        $lastConnectError = $null
        $connectWatch = [Diagnostics.Stopwatch]::StartNew()
        $connected = $false
        for ($connectAttempt = 1; $connectAttempt -le 8 -and -not $connected; $connectAttempt++) {
            $tcp = New-Object Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($HostAddress, 445, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw "Timed out connecting to host SMB endpoint $HostAddress`:445." }
                $tcp.EndConnect($async)
                $connected = $true
            }
            catch {
                $lastConnectError = $_.Exception.Message
                if ($connectAttempt -lt 8) { Start-Sleep -Milliseconds ([Math]::Min(2000, 200 * [Math]::Pow(2, $connectAttempt - 1))) }
            }
            finally { $tcp.Dispose() }
        }
        $connectWatch.Stop()
        if (-not $connected) {
            $connectDiagnostic = [ordered]@{
                AdapterStatus = [string]$adapter.Status
                AddressState = [string]$guestIp.AddressState
                GuestAddress = [string]$GuestAddress
                RouteDestinationPrefix = [string]$route.DestinationPrefix
                RouteNextHop = [string]$route.NextHop
                RouteInterfaceIndex = [int]$route.InterfaceIndex
                NeighborState = [string]$hostNeighbor.State
                NeighborMacAddress = [string]$hostNeighbor.LinkLayerAddress
            } | ConvertTo-Json -Depth 4 -Compress
            throw "Could not connect to host SMB endpoint $HostAddress`:445 after 8 attempts: $lastConnectError Diagnostic: $connectDiagnostic"
        }
        [pscustomobject][ordered]@{
            InterfaceAlias = [string]$adapter.Name
            InterfaceIndex = [int]$adapter.ifIndex
            GuestAddress = $GuestAddress
            HostAddress = $HostAddress
            AddressState = [string]$guestIp.AddressState
            RouteDestinationPrefix = [string]$route.DestinationPrefix
            HostNeighborState = [string]$hostNeighbor.State
            HostNeighborMacAddress = [string]$hostNeighbor.LinkLayerAddress
            ConnectMilliseconds = [Math]::Round($connectWatch.Elapsed.TotalMilliseconds, 3)
        }
    } -ArgumentList $MacAddress, $Runtime.GuestAddress, $Runtime.HostAddress, $Runtime.Network.HostMacAddress, ([int]$Runtime.Network.PrefixLength) | Select-Object -Last 1
    Write-HostInputLeaseState -Runtime $Runtime -Status 'GuestNetworkReady'
    $result
}

function Get-GuestHostInputDriveLetters {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [ValidateRange(1, 8)] [int] $Count
    )

    $used = @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.Name).ToUpperInvariant() })
    })
    $available = @('Z','Y','X','W','V','U','T','S','R','Q','P') | Where-Object { $used -notcontains $_ } | Select-Object -First $Count
    if (@($available).Count -ne $Count) { throw "The guest has fewer than $Count free drive letters for read-only host inputs." }
    @($available)
}

function Remove-HostInputShareRuntime {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [switch] $SuppressErrors
    )

    $errors = New-Object Collections.Generic.List[string]
    $vmName = [string]$Runtime.VmName
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.VmAdapterName) -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        try {
            Get-VMNetworkAdapter -VMName $vmName -Name ([string]$Runtime.VmAdapterName) -ErrorAction SilentlyContinue | Remove-VMNetworkAdapter -ErrorAction Stop
        }
        catch { $errors.Add("VM network adapter: $($_.Exception.Message)") }
    }
    foreach ($input in @($Runtime.Inputs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$input.ShareName)) {
            try { Remove-SmbShare -Name ([string]$input.ShareName) -Force -Confirm:$false -ErrorAction SilentlyContinue }
            catch { $errors.Add("SMB share $($input.ShareName): $($_.Exception.Message)") }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AccountName)) {
        try { Remove-LocalUser -Name ([string]$Runtime.AccountName) -ErrorAction SilentlyContinue }
        catch { $errors.Add("Local account $($Runtime.AccountName): $($_.Exception.Message)") }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Runtime.AccountSid)) {
        foreach ($input in @($Runtime.Inputs)) {
            if ([string]::IsNullOrWhiteSpace([string]$input.AclPath)) { continue }
            try { Remove-HostInputReadAce -Path ([string]$input.AclPath) -Sid ([string]$Runtime.AccountSid) }
            catch { $errors.Add("ACL $($input.AclPath): $($_.Exception.Message)") }
        }
    }
    foreach ($input in @($Runtime.Inputs)) {
        if ([string]::IsNullOrWhiteSpace([string]$input.ProjectionPath)) { continue }
        try {
            $projection = [IO.Path]::GetFullPath([string]$input.ProjectionPath)
            $allowedA = [IO.Path]::GetFullPath((Join-Path $BrokerRoot 'HostInputProjections')).TrimEnd('\') + '\'
            $allowedB = ([IO.Path]::GetPathRoot($projection).TrimEnd('\') + '\.CodexHyperVHostInputProjections\')
            if (-not $projection.StartsWith($allowedA, [StringComparison]::OrdinalIgnoreCase) -and -not $projection.StartsWith($allowedB, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing projection cleanup outside a managed root: $projection"
            }
            Remove-Item -LiteralPath $projection -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { $errors.Add("Projection $($input.ProjectionPath): $($_.Exception.Message)") }
    }
    $Runtime.CleanupErrors = $errors.ToArray()
    if ($errors.Count -eq 0) {
        Remove-Item -LiteralPath ([string]$Runtime.StatePath) -Force -ErrorAction SilentlyContinue
    }
    else {
        try { Write-HostInputLeaseState -Runtime $Runtime -Status 'CleanupFailed' } catch { }
    }
    $result = [pscustomobject][ordered]@{
        Success = $errors.Count -eq 0
        Errors = $errors.ToArray()
        StateDeleted = -not (Test-Path -LiteralPath ([string]$Runtime.StatePath) -PathType Leaf)
    }
    if (-not $result.Success -and -not $SuppressErrors) {
        throw ('Read-only host-input cleanup failed: ' + ($result.Errors -join ' | '))
    }
    $result
}

function ConvertFrom-HostInputLeaseState {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] [string] $StatePath
    )
    [pscustomobject][ordered]@{
        StatePath = $StatePath
        RequestId = [string]$State.RequestId
        WorkerId = [int]$State.WorkerId
        VmName = [string]$State.VmName
        Status = [string]$State.Status
        OwnerProcessId = [int]$State.OwnerProcessId
        OwnerProcessStartUtc = [string]$State.OwnerProcessStartUtc
        AccountName = [string]$State.AccountName
        AccountSid = [string]$State.AccountSid
        Username = $null
        Password = $null
        VmAdapterName = [string]$State.VmAdapterName
        SwitchName = [string]$State.SwitchName
        HostAddress = [string]$State.HostAddress
        GuestAddress = [string]$State.GuestAddress
        Network = $null
        Inputs = @($State.Inputs)
        CreatedUtc = [string]$State.CreatedUtc
        UpdatedUtc = [string]$State.UpdatedUtc
        CleanupErrors = @($State.CleanupErrors)
    }
}

function Recover-OrphanedHostInputResources {
    param(
        [Parameter(Mandatory = $true)] [string] $BrokerRoot,
        [string] $ExcludeRequestId
    )

    $stateRoot = Get-HostInputStateRoot -BrokerRoot $BrokerRoot
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $recovered = New-Object Collections.Generic.List[object]
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $state = Get-Content -Raw -LiteralPath $stateFile.FullName | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($ExcludeRequestId) -and [string]::Equals([string]$state.RequestId, $ExcludeRequestId, [StringComparison]::Ordinal)) { continue }
            if (Test-HostInputOwnerAlive -State $state) { continue }
            $runtime = ConvertFrom-HostInputLeaseState -State $state -StatePath $stateFile.FullName
            $vm = Get-VM -Name ([string]$runtime.VmName) -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -ne 'Off') {
                Stop-VM -Name $runtime.VmName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
            }
            $cleanup = Remove-HostInputShareRuntime -Runtime $runtime -BrokerRoot $BrokerRoot -SuppressErrors
            $recovered.Add([pscustomobject][ordered]@{ RequestId = $runtime.RequestId; Success = [bool]$cleanup.Success; Errors = @($cleanup.Errors) })
        }
        catch {
            $recovered.Add([pscustomobject][ordered]@{ RequestId = [IO.Path]::GetFileNameWithoutExtension($stateFile.Name); Success = $false; Errors = @($_.Exception.Message) })
        }
    }
    $recovered.ToArray()
}
