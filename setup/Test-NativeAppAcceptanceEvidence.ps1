[CmdletBinding()]
param([Parameter(Mandatory=$true)]$Results)
$ErrorActionPreference='Stop'
function Read-Evidence { param([string]$Root,[string]$Path) Get-Content -LiteralPath (Join-Path $Root $Path) -Raw -Encoding UTF8 | ConvertFrom-Json }
$visual=$Results.NativeVisualProtocol
$guest=Read-Evidence $visual.ResultPath 'result.json'
$clientClick=@($guest.Actions | Where-Object { $_.Type -eq 'click_client' })[0]
if ($clientClick.Details.Click.Geometry.Scaling -ne 'client' -or $clientClick.Details.Click.Geometry.ScaleX -ne 1 -or $clientClick.Details.Click.Geometry.ScaleY -ne 1) { throw 'Physical client-pixel click geometry was not retained.' }
$reference=Read-Evidence $visual.ResultPath 'native-reference\metadata.json'
if (-not $reference.Passed -or $reference.Metrics.MismatchedPixels -ne 0 -or $reference.Geometry.Scaling -ne 'integer_fit') { throw 'Native visual acceptance did not match the normalized reference exactly.' }
foreach ($name in @('actual.png','reference.png','diff.png')) {
    if (-not (Test-Path -LiteralPath (Join-Path $visual.ResultPath ('native-reference\'+$name)))) { throw "Native visual evidence missing: $name" }
}
$first=Read-Evidence $visual.ResultPath 'native-advance\response.json'
$second=Read-Evidence $visual.ResultPath 'native-advance-again\response.json'
$expected=123L
for ($i=0;$i -lt 10;$i++) { $expected=($expected*1664525L+1013904223L) -band 4294967295L }
if ($first.state.ticks -ne 10 -or $first.state.value -ne $expected -or $second.state.value -ne $expected -or $first.id -ceq $second.id) { throw 'Fresh deterministic protocol acknowledgements did not reproduce the seeded state.' }
$burst=Read-Evidence $visual.ResultPath 'native-effect\metadata.json'
if ($burst.FrameCount -lt 3 -or $burst.FrameCount -gt 24 -or $burst.EvidenceBytes -gt 16777216 -or -not $burst.Trigger -or $burst.Frames[0].ElapsedMs -gt $burst.Trigger.StartedMs) { throw 'Burst limits or capture-before-input timing were not proven.' }
Add-Type -AssemblyName System.Drawing
$sawFlash=$false;$sawCleared=$false;$prior=-1.0
foreach ($frame in $burst.Frames) {
    if ($frame.ElapsedMs -lt $prior -or [DateTime]$frame.StartedUtc -gt [DateTime]$frame.CompletedUtc) { throw 'Burst timestamps are not monotonic acquisition bounds.' }
    $prior=[double]$frame.ElapsedMs
    $bitmap=[Drawing.Bitmap]::new((Join-Path $visual.ResultPath ('native-effect\'+$frame.File)))
    try {
        $pixel=$bitmap.GetPixel(70,40)
        if ($pixel.R -eq 255 -and $pixel.G -eq 165 -and $pixel.B -eq 0) { $sawFlash=$true }
        if ($sawFlash -and $pixel.R -eq 25 -and $pixel.G -eq 25 -and $pixel.B -eq 112) { $sawCleared=$true }
    }
    finally { $bitmap.Dispose() }
}
if (-not $sawFlash -or -not $sawCleared) { throw 'Burst did not capture both the transient effect and its disappearance.' }
$capabilities=[ordered]@{}
foreach ($name in @('NativeController','NativeAudio')) {
    $summary=$Results[$name]
    if ($summary.FailureKind -eq 'CapabilityUnavailable') {
        $guest=Read-Evidence $summary.ResultPath 'result.json'
        $failure=@($guest.Actions | Where-Object { $_.Details -and $_.Details.FailureKind -eq 'CapabilityUnavailable' })[0]
        $capabilities[$name]=@{Status='Unavailable';Reason=$failure.Details.Error;RequestId=$summary.RequestId}
    }
    elseif ($name -eq 'NativeController') {
        $pad=Read-Evidence $summary.ResultPath 'controller-a.json'
        if (-not $pad.passed -or $pad.backend -cne 'XInput' -or $pad.physicalXboxVerified) { throw 'Controller acceptance did not prove application reception through XInput.' }
        $capabilities[$name]=@{Status='Available';Proof='Virtual controller received through XInput; physical Xbox and Godot application behavior unverified';RequestId=$summary.RequestId}
    }
    else {
        $audio=Read-Evidence $summary.ResultPath 'native-audio\metadata.json'
        $wave=Join-Path $summary.ResultPath 'native-audio\playback.wav'
        if ($audio.ProofLevel -cne 'GuestRenderEndpointLoopback' -or -not $audio.Capture.PlaybackPacketsObserved -or $audio.Capture.CapturedFrames -le 0 -or -not (Test-Path -LiteralPath $wave) -or (Get-Item -LiteralPath $wave).Length -gt 4194304) { throw 'Audio acceptance did not capture bounded playback packets from a guest render endpoint.' }
        $capabilities[$name]=@{Status='Available';Proof='Guest endpoint loopback packets; physical speaker audibility unverified';Endpoint=$audio.Capture.EndpointId;RequestId=$summary.RequestId}
    }
}
[pscustomobject]@{Success=$true;VisualAndDeterministicProtocolVerified=$true;ReadinessTimeoutVerified=$true;Capabilities=$capabilities}
