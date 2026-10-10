[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$harnessRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $harnessRoot 'seed\guest\GuestNativeActions.ps1')
$scenarios=New-Object Collections.Generic.List[string]
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Reject { param([scriptblock]$Run) $rejected=$false; try { & $Run } catch { $rejected=$true }; Assert-True $rejected 'Invalid native action was accepted.' }
function Action { param([string]$Json) $Json | ConvertFrom-Json }

$valid=Action '{"type":"wait_content","name":"ready","timeoutMs":500,"notColor":"#000000","minFraction":0.1,"viewport":{"width":320,"height":200,"scaling":"integer_fit"}}'
Assert-NativeAppAction $valid
foreach ($json in @(
    '{"type":"wait_content","name":"bad","timeoutMs":1,"notColor":"#000000","minFraction":0.1}',
    '{"type":"wait_content","name":"bad","timeoutMs":100,"notColor":"#000000","minFraction":0.1,"pixels":[{"x":0,"y":0,"color":"#ffffff"}]}',
    '{"type":"click_client","x":0.5,"y":1}',
    '{"type":"click_client","x":1,"y":1,"script":"arbitrary"}',
    '{"type":"assert_image","name":"bad","referencePath":"C:\\secret.png"}',
    '{"type":"capture_burst","name":"bad","durationMs":100,"fps":61,"maxFrames":10,"maxBytes":10000}',
    '{"type":"capture_burst","name":"bad","durationMs":100,"fps":10,"maxFrames":10,"maxBytes":10000,"trigger":{"type":"send_keys","keys":"ENTER"}}',
    '{"type":"controller","operation":"state","holdMs":10,"buttons":["POWER"]}',
    '{"type":"controller","operation":"state","holdMs":10,"leftX":2}',
    '{"type":"capture_audio","name":"bad","durationMs":30001,"maxBytes":10000}',
    '{"type":"app_command","name":"bad","operation":"exec","timeoutMs":100}',
    '{"type":"app_command","name":"bad","operation":"ready","timeoutMs":100,"jsonPointer":"/x"}'
)) { $bad=Action $json; Reject { Assert-NativeAppAction $bad } }
Reject { Assert-NativeAppActions @($valid,$valid) }
Reject { Assert-NativeAppActions @((1..33 | ForEach-Object { Action '{"type":"click_client","x":0,"y":0}' })) }
$scenarios.Add('bounded-shared-schema-and-collection-validation')

$g=[Codex.NativeApp.Visual]::Layout(1300,820,320,200,'integer_fit')
$p=[Codex.NativeApp.Visual]::MapPoint($g,0,0)
Assert-True ($g.ViewportX -eq 10 -and $g.ViewportY -eq 10 -and $p.X -eq 12 -and $p.Y -eq 12) 'Integer fit did not center the viewport and select the logical pixel center.'
$edge=[Codex.NativeApp.Visual]::MapPoint($g,319,199)
Assert-True ($edge.X -eq 1288 -and $edge.Y -eq 808) 'Last logical pixel escaped the viewport.'
Reject { [Codex.NativeApp.Visual]::MapPoint($g,320,0) }
Reject { [Codex.NativeApp.Visual]::Layout(100,100,320,200,'integer_fit') }
$fit=[Codex.NativeApp.Visual]::Layout(1000,700,320,200,'fit')
$stretch=[Codex.NativeApp.Visual]::Layout(1000,700,320,200,'stretch')
Assert-True ($fit.ViewportHeight -eq 625 -and $fit.ViewportY -eq 37 -and $stretch.ScaleY -eq 3.5) 'Explicit fit/stretch rules diverged.'
$client=[Codex.NativeApp.Visual]::Layout(1300,820,0,0,'')
$clientPoint=[Codex.NativeApp.Visual]::MapPoint($client,50,50)
Assert-True ($client.Scaling -eq 'client' -and $client.LogicalWidth -eq 1300 -and $client.LogicalHeight -eq 820 -and $clientPoint.X -eq 50 -and $clientPoint.Y -eq 50) 'Omitting viewport did not preserve physical client-pixel coordinates.'
$scenarios.Add('viewport-letterbox-edge-and-scaling-geometry')

$repositoryRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $harnessRoot))
$testRoot=Join-Path $repositoryRoot ('work\native-actions-unit-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$reference=[Drawing.Bitmap]::new(4,4)
$actual=[Drawing.Bitmap]::new(4,4)
try {
    foreach ($b in @($reference,$actual)) { $graphics=[Drawing.Graphics]::FromImage($b);try { $graphics.Clear([Drawing.Color]::Black) } finally { $graphics.Dispose() } }
    $actual.SetPixel(1,1,[Drawing.Color]::FromArgb(255,255,0,0))
    $referencePath=Join-Path $testRoot 'reference.png';$reference.Save($referencePath,[Drawing.Imaging.ImageFormat]::Png)
    $frame=[Codex.NativeApp.Frame]::new();$frame.Bitmap=$actual;$frame.Pixels=[Codex.NativeApp.Visual]::ReadPixels($actual)
    $mismatch=[Codex.NativeApp.Visual]::Compare($frame,$referencePath,[Drawing.Rectangle[]]@(),0,0,$null,(Join-Path $testRoot 'diff.png'))
    Assert-True (-not $mismatch.Passed -and $mismatch.MismatchedPixels -eq 1 -and $mismatch.MismatchFraction -eq 0.0625) 'Pixel mismatch metric is incorrect.'
    $masked=[Codex.NativeApp.Visual]::Compare($frame,$referencePath,[Drawing.Rectangle[]]@([Drawing.Rectangle]::new(1,1,1,1)),0,0,$null,$null)
    Assert-True ($masked.Passed -and $masked.ComparedPixels -eq 15) 'Explicit mask did not exclude exactly one pixel.'
    $tolerated=[Codex.NativeApp.Visual]::Compare($frame,$referencePath,[Drawing.Rectangle[]]@(),255,0,$null,$null)
    Assert-True $tolerated.Passed 'Per-channel tolerance was ignored.'
    Reject { [Codex.NativeApp.Visual]::Compare($frame,$referencePath,[Drawing.Rectangle[]]@([Drawing.Rectangle]::new(0,0,4,4)),0,0,$null,$null) }
    Reject { [Codex.NativeApp.Visual]::SavePng($actual,(Join-Path $testRoot 'oversized.png'),1) }
    Assert-True (-not (Test-Path (Join-Path $testRoot 'oversized.png'))) 'Byte rejection left a published frame.'
}
finally { $reference.Dispose();$actual.Dispose() }
$scenarios.Add('numeric-visual-masks-tolerances-and-atomic-byte-limit')

# No desktop capture: these synthetic frames exercise readiness timing itself.
function Get-NativeFrame {
    param($Action,[IntPtr]$Window)
    $f=[Codex.NativeApp.Frame]::new();$f.Bitmap=[Drawing.Bitmap]::new(2,2);$f.Pixels=[Codex.NativeApp.Visual]::ReadPixels($f.Bitmap);$f.StartedUtc=[DateTime]::UtcNow;$f.CompletedUtc=[DateTime]::UtcNow;$f
}
function Invoke-GuestLiveEvidenceHeartbeat { param($NotAfterUtc) }
$script:sample=0
function Test-NativeContent { param($Action,$Frame) $script:sample++;[pscustomobject]@{Passed=($script:sample -eq 1)} }
$wait=Action '{"type":"wait_content","name":"transient","timeoutMs":125,"pollMs":25,"stableMs":75,"notColor":"#000000","minFraction":0.1}'
$transientRoot=Join-Path $testRoot 'transient';New-Item -ItemType Directory -Path $transientRoot | Out-Null
$timed=Invoke-NativeVisualAction $wait ([IntPtr]::Zero) $transientRoot
Assert-True (-not $timed.Passed -and $timed.FailureKind -eq 'ContentReadinessTimeout' -and $timed.Samples -gt 1 -and (Test-Path (Join-Path $transientRoot 'actual.png'))) 'A transient readiness match bypassed stability or lost its final frame.'
$scenarios.Add('readiness-stability-timeout-retains-evidence')

$script:triggerCount=0
function Invoke-NativeClientClick { param($Action,[IntPtr]$Window) $script:triggerCount++;@{SyntheticUnitTrigger=$true} }
$burst=Action '{"type":"capture_burst","name":"burst","durationMs":200,"fps":10,"maxFrames":2,"maxBytes":1024,"trigger":{"type":"click_client","x":0,"y":0}}'
$burstRoot=Join-Path $testRoot 'burst';New-Item -ItemType Directory -Path $burstRoot | Out-Null
$captured=Invoke-NativeVisualAction $burst ([IntPtr]::Zero) $burstRoot
Assert-True ($captured.FrameCount -eq 2 -and $captured.EvidenceBytes -le 1024 -and $script:triggerCount -eq 1 -and $captured.Frames[0].ElapsedMs -le $captured.Trigger.StartedMs) 'Burst failed its frame/byte/one-shot-after-first-frame contract.'
$scenarios.Add('burst-bounds-and-single-trigger-after-initial-frame')

# Import only the existing JSON assertion functions; no guest job or input runs.
$guestAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $harnessRoot 'seed\guest\GuestAgent.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Resolve-JsonPointerValue','Test-IsJsonNumber','Test-JsonValuesEqual','Test-GuestResultAssertion')) {
    $definition=$guestAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-JsonAtomic { param($Path,$Value) $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8 }
$script:wrongIdentity=$false
function Wait-GuestResultFile {
    param($Path,$TimeoutMilliseconds)
    $command=Get-Content -LiteralPath $Path.Replace('.response.json','.command.json') -Raw | ConvertFrom-Json
    @{protocol='codex-app-test-v1';requestId=$command.requestId;id=$(if($script:wrongIdentity){'stale'}else{$command.id});operation=$command.operation;ok=$true;state=@{ticks=10}} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    [pscustomobject]@{Found=$true;ElapsedMilliseconds=1}
}
$protocolAction=Action '{"type":"app_command","name":"ready","operation":"ready","timeoutMs":500,"jsonPointer":"/state/ticks","equalsJson":"10"}'
$protocolRoot=Join-Path $testRoot 'protocol';New-Item -ItemType Directory -Path $protocolRoot | Out-Null
$script:NativeAppProtocolReady=$false
$ack=Invoke-NativeAppCommand $protocolAction $testRoot $protocolRoot 'unit-job'
Assert-True ($ack.Passed -and $script:NativeAppProtocolReady -and $ack.Assertion.Passed) 'Opt-in handshake did not validate identity and typed JSON state.'
$script:wrongIdentity=$true
Reject { Invoke-NativeAppCommand $protocolAction $testRoot $protocolRoot 'unit-job' }
$script:NativeAppProtocolReady=$false
$noReady=Invoke-NativeAppCommand (Action '{"type":"app_command","name":"advance","operation":"advance","ticks":1,"timeoutMs":100}') $testRoot $protocolRoot 'unit-job'
Assert-True ($noReady.FailureKind -eq 'CapabilityUnavailable') 'Commands were issued before an acknowledged ready handshake.'
$scenarios.Add('application-protocol-opt-in-identity-and-existing-json-assertions')
[pscustomobject]@{Success=$true;ScenarioCount=$scenarios.Count;Scenarios=$scenarios.ToArray();EvidenceRoot=$testRoot} | ConvertTo-Json -Depth 8
