[CmdletBinding()]
param(
    [ValidateRange(2, 10000)] [int] $FileCount = 1000,
    [ValidateRange(1, 1024)] [int] $FileSizeKiB = 64,
    [string] $RunnerPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Software\Skill\scripts\Invoke-HyperVExecutableTest.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($RunnerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw $parseErrors[0].Message }

function Import-RunnerFunction {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Runner function not found: $Name" }
    $body = $definition.Body.Extent.Text
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

Import-RunnerFunction -Name 'Get-PayloadSourceInventory'
Import-RunnerFunction -Name 'Get-PayloadManifest'

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$workRoot = Join-Path $temporaryRoot ('CodexPayloadFingerprint-' + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $workRoot 'payload'
if (-not ([IO.Path]::GetFullPath($workRoot) + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($workRoot) -notlike 'CodexPayloadFingerprint-*') {
    throw 'The benchmark work path failed its temporary-directory safety check.'
}

function Measure-FingerprintPass {
    param([IO.FileSystemInfo] $Artifact, $PreviousIndex)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $inventory = Get-PayloadSourceInventory -Artifact $Artifact -PreviousIndex $PreviousIndex
    $manifest = Get-PayloadManifest -Artifact $Artifact -PreviousIndex $PreviousIndex -Inventory $inventory
    $watch.Stop()
    [pscustomobject][ordered]@{
        TotalMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        EnumerationMilliseconds = [double]$manifest.EnumerationMilliseconds
        CandidateHashMilliseconds = [double]$manifest.CandidateHashMilliseconds
        CandidateCount = [int]$inventory.CandidateCount
        CandidateBytes = [long]$inventory.CandidateBytes
        FilesHashed = [int]$manifest.FilesHashed
        HashesReused = [int]$manifest.HashesReused
        Index = [pscustomobject]@{ Files = @($manifest.IndexFiles) }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null
    $buffer = New-Object byte[] ($FileSizeKiB * 1KB)
    for ($index = 0; $index -lt $FileCount; $index++) {
        $buffer[0] = [byte]($index % 251)
        $buffer[$buffer.Length - 1] = [byte](($index * 7) % 251)
        [IO.File]::WriteAllBytes((Join-Path $payloadRoot ('file-{0:D5}.bin' -f $index)), $buffer)
    }
    $artifact = Get-Item -LiteralPath $payloadRoot
    $cold = Measure-FingerprintPass -Artifact $artifact -PreviousIndex $null
    $warm = Measure-FingerprintPass -Artifact $artifact -PreviousIndex $cold.Index

    $changedPath = Join-Path $payloadRoot 'file-00000.bin'
    $buffer[0] = [byte](($buffer[0] + 1) % 251)
    [IO.File]::WriteAllBytes($changedPath, $buffer)
    [IO.File]::SetLastWriteTimeUtc($changedPath, [DateTime]::UtcNow.AddSeconds(2))
    $oneChanged = Measure-FingerprintPass -Artifact $artifact -PreviousIndex $warm.Index

    if ($cold.FilesHashed -ne $FileCount -or $cold.HashesReused -ne 0) { throw 'Cold fingerprint pass did not hash every generated file.' }
    if ($warm.FilesHashed -ne 0 -or $warm.HashesReused -ne $FileCount -or $warm.CandidateCount -ne 0) { throw 'Unchanged fingerprint pass did not reuse every prior hash.' }
    if ($oneChanged.FilesHashed -ne 1 -or $oneChanged.HashesReused -ne ($FileCount - 1) -or $oneChanged.CandidateCount -ne 1) { throw 'One-file change did not hash exactly one candidate.' }

    [pscustomobject][ordered]@{
        Success = $true
        MeasuredUtc = [DateTime]::UtcNow.ToString('o')
        FileCount = $FileCount
        FileSizeKiB = $FileSizeKiB
        TotalMiB = [Math]::Round(($FileCount * $FileSizeKiB) / 1024.0, 3)
        Cold = $cold | Select-Object * -ExcludeProperty Index
        WarmUnchanged = $warm | Select-Object * -ExcludeProperty Index
        OneChanged = $oneChanged | Select-Object * -ExcludeProperty Index
    }
}
finally {
    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($workRoot)
        if (($resolved + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'CodexPayloadFingerprint-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
