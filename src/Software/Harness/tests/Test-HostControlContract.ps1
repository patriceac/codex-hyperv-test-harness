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

function Invoke-PowerShellEncoded {
    param(
        [Parameter(Mandatory = $true)] [string] $ExecutablePath,
        [Parameter(Mandatory = $true)] [string] $Script
    )
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $priorErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $ExecutablePath -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorErrorPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output); Text = (@($output) -join [Environment]::NewLine) }
}

function Invoke-WindowsPowerShellEncoded {
    param([Parameter(Mandatory = $true)] [string] $Script)
    Invoke-PowerShellEncoded -ExecutablePath $windowsPowerShell -Script $Script
}

function Resolve-PowerShell7Path {
    $candidates = New-Object 'Collections.Generic.List[string]'
    if ([string]$PSVersionTable.PSEdition -eq 'Core') {
        try { $candidates.Add((Get-Process -Id $PID -ErrorAction Stop).Path) } catch {}
    }
    try {
        $command = Get-Command pwsh.exe -ErrorAction Stop
        if ($command.Source) { $candidates.Add([string]$command.Source) }
    }
    catch {}
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates.Add((Join-Path $programFiles 'PowerShell\7\pwsh.exe'))
    }
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $runtimeRoot = Join-Path $userProfile '.cache\codex-runtimes'
        if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
            foreach ($runtime in @(Get-ChildItem -Path (Join-Path $runtimeRoot '*\dependencies\native\powershell\pwsh.exe') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                $candidates.Add($runtime.FullName)
            }
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $fullPath = try { [IO.Path]::GetFullPath($candidate) } catch { continue }
        if ($seen.ContainsKey($fullPath)) { continue }
        $seen[$fullPath] = $true
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        try {
            $edition = & $fullPath -NoLogo -NoProfile -NonInteractive -Command '[Console]::Out.Write($PSVersionTable.PSEdition)' 2>$null
            if ($LASTEXITCODE -eq 0 -and [string]$edition -eq 'Core') { return $fullPath }
        }
        catch {}
    }
    $null
}

Assert-True (Test-Path -LiteralPath $runnerPath -PathType Leaf) 'The host-control runner is missing.'
Assert-True (Test-Path -LiteralPath $nativePath -PathType Leaf) 'The host-control native source is missing.'
Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) 'The runtime skill documentation is missing.'
Assert-True (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is required for the installed host-control runtime contract.'
$powerShell7 = Resolve-PowerShell7Path
Assert-True (-not [string]::IsNullOrWhiteSpace($powerShell7)) 'PowerShell 7 is required to validate the current host-control native bootstrap.'
$scenarios.Add('host-control-files-present')

$runnerText = Get-Content -LiteralPath $runnerPath -Raw
$nativeText = Get-Content -LiteralPath $nativePath -Raw
$skillText = Get-Content -LiteralPath $skillPath -Raw

Assert-True ($runnerText.Contains('$initialWarningSeconds = 6') -and $runnerText.Contains('$initialInputIgnoreSeconds = 3') -and $runnerText.Contains('$initialInputPauseEligibleSeconds = $initialWarningSeconds - $initialInputIgnoreSeconds') -and $runnerText.Contains('$resumeIdleSeconds = 10')) 'The host runner does not pin the requested six-second split warning and ten-second idle resume.'
Assert-True ($runnerText.Contains('Wait-InitialHostControlWarning') -and $runnerText.Contains('Wait-ForHostControlReady') -and $runnerText.Contains('Restore-ControlledWindowFocus')) 'The host runner is missing warning, pause/resume, or refocus integration.'
$initialWarningFunction = [regex]::Match($runnerText, '(?ms)^function Wait-InitialHostControlWarning \{.*?^\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($initialWarningFunction)) 'The initial host-control grace-period function could not be inspected.'
Assert-True ($initialWarningFunction.Contains('AddSeconds($initialInputIgnoreSeconds)') -and $initialWarningFunction.Contains('$script:observedPhysicalInputVersion = [long]$snapshot.PhysicalInputVersion')) 'The warning does not discard physical activity at the end of its first three input-ignored seconds.'
$pauseArmIndex = $initialWarningFunction.IndexOf('$script:pauseDetectionArmed = $true', [StringComparison]::Ordinal)
$pauseEligibleWaitIndex = $initialWarningFunction.IndexOf('Wait-HostControlDelay -Milliseconds ($initialInputPauseEligibleSeconds * 1000) -ResumeToWarning', [StringComparison]::Ordinal)
Assert-True ($pauseArmIndex -ge 0 -and $pauseEligibleWaitIndex -gt $pauseArmIndex) 'Pause detection is not armed before the final three warning seconds or warning-state resume is missing.'
Assert-True ($runnerText.Contains("HostExecutionAuthorized is required")) 'The host runner does not fail closed without an explicit host authorization signal.'
Assert-True ($runnerText.Contains('PowerShellCoreReferencePack') -and $runnerText.Contains("Join-Path `$PSHOME 'ref'") -and $runnerText.Contains('NativeBootstrap')) 'The host runner does not expose the runtime-aware PowerShell 7 native bootstrap.'
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

Assert-True ($nativeText.Contains('ControlledWindowBandForm') -and $nativeText.Contains('ApplyRoundedBandRegion') -and $nativeText.Contains('TryGetVisibleBounds')) 'The controlled app does not have a rounded inward highlight bound to its visible window bounds.'
Assert-True ($nativeText.Contains('ControlledWindowHighlightHex = "#B86CFF"') -and $nativeText.Contains('ControlledWindowFrameThicknessPixels = 6')) 'The controlled-app violet highlight contract is missing or has drifted.'
Assert-True ($runnerText.Contains('Set-ControlledWindowHighlight') -and $runnerText.Contains('$script:runtime.SetControlledWindow($Window)') -and $runnerText.Contains('$script:highlightProbeDeadlineUtc = [DateTime]::UtcNow.AddSeconds(30)')) 'The verified controlled window is not connected to the native highlight runtime through bounded discovery.'
Assert-True ($nativeText.Contains('DoesWindowProcessOwnForeground') -and $nativeText.Contains('ShouldShowControlledWindowHighlight(_visible, targetWindowUsable, targetProcessOwnsForeground)')) 'The controlled-app highlight can remain visible when another application owns the foreground.'
Assert-True ($runnerText.Contains('ControlledWindowHighlightPauseBehavior') -and $runnerText.Contains("'Dim'") -and $runnerText.Contains('ControlledWindowHighlightBackgroundBehavior') -and $runnerText.Contains("'Hidden'")) 'The controlled-app highlight does not advertise its paused and background behavior.'
$scenarios.Add('controlled-window-highlight-wiring-and-safety-contract')

$dpiRequirementIndex = $nativeText.IndexOf('HostDpiAwareness.RequirePerMonitorV2ForCurrentThread();', [StringComparison]::Ordinal)
$visualStylesIndex = $nativeText.IndexOf('Application.EnableVisualStyles();', [StringComparison]::Ordinal)
Assert-True ($nativeText.Contains('SetThreadDpiAwarenessContext') -and $nativeText.Contains('AreDpiAwarenessContextsEqual') -and $dpiRequirementIndex -ge 0 -and $dpiRequirementIndex -lt $visualStylesIndex) 'The visual-guard UI thread does not require PerMonitorV2 before WinForms creates its first window.'
Assert-True ($runnerText.Contains("VisualCoordinateSpace = 'PerMonitorV2PhysicalPixels'")) 'The host runner does not advertise the DPI-safe physical-pixel coordinate contract.'
$scenarios.Add('per-monitor-v2-dpi-coordinate-contract')

$escapedNative = $nativePath.Replace("'", "''")
$nativeProbe = @"
`$ErrorActionPreference = 'Stop'
Add-Type -Path '$escapedNative' -ReferencedAssemblies @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll')
`$probeNow = [DateTime]::UtcNow
`$zeroBounds = New-Object Drawing.Rectangle
`$dpiError = 0
`$dpiEnabled = [Codex.HostControl.HostDpiAwareness]::TryEnablePerMonitorV2ForCurrentThread([ref]`$dpiError)
[pscustomobject][ordered]@{
    Warning = [Codex.HostControl.HostControlContract]::InitialWarningSeconds
    InputIgnore = [Codex.HostControl.HostControlContract]::InitialInputIgnoreSeconds
    InputPauseEligible = [Codex.HostControl.HostControlContract]::InitialInputPauseEligibleSeconds
    Resume = [Codex.HostControl.HostControlContract]::ResumeIdleSeconds
    CancelKey = [Codex.HostControl.HostControlContract]::CancelVirtualKey
    Fuchsia = [Codex.HostControl.HostControlContract]::ActiveHaloHex
    Violet = [Codex.HostControl.HostControlContract]::ControlledWindowHighlightHex
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
    HighlightWhenForeground = [Codex.HostControl.HostControlContract]::ShouldShowControlledWindowHighlight(`$true, `$true, `$true)
    HighlightWhenBackground = [Codex.HostControl.HostControlContract]::ShouldShowControlledWindowHighlight(`$true, `$true, `$false)
    HighlightWhenGuardsHidden = [Codex.HostControl.HostControlContract]::ShouldShowControlledWindowHighlight(`$false, `$true, `$true)
    FrameThickness = [Codex.HostControl.HostControlContract]::HaloFrameThicknessPixels
    CoreThickness = [Codex.HostControl.HostControlContract]::HaloCoreThicknessPixels
    BandThickness = [Codex.HostControl.HostControlContract]::HaloBandThicknessPixels
    HaloOpacity = @(0..5 | ForEach-Object { [Codex.HostControl.HostControlContract]::GetHaloBandOpacity(`$_, 1.0) })
    ControlledWindowFrameThickness = [Codex.HostControl.HostControlContract]::ControlledWindowFrameThicknessPixels
    ControlledWindowCoreThickness = [Codex.HostControl.HostControlContract]::ControlledWindowCoreThicknessPixels
    ControlledWindowBandThickness = [Codex.HostControl.HostControlContract]::ControlledWindowBandThicknessPixels
    ControlledWindowCornerRadius = [Codex.HostControl.HostControlContract]::ControlledWindowCornerRadiusPixels
    ControlledWindowOpacity = @(0..2 | ForEach-Object { [Codex.HostControl.HostControlContract]::GetControlledWindowBandOpacity(`$_, 1.0) })
    WindowedCornersAreSquare = [Codex.HostControl.HostControlContract]::ShouldUseSquareControlledWindowCorners([Drawing.Rectangle]::FromLTRB(100,100,900,700), [Drawing.Rectangle]::FromLTRB(0,0,1920,1080))
    MaximizedCornersAreSquare = [Codex.HostControl.HostControlContract]::ShouldUseSquareControlledWindowCorners([Drawing.Rectangle]::FromLTRB(0,0,1920,1080), [Drawing.Rectangle]::FromLTRB(0,0,1920,1080))
    ZeroWindowHasVisibleBounds = [Codex.HostControl.HostWindowControl]::TryGetVisibleBounds([IntPtr]::Zero, [ref]`$zeroBounds)
    DpiEnabled = `$dpiEnabled
    DpiError = `$dpiError
    PerMonitorV2 = [Codex.HostControl.HostDpiAwareness]::IsCurrentThreadPerMonitorV2()
    ResumeAtNineSeconds = [Codex.HostControl.HostControlContract]::GetResumeDelayMilliseconds(`$probeNow, `$probeNow.AddSeconds(-9))
    ResumeAtTenSeconds = [Codex.HostControl.HostControlContract]::GetResumeDelayMilliseconds(`$probeNow, `$probeNow.AddSeconds(-10))
} | ConvertTo-Json -Compress
"@
$nativeResult = Invoke-WindowsPowerShellEncoded -Script $nativeProbe
Assert-True ($nativeResult.ExitCode -eq 0) "The native host-control source did not compile under Windows PowerShell 5.1: $($nativeResult.Text)"
$nativeContract = ($nativeResult.Output | Select-Object -Last 1) | ConvertFrom-Json
Assert-True ($nativeContract.Warning -eq 6 -and $nativeContract.InputIgnore -eq 3 -and $nativeContract.InputPauseEligible -eq 3 -and $nativeContract.Resume -eq 10 -and $nativeContract.CancelKey -eq 27 -and $nativeContract.Fuchsia -eq '#F000FF') 'The compiled native timing, Escape, or fuchsia contract is incorrect.'
Assert-True ($nativeContract.Violet -eq '#B86CFF') 'The compiled controlled-app highlight color is incorrect.'
Assert-True ($nativeContract.PhysicalKeyboard -and $nativeContract.PhysicalMouse) 'Physical input was not classified as user activity.'
Assert-True (-not $nativeContract.InjectedKeyboard -and -not $nativeContract.MarkedKeyboard -and -not $nativeContract.InjectedMouse -and -not $nativeContract.MarkedMouse) 'Controller-generated input would incorrectly pause its own host-control run.'
Assert-True ($nativeContract.NewActivity -and -not $nativeContract.SameActivity) 'The compiled pause decision does not distinguish new physical input.'
Assert-True (-not $nativeContract.UnarmedNewActivity -and $nativeContract.ArmedNewActivity -and -not $nativeContract.ArmedSameActivity) 'Physical input can pause before the first three seconds expire or fails to pause after detection is armed.'
Assert-True ($nativeContract.HighlightWhenForeground -and -not $nativeContract.HighlightWhenBackground -and -not $nativeContract.HighlightWhenGuardsHidden) 'The compiled controlled-window visibility policy is not foreground-only.'
Assert-True ($nativeContract.FrameThickness -eq 12 -and $nativeContract.CoreThickness -eq 2 -and $nativeContract.BandThickness -eq 2) 'The continuous halo frame does not keep the intended thin core and restrained inward glow.'
$haloOpacity = @($nativeContract.HaloOpacity | ForEach-Object { [double]$_ })
Assert-True ($haloOpacity.Count -eq 6 -and $haloOpacity[0] -ge 0.95) 'The halo does not keep a crisp two-pixel fuchsia core.'
for ($index = 1; $index -lt $haloOpacity.Count; $index++) {
    Assert-True ($haloOpacity[$index] -lt $haloOpacity[$index - 1]) 'The halo glow opacity does not fade smoothly inward.'
}
Assert-True ($haloOpacity[-1] -le 0.051) 'The inner halo edge does not fade to a restrained glow.'
$controlledWindowOpacity = @($nativeContract.ControlledWindowOpacity | ForEach-Object { [double]$_ })
Assert-True ($nativeContract.ControlledWindowFrameThickness -eq 6 -and $nativeContract.ControlledWindowCoreThickness -eq 2 -and $nativeContract.ControlledWindowBandThickness -eq 2 -and $nativeContract.ControlledWindowCornerRadius -eq 8) 'The controlled-app highlight does not keep the approved inward geometry.'
Assert-True ($controlledWindowOpacity.Count -eq 3 -and $controlledWindowOpacity[0] -ge 0.95) 'The controlled-app highlight does not keep a crisp two-pixel violet core.'
for ($index = 1; $index -lt $controlledWindowOpacity.Count; $index++) {
    Assert-True ($controlledWindowOpacity[$index] -lt $controlledWindowOpacity[$index - 1]) 'The controlled-app highlight does not fade smoothly inward.'
}
Assert-True ($controlledWindowOpacity[-1] -le 0.071 -and -not $nativeContract.ZeroWindowHasVisibleBounds) 'The controlled-app glow is too strong or accepts an invalid window handle.'
Assert-True (-not $nativeContract.WindowedCornersAreSquare -and $nativeContract.MaximizedCornersAreSquare) 'The controlled-app highlight does not preserve rounded windowed corners and square maximized edges.'
Assert-True ($nativeContract.DpiEnabled -and $nativeContract.PerMonitorV2 -and $nativeContract.DpiError -eq 0) 'The native helper could not establish a PerMonitorV2 physical-pixel coordinate space.'
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
Assert-True ($validation.NativeBootstrap.TypeLoaded -and $validation.NativeBootstrap.PSEdition -eq 'Desktop' -and $validation.NativeBootstrap.ReferenceMode -eq 'WindowsPowerShellFrameworkAssemblies') 'ValidationOnly did not compile and load the native helper through the Windows PowerShell 5.1 reference path.'
Assert-True ($validation.HostControl.InitialWarningSeconds -eq 6 -and $validation.HostControl.InitialInputIgnoreSeconds -eq 3 -and $validation.HostControl.InitialInputPauseEligibleSeconds -eq 3 -and $validation.HostControl.ResumeIdleSeconds -eq 10 -and $validation.HostControl.CancelKey -eq 'Escape') 'The validation result did not advertise the exact requested interaction policy.'
Assert-True ($validation.HostControl.InitialGraceInputBehavior -eq 'IgnoreThenPauseImmediately' -and $validation.HostControl.PostGraceInputBehavior -eq 'PauseImmediately') 'The validation result does not distinguish the two initial input phases from post-grace user takeover.'
Assert-True ($validation.HostControl.HaloRendering -eq 'ContinuousNonOverlappingBands' -and $validation.HostControl.HaloFrameThicknessPixels -eq 12) 'The validation result does not advertise the clean continuous halo geometry.'
Assert-True ($validation.HostControl.ControlledWindowHighlightColor -eq '#B86CFF' -and $validation.HostControl.ControlledWindowHighlightRendering -eq 'RoundedInwardNonOverlappingBands' -and $validation.HostControl.ControlledWindowHighlightFrameThicknessPixels -eq 6 -and $validation.HostControl.ControlledWindowHighlightPauseBehavior -eq 'Dim' -and $validation.HostControl.ControlledWindowHighlightBackgroundBehavior -eq 'Hidden') 'The validation result does not advertise the approved controlled-app highlight.'
Assert-True ($validation.HostControl.VisualCoordinateSpace -eq 'PerMonitorV2PhysicalPixels') 'The validation result does not advertise DPI-safe physical-pixel visual coordinates.'
$scenarios.Add('windows-powershell-validation-compiles-native-helper-without-launch')

$escapedPowerShell7 = $powerShell7.Replace("'", "''")
$powerShell7ValidationProbe = @"
`$ErrorActionPreference = 'Stop'
& '$escapedRunner' -ArtifactPath '$escapedPowerShell7' -HostExecutionAuthorized -ValidateOnly -ActionsJson '[{"type":"wait_window","timeoutMs":1000}]'
"@
$powerShell7ValidationResult = Invoke-PowerShellEncoded -ExecutablePath $powerShell7 -Script $powerShell7ValidationProbe
Assert-True ($powerShell7ValidationResult.ExitCode -eq 0) "The host runner native bootstrap failed under PowerShell 7: $($powerShell7ValidationResult.Text)"
$powerShell7Validation = $powerShell7ValidationResult.Text | ConvertFrom-Json
Assert-True ($powerShell7Validation.Success -and $powerShell7Validation.Status -eq 'Validated' -and $powerShell7Validation.ActionCount -eq 1) 'PowerShell 7 did not complete the validation-only host runner path.'
Assert-True ($powerShell7Validation.NativeBootstrap.TypeLoaded -and $powerShell7Validation.NativeBootstrap.PSEdition -eq 'Core' -and $powerShell7Validation.NativeBootstrap.ReferenceMode -eq 'PowerShellCoreReferencePack') 'PowerShell 7 did not compile and load the host-control native helper through its matching reference pack.'
Assert-True ([version]$powerShell7Validation.NativeBootstrap.PowerShellVersion -ge [version]'7.0') 'The PowerShell 7 validation did not report a supported engine version.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$powerShell7Validation.NativeBootstrap.RuntimeDescription)) 'The PowerShell 7 validation did not report its .NET runtime.'
Assert-True ($powerShell7Validation.HostControl.VisualCoordinateSpace -eq 'PerMonitorV2PhysicalPixels') 'PowerShell 7 validation did not preserve the DPI-safe physical-pixel visual coordinate contract.'
Assert-True ($powerShell7Validation.HostControl.InitialWarningSeconds -eq 6 -and $powerShell7Validation.HostControl.InitialInputIgnoreSeconds -eq 3 -and $powerShell7Validation.HostControl.InitialInputPauseEligibleSeconds -eq 3 -and $powerShell7Validation.HostControl.ControlledWindowHighlightBackgroundBehavior -eq 'Hidden') 'PowerShell 7 validation did not preserve the split warning or foreground-only highlight contract.'
$scenarios.Add('powershell7-validation-compiles-native-helper-without-launch')

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

Assert-True ($skillText.Contains('Invoke-HostExecutableTest.ps1') -and $skillText.Contains('six-second') -and $skillText.Contains('first three seconds') -and $skillText.Contains('final three seconds') -and $skillText.Contains('ten seconds') -and $skillText.Contains('Escape') -and $skillText.Contains('violet') -and $skillText.Contains('inward') -and $skillText.Contains('another application owns the foreground')) 'The runtime skill does not document the explicit host-control path and its user-visible behavior.'
$scenarios.Add('runtime-skill-documents-host-control')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
    Metrics = [ordered]@{
        WindowsPowerShellVersion = [string]$validation.NativeBootstrap.PowerShellVersion
        WindowsPowerShellRuntime = [string]$validation.NativeBootstrap.RuntimeDescription
        PowerShell7Path = $powerShell7
        PowerShell7Version = [string]$powerShell7Validation.NativeBootstrap.PowerShellVersion
        PowerShell7Runtime = [string]$powerShell7Validation.NativeBootstrap.RuntimeDescription
    }
} | ConvertTo-Json -Depth 8
