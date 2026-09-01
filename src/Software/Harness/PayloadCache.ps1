function Assert-PayloadHexId {
    param(
        [Parameter(Mandatory = $true)] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($Value -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "$Name must be a 64-character SHA-256 value."
    }
    $Value.ToUpperInvariant()
}

function Get-PayloadTextSha256 {
    param([Parameter(Mandatory = $true)] [string] $Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        ([BitConverter]::ToString($digest)).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-PayloadRequestId {
    param([Parameter(Mandatory = $true)] [string] $RequestId)

    if ($RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
        throw 'Payload lease RequestId is invalid.'
    }
    $RequestId
}

function Get-PayloadLeaseFile {
    param([Parameter(Mandatory = $true)] [string] $RequestId)

    $safeId = Assert-PayloadRequestId -RequestId $RequestId
    $path = Join-Path $payloadLeasePath ($safeId + '.json')
    Assert-PathInsideRoot -Path $path -Root $payloadLeasePath -Purpose 'payload generation lease' | Out-Null
    $path
}

function New-PayloadGenerationLease {
    param(
        [Parameter(Mandatory = $true)] [string] $PayloadId,
        [Parameter(Mandatory = $true)] [string] $ContentKey,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $VmName
    )

    $normalizedPayloadId = Assert-PayloadHexId -Value $PayloadId -Name 'Payload lease PayloadId'
    $normalizedContentKey = Assert-PayloadHexId -Value $ContentKey -Name 'Payload lease ContentKey'
    New-Item -ItemType Directory -Force -Path $payloadLeasePath | Out-Null
    $path = Get-PayloadLeaseFile -RequestId $RequestId
    Write-JsonAtomic -Path $path -Value ([ordered]@{
        RequestId = $RequestId
        PayloadId = $normalizedPayloadId
        ContentKey = $normalizedContentKey
        VmName = $VmName
        ParentVhdx = $null
        ChildVhdx = $null
        Stage = 'Synchronizing'
        ProcessId = $PID
        ProcessStartUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    })
    $path
}

function Update-PayloadGenerationLease {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [string] $ParentVhdx,
        [string] $ChildVhdx,
        [string] $Stage
    )

    $path = Get-PayloadLeaseFile -RequestId $RequestId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Payload generation lease is missing: $RequestId"
    }
    $lease = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    if ($PSBoundParameters.ContainsKey('ParentVhdx')) { $lease.ParentVhdx = $ParentVhdx }
    if ($PSBoundParameters.ContainsKey('ChildVhdx')) { $lease.ChildVhdx = $ChildVhdx }
    if ($PSBoundParameters.ContainsKey('Stage')) { $lease.Stage = $Stage }
    $lease.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic -Path $path -Value $lease
}

function Remove-PayloadGenerationLease {
    param([Parameter(Mandatory = $true)] [string] $RequestId)

    $path = Get-PayloadLeaseFile -RequestId $RequestId
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Get-ActivePayloadGenerationLeases {
    param(
        [Parameter(Mandatory = $true)] [string] $PayloadId,
        [string] $ExcludeRequestId
    )

    $normalizedPayloadId = Assert-PayloadHexId -Value $PayloadId -Name 'Payload lease query PayloadId'
    @(
        foreach ($leaseFile in Get-ChildItem -LiteralPath $payloadLeasePath -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try {
                $lease = Get-Content -Raw -LiteralPath $leaseFile.FullName -Encoding UTF8 | ConvertFrom-Json
                if ([string]$lease.PayloadId -eq $normalizedPayloadId -and
                    ([string]::IsNullOrWhiteSpace($ExcludeRequestId) -or -not [string]::Equals([string]$lease.RequestId, $ExcludeRequestId, [StringComparison]::OrdinalIgnoreCase))) {
                    $lease
                }
            }
            catch { }
        }
    )
}

function Get-PayloadCacheMutex {
    param([Parameter(Mandatory = $true)] [string] $PayloadId)

    $normalizedPayloadId = Assert-PayloadHexId -Value $PayloadId -Name 'Payload mutex PayloadId'
    New-Object Threading.Mutex($false, ('Global\CodexHyperVPayloadCache-' + $normalizedPayloadId))
}

function Enter-PayloadCacheMutex {
    param(
        [Parameter(Mandatory = $true)] [Threading.Mutex] $Mutex,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )

    while ($true) {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        try {
            if ($Mutex.WaitOne(500)) { return $true }
        }
        catch [Threading.AbandonedMutexException] {
            return $true
        }
    }
}

function Get-PayloadIdForArtifact {
    param(
        [Parameter(Mandatory = $true)] [string] $ArtifactPath,
        [Parameter(Mandatory = $true)] [bool] $IsDirectory,
        [ValidateSet('Application', 'ReadOnlyHostInput')] [string] $CacheScope = 'Application'
    )

    $identityPrefix = if ($CacheScope -eq 'ReadOnlyHostInput') {
        if ($IsDirectory) { 'readonly-host-input-directory|' } else { 'readonly-host-input-file|' }
    }
    elseif ($IsDirectory) { 'directory|' }
    else { 'file|' }
    Get-PayloadTextSha256 -Text ($identityPrefix + $ArtifactPath.ToUpperInvariant())
}

function Get-PayloadContentKeyFromManifest {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Files,
        [string[]] $Directories = @()
    )

    $canonical = New-Object Text.StringBuilder
    foreach ($directory in $Directories) {
        [void]$canonical.Append('D:').Append($directory.Length).Append(':').Append($directory).Append("`n")
    }
    foreach ($file in $Files) {
        $relativePath = [string]$file.RelativePath
        [void]$canonical.Append('F:').Append($relativePath.Length).Append(':').Append($relativePath).Append(':').Append([long]$file.Length).Append(':').Append(([string]$file.Sha256).ToUpperInvariant()).Append("`n")
    }
    Get-PayloadTextSha256 -Text $canonical.ToString()
}

function ConvertTo-SafePayloadRelativePath {
    param([Parameter(Mandatory = $true)] [string] $RelativePath)

    $normalized = $RelativePath.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized) -or [IO.Path]::IsPathRooted($normalized)) {
        throw "Invalid payload-relative path: $RelativePath"
    }
    $validationRoot = Join-Path $env:SystemDrive 'CodexPayloadPathValidation'
    $validationPrefix = [IO.Path]::GetFullPath($validationRoot).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath((Join-Path $validationRoot $normalized))
    if (-not $resolved.StartsWith($validationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Payload-relative path escapes its root: $RelativePath"
    }
    $normalized
}

function Assert-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $Purpose
    )

    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing $Purpose outside $rootPrefix"
    }
    $resolved
}

function Read-AndValidatePayloadManifest {
    param([Parameter(Mandatory = $true)] $Request)

    if (-not $Request.Payload) {
        throw 'The request does not include payload cache metadata.'
    }
    $payload = $Request.Payload
    $cacheScope = if ($payload.PSObject.Properties.Name -contains 'CacheScope' -and -not [string]::IsNullOrWhiteSpace([string]$payload.CacheScope)) {
        [string]$payload.CacheScope
    }
    else { 'Application' }
    if ($cacheScope -notin @('Application', 'ReadOnlyHostInput')) {
        throw "Unsupported payload cache scope: $cacheScope"
    }
    $payloadId = Assert-PayloadHexId -Value ([string]$payload.PayloadId) -Name 'PayloadId'
    $contentKey = Assert-PayloadHexId -Value ([string]$payload.ContentKey) -Name 'ContentKey'
    $expectedManifest = Join-Path (Join-Path $payloadManifestPath $payloadId) ($contentKey + '.json')
    $resolvedManifest = [IO.Path]::GetFullPath([string]$payload.ManifestPath)
    if (-not [string]::Equals($resolvedManifest, [IO.Path]::GetFullPath($expectedManifest), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Payload manifest path does not match its payload and content identities.'
    }
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Payload manifest not found: $resolvedManifest"
    }

    $manifest = Get-Content -Raw -LiteralPath $resolvedManifest -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.ManifestVersion -ne 2) {
        throw 'Unsupported payload manifest version.'
    }
    if ((Assert-PayloadHexId -Value ([string]$manifest.PayloadId) -Name 'Manifest PayloadId') -ne $payloadId -or
        (Assert-PayloadHexId -Value ([string]$manifest.ContentKey) -Name 'Manifest ContentKey') -ne $contentKey) {
        throw 'Payload manifest identity does not match the request.'
    }
    $manifestScope = if ($manifest.PSObject.Properties.Name -contains 'CacheScope' -and -not [string]::IsNullOrWhiteSpace([string]$manifest.CacheScope)) {
        [string]$manifest.CacheScope
    }
    else { 'Application' }
    if ($manifestScope -ne $cacheScope) {
        throw 'Payload manifest cache scope does not match the request.'
    }

    $isDirectory = [bool]$payload.IsDirectory
    if ([bool]$manifest.IsDirectory -ne $isDirectory) {
        throw 'Payload manifest artifact type does not match the request.'
    }
    $artifactPath = [IO.Path]::GetFullPath([string]$payload.ArtifactPath)
    if ($isDirectory) {
        $artifactPath = $artifactPath.TrimEnd('\')
    }
    if (-not [string]::Equals($artifactPath, [IO.Path]::GetFullPath([string]$manifest.ArtifactPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The manifest ArtifactPath does not match the canonical request ArtifactPath.'
    }
    if ((Get-PayloadIdForArtifact -ArtifactPath $artifactPath -IsDirectory $isDirectory -CacheScope $cacheScope) -ne $payloadId) {
        throw 'PayloadId does not identify the canonical ArtifactPath.'
    }

    $artifact = Get-Item -LiteralPath $artifactPath -Force -ErrorAction Stop
    if ([bool]$artifact.PSIsContainer -ne $isDirectory) {
        throw 'ArtifactPath changed between a file and directory after submission.'
    }
    if (($artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'ArtifactPath must not be a symbolic link or other reparse point.'
    }

    $directories = @($manifest.Directories | ForEach-Object { ([string]$_).Replace('\', '/') })
    $files = @($manifest.Files)
    if ($files.Count -eq 0) {
        throw 'The payload manifest contains no files.'
    }
    if ([int]$manifest.DirectoryCount -ne $directories.Count -or [int]$payload.DirectoryCount -ne $directories.Count) {
        throw 'Payload directory count does not match its manifest.'
    }
    if ([int]$manifest.FileCount -ne $files.Count -or [int]$payload.FileCount -ne $files.Count) {
        throw 'Payload file count does not match its manifest.'
    }

    $directorySet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativeDirectory in $directories) {
        $normalizedDirectory = (ConvertTo-SafePayloadRelativePath -RelativePath $relativeDirectory).Replace('\', '/')
        if (-not $directorySet.Add($normalizedDirectory)) {
            throw "Duplicate payload directory: $relativeDirectory"
        }
    }

    $fileSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $totalBytes = [long]0
    foreach ($file in $files) {
        $relativePath = (ConvertTo-SafePayloadRelativePath -RelativePath ([string]$file.RelativePath)).Replace('\', '/')
        $file.RelativePath = $relativePath
        if (-not $fileSet.Add($relativePath)) {
            throw "Duplicate payload file: $relativePath"
        }
        if ($directorySet.Contains($relativePath)) {
            throw "Payload path is both a file and a directory: $relativePath"
        }
        if ([long]$file.Length -lt 0 -or [string]$file.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Payload manifest has invalid file metadata: $relativePath"
        }
        $file.Sha256 = ([string]$file.Sha256).ToUpperInvariant()
        $totalBytes += [long]$file.Length
    }
    if ([long]$manifest.TotalBytes -ne $totalBytes -or [long]$payload.TotalBytes -ne $totalBytes) {
        throw 'Payload byte count does not match its manifest.'
    }
    if ((Get-PayloadContentKeyFromManifest -Files $files -Directories $directories) -ne $contentKey) {
        throw 'Payload manifest content does not match ContentKey.'
    }

    [pscustomobject][ordered]@{
        CacheScope = $cacheScope
        PayloadId = $payloadId
        ContentKey = $contentKey
        ArtifactPath = $artifactPath
        IsDirectory = $isDirectory
        ManifestPath = $resolvedManifest
        Directories = $directories
        Files = $files
        FileCount = $files.Count
        DirectoryCount = $directories.Count
        TotalBytes = $totalBytes
    }
}

function Get-PayloadCacheEntryPaths {
    param([Parameter(Mandatory = $true)] [string] $PayloadId)

    $validatedId = Assert-PayloadHexId -Value $PayloadId -Name 'PayloadId'
    $entryRoot = Join-Path $payloadCachePath $validatedId
    [pscustomobject]@{
        EntryRoot = $entryRoot
        MetadataPath = Join-Path $entryRoot 'cache-entry.json'
    }
}

function Get-PayloadVirtualSize {
    param([Parameter(Mandatory = $true)] [long] $PayloadBytes)

    $minimum = 1GB
    $rawSize = [Math]::Max([double]$minimum, ([double]$PayloadBytes * 1.5) + 512MB)
    $quantum = 64MB
    [long]([Math]::Ceiling($rawSize / $quantum) * $quantum)
}

function Mount-PayloadVhdForSync {
    param(
        [Parameter(Mandatory = $true)] [string] $VhdxPath,
        [Parameter(Mandatory = $true)] [string] $PayloadId
    )

    $mountDirectory = Join-Path $payloadMountPath ($PayloadId + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $mountDirectory | Out-Null
    $accessPath = $mountDirectory.TrimEnd('\') + '\'
    $diskNumber = $null
    $partitionNumber = $null
    try {
        $disk = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop | Get-Disk
        $diskNumber = [int]$disk.Number
        if ($disk.IsOffline) {
            Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction Stop | Out-Null
        }
        if ($disk.IsReadOnly) {
            Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction Stop | Out-Null
        }
        $disk = Get-Disk -Number $diskNumber
        if ([string]$disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop | Out-Null
            $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -ErrorAction Stop
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel ('CODEX-' + $PayloadId.Substring(0, 8)) -Confirm:$false -Force -ErrorAction Stop | Out-Null
        }
        $partition = Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Type -eq 'Basic' -or $_.GptType -eq '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}' } | Sort-Object Size -Descending | Select-Object -First 1
        if (-not $partition) {
            throw "Payload VHDX has no usable data partition: $VhdxPath"
        }
        $partitionNumber = [int]$partition.PartitionNumber
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partitionNumber -AccessPath $accessPath -ErrorAction Stop | Out-Null
        [pscustomobject]@{
            VhdxPath = $VhdxPath
            MountDirectory = $mountDirectory
            AccessPath = $accessPath
            DiskNumber = $diskNumber
            PartitionNumber = $partitionNumber
        }
    }
    catch {
        if ($null -ne $diskNumber -and $null -ne $partitionNumber) {
            Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partitionNumber -AccessPath $accessPath -ErrorAction SilentlyContinue | Out-Null
        }
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $mountDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Dismount-PayloadVhdForSync {
    param([Parameter(Mandatory = $true)] $Mount)

    try {
        Remove-PartitionAccessPath -DiskNumber ([int]$Mount.DiskNumber) -PartitionNumber ([int]$Mount.PartitionNumber) -AccessPath ([string]$Mount.AccessPath) -ErrorAction SilentlyContinue | Out-Null
    }
    finally {
        Dismount-VHD -Path ([string]$Mount.VhdxPath) -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ([string]$Mount.MountDirectory) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ManifestFileMap {
    param([object[]] $Files)

    $map = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Files)) {
        $map[[string]$file.RelativePath] = $file
    }
    Write-Output -NoEnumerate $map
}

function Assert-SourcePayloadFileSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $ArtifactPath,
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [bool] $IsDirectory
    )

    $sourcePath = if ($IsDirectory) { Join-Path $ArtifactPath ($RelativePath.Replace('/', '\')) } else { $ArtifactPath }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
    if ($sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Payload source file changed type or became a reparse point: $sourcePath"
    }
    if ($IsDirectory) {
        $cursor = Split-Path -Parent $sourceItem.FullName
        $artifactPrefix = [IO.Path]::GetFullPath($ArtifactPath).TrimEnd('\') + '\'
        while ($cursor.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $cursorItem = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($cursorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Payload source path traverses a reparse point: $cursor"
            }
            if ([string]::Equals($cursor.TrimEnd('\'), $ArtifactPath.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            $cursor = Split-Path -Parent $cursor
        }
    }
    $sourceItem.FullName
}

function Set-ReadOnlyHostInputPayloadAcl {
    param([Parameter(Mandatory = $true)] [string] $PayloadRoot)

    $acl = Get-Acl -LiteralPath $PayloadRoot -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    $identities = @($acl.Access | ForEach-Object { $_.IdentityReference } | Sort-Object Value -Unique)
    foreach ($identity in $identities) {
        $acl.PurgeAccessRules($identity)
    }

    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $systemRule = New-Object Security.AccessControl.FileSystemAccessRule(
        $systemSid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    )
    $usersRule = New-Object Security.AccessControl.FileSystemAccessRule(
        $usersSid,
        [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize',
        $inheritance,
        $propagation,
        $allow
    )
    [void]$acl.AddAccessRule($systemRule)
    [void]$acl.AddAccessRule($usersRule)
    Set-Acl -LiteralPath $PayloadRoot -AclObject $acl -ErrorAction Stop
}

function Sync-PayloadVolumeIncremental {
    param(
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] [string] $VolumeRoot,
        $PreviousMetadata
    )

    $payloadRoot = Join-Path $VolumeRoot 'Payload'
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
    if ([string]$Manifest.CacheScope -eq 'ReadOnlyHostInput') {
        Set-ReadOnlyHostInputPayloadAcl -PayloadRoot $payloadRoot
    }
    $previousFiles = if ($PreviousMetadata) { @($PreviousMetadata.Files) } else { @() }
    $previousDirectories = if ($PreviousMetadata) { @($PreviousMetadata.Directories) } else { @() }
    $previousMap = Get-ManifestFileMap -Files $previousFiles
    $currentMap = Get-ManifestFileMap -Files @($Manifest.Files)
    $currentDirectorySet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in @($Manifest.Directories)) { [void]$currentDirectorySet.Add([string]$directory) }

    $filesToDelete = @($previousFiles | Where-Object { -not $currentMap.ContainsKey([string]$_.RelativePath) })
    $directoriesToDelete = @($previousDirectories | Where-Object { -not $currentDirectorySet.Contains([string]$_) } | Sort-Object { ([string]$_).Length } -Descending)
    $filesToCopy = @($Manifest.Files | Where-Object {
        $path = [string]$_.RelativePath
        if (-not $previousMap.ContainsKey($path)) { return $true }
        $old = $previousMap[$path]
        [long]$old.Length -ne [long]$_.Length -or -not [string]::Equals([string]$old.Sha256, [string]$_.Sha256, [StringComparison]::OrdinalIgnoreCase)
    })

    foreach ($file in $filesToDelete) {
        $target = Join-Path $payloadRoot (([string]$file.RelativePath).Replace('/', '\'))
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    }
    foreach ($directory in $directoriesToDelete) {
        $target = Join-Path $payloadRoot (([string]$directory).Replace('/', '\'))
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
    foreach ($directory in @($Manifest.Directories | Sort-Object { ([string]$_).Length })) {
        $target = Join-Path $payloadRoot (([string]$directory).Replace('/', '\'))
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
    }
    foreach ($file in $filesToCopy) {
        $relativePath = [string]$file.RelativePath
        $sourcePath = Assert-SourcePayloadFileSafe -ArtifactPath $Manifest.ArtifactPath -RelativePath $relativePath -IsDirectory ([bool]$Manifest.IsDirectory)
        $targetPath = Join-Path $payloadRoot ($relativePath.Replace('/', '\'))
        if (Test-Path -LiteralPath $targetPath -PathType Container) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
        $targetItem = Get-Item -LiteralPath $targetPath -Force
        $actualHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        if ([long]$targetItem.Length -ne [long]$file.Length -or -not [string]::Equals($actualHash, [string]$file.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload source changed while syncing: $relativePath"
        }
    }
    foreach ($file in $filesToDelete) {
        $target = Join-Path $payloadRoot (([string]$file.RelativePath).Replace('/', '\'))
        if (Test-Path -LiteralPath $target) {
            throw "Payload deletion did not apply: $($file.RelativePath)"
        }
    }
    foreach ($directory in $directoriesToDelete) {
        $target = Join-Path $payloadRoot (([string]$directory).Replace('/', '\'))
        if (Test-Path -LiteralPath $target) {
            throw "Payload directory deletion did not apply: $directory"
        }
    }

    $marker = [ordered]@{
        FormatVersion = 2
        CacheScope = [string]$Manifest.CacheScope
        PayloadId = $Manifest.PayloadId
        ContentKey = $Manifest.ContentKey
        ArtifactPath = $Manifest.ArtifactPath
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path (Join-Path $VolumeRoot '.codex-payload.json') -Value $marker

    if (-not $PreviousMetadata) {
        $actualFiles = @(Get-ChildItem -LiteralPath $payloadRoot -File -Force -Recurse)
        if ($actualFiles.Count -ne $Manifest.FileCount) {
            throw "Initial payload cache verification found $($actualFiles.Count) files; expected $($Manifest.FileCount)."
        }
        foreach ($file in @($Manifest.Files)) {
            $targetPath = Join-Path $payloadRoot (([string]$file.RelativePath).Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw "Initial payload cache is missing $($file.RelativePath)."
            }
        }
    }

    [pscustomobject][ordered]@{
        FilesCopied = $filesToCopy.Count
        FilesDeleted = $filesToDelete.Count
        FilesReused = $Manifest.FileCount - $filesToCopy.Count
        DirectoriesDeleted = $directoriesToDelete.Count
    }
}

function Set-PayloadVhdImmutable {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $item.IsReadOnly = $true
}

function Remove-PayloadVhdFileSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Root
    )

    $resolved = Assert-PathInsideRoot -Path $Path -Root $Root -Purpose 'payload VHDX deletion'
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        Dismount-VHD -Path $resolved -ErrorAction SilentlyContinue
        $item = Get-Item -LiteralPath $resolved -Force
        $item.IsReadOnly = $false
        Remove-Item -LiteralPath $resolved -Force
    }
}

function Read-PayloadCacheMetadata {
    param([Parameter(Mandatory = $true)] $Manifest)

    $paths = Get-PayloadCacheEntryPaths -PayloadId $Manifest.PayloadId
    if (-not (Test-Path -LiteralPath $paths.MetadataPath -PathType Leaf)) {
        return $null
    }
    try {
        $metadata = Get-Content -Raw -LiteralPath $paths.MetadataPath -Encoding UTF8 | ConvertFrom-Json
        $manifestScope = if ($Manifest.PSObject.Properties.Name -contains 'CacheScope' -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.CacheScope)) { [string]$Manifest.CacheScope } else { 'Application' }
        $metadataScope = if ($metadata.PSObject.Properties.Name -contains 'CacheScope' -and -not [string]::IsNullOrWhiteSpace([string]$metadata.CacheScope)) { [string]$metadata.CacheScope } else { 'Application' }
        if ([int]$metadata.FormatVersion -ne 2 -or
            (Assert-PayloadHexId -Value ([string]$metadata.PayloadId) -Name 'Cached PayloadId') -ne $Manifest.PayloadId -or
            -not [string]::Equals([string]$metadata.ArtifactPath, [string]$Manifest.ArtifactPath, [StringComparison]::OrdinalIgnoreCase) -or
            [bool]$metadata.IsDirectory -ne [bool]$Manifest.IsDirectory -or
            $metadataScope -ne $manifestScope -or
            ($manifestScope -eq 'ReadOnlyHostInput' -and [int]$metadata.ReadOnlyAclVersion -ne 1)) {
            return $null
        }
        $currentPath = Join-Path $paths.EntryRoot ([string]$metadata.CurrentVhdxName)
        Assert-PathInsideRoot -Path $currentPath -Root $paths.EntryRoot -Purpose 'cached VHDX resolution' | Out-Null
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf) -or -not (Get-Item -LiteralPath $currentPath -Force).IsReadOnly) {
            return $null
        }
        $vhd = Get-VHD -Path $currentPath -ErrorAction Stop
        if ([string]$vhd.VhdFormat -ne 'VHDX') {
            return $null
        }
        $metadata | Add-Member -NotePropertyName CurrentVhdxPath -NotePropertyValue $currentPath -Force
        $metadata
    }
    catch {
        $null
    }
}

function Remove-PayloadCacheEntrySafe {
    param([Parameter(Mandatory = $true)] [string] $PayloadId)

    $paths = Get-PayloadCacheEntryPaths -PayloadId $PayloadId
    Assert-PathInsideRoot -Path $paths.EntryRoot -Root $payloadCachePath -Purpose 'payload cache entry deletion' | Out-Null
    if (Test-Path -LiteralPath $paths.EntryRoot -PathType Container) {
        Get-ChildItem -LiteralPath $paths.EntryRoot -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item -LiteralPath $paths.EntryRoot -Recurse -Force
    }
}

function Compact-PayloadCacheGeneration {
    param(
        [Parameter(Mandatory = $true)] $Metadata,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $RequestId
    )

    $maxDepth = Get-BoundedTimeout -Value $Config.PayloadCacheMaxChainDepth -Default 8 -Minimum 2 -Maximum 32
    if ([int]$Metadata.ChainDepth -lt $maxDepth) {
        return $Metadata
    }
    if (@(Get-ActivePayloadGenerationLeases -PayloadId ([string]$Metadata.PayloadId) -ExcludeRequestId $RequestId).Count -gt 0) {
        return $Metadata
    }
    $paths = Get-PayloadCacheEntryPaths -PayloadId ([string]$Metadata.PayloadId)
    $sourcePath = [string]$Metadata.CurrentVhdxPath
    $compactName = 'compact-{0:D6}-{1}.vhdx' -f ([int]$Metadata.Generation), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $compactPath = Join-Path $paths.EntryRoot $compactName
    try {
        Convert-VHD -Path $sourcePath -DestinationPath $compactPath -VHDType Dynamic -ErrorAction Stop
        $compactVhd = Get-VHD -Path $compactPath -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$compactVhd.ParentPath)) {
            throw 'Compacted payload VHDX unexpectedly retained a parent.'
        }
        Set-PayloadVhdImmutable -Path $compactPath
        $Metadata.CurrentVhdxName = $compactName
        $Metadata.CurrentVhdxPath = $compactPath
        $Metadata.ChainDepth = 1
        $Metadata.LastCompactedUtc = [DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic -Path $paths.MetadataPath -Value $Metadata
        foreach ($oldVhd in Get-ChildItem -LiteralPath $paths.EntryRoot -Filter '*.vhdx' -File -Force) {
            if (-not [string]::Equals($oldVhd.FullName, $compactPath, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-PayloadVhdFileSafe -Path $oldVhd.FullName -Root $paths.EntryRoot
            }
        }
    }
    catch {
        if (Test-Path -LiteralPath $compactPath -PathType Leaf) {
            Remove-PayloadVhdFileSafe -Path $compactPath -Root $paths.EntryRoot
        }
    }
    $Metadata
}

function Get-OrUpdatePayloadCache {
    param(
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )

    $payloadMutex = Get-PayloadCacheMutex -PayloadId ([string]$Manifest.PayloadId)
    $payloadMutexTaken = $false
    try {
    $payloadMutexTaken = Enter-PayloadCacheMutex -Mutex $payloadMutex -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $operationWatch = [Diagnostics.Stopwatch]::StartNew()
    $paths = Get-PayloadCacheEntryPaths -PayloadId $Manifest.PayloadId
    New-Item -ItemType Directory -Force -Path $paths.EntryRoot | Out-Null
    $metadata = Read-PayloadCacheMetadata -Manifest $Manifest
    if ($metadata -and [string]$metadata.CurrentContentKey -eq $Manifest.ContentKey) {
        $metadata.LastAccessUtc = [DateTime]::UtcNow.ToString('o')
        Write-JsonAtomic -Path $paths.MetadataPath -Value $metadata
        $operationWatch.Stop()
        return [pscustomobject][ordered]@{
            ParentVhdx = [string]$metadata.CurrentVhdxPath
            CacheHit = $true
            SyncMode = 'Unchanged'
            FilesCopied = 0
            FilesDeleted = 0
            FilesReused = $Manifest.FileCount
            DirectoriesDeleted = 0
            ChainDepth = [int]$metadata.ChainDepth
            Compacted = $false
            SyncMilliseconds = 0
            CacheOperationMilliseconds = [Math]::Round($operationWatch.Elapsed.TotalMilliseconds, 3)
        }
    }

    $entryHasOrphans = $null -ne (Get-ChildItem -LiteralPath $paths.EntryRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $metadata -and $entryHasOrphans) {
        Remove-PayloadCacheEntrySafe -PayloadId $Manifest.PayloadId
        New-Item -ItemType Directory -Force -Path $paths.EntryRoot | Out-Null
    }
    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $desiredSize = Get-PayloadVirtualSize -PayloadBytes $Manifest.TotalBytes
    $generation = if ($metadata) { [int]$metadata.Generation + 1 } else { 1 }
    $candidateName = 'generation-{0:D6}-{1}.vhdx' -f $generation, $Manifest.ContentKey.Substring(0, 12)
    $candidatePath = Join-Path $paths.EntryRoot $candidateName
    if (Test-Path -LiteralPath $candidatePath) {
        Remove-PayloadVhdFileSafe -Path $candidatePath -Root $paths.EntryRoot
    }
    $syncMode = 'Initial'
    $chainDepth = 1
    $mount = $null
    $syncResult = $null
    $syncStartedUtc = [DateTime]::UtcNow
    try {
        if (-not $metadata) {
            New-VHD -Path $candidatePath -Dynamic -SizeBytes $desiredSize -ErrorAction Stop | Out-Null
        }
        else {
            $currentVhd = Get-VHD -Path ([string]$metadata.CurrentVhdxPath) -ErrorAction Stop
            if ([long]$currentVhd.Size -lt $desiredSize) {
                Convert-VHD -Path ([string]$metadata.CurrentVhdxPath) -DestinationPath $candidatePath -VHDType Dynamic -ErrorAction Stop
                Resize-VHD -Path $candidatePath -SizeBytes $desiredSize -ErrorAction Stop
                $syncMode = 'ExpandedIncremental'
                $chainDepth = 1
            }
            else {
                New-VHD -Path $candidatePath -ParentPath ([string]$metadata.CurrentVhdxPath) -Differencing -ErrorAction Stop | Out-Null
                $syncMode = 'Incremental'
                $chainDepth = [int]$metadata.ChainDepth + 1
            }
        }
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $mount = Mount-PayloadVhdForSync -VhdxPath $candidatePath -PayloadId $Manifest.PayloadId
        $syncResult = Sync-PayloadVolumeIncremental -Manifest $Manifest -VolumeRoot $mount.MountDirectory -PreviousMetadata $metadata
        Dismount-PayloadVhdForSync -Mount $mount
        $mount = $null
        Set-PayloadVhdImmutable -Path $candidatePath

        $now = [DateTime]::UtcNow
        $createdUtc = if ($metadata -and $metadata.CreatedUtc) { [string]$metadata.CreatedUtc } else { $now.ToString('o') }
        $newMetadata = [pscustomobject][ordered]@{
            FormatVersion = 2
            CacheScope = if ([string]::IsNullOrWhiteSpace([string]$Manifest.CacheScope)) { 'Application' } else { [string]$Manifest.CacheScope }
            ReadOnlyAclVersion = if ([string]$Manifest.CacheScope -eq 'ReadOnlyHostInput') { 1 } else { 0 }
            PayloadId = $Manifest.PayloadId
            ArtifactPath = $Manifest.ArtifactPath
            IsDirectory = [bool]$Manifest.IsDirectory
            CurrentContentKey = $Manifest.ContentKey
            CurrentVhdxName = $candidateName
            Generation = $generation
            ChainDepth = $chainDepth
            CreatedUtc = $createdUtc
            LastAccessUtc = $now.ToString('o')
            LastSyncUtc = $now.ToString('o')
            LastCompactedUtc = if ($metadata) { $metadata.LastCompactedUtc } else { $null }
            SyncDurationSeconds = [Math]::Round(($now - $syncStartedUtc).TotalSeconds, 3)
            FileCount = $Manifest.FileCount
            DirectoryCount = $Manifest.DirectoryCount
            TotalBytes = $Manifest.TotalBytes
            Directories = @($Manifest.Directories)
            Files = @($Manifest.Files)
        }
        $newMetadata | Add-Member -NotePropertyName CurrentVhdxPath -NotePropertyValue $candidatePath -Force
        Write-JsonAtomic -Path $paths.MetadataPath -Value $newMetadata
        $beforeCompactPath = $candidatePath
        $newMetadata = Compact-PayloadCacheGeneration -Metadata $newMetadata -Config $Config -RequestId $RequestId
        $compacted = -not [string]::Equals($beforeCompactPath, [string]$newMetadata.CurrentVhdxPath, [StringComparison]::OrdinalIgnoreCase)
        $operationWatch.Stop()
        [pscustomobject][ordered]@{
            ParentVhdx = [string]$newMetadata.CurrentVhdxPath
            CacheHit = $false
            SyncMode = $syncMode
            FilesCopied = [int]$syncResult.FilesCopied
            FilesDeleted = [int]$syncResult.FilesDeleted
            FilesReused = [int]$syncResult.FilesReused
            DirectoriesDeleted = [int]$syncResult.DirectoriesDeleted
            ChainDepth = [int]$newMetadata.ChainDepth
            Compacted = $compacted
            SyncMilliseconds = [Math]::Round(($now - $syncStartedUtc).TotalMilliseconds, 3)
            CacheOperationMilliseconds = [Math]::Round($operationWatch.Elapsed.TotalMilliseconds, 3)
        }
    }
    catch {
        if ($mount) {
            Dismount-PayloadVhdForSync -Mount $mount
        }
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            Remove-PayloadVhdFileSafe -Path $candidatePath -Root $paths.EntryRoot
        }
        throw
    }
    }
    finally {
        if ($payloadMutexTaken) {
            try { $payloadMutex.ReleaseMutex() } catch { }
        }
        $payloadMutex.Dispose()
    }
}

function New-AndAttachPayloadChild {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $ParentVhdx
    )

    $childPath = Join-Path $payloadChildrenPath ($RequestId + '.vhdx')
    Assert-PathInsideRoot -Path $childPath -Root $payloadChildrenPath -Purpose 'payload child creation' | Out-Null
    if (Test-Path -LiteralPath $childPath -PathType Leaf) {
        Remove-PayloadVhdFileSafe -Path $childPath -Root $payloadChildrenPath
    }
    if (-not (Get-Item -LiteralPath $ParentVhdx -Force).IsReadOnly) {
        throw 'Refusing to create a run child from a mutable payload cache generation.'
    }
    New-VHD -Path $childPath -ParentPath $ParentVhdx -Differencing -ErrorAction Stop | Out-Null
    $controller = Get-VMScsiController -VMName $VmName | Sort-Object ControllerNumber | Select-Object -First 1
    if (-not $controller) {
        throw "The test VM has no SCSI controller: $VmName"
    }
    $usedLocations = @(Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.ControllerType -eq 'SCSI' -and $_.ControllerNumber -eq $controller.ControllerNumber } | ForEach-Object { [int]$_.ControllerLocation })
    $location = 0..63 | Where-Object { $usedLocations -notcontains $_ } | Select-Object -First 1
    if ($null -eq $location) {
        throw 'The test VM has no free SCSI location for its disposable payload child.'
    }
    try {
        Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber ([int]$controller.ControllerNumber) -ControllerLocation ([int]$location) -Path $childPath -ErrorAction Stop | Out-Null
        [pscustomobject][ordered]@{
            Path = $childPath
            ControllerNumber = [int]$controller.ControllerNumber
            ControllerLocation = [int]$location
        }
    }
    catch {
        Remove-PayloadVhdFileSafe -Path $childPath -Root $payloadChildrenPath
        throw
    }
}

function Remove-PayloadChildSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $ChildPath
    )

    $resolvedChild = Assert-PathInsideRoot -Path $ChildPath -Root $payloadChildrenPath -Purpose 'payload child cleanup'
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        throw 'The VM must be off before its disposable payload child is detached.'
    }
    foreach ($drive in @(Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -and [string]::Equals([IO.Path]::GetFullPath($_.Path), $resolvedChild, [StringComparison]::OrdinalIgnoreCase) })) {
        Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $resolvedChild -PathType Leaf) {
        Remove-PayloadVhdFileSafe -Path $resolvedChild -Root $payloadChildrenPath
    }
    -not (Test-Path -LiteralPath $resolvedChild)
}

function Reset-PayloadChildrenRootBrokerAcl {
    param([Parameter(Mandatory = $true)] [string] $ClientSid)

    if (-not (Test-Path -LiteralPath $payloadChildrenPath -PathType Container)) {
        throw "Payload child root is missing: $payloadChildrenPath"
    }
    $systemSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $clientSidObject = [Security.Principal.SecurityIdentifier]::new($ClientSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        ))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $clientSidObject,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        $propagation,
        $allow
    ))
    [IO.Directory]::SetAccessControl([IO.Path]::GetFullPath($payloadChildrenPath), $acl)
}

function Recover-OrphanedPayloadChildren {
    param(
        [Parameter(Mandatory = $true)] [string[]] $VmName,
        [Parameter(Mandatory = $true)] [string] $ClientSid
    )

    $childPrefix = [IO.Path]::GetFullPath($payloadChildrenPath).TrimEnd('\') + '\'
    $allOff = $true
    foreach ($name in @($VmName)) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        $attachedChildren = @(Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($childPrefix, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($attachedChildren.Count -gt 0 -and $vm.State -ne 'Off') {
            Stop-TestVm -VmName $name -Immediate
            $vm = Get-VM -Name $name
        }
        if ($vm.State -ne 'Off') {
            $allOff = $false
            continue
        }
        foreach ($drive in $attachedChildren) {
            Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction SilentlyContinue
        }
    }
    if ($allOff) {
        foreach ($child in Get-ChildItem -LiteralPath $payloadChildrenPath -Filter '*.vhdx' -File -ErrorAction SilentlyContinue) {
            try { Remove-PayloadVhdFileSafe -Path $child.FullName -Root $payloadChildrenPath } catch { }
        }
        $remainingAttachments = @(foreach ($name in @($VmName)) {
            Get-VMHardDiskDrive -VMName $name -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($childPrefix, [StringComparison]::OrdinalIgnoreCase)
            }
        })
        if ($remainingAttachments.Count -eq 0) {
            # Hyper-V adds virtualization-service ACEs to this directory while
            # disposable disks are attached. Once every worker is off and no
            # child remains attached, restore the broker's exact declared ACL
            # so an idle pool cannot retain those transient grants.
            Reset-PayloadChildrenRootBrokerAcl -ClientSid $ClientSid
        }
    }
}

function Resolve-GuestPayloadRoot {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] [string] $PayloadId,
        [Parameter(Mandatory = $true)] [string] $ContentKey,
        [switch] $ReadOnly
    )

    $resolved = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
        param($ExpectedPayloadId, $ExpectedContentKey, $MakeReadOnly)
        $usedLetters = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })
        foreach ($disk in @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })) {
            if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction SilentlyContinue | Out-Null }
            foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object Type -eq 'Basic')) {
                $letter = [string]$partition.DriveLetter
                if ([string]::IsNullOrWhiteSpace($letter)) {
                    $letter = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z') | Where-Object { $usedLetters -notcontains $_ } | Select-Object -First 1
                    if ($letter) {
                        Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $letter -ErrorAction SilentlyContinue | Out-Null
                        $usedLetters += $letter
                    }
                }
                if (-not $letter) { continue }
                $markerPath = "$letter`:\.codex-payload.json"
                if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
                try {
                    $marker = Get-Content -Raw -LiteralPath $markerPath -Encoding UTF8 | ConvertFrom-Json
                    $payloadRoot = "$letter`:\Payload"
                    if ([string]$marker.PayloadId -eq $ExpectedPayloadId -and [string]$marker.ContentKey -eq $ExpectedContentKey -and (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
                        if ($MakeReadOnly -and -not $disk.IsReadOnly) {
                            Set-Disk -Number $disk.Number -IsReadOnly $true -ErrorAction Stop | Out-Null
                        }
                        elseif (-not $MakeReadOnly -and $disk.IsReadOnly) {
                            Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop | Out-Null
                        }
                        return [pscustomobject]@{ PayloadRoot = $payloadRoot; DiskNumber = $disk.Number; DriveLetter = $letter }
                    }
                }
                catch { }
            }
        }
        $null
    } -ArgumentList $PayloadId, $ContentKey, ([bool]$ReadOnly) | Select-Object -Last 1
    if (-not $resolved -or [string]::IsNullOrWhiteSpace([string]$resolved.PayloadRoot)) {
        throw 'The guest could not locate the attached immutable payload generation.'
    }
    [string]$resolved.PayloadRoot
}

function Get-ProtectedPayloadIds {
    $protected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($requestPath, $processingPath)) {
        foreach ($requestFile in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try {
                $queued = Get-Content -Raw -LiteralPath $requestFile.FullName -Encoding UTF8 | ConvertFrom-Json
                if ([string]$queued.Payload.PayloadId -match '^[A-Fa-f0-9]{64}$') {
                    [void]$protected.Add(([string]$queued.Payload.PayloadId).ToUpperInvariant())
                }
            }
            catch { }
        }
    }
    foreach ($child in Get-ChildItem -LiteralPath $payloadChildrenPath -Filter '*.vhdx' -File -ErrorAction SilentlyContinue) {
        try {
            $parentPath = [string](Get-VHD -Path $child.FullName -ErrorAction Stop).ParentPath
            $cachePrefix = [IO.Path]::GetFullPath($payloadCachePath).TrimEnd('\') + '\'
            $resolvedParent = [IO.Path]::GetFullPath($parentPath)
            if ($resolvedParent.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $resolvedParent.Substring($cachePrefix.Length)
                $id = $relative.Split('\')[0]
                if ($id -match '^[A-Fa-f0-9]{64}$') { [void]$protected.Add($id.ToUpperInvariant()) }
            }
        }
        catch { }
    }
    foreach ($leaseFile in Get-ChildItem -LiteralPath $payloadLeasePath -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $lease = Get-Content -Raw -LiteralPath $leaseFile.FullName -Encoding UTF8 | ConvertFrom-Json
            if ([string]$lease.PayloadId -match '^[A-Fa-f0-9]{64}$') {
                [void]$protected.Add(([string]$lease.PayloadId).ToUpperInvariant())
            }
        }
        catch { }
    }
    Write-Output -NoEnumerate $protected
}

function Invoke-PayloadCacheGarbageCollection {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string[]] $VmName
    )

    $startedUtc = [DateTime]::UtcNow
    $evicted = New-Object Collections.Generic.List[object]
    $orphanedFilesRemoved = 0
    $runningVmNames = @($VmName | Where-Object { (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -ne 'Off' })
    if ($runningVmNames.Count -gt 0) {
        Write-JsonAtomic -Path $payloadGcStatePath -Value ([ordered]@{
            Status = 'SkippedVmRunning'
            RunningVmNames = $runningVmNames
            StartedUtc = $startedUtc.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
        })
        return
    }
    Recover-OrphanedPayloadChildren -VmName $VmName -ClientSid ([string]$Config.ClientSid)
    foreach ($leaseFile in Get-ChildItem -LiteralPath $payloadLeasePath -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $lease = Get-Content -Raw -LiteralPath $leaseFile.FullName -Encoding UTF8 | ConvertFrom-Json
            $requestId = [string]$lease.RequestId
            $requestActive = (Test-Path -LiteralPath (Join-Path $requestPath ($requestId + '.json')) -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $processingPath ($requestId + '.json')) -PathType Leaf)
            $childExists = -not [string]::IsNullOrWhiteSpace([string]$lease.ChildVhdx) -and (Test-Path -LiteralPath ([string]$lease.ChildVhdx) -PathType Leaf)
            $processAlive = $false
            if ($lease.ProcessId) {
                $processAlive = $null -ne (Get-Process -Id ([int]$lease.ProcessId) -ErrorAction SilentlyContinue)
            }
            if (-not $requestActive -and -not $childExists -and -not $processAlive) {
                Remove-Item -LiteralPath $leaseFile.FullName -Force -ErrorAction SilentlyContinue
                $orphanedFilesRemoved++
            }
        }
        catch { }
    }
    $protected = Get-ProtectedPayloadIds
    $maxAgeDays = Get-BoundedTimeout -Value $Config.PayloadCacheMaxAgeDays -Default 30 -Minimum 1 -Maximum 365
    $maxBytes = if ($Config.PayloadCacheMaxBytes) { [long]$Config.PayloadCacheMaxBytes } else { [long]64GB }
    $targetBytes = if ($Config.PayloadCacheTargetBytes) { [long]$Config.PayloadCacheTargetBytes } else { [long]56GB }
    if ($targetBytes -gt $maxBytes) { $targetBytes = $maxBytes }
    $ageCutoff = [DateTime]::UtcNow.AddDays(-$maxAgeDays)
    $candidates = New-Object Collections.Generic.List[object]
    foreach ($entry in Get-ChildItem -LiteralPath $payloadCachePath -Directory -ErrorAction SilentlyContinue) {
        if ($entry.Name -notmatch '^[A-Fa-f0-9]{64}$') { continue }
        $metadataPath = Join-Path $entry.FullName 'cache-entry.json'
        $lastAccessUtc = $entry.LastWriteTimeUtc
        try {
            if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
                $entryMetadata = Get-Content -Raw -LiteralPath $metadataPath -Encoding UTF8 | ConvertFrom-Json
                $lastAccessUtc = [DateTime]::Parse([string]$entryMetadata.LastAccessUtc).ToUniversalTime()
            }
        }
        catch { }
        $physicalBytes = [long](Get-ChildItem -LiteralPath $entry.FullName -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $candidates.Add([pscustomobject]@{ PayloadId = $entry.Name.ToUpperInvariant(); Path = $entry.FullName; LastAccessUtc = $lastAccessUtc; PhysicalBytes = $physicalBytes })
    }
    foreach ($candidate in @($candidates | Where-Object { -not $protected.Contains($_.PayloadId) -and $_.LastAccessUtc -lt $ageCutoff } | Sort-Object LastAccessUtc)) {
        Remove-PayloadCacheEntrySafe -PayloadId $candidate.PayloadId
        $evicted.Add([pscustomobject]@{ PayloadId = $candidate.PayloadId; Reason = 'Age'; PhysicalBytes = $candidate.PhysicalBytes })
        [void]$candidates.Remove($candidate)
    }
    $totalBytes = [long](($candidates | Measure-Object PhysicalBytes -Sum).Sum)
    if ($totalBytes -gt $maxBytes) {
        foreach ($candidate in @($candidates | Where-Object { -not $protected.Contains($_.PayloadId) } | Sort-Object LastAccessUtc)) {
            if ($totalBytes -le $targetBytes) { break }
            Remove-PayloadCacheEntrySafe -PayloadId $candidate.PayloadId
            $totalBytes -= [long]$candidate.PhysicalBytes
            $evicted.Add([pscustomobject]@{ PayloadId = $candidate.PayloadId; Reason = 'Size'; PhysicalBytes = $candidate.PhysicalBytes })
            [void]$candidates.Remove($candidate)
        }
    }

    $temporaryCutoff = [DateTime]::UtcNow.AddHours(-1)
    foreach ($temporary in Get-ChildItem -LiteralPath $payloadCacheTempPath -File -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTimeUtc -lt $temporaryCutoff) {
        try { Remove-PayloadVhdFileSafe -Path $temporary.FullName -Root $payloadCacheTempPath; $orphanedFilesRemoved++ } catch { }
    }
    foreach ($temporaryManifest in Get-ChildItem -LiteralPath $payloadManifestPath -Filter '*.tmp' -File -Force -Recurse -ErrorAction SilentlyContinue | Where-Object LastWriteTimeUtc -lt $temporaryCutoff) {
        Remove-Item -LiteralPath $temporaryManifest.FullName -Force -ErrorAction SilentlyContinue
        $orphanedFilesRemoved++
    }
    foreach ($mountDirectory in Get-ChildItem -LiteralPath $payloadMountPath -Directory -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTimeUtc -lt $temporaryCutoff) {
        try { Remove-Item -LiteralPath $mountDirectory.FullName -Recurse -Force; $orphanedFilesRemoved++ } catch { }
    }
    foreach ($manifestDirectory in Get-ChildItem -LiteralPath $payloadManifestPath -Directory -ErrorAction SilentlyContinue) {
        $hasCache = Test-Path -LiteralPath (Join-Path $payloadCachePath $manifestDirectory.Name) -PathType Container
        if (-not $hasCache -and -not $protected.Contains($manifestDirectory.Name)) {
            foreach ($manifestFile in Get-ChildItem -LiteralPath $manifestDirectory.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object LastWriteTimeUtc -lt ([DateTime]::UtcNow.AddDays(-1))) {
                Remove-Item -LiteralPath $manifestFile.FullName -Force -ErrorAction SilentlyContinue
                $orphanedFilesRemoved++
            }
            if (-not (Get-ChildItem -LiteralPath $manifestDirectory.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                Remove-Item -LiteralPath $manifestDirectory.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-JsonAtomic -Path $payloadGcStatePath -Value ([ordered]@{
        Status = 'Completed'
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        MaxAgeDays = $maxAgeDays
        MaxBytes = $maxBytes
        TargetBytes = $targetBytes
        RemainingPhysicalBytes = $totalBytes
        ProtectedPayloadIds = @($protected | ForEach-Object { [string]$_ })
        Evicted = $evicted.ToArray()
        OrphanedFilesRemoved = $orphanedFilesRemoved
    })
}
