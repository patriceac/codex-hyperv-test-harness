[CmdletBinding()]
param(
    [string] $VmName = 'Codex-Harness-Baseline',
    [string] $ConfigPath,
    [string] $CredentialPath,
    [string] $NetworkSwitchName = 'Default Switch',
    [ValidatePattern('^\d+\.\d+$')] [string] $DotNetChannel = '10.0',
    [string] $ExpectedDotNetSdkVersion,
    [hashtable] $ExpectedInstalledChannelVersions = @{},
    [ValidateRange(1, 20)] [int] $MaxWindowsUpdatePasses = 12,
    [ValidateSet('Automatic', 'Manual')] [string] $GuestRestartMode = 'Automatic',
    [string] $CancellationPath,
    [switch] $AllowApprovedConnectedStart,
    [string] $StatusPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($CredentialPath)) { $CredentialPath = Join-Path ([string]$layout.HarnessSourceRoot) 'private\guest-credential.json' }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'image-servicing-status.json' }
$downloadRoot = Join-Path ([string]$layout.RecoveryRoot) 'Media\DotNet'
$startedUtc = [DateTime]::UtcNow
$session = $null
$networkConnected = $false
$success = $false
$windowsUpdatePasses = New-Object Collections.Generic.List[object]
$windowsUpdateOperations = New-Object Collections.Generic.List[object]
$sdkResults = New-Object Collections.Generic.List[object]
$guestNetworkOriginal = $null
$guestNetworkRestored = $false
$cancelled = $false
$manualRestartPending = $false
$stopDetails = $null
$credential = $null
$restartGuardState = $null
$restartGuardActive = $false
$restartGuardStatePath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($StatusPath))) 'baseline-manual-restart-guard.json'
$cleanupFailures = New-Object Collections.Generic.List[string]

function Write-ImageServicingStatus {
    param(
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $true)] [string] $Message,
        [Nullable[bool]] $Succeeded = $null,
        $Details = $null
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($StatusPath))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $StatusPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [ordered]@{
            Success = $Succeeded
            Phase = $Phase
            Message = $Message
            StartedUtc = $startedUtc.ToString('o')
            UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            VmName = $VmName
            Details = $Details
        } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $StatusPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ImageServicingNotCancelled {
    if (-not [string]::IsNullOrWhiteSpace($CancellationPath) -and (Test-Path -LiteralPath $CancellationPath -PathType Leaf)) {
        $script:cancelled = $true
        $script:stopDetails = [pscustomobject][ordered]@{
            Reason = 'VisibleLauncherExited'
            CancellationPath = [IO.Path]::GetFullPath($CancellationPath)
            DetectedUtc = [DateTime]::UtcNow.ToString('o')
        }
        throw [OperationCanceledException]::new('Guest image servicing was cancelled because the visible launcher exited.')
    }
}

function Request-ManualGuestRestart {
    param(
        [Parameter(Mandatory = $true)] [string] $Stage,
        [Parameter(Mandatory = $true)] $Reason
    )

    $script:manualRestartPending = $true
    $script:stopDetails = [pscustomobject][ordered]@{
        Stage = $Stage
        Reason = $Reason
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
    }
    throw [InvalidOperationException]::new('A user-controlled guest restart is required before servicing can continue.')
}

function Enable-GuestManualRestartGuard {
    param([Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession)

    $state = $null
    if (Test-Path -LiteralPath $restartGuardStatePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $restartGuardStatePath | ConvertFrom-Json
        if ([string]$state.VmName -ne $VmName) { throw "Manual restart guard state belongs to '$($state.VmName)', not '$VmName'." }
    }
    else {
        $state = Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
            $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
            $keyExisted = Test-Path -LiteralPath $path
            $item = if ($keyExisted) { Get-Item -LiteralPath $path } else { $null }
            $values = foreach ($name in @('NoAutoRebootWithLoggedOnUsers', 'AlwaysAutoRebootAtScheduledTime')) {
                $exists = $item -and $name -in @($item.Property)
                [pscustomobject][ordered]@{
                    Name = $name
                    Existed = [bool]$exists
                    Value = if ($exists) { [int](Get-ItemPropertyValue -LiteralPath $path -Name $name) } else { $null }
                }
            }
            [pscustomobject][ordered]@{
                VmName = $using:VmName
                RegistryPath = $path
                KeyExisted = [bool]$keyExisted
                Values = @($values)
                CapturedUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        $parent = Split-Path -Parent $restartGuardStatePath
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $temporary = $restartGuardStatePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        try {
            $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
            Move-Item -LiteralPath $temporary -Destination $restartGuardStatePath -Force
        }
        finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        param($Path)
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -LiteralPath $Path -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -LiteralPath $Path -Name AlwaysAutoRebootAtScheduledTime -PropertyType DWord -Value 0 -Force | Out-Null
    } -ArgumentList ([string]$state.RegistryPath)
    $state
}

function Restore-GuestManualRestartGuard {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] $State
    )

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        param($GuardState)
        $path = [string]$GuardState.RegistryPath
        New-Item -Path $path -Force | Out-Null
        foreach ($value in @($GuardState.Values)) {
            if ([bool]$value.Existed) {
                New-ItemProperty -LiteralPath $path -Name ([string]$value.Name) -PropertyType DWord -Value ([int]$value.Value) -Force | Out-Null
            }
            else {
                Remove-ItemProperty -LiteralPath $path -Name ([string]$value.Name) -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not [bool]$GuardState.KeyExisted) {
            $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($key -and @($key.Property).Count -eq 0) { Remove-Item -LiteralPath $path -Force }
        }
    } -ArgumentList $State
    Remove-Item -LiteralPath $restartGuardStatePath -Force -ErrorAction Stop
}

function New-GuestCredential {
    $credentialData = Get-Content -Raw -LiteralPath $CredentialPath | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
}

function Connect-PowerShellDirect {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [ValidateRange(30, 900)] [int] $TimeoutSeconds = 300,
        [string] $DifferentBootMarker
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $candidate = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
            $marker = Invoke-Command -Session $candidate -ErrorAction Stop -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            }
            if ([string]::IsNullOrWhiteSpace($DifferentBootMarker) -or [string]$marker -ne $DifferentBootMarker) {
                return $candidate
            }
            Remove-PSSession -Session $candidate -ErrorAction SilentlyContinue
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for PowerShell Direct on $VmName. Last error: $lastError"
}

function Restart-GuestAndReconnect {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential
    )

    $bootMarker = Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    }
    try {
        Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock { Restart-Computer -Force }
    }
    catch {
        # PowerShell Direct normally disconnects while the guest restarts.
    }
    Remove-PSSession -Session $CurrentSession -ErrorAction SilentlyContinue
    Connect-PowerShellDirect -Credential $Credential -TimeoutSeconds 600 -DifferentBootMarker $bootMarker
}

function Wait-GuestWindowsUpdateIdle {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [ValidateRange(10, 600)] [int] $TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = $null
    $lastError = $null
    do {
        try {
            $lastState = Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
                $session = New-Object -ComObject Microsoft.Update.Session
                $installer = $session.CreateUpdateInstaller()
                [pscustomobject][ordered]@{
                    InstallerBusy = [bool]$installer.IsBusy
                    CheckedUtc = [DateTime]::UtcNow.ToString('o')
                }
            }
            $lastError = $null
            if (-not [bool]$lastState.InstallerBusy) { return $lastState }
        }
        catch { $lastError = $_.Exception.Message }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Windows Update did not become idle after its synchronous operation. Last state: $($lastState | ConvertTo-Json -Compress); last error: $lastError"
}

function Get-GuestInventory {
    param([Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession)

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        $os = Get-CimInstance Win32_OperatingSystem
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $sdkLines = @()
        $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        $dotnetPath = if ($dotnetCommand) { [string]$dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
        if (Test-Path -LiteralPath $dotnetPath -PathType Leaf) {
            $sdkLines = @(& $dotnetPath --list-sdks 2>$null)
        }
        $explicitPendingReboot =
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $pendingRename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME
            OsCaption = [string]$os.Caption
            OsVersion = [string]$os.Version
            OsBuildNumber = [string]$os.BuildNumber
            DisplayVersion = [string]$currentVersion.DisplayVersion
            EditionId = [string]$currentVersion.EditionID
            LastBootUpTimeUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            DotNetSdks = @($sdkLines | ForEach-Object { [string]$_ })
            PendingReboot = [bool]$explicitPendingReboot
            PendingFileRenameCount = if ($pendingRename) { @($pendingRename.PendingFileRenameOperations).Count } else { 0 }
        }
    }
}

function Wait-GuestUpdateConnectivity {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [ValidateRange(30, 600)] [int] $TimeoutSeconds = 300
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $renewAttempted = $false
    $lastState = $null
    do {
        $lastState = Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
            $configurations = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
                $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up'
            })
            $ipv4 = @($configurations.IPv4Address | Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress)
            $gateways = @($configurations.IPv4DefaultGateway | Where-Object NextHop | ForEach-Object NextHop)
            $dnsServers = @($configurations.DnsServer.ServerAddresses | Where-Object { $_ })
            $resolved = @()
            $dnsError = $null
            try {
                $resolved = @([Net.Dns]::GetHostAddresses('download.windowsupdate.com') | ForEach-Object IPAddressToString)
            }
            catch { $dnsError = $_.Exception.Message }
            [pscustomobject][ordered]@{
                IPv4Addresses = $ipv4
                IPv4Gateways = $gateways
                DnsServers = $dnsServers
                ResolvedWindowsUpdateAddresses = $resolved
                DnsError = $dnsError
                WinHttpProxy = ((& netsh.exe winhttp show proxy 2>&1) -join "`n")
            }
        }
        if (@($lastState.IPv4Addresses).Count -gt 0 -and
            @($lastState.IPv4Gateways).Count -gt 0 -and
            @($lastState.ResolvedWindowsUpdateAddresses).Count -gt 0) {
            return $lastState
        }
        if (-not $renewAttempted -and [DateTime]::UtcNow -ge $deadline.AddSeconds(-1 * [math]::Max(30, $TimeoutSeconds - 45))) {
            Invoke-Command -Session $CurrentSession -ErrorAction SilentlyContinue -ScriptBlock { ipconfig.exe /renew | Out-Null }
            $renewAttempted = $true
        }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)

    throw ('The approved guest update network did not become ready: ' + ($lastState | ConvertTo-Json -Depth 6 -Compress))
}

function Get-GuestNetworkConfiguration {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] [string] $AdapterMacAddress
    )

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        param($ExpectedMacAddress)
        $normalizedExpected = ([string]$ExpectedMacAddress -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
        $adapter = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            (([string]$_.MacAddress -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()) -eq $normalizedExpected
        })
        if ($adapter.Count -ne 1) { throw "Expected exactly one guest adapter with MAC $ExpectedMacAddress; found $($adapter.Count)." }
        $adapter = $adapter[0]
        $ipInterface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
        $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*'
        } | ForEach-Object {
            [pscustomobject][ordered]@{ IPAddress = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength }
        })
        $defaultRoutes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject][ordered]@{ NextHop = [string]$_.NextHop; RouteMetric = [int]$_.RouteMetric }
        })
        $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
        $original = [pscustomobject][ordered]@{
            InterfaceIndex = [int]$adapter.ifIndex
            InterfaceAlias = [string]$adapter.Name
            MacAddress = $normalizedExpected
            Dhcp = [string]$ipInterface.Dhcp
            InterfaceMetric = [int]$ipInterface.InterfaceMetric
            Addresses = $addresses
            DefaultRoutes = $defaultRoutes
            DnsServers = $dnsServers
        }

        $original
    } -ArgumentList $AdapterMacAddress
}

function Enable-GuestTemporaryDhcp {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] $Original
    )

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        param($Saved)
        $interfaceIndex = [int]$Saved.InterfaceIndex
        foreach ($route in @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
            Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($address in @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*'
        })) {
            Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction SilentlyContinue
        }
        Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses -ErrorAction Stop
        $renew = Start-Process -FilePath 'ipconfig.exe' -ArgumentList '/renew' -WindowStyle Hidden -PassThru
        if (-not $renew.WaitForExit(60000)) {
            Stop-Process -Id $renew.Id -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $Original
}

function Restore-GuestNetworkConfiguration {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] $Original
    )

    Invoke-Command -Session $CurrentSession -ErrorAction Stop -ScriptBlock {
        param($Saved)
        $interfaceIndex = [int]$Saved.InterfaceIndex
        foreach ($route in @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
            Remove-NetRoute -InputObject $route -Confirm:$false -ErrorAction SilentlyContinue
        }
        foreach ($address in @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*'
        })) {
            Remove-NetIPAddress -InputObject $address -Confirm:$false -ErrorAction SilentlyContinue
        }

        if ([string]$Saved.Dhcp -eq 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Enabled -InterfaceMetric ([int]$Saved.InterfaceMetric) -ErrorAction Stop | Out-Null
            if (@($Saved.DnsServers).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses @($Saved.DnsServers) -ErrorAction Stop
            }
            else { Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses -ErrorAction Stop }
            ipconfig.exe /renew | Out-Null
        }
        else {
            Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Disabled -InterfaceMetric ([int]$Saved.InterfaceMetric) -ErrorAction Stop | Out-Null
            $addresses = @($Saved.Addresses)
            $routes = @($Saved.DefaultRoutes)
            for ($index = 0; $index -lt $addresses.Count; $index++) {
                $parameters = @{
                    InterfaceIndex = $interfaceIndex
                    AddressFamily = 'IPv4'
                    IPAddress = [string]$addresses[$index].IPAddress
                    PrefixLength = [int]$addresses[$index].PrefixLength
                    ErrorAction = 'Stop'
                }
                if ($index -eq 0 -and $routes.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$routes[0].NextHop)) {
                    $parameters.DefaultGateway = [string]$routes[0].NextHop
                }
                New-NetIPAddress @parameters | Out-Null
            }
            if ($routes.Count -gt 0 -and $addresses.Count -eq 0) {
                throw 'Cannot restore a default route without an original IPv4 address.'
            }
            if ($routes.Count -gt 1) {
                foreach ($route in $routes) {
                    New-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop ([string]$route.NextHop) -RouteMetric ([int]$route.RouteMetric) -ErrorAction Stop | Out-Null
                }
            }
            if (@($Saved.DnsServers).Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ServerAddresses @($Saved.DnsServers) -ErrorAction Stop
            }
            else { Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses -ErrorAction Stop }
        }

        $restoredInterface = Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop
        $restoredAddresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*'
        } | ForEach-Object IPAddress | Sort-Object)
        $expectedAddresses = @($Saved.Addresses | ForEach-Object { [string]$_.IPAddress } | Sort-Object)
        $restoredRoutes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object NextHop | Sort-Object)
        $expectedRoutes = @($Saved.DefaultRoutes | ForEach-Object { [string]$_.NextHop } | Sort-Object)
        $restoredDns = @((Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ } | Sort-Object)
        $expectedDns = @($Saved.DnsServers | ForEach-Object { [string]$_ } | Sort-Object)
        if ([string]$restoredInterface.Dhcp -ne [string]$Saved.Dhcp -or
            ($restoredAddresses -join '|') -ne ($expectedAddresses -join '|') -or
            ($restoredRoutes -join '|') -ne ($expectedRoutes -join '|') -or
            ($restoredDns -join '|') -ne ($expectedDns -join '|')) {
            throw 'The guest network configuration did not match its pre-servicing state after restoration.'
        }
        [pscustomobject][ordered]@{
            InterfaceIndex = $interfaceIndex
            Dhcp = [string]$restoredInterface.Dhcp
            Addresses = $restoredAddresses
            DefaultRoutes = $restoredRoutes
            DnsServers = $restoredDns
            MatchesOriginal = $true
        }
    } -ArgumentList $Original
}

$windowsUpdateSearchScript = {
    $ErrorActionPreference = 'Stop'
    $microsoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
    $upgradeClassificationId = '3689bd2a-b205-4af4-8d4a-a63924c5e9d5'
    $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"

    function Invoke-UpdateSearchWithRetry {
        param(
            [Parameter(Mandatory = $true)] [int] $ServerSelection,
            [string] $ServiceId,
            [ValidateRange(1, 10)] [int] $MaxAttempts = 6
        )

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                foreach ($serviceName in @('cryptsvc', 'bits', 'wuauserv')) {
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
                    if ($service.Status -ne 'Running') {
                        Start-Service -Name $serviceName -ErrorAction Stop
                        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
                    }
                }
                $session = New-Object -ComObject Microsoft.Update.Session
                $session.ClientApplicationID = 'Codex Hyper-V baseline servicing'
                $candidateSearcher = $session.CreateUpdateSearcher()
                $candidateSearcher.ServerSelection = $ServerSelection
                if (-not [string]::IsNullOrWhiteSpace($ServiceId)) { $candidateSearcher.ServiceID = $ServiceId }
                $candidateResult = $candidateSearcher.Search($criteria)
                return [pscustomobject][ordered]@{ Session = $session; SearchResult = $candidateResult; Attempt = $attempt }
            }
            catch {
                $exception = $_.Exception
                while ($exception.InnerException) { $exception = $exception.InnerException }
                $serviceStopping = [int]$exception.HResult -eq -2145124322 -or $exception.Message -match '8024001E'
                if (-not $serviceStopping -or $attempt -eq $MaxAttempts) { throw }
                Start-Sleep -Seconds 10
            }
        }
    }

    $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    $registered = $false
    foreach ($service in @($serviceManager.Services)) {
        if ([string]$service.ServiceID -eq $microsoftUpdateServiceId) { $registered = $true; break }
    }
    if (-not $registered) {
        [void]$serviceManager.AddService2($microsoftUpdateServiceId, 7, '')
    }

    $updateService = 'MicrosoftUpdate'
    $serviceFallbackReason = $null
    try {
        $searchOperation = Invoke-UpdateSearchWithRetry -ServerSelection 3 -ServiceId $microsoftUpdateServiceId
        $updateSession = $searchOperation.Session
        $searchResult = $searchOperation.SearchResult
    }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        if ([int]$exception.HResult -ne -2145091564 -and $exception.Message -notmatch '80248014') { throw }
        $serviceFallbackReason = 'WU_E_DS_UNKNOWNSERVICE (0x80248014)'
        $updateService = 'WindowsUpdate'
        $searchOperation = Invoke-UpdateSearchWithRetry -ServerSelection 2
        $updateSession = $searchOperation.Session
        $searchResult = $searchOperation.SearchResult
    }
    $selected = New-Object -ComObject Microsoft.Update.UpdateColl
    $skipped = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $searchResult.Updates.Count; $index++) {
        $update = $searchResult.Updates.Item($index)
        $categoryIds = @()
        for ($categoryIndex = 0; $categoryIndex -lt $update.Categories.Count; $categoryIndex++) {
            $categoryIds += [string]$update.Categories.Item($categoryIndex).CategoryID
        }
        $reason = $null
        if ([bool]$update.BrowseOnly) { $reason = 'BrowseOnly' }
        elseif (-not [bool]$update.AutoSelectOnWebSites -and -not [bool]$update.IsMandatory) { $reason = 'Optional' }
        elseif ([string]$update.Title -match '(?i)\bPreview\b|\bInsider\b|\bAperçu\b') { $reason = 'Preview' }
        elseif ($categoryIds -contains $upgradeClassificationId) { $reason = 'FeatureUpgrade' }
        if ($reason) {
            $skipped.Add([pscustomobject][ordered]@{ Title = [string]$update.Title; Reason = $reason })
            continue
        }
        if (-not [bool]$update.EulaAccepted) { $update.AcceptEula() }
        [void]$selected.Add($update)
    }

    $global:CodexImageUpdateWuaState = [pscustomobject]@{
        Session = $updateSession
        Selected = $selected
    }
    $cbsRebootPending = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $windowsUpdateRebootRequired = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pendingRename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    $pendingFileRenameCount = if ($pendingRename) { @($pendingRename.PendingFileRenameOperations).Count } else { 0 }
    $pendingReasons = New-Object Collections.Generic.List[string]
    if ($cbsRebootPending) { $pendingReasons.Add('CbsRebootPending') }
    if ($windowsUpdateRebootRequired) { $pendingReasons.Add('WindowsUpdateRebootRequired') }
    if ($pendingFileRenameCount -gt 0) { $pendingReasons.Add('PendingFileRenameOperations') }
    [pscustomobject][ordered]@{
        SelectedCount = $selected.Count
        UpdateService = $updateService
        ServiceFallbackReason = $serviceFallbackReason
        SearchAttempt = [int]$searchOperation.Attempt
        SelectedTitles = [string[]]@(if ($selected.Count -gt 0) { 0..($selected.Count - 1) | ForEach-Object { [string]$selected.Item($_).Title } })
        Skipped = $skipped.ToArray()
        RebootRequired = [bool]($cbsRebootPending -or $windowsUpdateRebootRequired)
        PendingFileRenameCount = [int]$pendingFileRenameCount
        PendingRebootReasons = $pendingReasons.ToArray()
    }
}

$windowsUpdateDownloadScript = {
    $ErrorActionPreference = 'Stop'
    if (-not $global:CodexImageUpdateWuaState -or -not $global:CodexImageUpdateWuaState.Session -or -not $global:CodexImageUpdateWuaState.Selected) {
        throw 'Windows Update download state is unavailable.'
    }
    $downloader = $global:CodexImageUpdateWuaState.Session.CreateUpdateDownloader()
    $downloader.Updates = $global:CodexImageUpdateWuaState.Selected
    $downloadResult = $downloader.Download()
    if ([int]$downloadResult.ResultCode -notin @(2, 3)) {
        throw "Windows Update download failed with result code $([int]$downloadResult.ResultCode)."
    }
    [pscustomobject][ordered]@{
        ResultCode = [int]$downloadResult.ResultCode
        UpdateCount = [int]$global:CodexImageUpdateWuaState.Selected.Count
    }
}

$windowsUpdateInstallScript = {
    $ErrorActionPreference = 'Stop'
    if (-not $global:CodexImageUpdateWuaState -or -not $global:CodexImageUpdateWuaState.Session -or -not $global:CodexImageUpdateWuaState.Selected) {
        throw 'Windows Update installation state is unavailable.'
    }
    $selected = $global:CodexImageUpdateWuaState.Selected
    $installer = $global:CodexImageUpdateWuaState.Session.CreateUpdateInstaller()
    if ([bool]$installer.IsBusy) { throw 'Windows Update reports another installation in progress before the approved install operation.' }
    $installer.Updates = $selected
    $installationResult = $installer.Install()
    if ([int]$installationResult.ResultCode -notin @(2, 3, 4)) {
        throw "Windows Update installation failed with result code $([int]$installationResult.ResultCode)."
    }
    $perUpdate = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt $selected.Count; $index++) {
        $result = $installationResult.GetUpdateResult($index)
        $perUpdate.Add([pscustomobject][ordered]@{
            Title = [string]$selected.Item($index).Title
            ResultCode = [int]$result.ResultCode
            HResult = [int]$result.HResult
            RebootRequired = [bool]$result.RebootRequired
        })
    }
    $failed = @($perUpdate | Where-Object { $_.ResultCode -notin @(2, 3) })
    $cbsRebootPending = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $windowsUpdateRebootRequired = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pendingRename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    $pendingFileRenameCount = if ($pendingRename) { @($pendingRename.PendingFileRenameOperations).Count } else { 0 }
    $pendingReasons = New-Object Collections.Generic.List[string]
    if ([bool]$installationResult.RebootRequired) { $pendingReasons.Add('WindowsUpdateInstallationResult') }
    if ($cbsRebootPending) { $pendingReasons.Add('CbsRebootPending') }
    if ($windowsUpdateRebootRequired) { $pendingReasons.Add('WindowsUpdateRebootRequired') }
    if ($pendingFileRenameCount -gt 0) { $pendingReasons.Add('PendingFileRenameOperations') }
    [pscustomobject][ordered]@{
        SelectedCount = $selected.Count
        SelectedTitles = @(0..($selected.Count - 1) | ForEach-Object { [string]$selected.Item($_).Title })
        InstallationResultCode = [int]$installationResult.ResultCode
        RebootRequired = [bool]([bool]$installationResult.RebootRequired -or $cbsRebootPending -or $windowsUpdateRebootRequired)
        PendingFileRenameCount = [int]$pendingFileRenameCount
        PendingRebootReasons = $pendingReasons.ToArray()
        UpdateResults = $perUpdate.ToArray()
        FailedCount = $failed.Count
        FailedUpdates = @($failed)
    }
}

$windowsUpdateClearStateScript = {
    Remove-Variable -Name CodexImageUpdateWuaState -Scope Global -Force -ErrorAction SilentlyContinue
}

function Invoke-WindowsUpdateToConvergence {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $CurrentSession,
        [Parameter(Mandatory = $true)] [Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)] [string] $Stage
    )

    $activeSession = $CurrentSession
    for ($pass = 1; $pass -le $MaxWindowsUpdatePasses; $pass++) {
        Write-ImageServicingStatus -Phase 'WindowsUpdateSearch' -Message "$Stage Windows Update search pass $pass of $MaxWindowsUpdatePasses." -Details @{
            CompletedPasses = $windowsUpdatePasses.ToArray()
            CompletedOperations = $windowsUpdateOperations.ToArray()
            SdkResults = $sdkResults.ToArray()
        }
        $result = $null
        $search = $null
        $download = $null
        $installation = $null
        $idle = $null
        try {
            $search = Invoke-Command -Session $activeSession -ErrorAction Stop -ScriptBlock $windowsUpdateSearchScript
            $idle = Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession
            $windowsUpdateOperations.Add([pscustomobject][ordered]@{
                Stage = $Stage
                Pass = $pass
                Operation = 'Search'
                CompletedUtc = [DateTime]::UtcNow.ToString('o')
                SelectedCount = [int]$search.SelectedCount
                WindowsUpdateIdle = -not [bool]$idle.InstallerBusy
            })
            Assert-ImageServicingNotCancelled

            if ([int]$search.SelectedCount -gt 0) {
                Write-ImageServicingStatus -Phase 'WindowsUpdateDownload' -Message "$Stage Windows Update download pass $pass; cancellation will be checked before installation." -Details @{
                    SelectedTitles = @($search.SelectedTitles)
                    CompletedPasses = $windowsUpdatePasses.ToArray()
                    CompletedOperations = $windowsUpdateOperations.ToArray()
                }
                Assert-ImageServicingNotCancelled
                $download = Invoke-Command -Session $activeSession -ErrorAction Stop -ScriptBlock $windowsUpdateDownloadScript
                $idle = Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession
                $windowsUpdateOperations.Add([pscustomobject][ordered]@{
                    Stage = $Stage
                    Pass = $pass
                    Operation = 'Download'
                    CompletedUtc = [DateTime]::UtcNow.ToString('o')
                    ResultCode = [int]$download.ResultCode
                    WindowsUpdateIdle = -not [bool]$idle.InstallerBusy
                })
                Assert-ImageServicingNotCancelled

                Write-ImageServicingStatus -Phase 'WindowsUpdateInstall' -Message "$Stage Windows Update installation pass $pass." -Details @{
                    SelectedTitles = @($search.SelectedTitles)
                    CompletedPasses = $windowsUpdatePasses.ToArray()
                    CompletedOperations = $windowsUpdateOperations.ToArray()
                }
                Assert-ImageServicingNotCancelled
                $installation = Invoke-Command -Session $activeSession -ErrorAction Stop -ScriptBlock $windowsUpdateInstallScript
                $idle = Wait-GuestWindowsUpdateIdle -CurrentSession $activeSession
                $windowsUpdateOperations.Add([pscustomobject][ordered]@{
                    Stage = $Stage
                    Pass = $pass
                    Operation = 'Install'
                    CompletedUtc = [DateTime]::UtcNow.ToString('o')
                    ResultCode = [int]$installation.InstallationResultCode
                    WindowsUpdateIdle = -not [bool]$idle.InstallerBusy
                })
                Assert-ImageServicingNotCancelled
            }

            $result = [pscustomobject][ordered]@{
                SelectedCount = [int]$search.SelectedCount
                UpdateService = [string]$search.UpdateService
                ServiceFallbackReason = [string]$search.ServiceFallbackReason
                SearchAttempt = [int]$search.SearchAttempt
                SelectedTitles = @($search.SelectedTitles)
                Skipped = @($search.Skipped)
                DownloadResultCode = if ($download) { [int]$download.ResultCode } else { $null }
                InstallationResultCode = if ($installation) { [int]$installation.InstallationResultCode } else { $null }
                RebootRequired = if ($installation) { [bool]$installation.RebootRequired } else { [bool]$search.RebootRequired }
                PendingFileRenameCount = if ($installation) { [int]$installation.PendingFileRenameCount } else { [int]$search.PendingFileRenameCount }
                PendingRebootReasons = if ($installation) { @($installation.PendingRebootReasons) } else { @($search.PendingRebootReasons) }
                UpdateResults = if ($installation) { @($installation.UpdateResults) } else { @() }
                FailedCount = if ($installation) { [int]$installation.FailedCount } else { 0 }
                FailedUpdates = if ($installation) { @($installation.FailedUpdates) } else { @() }
            }
        }
        finally {
            Invoke-Command -Session $activeSession -ErrorAction SilentlyContinue -ScriptBlock $windowsUpdateClearStateScript | Out-Null
        }
        $record = [pscustomobject][ordered]@{
            Stage = $Stage
            Pass = $pass
            TimestampUtc = [DateTime]::UtcNow.ToString('o')
            SelectedCount = [int]$result.SelectedCount
            UpdateService = [string]$result.UpdateService
            ServiceFallbackReason = [string]$result.ServiceFallbackReason
            SearchAttempt = [int]$result.SearchAttempt
            SelectedTitles = @($result.SelectedTitles)
            Skipped = @($result.Skipped)
            DownloadResultCode = $result.DownloadResultCode
            InstallationResultCode = $result.InstallationResultCode
            RebootRequired = [bool]$result.RebootRequired
            PendingFileRenameCount = [int]$result.PendingFileRenameCount
            PendingRebootReasons = @($result.PendingRebootReasons)
            UpdateResults = @($result.UpdateResults)
            FailedCount = [int]$result.FailedCount
            FailedUpdates = @($result.FailedUpdates)
            WindowsUpdateIdle = -not [bool]$idle.InstallerBusy
            WindowsUpdateIdleCheckedUtc = [string]$idle.CheckedUtc
        }
        $windowsUpdatePasses.Add($record)
        Assert-ImageServicingNotCancelled
        if ([bool]$result.RebootRequired) {
            if ($GuestRestartMode -eq 'Manual') {
                Request-ManualGuestRestart -Stage $Stage -Reason ([pscustomobject][ordered]@{
                    UpdatePass = $pass
                    PendingRebootReasons = @($result.PendingRebootReasons)
                    PendingFileRenameCount = [int]$result.PendingFileRenameCount
                })
            }
            Assert-ImageServicingNotCancelled
            $activeSession = Restart-GuestAndReconnect -CurrentSession $activeSession -Credential $Credential
            continue
        }
        if ([int]$result.SelectedCount -eq 0) {
            return $activeSession
        }
    }
    throw "Windows Update did not converge during stage '$Stage' after $MaxWindowsUpdatePasses passes."
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Guest image servicing must run from an elevated administrator process.'
    }
    foreach ($requiredPath in @($CredentialPath, (Join-Path $PSScriptRoot 'Resolve-DotNetSdkInstaller.ps1'))) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Required servicing file is missing: $requiredPath" }
    }

    Import-Module Hyper-V -ErrorAction Stop
    Assert-ImageServicingNotCancelled
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $switch = Get-VMSwitch -Name $NetworkSwitchName -ErrorAction Stop
    $adapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop)
    if ($adapters.Count -lt 1) { throw "VM $VmName has no network adapter for temporary update connectivity." }
    $connectedAdapters = @($adapters | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
    $serviceAdapter = $adapters[0]
    if ($connectedAdapters.Count -gt 0) {
        if (-not $AllowApprovedConnectedStart -or $connectedAdapters.Count -ne 1 -or [string]$connectedAdapters[0].SwitchName -ne $NetworkSwitchName) {
            throw "VM $VmName must begin network-disconnected, or adoption must find exactly one adapter on the approved '$NetworkSwitchName' switch."
        }
        $serviceAdapter = $connectedAdapters[0]
        $networkConnected = $true
    }

    Write-ImageServicingStatus -Phase 'Starting' -Message 'Starting the isolated baseline and attaching the explicitly approved temporary update network.' -Details @{
        NetworkSwitchName = $switch.Name
        NetworkSwitchType = [string]$switch.SwitchType
        DotNetChannel = $DotNetChannel
        ExpectedDotNetSdkVersion = $ExpectedDotNetSdkVersion
        AdoptedApprovedConnection = [bool]($connectedAdapters.Count -eq 1)
    }
    if ($connectedAdapters.Count -eq 0) {
        Connect-VMNetworkAdapter -VMNetworkAdapter $serviceAdapter -SwitchName $NetworkSwitchName -ErrorAction Stop
        $networkConnected = $true
    }
    if ($vm.State -eq 'Off') { Start-VM -Name $VmName | Out-Null }
    elseif ($vm.State -ne 'Running') { throw "VM $VmName must be Off or Running before servicing; current state is $($vm.State)." }

    $credential = New-GuestCredential
    $session = Connect-PowerShellDirect -Credential $credential -TimeoutSeconds 300
    if ($GuestRestartMode -eq 'Manual') {
        $restartGuardState = Enable-GuestManualRestartGuard -CurrentSession $session
        $restartGuardActive = $true
    }
    $before = Get-GuestInventory -CurrentSession $session
    if ([string]$before.EditionId -ne 'Professional') { throw "Guest EditionId is '$($before.EditionId)', not 'Professional'." }

    $guestAdapterMac = (([string]$serviceAdapter.MacAddress) -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
    $guestNetworkOriginal = Get-GuestNetworkConfiguration -CurrentSession $session -AdapterMacAddress $guestAdapterMac
    $guestNetworkMode = 'OriginalConfiguration'

    Write-ImageServicingStatus -Phase 'WaitingForNetwork' -Message 'Testing the preserved guest network configuration on the approved temporary switch.' -Details @{
        Before = $before
        OriginalGuestNetwork = $guestNetworkOriginal
        NetworkSwitchName = $NetworkSwitchName
    }
    try {
        $networkReadiness = Wait-GuestUpdateConnectivity -CurrentSession $session -TimeoutSeconds 60
        $guestNetworkRestored = $true
    }
    catch {
        Write-ImageServicingStatus -Phase 'WaitingForNetwork' -Message 'The preserved guest configuration cannot reach Windows Update on this switch; trying bounded temporary DHCP.' -Details @{
            Before = $before
            OriginalGuestNetwork = $guestNetworkOriginal
            NetworkSwitchName = $NetworkSwitchName
            OriginalConfigurationError = $_.Exception.Message
        }
        Enable-GuestTemporaryDhcp -CurrentSession $session -Original $guestNetworkOriginal
        $guestNetworkMode = 'TemporaryDhcp'
        $guestNetworkRestored = $false
        $networkReadiness = Wait-GuestUpdateConnectivity -CurrentSession $session -TimeoutSeconds 300
    }

    $session = Invoke-WindowsUpdateToConvergence -CurrentSession $session -Credential $credential -Stage 'BeforeSdk'
    Assert-ImageServicingNotCancelled

    $installedVersions = @($before.DotNetSdks | ForEach-Object {
        if ([string]$_ -match '^(?<version>\d+\.\d+\.\d+)\s+\[') { $Matches.version }
    })
    $channels = New-Object Collections.Generic.List[string]
    $channels.Add($DotNetChannel)
    foreach ($installedVersion in $installedVersions) {
        $parts = $installedVersion.Split('.')
        if ($parts.Count -lt 2) { continue }
        $installedChannel = $parts[0] + '.' + $parts[1]
        if ($ExpectedInstalledChannelVersions.ContainsKey($installedChannel) -and $installedChannel -notin $channels) {
            $channels.Add($installedChannel)
        }
    }

    $resolvedSdks = New-Object Collections.Generic.List[object]
    foreach ($channel in $channels) {
        Assert-ImageServicingNotCancelled
        $expected = if ($channel -eq $DotNetChannel) { $ExpectedDotNetSdkVersion } else { [string]$ExpectedInstalledChannelVersions[$channel] }
        $resolved = & (Join-Path $PSScriptRoot 'Resolve-DotNetSdkInstaller.ps1') -Channel $channel -ExpectedVersion $expected -DestinationDirectory $downloadRoot -Download
        $resolvedSdks.Add($resolved)
    }
    Assert-ImageServicingNotCancelled

    $guestMaintenanceRoot = 'C:\CodexGuest\Maintenance'
    Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        param($Path)
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    } -ArgumentList $guestMaintenanceRoot

    foreach ($sdk in $resolvedSdks) {
        Assert-ImageServicingNotCancelled
        if ([string]$sdk.Version -in $installedVersions) {
            $sdkResults.Add([pscustomobject][ordered]@{
                Version = [string]$sdk.Version
                ExitCode = 0
                AlreadyInstalled = $true
                Sha512 = [string]$sdk.Sha512
                AuthenticodeSubject = [string]$sdk.AuthenticodeSubject
            })
            continue
        }
        Write-ImageServicingStatus -Phase 'InstallingSdk' -Message "Installing verified .NET SDK $($sdk.Version) in the baseline guest." -Details @{
            CompletedPasses = $windowsUpdatePasses.ToArray()
            ResolvedSdks = $resolvedSdks.ToArray()
        }
        $guestInstaller = Join-Path $guestMaintenanceRoot ([IO.Path]::GetFileName([string]$sdk.InstallerPath))
        Copy-Item -LiteralPath ([string]$sdk.InstallerPath) -Destination $guestInstaller -ToSession $session -Force
        Assert-ImageServicingNotCancelled
        $installResult = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            param($InstallerPath, $ExpectedSha512, $ExpectedVersion)
            $actualHash = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA512).Hash
            if ($actualHash -ne $ExpectedSha512) { throw "Guest copy of .NET SDK $ExpectedVersion failed SHA-512 verification." }
            $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
            if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
                throw "Guest copy of .NET SDK $ExpectedVersion failed Microsoft signature verification."
            }
            $process = Start-Process -FilePath $InstallerPath -ArgumentList @('/install','/quiet','/norestart') -Wait -PassThru
            [pscustomobject][ordered]@{
                Version = $ExpectedVersion
                ExitCode = [int]$process.ExitCode
                Sha512 = $actualHash
                AuthenticodeSubject = [string]$signature.SignerCertificate.Subject
            }
        } -ArgumentList $guestInstaller, ([string]$sdk.Sha512), ([string]$sdk.Version)
        if ([int]$installResult.ExitCode -notin @(0, 1641, 3010)) {
            throw ".NET SDK $($sdk.Version) installer exited with code $($installResult.ExitCode)."
        }
        $sdkResults.Add($installResult)
        Assert-ImageServicingNotCancelled
        Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { param($Path) Remove-Item -LiteralPath $Path -Force } -ArgumentList $guestInstaller
    }
    $sdkRequiresReboot = @($sdkResults | Where-Object { [int]$_.ExitCode -in @(1641, 3010) }).Count -gt 0
    $sdkRebootSignals = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $cbsRebootPending = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $windowsUpdateRebootRequired = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $pendingRename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        [pscustomobject][ordered]@{
            RebootRequired = [bool]($cbsRebootPending -or $windowsUpdateRebootRequired)
            PendingFileRenameCount = if ($pendingRename) { @($pendingRename.PendingFileRenameOperations).Count } else { 0 }
            CbsRebootPending = [bool]$cbsRebootPending
            WindowsUpdateRebootRequired = [bool]$windowsUpdateRebootRequired
        }
    }
    $sdkRequiresReboot = [bool]($sdkRequiresReboot -or [bool]$sdkRebootSignals.RebootRequired)
    if ($sdkRequiresReboot) {
        Assert-ImageServicingNotCancelled
        if ($GuestRestartMode -eq 'Manual') {
            Request-ManualGuestRestart -Stage 'AfterSdkInstall' -Reason ([pscustomobject][ordered]@{
                InstallerExitCodes = @($sdkResults | ForEach-Object { [int]$_.ExitCode })
                CbsRebootPending = [bool]$sdkRebootSignals.CbsRebootPending
                WindowsUpdateRebootRequired = [bool]$sdkRebootSignals.WindowsUpdateRebootRequired
                PendingFileRenameCount = [int]$sdkRebootSignals.PendingFileRenameCount
            })
        }
        Assert-ImageServicingNotCancelled
        $session = Restart-GuestAndReconnect -CurrentSession $session -Credential $credential
    }
    $session = Invoke-WindowsUpdateToConvergence -CurrentSession $session -Credential $credential -Stage 'AfterSdk'
    Assert-ImageServicingNotCancelled

    $expectedVersions = @($resolvedSdks | ForEach-Object { [string]$_.Version })
    $verification = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        param($ExpectedVersions, $MaintenanceRoot)
        $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        $dotnetPath = if ($dotnetCommand) { [string]$dotnetCommand.Source } else { Join-Path $env:ProgramFiles 'dotnet\dotnet.exe' }
        if (-not (Test-Path -LiteralPath $dotnetPath -PathType Leaf)) { throw "The installed .NET command was not found at '$dotnetPath'." }
        $sdkLines = @(& $dotnetPath --list-sdks 2>$null)
        $installed = @($sdkLines | ForEach-Object { if ($_ -match '^(?<version>\d+\.\d+\.\d+)\s+\[') { $Matches.version } })
        $missing = @($ExpectedVersions | Where-Object { $_ -notin $installed })
        if ($missing.Count -gt 0) { throw "Expected .NET SDKs are missing after installation: $($missing -join ', ')." }

        $smokeRoot = Join-Path $MaintenanceRoot 'SdkSmoke'
        New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null
        Push-Location $smokeRoot
        try {
            $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
            $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
            $env:DOTNET_NOLOGO = '1'
            function Invoke-DotNetSmokeCommand {
                param(
                    [Parameter(Mandatory = $true)] [string] $Description,
                    [Parameter(Mandatory = $true)] [string[]] $Arguments
                )
                $output = @(& $dotnetPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0) { throw "$Description failed with exit code $exitCode. Output: $($output -join "`n")" }
            }
            '<configuration><packageSources><clear /></packageSources></configuration>' | Set-Content -LiteralPath (Join-Path $smokeRoot 'NuGet.Config') -Encoding UTF8
            Invoke-DotNetSmokeCommand -Description 'dotnet new' -Arguments @('new','console','--force','--no-restore')
            Invoke-DotNetSmokeCommand -Description 'dotnet restore' -Arguments @('restore','--configfile',(Join-Path $smokeRoot 'NuGet.Config'))
            Invoke-DotNetSmokeCommand -Description 'dotnet build' -Arguments @('build','--no-restore')
        }
        finally { Pop-Location }

        $os = Get-CimInstance Win32_OperatingSystem
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $explicitPendingReboot =
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $pendingRename = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        $pendingFileRenameCount = if ($pendingRename) { @($pendingRename.PendingFileRenameOperations).Count } else { 0 }
        if ($explicitPendingReboot) { throw 'Windows Update or CBS still explicitly requires a reboot after update convergence.' }
        $manifest = [ordered]@{
            ServicedUtc = [DateTime]::UtcNow.ToString('o')
            OsCaption = [string]$os.Caption
            OsVersion = [string]$os.Version
            OsBuildNumber = [string]$os.BuildNumber
            DisplayVersion = [string]$currentVersion.DisplayVersion
            EditionId = [string]$currentVersion.EditionID
            DotNetSdks = $installed
            ExpectedDotNetSdks = @($ExpectedVersions)
            PendingReboot = $false
            PendingFileRenameCount = [int]$pendingFileRenameCount
            PendingFileRenameAutomaticRestartAuthorized = $false
            SdkSmokeBuildPassed = $true
        }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath 'C:\CodexGuest\image-manifest.json' -Encoding UTF8
        Remove-Item -LiteralPath $MaintenanceRoot -Recurse -Force
        [pscustomobject]$manifest
    } -ArgumentList (, $expectedVersions), $guestMaintenanceRoot

    if ($restartGuardActive) {
        Restore-GuestManualRestartGuard -CurrentSession $session -State $restartGuardState
        $restartGuardActive = $false
    }

    if ($guestNetworkMode -eq 'TemporaryDhcp') {
        $networkRestoration = Restore-GuestNetworkConfiguration -CurrentSession $session -Original $guestNetworkOriginal
        $guestNetworkRestored = $true
    }
    else {
        $networkRestoration = [pscustomobject][ordered]@{
            Mode = 'OriginalConfiguration'
            MatchesOriginal = $true
        }
    }

    Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop | Disconnect-VMNetworkAdapter -ErrorAction Stop
    $networkConnected = $false
    Assert-ImageServicingNotCancelled
    try { Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock { shutdown.exe /s /t 0 } } catch { }
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    $session = $null
    $shutdownDeadline = [DateTime]::UtcNow.AddMinutes(5)
    while ((Get-VM -Name $VmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) { Start-Sleep -Seconds 2 }
    if ((Get-VM -Name $VmName).State -ne 'Off') { throw "Guest $VmName did not shut down after servicing." }
    if (@(Get-VMNetworkAdapter -VMName $VmName | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) }).Count -gt 0) {
        throw "Guest $VmName remained connected to a virtual switch after servicing."
    }

    $success = $true
    Write-ImageServicingStatus -Phase 'ReadyToSeal' -Message 'Windows and supported .NET SDK channels are current; the guest is verified, shut down, and network-disconnected.' -Succeeded $true -Details @{
        Before = $before
        After = $verification
        ResolvedSdks = $resolvedSdks.ToArray()
        SdkInstallations = $sdkResults.ToArray()
        WindowsUpdatePasses = $windowsUpdatePasses.ToArray()
        WindowsUpdateOperations = $windowsUpdateOperations.ToArray()
        NetworkReadiness = $networkReadiness
        NetworkRestoration = $networkRestoration
        GuestNetworkMode = $guestNetworkMode
        NetworkSwitchName = $NetworkSwitchName
        NetworkDisconnected = $true
        VmState = [string](Get-VM -Name $VmName).State
    }
    [pscustomobject][ordered]@{
        Success = $true
        StatusPath = $StatusPath
        Before = $before
        After = $verification
        ResolvedSdks = $resolvedSdks.ToArray()
        WindowsUpdatePasses = $windowsUpdatePasses.ToArray()
        WindowsUpdateOperations = $windowsUpdateOperations.ToArray()
        NetworkReadiness = $networkReadiness
        NetworkRestoration = $networkRestoration
        GuestNetworkMode = $guestNetworkMode
    }
}
catch {
    if ($cancelled) {
        $success = $true
        Write-ImageServicingStatus -Phase 'Cancelled' -Message 'Guest servicing stopped cooperatively after the current synchronous operation and before any further reboot or mutation.' -Details @{
            Stop = $stopDetails
            WindowsUpdatePasses = $windowsUpdatePasses.ToArray()
            WindowsUpdateOperations = $windowsUpdateOperations.ToArray()
            SdkInstallations = $sdkResults.ToArray()
        }
        return [pscustomobject][ordered]@{
            Success = $false
            Cancelled = $true
            ResumeRequired = $false
            Phase = 'Cancelled'
            StatusPath = $StatusPath
            Details = $stopDetails
        }
    }
    if ($manualRestartPending) {
        $success = $true
        Write-ImageServicingStatus -Phase 'ManualRebootPending' -Message 'A guest restart is required; automatic restart is disabled for this maintenance run.' -Details @{
            Stop = $stopDetails
            WindowsUpdatePasses = $windowsUpdatePasses.ToArray()
            WindowsUpdateOperations = $windowsUpdateOperations.ToArray()
            SdkInstallations = $sdkResults.ToArray()
        }
        return [pscustomobject][ordered]@{
            Success = $false
            Cancelled = $false
            ResumeRequired = $true
            Phase = 'ManualRebootPending'
            StatusPath = $StatusPath
            Details = $stopDetails
        }
    }
    Write-ImageServicingStatus -Phase 'Failed' -Message $_.Exception.Message -Succeeded $false -Details @{
        ScriptStackTrace = $_.ScriptStackTrace
        WindowsUpdatePasses = $windowsUpdatePasses.ToArray()
        WindowsUpdateOperations = $windowsUpdateOperations.ToArray()
        SdkInstallations = $sdkResults.ToArray()
    }
    throw
}
finally {
    if (-not $guestNetworkRestored -and $guestNetworkOriginal -and $session) {
        try {
            [void](Restore-GuestNetworkConfiguration -CurrentSession $session -Original $guestNetworkOriginal)
            $guestNetworkRestored = $true
        }
        catch { $cleanupFailures.Add("Guest network configuration restoration failed: $($_.Exception.Message)") }
    }
    if ($restartGuardActive -and -not $manualRestartPending) {
        try {
            if (-not $session -and $credential) {
                $cleanupVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
                if ($cleanupVm -and $cleanupVm.State -eq 'Running') {
                    $session = Connect-PowerShellDirect -Credential $credential -TimeoutSeconds 120
                }
            }
            if (-not $session) { throw 'The guest is unavailable.' }
            Restore-GuestManualRestartGuard -CurrentSession $session -State $restartGuardState
            $restartGuardActive = $false
        }
        catch { $cleanupFailures.Add("Temporary manual-restart guard restoration failed: $($_.Exception.Message)") }
    }
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    if ($networkConnected) {
        Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue
    }
    $remainingConnections = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) })
    if ($remainingConnections.Count -gt 0) { $cleanupFailures.Add("Temporary guest networking remained connected: $($remainingConnections.SwitchName -join ', ').") }
    # A servicing error is not permission to simulate pulling the VM's power.
    # In particular, manual/adoption maintenance deliberately preserves the
    # current guest disk so the user can finish or inspect in-flight Windows
    # work.  The caller owns any later, explicit shutdown decision after the
    # guest has reached a known state.
    if ($cleanupFailures.Count -gt 0) { throw ('Guest servicing cleanup was incomplete: ' + ($cleanupFailures -join ' ')) }
}
