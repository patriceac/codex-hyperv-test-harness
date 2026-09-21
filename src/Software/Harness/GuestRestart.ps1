$contractPath = Join-Path $PSScriptRoot 'GuestPowerTestContract.ps1'
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) { $contractPath = Join-Path $PSScriptRoot '..\Skill\scripts\GuestPowerTestContract.ps1' }
. $contractPath

function Invoke-GuestPowerWatchdog {
    param([ValidateSet('Fixture','Frame')] [string] $Mode, [string] $VmName, [string] $RequestId, [DateTime] $ExecutionDeadlineUtc, $Policy, [string] $BaselineId, [string] $CapturePath, [int] $TimeoutSeconds = 30)
    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $base = Join-Path $probePath ($RequestId + '-power-' + [Guid]::NewGuid().ToString('N'))
    $inputPath = $base + '.input.json'; $outputPath = $base + '.json'; $leasePath = $base + '.process.json'
    $process = $null
    try {
        Write-JsonAtomic -Path $inputPath -Value @{ Mode = $Mode; VmName = $VmName; RequestId = $RequestId; Policy = $Policy; BaselineId = $BaselineId; CapturePath = $CapturePath; CredentialPath = $credentialPath; PromptModule = (Join-Path $PSScriptRoot 'SystemPrompts.ps1') }
        $command = @'
$ErrorActionPreference = 'Stop'
try {
    $data = Get-Content -Raw -LiteralPath __INPUT__ -Encoding UTF8 | ConvertFrom-Json
    if ($data.Mode -eq 'Fixture') {
        $saved = Get-Content -Raw -LiteralPath $data.CredentialPath -Encoding UTF8 | ConvertFrom-Json
        $credential = New-Object Management.Automation.PSCredential($saved.UserName, (ConvertTo-SecureString $saved.Password -AsPlainText -Force))
        $value = Invoke-Command -VMName $data.VmName -Credential $credential -ErrorAction Stop -ScriptBlock {
            param($Id, $Clean, $Fixture, $Credential, $Plan, $BaselineId)
            . 'C:\CodexGuest\GuestPowerTest.ps1'
            Initialize-GuestPowerTest -RequestId $Id -CleanSignIn $Clean -CredentialFixture $Fixture -Credential $Credential -Plan $Plan -PoolBaselineId $BaselineId
        } -ArgumentList $data.RequestId, ([bool]$data.Policy.Plan), $data.Policy.CredentialFixture, $credential, $data.Policy.Plan, $data.BaselineId
    } else {
        . $data.PromptModule
        $value = Save-SystemPromptVmFramebuffer -VmName $data.VmName -Path $data.CapturePath
    }
    $result = @{ Success = $true; Value = $value }
} catch { $result = @{ Success = $false; Error = $_.Exception.Message } }
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath __OUTPUT__ -Encoding UTF8
'@
        $command = $command.Replace('__INPUT__', (ConvertTo-PowerShellSingleQuotedLiteral $inputPath)).Replace('__OUTPUT__', (ConvertTo-PowerShellSingleQuotedLiteral $outputPath))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
        Write-JsonAtomic -Path $leasePath -Value @{ ProcessId = $process.Id; ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o'); CreatedUtc = [DateTime]::UtcNow.ToString('o') }
        $limit = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $limit) { throw "Bounded guest power $Mode operation timed out." }
            Start-Sleep -Milliseconds 200
            $process.Refresh()
        }
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "Guest power $Mode operation returned no evidence." }
        $result = Read-BrokerJsonWithRetry -Path $outputPath
        if (-not $result.Success) { throw "Guest power $Mode operation failed: $($result.Error)" }
        $result.Value
    }
    finally {
        if ($process) { Stop-GuestProbeProcess -Process $process -LeasePath $leasePath }
        foreach ($path in @($inputPath, $outputPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Get-GuestRestartObservation {
    param([string] $VmName, [string] $RequestId, [string] $PhaseId, [string] $Outbox, [DateTime] $ExecutionDeadlineUtc)
    $output = Join-Path $probePath ($RequestId + '-restart-' + [Guid]::NewGuid().ToString('N') + '.json')
    $probe = $null
    try {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $probe = Start-GuestSessionProbe -VmName $VmName -OutputPath $output -InboxFile ('C:\CodexGuest\Inbox\' + $PhaseId + '.json') -ProcessingFile ('C:\CodexGuest\Processing\' + $PhaseId + '.json') -CompletedFile ('C:\CodexGuest\Completed\' + $PhaseId + '.json') -Outbox $Outbox -PowerTestContextPath ('C:\ProgramData\CodexHarness\PowerTests\' + $RequestId + '\context.json')
        $timeout = [DateTime]::UtcNow.AddSeconds(15)
        while (-not $probe.Process.HasExited) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ([DateTime]::UtcNow -ge $timeout) { return $null }
            Start-Sleep -Milliseconds 200
            $probe.Process.Refresh()
        }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { return $null }
        $result = Read-BrokerJsonWithRetry -Path $output
        if ($result.Success -and $result.PowerTest -and $result.CurrentGuestBootTimeUtc) { return $result }
        return $null
    }
    finally {
        if ($probe) { Stop-GuestProbeProcess -Process $probe.Process -LeasePath $probe.LeasePath }
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($output + '.tmp') -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GuestManualSignIn {
    param([string] $VmName, [Management.Automation.PSCredential] $Credential, [string] $RequestId, [DateTime] $ExecutionDeadlineUtc)
    # Only called after a fresh, positive signed-out console observation. Capture
    # the screen before this call, never while a password is being entered.
    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $vm = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter ("ElementName='" + $VmName.Replace("'", "''") + "'") -OperationTimeoutSec 5 -ErrorAction Stop
    $keyboard = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard -OperationTimeoutSec 5 -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } -OperationTimeoutSec 5 -ErrorAction Stop
    if ([uint32]$result.ReturnValue -ne 0) { throw 'Manual guest sign-in navigation failed.' }
    Start-Sleep -Milliseconds 750
    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    try { $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeText -Arguments @{ asciiText = $Credential.GetNetworkCredential().Password } -OperationTimeoutSec 5 -ErrorAction Stop }
    catch { throw 'Manual guest credential input failed.' }
    if ([uint32]$result.ReturnValue -ne 0) { throw 'Manual guest credential input failed.' }
    Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
    $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } -OperationTimeoutSec 5 -ErrorAction Stop
    if ([uint32]$result.ReturnValue -ne 0) { throw 'Manual guest sign-in submission failed.' }
}

function New-GuestRestartPhaseJob {
    param($OriginalJob, $Plan, [int] $Phase, [string] $RequestId, [string] $PayloadRoot, [string] $Outbox, [string] $CredentialFile, [DateTime] $Deadline)
    $job = Copy-GuestJobForExecution -Job $OriginalJob
    $job.id = if ($Phase -eq 0) { $RequestId } else { $RequestId + '-boot' + $Phase }
    $job | Add-Member -NotePropertyName restartRequestId -NotePropertyValue $RequestId -Force
    $job | Add-Member -NotePropertyName restartPhase -NotePropertyValue $Phase -Force
    $job | Add-Member -NotePropertyName awaitGuestRestart -NotePropertyValue ($Phase -lt $Plan.Boots.Count) -Force
    if ($Phase -gt 0) {
        $step = $Plan.Boots[$Phase - 1].Continuation
        $job.executable = [IO.Path]::Combine($PayloadRoot, $step.ExecutableRelativePath)
        $job.arguments = $step.Arguments
        $job.actions = @($step.Actions)
        $allowed = @('PAYLOAD', 'OUTDIR')
        if ($CredentialFile) { $allowed += 'GUEST_CREDENTIAL_FILE' }
        $job.arguments = Expand-GuestJobTokens -Value $job.arguments -GuestPayloadRoot $PayloadRoot -GuestOutputRoot $Outbox -GuestCredentialFile $CredentialFile -AllowedTokens $allowed -Context 'Continuation Arguments'
        foreach ($action in $job.actions) {
            if ($action.type -eq 'send_keys') { $null = Get-ValidatedKeyChord -Action $action -Context 'Continuation action' }
            foreach ($property in @($action.PSObject.Properties)) {
                if ($property.Value -is [string]) { $property.Value = Expand-GuestJobTokens -Value $property.Value -GuestPayloadRoot $PayloadRoot -GuestOutputRoot $Outbox -GuestCredentialFile $CredentialFile -AllowedTokens $allowed -Context 'Continuation action' }
            }
        }
    }
    if ($Phase -lt $Plan.Boots.Count) {
        $marker = $Plan.Boots[$Phase].BeforeRestart
        $job | Add-Member -NotePropertyName assertResultFile -NotePropertyValue $marker.ResultFile.Replace('{OUTDIR}', $Outbox) -Force
        $job | Add-Member -NotePropertyName assertResultJsonPointer -NotePropertyValue $marker.JsonPointer -Force
        $job | Add-Member -NotePropertyName assertResultEqualsJson -NotePropertyValue $marker.EqualsJson -Force
    }
    if ($job.actions.Count -eq 0) {
        $job.actions = @([pscustomobject]@{ type = 'wait_result_file'; path = $job.assertResultFile; timeoutMs = [long][Math]::Max(100, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds) })
    }
    $job
}

function Invoke-GuestRestartPlan {
    param($Job, $Policy, [string] $VmName, [string] $RequestId, [string] $PayloadRoot, [string] $Outbox, [string] $ResultRoot, [string] $CredentialFile, [DateTime] $ExecutionDeadlineUtc, [Management.Automation.PSCredential] $Credential, [scriptblock] $NetworkCheck)
    $history = [ordered]@{ FormatVersion = 1; RequestId = $RequestId; ContractProven = $false; OriginalApplicationLaunchCount = 0; Boots = @(); Phases = @(); ManualSignInCount = 0; ApplicationActionReplayed = $false }
    $journal = Join-Path $ResultRoot 'broker-guest-restart.json'
    $observation = Get-GuestRestartObservation $VmName $RequestId $RequestId $Outbox $ExecutionDeadlineUtc
    if (-not $observation -or -not $observation.PowerTest.SignedIn) { throw 'Restart test initial boot/session observation failed.' }
    $bootTime = [DateTimeOffset]::Parse($observation.CurrentGuestBootTimeUtc).UtcDateTime
    for ($phase = 0; $phase -le $Policy.Plan.Boots.Count; $phase++) {
        Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
        $phaseJob = New-GuestRestartPhaseJob $Job $Policy.Plan $phase $RequestId $PayloadRoot $Outbox $CredentialFile $ExecutionDeadlineUtc
        $phaseId = $phaseJob.id
        $phaseStarted = [DateTimeOffset]::Parse($observation.CurrentGuestUtc).UtcDateTime
        $phaseRecord = [ordered]@{ Phase = $phase; JobId = $phaseId; SubmissionStartedUtc = [DateTime]::UtcNow.ToString('o'); SubmissionAttempts = 1; GuestBootTimeUtc = $bootTime.ToString('o'); Completed = $false }
        $history.Phases += $phaseRecord
        if ($phase -eq 0) { $history.OriginalApplicationLaunchCount = 1 }
        # Durable ambiguity marker precedes delivery. Neither broker nor guest
        # recovery may replay any phase, even if delivery acknowledgement is lost.
        Write-JsonAtomic -Path $journal -Value $history
        $path = Join-Path $ResultRoot ($phaseId + '.json')
        Write-JsonAtomic -Path $path -Value $phaseJob
        $null = Invoke-ExpectedPowerOffJobSubmissionBounded -VmName $VmName -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc -JobPath $path -GuestTransferRoot 'C:\CodexGuest\Transfer' -GuestTransferFile ('C:\CodexGuest\Transfer\' + $phaseId + '.json') -GuestInboxFile ('C:\CodexGuest\Inbox\' + $phaseId + '.json') -GuestProcessingFile ('C:\CodexGuest\Processing\' + $phaseId + '.json') -GuestCompletedFile ('C:\CodexGuest\Completed\' + $phaseId + '.json') -GuestOutbox $Outbox
        $transitionDeadline = $null; $newBoot = $null; $signedOutSince = $null; $manualSent = $false; $launched = $false
        while ($true) {
            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
            if ($NetworkCheck) { & $NetworkCheck }
            $observation = Get-GuestRestartObservation $VmName $RequestId $phaseId $Outbox $ExecutionDeadlineUtc
            if ($phase -lt $Policy.Plan.Boots.Count) { $rule = $Policy.Plan.Boots[$phase] }
            if (-not $observation) {
                if (-not $transitionDeadline -and $phase -lt $Policy.Plan.Boots.Count) { $transitionDeadline = [DateTime]::UtcNow.AddSeconds($rule.BootTimeoutSeconds) }
                $signedOutSince = $null
            }
            else {
                $observedBoot = [DateTimeOffset]::Parse($observation.CurrentGuestBootTimeUtc).UtcDateTime
                $lease = $observation.ApplicationLease
                if ($lease.JobId -ceq $phaseId -and [int]$lease.ProcessId -gt 0 -and [DateTimeOffset]::Parse($lease.GuestBootTimeUtc).UtcDateTime -eq $bootTime) { $launched = $true }
                if ($observedBoot -eq $bootTime) {
                    if ($newBoot) { throw 'Guest boot identity moved backwards.' }
                    $transitionDeadline = $null
                    if ($observation.Presence.AgentError -or ($phase -lt $Policy.Plan.Boots.Count -and ($observation.Presence.Result -or $observation.Presence.Completed))) { throw 'Restart phase terminated before its required boot.' }
                    if ($phase -eq $Policy.Plan.Boots.Count -and $observation.Presence.Result -and $launched) { break }
                    if ($phase -eq $Policy.Plan.Boots.Count -and $observation.Presence.Completed -and -not $observation.Presence.Result) { throw 'Final restart phase completed without evidence.' }
                }
                else {
                    if ($phase -eq $Policy.Plan.Boots.Count -or $observedBoot -lt $bootTime) { throw 'Unexpected guest restart.' }
                    $marker = @($observation.PowerTest.Markers)[$phase]
                    if (-not $launched -or -not $marker.Passed -or -not $marker.WrittenUtc) { throw 'Guest restart lacks a bound application lease and successful pre-restart marker.' }
                    $written = [DateTimeOffset]::Parse($marker.WrittenUtc).UtcDateTime
                    if ($written -ge $observedBoot -or $written -lt $phaseStarted) { throw 'Restart marker does not belong to the preceding application phase.' }
                    if (-not $newBoot) {
                        $newBoot = $observedBoot
                        $transitionDeadline = [DateTime]::UtcNow.AddSeconds($rule.BootTimeoutSeconds + $rule.SignedOutObservationSeconds)
                        $record = [ordered]@{ Index = $phase + 1; PreviousGuestBootTimeUtc = $bootTime.ToString('o'); GuestBootTimeUtc = $newBoot.ToString('o'); ExpectedSignIn = $rule.ExpectedSignIn; BeforeRestartMarkerWrittenUtc = $marker.WrittenUtc; SignedOutObservedSeconds = 0; ManualCredentialInput = $false; ConsoleUser = $null }
                        $history.Boots += $record
                        Write-JsonAtomic -Path $journal -Value $history
                    }
                    elseif ($observedBoot -ne $newBoot) { throw 'Guest restarted again before its continuation was delivered.' }
                    if ($rule.ExpectedSignIn -ceq 'Manual' -and -not $manualSent) {
                        if ($observation.PowerTest.SignedIn) { throw 'Manual-sign-in boot unexpectedly signed in automatically.' }
                        if (-not $signedOutSince) { $signedOutSince = [DateTime]::UtcNow }
                        $record.SignedOutObservedSeconds = ([DateTime]::UtcNow - $signedOutSince).TotalSeconds
                        if ($record.SignedOutObservedSeconds -ge $rule.SignedOutObservationSeconds) {
                            $null = Invoke-GuestPowerWatchdog -Mode Frame -VmName $VmName -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc -CapturePath (Join-Path $ResultRoot ('restart-' + ($phase + 1) + '-signed-out.png')) -TimeoutSeconds 15
                            Assert-RequestActive -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
                            $fresh = Get-GuestRestartObservation $VmName $RequestId $phaseId $Outbox $ExecutionDeadlineUtc
                            if (-not $fresh -or $fresh.PowerTest.SignedIn -or [DateTimeOffset]::Parse($fresh.CurrentGuestBootTimeUtc).UtcDateTime -ne $newBoot) { throw 'Signed-out console identity changed before manual credential input.' }
                            $manualSent = $true; $record.ManualCredentialInput = $true; $history.ManualSignInCount++
                            Write-JsonAtomic -Path $journal -Value $history
                            Invoke-GuestManualSignIn -VmName $VmName -Credential $Credential -RequestId $RequestId -ExecutionDeadlineUtc $ExecutionDeadlineUtc
                        }
                    }
                    elseif ($observation.PowerTest.SignedIn) {
                        if ($observation.PowerTest.ConsoleUser -ine ($Credential.UserName -replace '^.*\\', '')) { throw 'Unexpected guest console account after restart.' }
                        if (Test-GuestSessionBootIdentity -GuestState $observation.State -CurrentGuestBootTimeUtc $observation.CurrentGuestBootTimeUtc -Required $true) {
                            $record.ConsoleUser = $observation.PowerTest.ConsoleUser
                            $bootTime = $newBoot
                            break
                        }
                    }
                }
            }
            if ($transitionDeadline -and [DateTime]::UtcNow -ge $transitionDeadline) { throw [TimeoutException]::new('Guest restart/sign-in observation deadline expired.') }
            Start-Sleep -Milliseconds 500
        }
        $phaseRecord.Completed = $true
        Write-JsonAtomic -Path $journal -Value $history
    }
    $history.ContractProven = $true
    Write-JsonAtomic -Path $journal -Value $history
    [pscustomobject]$history
}
