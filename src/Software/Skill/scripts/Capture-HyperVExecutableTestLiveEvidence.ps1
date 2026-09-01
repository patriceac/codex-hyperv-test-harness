[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')]
    [string] $RequestId,

    [Alias('IncludeGuestEvidenceFile')]
    [AllowEmptyCollection()]
    [string[]] $GuestEvidencePath = @(),

    [ValidateRange(3000, 30000)]
    [int] $CaptureTimeoutMilliseconds = 30000,

    [ValidateRange(5, 120)]
    [int] $WaitTimeoutSeconds = 60,

    [string] $BrokerRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HyperVBrokerLocation.ps1')
$BrokerRoot = Resolve-HyperVBrokerRoot -BrokerRoot $BrokerRoot

function Assert-ClientLiveEvidencePaths {
    param([AllowEmptyCollection()] [string[]] $Paths)

    $normalized = New-Object Collections.Generic.List[string]
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Length -gt 240) { throw 'Guest evidence paths must contain 1 to 240 characters.' }
        if ([IO.Path]::IsPathRooted($path) -or $path.StartsWith('\\', [StringComparison]::Ordinal) -or $path.Contains(':') -or $path.IndexOfAny([char[]]'*?') -ge 0) {
            throw "Guest evidence paths must be literal relative paths below {OUTDIR}: $path"
        }
        $parts = @($path -split '[\\/]')
        if ($parts.Count -eq 0 -or @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
            throw "Guest evidence path contains an unsafe segment: $path"
        }
        foreach ($part in $parts) {
            if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Guest evidence path contains an invalid filename character: $path" }
        }
        $canonical = $parts -join '\'
        if (-not $seen.Add($canonical)) { throw "Guest evidence paths must be unique (case-insensitive): $canonical" }
        $normalized.Add($canonical)
    }
    if ($normalized.Count -gt 16) { throw 'No more than 16 guest evidence files may be requested per capture.' }
    $normalized.ToArray()
}

function Write-ClientJsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        [IO.File]::Move($temporary, $Path)
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

$liveRoot = Join-Path $BrokerRoot 'LiveEvidence'
$requestsRoot = Join-Path $liveRoot 'Requests'
$responsesRoot = Join-Path $liveRoot 'Responses'
foreach ($requiredRoot in @($requestsRoot, $responsesRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "The installed broker does not expose the live-evidence protocol directory: $requiredRoot. Update the canonical harness; do not access a pool VM directly."
    }
}

$guestPaths = @(Assert-ClientLiveEvidencePaths -Paths $GuestEvidencePath)
$captureId = 'live-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
$requestPath = Join-Path $requestsRoot ($captureId + '.json')
$responsePath = Join-Path $responsesRoot ($captureId + '.json')
$requestedUtc = [DateTime]::UtcNow
$request = [ordered]@{
    FormatVersion = 1
    CaptureId = $captureId
    RequestId = $RequestId
    RequestedUtc = $requestedUtc.ToString('o')
    RequestedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    GuestEvidencePaths = $guestPaths
    CaptureTimeoutMilliseconds = $CaptureTimeoutMilliseconds
}
Write-ClientJsonAtomic -Path $requestPath -Value $request

$deadline = [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
do {
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        try {
            $responseItem = Get-Item -LiteralPath $responsePath -Force
            if ($responseItem.Length -le 0 -or $responseItem.Length -gt 1MB) { throw 'The live-evidence broker response exceeded its size bound.' }
            $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if (-not [string]::Equals([string]$response.CaptureId, $captureId, [StringComparison]::Ordinal) -or
                -not [string]::Equals([string]$response.RequestId, $RequestId, [StringComparison]::Ordinal)) {
                throw 'The live-evidence broker response does not match the submitted capture identity.'
            }
            $response | Add-Member -NotePropertyName ResponsePath -NotePropertyValue $responsePath -Force
            $response | ConvertTo-Json -Depth 20
            if ([bool]$response.Success) { exit 0 }
            exit 2
        }
        catch [System.Management.Automation.RuntimeException] {
            throw
        }
    }
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt $deadline)

[ordered]@{
    FormatVersion = 1
    CaptureId = $captureId
    RequestId = $RequestId
    Success = $false
    Status = 'BrokerResponseTimedOut'
    FailureKind = 'BrokerResponseTimedOut'
    Message = "The client stopped waiting after $WaitTimeoutSeconds seconds. The original request was not changed, cancelled, restarted, or extended; the broker may still publish this capture response."
    RequestedUtc = $requestedUtc.ToString('o')
    RequestPath = $requestPath
    ResponsePath = $responsePath
} | ConvertTo-Json -Depth 8
exit 3
