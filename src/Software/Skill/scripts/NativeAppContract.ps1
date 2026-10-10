# Shared, side-effect-free validation for the client, SYSTEM broker and guest.
$script:NativeAppActionTypes = @('wait_content','click_client','assert_image','capture_burst','controller','audio_probe','capture_audio','app_command')

function Assert-NativeProperties {
    param($Value, [string[]]$Allowed, [string]$Context)
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw "$Context must be a JSON object." }
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -cnotin $Allowed) { throw "$Context contains unsupported property '$($property.Name)'." }
    }
}

function Get-NativeNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [string]$Context, [switch]$Fractional)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "$Context must be numeric." }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum -or $number -gt $Maximum -or (-not $Fractional -and $number -ne [Math]::Truncate($number))) {
        throw "$Context must be $(if (-not $Fractional) { 'a whole number ' })between $Minimum and $Maximum."
    }
    $number
}

function Assert-NativeRectangle {
    param($Value, [string]$Context)
    Assert-NativeProperties $Value @('x','y','width','height') $Context
    foreach ($field in @('x','y')) { $null = Get-NativeNumber $Value.$field 0 8191 "$Context.$field" }
    foreach ($field in @('width','height')) { $null = Get-NativeNumber $Value.$field 1 8192 "$Context.$field" }
    if ([long]$Value.width * [long]$Value.height -gt 8388608) { throw "$Context exceeds 8388608 pixels." }
}

function Assert-NativeAppAction {
    param([Parameter(Mandatory=$true)]$Action, [switch]$ExpandedPaths)
    $type = [string]$Action.type
    if ($type -cnotin $script:NativeAppActionTypes) { throw "Unsupported native application action: $type" }
    $visual = @('viewport','region')
    $comparison = @('referencePath','channelTolerance','maxMismatchFraction','masks')
    $allowed = switch ($type) {
        'wait_content' { @('name','timeoutMs','pollMs','stableMs','pixels','notColor','minFraction') + $visual + $comparison }
        'click_client' { @('x','y','viewport') }
        'assert_image' { @('name') + $visual + $comparison }
        'capture_burst' { @('name','durationMs','fps','maxFrames','maxBytes','trigger') + $visual }
        'controller' { @('operation','buttons','leftX','leftY','rightX','rightY','leftTrigger','rightTrigger','holdMs') }
        'audio_probe' { @('name') }
        'capture_audio' { @('name','durationMs','maxBytes','endpointId') }
        'app_command' { @('name','operation','seed','ticks','timeoutMs','jsonPointer','equalsJson') }
    }
    Assert-NativeProperties $Action (@('type') + $allowed) $type
    if ($type -notin @('click_client','controller')) {
        if ([string]$Action.name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,47}$') { throw "$type name must be a unique 1-48 character evidence identifier." }
    }
    if ($Action.viewport) {
        Assert-NativeProperties $Action.viewport @('width','height','scaling') "$type.viewport"
        foreach ($field in @('width','height')) { $null = Get-NativeNumber $Action.viewport.$field 1 4096 "$type.viewport.$field" }
        if ([string]$Action.viewport.scaling -cnotin @('integer_fit','fit','stretch')) { throw "$type.viewport.scaling must be integer_fit, fit or stretch." }
    }
    if ($Action.region) { Assert-NativeRectangle $Action.region "$type.region" }
    if ($type -eq 'click_client') {
        foreach ($field in @('x','y')) { $null = Get-NativeNumber $Action.$field 0 8191 "$type.$field" }
    }
    if ($type -in @('wait_content','assert_image')) {
        if ($null -ne $Action.channelTolerance) { $null = Get-NativeNumber $Action.channelTolerance 0 255 "$type.channelTolerance" }
        if ($null -ne $Action.maxMismatchFraction) { $null = Get-NativeNumber $Action.maxMismatchFraction 0 1 "$type.maxMismatchFraction" -Fractional }
        if ($Action.referencePath) {
            if (([string]$Action.referencePath).Length -gt 1024) { throw "$type referencePath exceeds 1024 characters." }
            if (-not $ExpandedPaths -and [string]$Action.referencePath -cnotmatch '^\{(?:PAYLOAD|HOSTINPUT:[A-Za-z][A-Za-z0-9_-]{0,31})\}(?:[\\/]|$)') { throw "$type referencePath must be under PAYLOAD or a read-only HOSTINPUT token." }
            if ($ExpandedPaths -and [string]$Action.referencePath -notmatch '\.png$') { throw "$type referencePath must name a PNG." }
        }
        elseif ($type -eq 'assert_image') { throw 'assert_image requires referencePath.' }
        if (@($Action.masks).Count -gt 32) { throw "$type allows at most 32 masks." }
        foreach ($mask in @($Action.masks)) { if ($null -ne $mask) { Assert-NativeRectangle $mask "$type.mask" } }
    }
    if ($type -eq 'wait_content') {
        $null = Get-NativeNumber $Action.timeoutMs 100 300000 'wait_content.timeoutMs'
        if ($null -ne $Action.pollMs) { $null = Get-NativeNumber $Action.pollMs 25 2000 'wait_content.pollMs' }
        if ($null -ne $Action.stableMs) { $null = Get-NativeNumber $Action.stableMs 0 ([double]$Action.timeoutMs) 'wait_content.stableMs' }
        $conditions = [int][bool]$Action.referencePath + [int][bool]$Action.notColor + [int][bool]$Action.pixels
        if ($conditions -ne 1) { throw 'wait_content requires exactly one of referencePath, notColor or pixels.' }
        if ($Action.notColor) {
            if ([string]$Action.notColor -cnotmatch '^#[A-Fa-f0-9]{6}$') { throw 'notColor must be #RRGGBB.' }
            $null = Get-NativeNumber $Action.minFraction 0.000001 1 'wait_content.minFraction' -Fractional
        }
        if ($Action.pixels) {
            if (@($Action.pixels).Count -gt 64) { throw 'wait_content allows at most 64 pixel conditions.' }
            foreach ($pixel in @($Action.pixels)) {
                Assert-NativeProperties $pixel @('x','y','color') 'pixel'
                foreach ($field in @('x','y')) { $null = Get-NativeNumber $pixel.$field 0 8191 "pixel.$field" }
                if ([string]$pixel.color -cnotmatch '^#[A-Fa-f0-9]{6}$') { throw 'pixel.color must be #RRGGBB.' }
            }
        }
    }
    if ($type -eq 'capture_burst') {
        $null = Get-NativeNumber $Action.durationMs 50 10000 'capture_burst.durationMs'
        $null = Get-NativeNumber $Action.fps 1 60 'capture_burst.fps'
        $null = Get-NativeNumber $Action.maxFrames 1 240 'capture_burst.maxFrames'
        $null = Get-NativeNumber $Action.maxBytes 1024 67108864 'capture_burst.maxBytes'
        if ($Action.trigger) {
            if ([string]$Action.trigger.type -cne 'click_client') { throw 'capture_burst.trigger supports only click_client.' }
            Assert-NativeAppAction $Action.trigger
        }
    }
    if ($type -eq 'controller') {
        if ([string]$Action.operation -cnotin @('probe','connect','state','disconnect')) { throw 'controller.operation must be probe, connect, state or disconnect.' }
        if ($Action.operation -eq 'state') {
            $null = Get-NativeNumber $Action.holdMs 10 10000 'controller.holdMs'
            $buttons = @('Menu','View','A','B','X','Y','DPadUp','DPadDown','DPadLeft','DPadRight','LeftShoulder','RightShoulder','LeftThumbstick','RightThumbstick')
            if (@($Action.buttons).Count -gt 14) { throw 'controller.buttons exceeds 14.' }
            foreach ($button in @($Action.buttons)) { if ($null -ne $button -and $button -cnotin $buttons) { throw "Unsupported controller button: $button" } }
            foreach ($axis in @('leftX','leftY','rightX','rightY','leftTrigger','rightTrigger')) {
                if ($null -ne $Action.$axis) { $null = Get-NativeNumber $Action.$axis $(if ($axis -like '*Trigger') { 0 } else { -1 }) 1 "controller.$axis" -Fractional }
            }
        }
        elseif (@($Action.PSObject.Properties.Name | Where-Object { $_ -notin @('type','operation') }).Count -gt 0) { throw 'Controller input properties require operation=state.' }
    }
    if ($type -eq 'capture_audio') {
        $null = Get-NativeNumber $Action.durationMs 100 30000 'capture_audio.durationMs'
        $null = Get-NativeNumber $Action.maxBytes 1024 33554432 'capture_audio.maxBytes'
        if ($null -ne $Action.endpointId -and ([string]$Action.endpointId).Length -gt 512) { throw 'capture_audio.endpointId exceeds 512 characters.' }
    }
    if ($type -eq 'app_command') {
        if ([string]$Action.operation -cnotin @('ready','seed','advance','checkpoint')) { throw 'app_command.operation must be ready, seed, advance or checkpoint.' }
        $null = Get-NativeNumber $Action.timeoutMs 100 60000 'app_command.timeoutMs'
        if ($Action.operation -eq 'seed') { $null = Get-NativeNumber $Action.seed 0 2147483647 'app_command.seed' }
        elseif ($null -ne $Action.seed) { throw 'seed is valid only for the seed operation.' }
        if ($Action.operation -eq 'advance') { $null = Get-NativeNumber $Action.ticks 1 100000 'app_command.ticks' }
        elseif ($null -ne $Action.ticks) { throw 'ticks is valid only for the advance operation.' }
        if (($null -ne $Action.jsonPointer) -xor ($null -ne $Action.equalsJson)) { throw 'app_command requires both jsonPointer and equalsJson for an assertion.' }
        if ($null -ne $Action.jsonPointer) {
            if (([string]$Action.jsonPointer).Length -gt 1024 -or ([string]$Action.jsonPointer -ne '' -and [string]$Action.jsonPointer -notmatch '^/') -or [regex]::IsMatch([string]$Action.jsonPointer, '~(?![01])')) { throw 'app_command.jsonPointer is invalid.' }
            if (([string]$Action.equalsJson).Length -gt 16384) { throw 'app_command.equalsJson exceeds 16384 characters.' }
            try { $null = ('{"value":' + [string]$Action.equalsJson + '}') | ConvertFrom-Json -ErrorAction Stop } catch { throw 'app_command.equalsJson is invalid JSON.' }
        }
    }
}

function Assert-NativeAppActions {
    param([object[]]$Actions, [switch]$ExpandedPaths)
    $native=@($Actions | Where-Object { [string]$_.type -cin $script:NativeAppActionTypes })
    if ($native.Count -gt 32) { throw 'A request may contain at most 32 native application actions.' }
    $names=@{}; $budget=0L
    foreach ($action in $native) {
        Assert-NativeAppAction $action -ExpandedPaths:$ExpandedPaths
        if ($action.name) {
            if ($names.ContainsKey([string]$action.name)) { throw "Duplicate native evidence name: $($action.name)" }
            $names[[string]$action.name]=$true
        }
        $budget+=switch ([string]$action.type) {
            'assert_image' { 101711872L }
            'wait_content' { 34603008L }
            'capture_burst' { [long]$action.maxBytes + 1048576L }
            'capture_audio' { [long]$action.maxBytes + 1048576L }
            'app_command' { 2097152L }
            default { 1048576L }
        }
    }
    if ($budget -gt 268435456L) { throw 'Native action evidence reservations exceed the 256 MiB per-request budget; split the test.' }
}
