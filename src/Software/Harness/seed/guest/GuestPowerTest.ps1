# Loaded through PowerShell Direct: observation is independent of interactive sign-in.
if (-not ('CodexPowerSession' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexPowerSession {
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool WTSQuerySessionInformation(IntPtr server, uint id, int info, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);
    public static string ConsoleUser() {
        uint id = WTSGetActiveConsoleSessionId();
        if (id == 0xffffffff) throw new InvalidOperationException("Console session is transitioning.");
        IntPtr buffer; int bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, id, 5, out buffer, out bytes)) throw new InvalidOperationException("Console user observation failed.");
        try { return Marshal.PtrToStringUni(buffer) ?? ""; } finally { WTSFreeMemory(buffer); }
    }
    [StructLayout(LayoutKind.Sequential)] struct LSA_STRING { public ushort Length, MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_ATTRIBUTES { public uint Length; public IntPtr RootDirectory, ObjectName; public uint Attributes; public IntPtr SecurityDescriptor, SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    public static void RemoveAutoLogonSecret() {
        var attrs = new LSA_ATTRIBUTES(); attrs.Length = (uint)Marshal.SizeOf(attrs);
        IntPtr handle; uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x20, out handle);
        if (status != 0) throw new InvalidOperationException("Cannot open disposable guest LSA policy.");
        var key = new LSA_STRING(); key.Buffer = Marshal.StringToHGlobalUni("DefaultPassword"); key.Length = 30; key.MaximumLength = 32;
        try { status = LsaStorePrivateData(handle, ref key, IntPtr.Zero); if (status != 0 && status != 0xc0000034) throw new InvalidOperationException("Cannot clear disposable guest autologon secret."); }
        finally { Marshal.FreeHGlobal(key.Buffer); LsaClose(handle); }
    }
}
'@
}

function Get-GuestPrebootEvidence {
    $volume = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
    if (-not $volume) { throw 'OS volume encryption state is unavailable.' }
    $conversion = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus -ErrorAction Stop
    $protection = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
    $ids = Invoke-CimMethod -InputObject $volume -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]0 } -ErrorAction Stop
    if ($conversion.ReturnValue -ne 0 -or $protection.ReturnValue -ne 0 -or $ids.ReturnValue -ne 0) { throw 'OS volume encryption query failed.' }
    $types = @($ids.VolumeKeyProtectorID | Where-Object { $_ } | ForEach-Object {
        $type = Invoke-CimMethod -InputObject $volume -MethodName GetKeyProtectorType -Arguments @{ VolumeKeyProtectorID = [string]$_ } -ErrorAction Stop
        if ($type.ReturnValue -ne 0) { throw 'OS volume protector query failed.' }
        [int]$type.KeyProtectorType
    })
    $policy = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
    $banner = -not [string]::IsNullOrWhiteSpace(([string]$policy.legalnoticecaption).Trim([char]0)) -or -not [string]::IsNullOrWhiteSpace(([string]$policy.legalnoticetext).Trim([char]0))
    $smartCard = [int]$policy.scforceoption -ne 0
    $unencrypted = [int]$conversion.ConversionStatus -eq 0
    $tpmOnly = [int]$conversion.ConversionStatus -eq 1 -and [int]$protection.ProtectionStatus -eq 1 -and $types -contains 1 -and @($types | Where-Object { $_ -notin @(1, 3) }).Count -eq 0
    $clearKeyOnly = [int]$conversion.ConversionStatus -eq 1 -and [int]$protection.ProtectionStatus -eq 0 -and $ids.PSObject.Properties.Name -contains 'VolumeKeyProtectorID' -and $types.Count -eq 0
    [pscustomobject]@{ Unencrypted = $unencrypted; TpmOnly = $tpmOnly; ClearKeyOnly = $clearKeyOnly; ConversionStatus = [int]$conversion.ConversionStatus; ProtectionStatus = [int]$protection.ProtectionStatus; ProtectorTypes = $types; LoginBannerPresent = $banner; SmartCardRequired = $smartCard; UnattendedPrebootSupported = ($unencrypted -or $tpmOnly -or $clearKeyOnly) -and -not $banner -and -not $smartCard }
}

function Initialize-GuestPowerTest {
    param([string] $RequestId, [bool] $CleanSignIn, [bool] $CredentialFixture, [Management.Automation.PSCredential] $Credential, $Plan, [string] $PoolBaselineId)
    if ($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,100}$') { throw 'Invalid power-test request id.' }
    if (-not $PoolBaselineId) { throw 'Power tests require a bound managed-pool baseline.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $preboot = Get-GuestPrebootEvidence
    if ($CleanSignIn) {
        if (-not $preboot.UnattendedPrebootSupported) { throw "Guest does not positively support unattended preboot: conversion=$($preboot.ConversionStatus), protection=$($preboot.ProtectionStatus), protectors=[$($preboot.ProtectorTypes -join ',')], banner=$($preboot.LoginBannerPresent), smartCard=$($preboot.SmartCardRequired)." }
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $winlogon AutoAdminLogon '0' -ErrorAction Stop
        foreach ($name in @('DefaultPassword', 'AutoLogonCount', 'ForceAutoLogon')) { Remove-ItemProperty $winlogon $name -ErrorAction SilentlyContinue }
        foreach ($name in @('DefaultPassword', 'AutoLogonCount', 'ForceAutoLogon')) { if ((Get-Item $winlogon).GetValueNames() -contains $name) { throw 'Disposable autologon registry cleanup failed.' } }
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' DisableAutomaticRestartSignOn 1 -Type DWord -ErrorAction Stop
        [CodexPowerSession]::RemoveAutoLogonSecret()
    }
    $contextRoot = 'C:\ProgramData\CodexHarness\PowerTests\' + $RequestId
    New-Item -ItemType Directory -Path $contextRoot -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($identity.User, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $contextRoot -AclObject $acl -ErrorAction Stop
    $fixturePath = $null
    if ($CredentialFixture) {
        Add-Type -AssemblyName System.Security
        $bytes = [Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
        try { $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        $fixturePath = Join-Path $contextRoot 'credential.json'
        @{ FormatVersion = 1; UserName = $Credential.UserName; UserSid = $identity.User.Value; PoolBaselineId = $PoolBaselineId; Protection = 'DPAPI CurrentUser'; ProtectedPassword = [Convert]::ToBase64String($protected) } | ConvertTo-Json | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    }
    @{ RequestId = $RequestId; Plan = $Plan } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $contextRoot 'context.json') -Encoding UTF8
    [pscustomobject]@{ FormatVersion = 1; RequestId = $RequestId; UserName = $Credential.UserName; UserSid = $identity.User.Value; PoolBaselineId = $PoolBaselineId; SharedCredentialScope = 'ManagedPoolBaseline'; CredentialFile = $fixturePath; PersistentAutoLogonCleared = $CleanSignIn; Preboot = $preboot }
}

function Get-GuestPowerTestObservation {
    param([string] $ContextPath, [string] $Outbox)
    $context = Get-Content -Raw -LiteralPath $ContextPath -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $user = [CodexPowerSession]::ConsoleUser()
    $markers = @($context.Plan.Boots | ForEach-Object {
        $rule = $_.BeforeRestart
        $path = $rule.ResultFile.Replace('{OUTDIR}', $Outbox)
        $passed = $false; $written = $null
        try {
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            if ($file.Length -gt 1048576 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid marker.' }
            $value = Get-Content -Raw -LiteralPath $path -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if ($rule.JsonPointer -ne '') {
                foreach ($segment in $rule.JsonPointer.Substring(1).Split('/')) {
                    $key = $segment.Replace('~1', '/').Replace('~0', '~')
                    if ($value -is [Array]) { if ($key -notmatch '^(0|[1-9][0-9]*)$' -or [long]$key -ge $value.Count) { throw 'Missing pointer.' }; $value = $value[[int]$key] }
                    else { $property = @($value.PSObject.Properties | Where-Object { $_.Name -ceq $key }); if ($property.Count -ne 1) { throw 'Missing pointer.' }; $value = $property[0].Value }
                }
            }
            $expected = ('{"value":' + $rule.EqualsJson + '}') | ConvertFrom-Json
            $passed = (ConvertTo-Json -InputObject $value -Depth 20 -Compress) -ceq (ConvertTo-Json -InputObject $expected.value -Depth 20 -Compress)
            $written = $file.LastWriteTimeUtc.ToString('o')
        } catch { }
        [pscustomobject]@{ Passed = $passed; WrittenUtc = $written }
    })
    [pscustomobject]@{ ConsoleUser = $user; SignedIn = -not [string]::IsNullOrWhiteSpace($user); Markers = $markers }
}
