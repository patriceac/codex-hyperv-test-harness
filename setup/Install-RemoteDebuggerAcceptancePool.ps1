#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')] [switch] $PlanOnly,
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(Mandatory = $true, ParameterSetName = 'Library')] [switch] $LibraryOnly,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string] $PublisherCertificatePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string] $ReleaseExecutablePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string] $OlderExecutablePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string] $NewerExecutablePath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string] $SameVersionExecutablePath,
    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(ParameterSetName = 'Apply')]
    [string] $InstallRoot = 'D:\Disk\VMs\RemoteDebugger-Acceptance',
    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(ParameterSetName = 'Apply')]
    [string] $RecoveryBundleRoot = 'D:\Disk\VMs\Codex-Harness\Recovery\Current',
    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(ParameterSetName = 'Apply')]
    [string] $SourceRoot,
    [Parameter(ParameterSetName = 'Plan')]
    [Parameter(ParameterSetName = 'Apply')]
    [string] $ClientSid,
    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string] $ExpectedPlanSha256
)

$ErrorActionPreference = 'Stop'
$script:DedicatedInstallRoot = 'D:\Disk\VMs\RemoteDebugger-Acceptance'
$script:DedicatedRecoveryRoot = 'D:\Disk\VMs\Codex-Harness\Recovery\Current'
$script:ExpectedRecoveryManifestSha256 = '061F9DE56C36C0BC02806490655174C8E24BB32071043CFCA82E053028A10B7A'
$script:ExpectedPublisherThumbprint = '772169E21DEBE5D4E39D74BE04F168038C539552844CA06F86766A5FAEAD36EC'
$script:ExpectedFixtureHashes = [ordered]@{
    Release = '9019DB6BC9AB9F14CD064BA63A1F97C0E6DEC67CAB0134C0116D4B68B0CF4C9A'
    Older = '15C447035EB1B5EAFBBF016940FD255B45EB89020FE423CE015A8A5F66EB475E'
    Newer = '950414DE1CC490DD4BBE5E3845D8B8309E488196134352D275F468EE92612539'
    SameVersionDifferentHash = 'C29FBF1D48D4D0DAB6BB8B3EE4247C937655DDA07F581C5F25FDB4FD47B454EC'
}

function Get-RemoteDebuggerAcceptanceSha256 {
    param([Parameter(Mandatory = $true)] [string] $Path)

    Set-StrictMode -Version Latest
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-RemoteDebuggerAcceptanceTextSha256 {
    param([Parameter(Mandatory = $true)] [string] $Text)

    Set-StrictMode -Version Latest
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-RemoteDebuggerAcceptancePlanSha256 {
    param([Parameter(Mandatory = $true)] [Collections.IDictionary] $Plan)

    Set-StrictMode -Version Latest
    Get-RemoteDebuggerAcceptanceTextSha256 -Text ($Plan | ConvertTo-Json -Compress -Depth 30)
}

function Assert-RemoteDebuggerAcceptanceExactPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Actual,
        [Parameter(Mandatory = $true)] [string] $Expected,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    Set-StrictMode -Version Latest
    $actualFull = [IO.Path]::GetFullPath($Actual).TrimEnd('\')
    $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
    if (-not [string]::Equals($actualFull, $expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must be the reviewed dedicated path '$expectedFull'; received '$actualFull'."
    }
    $actualFull
}

function Assert-RemoteDebuggerAcceptanceNoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Boundary
    )

    Set-StrictMode -Version Latest
    $current = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $stop = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Dedicated acceptance setup rejects reparse point '$current'."
            }
        }
        if ([string]::Equals($current, $stop, [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent.TrimEnd('\'), $current, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Path '$Path' is outside its expected boundary '$Boundary'."
        }
        $current = $parent.TrimEnd('\')
    }
}

function Get-RemoteDebuggerAcceptanceTreeFingerprint {
    param([Parameter(Mandatory = $true)] [object[]] $Trees)

    Set-StrictMode -Version Latest
    $rows = New-Object Collections.Generic.List[string]
    $fileCount = 0
    $totalBytes = [long]0
    foreach ($tree in $Trees) {
        $name = [string]$tree.Name
        $root = [IO.Path]::GetFullPath([string]$tree.Path).TrimEnd('\')
        if ($name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Source tree '$name' is invalid or missing: $root"
        }
        Assert-RemoteDebuggerAcceptanceNoReparseAncestors -Path $root -Boundary ([IO.Path]::GetPathRoot($root))
        $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
        $reparse = @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Select-Object -First 1)
        if ($reparse.Count -gt 0) { throw "Source tree '$name' contains reparse point '$($reparse[0].FullName)'." }
        foreach ($file in @($items | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
            if ($relative -match '(^|/)private(/|$)') {
                throw "Source tree '$name' contains a private directory; dedicated setup copies credentials only from the reviewed recovery bundle."
            }
            $hash = Get-RemoteDebuggerAcceptanceSha256 -Path $file.FullName
            $rows.Add($name + '/' + $relative + '|' + [string][long]$file.Length + '|' + $hash)
            $fileCount++
            $totalBytes += [long]$file.Length
        }
    }
    [pscustomobject][ordered]@{
        FileCount = $fileCount
        TotalBytes = $totalBytes
        Sha256 = Get-RemoteDebuggerAcceptanceTextSha256 -Text (($rows.ToArray() -join "`n") + "`n")
    }
}

function Get-RemoteDebuggerAcceptanceManifestEntry {
    param(
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] [string] $RelativePath
    )

    Set-StrictMode -Version Latest
    $entries = @($Manifest.Files | Where-Object { [string]::Equals(([string]$_.RelativePath).Replace('\', '/'), $RelativePath.Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase) })
    if ($entries.Count -ne 1) { throw "Recovery manifest must contain one '$RelativePath' entry; found $($entries.Count)." }
    if ([long]$entries[0].Length -lt 0 -or [string]$entries[0].Sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') {
        throw "Recovery manifest entry '$RelativePath' is invalid."
    }
    $entries[0]
}

function Resolve-RemoteDebuggerAcceptanceRecovery {
    param([Parameter(Mandatory = $true)] [string] $BundleRoot)

    Set-StrictMode -Version Latest
    $root = Assert-RemoteDebuggerAcceptanceExactPath -Actual $BundleRoot -Expected $script:DedicatedRecoveryRoot -Name 'RecoveryBundleRoot'
    Assert-RemoteDebuggerAcceptanceNoReparseAncestors -Path $root -Boundary ([IO.Path]::GetPathRoot($root))
    $manifestPath = Join-Path $root 'manifest.json'
    $checksumsPath = Join-Path $root 'checksums.sha256'
    foreach ($path in @($manifestPath, $checksumsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Recovery input is missing: $path" }
    }
    $manifestSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $manifestPath
    if ($manifestSha256 -cne $script:ExpectedRecoveryManifestSha256) {
        throw "Recovery Current manifest drifted: expected $($script:ExpectedRecoveryManifestSha256), found $manifestSha256."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([int]$manifest.FormatVersion -ne 1 -or
        [string]$manifest.BundleId -cne '20260905T171216796Z-165715b8' -or
        [string]$manifest.BaselineVmId -cne 'f5aa5888-7f5a-4348-ae5e-cd886fa47331' -or
        [string]$manifest.BaselineCheckpointId -cne '2e96f5a7-e754-4a52-bca2-57ad1e98c08f' -or
        [string]$manifest.BaselineVmName -cne 'Codex-Harness-Baseline' -or
        [string]$manifest.BaselineCheckpointName -cne 'Clean-Windows11-Harness') {
        throw 'Recovery Current identity no longer matches the reviewed source baseline.'
    }
    $checksumsSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $checksumsPath
    if (-not [string]::Equals($checksumsSha256, [string]$manifest.ChecksumsSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Recovery checksums file no longer matches its manifest fingerprint.'
    }
    $vmConfigEntry = Get-RemoteDebuggerAcceptanceManifestEntry -Manifest $manifest -RelativePath ([string]$manifest.ExportedVmConfiguration)
    $bundleConfigEntry = Get-RemoteDebuggerAcceptanceManifestEntry -Manifest $manifest -RelativePath ([string]$manifest.ConfigRelativePath)
    $credentialEntry = Get-RemoteDebuggerAcceptanceManifestEntry -Manifest $manifest -RelativePath 'Software/Harness/private/guest-credential.json'
    $vmConfigPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$manifest.ExportedVmConfiguration).Replace('/', '\')))
    $bundleConfigPath = [IO.Path]::GetFullPath((Join-Path $root ([string]$manifest.ConfigRelativePath).Replace('/', '\')))
    $rootPrefix = $root.TrimEnd('\') + '\'
    foreach ($path in @($vmConfigPath, $bundleConfigPath)) {
        if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Recovery manifest resolves an invalid or missing source file: $path"
        }
    }
    foreach ($pair in @(@($vmConfigPath, $vmConfigEntry), @($bundleConfigPath, $bundleConfigEntry))) {
        $item = Get-Item -LiteralPath $pair[0] -Force
        $hash = Get-RemoteDebuggerAcceptanceSha256 -Path $pair[0]
        if ([long]$item.Length -ne [long]$pair[1].Length -or -not [string]::Equals($hash, [string]$pair[1].Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recovery source fingerprint mismatch: $($pair[0])"
        }
    }
    [pscustomobject][ordered]@{
        Root = $root
        ManifestPath = $manifestPath
        ManifestSha256 = $manifestSha256
        BundleId = [string]$manifest.BundleId
        FileCount = [int]$manifest.FileCount
        TotalBytes = [long]$manifest.TotalBytes
        ChecksumsPath = $checksumsPath
        ChecksumsSha256 = $checksumsSha256
        BaselineVmName = [string]$manifest.BaselineVmName
        BaselineVmId = [string]$manifest.BaselineVmId
        BaselineCheckpointName = [string]$manifest.BaselineCheckpointName
        BaselineCheckpointId = [string]$manifest.BaselineCheckpointId
        ExportedVmConfigurationPath = $vmConfigPath
        ExportedVmConfigurationLength = [long]$vmConfigEntry.Length
        ExportedVmConfigurationSha256 = ([string]$vmConfigEntry.Sha256).ToUpperInvariant()
        SourceConfigurationPath = $bundleConfigPath
        SourceConfigurationSha256 = ([string]$bundleConfigEntry.Sha256).ToUpperInvariant()
        CredentialRelativePath = 'Software/Harness/private/guest-credential.json'
        CredentialLength = [long]$credentialEntry.Length
        CredentialManifestSha256 = ([string]$credentialEntry.Sha256).ToUpperInvariant()
        CredentialHandling = 'Opaque setup-only copy after full recovery integrity verification; content is never emitted.'
        FullContentVerificationAtApply = $true
    }
}

function Initialize-RemoteDebuggerAcceptanceAuthenticodeVerifier {
    param([Parameter(Mandatory = $true)] [string] $ModulePath)

    Set-StrictMode -Version Latest
    if ('CodexRemoteDebuggerAuthenticode' -as [type]) { return }
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Dedicated acceptance signature verification must run under Windows PowerShell 5.1 (Desktop edition).'
    }
    $source = Get-Content -LiteralPath $ModulePath -Raw -Encoding UTF8
    $pattern = "Add-Type -ReferencedAssemblies @\('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Security.dll'\) -TypeDefinition @'\r?\n(?<Code>[\s\S]*?)\r?\n'@"
    $match = [regex]::Match($source, $pattern)
    if (-not $match.Success) { throw 'Remote Debugger provisioning Authenticode verifier source is missing.' }
    Add-Type -ErrorAction Stop -ReferencedAssemblies @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Security.dll') -TypeDefinition $match.Groups['Code'].Value
}

function Resolve-RemoteDebuggerAcceptancePublisher {
    param([Parameter(Mandatory = $true)] [string] $Path)

    Set-StrictMode -Version Latest
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Publisher certificate is missing: $fullPath" }
    Assert-RemoteDebuggerAcceptanceNoReparseAncestors -Path $fullPath -Boundary ([IO.Path]::GetPathRoot($fullPath))
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($fullPath)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $thumbprint = ([BitConverter]::ToString($sha.ComputeHash($certificate.RawData))).Replace('-', '') }
        finally { $sha.Dispose() }
        if ($thumbprint -cne $script:ExpectedPublisherThumbprint) {
            throw "Publisher certificate pin drifted: expected $($script:ExpectedPublisherThumbprint), found $thumbprint."
        }
        $codeSigning = $false
        $certificateAuthority = $false
        foreach ($extension in $certificate.Extensions) {
            if ($extension -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
                foreach ($oid in $extension.EnhancedKeyUsages) {
                    if ([string]$oid.Value -ceq '1.3.6.1.5.5.7.3.3') { $codeSigning = $true }
                }
            }
            if ($extension -is [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] -and $extension.CertificateAuthority) {
                $certificateAuthority = $true
            }
        }
        if (-not $codeSigning -or $certificateAuthority) { throw 'Publisher certificate must be a non-CA code-signing leaf.' }
        $now = [DateTime]::UtcNow
        if ($now -lt $certificate.NotBefore.ToUniversalTime() -or $now -gt $certificate.NotAfter.ToUniversalTime()) {
            throw 'Publisher certificate is outside its validity period.'
        }
        [pscustomobject][ordered]@{
            Path = $fullPath
            FileSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $fullPath
            CertificateSha256 = $thumbprint
            Subject = [string]$certificate.Subject
            NotBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString('o')
            NotAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
            CodeSigningEku = $true
            CertificateAuthority = $false
            TrustModel = 'Pinned self-signed non-CA code-signing leaf enrolled by the reviewed setup; no private key is copied.'
        }
    }
    finally { $certificate.Dispose() }
}

function Resolve-RemoteDebuggerAcceptanceFixture {
    param(
        [Parameter(Mandatory = $true)] [string] $Variant,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ExpectedSha256,
        [Parameter(Mandatory = $true)] [string] $PublisherThumbprint
    )

    Set-StrictMode -Version Latest
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
        -not [string]::Equals([IO.Path]::GetFileName($fullPath), 'RemoteDebugger.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Variant fixture must be an existing RemoteDebugger.exe: $fullPath"
    }
    Assert-RemoteDebuggerAcceptanceNoReparseAncestors -Path $fullPath -Boundary ([IO.Path]::GetPathRoot($fullPath))
    $item = Get-Item -LiteralPath $fullPath -Force
    if ([long]$item.Length -lt 1MB -or [long]$item.Length -gt 512MB) { throw "$Variant fixture size is outside the reviewed bounds." }
    $actualSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $fullPath
    if ($actualSha256 -cne $ExpectedSha256) { throw "$Variant fixture hash drifted: expected $ExpectedSha256, found $actualSha256." }
    $verifiedPublisher = [CodexRemoteDebuggerAuthenticode]::Verify($fullPath, $PublisherThumbprint)
    if (-not [string]::Equals($verifiedPublisher, $PublisherThumbprint, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Variant fixture signature returned a different publisher identity."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $fullPath -ErrorAction Stop
    [pscustomobject][ordered]@{
        Variant = $Variant
        Path = $fullPath
        Length = [long]$item.Length
        Sha256 = $actualSha256
        PublisherThumbprint = $verifiedPublisher.ToUpperInvariant()
        CmsSignatureValid = $true
        PeImageDigestMatches = $true
        CodeSigningLeafValid = $true
        WinVerifyTrustDisposition = [string]$signature.Status
    }
}

function New-RemoteDebuggerAcceptanceNetworkPolicy {
    Set-StrictMode -Version Latest
    [ordered]@{
        FormatVersion = 1
        DefaultProfile = 'None'
        IsolatedTestNet = [ordered]@{ Enabled = $true; SwitchPrefix = 'RemoteDebugger-Acceptance-TestNet'; NetworkPrefix = '10.254.0.0/24' }
        InternetOnly = [ordered]@{
            Enabled = $false; SwitchName = ''; SwitchId = ''; NatName = ''; NatPrefix = ''; ExternalIPInterfaceAddressPrefix = ''
            InternalRoutingDomainId = '{00000000-0000-0000-0000-000000000000}'
            TcpFilteringBehavior = 'AddressDependentFiltering'; UdpFilteringBehavior = 'AddressDependentFiltering'; UdpInboundRefresh = $false
            TcpEstablishedConnectionTimeout = 1800; TcpTransientConnectionTimeout = 120; UdpIdleSessionTimeout = 120; IcmpQueryTimeout = 30
            GatewayAddress = ''; PrefixLength = 24; PrimaryVlanId = 0; SecondaryVlanId = 0; DnsServers = @(); DenyRemotePrefixes = @()
        }
        TrustedLan = [ordered]@{ Enabled = $false; AllowedSwitches = @() }
    }
}

function New-RemoteDebuggerAcceptanceConfiguration {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $PublisherThumbprint,
        [Parameter(Mandatory = $true)] [string[]] $ApprovedHashes
    )

    Set-StrictMode -Version Latest
    $liveRoot = Join-Path $Root 'Live'
    $softwareRoot = Join-Path $Root 'Software'
    [ordered]@{
        FormatVersion = 1
        InstallRoot = $Root
        LiveRoot = $liveRoot
        BaselineRoot = Join-Path $liveRoot 'Baseline'
        BrokerRoot = Join-Path $liveRoot 'Broker'
        SoftwareRoot = $softwareRoot
        HarnessSourceRoot = Join-Path $softwareRoot 'Harness'
        SkillSourceRoot = Join-Path $softwareRoot 'Skill'
        RecoveryRoot = Join-Path $Root 'Recovery'
        BaselineVmName = 'RemoteDebugger-Acceptance-Baseline'
        BaselineCheckpointName = 'RemoteDebugger-Acceptance-Clean'
        PoolVmPrefix = 'RemoteDebugger-Acceptance'
        PoolSize = 2
        PoolIdleTimeoutSeconds = 600
        PoolLifecycleConcurrency = 2
        VmMemoryBytes = [long]8GB
        VmProcessorCount = 4
        GuestDisplayWidth = 1920
        GuestDisplayHeight = 1080
        BrokerTaskName = 'RemoteDebugger Acceptance Hyper-V Broker'
        BrokerLocationPointer = Join-Path $liveRoot 'broker-location.json'
        BrokerInstanceId = 'RemoteDebuggerAcceptance'
        RecoveryResumeTaskName = 'RemoteDebugger Acceptance Recovery Resume'
        RecoveryGenerations = 1
        NetworkPolicy = 'DisconnectedExceptPerRequestIsolatedTestNet'
        RequestNetworkPolicy = New-RemoteDebuggerAcceptanceNetworkPolicy
        RemoteDebuggerProvisionV1 = [ordered]@{
            FormatVersion = 1
            Enabled = $true
            PublisherThumbprint = $PublisherThumbprint
            ApprovedExecutableSha256 = @($ApprovedHashes)
        }
    }
}

function Get-RemoteDebuggerAcceptancePointerSnapshot {
    Set-StrictMode -Version Latest
    $path = 'C:\ProgramData\CodexHyperVBroker\location.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Path = $path; Disposition = 'AbsentAndMustRemainAbsent'; Sha256 = $null; BrokerRoot = $null }
    }
    Assert-RemoteDebuggerAcceptanceNoReparseAncestors -Path $path -Boundary ([IO.Path]::GetPathRoot($path))
    $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    [pscustomobject][ordered]@{
        Path = $path
        Disposition = 'PresentAndMustRemainByteIdentical'
        Sha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $path
        BrokerRoot = [string]$document.BrokerRoot
    }
}

function Assert-RemoteDebuggerAcceptancePointerUnchanged {
    param([Parameter(Mandatory = $true)] $Snapshot)

    Set-StrictMode -Version Latest
    if ([string]$Snapshot.Disposition -eq 'AbsentAndMustRemainAbsent') {
        if (Test-Path -LiteralPath ([string]$Snapshot.Path)) { throw 'Shared global broker pointer was unexpectedly created.' }
        return
    }
    if (-not (Test-Path -LiteralPath ([string]$Snapshot.Path) -PathType Leaf) -or
        (Get-RemoteDebuggerAcceptanceSha256 -Path ([string]$Snapshot.Path)) -cne [string]$Snapshot.Sha256) {
        throw 'Shared global broker pointer changed during dedicated acceptance setup.'
    }
}

function Get-RemoteDebuggerAcceptanceInventory {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string[]] $VmNames,
        [Parameter(Mandatory = $true)] [string] $TaskName
    )

    Set-StrictMode -Version Latest
    if (Test-Path -LiteralPath $Root) { throw "Dedicated install root already exists: $Root" }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { Import-Module Hyper-V -ErrorAction Stop }
    $conflictingVms = @($VmNames | Where-Object { $null -ne (Get-VM -Name $_ -ErrorAction SilentlyContinue) })
    if ($conflictingVms.Count -gt 0) { throw "Dedicated VM name already exists: $($conflictingVms[0])" }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { throw "Dedicated broker task already exists: $TaskName" }
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).Substring(0, 1)) -PSProvider FileSystem -ErrorAction Stop
    $minimum = [long]120GB
    if ([long]$drive.Free -lt $minimum) { throw "Dedicated setup requires at least 120 GiB free; found $([Math]::Round([long]$drive.Free / 1GB, 1)) GiB." }
    [pscustomobject][ordered]@{
        InstallRootAbsent = $true
        DedicatedVmNamesAbsent = $true
        DedicatedTaskAbsent = $true
        FreeBytes = [long]$drive.Free
        MinimumFreeBytes = $minimum
        SufficientFreeSpace = $true
    }
}

function New-RemoteDebuggerAcceptancePlan {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $BundleRoot,
        [Parameter(Mandatory = $true)] [string] $RepositoryRoot,
        [Parameter(Mandatory = $true)] [string] $PublisherPath,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $FixturePaths,
        [Parameter(Mandatory = $true)] [string] $HostClientSid
    )

    Set-StrictMode -Version Latest
    $root = Assert-RemoteDebuggerAcceptanceExactPath -Actual $Root -Expected $script:DedicatedInstallRoot -Name 'InstallRoot'
    try { $null = [Security.Principal.SecurityIdentifier]::new($HostClientSid) }
    catch { throw "ClientSid is invalid: $HostClientSid" }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
    $harnessRoot = Join-Path $repository 'src\Software\Harness'
    $skillRoot = Join-Path $repository 'src\Software\Skill'
    $modulePath = Join-Path $harnessRoot 'RemoteDebuggerProvisioning.ps1'
    foreach ($path in @($harnessRoot, $skillRoot, $modulePath, $PSCommandPath)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Dedicated setup source is missing: $path" }
    }
    $sourceFingerprint = Get-RemoteDebuggerAcceptanceTreeFingerprint -Trees @(
        [pscustomobject]@{ Name = 'Harness'; Path = $harnessRoot },
        [pscustomobject]@{ Name = 'Skill'; Path = $skillRoot }
    )
    Initialize-RemoteDebuggerAcceptanceAuthenticodeVerifier -ModulePath $modulePath
    $publisher = Resolve-RemoteDebuggerAcceptancePublisher -Path $PublisherPath
    $fixtures = New-Object Collections.Generic.List[object]
    foreach ($variant in @('Release', 'Older', 'Newer', 'SameVersionDifferentHash')) {
        if (-not $FixturePaths.Contains($variant)) { throw "Missing $variant fixture path." }
        $fixtures.Add((Resolve-RemoteDebuggerAcceptanceFixture -Variant $variant -Path ([string]$FixturePaths[$variant]) -ExpectedSha256 ([string]$script:ExpectedFixtureHashes[$variant]) -PublisherThumbprint ([string]$publisher.CertificateSha256)))
    }
    if (@($fixtures.ToArray() | Group-Object Sha256 | Where-Object Count -ne 1).Count -gt 0) {
        throw 'Each acceptance fixture must have a distinct exact SHA-256.'
    }
    $approvedHashes = @($fixtures.ToArray() | ForEach-Object { [string]$_.Sha256 })
    $configuration = New-RemoteDebuggerAcceptanceConfiguration -Root $root -PublisherThumbprint ([string]$publisher.CertificateSha256) -ApprovedHashes $approvedHashes
    $configurationJson = $configuration | ConvertTo-Json -Compress -Depth 30
    $recovery = Resolve-RemoteDebuggerAcceptanceRecovery -BundleRoot $BundleRoot
    $pointer = Get-RemoteDebuggerAcceptancePointerSnapshot
    $sharedConfigPath = 'D:\Disk\VMs\Codex-Harness\Software\harness-config.json'
    if (-not (Test-Path -LiteralPath $sharedConfigPath -PathType Leaf)) { throw "Shared harness configuration is missing: $sharedConfigPath" }
    $vmNames = @('RemoteDebugger-Acceptance-Baseline', 'RemoteDebugger-Acceptance-01', 'RemoteDebugger-Acceptance-02')
    $inventory = Get-RemoteDebuggerAcceptanceInventory -Root $root -VmNames $vmNames -TaskName 'RemoteDebugger Acceptance Hyper-V Broker'
    $core = [ordered]@{
        FormatVersion = 1
        Operation = 'InstallRemoteDebuggerAcceptancePoolV1'
        InstallRoot = $root
        Source = [ordered]@{
            RepositoryRoot = $repository
            HarnessRoot = $harnessRoot
            SkillRoot = $skillRoot
            TreeFileCount = [int]$sourceFingerprint.FileCount
            TreeTotalBytes = [long]$sourceFingerprint.TotalBytes
            TreeSha256 = [string]$sourceFingerprint.Sha256
            SetupScriptSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $PSCommandPath
            ProvisioningModuleSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $modulePath
            ObservationModuleSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path (Join-Path $harnessRoot 'RemoteDebuggerObservation.ps1')
        }
        RecoverySource = $recovery
        Publisher = $publisher
        ApprovedFixtures = $fixtures.ToArray()
        Layout = [ordered]@{
            BaselineVmName = 'RemoteDebugger-Acceptance-Baseline'
            BaselineCheckpointName = 'RemoteDebugger-Acceptance-Clean'
            PoolVmNames = @('RemoteDebugger-Acceptance-01', 'RemoteDebugger-Acceptance-02')
            PoolSize = 2
            VmMemoryBytes = [long]8GB
            VmProcessorCount = 4
            GuestDisplayWidth = 1920
            GuestDisplayHeight = 1080
            PoolIdleTimeoutSeconds = 600
            PoolLifecycleConcurrency = 2
            BrokerRoot = Join-Path $root 'Live\Broker'
            BrokerTaskName = 'RemoteDebugger Acceptance Hyper-V Broker'
            BrokerInstanceId = 'RemoteDebuggerAcceptance'
            BrokerMutexName = 'Global\CodexHyperVBroker-RemoteDebuggerAcceptance'
            ClientSid = $HostClientSid
            NetworkDefault = 'None'
            EnabledRequestNetworks = @('None', 'IsolatedTestNet')
            DisabledRequestNetworks = @('InternetOnly', 'TrustedLan')
        }
        ProtectedConfiguration = [ordered]@{
            Path = Join-Path $root 'Software\harness-config.json'
            ContentSha256 = Get-RemoteDebuggerAcceptanceTextSha256 -Text $configurationJson
            RemoteDebuggerProvisionV1 = $configuration.RemoteDebuggerProvisionV1
        }
        PrivilegedBootstrap = [ordered]@{
            FixedCommand = 'RemoteDebugger.exe cli platform-provision'
            NormalPayloadExecutable = 'Lab.exe'
            EvidencePath = 'C:\CodexGuest\Provisioning\<RequestId>\remote-debugger-provisioning.json'
            ProductLaunchToken = 'Interactive medium user inherited by Lab; bootstrap never launches the normal product UI.'
            Observation = 'Bounded administrator read-only powercfg, firewall, and service snapshot; no request-controlled command.'
        }
        Preservation = [ordered]@{
            SharedGlobalBrokerPointer = $pointer
            SharedHarnessConfigurationPath = $sharedConfigPath
            SharedHarnessConfigurationSha256 = Get-RemoteDebuggerAcceptanceSha256 -Path $sharedConfigPath
            SharedBaselineVmName = 'Codex-Harness-Baseline'
            SharedPoolVmNames = @('Codex-Harness-01', 'Codex-Harness-02', 'Codex-Harness-03', 'Codex-Harness-04')
            SharedBrokerTaskName = 'Codex Hyper-V Broker'
            CodexPointerUpdate = $false
            SharedWorkerMutation = $false
        }
        Effects = @(
            'Deep-hash verify the fixed Recovery Current bundle before mutation.',
            'Copy the reviewed harness and skill source into the dedicated root; copy the guest credential opaquely with administrator/SYSTEM ACLs.',
            'Import the known baseline with Import-VM -Copy -GenerateNewId, immediately rename the returned VM object, and keep all adapters disconnected.',
            'Create two disposable 8 GiB, four-vCPU workers at 1920x1080 from the renamed clean checkpoint.',
            'Install and start only the dedicated SYSTEM broker task; it may prewarm a disconnected worker.',
            'Permit only None and per-request IsolatedTestNet; never connect the baseline or workers to InternetOnly or TrustedLan.',
            'Preserve the shared baseline, shared workers, shared broker task, and global broker pointer byte-for-byte.'
        )
    }
    [pscustomobject][ordered]@{ Core = $core; Configuration = $configuration; Inventory = $inventory }
}

function Set-RemoteDebuggerAcceptancePrivateAcl {
    param([Parameter(Mandatory = $true)] [string] $Path)

    Set-StrictMode -Version Latest
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($rule)
    }
    if ($item.PSIsContainer) { [IO.Directory]::SetAccessControl($item.FullName, $acl) }
    else { [IO.File]::SetAccessControl($item.FullName, $acl) }
}

function Write-RemoteDebuggerAcceptanceJson {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    Set-StrictMode -Version Latest
    $json = $Value | ConvertTo-Json -Compress -Depth 30
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

if ($LibraryOnly) { return }
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
$fixturePaths = [ordered]@{
    Release = $ReleaseExecutablePath
    Older = $OlderExecutablePath
    Newer = $NewerExecutablePath
    SameVersionDifferentHash = $SameVersionExecutablePath
}
$definition = New-RemoteDebuggerAcceptancePlan -Root $InstallRoot -BundleRoot $RecoveryBundleRoot -RepositoryRoot $SourceRoot -PublisherPath $PublisherCertificatePath -FixturePaths $fixturePaths -HostClientSid $ClientSid
$planSha256 = Get-RemoteDebuggerAcceptancePlanSha256 -Plan $definition.Core
if ($PlanOnly) {
    [pscustomobject][ordered]@{
        FormatVersion = 1
        Operation = 'InstallRemoteDebuggerAcceptancePoolV1'
        PlanSha256 = $planSha256
        Plan = $definition.Core
        ReadOnlyChecks = $definition.Inventory
        NoMutationPerformed = $true
        ApplyCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File setup\Install-RemoteDebuggerAcceptancePool.ps1 -Apply -ExpectedPlanSha256 $planSha256 <same explicit certificate and fixture paths>"
    } | ConvertTo-Json -Depth 30
    return
}

if (-not [string]::Equals($planSha256, $ExpectedPlanSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Dedicated acceptance plan drifted: expected $ExpectedPlanSha256, recomputed $planSha256. Run -PlanOnly again and review the new plan."
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Dedicated acceptance pool apply must run from an elevated Windows PowerShell 5.1 process.'
}

$installRootFull = [string]$definition.Core.InstallRoot
$pointerSnapshot = $definition.Core.Preservation.SharedGlobalBrokerPointer
$sharedConfigPath = [string]$definition.Core.Preservation.SharedHarnessConfigurationPath
$sharedConfigSha256 = [string]$definition.Core.Preservation.SharedHarnessConfigurationSha256
$vmNames = @('RemoteDebugger-Acceptance-Baseline', 'RemoteDebugger-Acceptance-01', 'RemoteDebugger-Acceptance-02')
$taskName = 'RemoteDebugger Acceptance Hyper-V Broker'
$mutexNameHash = Get-RemoteDebuggerAcceptanceTextSha256 -Text $installRootFull.ToUpperInvariant()
$mutex = [Threading.Mutex]::new($false, ('Global\CodexRemoteDebuggerAcceptanceSetup-' + $mutexNameHash.Substring(0, 20)))
$lockTaken = $false
try {
    try { $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) }
    catch [Threading.AbandonedMutexException] { $lockTaken = $true }
    if (-not $lockTaken) { throw 'Another setup operation for this dedicated acceptance root is already running.' }
    if (Test-Path -LiteralPath $installRootFull) { throw "Dedicated install root appeared after review: $installRootFull" }
    foreach ($name in $vmNames) { if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw "Dedicated VM name appeared after review: $name" } }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw "Dedicated broker task appeared after review: $taskName" }
    Assert-RemoteDebuggerAcceptancePointerUnchanged -Snapshot $pointerSnapshot
    if ((Get-RemoteDebuggerAcceptanceSha256 -Path $sharedConfigPath) -cne $sharedConfigSha256) { throw 'Shared harness configuration changed after plan review.' }

    . (Join-Path ([string]$definition.Core.RecoverySource.Root) 'RecoveryCommon.ps1')
    $integrity = Test-CodexRecoveryBundleIntegrity -BundleRoot ([string]$definition.Core.RecoverySource.Root)
    if (-not $integrity.Success) { throw ('Recovery Current deep verification failed: ' + ($integrity.Failures -join '; ')) }
    if ((Get-RemoteDebuggerAcceptanceSha256 -Path ([string]$definition.Core.RecoverySource.ManifestPath)) -cne [string]$definition.Core.RecoverySource.ManifestSha256) {
        throw 'Recovery Current manifest changed during deep verification.'
    }

    New-Item -ItemType Directory -Path $installRootFull | Out-Null
    $softwareRoot = Join-Path $installRootFull 'Software'
    New-Item -ItemType Directory -Path $softwareRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'src\Software\Harness') -Destination (Join-Path $softwareRoot 'Harness') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'src\Software\Skill') -Destination (Join-Path $softwareRoot 'Skill') -Recurse -Force
    $copiedFingerprint = Get-RemoteDebuggerAcceptanceTreeFingerprint -Trees @(
        [pscustomobject]@{ Name = 'Harness'; Path = (Join-Path $softwareRoot 'Harness') },
        [pscustomobject]@{ Name = 'Skill'; Path = (Join-Path $softwareRoot 'Skill') }
    )
    if ([string]$copiedFingerprint.Sha256 -cne [string]$definition.Core.Source.TreeSha256) { throw 'Dedicated source copy does not match the reviewed source tree.' }

    $configPath = Join-Path $softwareRoot 'harness-config.json'
    Write-RemoteDebuggerAcceptanceJson -Path $configPath -Value $definition.Configuration
    if ((Get-RemoteDebuggerAcceptanceSha256 -Path $configPath) -cne [string]$definition.Core.ProtectedConfiguration.ContentSha256) {
        throw 'Dedicated protected configuration bytes do not match the reviewed plan.'
    }
    $privateRoot = Join-Path $softwareRoot 'Harness\private'
    New-Item -ItemType Directory -Path $privateRoot | Out-Null
    Set-RemoteDebuggerAcceptancePrivateAcl -Path $privateRoot
    $credentialSource = Join-Path ([string]$definition.Core.RecoverySource.Root) ([string]$definition.Core.RecoverySource.CredentialRelativePath).Replace('/', '\')
    $credentialDestination = Join-Path $privateRoot 'guest-credential.json'
    Copy-Item -LiteralPath $credentialSource -Destination $credentialDestination
    Set-RemoteDebuggerAcceptancePrivateAcl -Path $credentialDestination

    Import-Module Hyper-V -ErrorAction Stop
    $baselineRoot = Join-Path $installRootFull 'Live\Baseline'
    $vmPath = Join-Path $baselineRoot 'Virtual Machines'
    $snapshotPath = Join-Path $baselineRoot 'Snapshots'
    $pagingPath = Join-Path $baselineRoot 'Smart Paging'
    $vhdPath = Join-Path $baselineRoot 'Virtual Hard Disks'
    New-Item -ItemType Directory -Force -Path $vmPath, $snapshotPath, $pagingPath, $vhdPath | Out-Null
    $importedVm = Import-VM -Path ([string]$definition.Core.RecoverySource.ExportedVmConfigurationPath) -Copy -GenerateNewId -VirtualMachinePath $vmPath -SnapshotFilePath $snapshotPath -SmartPagingFilePath $pagingPath -VhdDestinationPath $vhdPath -ErrorAction Stop
    if ([string]$importedVm.Id -eq [string]$definition.Core.RecoverySource.BaselineVmId) { throw 'Import-VM did not generate a new baseline VM identity.' }
    Rename-VM -VM $importedVm -NewName 'RemoteDebugger-Acceptance-Baseline' -ErrorAction Stop
    $importedVm = Get-VM -Id $importedVm.Id -ErrorAction Stop
    if ($importedVm.State -ne 'Off') { Stop-VM -VM $importedVm -TurnOff -Force -ErrorAction Stop | Out-Null }
    $configurationLocation = [IO.Path]::GetFullPath([string]$importedVm.ConfigurationLocation)
    if (-not ($configurationLocation + '\').StartsWith($baselineRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Imported baseline configuration escaped the dedicated baseline root.'
    }
    Get-VMNetworkAdapter -VM $importedVm -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction Stop
    Set-VMProcessor -VM $importedVm -Count 4 -ErrorAction Stop
    Set-VMMemory -VM $importedVm -DynamicMemoryEnabled $false -StartupBytes ([long]8GB) -ErrorAction Stop
    Set-VMVideo -VM $importedVm -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single -ErrorAction Stop
    Set-VM -VM $importedVm -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -ErrorAction Stop
    $sourceSnapshots = @(Get-VMSnapshot -VM $importedVm -ErrorAction Stop | Where-Object { [string]$_.Name -ceq 'Clean-Windows11-Harness' })
    if ($sourceSnapshots.Count -ne 1) { throw "Imported baseline must contain one reviewed clean checkpoint; found $($sourceSnapshots.Count)." }
    Rename-VMSnapshot -VMSnapshot $sourceSnapshots[0] -NewName 'RemoteDebugger-Acceptance-Clean' -ErrorAction Stop

    $harnessSourceRoot = Join-Path $softwareRoot 'Harness'
    $brokerRoot = Join-Path $installRootFull 'Live\Broker'
    $poolDefinitionPath = Join-Path $harnessSourceRoot 'pool-definition.json'
    & (Join-Path $harnessSourceRoot 'Initialize-HyperVTestPool.ps1') -SourceVmName 'RemoteDebugger-Acceptance-Baseline' -BaselineName 'RemoteDebugger-Acceptance-Clean' -PoolSize 2 -PoolVmPrefix 'RemoteDebugger-Acceptance' -BrokerRoot $brokerRoot -DefinitionPath $poolDefinitionPath -StatusPath (Join-Path $brokerRoot 'State\Management\pool-provision-status.json') -ConfigPath $configPath
    & (Join-Path $harnessSourceRoot 'Install-PoolHostBroker.ps1') -SourceRoot $harnessSourceRoot -BrokerRoot $brokerRoot -PoolDefinitionPath $poolDefinitionPath -StatusPath (Join-Path $brokerRoot 'State\Management\pool-broker-install-status.json') -ConfigPath $configPath -ClientSid $ClientSid

    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction Stop
        $location = [IO.Path]::GetFullPath([string]$vm.ConfigurationLocation)
        if (-not ($location + '\').StartsWith($installRootFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Dedicated VM escaped install root: $name" }
        if (@(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SwitchName) }).Count -gt 0) { throw "Dedicated VM has a connected network adapter: $name" }
    }
    $baseline = Get-VM -Name 'RemoteDebugger-Acceptance-Baseline' -ErrorAction Stop
    if ($baseline.State -ne 'Off') { throw 'Dedicated baseline was unexpectedly started.' }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -eq 'Disabled') { throw 'Dedicated broker task is disabled after installation.' }
    Assert-RemoteDebuggerAcceptancePointerUnchanged -Snapshot $pointerSnapshot
    if ((Get-RemoteDebuggerAcceptanceSha256 -Path $sharedConfigPath) -cne $sharedConfigSha256) { throw 'Shared harness configuration changed during dedicated setup.' }

    $receipt = [ordered]@{
        FormatVersion = 1
        Success = $true
        Operation = 'InstallRemoteDebuggerAcceptancePoolV1'
        PlanSha256 = $planSha256
        InstallRoot = $installRootFull
        BaselineVmId = [string]$baseline.Id
        BaselineVmName = [string]$baseline.Name
        PoolVmNames = @('RemoteDebugger-Acceptance-01', 'RemoteDebugger-Acceptance-02')
        BrokerRoot = $brokerRoot
        BrokerTaskName = $taskName
        BrokerTaskState = [string]$task.State
        PublisherThumbprint = $script:ExpectedPublisherThumbprint
        ApprovedExecutableSha256 = @($script:ExpectedFixtureHashes.Values)
        SharedGlobalPointerPreserved = $true
        SharedHarnessConfigurationPreserved = $true
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receiptPath = Join-Path $installRootFull 'Live\Setup\remote-debugger-acceptance-install.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $receiptPath) -Force | Out-Null
    Write-RemoteDebuggerAcceptanceJson -Path $receiptPath -Value $receipt
    [pscustomobject]$receipt | ConvertTo-Json -Depth 20
}
catch {
    # Preserve partial dedicated assets for inspection. Automatic cleanup could
    # mistake an independently-created same-name VM or task for this attempt.
    throw
}
finally {
    if ($lockTaken) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
