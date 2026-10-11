function Get-NativeGamepadIds {
    foreach ($pad in [Windows.Gaming.Input.Gamepad]::Gamepads) {
        [Windows.Gaming.Input.RawGameController]::FromGameController($pad).NonRoamableId
    }
}

function Wait-NativeControllerDevice {
    param([string[]]$ExistingIds, [int]$TimeoutMilliseconds=5000)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $current=@(Get-NativeGamepadIds)
        $added=@($current | Where-Object { $_ -and $_ -notin $ExistingIds })
        if ($added.Count -gt 0 -or $watch.ElapsedMilliseconds -ge $TimeoutMilliseconds) { break }
        Start-Sleep -Milliseconds 50
    } while ($true)
    [pscustomobject]@{ DeviceEnumerated=($added.Count -gt 0); InitialCount=@($ExistingIds).Count; FinalCount=$current.Count; AddedCount=$added.Count; ElapsedMs=$watch.Elapsed.TotalMilliseconds }
}

function Reset-NativeController {
    if ($null -ne $script:NativeController) {
        try {
            $neutral=New-Object Windows.UI.Input.Preview.Injection.InjectedInputGamepadInfo
            $script:NativeController.InjectGamepadInput($neutral)
        }
        finally { $script:NativeController.UninitializeGamepadInjection(); $script:NativeController=$null }
    }
}

function Invoke-NativeController {
    param($Action)
    $evidence=[ordered]@{ Evaluated=$false; Passed=$null; Backend='Windows.UI.Input.Preview.Injection.InputInjector'; Operation=[string]$Action.operation; ProofLevel='WindowsVirtualGamepad'; PhysicalXboxVerified=$false; ApplicationReceptionVerified=$false }
    $stage='ResolveApi'
    try {
        $null=[Windows.UI.Input.Preview.Injection.InputInjector,Windows.UI.Input.Preview.Injection,ContentType=WindowsRuntime]
        $null=[Windows.UI.Input.Preview.Injection.InjectedInputGamepadInfo,Windows.UI.Input.Preview.Injection,ContentType=WindowsRuntime]
        $null=[Windows.Gaming.Input.GamepadButtons,Windows.Gaming.Input,ContentType=WindowsRuntime]
        $null=[Windows.Gaming.Input.Gamepad,Windows.Gaming.Input,ContentType=WindowsRuntime]
        $null=[Windows.Gaming.Input.RawGameController,Windows.Gaming.Input,ContentType=WindowsRuntime]
        if ($Action.operation -eq 'disconnect') {
            $stage='Disconnect'
            Reset-NativeController
            $evidence['Connected']=$false
            return $evidence
        }
        if ($Action.operation -in @('connect','probe')) {
            $stage='RequestState'
            if ($null -ne $script:NativeController) { throw 'A request-owned virtual gamepad is already connected.' }
            $stage='Create'
            $existingIds=@(Get-NativeGamepadIds)
            $injector=[Windows.UI.Input.Preview.Injection.InputInjector]::TryCreate()
            if ($null -eq $injector) { throw 'InputInjector.TryCreate returned null; this guest process lacks the inputInjectionBrokered capability.' }
            $stage='Initialize'
            $injector.InitializeGamepadInjection()
            $script:NativeController=$injector
            $stage='EnumerateDevice'
            $enumeration=Wait-NativeControllerDevice -ExistingIds $existingIds
            $evidence['DeviceEnumeration']=$enumeration
            if (-not $enumeration.DeviceEnumerated) {
                Reset-NativeController
                $evidence['Connected']=$false
                $evidence['FailureKind']='CapabilityUnavailable'; $evidence['Available']=$false; $evidence['ProofLevel']='Unavailable'; $evidence['Stage']=$stage
                $evidence['Error']='Windows accepted gamepad initialization but exposed no new Windows.Gaming.Input device within 5000 ms.'
                $evidence['Requirement']='A guest input stack that enumerates the injected virtual gamepad is required; API initialization alone does not establish device availability.'
                return $evidence
            }
            $evidence['Available']=$true
            $evidence['Connected']=$true
            if ($Action.operation -eq 'probe') { Reset-NativeController; $evidence['Connected']=$false }
            return $evidence
        }
        $stage='Input'
        if ($null -eq $script:NativeController) { throw 'No request-owned gamepad is connected; use controller connect first.' }
        $info=New-Object Windows.UI.Input.Preview.Injection.InjectedInputGamepadInfo
        $flags=0
        foreach ($button in @($Action.buttons)) { if ($null -ne $button) { $flags=$flags -bor [int][Enum]::Parse([Windows.Gaming.Input.GamepadButtons],[string]$button,$false) } }
        $info.Buttons=[Windows.Gaming.Input.GamepadButtons]$flags
        $info.LeftThumbstickX=[double]$Action.leftX; $info.LeftThumbstickY=[double]$Action.leftY
        $info.RightThumbstickX=[double]$Action.rightX; $info.RightThumbstickY=[double]$Action.rightY
        $info.LeftTrigger=[double]$Action.leftTrigger; $info.RightTrigger=[double]$Action.rightTrigger
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { $script:NativeController.InjectGamepadInput($info); Start-Sleep -Milliseconds ([int]$Action.holdMs) }
        finally { $script:NativeController.InjectGamepadInput((New-Object Windows.UI.Input.Preview.Injection.InjectedInputGamepadInfo)) }
        $evidence['RequestedHoldMs']=[int]$Action.holdMs; $evidence['ElapsedMs']=$watch.Elapsed.TotalMilliseconds
        $evidence['State']=$Action; $evidence['ReleasedToNeutral']=$true
        return $evidence
    }
    catch {
        $evidence['FailureKind']=if ($stage -in @('ResolveApi','Create','Initialize')) { 'CapabilityUnavailable' } else { 'ControllerInputFailure' }
        $evidence['Available']=$false
        $evidence['ProofLevel']='Unavailable'
        $evidence['Stage']=$stage
        $evidence['Error']=$_.Exception.Message
        $evidence['Requirement']='Windows gamepad input injection permitted for the guest interactive process. No driver installation, keyboard substitution, app event injection or physical Xbox proof is implied.'
        return $evidence
    }
}

function Invoke-NativeAudio {
    param($Action, [string]$Directory)
    try {
        $endpoints=[Codex.NativeApp.Audio]::Endpoints()
        if ($Action.type -eq 'audio_probe') {
            $renders=@($endpoints | Where-Object { $_.Flow -eq 'Render' -and $_.State -eq 1 })
            return [ordered]@{ Evaluated=$false; Passed=$null; Backend='WASAPI'; Endpoints=@($endpoints); Available=($renders.Count -gt 0); FailureKind=$(if ($renders.Count -eq 0) { 'CapabilityUnavailable' }); Error=$(if ($renders.Count -eq 0) { 'No active guest render endpoint exists for playback loopback capture.' }); ProofLevel='EndpointInventoryOnly' }
        }
        $capture=[Codex.NativeApp.Audio]::Capture([string]$Action.endpointId,[int]$Action.durationMs,[long]$Action.maxBytes,(Join-Path $Directory 'playback.wav'))
        [ordered]@{ Evaluated=$false; Passed=$null; Backend='WASAPI'; Endpoints=@($endpoints); Available=$true; Capture=$capture; File='playback.wav'; ProofLevel='GuestRenderEndpointLoopback'; Source='Actual guest endpoint mix, including other guest sounds; not application-produced or decoded audio'; PhysicalSpeakerVerified=$false }
    }
    catch {
        $cause=$_.Exception
        while ($cause.InnerException) { $cause=$cause.InnerException }
        $unavailable=$cause -is [Runtime.InteropServices.COMException] -or $cause -is [PlatformNotSupportedException] -or $cause.Message -eq 'Requested endpoint is not an active guest render endpoint.'
        [ordered]@{ Evaluated=$false; Passed=$null; Backend='WASAPI'; Endpoints=@($endpoints); Available=$false; FailureKind=$(if ($unavailable) { 'CapabilityUnavailable' } else { 'AudioCaptureFailure' }); Error=$cause.Message; Requirement='An active Windows guest render endpoint and a shared-mode loopback stream are required.' }
    }
}
