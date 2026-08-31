[CmdletBinding()]
param(
    [string] $SkillRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $SkillRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill'
}
$runnerPath = Join-Path $SkillRoot 'scripts\Invoke-HostExecutableTest.ps1'
$nativePath = Join-Path $SkillRoot 'scripts\HostControlNative.cs'
$skillPath = Join-Path $SkillRoot 'SKILL.md'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scenarios = New-Object Collections.Generic.List[string]

function Assert-True {
    param([bool] $Condition, [Parameter(Mandatory = $true)] [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-WindowsPowerShellEncoded {
    param([Parameter(Mandatory = $true)] [string] $Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $priorErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorErrorPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output); Text = (@($output) -join [Environment]::NewLine) }
}

Assert-True (Test-Path -LiteralPath $runnerPath -PathType Leaf) 'The host-control runner is missing.'
Assert-True (Test-Path -LiteralPath $nativePath -PathType Leaf) 'The host-control native source is missing.'
Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) 'The runtime skill documentation is missing.'
Assert-True (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is required for the installed host-control runtime contract.'
$scenarios.Add('host-control-files-present')

$runnerText = Get-Content -LiteralPath $runnerPath -Raw
$nativeText = Get-Content -LiteralPath $nativePath -Raw
$skillText = Get-Content -LiteralPath $skillPath -Raw

Assert-True ($runnerText.Contains('$initialWarningSeconds = 5') -and $runnerText.Contains('$resumeIdleSeconds = 10')) 'The host runner does not pin the requested five-second warning and ten-second idle resume.'
Assert-True ($runnerText.Contains('Wait-InitialHostControlWarning') -and $runnerText.Contains('Wait-ForHostControlReady') -and $runnerText.Contains('Restore-ControlledWindowFocus')) 'The host runner is missing warning, pause/resume, or refocus integration.'
$initialWarningFunction = [regex]::Match($runnerText, '(?ms)^function Wait-InitialHostControlWarning \{.*?^\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($initialWarningFunction)) 'The initial host-control grace-period function could not be inspected.'
Assert-True (-not $initialWarningFunction.Contains('Wait-ForHostControlReady')) 'Ordinary physical input can still enter the amber paused state during the initial five-second grace period.'
Assert-True ($initialWarningFunction.Contains('$script:observedPhysicalInputVersion = [long]$snapshot.PhysicalInputVersion') -and $initialWarningFunction.Contains('$script:pauseDetectionArmed = $true')) 'The grace period does not discard pre-control activity and arm pause detection only after it expires.'
Assert-True ($runnerText.Contains("HostExecutionAuthorized is required")) 'The host runner does not fail closed without an explicit host authorization signal.'
Assert-True (-not ($runnerText -match '\[.*\]\s*\$WarningSeconds') -and -not ($runnerText -match '\[.*\]\s*\$ResumeIdleSeconds')) 'The user-selected host-control timing was accidentally exposed as a caller override.'
$scenarios.Add('fixed-warning-idle-and-authorization-contract')

Assert-True ($nativeText.Contains('WH_KEYBOARD_LL') -and $nativeText.Contains('WH_MOUSE_LL')) 'The native guard does not monitor low-level physical keyboard and mouse activity.'
Assert-True ($nativeText.Contains('LLKHF_INJECTED') -and $nativeText.Contains('LLMHF_INJECTED') -and $nativeText.Contains('SyntheticInputMarker')) 'The native guard cannot distinguish controller-generated input from physical input.'
Assert-True ($nativeText.Contains('CancelVirtualKey = 0x1B') -and $nativeText.Contains('return new IntPtr(1)')) 'Escape cancellation is not globally captured and swallowed while host control is active.'
Assert-True ($nativeText.Contains('Screen.AllScreens') -and $nativeText.Contains('WS_EX_TRANSPARENT') -and $nativeText.Contains('WS_EX_NOACTIVATE') -and $nativeText.Contains('WM_NCHITTEST') -and $nativeText.Contains('HTTRANSPARENT')) 'The halo is not multi-monitor, click-through, and non-activating.'
Assert-True ($nativeText.Contains('HaloBandForm') -and $nativeText.Contains('AddFrameBand(screen.Bounds, bandIndex)') -and $nativeText.Contains('ApplyBandRegion')) 'The halo is not rendered as one continuous, non-overlapping frame stack per monitor.'
Assert-True (-not $nativeText.Contains('HaloEdgeForm') -and -not $nativeText.Contains('AddEdge(')) 'The overlapping edge-window halo implementation is still present.'
Assert-True ($nativeText.Contains('WDA_EXCLUDEFROMCAPTURE') -and $nativeText.Contains('WDA_MONITOR') -and $runnerText.Contains('HaloSuppressedCopyFromScreen') -and $runnerText.Contains('CaptureProtectionSucceeded')) 'The halo is not protected from runner screenshot evidence with a compatible fallback.'
Assert-True ($nativeText.Contains('MOUSEEVENTF_VIRTUALDESK') -and $nativeText.Contains('MOUSEEVENTF_ABSOLUTE')) 'Synthetic mouse input does not support the complete multi-monitor virtual desktop.'
$scenarios.Add('native-input-halo-and-capture-safety-contract')

$escapedNative = $nativePath.Replace("'", "''")
$nativeProbe = @"
`$ErrorActionPreference = 'Stop'
Add-Type -Path '$escapedNative' -ReferencedAssemblies @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll')
`$probeNow = [DateTime]::UtcNow
[pscustomobject][ordered]@{
    Warning = [Codex.HostControl.HostControlContract]::InitialWarningSeconds
    Resume = [Codex.HostControl.HostControlContract]::ResumeIdleSeconds
    CancelKey = [Codex.HostControl.HostControlContract]::CancelVirtualKey
    Fuchsia = [Codex.HostControl.HostControlContract]::ActiveHaloHex
    PhysicalKeyboard = [Codex.HostControl.HostControlContract]::IsPhysicalKeyboardInput(0, 0)
    InjectedKeyboard = [Codex.HostControl.HostControlContract]::IsPhysicalKeyboardInput(0x10, 0)
    MarkedKeyboard = [Codex.HostControl.HostControlContract]::IsPhysicalKeyboardInput(0, [Codex.HostControl.HostControlContract]::SyntheticInputMarker)
    PhysicalMouse = [Codex.HostControl.HostControlContract]::IsPhysicalMouseInput(0, 0)
    InjectedMouse = [Codex.HostControl.HostControlContract]::IsPhysicalMouseInput(1, 0)
    MarkedMouse = [Codex.HostControl.HostControlContract]::IsPhysicalMouseInput(0, [Codex.HostControl.HostControlContract]::SyntheticInputMarker)
    NewActivity = [Codex.HostControl.HostControlContract]::HasUnobservedPhysicalInput(3, 2)
    SameActivity = [Codex.HostControl.HostControlContract]::HasUnobservedPhysicalInput(3, 3)
    UnarmedNewActivity = [Codex.HostControl.HostControlContract]::ShouldPauseForPhysicalInput(`$false, 3, 2)
    ArmedNewActivity = [Codex.HostControl.HostControlContract]::ShouldPauseForPhysicalInput(`$true, 3, 2)
    ArmedSameActivity = [Codex.HostControl.HostControlContract]::ShouldPauseForPhysicalInput(`$true, 3, 3)
    FrameThickness = [Codex.HostControl.HostControlContract]::HaloFrameThicknessPixels
    CoreThickness = [Codex.HostControl.HostControlContract]::HaloCoreThicknessPixels
    BandThickness = [Codex.HostControl.HostControlContract]::HaloBandThicknessPixels
    HaloOpacity = @(0..5 | ForEach-Object { [Codex.HostControl.HostControlContract]::GetHaloBandOpacity(`$_, 1.0) })
    ResumeAtNineSeconds = [Codex.HostControl.HostControlContract]::GetResumeDelayMilliseconds(`$probeNow, `$probeNow.AddSeconds(-9))
    ResumeAtTenSeconds = [Codex.HostControl.HostControlContract]::GetResumeDelayMilliseconds(`$probeNow, `$probeNow.AddSeconds(-10))
} | ConvertTo-Json -Compress
"@
$nativeResult = Invoke-WindowsPowerShellEncoded -Script $nativeProbe
Assert-True ($nativeResult.ExitCode -eq 0) "The native host-control source did not compile under Windows PowerShell 5.1: $($nativeResult.Text)"
$nativeContract = ($nativeResult.Output | Select-Object -Last 1) | ConvertFrom-Json
Assert-True ($nativeContract.Warning -eq 5 -and $nativeContract.Resume -eq 10 -and $nativeContract.CancelKey -eq 27 -and $nativeContract.Fuchsia -eq '#F000FF') 'The compiled native timing, Escape, or fuchsia contract is incorrect.'
Assert-True ($nativeContract.PhysicalKeyboard -and $nativeContract.PhysicalMouse) 'Physical input was not classified as user activity.'
Assert-True (-not $nativeContract.InjectedKeyboard -and -not $nativeContract.MarkedKeyboard -and -not $nativeContract.InjectedMouse -and -not $nativeContract.MarkedMouse) 'Controller-generated input would incorrectly pause its own host-control run.'
Assert-True ($nativeContract.NewActivity -and -not $nativeContract.SameActivity) 'The compiled pause decision does not distinguish new physical input.'
Assert-True (-not $nativeContract.UnarmedNewActivity -and $nativeContract.ArmedNewActivity -and -not $nativeContract.ArmedSameActivity) 'Physical input can pause before the grace period expires or fails to pause after it is armed.'
Assert-True ($nativeContract.FrameThickness -eq 12 -and $nativeContract.CoreThickness -eq 2 -and $nativeContract.BandThickness -eq 2) 'The continuous halo frame does not keep the intended thin core and restrained inward glow.'
$haloOpacity = @($nativeContract.HaloOpacity | ForEach-Object { [double]$_ })
Assert-True ($haloOpacity.Count -eq 6 -and $haloOpacity[0] -ge 0.95) 'The halo does not keep a crisp two-pixel fuchsia core.'
for ($index = 1; $index -lt $haloOpacity.Count; $index++) {
    Assert-True ($haloOpacity[$index] -lt $haloOpacity[$index - 1]) 'The halo glow opacity does not fade smoothly inward.'
}
Assert-True ($haloOpacity[-1] -le 0.051) 'The inner halo edge does not fade to a restrained glow.'
Assert-True ($nativeContract.ResumeAtNineSeconds -ge 900 -and $nativeContract.ResumeAtNineSeconds -le 1100 -and $nativeContract.ResumeAtTenSeconds -eq 0) 'The compiled resume decision does not require ten uninterrupted idle seconds.'
$scenarios.Add('native-source-compiles-and-input-classification-passes')

$escapedRunner = $runnerPath.Replace("'", "''")
$escapedArtifact = $windowsPowerShell.Replace("'", "''")
$validationProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedArtifact' -HostExecutionAuthorized -ValidateOnly -ActionsJson '[{"type":"wait_window","timeoutMs":1000}]'
"@
$validationResult = Invoke-WindowsPowerShellEncoded -Script $validationProbe
Assert-True ($validationResult.ExitCode -eq 0) "The host runner validation-only path failed: $($validationResult.Text)"
$validation = $validationResult.Text | ConvertFrom-Json
Assert-True ($validation.Success -and $validation.Status -eq 'Validated' -and $validation.ActionCount -eq 1) 'The host runner did not validate a supported action contract.'
Assert-True ($validation.HostControl.InitialWarningSeconds -eq 5 -and $validation.HostControl.ResumeIdleSeconds -eq 10 -and $validation.HostControl.CancelKey -eq 'Escape') 'The validation result did not advertise the exact requested interaction policy.'
Assert-True ($validation.HostControl.InitialGraceInputBehavior -eq 'IgnoreForPause' -and $validation.HostControl.PostGraceInputBehavior -eq 'PauseImmediately') 'The validation result does not distinguish the non-pausing grace period from post-grace user takeover.'
Assert-True ($validation.HostControl.HaloRendering -eq 'ContinuousNonOverlappingBands' -and $validation.HostControl.HaloFrameThicknessPixels -eq 12) 'The validation result does not advertise the clean continuous halo geometry.'
$scenarios.Add('validation-only-contract-succeeds-without-launch')

$escapedArtifactDirectory = (Split-Path -Parent $windowsPowerShell).Replace("'", "''")
$directoryValidationProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedArtifactDirectory' -ExecutableRelativePath 'powershell.exe' -HostExecutionAuthorized -ValidateOnly -ActionsJson '[{"type":"wait","ms":0}]'
"@
$directoryValidation = Invoke-WindowsPowerShellEncoded -Script $directoryValidationProbe
Assert-True ($directoryValidation.ExitCode -eq 0) "The host runner rejected a safe directory artifact: $($directoryValidation.Text)"
$ambiguousExecutableProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedArtifactDirectory' -ExecutableRelativePath '.\powershell.exe' -HostExecutionAuthorized -ValidateOnly -ActionsJson '[{"type":"wait","ms":0}]'
"@
$ambiguousExecutable = Invoke-WindowsPowerShellEncoded -Script $ambiguousExecutableProbe
Assert-True ($ambiguousExecutable.ExitCode -ne 0 -and $ambiguousExecutable.Text -like '*unambiguous relative path segments*') 'The host runner accepted an ambiguous executable path traversal.'
Assert-True ($runnerText.Contains('Assert-NoExecutableReparseTraversal') -and $runnerText.Contains('Get-VerifiedTrackedProcess') -and $runnerText.Contains('ProcessCleanupFailure')) 'The host runner is missing executable reparse or process-identity cleanup guards.'
$scenarios.Add('directory-artifact-and-cleanup-safety-contract')

$missingAuthorizationProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedArtifact' -ValidateOnly -ActionsJson '[{"type":"wait","ms":0}]'
"@
$missingAuthorization = Invoke-WindowsPowerShellEncoded -Script $missingAuthorizationProbe
Assert-True ($missingAuthorization.ExitCode -ne 0 -and $missingAuthorization.Text -like '*HostExecutionAuthorized is required*') 'The host runner did not reject an invocation without explicit host authorization.'
$scenarios.Add('missing-host-authorization-rejected')

$unsafeEvidenceProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedArtifact' -HostExecutionAuthorized -ValidateOnly -ActionsJson '[{"type":"wait_result_file","path":"{OUTDIR}\\..\\escape.json","timeoutMs":1000}]'
"@
$unsafeEvidence = Invoke-WindowsPowerShellEncoded -Script $unsafeEvidenceProbe
Assert-True ($unsafeEvidence.ExitCode -ne 0 -and $unsafeEvidence.Text -like '*escapes the request output directory*') 'The host runner accepted an evidence path traversal.'
$scenarios.Add('host-evidence-path-traversal-rejected')

Assert-True ($skillText.Contains('Invoke-HostExecutableTest.ps1') -and $skillText.Contains('five-second') -and $skillText.Contains('does not pause') -and $skillText.Contains('ten seconds') -and $skillText.Contains('Escape')) 'The runtime skill does not document the explicit host-control path and its user-visible behavior.'
$scenarios.Add('runtime-skill-documents-host-control')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
