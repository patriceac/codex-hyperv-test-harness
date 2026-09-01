[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$harnessRoot = Split-Path -Parent $PSScriptRoot
$softwareRoot = Split-Path -Parent $harnessRoot
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $softwareRoot)
$recoveryRoot = Join-Path $softwareRoot 'Recovery'
$commonPath = Join-Path $recoveryRoot 'RecoveryCommon.ps1'
$builderPath = Join-Path $recoveryRoot 'New-CodexHyperVRecovery.ps1'
$wrapperPath = Join-Path $repositoryRoot 'setup\Refresh-LocalRecovery.ps1'
$deployPath = Join-Path $repositoryRoot 'setup\Deploy-HarnessRelease.ps1'
. $commonPath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Set-TestFile {
    param([string] $Path, [string] $Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Write-TestManifest {
    param(
        [string] $BundleRoot,
        [string] $BundleId = ('test-' + [Guid]::NewGuid().ToString('N'))
    )

    $entries = New-Object Collections.Generic.List[object]
    $checksumLines = New-Object Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $BundleRoot -Recurse -File -Force | Sort-Object FullName)) {
        if ($file.Name -in @('manifest.json','checksums.sha256')) { continue }
        $relative = Get-CodexRelativePath -BasePath $BundleRoot -Path $file.FullName
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $entries.Add([pscustomobject][ordered]@{ RelativePath = $relative; Length = [long]$file.Length; Sha256 = $hash })
        $checksumLines.Add("$hash *$relative")
    }
    $checksumPath = Join-Path $BundleRoot 'checksums.sha256'
    $checksumLines.ToArray() | Set-Content -LiteralPath $checksumPath -Encoding ASCII
    $manifest = [ordered]@{
        FormatVersion = 1
        BundleId = $BundleId
        BaselineVmName = 'Test-Baseline'
        BaselineVmId = '11111111-1111-1111-1111-111111111111'
        BaselineCheckpointName = 'Test-Checkpoint'
        BaselineCheckpointId = '22222222-2222-2222-2222-222222222222'
        ExportedVmConfiguration = 'BaselineExport/Test/Virtual Machines/test.vmcx'
        FileCount = $entries.Count
        TotalBytes = [long](($entries | Measure-Object -Property Length -Sum).Sum)
        ChecksumsSha256 = (Get-FileHash -LiteralPath $checksumPath -Algorithm SHA256).Hash
        Files = $entries.ToArray()
    }
    Write-CodexJsonAtomic -Path (Join-Path $BundleRoot 'manifest.json') -Value $manifest
    [pscustomobject]$manifest
}

$scenarios = New-Object Collections.Generic.List[string]
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexRecoveryDelta-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    $hardLinkSource = Join-Path $testRoot 'hardlink\source.bin'
    $hardLinkDestination = Join-Path $testRoot 'hardlink\destination.bin'
    Set-TestFile -Path $hardLinkSource -Value ('baseline-' + ('x' * 4096))
    $link = New-CodexRecoveryHardLink -SourcePath $hardLinkSource -DestinationPath $hardLinkDestination
    $sourceIdentity = Get-CodexFileIdentity -Path $hardLinkSource
    $destinationIdentity = Get-CodexFileIdentity -Path $hardLinkDestination
    Assert-True ([string]$sourceIdentity.Value -ceq [string]$destinationIdentity.Value) 'Hard-link creation did not preserve NTFS file identity.'
    Assert-True ([uint32]$link.LinkCount -ge 2) 'Hard-link count did not increase.'
    $scenarios.Add('native-hard-link-identity-is-proven')

    $priorRoot = Join-Path $testRoot 'prior'
    $sourceRoot = Join-Path $testRoot 'source'
    $deltaRoot = Join-Path $testRoot 'delta'
    Set-TestFile -Path (Join-Path $priorRoot 'Software\same.txt') -Value 'unchanged'
    Set-TestFile -Path (Join-Path $priorRoot 'Software\changed.txt') -Value 'old-value'
    $priorManifest = Write-TestManifest -BundleRoot $priorRoot -BundleId 'prior-bundle'
    $priorMap = Get-CodexRecoveryManifestFileMap -Manifest $priorManifest
    Set-TestFile -Path (Join-Path $sourceRoot 'same.txt') -Value 'unchanged'
    Set-TestFile -Path (Join-Path $sourceRoot 'changed.txt') -Value 'new-value'
    $deltaResults = @(Copy-CodexRecoveryTreeIncremental -SourceRoot $sourceRoot -DestinationBundleRoot $deltaRoot -BundlePrefix 'Software' -PriorBundleRoot $priorRoot -PriorFileMap $priorMap)
    $sameResult = @($deltaResults | Where-Object RelativePath -eq 'Software/same.txt')[0]
    $changedResult = @($deltaResults | Where-Object RelativePath -eq 'Software/changed.txt')[0]
    Assert-True ([bool]$sameResult.ReusedByHardLink) 'Unchanged software was not reused by hard link.'
    Assert-True (-not [bool]$changedResult.ReusedByHardLink) 'Changed software was incorrectly reused.'
    Assert-True ((Get-CodexFileIdentity (Join-Path $priorRoot 'Software\same.txt')).Value -ceq (Get-CodexFileIdentity (Join-Path $deltaRoot 'Software\same.txt')).Value) 'Unchanged software identities differ.'
    Assert-True ((Get-CodexFileIdentity (Join-Path $priorRoot 'Software\changed.txt')).Value -cne (Get-CodexFileIdentity (Join-Path $deltaRoot 'Software\changed.txt')).Value) 'Changed software unexpectedly shares prior storage.'
    $scenarios.Add('incremental-tree-links-unchanged-and-copies-changed-files')

    $corruptPriorRoot = Join-Path $testRoot 'corrupt-prior'
    $corruptSource = Join-Path $testRoot 'corrupt-source\value.txt'
    $corruptDeltaRoot = Join-Path $testRoot 'corrupt-delta'
    Set-TestFile -Path (Join-Path $corruptPriorRoot 'Software\value.txt') -Value 'wxyz'
    Set-TestFile -Path $corruptSource -Value 'abcd'
    $claimedHash = (Get-FileHash -LiteralPath $corruptSource -Algorithm SHA256).Hash
    $claimedMap = @{ 'Software/value.txt' = [pscustomobject]@{ RelativePath = 'Software/value.txt'; Length = 4; Sha256 = $claimedHash } }
    $corruptResult = Copy-CodexRecoveryFileIncremental -SourcePath $corruptSource -DestinationBundleRoot $corruptDeltaRoot -RelativePath 'Software/value.txt' -PriorBundleRoot $corruptPriorRoot -PriorFileMap $claimedMap
    Assert-True (-not [bool]$corruptResult.ReusedByHardLink) 'A same-length prior file whose content disagreed with its manifest was reused.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $corruptDeltaRoot 'Software\value.txt') -Raw) -ceq 'abcd') 'Corrupt-prior fallback did not copy the source content.'
    $scenarios.Add('small-file-reuse-rehashes-prior-content-and-falls-back-safely')

    $trustedRoot = Join-Path $testRoot 'trusted'
    $candidateRoot = Join-Path $testRoot 'candidate'
    $trustedBaseline = Join-Path $trustedRoot 'BaselineExport\Test\Virtual Machines\test.vmcx'
    Set-TestFile -Path $trustedBaseline -Value ('vm-config-' + ('z' * 8192))
    $trustedManifest = Write-TestManifest -BundleRoot $trustedRoot -BundleId 'trusted-bundle'
    $candidateBaseline = Join-Path $candidateRoot 'BaselineExport\Test\Virtual Machines\test.vmcx'
    [void](New-CodexRecoveryHardLink -SourcePath $trustedBaseline -DestinationPath $candidateBaseline)
    Set-TestFile -Path (Join-Path $candidateRoot 'Software\delta.txt') -Value 'delta'
    [void](Write-TestManifest -BundleRoot $candidateRoot -BundleId 'candidate-bundle')
    $trustedRelative = 'BaselineExport/Test/Virtual Machines/test.vmcx'
    $integrity = Test-CodexRecoveryBundleIntegrity -BundleRoot $candidateRoot -TrustedBundleRoot $trustedRoot -TrustedRelativePaths @($trustedRelative)
    Assert-True ([bool]$integrity.Success) ('Trusted delta verification failed: ' + ($integrity.Failures -join '; '))
    Assert-True ([int]$integrity.TrustedIdentityFiles -eq 1 -and [int]$integrity.HashedFiles -eq 1) 'Trusted verification did not split identity and SHA-256 work correctly.'
    Remove-Item -LiteralPath $candidateBaseline -Force
    Copy-Item -LiteralPath $trustedBaseline -Destination $candidateBaseline
    $identityFailure = Test-CodexRecoveryBundleIntegrity -BundleRoot $candidateRoot -TrustedBundleRoot $trustedRoot -TrustedRelativePaths @($trustedRelative)
    Assert-True (-not [bool]$identityFailure.Success -and (@($identityFailure.Failures) -join '; ') -match 'hard-link identity mismatch') 'A byte-identical but physically independent baseline was accepted as trusted reuse.'
    $scenarios.Add('trusted-baseline-verification-requires-shared-file-identity')

    $builder = Get-Content -LiteralPath $builderPath -Raw
    $wrapper = Get-Content -LiteralPath $wrapperPath -Raw
    Assert-True ($builder -match "ValidateSet\('FullExport','ReuseCurrent'\)" -and $builder -match 'BaselineExportDisposition' -and $builder -match 'Get-MatchingRecoveryReceipt') 'Recovery builder does not expose the fail-closed reuse contract.'
    Assert-True ($wrapper -match 'BaselineExportMode\s+\$BaselineExportMode') 'Recovery wrapper does not forward the reviewed export mode.'
    $scenarios.Add('builder-and-wrapper-expose-explicit-fail-closed-modes')

    $preflightRoot = Join-Path $testRoot 'preflight-root'
    $preview = & $deployPath -InstallRoot $preflightRoot -InvocationPreflightOnly
    Assert-True ([bool]$preview.Success -and [bool]$preview.NoMutationPerformed -and -not (Test-Path -LiteralPath $preflightRoot)) 'Deployment invocation preflight mutated state or failed.'
    Assert-True ([string]$preview.RecoveryRefreshInvocation.BaselineExportMode -eq 'ReuseCurrent') 'Deployment invocation does not bind the planned recovery reuse mode.'
    $scenarios.Add('release-controller-binds-recovery-mode-without-mutation')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
