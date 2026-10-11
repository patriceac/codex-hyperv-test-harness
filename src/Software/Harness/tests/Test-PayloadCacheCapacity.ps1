[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$harnessRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $harnessRoot 'PayloadCache.ps1')

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('codex-payload-capacity-' + [Guid]::NewGuid().ToString('N'))
$script:payloadMountPath = Join-Path $testRoot 'mounts'
$script:diskNumber = 42
$script:partitionNumber = 1
$script:partitionSize = [long]2GB
$script:maximumSize = [long]8GB
$script:resizeCount = 0
$script:accessPathCount = 0
$script:partitionStyle = 'GPT'
$script:formatCount = 0

function Mount-VHD {
    [CmdletBinding()]
    param([string] $Path, [switch] $NoDriveLetter, [switch] $Passthru)
    if (-not $NoDriveLetter) { throw 'Host payload attachment must suppress drive letters before either creation or remount.' }
    [pscustomobject]@{ Number = $script:diskNumber }
}

function Get-Disk {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)] $InputObject,
        [int] $Number
    )
    process {
        [pscustomobject]@{
            Number = $script:diskNumber
            IsOffline = $false
            IsReadOnly = $false
            PartitionStyle = $script:partitionStyle
        }
    }
}

function Initialize-Disk {
    [CmdletBinding()]
    param([int] $Number, [string] $PartitionStyle)
    if ($PartitionStyle -ne 'GPT') { throw 'New payload disk must retain its GPT layout.' }
    $script:partitionStyle = $PartitionStyle
}

function New-Partition {
    [CmdletBinding()]
    param([int] $DiskNumber, [switch] $UseMaximumSize, [switch] $AssignDriveLetter)
    if (-not $PSBoundParameters.ContainsKey('AssignDriveLetter') -or $AssignDriveLetter) {
        throw 'Unformatted payload partition must be created without requesting a host drive letter.'
    }
    Get-Partition -DiskNumber $DiskNumber
}

function Format-Volume {
    [CmdletBinding()]
    param($Partition, [string] $FileSystem, [string] $NewFileSystemLabel, [switch] $Confirm, [switch] $Force)
    if ($FileSystem -ne 'NTFS' -or $script:accessPathCount -ne 0) { throw 'New payload must be formatted before folder access.' }
    $script:formatCount++
}

function Get-Partition {
    [CmdletBinding()]
    param([int] $DiskNumber)
    [pscustomobject]@{
        DiskNumber = $script:diskNumber
        PartitionNumber = $script:partitionNumber
        Type = 'Basic'
        GptType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
        Size = $script:partitionSize
    }
}

function Get-PartitionSupportedSize {
    [CmdletBinding()]
    param([int] $DiskNumber, [int] $PartitionNumber)
    [pscustomobject]@{ SizeMin = [long]1GB; SizeMax = $script:maximumSize }
}

function Resize-Partition {
    [CmdletBinding()]
    param([int] $DiskNumber, [int] $PartitionNumber, [long] $Size)
    if ($Size -ne $script:maximumSize) { throw 'Payload partition was not extended to its supported maximum.' }
    $script:partitionSize = $Size
    $script:resizeCount++
}

function Add-PartitionAccessPath {
    [CmdletBinding()]
    param([int] $DiskNumber, [int] $PartitionNumber, [string] $AccessPath)
    if (($script:maximumSize - $script:partitionSize) -ge [long]1MB) { throw 'Payload partition was mounted before capacity expansion.' }
    $script:accessPathCount++
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $mount = Mount-PayloadVhdForSync -VhdxPath (Join-Path $testRoot 'payload.vhdx') -PayloadId ('A' * 64)
    if ($script:resizeCount -ne 1 -or $script:accessPathCount -ne 1 -or -not (Test-Path -LiteralPath $mount.MountDirectory -PathType Container)) {
        throw 'Expanded payload VHD capacity was not applied before the mount path became usable.'
    }

    $script:resizeCount = 0
    $script:accessPathCount = 0
    $script:partitionSize = $script:maximumSize - [long]512KB
    $null = Mount-PayloadVhdForSync -VhdxPath (Join-Path $testRoot 'already-sized.vhdx') -PayloadId ('B' * 64)
    if ($script:resizeCount -ne 0 -or $script:accessPathCount -ne 1) {
        throw 'An already full-size payload partition should mount without another resize.'
    }
    if ($script:formatCount -ne 0) { throw 'Existing cached payload disks must not be reformatted on remount.' }

    $script:partitionStyle = 'RAW'
    $script:accessPathCount = 0
    $null = Mount-PayloadVhdForSync -VhdxPath (Join-Path $testRoot 'new-payload.vhdx') -PayloadId ('C' * 64)
    if ($script:formatCount -ne 1 -or $script:partitionStyle -ne 'GPT' -or $script:accessPathCount -ne 1) {
        throw 'Fresh payload must suppress host letters, initialize/format once and retain folder access.'
    }

    [pscustomobject]@{ Success = $true; ScenarioCount = 3; Scenarios = @('expanded-before-mount', 'sub-megabyte-noop', 'fresh-payload-no-host-letter') } | ConvertTo-Json -Depth 4
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedRoot) -notlike 'codex-payload-capacity-*') {
        throw 'Unsafe payload-capacity test cleanup target.'
    }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
