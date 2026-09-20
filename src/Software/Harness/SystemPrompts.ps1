function Get-SystemPromptPropertyNames {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-SystemPromptPropertyValue {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function ConvertTo-SystemPromptRelativePath {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $normalized = $Value.Replace('/', '\').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized) -or [IO.Path]::IsPathRooted($normalized)) {
        throw 'SystemPrompts ExecutableRelativePath must be a non-empty relative path.'
    }
    $segments = @($normalized.Split('\'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw 'SystemPrompts ExecutableRelativePath is not a safe payload-relative path.'
    }
    foreach ($segment in $segments) {
        if ($segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw 'SystemPrompts ExecutableRelativePath contains an invalid path segment.'
        }
    }
    $normalized
}

function Resolve-SystemPromptPolicyV1 {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [AllowNull()] $PayloadManifest
    )

    $operation = [string](Get-SystemPromptPropertyValue -Value $Request -Name 'Operation')
    $propertyLookup = Get-SystemPromptPropertyValue -Value $Request -Name 'SystemPrompts'
    $exactProperty = @(Get-SystemPromptPropertyNames -Value $Request | Where-Object { $_ -ceq 'SystemPrompts' }) | Select-Object -First 1
    if ($null -ne $propertyLookup -and -not $exactProperty) {
        throw 'The top-level system-prompt property name must use exact case: SystemPrompts.'
    }
    $supportedOperations = @('RunGuestJobSystemPromptsV1', 'RunGuestJobSetupSystemPromptsV1')
    if ($operation -notin $supportedOperations) {
        if ($null -ne $propertyLookup) { throw 'SystemPrompts requires the versioned system-prompt operation.' }
        return $null
    }
    if ($null -eq $propertyLookup) { throw "$operation requires SystemPrompts." }
    $guestSetup = Get-SystemPromptPropertyValue -Value $Request -Name 'GuestSetup'
    if ($operation -eq 'RunGuestJobSetupSystemPromptsV1' -and $null -eq $guestSetup) {
        throw 'RunGuestJobSetupSystemPromptsV1 requires GuestSetup.'
    }
    if ($operation -eq 'RunGuestJobSystemPromptsV1' -and $null -ne $guestSetup) {
        throw 'Guest setup and system prompts require RunGuestJobSetupSystemPromptsV1.'
    }
    if ($null -eq $PayloadManifest) { throw 'System-prompt acceptance requires a canonical application payload manifest.' }

    $allowed = @(
        'FormatVersion', 'AcceptUac', 'AcceptWindowsFirewall', 'PromptTimeoutSeconds',
        'ExecutableRelativePath', 'ExecutableSha256', 'FirewallProfiles'
    )
    $names = @(Get-SystemPromptPropertyNames -Value $propertyLookup)
    $unexpected = @($names | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count -gt 0) {
        throw ('SystemPrompts contains unsupported properties: ' + ($unexpected -join ', '))
    }
    foreach ($required in $allowed) {
        if ($names -cnotcontains $required) { throw "SystemPrompts is missing the exact $required property." }
    }

    $formatVersion = Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'FormatVersion'
    $timeout = Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'PromptTimeoutSeconds'
    $integralTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    if ($null -eq $formatVersion -or $formatVersion.GetType() -notin $integralTypes -or [int64]$formatVersion -ne 1) {
        throw 'SystemPrompts FormatVersion must be exact integer 1.'
    }
    if ($null -eq $timeout -or $timeout.GetType() -notin $integralTypes -or [int64]$timeout -lt 5 -or [int64]$timeout -gt 600) {
        throw 'SystemPrompts PromptTimeoutSeconds must be an integer between 5 and 600.'
    }

    $acceptUac = Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'AcceptUac'
    $acceptFirewall = Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'AcceptWindowsFirewall'
    if ($acceptUac -isnot [bool] -or $acceptFirewall -isnot [bool]) {
        throw 'SystemPrompts acceptance flags must be exact JSON Booleans.'
    }
    if (-not $acceptUac -and -not $acceptFirewall) {
        throw 'SystemPrompts must enable at least one supported prompt kind.'
    }

    if ((Get-SystemPromptPropertyValue -Value $Request -Name 'ExpectGuestPowerOff') -eq $true) {
        throw 'System-prompt acceptance cannot be combined with expected power-off.'
    }

    $relativePath = ConvertTo-SystemPromptRelativePath -Value ([string](Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'ExecutableRelativePath'))
    $expectedHash = [string](Get-SystemPromptPropertyValue -Value $propertyLookup -Name 'ExecutableSha256')
    if ($expectedHash -cnotmatch '^[A-F0-9]{64}$') {
        throw 'SystemPrompts ExecutableSha256 must be an uppercase exact SHA-256 hash.'
    }
    $jobExecutable = [string](Get-SystemPromptPropertyValue -Value (Get-SystemPromptPropertyValue -Value $Request -Name 'Job') -Name 'executable')
    if (-not [string]::Equals($jobExecutable, ('{PAYLOAD}\' + $relativePath), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SystemPrompts executable identity does not exactly match the guest job payload executable.'
    }
    $manifestMatch = @($PayloadManifest.Files | Where-Object {
        [string]::Equals(([string]$_.RelativePath).Replace('/', '\'), $relativePath, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($manifestMatch.Count -ne 1 -or -not [string]::Equals([string]$manifestMatch[0].Sha256, $expectedHash, [StringComparison]::Ordinal)) {
        throw 'SystemPrompts executable identity does not exactly match one payload-manifest file.'
    }

    $profilesValue = $null
    if ($propertyLookup -is [Collections.IDictionary]) {
        $profilesValue = $propertyLookup['FirewallProfiles']
    }
    else {
        $profilesValue = $propertyLookup.PSObject.Properties['FirewallProfiles'].Value
    }
    if ($null -eq $profilesValue -or $profilesValue -is [string] -or $profilesValue -isnot [Array]) {
        throw 'SystemPrompts FirewallProfiles must be a JSON array.'
    }
    $profiles = @($profilesValue)
    if (-not $acceptFirewall -and $profiles.Count -ne 0) {
        throw 'SystemPrompts FirewallProfiles must be empty when Windows Firewall acceptance is disabled.'
    }
    if ($acceptFirewall -and ($profiles.Count -lt 1 -or $profiles.Count -gt 2)) {
        throw 'SystemPrompts FirewallProfiles must contain one or two profiles when Windows Firewall acceptance is enabled.'
    }
    $profileSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($profile in $profiles) {
        if ($profile -isnot [string] -or [string]$profile -notin @('Private', 'Public') -or -not $profileSet.Add([string]$profile)) {
            throw 'SystemPrompts FirewallProfiles accepts unique exact values Private and Public only.'
        }
    }

    $sequence = @()
    if ($acceptUac) { $sequence += 'Uac' }
    if ($acceptFirewall) { $sequence += 'WindowsFirewall' }
    [pscustomobject][ordered]@{
        FormatVersion = 1
        AcceptUac = [bool]$acceptUac
        AcceptWindowsFirewall = [bool]$acceptFirewall
        PromptTimeoutSeconds = [int]$timeout
        ExecutableRelativePath = $relativePath
        ExecutableSha256 = $expectedHash
        FirewallProfiles = @($profiles)
        Sequence = @($sequence)
    }
}

function Get-SystemPromptGuestObservationV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $ExpectedExecutablePath
    )

    Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Outbox, $ExpectedPath)

        if (-not ('CodexSystemPromptToken' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexSystemPromptToken
{
    private const UInt32 PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const UInt32 TOKEN_QUERY = 0x0008;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(UInt32 access, bool inherit, Int32 processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, UInt32 access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, Int32 tokenClass, out Int32 information, Int32 length, out Int32 returned);

    public static bool IsElevated(Int32 processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                Int32 elevated;
                Int32 returned;
                if (!GetTokenInformation(token, 20, out elevated, sizeof(Int32), out returned)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return elevated != 0;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@
        }

        function Get-ObservedProcess {
            param($CimProcess)
            $startedUtc = $null
            if ($null -ne $CimProcess.CreationDate) {
                try { $startedUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime().ToString('o') } catch { $startedUtc = $null }
            }
            [pscustomobject][ordered]@{
                ProcessId = [int]$CimProcess.ProcessId
                Name = [string]$CimProcess.Name
                ExecutablePath = [string]$CimProcess.ExecutablePath
                CommandLine = [string]$CimProcess.CommandLine
                SessionId = if ($null -ne $CimProcess.SessionId) { [int]$CimProcess.SessionId } else { $null }
                StartedUtc = $startedUtc
            }
        }

        $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        $consent = @($all | Where-Object { [string]::Equals([string]$_.Name, 'consent.exe', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Get-ObservedProcess $_ })
        $pickerHostPath = Join-Path $env:WINDIR 'System32\PickerHost.exe'
        $firewall = @($all | Where-Object {
            ([string]::Equals([string]$_.Name, 'rundll32.exe', [StringComparison]::OrdinalIgnoreCase) -and [string]$_.CommandLine -match '(?i)FirewallUX\.dll') -or
            ([string]::Equals([string]$_.Name, 'SystemSettingsAdminFlows.exe', [StringComparison]::OrdinalIgnoreCase) -and [string]$_.CommandLine -match '(?i)firewall') -or
            ([string]::Equals([string]$_.Name, 'PickerHost.exe', [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$_.ExecutablePath, $pickerHostPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.CommandLine -match '(?i)(?:^|\s)FirewallNotificationDialogServer(?:\s|$)')
        } | ForEach-Object { Get-ObservedProcess $_ })

        $lease = $null
        $application = $null
        $leasePath = Join-Path $Outbox 'lease.json'
        if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
            try { $lease = Get-Content -Raw -LiteralPath $leasePath -Encoding UTF8 | ConvertFrom-Json } catch { $lease = $null }
        }
        if ($lease -and [int]$lease.ProcessId -gt 0) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [int]$lease.ProcessId) -ErrorAction SilentlyContinue
            if ($process) {
                $path = [string]$process.ExecutablePath
                $application = [pscustomobject][ordered]@{
                    ProcessId = [int]$process.ProcessId
                    ExecutablePath = $path
                    PathMatches = [string]::Equals($path, $ExpectedPath, [StringComparison]::OrdinalIgnoreCase)
                    Sha256 = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant() } else { $null }
                    Elevated = [CodexSystemPromptToken]::IsElevated([int]$process.ProcessId)
                    StartedUtc = [string]$lease.StartedUtc
                }
            }
        }
        [pscustomobject][ordered]@{
            ConsentProcesses = $consent
            FirewallProcesses = $firewall
            ApplicationLease = $lease
            Application = $application
        }
    } -ArgumentList $GuestOutbox, $ExpectedExecutablePath | Select-Object -Last 1
}

function Send-SystemPromptVirtualKey {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [uint32] $VirtualKey
    )

    $escapedName = $VmName.Replace("'", "''")
    $vmComputer = Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter "ElementName='$escapedName'" -ErrorAction Stop |
        Select-Object -First 1
    if (-not $vmComputer) { throw "Hyper-V WMI object not found for VM: $VmName" }
    $keyboard = Get-CimAssociatedInstance -InputObject $vmComputer -Association Msvm_SystemDevice -ResultClassName Msvm_Keyboard -ErrorAction Stop | Select-Object -First 1
    if (-not $keyboard) { throw "Virtual keyboard not found for VM: $VmName" }
    $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = $VirtualKey } -ErrorAction Stop
    if ([uint32]$result.ReturnValue -ne 0) { throw "Virtual keyboard TypeKey failed with code $($result.ReturnValue)." }
}

function Save-SystemPromptVmFramebuffer {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(160, 1920)] [int] $Width = 800,
        [ValidateRange(120, 1080)] [int] $Height = 600
    )

    $vmComputer = Get-WmiObject -Namespace 'root/virtualization/v2' -Class Msvm_ComputerSystem -ErrorAction Stop |
        Where-Object { [string]::Equals([string]$_.ElementName, $VmName, [StringComparison]::Ordinal) } |
        Select-Object -First 1
    if (-not $vmComputer) { throw "Hyper-V WMI object not found for VM: $VmName" }
    $settingsQuery = "ASSOCIATORS OF {$($vmComputer.__PATH)} WHERE AssocClass = Msvm_SettingsDefineState ResultClass = Msvm_VirtualSystemSettingData"
    $allSettings = @(Get-WmiObject -Namespace 'root/virtualization/v2' -Query $settingsQuery -ErrorAction Stop)
    $settings = $allSettings | Where-Object { [string]$_.VirtualSystemType -match 'Realized' } | Select-Object -First 1
    if (-not $settings) { $settings = $allSettings | Select-Object -First 1 }
    if (-not $settings) { throw "Realized virtual-system settings not found for VM: $VmName" }
    $service = Get-WmiObject -Namespace 'root/virtualization/v2' -Class Msvm_VirtualSystemManagementService -ErrorAction Stop | Select-Object -First 1
    $arguments = $service.PSBase.GetMethodParameters('GetVirtualSystemThumbnailImage')
    $arguments.TargetSystem = [string]$settings.__PATH
    $arguments.WidthPixels = [uint16]$Width
    $arguments.HeightPixels = [uint16]$Height
    $result = $service.PSBase.InvokeMethod('GetVirtualSystemThumbnailImage', $arguments, $null)
    if ([uint32]$result.ReturnValue -ne 0) { throw "VM framebuffer capture failed with code $($result.ReturnValue)." }
    $bytes = [byte[]]$result.ImageData
    $pixelBytes = $Width * $Height * 2
    if ($bytes.Length -lt $pixelBytes) { throw "VM framebuffer returned $($bytes.Length) bytes; expected at least $pixelBytes." }

    Add-Type -AssemblyName System.Drawing
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $bitmap = New-Object Drawing.Bitmap -ArgumentList $Width, $Height, ([Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        $rectangle = New-Object Drawing.Rectangle 0, 0, $Width, $Height
        $data = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        try { [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $pixelBytes) }
        finally { $bitmap.UnlockBits($data) }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    $Path
}

function Get-SystemPromptFirewallRulesV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $ExecutablePath
    )

    @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Path)
        $exactApplicationFilters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
            [string]::Equals([string]$_.Program, $Path, [StringComparison]::OrdinalIgnoreCase)
        })
        foreach ($exactApplicationFilter in $exactApplicationFilters) {
            $associatedRules = @(Get-NetFirewallRule -PolicyStore ActiveStore `
                -AssociatedNetFirewallApplicationFilter $exactApplicationFilter -ErrorAction Stop)
            foreach ($rule in $associatedRules) {
                $applications = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
                $matchingApplications = @($applications | Where-Object {
                    [string]::Equals([string]$_.Program, $Path, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matchingApplications.Count -gt 0) {
                    $ports = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
                    [pscustomobject][ordered]@{
                        Name = [string]$rule.Name
                        DisplayName = [string]$rule.DisplayName
                        Direction = [string]$rule.Direction
                        Action = [string]$rule.Action
                        Enabled = [string]$rule.Enabled
                        Profile = [string]$rule.Profile
                        Program = [string]$matchingApplications[0].Program
                        ApplicationFilterCount = $applications.Count
                        MatchingApplicationFilterCount = $matchingApplications.Count
                        Protocol = if ($ports.Count -eq 1) { [string]$ports[0].Protocol } else { $null }
                        PortFilterCount = $ports.Count
                        PolicyStoreSourceType = [string]$rule.PolicyStoreSourceType
                    }
                }
            }
        }
    } -ArgumentList $ExecutablePath)
}

function Resolve-SystemPromptFirewallRulePlanV1 {
    param(
        [object[]] $Rules,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $ExecutablePath,
        [Parameter(Mandatory = $true)] [string[]] $Profiles
    )

    $exactRules = @($Rules | Where-Object {
        [string]::Equals([string]$_.Program, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
    })
    $expectedRules = New-Object Collections.Generic.List[object]
    $expectedNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($profile in @($Profiles)) {
        $name = 'CodexHarness-' + $RequestId + '-' + $profile
        $null = $expectedNames.Add($name)
        $matches = @($exactRules | Where-Object { [string]$_.Name -ceq $name })
        if ($matches.Count -ne 1) {
            throw "Windows Firewall acceptance requires exactly one broker-owned $profile allow rule for the exact executable."
        }
        $rule = $matches[0]
        if ([string]$rule.DisplayName -cne ('Codex Harness ' + $RequestId + ' ' + $profile) -or
            [string]$rule.Direction -cne 'Inbound' -or [string]$rule.Action -cne 'Allow' -or
            [string]$rule.Enabled -cne 'True' -or [string]$rule.Profile -cne $profile -or
            [int]$rule.ApplicationFilterCount -ne 1 -or [int]$rule.MatchingApplicationFilterCount -ne 1 -or
            [int]$rule.PortFilterCount -ne 1 -or [string]$rule.Protocol -cne 'Any' -or
            [string]$rule.PolicyStoreSourceType -cne 'Local') {
            throw "The broker-owned $profile firewall rule no longer has its exact requested allow state."
        }
        $expectedRules.Add($rule)
    }

    $queryUserBlocks = New-Object Collections.Generic.List[object]
    foreach ($rule in @($exactRules | Where-Object { -not $expectedNames.Contains([string]$_.Name) })) {
        $match = [regex]::Match([string]$rule.Name, '^(?<Protocol>TCP|UDP) Query User\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}.+$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success -or [string]$rule.Direction -cne 'Inbound' -or
            [string]$rule.Action -cne 'Block' -or [string]$rule.Enabled -cne 'True' -or
            [int]$rule.ApplicationFilterCount -ne 1 -or [int]$rule.MatchingApplicationFilterCount -ne 1 -or
            [int]$rule.PortFilterCount -ne 1 -or
            -not [string]::Equals([string]$rule.Protocol, [string]$match.Groups['Protocol'].Value, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$rule.PolicyStoreSourceType -cne 'Local') {
            throw 'Windows Firewall acceptance found an unexpected or ambiguous rule for the exact executable.'
        }
        $queryUserBlocks.Add($rule)
    }

    [pscustomobject][ordered]@{
        ExpectedAllowRules = $expectedRules.ToArray()
        QueryUserBlockRules = $queryUserBlocks.ToArray()
    }
}

function Remove-SystemPromptQueryUserBlockRulesV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $ExecutablePath,
        [object[]] $Rules
    )

    if (@($Rules).Count -eq 0) { return @() }
    $rulesJson = ConvertTo-Json -Compress -Depth 8 -InputObject @($Rules)
    @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Path, $RulesJson)
        $requestedRules = @($RulesJson | ConvertFrom-Json)
        foreach ($requested in $requestedRules) {
            $name = [string]$requested.Name
            $nameMatch = [regex]::Match($name, '^(?<Protocol>TCP|UDP) Query User\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}.+$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
            if (-not $nameMatch.Success) { throw "Refusing to remove a non-Query-User firewall rule: $name" }

            $persistentRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue)
            if ($persistentRules.Count -ne 1) { throw "Query User firewall rule did not resolve uniquely in PersistentStore: $name" }
            $rule = $persistentRules[0]
            $applications = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
            $ports = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
            if ([string]$rule.Name -cne $name -or [string]$rule.Direction -cne 'Inbound' -or
                [string]$rule.Action -cne 'Block' -or [string]$rule.Enabled -cne 'True' -or
                [string]$rule.PolicyStoreSourceType -cne 'Local' -or
                $applications.Count -ne 1 -or -not [string]::Equals([string]$applications[0].Program, $Path, [StringComparison]::OrdinalIgnoreCase) -or
                $ports.Count -ne 1 -or
                -not [string]::Equals([string]$ports[0].Protocol, [string]$nameMatch.Groups['Protocol'].Value, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Query User firewall rule changed before bounded removal: $name"
            }

            $evidence = [pscustomobject][ordered]@{
                Name = [string]$rule.Name
                DisplayName = [string]$rule.DisplayName
                Direction = [string]$rule.Direction
                Action = [string]$rule.Action
                Enabled = [string]$rule.Enabled
                Profile = [string]$rule.Profile
                Program = [string]$applications[0].Program
                Protocol = [string]$ports[0].Protocol
                PolicyStoreSourceType = [string]$rule.PolicyStoreSourceType
            }
            $rule | Remove-NetFirewallRule -Confirm:$false -ErrorAction Stop
            $remainingRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object {
                [string]$_.Name -ceq $name
            })
            if ($remainingRules.Count -ne 0) {
                throw "Query User firewall rule remained after bounded removal: $name"
            }
            $evidence
        }
    } -ArgumentList $ExecutablePath, $rulesJson)
}

function Prepare-SystemPromptFirewallProfilesV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string[]] $Profiles
    )

    $profilesJson = ConvertTo-Json -Compress -InputObject @($Profiles)
    @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($RequestedProfilesJson)
        foreach ($profileName in @($RequestedProfilesJson | ConvertFrom-Json)) {
            Set-NetFirewallProfile -Name $profileName -Enabled True -DefaultInboundAction Block -NotifyOnListen True `
                -AllowInboundRules True -AllowLocalFirewallRules True -AllowUserApps True -AllowUserPorts True `
                -DisabledInterfaceAliases ([string[]]@()) -ErrorAction Stop
            $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -Name $profileName -ErrorAction Stop)
            $disabledAliases = @($profiles[0].DisabledInterfaceAliases | ForEach-Object { [string]$_ } | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'NotConfigured'
            })
            if ($profiles.Count -ne 1 -or [string]$profiles[0].Enabled -ne 'True' -or
                [string]$profiles[0].DefaultInboundAction -ne 'Block' -or [string]$profiles[0].NotifyOnListen -ne 'True' -or
                [string]$profiles[0].AllowInboundRules -ne 'True' -or [string]$profiles[0].AllowLocalFirewallRules -ne 'True' -or
                [string]$profiles[0].AllowUserApps -ne 'True' -or [string]$profiles[0].AllowUserPorts -ne 'True' -or
                $disabledAliases.Count -ne 0) {
                throw "The $profileName firewall profile could not be prepared for an application-listen notification."
            }
            [pscustomobject][ordered]@{
                Name = [string]$profiles[0].Name
                Enabled = [string]$profiles[0].Enabled
                DefaultInboundAction = [string]$profiles[0].DefaultInboundAction
                NotifyOnListen = [string]$profiles[0].NotifyOnListen
                AllowInboundRules = [string]$profiles[0].AllowInboundRules
                AllowLocalFirewallRules = [string]$profiles[0].AllowLocalFirewallRules
                AllowUserApps = [string]$profiles[0].AllowUserApps
                AllowUserPorts = [string]$profiles[0].AllowUserPorts
                DisabledInterfaceAliases = @($disabledAliases)
            }
        }
    } -ArgumentList $profilesJson)
}

function Grant-SystemPromptFirewallAccessV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $ExecutablePath,
        [Parameter(Mandatory = $true)] [string[]] $Profiles
    )

    $profilesJson = ConvertTo-Json -Compress -InputObject @($Profiles)
    @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($Id, $Path, $RequestedProfilesJson)
        $requestedProfiles = @($RequestedProfilesJson | ConvertFrom-Json)
        foreach ($profile in $requestedProfiles) {
            $name = 'CodexHarness-' + $Id + '-' + $profile
            if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { throw "Firewall rule already exists: $name" }
            New-NetFirewallRule -Name $name -DisplayName ('Codex Harness ' + $Id + ' ' + $profile) -Direction Inbound -Action Allow -Enabled True -Profile $profile -Program $Path -InterfaceType Any -EdgeTraversalPolicy Block -ErrorAction Stop | Out-Null
            $rule = Get-NetFirewallRule -Name $name -PolicyStore ActiveStore -ErrorAction Stop
            $application = $rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
            if ([string]$rule.Action -ne 'Allow' -or [string]$rule.Direction -ne 'Inbound' -or [string]$rule.Enabled -ne 'True' -or [string]$rule.Profile -ne $profile -or
                -not [string]::Equals([string]$application.Program, $Path, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Firewall rule verification failed: $name"
            }
            [pscustomobject][ordered]@{
                Name = $name
                Profile = $profile
                Direction = 'Inbound'
                Action = 'Allow'
                Program = [string]$application.Program
            }
        }
    } -ArgumentList $RequestId, $ExecutablePath, $profilesJson)
}

function New-SystemPromptRuntimeV1 {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $GuestOutbox,
        [Parameter(Mandatory = $true)] [string] $GuestExecutablePath,
        [Parameter(Mandatory = $true)] [string] $ResultRoot
    )

    $observation = Get-SystemPromptGuestObservationV1 -Session $Session -GuestOutbox $GuestOutbox -ExpectedExecutablePath $GuestExecutablePath
    if (@($observation.ConsentProcesses).Count -ne 0 -or @($observation.FirewallProcesses).Count -ne 0) {
        throw 'A system prompt was already active before the guest job was submitted.'
    }
    $firewallProfileReadiness = @()
    if ($Policy.AcceptWindowsFirewall) {
        $priorRules = @(Get-SystemPromptFirewallRulesV1 -Session $Session -ExecutablePath $GuestExecutablePath)
        if ($priorRules.Count -ne 0) { throw 'The exact test executable already has firewall rules; prompt acceptance would be ambiguous.' }
        $firewallProfileReadiness = @(Prepare-SystemPromptFirewallProfilesV1 -Session $Session -Profiles @($Policy.FirewallProfiles))
    }

    [pscustomobject][ordered]@{
        Policy = $Policy
        VmName = $VmName
        RequestId = $RequestId
        GuestOutbox = $GuestOutbox
        GuestExecutablePath = $GuestExecutablePath
        ResultRoot = $ResultRoot
        StartedUtc = [DateTime]::UtcNow
        PromptDeadlineUtc = [DateTime]::UtcNow.AddSeconds([int]$Policy.PromptTimeoutSeconds)
        CurrentIndex = 0
        FirewallProfileReadiness = @($firewallProfileReadiness)
        Acceptances = (New-Object Collections.Generic.List[object])
        Complete = $false
    }
}

function Invoke-SystemPromptServiceV1 {
    param(
        [Parameter(Mandatory = $true)] $Runtime,
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [scriptblock] $ActivityCheck
    )

    if ($Runtime.Complete) { return [pscustomobject]@{ Changed = $false; Complete = $true; Message = 'All requested system prompts were accepted.' } }
    if ([DateTime]::UtcNow -ge [DateTime]$Runtime.PromptDeadlineUtc) {
        throw [TimeoutException]::new("Timed out waiting for the requested $(@($Runtime.Policy.Sequence)[$Runtime.CurrentIndex]) system prompt.")
    }
    if ($ActivityCheck) { & $ActivityCheck }
    $kind = [string]@($Runtime.Policy.Sequence)[$Runtime.CurrentIndex]
    $observation = Get-SystemPromptGuestObservationV1 -Session $Session -GuestOutbox $Runtime.GuestOutbox -ExpectedExecutablePath $Runtime.GuestExecutablePath

    if ($kind -eq 'Uac') {
        if ($observation.ApplicationLease) { throw 'The exact application started before the requested startup UAC prompt was observed.' }
        $matches = @($observation.ConsentProcesses | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.StartedUtc) -and
            [DateTime]::Parse([string]$_.StartedUtc).ToUniversalTime() -ge [DateTime]$Runtime.StartedUtc
        })
        if ($matches.Count -eq 0) { return [pscustomobject]@{ Changed = $false; Complete = $false; Message = 'Waiting for the exact startup UAC prompt.' } }
        if ($matches.Count -ne 1) { throw 'The startup UAC prompt did not resolve to one new consent.exe process.' }
        $consentStartedUtc = [DateTime]::Parse([string]$matches[0].StartedUtc).ToUniversalTime()
        if ([DateTime]::UtcNow - $consentStartedUtc -lt [TimeSpan]::FromSeconds(2)) {
            return [pscustomobject]@{ Changed = $false; Complete = $false; Message = 'Waiting for the startup UAC prompt to finish rendering.' }
        }

        $acceptedUtc = [DateTime]::UtcNow
        $beforeName = 'system-prompt-uac-before.png'
        $afterName = 'system-prompt-uac-after.png'
        $null = Save-SystemPromptVmFramebuffer -VmName $Runtime.VmName -Path (Join-Path $Runtime.ResultRoot $beforeName)
        # Consent UI defaults to No. Left selects Yes without relying on localized text.
        Send-SystemPromptVirtualKey -VmName $Runtime.VmName -VirtualKey 0x25
        Start-Sleep -Milliseconds 250
        Send-SystemPromptVirtualKey -VmName $Runtime.VmName -VirtualKey 0x0D

        $verificationDeadline = [DateTime]::UtcNow.AddSeconds(15)
        $verified = $null
        do {
            if ($ActivityCheck) { & $ActivityCheck }
            Start-Sleep -Milliseconds 250
            $verified = Get-SystemPromptGuestObservationV1 -Session $Session -GuestOutbox $Runtime.GuestOutbox -ExpectedExecutablePath $Runtime.GuestExecutablePath
            if (@($verified.ConsentProcesses | Where-Object { [int]$_.ProcessId -eq [int]$matches[0].ProcessId }).Count -eq 0 -and $verified.Application) { break }
        } while ([DateTime]::UtcNow -lt $verificationDeadline -and [DateTime]::UtcNow -lt [DateTime]$Runtime.PromptDeadlineUtc)
        if (-not $verified.Application -or -not [bool]$verified.Application.PathMatches -or
            -not [string]::Equals([string]$verified.Application.Sha256, [string]$Runtime.Policy.ExecutableSha256, [StringComparison]::Ordinal) -or
            -not [bool]$verified.Application.Elevated) {
            throw 'UAC acceptance did not produce the exact hashed executable with an elevated token.'
        }
        $null = Save-SystemPromptVmFramebuffer -VmName $Runtime.VmName -Path (Join-Path $Runtime.ResultRoot $afterName)
        $Runtime.Acceptances.Add([pscustomobject][ordered]@{
            Kind = 'Uac'
            Success = $true
            ObservedProcessId = [int]$matches[0].ProcessId
            ApplicationProcessId = [int]$verified.Application.ProcessId
            ExpectedExecutablePath = [string]$Runtime.GuestExecutablePath
            ObservedExecutablePath = [string]$verified.Application.ExecutablePath
            ExpectedSha256 = [string]$Runtime.Policy.ExecutableSha256
            ObservedSha256 = [string]$verified.Application.Sha256
            Elevated = [bool]$verified.Application.Elevated
            AuthorizationMethod = 'HyperVVirtualKeyboard'
            AcceptedUtc = $acceptedUtc.ToString('o')
            BeforeScreenshot = $beforeName
            AfterScreenshot = $afterName
        })
    }
    elseif ($kind -eq 'WindowsFirewall') {
        if (-not $observation.Application) { return [pscustomobject]@{ Changed = $false; Complete = $false; Message = 'Waiting for the application before its Windows Firewall prompt.' } }
        if (-not [bool]$observation.Application.PathMatches -or
            -not [string]::Equals([string]$observation.Application.Sha256, [string]$Runtime.Policy.ExecutableSha256, [StringComparison]::Ordinal)) {
            throw 'The running application does not match the executable identity bound to Windows Firewall acceptance.'
        }
        $matches = @($observation.FirewallProcesses | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.StartedUtc) -and
            [DateTime]::Parse([string]$_.StartedUtc).ToUniversalTime() -ge [DateTime]$Runtime.StartedUtc
        })
        if ($matches.Count -eq 0) { return [pscustomobject]@{ Changed = $false; Complete = $false; Message = 'Waiting for the exact Windows Firewall prompt host.' } }
        if ($matches.Count -ne 1) { throw 'The Windows Firewall prompt did not resolve to one new firewall UX process.' }
        $firewallStartedUtc = [DateTime]::Parse([string]$matches[0].StartedUtc).ToUniversalTime()
        if ([DateTime]::UtcNow - $firewallStartedUtc -lt [TimeSpan]::FromSeconds(2)) {
            return [pscustomobject]@{ Changed = $false; Complete = $false; Message = 'Waiting for the Windows Firewall prompt to finish rendering.' }
        }

        $acceptedUtc = [DateTime]::UtcNow
        $beforeName = 'system-prompt-firewall-before.png'
        $afterName = 'system-prompt-firewall-after.png'
        $null = Save-SystemPromptVmFramebuffer -VmName $Runtime.VmName -Path (Join-Path $Runtime.ResultRoot $beforeName)
        $rules = @(Grant-SystemPromptFirewallAccessV1 -Session $Session -RequestId $Runtime.RequestId -ExecutablePath $Runtime.GuestExecutablePath -Profiles @($Runtime.Policy.FirewallProfiles))
        if ($rules.Count -ne @($Runtime.Policy.FirewallProfiles).Count) { throw 'Windows Firewall acceptance did not create every exact requested rule.' }
        # The exact authorization is already committed; Escape closes the stale notification.
        Send-SystemPromptVirtualKey -VmName $Runtime.VmName -VirtualKey 0x1B
        $verificationDeadline = [DateTime]::UtcNow.AddSeconds(10)
        $verified = $null
        do {
            if ($ActivityCheck) { & $ActivityCheck }
            Start-Sleep -Milliseconds 250
            $verified = Get-SystemPromptGuestObservationV1 -Session $Session -GuestOutbox $Runtime.GuestOutbox -ExpectedExecutablePath $Runtime.GuestExecutablePath
            if (@($verified.FirewallProcesses | Where-Object { [int]$_.ProcessId -eq [int]$matches[0].ProcessId }).Count -eq 0) { break }
        } while ([DateTime]::UtcNow -lt $verificationDeadline -and [DateTime]::UtcNow -lt [DateTime]$Runtime.PromptDeadlineUtc)
        if (@($verified.FirewallProcesses | Where-Object { [int]$_.ProcessId -eq [int]$matches[0].ProcessId }).Count -ne 0) {
            throw 'The Windows Firewall prompt remained active after exact authorization and dismissal.'
        }

        # Windows creates exact-application Query User block rules when its stale
        # notification is cancelled. Reconcile only those new, locally generated
        # rules and require a stable exact allow-only state before claiming success.
        $removedQueryUserBlocks = New-Object Collections.Generic.List[object]
        $removedNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $cleanSinceUtc = $null
        $reconciliationDeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
        if ($reconciliationDeadlineUtc -gt [DateTime]$Runtime.PromptDeadlineUtc) {
            $reconciliationDeadlineUtc = [DateTime]$Runtime.PromptDeadlineUtc
        }
        $finalFirewallPlan = $null
        do {
            if ($ActivityCheck) { & $ActivityCheck }
            $currentRules = @(Get-SystemPromptFirewallRulesV1 -Session $Session -ExecutablePath $Runtime.GuestExecutablePath)
            $currentPlan = Resolve-SystemPromptFirewallRulePlanV1 -Rules $currentRules -RequestId $Runtime.RequestId `
                -ExecutablePath $Runtime.GuestExecutablePath -Profiles @($Runtime.Policy.FirewallProfiles)
            $newBlocks = @($currentPlan.QueryUserBlockRules | Where-Object { -not $removedNames.Contains([string]$_.Name) })
            if ($newBlocks.Count -gt 0) {
                $removed = @(Remove-SystemPromptQueryUserBlockRulesV1 -Session $Session -ExecutablePath $Runtime.GuestExecutablePath -Rules $newBlocks)
                if ($removed.Count -ne $newBlocks.Count) {
                    throw 'Windows Firewall acceptance did not remove every exact Query User block rule.'
                }
                foreach ($rule in $removed) {
                    $null = $removedNames.Add([string]$rule.Name)
                    $removedQueryUserBlocks.Add($rule)
                }
                $cleanSinceUtc = $null
            }
            elseif (@($currentPlan.QueryUserBlockRules).Count -gt 0) {
                $cleanSinceUtc = $null
            }
            elseif ($null -eq $cleanSinceUtc) {
                $cleanSinceUtc = [DateTime]::UtcNow
                $finalFirewallPlan = $currentPlan
            }
            elseif ([DateTime]::UtcNow - $cleanSinceUtc -ge [TimeSpan]::FromSeconds(2)) {
                $finalFirewallPlan = $currentPlan
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $reconciliationDeadlineUtc)
        if ($null -eq $cleanSinceUtc -or [DateTime]::UtcNow - $cleanSinceUtc -lt [TimeSpan]::FromSeconds(2) -or
            $null -eq $finalFirewallPlan -or @($finalFirewallPlan.QueryUserBlockRules).Count -ne 0) {
            throw 'Windows Firewall acceptance did not reach a stable exact allow state without inbound block rules.'
        }
        $null = Save-SystemPromptVmFramebuffer -VmName $Runtime.VmName -Path (Join-Path $Runtime.ResultRoot $afterName)
        $Runtime.Acceptances.Add([pscustomobject][ordered]@{
            Kind = 'WindowsFirewall'
            Success = $true
            ObservedProcessId = [int]$matches[0].ProcessId
            ApplicationProcessId = [int]$observation.Application.ProcessId
            ExpectedExecutablePath = [string]$Runtime.GuestExecutablePath
            ObservedExecutablePath = [string]$observation.Application.ExecutablePath
            ExpectedSha256 = [string]$Runtime.Policy.ExecutableSha256
            ObservedSha256 = [string]$observation.Application.Sha256
            FirewallProfiles = @($Runtime.Policy.FirewallProfiles)
            FirewallRules = @($finalFirewallPlan.ExpectedAllowRules)
            RemovedQueryUserBlockRules = $removedQueryUserBlocks.ToArray()
            ExactApplicationInboundBlockRuleCount = 0
            AuthorizationMethod = 'ExactInboundFirewallRulesWithQueryUserReconciliation'
            AcceptedUtc = $acceptedUtc.ToString('o')
            BeforeScreenshot = $beforeName
            AfterScreenshot = $afterName
        })
    }
    else { throw "Unsupported system-prompt runtime kind: $kind" }

    $Runtime.CurrentIndex++
    $Runtime.Complete = $Runtime.CurrentIndex -ge @($Runtime.Policy.Sequence).Count
    if (-not $Runtime.Complete) { $Runtime.PromptDeadlineUtc = [DateTime]::UtcNow.AddSeconds([int]$Runtime.Policy.PromptTimeoutSeconds) }
    [pscustomobject]@{
        Changed = $true
        Complete = [bool]$Runtime.Complete
        Message = if ($Runtime.Complete) { 'All requested system prompts were accepted and verified.' } else { "Accepted and verified $kind; waiting for the next requested system prompt." }
    }
}

function Get-SystemPromptEvidenceV1 {
    param([AllowNull()] $Runtime)

    if ($null -eq $Runtime) { return $null }
    [pscustomobject][ordered]@{
        FormatVersion = 1
        ContractSatisfied = [bool]$Runtime.Complete -and $Runtime.Acceptances.Count -eq @($Runtime.Policy.Sequence).Count
        ExecutableRelativePath = [string]$Runtime.Policy.ExecutableRelativePath
        ExecutableSha256 = [string]$Runtime.Policy.ExecutableSha256
        RequestedKinds = @($Runtime.Policy.Sequence)
        FirewallProfiles = @($Runtime.Policy.FirewallProfiles)
        FirewallProfileReadiness = @($Runtime.FirewallProfileReadiness)
        PromptTimeoutSeconds = [int]$Runtime.Policy.PromptTimeoutSeconds
        Acceptances = $Runtime.Acceptances.ToArray()
    }
}
