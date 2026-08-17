[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SkillSourceRoot,
    [string] $PolicyBlockPath,
    [Parameter(Mandatory = $true)] [string] $TargetUserProfile,
    [Parameter(Mandatory = $true)] [string] $TargetUserSid,
    [switch] $SkipGlobalPolicy,
    [switch] $FingerprintOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExistingFileSystemItem {
    param([Parameter(Mandatory = $true)] [string] $Path)

    try { Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { $null }
    catch [IO.FileNotFoundException] { $null }
    catch [IO.DirectoryNotFoundException] { $null }
    catch { throw "Unable to inspect user-integration path '$Path': $($_.Exception.Message)" }
}

function Test-IsReparsePoint {
    param([Parameter(Mandatory = $true)] [IO.FileSystemInfo] $Item)

    (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-PathChain {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    $reverse = New-Object 'Collections.Generic.List[string]'
    while ($null -ne $current) {
        [void]$reverse.Add($current.FullName)
        if ([string]::Equals($current.FullName, $current.Root.FullName, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = $current.Parent
    }
    for ($index = $reverse.Count - 1; $index -ge 0; $index--) { $reverse[$index] }
}

function Assert-NoReparsePointChain {
    param([Parameter(Mandatory = $true)] [string] $Path)

    foreach ($ancestor in @(Get-PathChain -Path $Path)) {
        $item = Get-ExistingFileSystemItem -Path $ancestor
        if ($null -eq $item) { continue }
        if (-not $item.PSIsContainer) { throw "User-integration path ancestor is not a directory: $ancestor" }
        if (Test-IsReparsePoint -Item $item) { throw "User-integration path contains a reparse point: $ancestor" }
    }
}

function Ensure-SafeDirectoryChain {
    param([Parameter(Mandatory = $true)] [string] $Path)

    foreach ($ancestor in @(Get-PathChain -Path $Path)) {
        $item = Get-ExistingFileSystemItem -Path $ancestor
        if ($null -eq $item) {
            [IO.Directory]::CreateDirectory($ancestor) | Out-Null
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        }
        if (-not $item.PSIsContainer) { throw "User-integration destination parent is not a directory: $ancestor" }
        if (Test-IsReparsePoint -Item $item) { throw "User-integration destination parent contains a reparse point: $ancestor" }
    }
}

function Get-ContentTreeInventory {
    param([Parameter(Mandatory = $true)] [string] $Root)

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    Assert-NoReparsePointChain -Path $resolvedRoot
    $rootItem = Get-Item -LiteralPath $resolvedRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw "Content-tree root is not a directory: $resolvedRoot" }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $records = New-Object 'Collections.Generic.List[string]'
    [void]$pending.Push($resolvedRoot)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (Test-IsReparsePoint -Item $child) { throw "Content tree contains a reparse point: $($child.FullName)" }
            $relative = $child.FullName.Substring($resolvedRoot.Length).TrimStart('\').Replace('\', '/')
            if ($child.PSIsContainer) {
                [void]$records.Add('D' + "`t" + $relative)
                [void]$pending.Push($child.FullName)
                continue
            }
            $alternateStreams = @(Get-Item -LiteralPath $child.FullName -Stream * -ErrorAction Stop | Where-Object { [string]$_.Stream -ne ':$DATA' })
            if ($alternateStreams.Count -gt 0) { throw "Content tree contains an alternate data stream: $($child.FullName)" }
            [void]$records.Add('F' + "`t" + $relative + "`t" + (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256 -ErrorAction Stop).Hash)
        }
    }
    @($records | Sort-Object)
}

function Get-ContentTreeFingerprint {
    param([Parameter(Mandatory = $true)] [string] $Root)

    $inventory = @(Get-ContentTreeInventory -Root $Root)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($inventory -join "`n"))
        [pscustomobject][ordered]@{
            Fingerprint = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
            RecordCount = $inventory.Count
            Inventory = $inventory
        }
    }
    finally { $sha.Dispose() }
}

function Get-FileFingerprint {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-NoReparsePointChain -Path (Split-Path -Parent $fullPath)
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (Test-IsReparsePoint -Item $item)) { throw "Policy source must be one regular file: $Path" }
    $alternateStreams = @(Get-Item -LiteralPath $item.FullName -Stream * -ErrorAction Stop | Where-Object { [string]$_.Stream -ne ':$DATA' })
    if ($alternateStreams.Count -gt 0) { throw "Policy source contains an alternate data stream: $Path" }
    (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    & robocopy.exe $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "Robocopy failed with exit code $LASTEXITCODE while staging '$Source'." }
}

function Remove-SafeTree {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $item = Get-ExistingFileSystemItem -Path $Path
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer) { throw "Refusing to remove a non-directory transaction path: $Path" }
    $null = Get-ContentTreeInventory -Root $Path
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) { throw "Transaction cleanup did not remove: $Path" }
}

function Install-RuntimeSkillForCurrentUser {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination
    )

    $sourceBefore = Get-ContentTreeFingerprint -Root $Source
    $destinationParent = Split-Path -Parent $Destination
    Ensure-SafeDirectoryChain -Path $destinationParent
    Assert-NoReparsePointChain -Path $Destination
    $existingDestination = Get-ExistingFileSystemItem -Path $Destination
    if ($existingDestination -and (-not $existingDestination.PSIsContainer -or (Test-IsReparsePoint -Item $existingDestination))) {
        throw "Runtime skill destination is not one regular directory: $Destination"
    }
    $destinationBefore = if ($existingDestination) { Get-ContentTreeFingerprint -Root $Destination } else { $null }
    $stage = Join-Path $destinationParent ('RuntimeSkillStage-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $destinationParent ('RuntimeSkillBackup-' + [Guid]::NewGuid().ToString('N'))
    $stageCreated = $false
    $destinationMoved = $false
    $stageMoved = $false
    $backupRetired = $false
    try {
        if ((Get-ExistingFileSystemItem -Path $stage) -or (Get-ExistingFileSystemItem -Path $backup)) { throw 'A random runtime-skill transaction path already exists.' }
        Invoke-RobocopyMirror -Source $Source -Destination $stage
        $stageCreated = $true
        $stageInventory = Get-ContentTreeFingerprint -Root $stage
        $sourceAfter = Get-ContentTreeFingerprint -Root $Source
        if ($sourceBefore.Fingerprint -cne $sourceAfter.Fingerprint -or $sourceBefore.Fingerprint -cne $stageInventory.Fingerprint) {
            throw 'The runtime skill source changed while it was staged, or the staged tree differs.'
        }
        if ($existingDestination) {
            Assert-NoReparsePointChain -Path $Destination
            [IO.Directory]::Move($Destination, $backup)
            $destinationMoved = $true
        }
        if (Get-ExistingFileSystemItem -Path $Destination) { throw "Runtime skill destination unexpectedly exists: $Destination" }
        [IO.Directory]::Move($stage, $Destination)
        $stageMoved = $true
        $finalInventory = Get-ContentTreeFingerprint -Root $Destination
        if ($sourceBefore.Fingerprint -cne $finalInventory.Fingerprint) { throw 'The installed runtime skill differs from the stable source snapshot.' }
        $result = [pscustomobject][ordered]@{
            Path = $Destination
            Fingerprint = [string]$finalInventory.Fingerprint
            RecordCount = [int]$finalInventory.RecordCount
            HashVerified = $true
        }
        if ($destinationMoved) {
            Remove-SafeTree -Path $backup
            $backupRetired = $true
        }
        $result
    }
    catch {
        $original = $_
        $rollbackErrors = New-Object 'Collections.Generic.List[string]'
        if ($stageMoved) {
            try { Remove-SafeTree -Path $Destination } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        elseif ($stageCreated) {
            try { Remove-SafeTree -Path $stage } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        if ($destinationMoved -and -not $backupRetired) {
            try {
                if (Get-ExistingFileSystemItem -Path $Destination) { throw "Runtime skill destination exists during rollback: $Destination" }
                $backupInventory = Get-ContentTreeFingerprint -Root $backup
                if ($null -eq $destinationBefore -or $backupInventory.Fingerprint -cne $destinationBefore.Fingerprint) {
                    throw 'Runtime skill backup changed before rollback.'
                }
                [IO.Directory]::Move($backup, $Destination)
                $destinationMoved = $false
            }
            catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Runtime skill installation failed and rollback remains incomplete. Original: $($original.Exception.Message) Rollback: $($rollbackErrors -join '; ')"
        }
        throw $original
    }
}

function Install-ManagedPolicyForCurrentUser {
    param(
        [Parameter(Mandatory = $true)] [string] $BlockPath,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [string] $ExpectedFingerprint
    )

    $fingerprintBefore = Get-FileFingerprint -Path $BlockPath
    if ($fingerprintBefore -cne $ExpectedFingerprint) { throw 'The managed policy source changed before installation.' }
    $block = (Get-Content -LiteralPath $BlockPath -Raw -ErrorAction Stop).Trim()
    $fingerprintAfter = Get-FileFingerprint -Path $BlockPath
    if ($fingerprintAfter -cne $fingerprintBefore) { throw 'The managed policy source changed while it was read.' }
    $startMarker = '<!-- BEGIN CODEX HYPERV TEST HARNESS -->'
    $endMarker = '<!-- END CODEX HYPERV TEST HARNESS -->'
    $parent = Split-Path -Parent $Destination
    Ensure-SafeDirectoryChain -Path $parent
    $destinationItem = Get-ExistingFileSystemItem -Path $Destination
    if ($destinationItem -and ($destinationItem.PSIsContainer -or (Test-IsReparsePoint -Item $destinationItem))) {
        throw "Managed policy destination is not one regular file: $Destination"
    }
    $existing = if ($destinationItem) { Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop } else { '' }
    $pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ([regex]::IsMatch($existing, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $updated = [regex]::Replace($existing, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, [Text.RegularExpressions.RegexOptions]::Singleline)
    }
    else {
        $updated = $existing.TrimEnd() + $(if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }) + $block + "`r`n"
    }
    $temporary = Join-Path $parent ('.codex-hyperv-policy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.codex-hyperv-policy-' + [Guid]::NewGuid().ToString('N') + '.bak')
    $replacementCommitted = $false
    $newFileCommitted = $false
    try {
        [IO.File]::WriteAllText($temporary, $updated, (New-Object Text.UTF8Encoding($false)))
        if ($destinationItem) {
            [IO.File]::Replace($temporary, $Destination, $backup, $true)
            $replacementCommitted = $true
        }
        else {
            [IO.File]::Move($temporary, $Destination)
            $newFileCommitted = $true
        }
        $installed = [IO.File]::ReadAllText($Destination)
        if ($installed -cne $updated) { throw 'The installed managed policy differs from the verified replacement content.' }
        if ($replacementCommitted) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $backup) { throw 'Managed policy backup retirement did not complete.' }
            $replacementCommitted = $false
        }
    }
    catch {
        $original = $_
        $rollbackErrors = New-Object 'Collections.Generic.List[string]'
        if ($replacementCommitted -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            try {
                $failedReplacement = Join-Path $parent ('.codex-hyperv-policy-' + [Guid]::NewGuid().ToString('N') + '.failed')
                [IO.File]::Replace($backup, $Destination, $failedReplacement, $true)
                if (Test-Path -LiteralPath $failedReplacement -PathType Leaf) { Remove-Item -LiteralPath $failedReplacement -Force -ErrorAction Stop }
                $replacementCommitted = $false
            }
            catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        elseif ($newFileCommitted) {
            try { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
        }
        foreach ($residue in @($temporary, $backup)) {
            if (Test-Path -LiteralPath $residue -PathType Leaf) {
                try { Remove-Item -LiteralPath $residue -Force -ErrorAction Stop } catch { [void]$rollbackErrors.Add($_.Exception.Message) }
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Managed policy installation failed and rollback remains incomplete. Original: $($original.Exception.Message) Rollback: $($rollbackErrors -join '; ')"
        }
        throw $original
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
    }
    [pscustomobject][ordered]@{ Path = $Destination; BlockFingerprint = $fingerprintAfter }
}

$skillSource = [IO.Path]::GetFullPath($SkillSourceRoot).TrimEnd('\')
$profile = [IO.Path]::GetFullPath($TargetUserProfile).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($profile) -or [IO.Path]::GetPathRoot($profile) -eq $profile) { throw 'TargetUserProfile must be a specific non-root directory.' }
try { $targetSidObject = [Security.Principal.SecurityIdentifier]::new($TargetUserSid) } catch { throw "Invalid target-user SID: $TargetUserSid" }
if (-not (Test-Path -LiteralPath (Join-Path $skillSource 'SKILL.md') -PathType Leaf)) { throw "Runtime skill source is incomplete: $skillSource" }
$skillFingerprint = Get-ContentTreeFingerprint -Root $skillSource
$policyFingerprint = if ($SkipGlobalPolicy) { $null } else {
    if ([string]::IsNullOrWhiteSpace($PolicyBlockPath)) { throw 'PolicyBlockPath is required unless SkipGlobalPolicy is set.' }
    Get-FileFingerprint -Path $PolicyBlockPath
}
if ($FingerprintOnly) {
    [pscustomobject][ordered]@{
        SkillFingerprint = [string]$skillFingerprint.Fingerprint
        SkillRecordCount = [int]$skillFingerprint.RecordCount
        PolicyFingerprint = $policyFingerprint
    }
    return
}
if (Test-Administrator) { throw 'User-profile integration must run from the target user''s unelevated process.' }
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
if ($currentSid -ne $targetSidObject) { throw 'TargetUserSid must match the current unelevated user.' }
$currentProfile = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\')
if (-not [string]::Equals($currentProfile, $profile, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'TargetUserProfile must match the current unelevated user profile.'
}
Assert-NoReparsePointChain -Path $profile
$skillDestination = Join-Path $profile '.agents\skills\hyperv-test-executables'
if (-not ($skillDestination + '\').StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime skill destination escapes TargetUserProfile.' }
$skillResult = Install-RuntimeSkillForCurrentUser -Source $skillSource -Destination $skillDestination
$policyResult = if ($SkipGlobalPolicy) { $null } else {
    Install-ManagedPolicyForCurrentUser -BlockPath ([IO.Path]::GetFullPath($PolicyBlockPath)) -Destination (Join-Path $profile '.codex\AGENTS.md') -ExpectedFingerprint $policyFingerprint
}
[pscustomobject][ordered]@{
    Success = $true
    TargetUserSid = [string]$currentSid.Value
    TargetUserProfile = $profile
    Skill = $skillResult
    Policy = $policyResult
    SkillFingerprint = [string]$skillResult.Fingerprint
    PolicyFingerprint = $policyFingerprint
}
