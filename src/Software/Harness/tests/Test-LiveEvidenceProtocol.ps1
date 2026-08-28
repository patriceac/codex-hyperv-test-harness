[CmdletBinding()]
param(
    [string] $HarnessRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$liveModulePath = Join-Path $HarnessRoot 'LiveEvidence.ps1'
$hostBrokerPath = Join-Path $HarnessRoot 'HostBroker.ps1'
$guestModulePath = Join-Path $HarnessRoot 'seed\guest\GuestLiveEvidence.ps1'
$clientPath = Join-Path (Split-Path -Parent $HarnessRoot) 'Skill\scripts\Capture-HyperVExecutableTestLiveEvidence.ps1'
$installerPath = Join-Path $HarnessRoot 'Install-PoolHostBroker.ps1'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Operation, [string] $Message)
    $threw = $false
    try { & $Operation } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

function Import-NamedFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw $parseErrors[0].Message }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

function Write-JsonAtomic {
    param([string] $Path, $Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if ([IO.File]::Exists($Path)) {
            $backup = $temporary + '.bak'
            try { [IO.File]::Replace($temporary, $Path, $backup, $true) } finally { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
        }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

. $liveModulePath
Import-NamedFunction -Path $hostBrokerPath -Name 'Publish-HostLiveEvidenceDirectoryAtomic'
Import-NamedFunction -Path $hostBrokerPath -Name 'New-HostLiveEvidenceDirectorySecurity'
Import-NamedFunction -Path $hostBrokerPath -Name 'Set-HostLiveEvidencePublishedAcl'
Import-NamedFunction -Path $hostBrokerPath -Name 'Get-HostLiveEvidenceInventoryTotalBytes'
Import-NamedFunction -Path $guestModulePath -Name 'Resolve-GuestLiveEvidenceSource'
Import-NamedFunction -Path $guestModulePath -Name 'Initialize-GuestLiveEvidenceNativeMethods'
Import-NamedFunction -Path $guestModulePath -Name 'Copy-GuestLiveEvidenceFileStable'
Import-NamedFunction -Path (Join-Path $HarnessRoot 'seed\guest\GuestAgent.ps1') -Name 'Wait-GuestResultFile'
Import-NamedFunction -Path $clientPath -Name 'Assert-ClientLiveEvidencePaths'

$scenarios = New-Object Collections.Generic.List[string]
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-live-evidence-' + [Guid]::NewGuid().ToString('N'))
$script:workerStates = @()

function Get-PoolWorkerStates { param([string] $BrokerRoot, $Config) @($script:workerStates) }

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    $accepted = @(Assert-LiveEvidenceRelativePaths -Paths @('release-gate-progress.json', 'milestones/phase-2.png'))
    Assert-True ($accepted.Count -eq 2 -and $accepted[1] -eq 'milestones\phase-2.png') 'Valid guest evidence paths were not normalized.'
    foreach ($unsafe in @('..\escape.json', 'C:\escape.json', '\\server\share.json', 'milestones\*.png', 'file.json:stream', 'a\\b.json', '.\x.json')) {
        Assert-Throws -Operation { Assert-LiveEvidenceRelativePaths -Paths @($unsafe) | Out-Null } -Message "Unsafe path was accepted: $unsafe"
        Assert-Throws -Operation { Assert-ClientLiveEvidencePaths -Paths @($unsafe) | Out-Null } -Message "The client accepted an unsafe path: $unsafe"
    }
    Assert-Throws -Operation { Assert-LiveEvidenceRelativePaths -Paths @('x.json', 'X.JSON') | Out-Null } -Message 'Case-insensitive duplicate paths were accepted.'
    Assert-Throws -Operation { Assert-LiveEvidenceRelativePaths -Paths @(1..17 | ForEach-Object { "file-$_.json" }) | Out-Null } -Message 'More than 16 guest paths were accepted.'
    $scenarios.Add('client-and-broker-relative-path-validation')

    $outDir = Join-Path $testRoot 'outdir'
    $outside = Join-Path $testRoot 'outside'
    New-Item -ItemType Directory -Force -Path $outDir, $outside | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $outDir 'progress.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $outside 'secret.json') -Encoding UTF8
    $resolved = Resolve-GuestLiveEvidenceSource -OutputPath $outDir -RelativePath 'progress.json'
    Assert-True ([string]$resolved.Name -eq 'progress.json') 'A normal file below OUTDIR was not resolved.'
    $junction = Join-Path $outDir 'linked'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws -Operation { Resolve-GuestLiveEvidenceSource -OutputPath $outDir -RelativePath 'linked\secret.json' | Out-Null } -Message 'A reparse-point traversal was accepted.'
    $scenarios.Add('guest-outdir-and-reparse-protection')

    $script:GuestLiveEvidenceMaximumFileBytes = 4MB
    $stableSource = Get-Item -LiteralPath (Join-Path $outDir 'progress.json')
    $stableDestination = Join-Path $testRoot 'stable-copy\progress.json'
    $stableRecord = Copy-GuestLiveEvidenceFileStable -Source $stableSource -Destination $stableDestination -RelativePath 'progress.json' -AuthorizedRoot $outDir
    Assert-True ((Get-FileHash -LiteralPath $stableDestination -Algorithm SHA256).Hash -eq [string]$stableRecord.Sha256) 'The bounded stable copy did not preserve its verified hash.'
    Assert-Throws -Operation { Copy-GuestLiveEvidenceFileStable -Source (Get-Item -LiteralPath (Join-Path $junction 'secret.json')) -Destination (Join-Path $testRoot 'stable-copy\escaped.json') -RelativePath 'linked\secret.json' -AuthorizedRoot $outDir | Out-Null } -Message 'The opened-handle final-path check accepted a source outside {OUTDIR}.'
    $dictionaryInventoryBytes = Get-HostLiveEvidenceInventoryTotalBytes -Inventory @([ordered]@{ Length = 2 }, [ordered]@{ Length = 3 })
    Assert-True ($dictionaryInventoryBytes -eq 5) 'The host inventory byte total does not support the ordered dictionaries returned by Windows PowerShell remoting.'

    $script:deadlineProbePath = Join-Path $outDir 'deadline-probe.json'
    Set-Item -LiteralPath 'Function:\script:Invoke-GuestLiveEvidenceHeartbeat' -Value {
        param([Nullable[DateTime]] $NotAfterUtc)
        '{"late":true}' | Set-Content -LiteralPath $script:deadlineProbePath -Encoding UTF8
        Start-Sleep -Milliseconds 150
    }
    try {
        $deadlineProbe = Wait-GuestResultFile -Path $script:deadlineProbePath -TimeoutMilliseconds 100
        Assert-True (-not [bool]$deadlineProbe.Found -and (Test-Path -LiteralPath $script:deadlineProbePath -PathType Leaf)) 'A result published only while live capture overran the action deadline was accepted as on-time.'
    }
    finally {
        Remove-Item -LiteralPath 'Function:\script:Invoke-GuestLiveEvidenceHeartbeat' -Force -ErrorAction SilentlyContinue
    }
    $scenarios.Add('guest-action-deadline-preservation')

    $oversizedPath = Join-Path $outDir 'oversized.bin'
    $oversizedStream = [IO.File]::Open($oversizedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedStream.SetLength(4MB + 1) } finally { $oversizedStream.Dispose() }
    Assert-Throws -Operation { Copy-GuestLiveEvidenceFileStable -Source (Get-Item -LiteralPath $oversizedPath) -Destination (Join-Path $testRoot 'stable-copy\oversized.bin') -RelativePath 'oversized.bin' -AuthorizedRoot $outDir | Out-Null } -Message 'An oversized guest evidence file was copied.'
    $hostBrokerText = Get-Content -LiteralPath $hostBrokerPath -Raw
    Assert-True ($hostBrokerText.Contains('C:\Windows\Temp\CodexLiveEvidenceHostStage') -and $hostBrokerText.Contains('Source grew beyond its broker transfer bound') -and $hostBrokerText.Contains('$stageAcl.SetAccessRuleProtection($true, $false)')) 'The host broker is missing its ACL-restricted bounded guest staging contract.'
    $guestAgentText = Get-Content -LiteralPath (Join-Path $HarnessRoot 'seed\guest\GuestAgent.ps1') -Raw
    Assert-True ($guestAgentText.Contains('Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc $deadline') -and $guestAgentText.Contains('Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc $waitDeadline') -and $guestAgentText.Contains('$process.ExitTime.ToUniversalTime() -le $waitDeadline')) 'Live observation is not charged against the original guest action deadlines.'
    $scenarios.Add('bounded-stable-copy-and-private-host-stage')

    $brokerRoot = Join-Path $testRoot 'broker'
    foreach ($path in @('Requests', 'Processing', 'Results', 'LiveEvidence\Requests', 'LiveEvidence\Processing', 'LiveEvidence\Responses')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $brokerRoot $path) | Out-Null
    }
    $config = [pscustomobject]@{ PoolEnabled = $true; PoolMaxWorkers = 1 }
    $requestId = 'active-request'
    $requestResult = Join-Path (Join-Path $brokerRoot 'Results') $requestId
    New-Item -ItemType Directory -Force -Path $requestResult | Out-Null
    Write-JsonAtomic -Path (Join-Path (Join-Path $brokerRoot 'Processing') ($requestId + '.json')) -Value ([ordered]@{ RequestId = $requestId })
    Write-JsonAtomic -Path (Join-Path $requestResult 'request-state.json') -Value ([ordered]@{ RequestId = $requestId; Status = 'GuestAction'; WorkerId = 1; ApplicationProcessId = 4242 })
    Write-JsonAtomic -Path (Join-Path $requestResult 'client-state.json') -Value ([ordered]@{ RequestId = $requestId; Status = 'GuestAction' })
    $script:workerStates = @([pscustomobject]@{
        WorkerId = 1
        Status = 'Leased'
        RequestId = $requestId
        OperationId = 'operation-one'
        ProcessId = $PID
        ProcessStartUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
    })
    $validBinding = Get-LiveEvidencePoolBinding -BrokerRoot $brokerRoot -Config $config -RequestId $requestId -ExpectedWorkerId 1 -ExpectedOperationId 'operation-one'
    Assert-True ([bool]$validBinding.Valid) 'A current broker/worker/request binding was rejected.'
    Assert-True ((Get-LiveEvidenceLifecycleDisposition -LifecycleStage 'GuestAction' -ApplicationProcessId 4242) -eq 'Supported') 'A broker-confirmed guest wait was not recognized as live-capture eligible.'
    Assert-True (-not (Get-LiveEvidencePoolBinding -BrokerRoot $brokerRoot -Config $config -RequestId $requestId -ExpectedWorkerId 2 -ExpectedOperationId 'operation-one').Valid) 'A stale worker ID was accepted.'
    Assert-True (-not (Get-LiveEvidencePoolBinding -BrokerRoot $brokerRoot -Config $config -RequestId $requestId -ExpectedWorkerId 1 -ExpectedOperationId 'operation-old').Valid) 'A stale worker operation was accepted.'
    $scenarios.Add('current-and-stale-worker-binding-validation')

    function Submit-LiveCommand {
        param([string] $CaptureId, [string] $TargetRequestId)
        Write-JsonAtomic -Path (Join-Path (Join-Path $brokerRoot 'LiveEvidence\Requests') ($CaptureId + '.json')) -Value ([ordered]@{
            FormatVersion = 1
            CaptureId = $CaptureId
            RequestId = $TargetRequestId
            RequestedUtc = [DateTime]::UtcNow.ToString('o')
            RequestedBy = 'test'
            GuestEvidencePaths = @('release-gate-progress.json')
            CaptureTimeoutMilliseconds = 5000
        })
        Route-LiveEvidenceRequests -BrokerRoot $brokerRoot -Config $config
    }

    Write-JsonAtomic -Path (Join-Path $brokerRoot 'LiveEvidence\Requests\capture-invalid.json') -Value ([ordered]@{
        FormatVersion = 99
        CaptureId = 'capture-invalid'
        RequestId = $requestId
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        GuestEvidencePaths = @()
        CaptureTimeoutMilliseconds = 5000
    })
    Route-LiveEvidenceRequests -BrokerRoot $brokerRoot -Config $config
    $invalid = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-invalid.json')
    Assert-True ([string]$invalid.Status -eq 'Rejected' -and [string]$invalid.FailureKind -eq 'Validation') 'An unsupported command schema was not rejected before routing.'
    $scenarios.Add('command-schema-validation')

    Submit-LiveCommand -CaptureId 'capture-not-found' -TargetRequestId 'missing-request'
    $notFound = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-not-found.json')
    Assert-True ($notFound -and [string]$notFound.Status -eq 'RequestNotFound') ("RequestNotFound was not distinguished: " + ($notFound | ConvertTo-Json -Depth 5 -Compress))

    $queuedId = 'queued-request'
    Write-JsonAtomic -Path (Join-Path (Join-Path $brokerRoot 'Requests') ($queuedId + '.json')) -Value ([ordered]@{ RequestId = $queuedId })
    Submit-LiveCommand -CaptureId 'capture-queued' -TargetRequestId $queuedId
    $queued = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-queued.json')
    Assert-True ([string]$queued.Status -eq 'QueuedNotRunning') 'QueuedNotRunning was not distinguished.'

    $preparingId = 'preparing-request'
    $preparingResult = Join-Path (Join-Path $brokerRoot 'Results') $preparingId
    New-Item -ItemType Directory -Force -Path $preparingResult | Out-Null
    Write-JsonAtomic -Path (Join-Path (Join-Path $brokerRoot 'Processing') ($preparingId + '.json')) -Value ([ordered]@{ RequestId = $preparingId })
    Write-JsonAtomic -Path (Join-Path $preparingResult 'request-state.json') -Value ([ordered]@{ RequestId = $preparingId; Status = 'WaitingForGuestAgent'; WorkerId = 1 })
    Submit-LiveCommand -CaptureId 'capture-desktop-not-ready' -TargetRequestId $preparingId
    $notReady = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-desktop-not-ready.json')
    Assert-True ([string]$notReady.Status -eq 'GuestDesktopNotReady') 'GuestDesktopNotReady was not distinguished.'
    $scenarios.Add('not-found-queued-and-desktop-not-ready-routing')

    Submit-LiveCommand -CaptureId 'capture-stale-bound' -TargetRequestId $requestId
    $staleBoundPath = Join-Path $brokerRoot 'LiveEvidence\Processing\capture-stale-bound.json'
    Assert-True (Test-Path -LiteralPath $staleBoundPath -PathType Leaf) 'The stale-binding test capture was not initially bound.'
    $script:workerStates[0].OperationId = 'operation-replaced'
    Reconcile-LiveEvidenceCommands -BrokerRoot $brokerRoot -Config $config
    $staleBound = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-stale-bound.json')
    Assert-True ([string]$staleBound.Status -eq 'StaleWorkerRequestBinding' -and -not (Test-Path -LiteralPath $staleBoundPath)) 'A replaced worker operation was not failed closed as a stale binding.'
    $script:workerStates[0].OperationId = 'operation-one'
    $scenarios.Add('stale-bound-command-reconciliation')

    $claimedCaptureId = 'capture-claim-recovery'
    $claimedPath = Join-Path $brokerRoot ('LiveEvidence\Processing\' + $claimedCaptureId + '.crash.claimed')
    Write-JsonAtomic -Path $claimedPath -Value ([ordered]@{
        FormatVersion = 1
        CaptureId = $claimedCaptureId
        RequestId = $requestId
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        GuestEvidencePaths = @()
        CaptureTimeoutMilliseconds = 5000
    })
    Reconcile-LiveEvidenceCommands -BrokerRoot $brokerRoot -Config $config
    $recoveredClaimPath = Join-Path $brokerRoot ('LiveEvidence\Requests\' + $claimedCaptureId + '.json')
    Assert-True ((Test-Path -LiteralPath $recoveredClaimPath -PathType Leaf) -and -not (Test-Path -LiteralPath $claimedPath)) 'An interrupted atomic claim was not returned to the broker request queue.'
    Remove-Item -LiteralPath $recoveredClaimPath -Force
    $scenarios.Add('interrupted-claim-recovery')

    Submit-LiveCommand -CaptureId 'capture-terminal-race' -TargetRequestId $requestId
    $boundPath = Join-Path $brokerRoot 'LiveEvidence\Processing\capture-terminal-race.json'
    Assert-True (Test-Path -LiteralPath $boundPath -PathType Leaf) 'A valid active capture was not broker-bound.'
    Write-JsonAtomic -Path (Join-Path $requestResult 'broker-result.json') -Value ([ordered]@{ RequestId = $requestId; Success = $true })
    Write-JsonAtomic -Path (Join-Path $requestResult 'request-state.json') -Value ([ordered]@{ RequestId = $requestId; Status = 'CollectingEvidence'; WorkerId = 1; ApplicationProcessId = 4242 })
    Reconcile-LiveEvidenceCommands -BrokerRoot $brokerRoot -Config $config
    $terminalRace = Read-LiveEvidenceJsonSafe -Path (Join-Path $brokerRoot 'LiveEvidence\Responses\capture-terminal-race.json')
    Assert-True ([string]$terminalRace.Status -eq 'RequestAlreadyTerminal' -and -not (Test-Path -LiteralPath $boundPath)) 'A capture-versus-terminal race was not resolved atomically to a terminal outcome.'
    $scenarios.Add('capture-versus-terminal-race')

    $publicationRoot = Join-Path $testRoot 'publication'
    $privateStageRoot = Join-Path $publicationRoot 'broker-private'
    $publishedRoot = Join-Path $publicationRoot 'request-evidence'
    New-Item -ItemType Directory -Force -Path $privateStageRoot, $publishedRoot | Out-Null
    $incomingA = Join-Path $privateStageRoot '.incoming-capture-a'
    $incomingB = Join-Path $privateStageRoot '.incoming-capture-b'
    $final = Join-Path $publishedRoot 'capture-final'
    New-Item -ItemType Directory -Force -Path $incomingA, $incomingB | Out-Null
    'complete-a' | Set-Content -LiteralPath (Join-Path $incomingA 'capture.json') -Encoding UTF8
    'complete-b' | Set-Content -LiteralPath (Join-Path $incomingB 'capture.json') -Encoding UTF8
    $testClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Set-HostLiveEvidencePublishedAcl -Path $incomingA -ClientSid $testClientSid
    Publish-HostLiveEvidenceDirectoryAtomic -IncomingPath $incomingA -FinalPath $final
    Assert-True ((Get-Content -LiteralPath (Join-Path $final 'capture.json') -Raw).Trim() -eq 'complete-a') 'Atomic publication did not expose the complete staging tree.'
    Assert-Throws -Operation { Publish-HostLiveEvidenceDirectoryAtomic -IncomingPath $incomingB -FinalPath $final } -Message 'A second publication overwrote an existing capture.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $final 'capture.json') -Raw).Trim() -eq 'complete-a') 'A publication collision changed the first complete capture.'
    $publishedAcl = Get-Acl -LiteralPath $final
    Assert-True ([bool]$publishedAcl.AreAccessRulesProtected) 'Published live evidence did not retain a protected DACL.'
    $clientRules = @($publishedAcl.Access | Where-Object {
        [string]$_.AccessControlType -eq 'Allow' -and
        [string]$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $testClientSid
    })
    Assert-True ($clientRules.Count -eq 1) 'Published live evidence does not have exactly one explicit client allow rule.'
    $mutatingRights = [Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    Assert-True (([int64]$clientRules[0].FileSystemRights -band [int64]$mutatingRights) -eq 0) 'Published live evidence grants the client mutating rights.'
    $scenarios.Add('private-stage-atomic-publication-read-acl-and-no-overwrite')

    $mutexOutput = Join-Path $testRoot 'mutex-output.txt'
    $moduleLiteral = $liveModulePath.Replace("'", "''")
    $outputLiteral = $mutexOutput.Replace("'", "''")
    $processes = New-Object Collections.Generic.List[object]
    $powerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    for ($worker = 1; $worker -le 4; $worker++) {
        $command = @"
. '$moduleLiteral'
for (`$iteration = 1; `$iteration -le 20; `$iteration++) {
    Invoke-WithLiveEvidenceMutex -CaptureId 'concurrent-capture' -Operation {
        Add-Content -LiteralPath '$outputLiteral' -Value '$worker'
    } | Out-Null
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $processes.Add((Start-Process -FilePath $powerShellExecutable -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru))
    }
    foreach ($process in $processes) {
        if (-not $process.WaitForExit(30000) -or $process.ExitCode -ne 0) { throw "Concurrent live-evidence mutex worker failed: PID $($process.Id)." }
        $process.Dispose()
    }
    Assert-True (@(Get-Content -LiteralPath $mutexOutput).Count -eq 80) 'Concurrent capture serialization lost protected operations.'
    $scenarios.Add('concurrent-capture-mutex-serialization')

    $clientText = Get-Content -LiteralPath $clientPath -Raw
    $hostText = $hostBrokerText
    $installerText = Get-Content -LiteralPath $installerPath -Raw
    Assert-True ($clientText -notmatch '\b(Get-VM|Start-VM|Stop-VM|Checkpoint-VM|New-PSSession)\b') 'The client live-observation command directly controls Hyper-V or opens a guest session.'
    Assert-True ($hostText.Contains('Invoke-HostLiveEvidenceService') -and $hostText.Contains('RequestRemainedActiveAfterCapture')) 'Host lifecycle integration or post-capture liveness evidence is missing.'
    Assert-True ($installerText.Contains("'LiveEvidence.ps1'") -and $installerText.Contains('$liveEvidenceProcessingRoot -ClientMode None') -and $installerText.Contains('$liveEvidenceResponseRoot -ClientMode Read')) 'Broker deployment or ACL isolation does not include live evidence.'
    $scenarios.Add('broker-only-control-and-acl-contract')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
