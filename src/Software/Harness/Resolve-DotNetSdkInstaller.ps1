[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+$')] [string] $Channel = '10.0',
    [string] $ExpectedVersion,
    [string] $DestinationDirectory,
    [switch] $Download,
    [string] $ReleaseIndexUri = 'https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json',
    [string] $ReleaseIndexPath,
    [string] $ReleasesPath,
    [switch] $AllowUnsignedLocalMetadata
)

$ErrorActionPreference = 'Stop'
$officialMetadataHosts = @('dotnetcli.blob.core.windows.net', 'builds.dotnet.microsoft.com')
$officialPayloadHosts = @('builds.dotnet.microsoft.com')

function Assert-OfficialHttpsUri {
    param(
        [Parameter(Mandatory = $true)] [string] $Value,
        [Parameter(Mandatory = $true)] [string[]] $AllowedHosts,
        [Parameter(Mandatory = $true)] [string] $Purpose
    )

    $uri = [Uri]$Value
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin $AllowedHosts) {
        throw "$Purpose must use HTTPS on an approved Microsoft .NET host: $Value"
    }
    $uri
}

function Invoke-VerifiedWebDownload {
    param(
        [Parameter(Mandatory = $true)] [Uri] $Uri,
        [Parameter(Mandatory = $true)] [string] $Path
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Invoke-WebRequest -Uri $Uri.AbsoluteUri -OutFile $temporary -UseBasicParsing
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-MetadataJson {
    param(
        [string] $LocalPath,
        [Uri] $Uri,
        [string] $TemporaryRoot,
        [string] $Name
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalPath)) {
        if (-not $AllowUnsignedLocalMetadata) {
            throw 'Local .NET release metadata is accepted only with -AllowUnsignedLocalMetadata for deterministic source tests.'
        }
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
            throw "Local .NET metadata file is missing: $LocalPath"
        }
        return Get-Content -Raw -LiteralPath $LocalPath | ConvertFrom-Json
    }

    $path = Join-Path $TemporaryRoot $Name
    Invoke-VerifiedWebDownload -Uri $Uri -Path $path
    Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-dotnet-metadata-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    $indexUri = Assert-OfficialHttpsUri -Value $ReleaseIndexUri -AllowedHosts $officialMetadataHosts -Purpose 'The .NET release index'
    $index = Get-MetadataJson -LocalPath $ReleaseIndexPath -Uri $indexUri -TemporaryRoot $temporaryRoot -Name 'releases-index.json'
    $channelEntry = @($index.'releases-index' | Where-Object { [string]$_.'channel-version' -eq $Channel })
    if ($channelEntry.Count -ne 1) {
        throw "Expected exactly one .NET channel '$Channel' in the official release index; found $($channelEntry.Count)."
    }
    $channelEntry = $channelEntry[0]
    if ([string]$channelEntry.'support-phase' -notin @('active', 'maintenance')) {
        throw ".NET channel $Channel is not supported; support phase is '$($channelEntry.'support-phase')'."
    }
    if ([string]$channelEntry.'latest-sdk' -match '(?i)(preview|rc)') {
        throw "The resolved .NET SDK is not stable: $($channelEntry.'latest-sdk')"
    }
    $version = [string]$channelEntry.'latest-sdk'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $version -ne $ExpectedVersion) {
        throw "The latest stable .NET $Channel SDK changed after approval: expected $ExpectedVersion, resolved $version. Review a new plan before downloading it."
    }

    $releasesUri = Assert-OfficialHttpsUri -Value ([string]$channelEntry.'releases.json') -AllowedHosts $officialMetadataHosts -Purpose 'The .NET channel metadata'
    $releases = Get-MetadataJson -LocalPath $ReleasesPath -Uri $releasesUri -TemporaryRoot $temporaryRoot -Name "releases-$Channel.json"
    if ([string]$releases.'latest-sdk' -ne $version) {
        throw "The .NET release index and channel metadata disagree: '$version' versus '$($releases.'latest-sdk')'."
    }

    $sdk = $null
    $release = $null
    foreach ($candidateRelease in @($releases.releases)) {
        $candidateSdks = New-Object Collections.Generic.List[object]
        if ($candidateRelease.sdk) { $candidateSdks.Add($candidateRelease.sdk) }
        foreach ($candidateSdk in @($candidateRelease.sdks)) { if ($candidateSdk) { $candidateSdks.Add($candidateSdk) } }
        $match = @($candidateSdks | Where-Object { [string]$_.version -eq $version } | Select-Object -First 1)
        if ($match.Count -eq 1) {
            $release = $candidateRelease
            $sdk = $match[0]
            break
        }
    }
    if (-not $sdk) { throw "The official .NET $Channel metadata does not describe SDK $version." }

    $installer = @($sdk.files | Where-Object {
        [string]$_.rid -eq 'win-x64' -and [string]$_.name -eq 'dotnet-sdk-win-x64.exe'
    })
    if ($installer.Count -ne 1) {
        throw "Expected exactly one win-x64 executable for .NET SDK $version; found $($installer.Count)."
    }
    $installer = $installer[0]
    $installerUri = Assert-OfficialHttpsUri -Value ([string]$installer.url) -AllowedHosts $officialPayloadHosts -Purpose 'The .NET SDK installer'
    $expectedSha512 = ([string]$installer.hash).ToUpperInvariant()
    if ($expectedSha512 -notmatch '^[A-F0-9]{128}$') {
        throw "The official .NET SDK installer metadata has an invalid SHA-512 value for $version."
    }

    $installerPath = $null
    $signatureSubject = $null
    if ($Download) {
        if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
            throw '-DestinationDirectory is required with -Download.'
        }
        $destinationRoot = [IO.Path]::GetFullPath($DestinationDirectory)
        New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
        $installerPath = Join-Path $destinationRoot ("dotnet-sdk-$version-win-x64.exe")
        $validExisting = $false
        if (Test-Path -LiteralPath $installerPath -PathType Leaf) {
            $validExisting = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA512).Hash -eq $expectedSha512
            if ($validExisting) {
                $existingSignature = Get-AuthenticodeSignature -LiteralPath $installerPath
                $validExisting = $existingSignature.Status -eq 'Valid' -and [string]$existingSignature.SignerCertificate.Subject -match 'Microsoft Corporation'
            }
        }
        if (-not $validExisting) {
            Invoke-VerifiedWebDownload -Uri $installerUri -Path $installerPath
        }
        $actualSha512 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA512).Hash
        if ($actualSha512 -ne $expectedSha512) {
            throw "The downloaded .NET SDK $version SHA-512 does not match Microsoft's release metadata."
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
        if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "The downloaded .NET SDK $version installer does not have a valid Microsoft Authenticode signature."
        }
        $signatureSubject = [string]$signature.SignerCertificate.Subject
    }

    [pscustomobject][ordered]@{
        Channel = $Channel
        Version = $version
        RuntimeVersion = [string]$sdk.'runtime-version'
        ReleaseDate = [string]$release.'release-date'
        SupportPhase = [string]$channelEntry.'support-phase'
        ReleaseType = [string]$channelEntry.'release-type'
        Uri = $installerUri.AbsoluteUri
        Sha512 = $expectedSha512
        InstallerPath = $installerPath
        AuthenticodeSubject = $signatureSubject
        Downloaded = [bool]$Download
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
