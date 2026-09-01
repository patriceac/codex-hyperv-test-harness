$script:GuestLiveEvidenceRoot = 'C:\CodexGuest\LiveEvidence'
$script:GuestLiveEvidenceInbox = Join-Path $script:GuestLiveEvidenceRoot 'Inbox'
$script:GuestLiveEvidenceProcessing = Join-Path $script:GuestLiveEvidenceRoot 'Processing'
$script:GuestLiveEvidenceResponses = Join-Path $script:GuestLiveEvidenceRoot 'Responses'
$script:GuestLiveEvidenceStage = Join-Path $script:GuestLiveEvidenceRoot 'Stage'
$script:GuestLiveEvidenceMaximumFileCount = 16
$script:GuestLiveEvidenceMaximumFileBytes = 4MB
$script:GuestLiveEvidenceMaximumTotalBytes = 16MB
$script:ActiveLiveEvidenceContext = $null
$script:GuestLiveEvidenceCaptureInProgress = $false

function Initialize-GuestLiveEvidenceNativeMethods {
    if ('CodexGuest.LiveEvidenceNativeMethods' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexGuest
{
    public static class LiveEvidenceNativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFinalPathNameByHandle(
            SafeFileHandle hFile,
            StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags);
    }
}
'@
}

foreach ($livePath in @($script:GuestLiveEvidenceInbox, $script:GuestLiveEvidenceProcessing, $script:GuestLiveEvidenceResponses, $script:GuestLiveEvidenceStage)) {
    New-Item -ItemType Directory -Force -Path $livePath | Out-Null
}

function Test-GuestLiveEvidenceIdentifier {
    param([string] $Value)
    -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$'
}

function Set-GuestLiveEvidenceContext {
    param(
        [Parameter(Mandatory = $true)] [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $OutputPath,
        [Parameter(Mandatory = $true)] [int] $ApplicationProcessId,
        [string] $LifecycleStage = 'ApplicationRunning'
    )

    $script:ActiveLiveEvidenceContext = [pscustomobject][ordered]@{
        RequestId = $RequestId
        OutputPath = [IO.Path]::GetFullPath($OutputPath).TrimEnd('\')
        ApplicationProcessId = $ApplicationProcessId
        LifecycleStage = $LifecycleStage
    }
}

function Update-GuestLiveEvidenceContext {
    param([Parameter(Mandatory = $true)] [string] $LifecycleStage)
    if ($script:ActiveLiveEvidenceContext) { $script:ActiveLiveEvidenceContext.LifecycleStage = $LifecycleStage }
}

function Clear-GuestLiveEvidenceContext {
    $script:ActiveLiveEvidenceContext = $null
}

function Resolve-GuestLiveEvidenceSource {
    param(
        [Parameter(Mandatory = $true)] [string] $OutputPath,
        [Parameter(Mandatory = $true)] [string] $RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':') -or $RelativePath.IndexOfAny([char[]]'*?') -ge 0) {
        throw "Guest evidence path must be a literal relative path below {OUTDIR}: $RelativePath"
    }
    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
        throw "Guest evidence path contains an unsafe segment: $RelativePath"
    }

    $root = [IO.Path]::GetFullPath($OutputPath).TrimEnd('\')
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The request output directory is missing or is a reparse point.'
    }
    $candidate = $root
    foreach ($part in $parts) {
        $candidate = Join-Path $candidate $part
        $resolved = [IO.Path]::GetFullPath($candidate)
        $prefix = $root + '\'
        if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Guest evidence path escapes {OUTDIR}: $RelativePath"
        }
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Guest evidence path traverses a reparse point: $RelativePath"
        }
    }
    $leaf = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if ($leaf.PSIsContainer) { throw "Guest evidence path must identify a file: $RelativePath" }
    $leaf
}

function Copy-GuestLiveEvidenceFileStable {
    param(
        [Parameter(Mandatory = $true)] [IO.FileInfo] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [string] $AuthorizedRoot
    )

    Initialize-GuestLiveEvidenceNativeMethods
    if ($Source.Length -le 0 -or $Source.Length -gt $script:GuestLiveEvidenceMaximumFileBytes) {
        throw "Guest evidence file must be between 1 byte and $script:GuestLiveEvidenceMaximumFileBytes bytes: $RelativePath"
    }
    $authorizedRootPath = [IO.Path]::GetFullPath($AuthorizedRoot).TrimEnd('\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $lastError = $null
    try {
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            try {
                $sourceStream = $null
                $destinationStream = $null
                try {
                    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                    $sourceStream = [IO.File]::Open($Source.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
                    $finalPathBuffer = New-Object Text.StringBuilder 32768
                    $finalPathLength = [CodexGuest.LiveEvidenceNativeMethods]::GetFinalPathNameByHandle($sourceStream.SafeFileHandle, $finalPathBuffer, [uint32]$finalPathBuffer.Capacity, 0)
                    if ($finalPathLength -eq 0) {
                        throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
                    }
                    if ($finalPathLength -ge $finalPathBuffer.Capacity) { throw 'The opened source final path exceeded its fixed validation buffer.' }
                    $finalSourcePath = $finalPathBuffer.ToString()
                    if ($finalSourcePath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
                        $finalSourcePath = '\\' + $finalSourcePath.Substring(8)
                    }
                    elseif ($finalSourcePath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
                        $finalSourcePath = $finalSourcePath.Substring(4)
                    }
                    $finalSourcePath = [IO.Path]::GetFullPath($finalSourcePath)
                    if (-not $finalSourcePath.StartsWith($authorizedRootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        throw "The opened guest evidence handle escapes {OUTDIR}: $RelativePath"
                    }

                    $initialLength = [long]$sourceStream.Length
                    if ($initialLength -le 0 -or $initialLength -gt $script:GuestLiveEvidenceMaximumFileBytes) { throw 'The opened source exceeded its size bound.' }
                    $sourceStream.Position = 0
                    $beforeHash = (Get-FileHash -InputStream $sourceStream -Algorithm SHA256 -ErrorAction Stop).Hash
                    $sourceStream.Position = 0
                    $destinationStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $buffer = New-Object byte[] 65536
                    $copied = [long]0
                    while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $copied += $read
                        if ($copied -gt $script:GuestLiveEvidenceMaximumFileBytes) { throw 'The source grew beyond its size bound during copy.' }
                        $destinationStream.Write($buffer, 0, $read)
                    }
                    $destinationStream.Flush($true)
                    $afterLength = [long]$sourceStream.Length
                    $sourceStream.Position = 0
                    $afterHash = (Get-FileHash -InputStream $sourceStream -Algorithm SHA256 -ErrorAction Stop).Hash
                }
                finally {
                    if ($destinationStream) { $destinationStream.Dispose() }
                    if ($sourceStream) { $sourceStream.Dispose() }
                }
                $destinationItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
                $destinationHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($initialLength -ne $afterLength -or $copied -ne $initialLength -or
                    $destinationItem.Length -ne $initialLength -or $beforeHash -ne $destinationHash -or $destinationHash -ne $afterHash) {
                    throw 'The source changed while it was being snapshotted.'
                }
                [IO.File]::Move($temporary, $Destination)
                return [pscustomobject][ordered]@{
                    RelativePath = $RelativePath
                    Length = [long]$destinationItem.Length
                    Sha256 = $destinationHash
                    SourceLastWriteUtc = $Source.LastWriteTimeUtc.ToString('o')
                    Attempts = $attempt
                }
            }
            catch {
                $lastError = $_.Exception.Message
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                if ($attempt -lt 4) { Start-Sleep -Milliseconds ([int](100 * [Math]::Pow(2, $attempt - 1))) }
            }
        }
        throw "Could not obtain a stable bounded snapshot of '$RelativePath': $lastError"
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Publish-GuestLiveEvidenceFailure {
    param(
        [Parameter(Mandatory = $true)] [string] $CaptureId,
        [string] $RequestId,
        [Parameter(Mandatory = $true)] [string] $Status,
        [Parameter(Mandatory = $true)] [string] $FailureKind,
        [Parameter(Mandatory = $true)] [string] $Message,
        [string] $RequestedUtc,
        [string] $CaptureStartedUtc,
        [Nullable[int]] $ApplicationProcessId
    )

    $stage = Join-Path $script:GuestLiveEvidenceStage ($CaptureId + '-' + [Guid]::NewGuid().ToString('N'))
    $destination = Join-Path $script:GuestLiveEvidenceResponses $CaptureId
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Write-JsonAtomic -Path (Join-Path $stage 'live-evidence-result.json') -Value ([ordered]@{
        FormatVersion = 1
        CaptureId = $CaptureId
        RequestId = $RequestId
        Success = $false
        Status = $Status
        FailureKind = $FailureKind
        Message = $Message
        RequestedUtc = $RequestedUtc
        CaptureStartedUtc = $CaptureStartedUtc
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        ApplicationProcessId = if ($null -ne $ApplicationProcessId) { [int]$ApplicationProcessId } else { $null }
        ApplicationRunningBeforeCapture = $false
        ApplicationRunningAfterCapture = $false
        Screenshot = $null
        GuestEvidenceFiles = @()
    })
    if (Test-Path -LiteralPath $destination -PathType Container) { Remove-Item -LiteralPath $destination -Recurse -Force }
    [IO.Directory]::Move($stage, $destination)
}

function Invoke-GuestLiveEvidenceRequest {
    param(
        [Parameter(Mandatory = $true)] $Command,
        [Parameter(Mandatory = $true)] $Context,
        [Nullable[DateTime]] $NotAfterUtc
    )

    $captureId = [string]$Command.CaptureId
    $requestId = [string]$Command.RequestId
    if (-not (Test-GuestLiveEvidenceIdentifier -Value $captureId) -or -not (Test-GuestLiveEvidenceIdentifier -Value $requestId)) {
        throw 'The guest live evidence command has an invalid capture or request ID.'
    }
    if (-not [string]::Equals($requestId, [string]$Context.RequestId, [StringComparison]::Ordinal) -or
        [int]$Command.ExpectedApplicationProcessId -ne [int]$Context.ApplicationProcessId) {
        Publish-GuestLiveEvidenceFailure -CaptureId $captureId -RequestId $requestId -Status 'StaleWorkerRequestBinding' -FailureKind 'StaleWorkerRequestBinding' -Message 'The guest command does not match the active request/application lease.' -RequestedUtc ([string]$Command.RequestedUtc) -ApplicationProcessId ([int]$Context.ApplicationProcessId)
        return
    }

    $captureStartedUtc = [DateTime]::UtcNow
    $applicationBefore = $null -ne (Get-Process -Id ([int]$Context.ApplicationProcessId) -ErrorAction SilentlyContinue)
    if (-not $applicationBefore) {
        Publish-GuestLiveEvidenceFailure -CaptureId $captureId -RequestId $requestId -Status 'RequestAlreadyTerminal' -FailureKind 'RequestAlreadyTerminal' -Message 'The application process was no longer running when live capture began.' -RequestedUtc ([string]$Command.RequestedUtc) -CaptureStartedUtc $captureStartedUtc.ToString('o') -ApplicationProcessId ([int]$Context.ApplicationProcessId)
        return
    }

    $stage = Join-Path $script:GuestLiveEvidenceStage ($captureId + '-' + [Guid]::NewGuid().ToString('N'))
    $destination = Join-Path $script:GuestLiveEvidenceResponses $captureId
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        if ($null -ne $NotAfterUtc -and [DateTime]::UtcNow -ge [DateTime]$NotAfterUtc) {
            throw '[CAPTURE_INFRASTRUCTURE] Live capture could not start without overrunning the original guest action deadline.'
        }
        $screenshotPath = Join-Path $stage 'live-screenshot.png'
        $capture = Capture-Screen -Path $screenshotPath -TimeoutMilliseconds ([int]$Command.CaptureTimeoutMilliseconds) -Attempts 5
        if ($null -ne $NotAfterUtc -and [DateTime]::UtcNow -ge [DateTime]$NotAfterUtc) {
            throw '[CAPTURE_INFRASTRUCTURE] Live capture did not finish before the original guest action deadline.'
        }
        $screenshotItem = Get-Item -LiteralPath $screenshotPath -Force
        if ($screenshotItem.Length -le 0 -or $screenshotItem.Length -gt 32MB) { throw '[CAPTURE_INFRASTRUCTURE] The fresh screenshot exceeded its bounded size contract.' }
        if ($screenshotItem.LastWriteTimeUtc -lt $captureStartedUtc.AddSeconds(-1)) { throw '[CAPTURE_INFRASTRUCTURE] The screenshot timestamp predates the current capture attempt.' }
        $screenshotHash = (Get-FileHash -LiteralPath $screenshotPath -Algorithm SHA256).Hash
        $screenshotCapturedUtc = [DateTime]::UtcNow

        $evidenceRecords = New-Object Collections.Generic.List[object]
        $totalBytes = [long]0
        $requestedPaths = @($Command.GuestEvidencePaths)
        if ($requestedPaths.Count -gt $script:GuestLiveEvidenceMaximumFileCount) { throw 'Too many guest evidence files were requested.' }
        foreach ($relativePath in $requestedPaths) {
            if ($null -ne $NotAfterUtc -and [DateTime]::UtcNow -ge [DateTime]$NotAfterUtc) {
                throw '[CAPTURE_INFRASTRUCTURE] Guest evidence collection reached the original guest action deadline.'
            }
            $source = Resolve-GuestLiveEvidenceSource -OutputPath ([string]$Context.OutputPath) -RelativePath ([string]$relativePath)
            if ($totalBytes + [long]$source.Length -gt $script:GuestLiveEvidenceMaximumTotalBytes) {
                throw "Guest evidence files exceed the $script:GuestLiveEvidenceMaximumTotalBytes-byte aggregate limit."
            }
            $record = Copy-GuestLiveEvidenceFileStable -Source $source -Destination (Join-Path (Join-Path $stage 'files') ([string]$relativePath)) -RelativePath ([string]$relativePath) -AuthorizedRoot ([string]$Context.OutputPath)
            $totalBytes += [long]$record.Length
            $evidenceRecords.Add($record)
        }
        if ($null -ne $NotAfterUtc -and [DateTime]::UtcNow -ge [DateTime]$NotAfterUtc) {
            throw '[CAPTURE_INFRASTRUCTURE] Guest evidence collection did not finish before the original guest action deadline.'
        }

        $applicationAfter = $null -ne (Get-Process -Id ([int]$Context.ApplicationProcessId) -ErrorAction SilentlyContinue)
        $completedUtc = [DateTime]::UtcNow
        Write-JsonAtomic -Path (Join-Path $stage 'live-evidence-result.json') -Value ([ordered]@{
            FormatVersion = 1
            CaptureId = $captureId
            RequestId = $requestId
            Success = $true
            Status = 'Captured'
            FailureKind = $null
            Message = 'Fresh live evidence was captured from the active interactive guest session.'
            RequestedUtc = [string]$Command.RequestedUtc
            CaptureStartedUtc = $captureStartedUtc.ToString('o')
            CapturedUtc = $screenshotCapturedUtc.ToString('o')
            CompletedUtc = $completedUtc.ToString('o')
            GuestLifecycleStage = [string]$Context.LifecycleStage
            ApplicationProcessId = [int]$Context.ApplicationProcessId
            ApplicationRunningBeforeCapture = [bool]$applicationBefore
            ApplicationRunningAfterCapture = [bool]$applicationAfter
            Screenshot = [ordered]@{
                FileName = 'live-screenshot.png'
                Length = [long]$screenshotItem.Length
                Width = [int]$capture.Width
                Height = [int]$capture.Height
                Sha256 = $screenshotHash
                Attempts = [int]$capture.Attempts
                ElapsedMilliseconds = [double]$capture.ElapsedMilliseconds
            }
            GuestEvidenceFiles = $evidenceRecords.ToArray()
            GuestEvidenceTotalBytes = $totalBytes
        })
        if (Test-Path -LiteralPath $destination -PathType Container) { Remove-Item -LiteralPath $destination -Recurse -Force }
        [IO.Directory]::Move($stage, $destination)
    }
    catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        $failureKind = if ($_.Exception.Message.StartsWith('[CAPTURE_INFRASTRUCTURE]', [StringComparison]::Ordinal)) { 'ScreenshotInfrastructureFailure' } elseif ($_.Exception.Message -like '*reparse*' -or $_.Exception.Message -like '*escapes*' -or $_.Exception.Message -like '*relative path*') { 'GuestEvidencePathRejected' } else { 'GuestEvidenceUnavailable' }
        $status = if ($failureKind -eq 'ScreenshotInfrastructureFailure') { 'ScreenshotInfrastructureFailure' } else { $failureKind }
        Publish-GuestLiveEvidenceFailure -CaptureId $captureId -RequestId $requestId -Status $status -FailureKind $failureKind -Message $_.Exception.Message -RequestedUtc ([string]$Command.RequestedUtc) -CaptureStartedUtc $captureStartedUtc.ToString('o') -ApplicationProcessId ([int]$Context.ApplicationProcessId)
    }
}

function Invoke-GuestLiveEvidenceHeartbeat {
    param([Nullable[DateTime]] $NotAfterUtc)

    if (-not $script:ActiveLiveEvidenceContext -or $script:GuestLiveEvidenceCaptureInProgress) { return }
    if ($null -ne $NotAfterUtc -and ([DateTime]$NotAfterUtc - [DateTime]::UtcNow).TotalMilliseconds -lt 3000) { return }
    $requestFile = @(Get-ChildItem -LiteralPath $script:GuestLiveEvidenceInbox -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc, Name | Select-Object -First 1)
    if ($requestFile.Count -eq 0) { return }

    $captureId = [IO.Path]::GetFileNameWithoutExtension($requestFile[0].Name)
    $processingFile = Join-Path $script:GuestLiveEvidenceProcessing $requestFile[0].Name
    $script:GuestLiveEvidenceCaptureInProgress = $true
    try {
        Move-Item -LiteralPath $requestFile[0].FullName -Destination $processingFile -Force
        $command = Get-Content -LiteralPath $processingFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not [string]::Equals([string]$command.CaptureId, $captureId, [StringComparison]::Ordinal)) { throw 'CaptureId must match the guest request filename.' }
        if ($null -ne $NotAfterUtc) {
            $remainingMilliseconds = [int][Math]::Floor((([DateTime]$NotAfterUtc) - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remainingMilliseconds -lt 3000) { throw '[CAPTURE_INFRASTRUCTURE] Insufficient original action time remains for a live capture.' }
            $boundedCaptureTimeout = [Math]::Min([int]$command.CaptureTimeoutMilliseconds, $remainingMilliseconds)
            $command | Add-Member -NotePropertyName CaptureTimeoutMilliseconds -NotePropertyValue $boundedCaptureTimeout -Force
        }
        Invoke-GuestLiveEvidenceRequest -Command $command -Context $script:ActiveLiveEvidenceContext -NotAfterUtc $NotAfterUtc
    }
    catch {
        if (Test-GuestLiveEvidenceIdentifier -Value $captureId) {
            Publish-GuestLiveEvidenceFailure -CaptureId $captureId -RequestId ([string]$script:ActiveLiveEvidenceContext.RequestId) -Status 'ScreenshotInfrastructureFailure' -FailureKind 'ScreenshotInfrastructureFailure' -Message $_.Exception.Message -ApplicationProcessId ([int]$script:ActiveLiveEvidenceContext.ApplicationProcessId)
        }
    }
    finally {
        Remove-Item -LiteralPath $processingFile -Force -ErrorAction SilentlyContinue
        $script:GuestLiveEvidenceCaptureInProgress = $false
    }
}
