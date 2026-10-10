$nativeContractPath=Join-Path $PSScriptRoot 'NativeAppContract.ps1'
if (-not (Test-Path -LiteralPath $nativeContractPath)) { $nativeContractPath=Join-Path $PSScriptRoot '..\..\..\Skill\scripts\NativeAppContract.ps1' }
. $nativeContractPath
if (-not ('Codex.NativeApp.Visual' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeAppSupport.cs') -ReferencedAssemblies System.dll,System.Drawing.dll,System.Windows.Forms.dll
}
if (-not ('Codex.NativeApp.Audio' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'NativeAudio.cs') }
. (Join-Path $PSScriptRoot 'GuestNativeDevices.ps1')

function Get-NativeGeometry {
    param($Action, [IntPtr]$Window)
    [Codex.NativeApp.Visual]::Measure($Window, [int]$Action.viewport.width, [int]$Action.viewport.height, [string]$Action.viewport.scaling)
}

function Get-NativeFrame {
    param($Action, [IntPtr]$Window)
    [Codex.NativeApp.Visual]::Capture($Window, [int]$Action.viewport.width, [int]$Action.viewport.height, [string]$Action.viewport.scaling,
        [int]$Action.region.x, [int]$Action.region.y, [int]$Action.region.width, [int]$Action.region.height)
}

function Get-NativeMasks {
    param($Action)
    foreach ($mask in @($Action.masks)) {
        if ($null -ne $mask) { [Drawing.Rectangle]::new([int]$mask.x,[int]$mask.y,[int]$mask.width,[int]$mask.height) }
    }
}

function Invoke-NativeClientClick {
    param($Action, [IntPtr]$Window)
    $geometry = Get-NativeGeometry $Action $Window
    $point = [Codex.NativeApp.Visual]::MapPoint($geometry,[int]$Action.x,[int]$Action.y)
    [CodexGuestInput]::ClickLeftPhysical($point.X,$point.Y)
    [ordered]@{ Geometry=$geometry; LogicalX=[int]$Action.x; LogicalY=[int]$Action.y; ScreenX=$point.X; ScreenY=$point.Y; PixelSelection='CenterOfLogicalPixel' }
}

function Test-NativeContent {
    param($Action, $Frame)
    $tolerance = [int]$Action.channelTolerance
    if ($Action.referencePath) {
        return [Codex.NativeApp.Visual]::Compare($Frame,[string]$Action.referencePath,[Drawing.Rectangle[]]@(Get-NativeMasks $Action),$tolerance,[double]$Action.maxMismatchFraction,$null,$null)
    }
    if ($Action.notColor) {
        $fraction = [Codex.NativeApp.Visual]::FractionDifferent($Frame,[Convert]::ToInt32(([string]$Action.notColor).Substring(1),16),$tolerance)
        return [pscustomobject]@{ Passed=($fraction -ge [double]$Action.minFraction); FractionDifferent=$fraction; MinimumFraction=[double]$Action.minFraction }
    }
    $matched = 0
    foreach ($pixel in @($Action.pixels)) {
        if ([Codex.NativeApp.Visual]::PixelMatches($Frame,[int]$pixel.x,[int]$pixel.y,[Convert]::ToInt32(([string]$pixel.color).Substring(1),16),$tolerance)) { $matched++ }
    }
    [pscustomobject]@{ Passed=($matched -eq @($Action.pixels).Count); MatchedPixels=$matched; RequiredPixels=@($Action.pixels).Count }
}

function Invoke-NativeVisualAction {
    param($Action, [IntPtr]$Window, [string]$Directory)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $frame = $null
    try {
        if ($Action.type -eq 'wait_content') {
            $stableSince = $null
            $poll = if ($null -ne $Action.pollMs) { [int]$Action.pollMs } else { 100 }
            $samples = 0; $passed = $false
            do {
                if ($null -ne $frame) { $frame.Dispose(); $frame=$null }
                $frame = Get-NativeFrame $Action $Window
                $condition = Test-NativeContent $Action $frame
                $samples++
                if ($condition.Passed) {
                    if ($null -eq $stableSince) { $stableSince=$watch.Elapsed.TotalMilliseconds }
                    $passed = ($watch.Elapsed.TotalMilliseconds - $stableSince -ge [int]$Action.stableMs) -and ($watch.Elapsed.TotalMilliseconds -le [int]$Action.timeoutMs)
                    if ($passed) { break }
                }
                else { $stableSince=$null }
                $remaining=[int]$Action.timeoutMs-$watch.Elapsed.TotalMilliseconds
                if ($remaining -le 0) { break }
                Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc ([DateTime]::UtcNow.AddMilliseconds($remaining))
                $remaining=[int]$Action.timeoutMs-$watch.Elapsed.TotalMilliseconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($poll,$remaining)) }
            } while ($watch.Elapsed.TotalMilliseconds -lt [int]$Action.timeoutMs)
            [Codex.NativeApp.Visual]::SavePng($frame.Bitmap,(Join-Path $Directory 'actual.png'),33554432)
            return [ordered]@{ Evaluated=$true; Passed=$passed; FailureKind=$(if (-not $passed) { 'ContentReadinessTimeout' }); Geometry=$frame.Geometry; Samples=$samples; ElapsedMs=$watch.Elapsed.TotalMilliseconds; StableMs=[int]$Action.stableMs; StabilityMeaning='Condition continuously matched at each sampled frame'; LastCondition=$condition; Actual='actual.png' }
        }
        if ($Action.type -eq 'assert_image') {
            $frame = Get-NativeFrame $Action $Window
            [Codex.NativeApp.Visual]::SavePng($frame.Bitmap,(Join-Path $Directory 'actual.png'),33554432)
            $comparison = [Codex.NativeApp.Visual]::Compare($frame,[string]$Action.referencePath,[Drawing.Rectangle[]]@(Get-NativeMasks $Action),[int]$Action.channelTolerance,[double]$Action.maxMismatchFraction,(Join-Path $Directory 'reference.png'),(Join-Path $Directory 'diff.png'))
            return [ordered]@{ Evaluated=$true; Passed=$comparison.Passed; FailureKind=$(if (-not $comparison.Passed) { 'VisualAssertion' }); Geometry=$frame.Geometry; Region=$Action.region; Masks=@($Action.masks); ChannelTolerance=[int]$Action.channelTolerance; MaximumMismatchFraction=[double]$Action.maxMismatchFraction; Metrics=$comparison; Actual='actual.png'; Reference='reference.png'; Diff='diff.png'; ReferenceSha256=(Get-FileHash -LiteralPath $Action.referencePath -Algorithm SHA256).Hash; CaptureStartedUtc=$frame.StartedUtc.ToString('o'); CaptureCompletedUtc=$frame.CompletedUtc.ToString('o') }
        }
        $frames=New-Object Collections.Generic.List[object]
        $bytes=0L; $trigger=$null; $stopReason='Duration'; $slot=0
        # Capture the first frame before triggering input. All helpers were loaded
        # before application launch; no process/PowerShell startup occurs per frame.
        while ($frames.Count -lt [int]$Action.maxFrames -and $watch.Elapsed.TotalMilliseconds -lt [int]$Action.durationMs) {
            if ($null -ne $frame) { $frame.Dispose(); $frame=$null }
            $frame=Get-NativeFrame $Action $Window
            $capturedMs=$watch.Elapsed.TotalMilliseconds
            $name='frame-{0:D4}.png' -f $frames.Count
            try { [Codex.NativeApp.Visual]::SavePng($frame.Bitmap,(Join-Path $Directory $name),([long]$Action.maxBytes-$bytes)) }
            catch { if ($_.Exception.Message -like '*EvidenceByteLimit*') { $stopReason='EvidenceByteLimit'; break }; throw }
            $length=(Get-Item -LiteralPath (Join-Path $Directory $name)).Length; $bytes+=$length
            $frames.Add([ordered]@{ File=$name; StartedUtc=$frame.StartedUtc.ToString('o'); CompletedUtc=$frame.CompletedUtc.ToString('o'); ElapsedMs=$capturedMs; Bytes=$length; Geometry=$frame.Geometry })
            if ($frames.Count -eq 1 -and $Action.trigger) {
                $trigger=[ordered]@{ StartedMs=$watch.Elapsed.TotalMilliseconds; Click=(Invoke-NativeClientClick $Action.trigger $Window); CompletedMs=$watch.Elapsed.TotalMilliseconds }
            }
            $slot=[Math]::Max($slot+1,[Math]::Ceiling($watch.Elapsed.TotalMilliseconds*[int]$Action.fps/1000.0))
            $wait=[Math]::Min([int]$Action.durationMs,$slot*1000.0/[int]$Action.fps)-$watch.Elapsed.TotalMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($wait)) }
        }
        if ($frames.Count -ge [int]$Action.maxFrames) { $stopReason='FrameLimit' }
        [ordered]@{ Evaluated=$false; Passed=$null; Frames=$frames.ToArray(); FrameCount=$frames.Count; EvidenceBytes=$bytes; RequestedFps=[int]$Action.fps; RequestedDurationMs=[int]$Action.durationMs; ElapsedMs=$watch.Elapsed.TotalMilliseconds; StopReason=$stopReason; Trigger=$trigger; Timing='Best effort visible desktop samples; PNG encoding included between frames; timestamps bound acquisition, not application presentation'; FailureKind=$(if ($frames.Count -eq 0) { 'EvidenceByteLimit' }) }
    }
    finally { if ($null -ne $frame) { $frame.Dispose() } }
}

function Invoke-NativeAppCommand {
    param($Action, [string]$OutputRoot, [string]$Directory, [string]$JobId)
    if ($Action.operation -ne 'ready' -and -not $script:NativeAppProtocolReady) {
        return [ordered]@{ Evaluated=$false; Passed=$null; FailureKind='CapabilityUnavailable'; Error='Application protocol requires a successful ready handshake first.' }
    }
    $protocolRoot=Join-Path $OutputRoot 'app-protocol'
    New-Item -ItemType Directory -Path $protocolRoot -Force | Out-Null
    $nonce=[Guid]::NewGuid().ToString('N')
    $command=[ordered]@{ protocol='codex-app-test-v1'; requestId=$JobId; id=$nonce; operation=[string]$Action.operation }
    if ($Action.operation -eq 'seed') { $command['seed']=[int]$Action.seed }
    if ($Action.operation -eq 'advance') { $command['ticks']=[int]$Action.ticks }
    $commandPath=Join-Path $protocolRoot ($nonce+'.command.json')
    $responsePath=Join-Path $protocolRoot ($nonce+'.response.json')
    Write-JsonAtomic -Path $commandPath -Value $command
    $wait=Wait-GuestResultFile -Path $responsePath -TimeoutMilliseconds ([int]$Action.timeoutMs)
    if (-not $wait.Found) {
        return [ordered]@{ Evaluated=($Action.operation -ne 'ready'); Passed=$false; FailureKind=$(if ($Action.operation -eq 'ready') { 'CapabilityUnavailable' } else { 'ApplicationProtocolTimeout' }); Error='Application did not acknowledge the opt-in codex-app-test-v1 command within its deadline.'; Command=$command; ElapsedMs=$wait.ElapsedMilliseconds }
    }
    if ((Get-Item -LiteralPath $responsePath).Length -gt 1048576) { throw 'Application protocol response exceeds 1 MiB.' }
    $response=Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($response.protocol -cne 'codex-app-test-v1' -or $response.id -cne $nonce -or $response.requestId -cne $JobId -or $response.operation -cne $Action.operation -or $response.ok -isnot [bool]) { throw 'Application protocol acknowledgement identity/schema mismatch.' }
    $passed=[bool]$response.ok
    if ($Action.operation -eq 'ready' -and $passed) { $script:NativeAppProtocolReady=$true }
    $assertion=$null
    if ($passed -and $null -ne $Action.jsonPointer) {
        $assertion=Test-GuestResultAssertion -Path $responsePath -JsonPointer ([string]$Action.jsonPointer) -ExpectedJson ([string]$Action.equalsJson)
        $passed=[bool]$assertion.Passed
    }
    Copy-Item -LiteralPath $responsePath -Destination (Join-Path $Directory 'response.json')
    [ordered]@{ Evaluated=$true; Passed=$passed; FailureKind=$(if (-not $passed) { 'ApplicationProtocolAssertion' }); Command=$command; Response='response.json'; Assertion=$assertion; ElapsedMs=$wait.ElapsedMilliseconds }
}

function Invoke-NativeAppAction {
    param($Action, [IntPtr]$Window, [string]$OutputRoot, [string]$JobId)
    Assert-NativeAppAction $Action -ExpandedPaths
    if ($Action.type -eq 'click_client') { return [ordered]@{ Evaluated=$false; Passed=$null; Click=(Invoke-NativeClientClick $Action $Window) } }
    if ($Action.type -eq 'controller') { return Invoke-NativeController $Action }
    $directory=Join-Path $OutputRoot ('native-'+$Action.name)
    if (Test-Path -LiteralPath $directory) { throw "Native evidence identifier is already used: $($Action.name)" }
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $result=switch ($Action.type) {
            'app_command' { Invoke-NativeAppCommand $Action $OutputRoot $directory $JobId }
            { $_ -in @('audio_probe','capture_audio') } { Invoke-NativeAudio $Action $directory }
            default { Invoke-NativeVisualAction $Action $Window $directory }
        }
        $result['EvidenceDirectory']='native-'+$Action.name
        Write-JsonAtomic -Path (Join-Path $directory 'metadata.json') -Value $result
        return $result
    }
    catch {
        Write-JsonAtomic -Path (Join-Path $directory 'error.json') -Value @{ Action=[string]$Action.type; Error=$_.Exception.Message; Utc=[DateTime]::UtcNow.ToString('o') }
        throw
    }
}
