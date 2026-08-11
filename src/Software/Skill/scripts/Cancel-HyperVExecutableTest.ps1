[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')]
    [string] $RequestId,

    [string] $Reason = 'Cancellation requested by the client.',
    [string] $BrokerRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HyperVBrokerLocation.ps1')
$BrokerRoot = Resolve-HyperVBrokerRoot -BrokerRoot $BrokerRoot

$requestsRoot = Join-Path $BrokerRoot 'Requests'
$processingRoot = Join-Path $BrokerRoot 'Processing'
$resultsRoot = Join-Path $BrokerRoot 'Results'
$stagingRoot = Join-Path $BrokerRoot 'Staging'
$cancellationsRoot = Join-Path $BrokerRoot 'Cancellations'
$cancelledRoot = Join-Path $BrokerRoot 'Cancelled'
foreach ($requiredRoot in @($requestsRoot, $processingRoot, $resultsRoot, $stagingRoot, $cancellationsRoot, $cancelledRoot)) {
    if (-not (Test-Path -LiteralPath $requiredRoot -PathType Container)) {
        throw "Broker directory not found: $requiredRoot"
    }
}

$requestFile = Join-Path $requestsRoot ($RequestId + '.json')
$processingFile = Join-Path $processingRoot ($RequestId + '.json')
$cancellationFile = Join-Path $cancellationsRoot ($RequestId + '.json')
$resultPath = Join-Path $resultsRoot $RequestId
$brokerResultPath = Join-Path $resultPath 'broker-result.json'
$clientStatePath = Join-Path $resultPath 'client-state.json'
$stagingPath = Join-Path $stagingRoot $RequestId

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $temporary + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporary, $Path, $backup, $true)
                }
                else { [IO.File]::Move($temporary, $Path) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Write-Outcome {
    param(
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [string] $Message
    )

    [ordered]@{
        RequestId = $RequestId
        Status = $Status
        Message = $Message
        ResultPath = $resultPath
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 6
}

if (Test-Path -LiteralPath $brokerResultPath -PathType Leaf) {
    Write-Outcome -Status 'AlreadyCompleted' -Message 'The broker has already completed this request.'
    exit 0
}

if (Test-Path -LiteralPath $requestFile -PathType Leaf) {
    $cancelledFile = Join-Path $cancelledRoot ($RequestId + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
    try {
        Move-Item -LiteralPath $requestFile -Destination $cancelledFile -ErrorAction Stop

        Write-JsonAtomic -Path $clientStatePath -Value ([ordered]@{
            RequestId = $RequestId
            Status = 'Cancelled'
            Message = $Reason
            UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        })

        $resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
        $resolvedStagingPath = [IO.Path]::GetFullPath($stagingPath)
        if ($resolvedStagingPath.StartsWith($resolvedStagingRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedStagingPath) -eq $RequestId -and
            (Test-Path -LiteralPath $resolvedStagingPath -PathType Container)) {
            Remove-Item -LiteralPath $resolvedStagingPath -Recurse -Force
        }

        Write-Outcome -Status 'CancelledBeforeStart' -Message 'The request was atomically removed from the queue; the VM will not run it.'
        exit 0
    }
    catch {
        # The broker may have claimed the file between the check and the move.
    }
}

if (Test-Path -LiteralPath $processingFile -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $cancellationFile -PathType Leaf)) {
        Write-JsonAtomic -Path $cancellationFile -Value ([ordered]@{
            RequestId = $RequestId
            Reason = $Reason
            RequestedUtc = [DateTime]::UtcNow.ToString('o')
            RequestedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        })
    }
    Write-Outcome -Status 'CancellationRequested' -Message 'The assigned pool worker was signalled and will be isolated and recycled before reuse.'
    exit 0
}

if (Test-Path -LiteralPath $brokerResultPath -PathType Leaf) {
    Write-Outcome -Status 'AlreadyCompleted' -Message 'The broker completed this request while cancellation was being requested.'
    exit 0
}

$cancelledRecord = Get-ChildItem -LiteralPath $cancelledRoot -Filter ($RequestId + '-*.json') -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cancelledRecord) {
    Write-Outcome -Status 'AlreadyCancelled' -Message 'The request was already removed from the queue.'
    exit 0
}

if (Test-Path -LiteralPath $cancellationFile -PathType Leaf) {
    Write-Outcome -Status 'CancellationRequested' -Message 'Cancellation was already requested.'
    exit 0
}

if (Test-Path -LiteralPath $requestFile -PathType Leaf) {
    throw "The queued request still exists but could not be moved to the cancellation archive: $requestFile"
}

Write-Outcome -Status 'NotFound' -Message 'No queued, running, completed, or cancelled request was found with this ID.'
exit 1
