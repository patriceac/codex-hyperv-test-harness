[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $ActiveBrokerRoot,
    [string] $TargetUserProfile = $env:USERPROFILE,
    [ValidateSet('FullExport','ReuseCurrent')] [string] $BaselineExportMode = 'FullExport',
    [switch] $NoElevation
)

$ErrorActionPreference = 'Stop'
$softwareRoot = Split-Path -Parent $PSScriptRoot
$harnessRoot = Join-Path $softwareRoot 'Harness'
. (Join-Path $harnessRoot 'HarnessPaths.ps1')
. (Join-Path $PSScriptRoot 'RecoveryCommon.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($ActiveBrokerRoot)) { $ActiveBrokerRoot = [string]$layout.BrokerRoot }
$statusPath = Join-Path ([string]$layout.RecoveryRoot) 'last-refresh.json'

if (-not (Test-CodexAdministrator)) {
    if ($NoElevation) { throw 'Recovery refresh requires administrator rights.' }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PSCommandPath + '"'),
        '-ConfigPath', ('"' + $layout.ConfigPath + '"'),
        '-ActiveBrokerRoot', ('"' + $ActiveBrokerRoot + '"'),
        '-TargetUserProfile', ('"' + $TargetUserProfile + '"'),
        '-BaselineExportMode', $BaselineExportMode,
        '-NoElevation'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}

$taskName = [string]$layout.BrokerTaskName
$recoveryRoot = [IO.Path]::GetFullPath([string]$layout.RecoveryRoot)
$stagingParent = Assert-CodexPathWithin -Path (Join-Path $recoveryRoot 'Staging') -Parent ([string]$layout.InstallRoot) -ExpectedLeaf 'Staging'
$currentRoot = Assert-CodexPathWithin -Path (Join-Path $recoveryRoot 'Current') -Parent $recoveryRoot -ExpectedLeaf 'Current'
$previousRoot = Assert-CodexPathWithin -Path (Join-Path $recoveryRoot 'Previous') -Parent $recoveryRoot -ExpectedLeaf 'Previous'
$successfulRefreshPath = Join-Path $recoveryRoot 'last-successful-refresh.json'
$bundleId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stagingRoot = Assert-CodexPathWithin -Path (Join-Path $stagingParent ('bundle-' + $bundleId)) -Parent $stagingParent
$maintenancePath = Join-Path $ActiveBrokerRoot 'State\maintenance.json'
$taskWasRunning = $false
$maintenanceCreated = $false
$startedUtc = [DateTime]::UtcNow
$knownEntries = @{}
$hardLinkedPaths = New-Object Collections.Generic.List[string]
$trustedBaselinePaths = New-Object Collections.Generic.List[string]
$priorManifest = $null
$priorManifestMap = @{}
$priorManifestSha256 = $null
$priorIntegrity = $null
$priorReceipt = $null
$baselineExportSourceBundleId = $null
$baselineExportDisposition = 'FullExport'

function Write-RefreshStatus {
    param([bool] $Success, [string] $Message, $Details)
    $status = [ordered]@{
        Success = $Success
        Message = $Message
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        BundleId = $bundleId
        CurrentRoot = $currentRoot
        Details = $Details
    }
    Write-CodexJsonAtomic -Path $statusPath -Value $status
    if ($Success) { Write-CodexJsonAtomic -Path $successfulRefreshPath -Value $status }
}

function Add-KnownEntry {
    param([Parameter(Mandatory = $true)] $Entry)

    $relative = ([string]$Entry.RelativePath).Replace('\', '/')
    if ($knownEntries.ContainsKey($relative)) { throw "Duplicate staged recovery path: $relative" }
    $knownEntries[$relative] = $Entry
    if ($Entry.PSObject.Properties['ReusedByHardLink'] -and [bool]$Entry.ReusedByHardLink) {
        $hardLinkedPaths.Add($relative)
    }
}

function Get-MatchingRecoveryReceipt {
    param(
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] [string] $ManifestSha256
    )

    foreach ($candidate in @(
        [pscustomobject]@{ Path = $successfulRefreshPath; Kind = 'SuccessfulRefresh' },
        [pscustomobject]@{ Path = $statusPath; Kind = 'LegacyRefresh' },
        [pscustomobject]@{ Path = (Join-Path $recoveryRoot 'last-verification.json'); Kind = 'DeepVerification' }
    )) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        try { $receipt = Get-Content -LiteralPath $candidate.Path -Raw | ConvertFrom-Json } catch { continue }
        if (-not [bool]$receipt.Success -or -not [string]::Equals([string]$receipt.BundleId, [string]$Manifest.BundleId, [StringComparison]::Ordinal)) { continue }
        if ($candidate.Kind -eq 'DeepVerification') {
            if ([bool]$receipt.ContentHashesSkipped -or [int]$receipt.VerifiedFiles -ne [int]$Manifest.FileCount -or [long]$receipt.VerifiedBytes -ne [long]$Manifest.TotalBytes) { continue }
        }
        else {
            if ($receipt.Details.PSObject.Properties['FileCount'] -and [int]$receipt.Details.FileCount -ne [int]$Manifest.FileCount) { continue }
            if ($receipt.Details.PSObject.Properties['TotalBytes'] -and [long]$receipt.Details.TotalBytes -ne [long]$Manifest.TotalBytes) { continue }
            if ($receipt.Details.PSObject.Properties['ManifestSha256'] -and
                -not [string]::Equals([string]$receipt.Details.ManifestSha256, $ManifestSha256, [StringComparison]::OrdinalIgnoreCase)) { continue }
        }
        return [pscustomobject][ordered]@{ Kind = [string]$candidate.Kind; Path = [string]$candidate.Path }
    }
    $null
}

try {
    Import-Module Hyper-V -ErrorAction Stop
    New-Item -ItemType Directory -Force -Path $recoveryRoot, $stagingParent | Out-Null
    foreach ($stale in @(Get-ChildItem -LiteralPath $stagingParent -Directory -Force -Filter 'bundle-*' -ErrorAction SilentlyContinue)) {
        [void](Assert-CodexPathWithin -Path $stale.FullName -Parent $stagingParent)
        Remove-Item -LiteralPath $stale.FullName -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

    $currentManifestPath = Join-Path $currentRoot 'manifest.json'
    if (Test-Path -LiteralPath $currentManifestPath -PathType Leaf) {
        try {
            $priorIntegrity = Test-CodexRecoveryBundleIntegrity -BundleRoot $currentRoot -SkipContentHashes
            if (-not $priorIntegrity.Success) { throw ($priorIntegrity.Failures -join '; ') }
            $priorManifest = $priorIntegrity.Manifest
            $priorManifestMap = Get-CodexRecoveryManifestFileMap -Manifest $priorManifest
            $priorManifestSha256 = (Get-FileHash -LiteralPath $currentManifestPath -Algorithm SHA256).Hash
            $priorReceipt = Get-MatchingRecoveryReceipt -Manifest $priorManifest -ManifestSha256 $priorManifestSha256
        }
        catch {
            if ($BaselineExportMode -eq 'ReuseCurrent') {
                throw "ReuseCurrent requires a structurally valid Current recovery generation: $($_.Exception.Message)"
            }
            $priorIntegrity = $null
            $priorManifest = $null
            $priorManifestMap = @{}
            $priorManifestSha256 = $null
            $priorReceipt = $null
        }
    }
    if ($BaselineExportMode -eq 'ReuseCurrent' -and $null -eq $priorManifest) {
        throw 'ReuseCurrent requires Recovery\Current with a valid manifest; use a reviewed FullExport plan instead.'
    }
    if ($BaselineExportMode -eq 'ReuseCurrent' -and $null -eq $priorReceipt) {
        throw 'ReuseCurrent requires a successful matching refresh or deep-verification receipt; use a reviewed FullExport plan instead.'
    }

    if (Test-Path -LiteralPath $ActiveBrokerRoot -PathType Container) {
        $queued = @(Get-ChildItem -LiteralPath (Join-Path $ActiveBrokerRoot 'Requests') -Filter '*.json' -File -ErrorAction SilentlyContinue)
        $processing = @(Get-ChildItem -LiteralPath (Join-Path $ActiveBrokerRoot 'Processing') -Filter '*.json' -File -ErrorAction SilentlyContinue)
        if ($queued.Count -gt 0 -or $processing.Count -gt 0) {
            throw "Recovery refresh requires an empty queue; queued=$($queued.Count), processing=$($processing.Count)."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $maintenancePath) | Out-Null
        Write-CodexJsonAtomic -Path $maintenancePath -Value ([ordered]@{
            Status = 'MaintenanceRequested'
            Reason = 'Building a verified one-click recovery bundle.'
            RequestedUtc = [DateTime]::UtcNow.ToString('o')
        })
        $maintenanceCreated = $true
    }

    $workerNames = @(1..([int]$layout.PoolSize) | ForEach-Object { '{0}-{1:D2}' -f ([string]$layout.PoolVmPrefix), $_ })
    $workerDrainDeadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        $runningWorkers = @($workerNames | ForEach-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue } | Where-Object State -ne 'Off')
        if ($runningWorkers.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $workerDrainDeadline)
    foreach ($runningWorker in @($runningWorkers)) {
        Stop-VM -Name $runningWorker.Name -TurnOff -Force -ErrorAction Stop | Out-Null
    }

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        $taskWasRunning = $true
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        } while ($task -and $task.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline)
        if ($task -and $task.State -eq 'Running') { throw 'The broker task did not stop for recovery export.' }
    }

    foreach ($workerId in 1..([int]$layout.PoolSize)) {
        $workerName = '{0}-{1:D2}' -f ([string]$layout.PoolVmPrefix), $workerId
        $worker = Get-VM -Name $workerName -ErrorAction SilentlyContinue
        if ($worker -and $worker.State -ne 'Off') {
            throw "Worker must be off before recovery export: $workerName ($($worker.State))."
        }
    }

    $baseline = Get-VM -Name ([string]$layout.BaselineVmName) -ErrorAction Stop
    if ($baseline.State -ne 'Off') {
        Stop-VM -Name $baseline.Name -TurnOff -Force -ErrorAction Stop | Out-Null
    }
    $checkpoint = Get-VMSnapshot -VMName $baseline.Name -Name ([string]$layout.BaselineCheckpointName) -ErrorAction Stop
    Get-VMNetworkAdapter -VMName $baseline.Name -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter -ErrorAction SilentlyContinue

    $bundleSoftware = Join-Path $stagingRoot 'Software'
    foreach ($entry in @(Copy-CodexRecoveryTreeIncremental -SourceRoot ([string]$layout.SoftwareRoot) -DestinationBundleRoot $stagingRoot -BundlePrefix 'Software' -PriorBundleRoot $(if ($null -ne $priorManifest) { $currentRoot } else { $null }) -PriorFileMap $priorManifestMap)) {
        Add-KnownEntry -Entry $entry
    }
    $privateCredential = Join-Path $bundleSoftware 'Harness\private\guest-credential.json'
    if (-not (Test-Path -LiteralPath $privateCredential -PathType Leaf)) {
        throw 'The portable guest credential was not included in the recovery software snapshot.'
    }
    Set-CodexPrivateFileAcl -Path $privateCredential

    $codexRoot = Join-Path $stagingRoot 'Codex'
    New-Item -ItemType Directory -Force -Path $codexRoot | Out-Null
    $agentsSource = Join-Path $bundleSoftware 'Setup\AGENTS.block.md'
    if (-not (Test-Path -LiteralPath $agentsSource -PathType Leaf)) {
        throw "The canonical managed Codex policy block is missing from the software snapshot: $agentsSource"
    }
    Add-KnownEntry -Entry (Copy-CodexRecoveryFileIncremental -SourcePath $agentsSource -DestinationBundleRoot $stagingRoot -RelativePath 'Codex/AGENTS.md' -PriorBundleRoot $(if ($null -ne $priorManifest) { $currentRoot } else { $null }) -PriorFileMap $priorManifestMap)

    foreach ($name in @('INSTALL.cmd', 'Install-CodexHyperVHarness.ps1', 'RecoveryCommon.ps1', 'SHOW-RECOVERY-RESULT.cmd', 'Show-CodexHyperVRecoveryResult.ps1')) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Recovery installer source is missing: $source" }
        Add-KnownEntry -Entry (Copy-CodexRecoveryFileIncremental -SourcePath $source -DestinationBundleRoot $stagingRoot -RelativePath $name -PriorBundleRoot $(if ($null -ne $priorManifest) { $currentRoot } else { $null }) -PriorFileMap $priorManifestMap)
    }

    $exportRoot = Join-Path $stagingRoot 'BaselineExport'
    New-Item -ItemType Directory -Force -Path $exportRoot | Out-Null
    if ($BaselineExportMode -eq 'ReuseCurrent') {
        foreach ($comparison in @(
            [pscustomobject]@{ Name = 'VM name'; Current = [string]$baseline.Name; Prior = [string]$priorManifest.BaselineVmName },
            [pscustomobject]@{ Name = 'VM ID'; Current = [string]$baseline.Id; Prior = [string]$priorManifest.BaselineVmId },
            [pscustomobject]@{ Name = 'checkpoint name'; Current = [string]$checkpoint.Name; Prior = [string]$priorManifest.BaselineCheckpointName },
            [pscustomobject]@{ Name = 'checkpoint ID'; Current = [string]$checkpoint.Id; Prior = [string]$priorManifest.BaselineCheckpointId }
        )) {
            if (-not [string]::Equals($comparison.Current, $comparison.Prior, [StringComparison]::OrdinalIgnoreCase)) {
                throw "ReuseCurrent baseline $($comparison.Name) mismatch; use a reviewed FullExport plan instead."
            }
        }

        $priorBaselineEntries = @($priorManifest.Files | Where-Object { ([string]$_.RelativePath).Replace('\', '/') -like 'BaselineExport/*' } | Sort-Object RelativePath)
        if ($priorBaselineEntries.Count -eq 0) { throw 'ReuseCurrent found no BaselineExport files in the Current manifest.' }
        foreach ($entry in $priorBaselineEntries) {
            $relative = ([string]$entry.RelativePath).Replace('\', '/')
            $source = Assert-CodexPathWithin -Path (Join-Path $currentRoot $relative) -Parent $currentRoot
            $destination = Assert-CodexPathWithin -Path (Join-Path $stagingRoot $relative) -Parent $stagingRoot
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or [long](Get-Item -LiteralPath $source).Length -ne [long]$entry.Length) {
                throw "Reusable baseline file is missing or changed in length: $relative"
            }
            [void](New-CodexRecoveryHardLink -SourcePath $source -DestinationPath $destination)
            Add-KnownEntry -Entry ([pscustomobject][ordered]@{
                RelativePath = $relative
                Length = [long]$entry.Length
                Sha256 = [string]$entry.Sha256
                ReusedByHardLink = $true
            })
            $trustedBaselinePaths.Add($relative)
        }
        $exportedRelative = ([string]$priorManifest.ExportedVmConfiguration).Replace('\', '/')
        if ($exportedRelative -notlike 'BaselineExport/*' -or -not $priorManifestMap.ContainsKey($exportedRelative)) {
            throw 'ReuseCurrent found an invalid exported VM configuration path in the Current manifest.'
        }
        $exportedConfig = Assert-CodexPathWithin -Path (Join-Path $stagingRoot $exportedRelative) -Parent $stagingRoot
        $baselineExportSourceBundleId = [string]$priorManifest.BundleId
        $baselineExportDisposition = 'ReusedCurrentByNtfsHardLink'
    }
    else {
        Export-VM -Name $baseline.Name -Path $exportRoot -ErrorAction Stop
        $exportedConfig = Get-CodexExportedVmConfigurationPath -ExportRoot $exportRoot
    }

    $files = New-Object Collections.Generic.List[object]
    $checksumLines = New-Object Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -Force | Sort-Object FullName)) {
        if ($file.Name -in @('manifest.json', 'checksums.sha256')) { continue }
        $relative = Get-CodexRelativePath -BasePath $stagingRoot -Path $file.FullName
        if ($knownEntries.ContainsKey($relative)) {
            $known = $knownEntries[$relative]
            if ([long]$known.Length -ne [long]$file.Length) { throw "Staged recovery file changed in length: $relative" }
            $hash = [string]$known.Sha256
        }
        else {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        $files.Add([pscustomobject][ordered]@{
            RelativePath = $relative
            Length = [long]$file.Length
            Sha256 = $hash
        })
        $checksumLines.Add("$hash *$relative")
    }
    $checksumPath = Join-Path $stagingRoot 'checksums.sha256'
    $checksumLines.ToArray() | Set-Content -LiteralPath $checksumPath -Encoding ASCII
    $checksumHash = (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash
    $hardLinkedEntries = @($files | Where-Object { $hardLinkedPaths.Contains([string]$_.RelativePath) })
    $baselineEntries = @($files | Where-Object { [string]$_.RelativePath -like 'BaselineExport/*' })
    $imageServicingStatusPath = Join-Path $ActiveBrokerRoot 'State\Management\baseline-servicing-status.json'
    $imageServicing = $null
    if (Test-Path -LiteralPath $imageServicingStatusPath -PathType Leaf) {
        $servicingStatus = Get-Content -Raw -LiteralPath $imageServicingStatusPath | ConvertFrom-Json
        if ([bool]$servicingStatus.Success) {
            $imageServicing = [ordered]@{
                StatusUpdatedUtc = [string]$servicingStatus.UpdatedUtc
                Os = $servicingStatus.Details.After
                DotNetSdks = @($servicingStatus.Details.ResolvedSdks | ForEach-Object {
                    [ordered]@{ Channel = $_.Channel; Version = $_.Version; RuntimeVersion = $_.RuntimeVersion; ReleaseDate = $_.ReleaseDate; Sha512 = $_.Sha512 }
                })
                WindowsUpdatePassCount = @($servicingStatus.Details.WindowsUpdatePasses).Count
                NetworkSwitchName = [string]$servicingStatus.Details.NetworkSwitchName
                NetworkDisconnected = [bool]$servicingStatus.Details.NetworkDisconnected
            }
        }
    }
    $manifest = [ordered]@{
        FormatVersion = 1
        BundleId = $bundleId
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        SourceMachine = $env:COMPUTERNAME
        BaselineVmName = [string]$baseline.Name
        BaselineVmId = [string]$baseline.Id
        BaselineCheckpointName = [string]$checkpoint.Name
        BaselineCheckpointId = [string]$checkpoint.Id
        ExportedVmConfiguration = Get-CodexRelativePath -BasePath $stagingRoot -Path $exportedConfig
        ConfigRelativePath = 'Software/harness-config.json'
        FileCount = $files.Count
        TotalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        ChecksumsSha256 = $checksumHash
        CredentialPolicy = 'Portable throwaway-VM credential; ACL restricted to SYSTEM and Administrators.'
        BaselineExportDisposition = $baselineExportDisposition
        BaselineExportSourceBundleId = $baselineExportSourceBundleId
        ContentReuse = [ordered]@{
            PriorBundleId = if ($null -ne $priorManifest) { [string]$priorManifest.BundleId } else { $null }
            PriorManifestSha256 = $priorManifestSha256
            HardLinkedFiles = $hardLinkedEntries.Count
            HardLinkedBytes = [long](($hardLinkedEntries | Measure-Object -Property Length -Sum).Sum)
            BaselineFiles = $baselineEntries.Count
            BaselineBytes = [long](($baselineEntries | Measure-Object -Property Length -Sum).Sum)
            VerificationMode = if ($BaselineExportMode -eq 'ReuseCurrent') { 'Sha256DeltaAndNtfsHardLinkIdentity' } else { 'FullSha256' }
        }
        ImageServicing = $imageServicing
        Files = $files.ToArray()
    }
    $stagingManifestPath = Join-Path $stagingRoot 'manifest.json'
    Write-CodexJsonAtomic -Path $stagingManifestPath -Value $manifest
    $manifestSha256 = (Get-FileHash -LiteralPath $stagingManifestPath -Algorithm SHA256).Hash

    $verification = if ($BaselineExportMode -eq 'ReuseCurrent') {
        Test-CodexRecoveryBundleIntegrity -BundleRoot $stagingRoot -TrustedBundleRoot $currentRoot -TrustedRelativePaths $trustedBaselinePaths.ToArray()
    }
    else {
        Test-CodexRecoveryBundleIntegrity -BundleRoot $stagingRoot
    }
    if (-not $verification.Success) {
        throw ('Recovery staging verification failed: ' + ($verification.Failures -join '; '))
    }

    if (Test-Path -LiteralPath $previousRoot) {
        [void](Assert-CodexPathWithin -Path $previousRoot -Parent $recoveryRoot -ExpectedLeaf 'Previous')
        Remove-Item -LiteralPath $previousRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $currentRoot) {
        [void](Assert-CodexPathWithin -Path $currentRoot -Parent $recoveryRoot -ExpectedLeaf 'Current')
        if (Test-Path -LiteralPath (Join-Path $currentRoot 'manifest.json') -PathType Leaf) {
            Move-Item -LiteralPath $currentRoot -Destination $previousRoot
        }
        else {
            Remove-Item -LiteralPath $currentRoot -Recurse -Force
        }
    }
    Move-Item -LiteralPath $stagingRoot -Destination $currentRoot
    $postRotation = Test-CodexRecoveryBundleIntegrity -BundleRoot $currentRoot -SkipContentHashes
    if (-not $postRotation.Success) {
        throw ('The rotated recovery bundle failed structural verification: ' + ($postRotation.Failures -join '; '))
    }
    Write-RefreshStatus -Success $true -Message 'The verified one-click recovery bundle was refreshed.' -Details ([ordered]@{
        Manifest = Join-Path $currentRoot 'manifest.json'
        FileCount = $manifest.FileCount
        TotalBytes = $manifest.TotalBytes
        ExportedVmConfiguration = $manifest.ExportedVmConfiguration
        ManifestSha256 = $manifestSha256
        BaselineExportDisposition = $baselineExportDisposition
        BaselineExportSourceBundleId = $baselineExportSourceBundleId
        PriorReceiptKind = if ($null -ne $priorReceipt) { [string]$priorReceipt.Kind } else { $null }
        HardLinkedFiles = $hardLinkedEntries.Count
        HardLinkedBytes = [long](($hardLinkedEntries | Measure-Object -Property Length -Sum).Sum)
        HashedFiles = [int]$verification.HashedFiles
        HashedBytes = [long]$verification.HashedBytes
        TrustedIdentityFiles = [int]$verification.TrustedIdentityFiles
        TrustedIdentityBytes = [long]$verification.TrustedIdentityBytes
        PreviousRetained = Test-Path -LiteralPath (Join-Path $previousRoot 'manifest.json') -PathType Leaf
    })
}
catch {
    Write-RefreshStatus -Success $false -Message $_.Exception.Message -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace; StagingRoot = $stagingRoot; BaselineExportMode = $BaselineExportMode })
    throw
}
finally {
    if ($maintenanceCreated) { Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction SilentlyContinue }
    if ($taskWasRunning) { Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }
}
