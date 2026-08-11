param(
    [string] $BrokerRoot,
    [string] $PayloadId,
    [string] $StatusPath,
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($BrokerRoot)) { $BrokerRoot = [string]$layout.BrokerRoot }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'payload-cache-inspection.json' }
Import-Module Hyper-V
$config = Get-Content -Raw -LiteralPath (Join-Path $BrokerRoot 'Private\config.json') | ConvertFrom-Json
$cacheRoot = Join-Path $BrokerRoot 'PayloadCache'
$entryRoots = if ([string]::IsNullOrWhiteSpace($PayloadId)) {
    @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue)
}
else {
    @((Get-Item -LiteralPath (Join-Path $cacheRoot $PayloadId) -ErrorAction Stop))
}
$entries = foreach ($entryRoot in $entryRoots) {
    $metadataPath = Join-Path $entryRoot.FullName 'cache-entry.json'
    $metadata = if (Test-Path -LiteralPath $metadataPath -PathType Leaf) { Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json } else { $null }
    $vhds = foreach ($vhdx in Get-ChildItem -LiteralPath $entryRoot.FullName -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue) {
        $vhd = Get-VHD -Path $vhdx.FullName
        [ordered]@{
            Path = $vhdx.FullName
            IsReadOnly = $vhdx.IsReadOnly
            VhdType = [string]$vhd.VhdType
            VhdFormat = [string]$vhd.VhdFormat
            ParentPath = [string]$vhd.ParentPath
            VirtualSizeBytes = [long]$vhd.Size
            PhysicalSizeBytes = [long]$vhd.FileSize
        }
    }
    [ordered]@{
        PayloadId = $entryRoot.Name
        Metadata = $metadata
        Vhds = @($vhds)
    }
}
$vm = Get-VM -Name ([string]$config.VmName)
$result = [ordered]@{
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    VmName = $vm.Name
    VmState = [string]$vm.State
    VmNetworkAdapters = @(Get-VMNetworkAdapter -VMName $vm.Name | Select-Object Name, SwitchName, Status)
    VmHardDisks = @(Get-VMHardDiskDrive -VMName $vm.Name | Select-Object ControllerType, ControllerNumber, ControllerLocation, Path)
    VmSnapshots = @(Get-VMSnapshot -VMName $vm.Name | Select-Object Name, Id, CreationTime, ParentSnapshotId)
    DisposableChildren = @(Get-ChildItem -LiteralPath (Join-Path $BrokerRoot 'PayloadChildren') -Filter '*.vhdx' -File -Force -ErrorAction SilentlyContinue | Select-Object FullName, Length, IsReadOnly)
    CachePolicy = [ordered]@{
        MaxAgeDays = [int]$config.PayloadCacheMaxAgeDays
        MaxBytes = [long]$config.PayloadCacheMaxBytes
        TargetBytes = [long]$config.PayloadCacheTargetBytes
        MaxChainDepth = [int]$config.PayloadCacheMaxChainDepth
    }
    GarbageCollectionState = if (Test-Path -LiteralPath (Join-Path $BrokerRoot 'State\payload-cache-gc.json') -PathType Leaf) { Get-Content -Raw -LiteralPath (Join-Path $BrokerRoot 'State\payload-cache-gc.json') | ConvertFrom-Json } else { $null }
    Entries = @($entries)
}
$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
