[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$measurement = & (Join-Path $repositoryRoot 'setup\Measure-PayloadFingerprint.ps1') -FileCount 32 -FileSizeKiB 1
if (-not $measurement.Success) { throw 'Payload fingerprint measurement did not succeed.' }
if ($measurement.WarmUnchanged.FilesHashed -ne 0 -or $measurement.WarmUnchanged.HashesReused -ne 32) {
    throw 'An unchanged cache hit hashed file contents instead of reusing metadata-qualified hashes.'
}
if ($measurement.OneChanged.FilesHashed -ne 1 -or $measurement.OneChanged.HashesReused -ne 31) {
    throw 'The changed-file pass did not hash exactly one metadata candidate.'
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = 3
    Scenarios = @('cold-hashes-all', 'unchanged-hashes-zero', 'one-change-hashes-one')
    Metrics = $measurement
} | ConvertTo-Json -Depth 12
