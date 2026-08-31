[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArtifactPath,
    [string] $ExecutableRelativePath,
    [string] $Arguments = '',
    [string] $ActionsPath,
    [string] $ActionsJson,
    [string] $AssertResultFile,
    [string] $AssertResultJsonPointer,
    [string] $AssertResultEqualsJson,
    [string] $ResultsRoot,
    [switch] $HostExecutionAuthorized,
    [switch] $LeaveRunning,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$initialWarningSeconds = 5
$resumeIdleSeconds = 10
$haloFrameThicknessPixels = 12
$script:observedPhysicalInputVersion = [long]0
$script:userPauseCount = 0
$script:focusRestoreCount = 0
$script:totalPausedMilliseconds = [long]0
$script:pauseDetectionArmed = $false
$script:windowHandle = [IntPtr]::Zero
$script:runtime = $null
$script:rootProcess = $null
$script:rootProcessStartedUtc = $null
$script:trackedProcessStarts = @{}

function Assert-HostExecutionAuthorization {
    if (-not $HostExecutionAuthorized) {
        throw 'HostExecutionAuthorized is required. Pass it only after the user explicitly requested that this named artifact be run on the physical host.'
    }
}

function Assert-InteractiveHostSession {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User -and $identity.User.Value -eq 'S-1-5-18') {
        throw 'Host control cannot run as SYSTEM because session 0 cannot control the visible user desktop.'
    }
    if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -le 0) {
        throw 'Host control requires the currently logged-in interactive user session.'
    }
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory = $true)] [IO.FileSystemInfo] $Item, [Parameter(Mandatory = $true)] [string] $Context)
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Context must not be a symbolic link or other reparse point."
    }
}

function Assert-NoExecutableReparseTraversal {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $RelativePath
    )
    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') -or $_.Contains(':') }).Count -gt 0) {
        throw 'ExecutableRelativePath must contain only unambiguous relative path segments.'
    }
    $current = $Root
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        Assert-NoReparsePoint -Item $item -Context "ExecutableRelativePath component '$part'"
    }
}

function Assert-SupportedReservedTokens {
    param(
        [AllowNull()] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Context,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [string[]] $AllowedTokens
    )
    if ([string]::IsNullOrEmpty($Value)) { return }
    foreach ($match in [regex]::Matches($Value, '\{[^{}]+\}')) {
        $token = $match.Value.Trim('{', '}')
        if ($token -notin $AllowedTokens) {
            $allowed = if ($AllowedTokens.Count -gt 0) { ($AllowedTokens | ForEach-Object { '{' + $_ + '}' }) -join ', ' } else { '<none>' }
            throw "$Context contains unresolved reserved token '$($match.Value)'. Allowed tokens: $allowed."
        }
    }
}

function Get-ValidatedOutdirRelativePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $Context
    )
    $prefix = '{OUTDIR}\'
    if (-not $Value.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw "$Context must begin with {OUTDIR}\."
    }
    $relative = $Value.Substring($prefix.Length)
    if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) {
        throw "$Context must identify a relative file below {OUTDIR}."
    }
    $parts = @($relative -split '[\\/]')
    if (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -gt 0) {
        throw "$Context escapes the request output directory."
    }
    $relative
}

function Assert-ValidJsonPointer {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { return }
    if ($Value.Length -gt 0 -and -not $Value.StartsWith('/', [StringComparison]::Ordinal)) {
        throw 'AssertResultJsonPointer must be empty or begin with a slash.'
    }
    if ([regex]::IsMatch($Value, '~(?![01])')) {
        throw 'AssertResultJsonPointer contains an invalid RFC 6901 escape.'
    }
}

function Assert-ValidExpectedJson {
    param([AllowNull()] [string] $Value)
    if ($null -eq $Value) { return }
    try { $null = ('{"value":' + $Value + '}') | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "AssertResultEqualsJson must be a valid JSON value: $($_.Exception.Message)" }
}

function Get-HostActions {
    if (-not [string]::IsNullOrWhiteSpace($ActionsPath) -and -not [string]::IsNullOrWhiteSpace($ActionsJson)) {
        throw 'ActionsPath and ActionsJson cannot be specified together.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ActionsPath)) {
        $parsed = Get-Content -Raw -LiteralPath $ActionsPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ActionsJson)) {
        $parsed = $ActionsJson | ConvertFrom-Json -ErrorAction Stop
    }
    else {
        $parsed = @(
            [ordered]@{ type = 'wait_window'; timeoutMs = 30000 },
            [ordered]@{ type = 'screenshot'; name = 'launched.png' },
            [ordered]@{ type = 'wait'; ms = 2000 },
            [ordered]@{ type = 'screenshot'; name = 'after-wait.png' }
        )
    }
    $actions = @($parsed)
    if ($actions.Count -eq 0) { throw 'At least one host action is required.' }
    $actions
}

function Assert-HostActions {
    param([Parameter(Mandatory = $true)] [object[]] $Actions)

    $screenshotNames = @()
    for ($index = 0; $index -lt $Actions.Count; $index++) {
        $action = $Actions[$index]
        $type = [string]$action.type
        if ([string]::IsNullOrWhiteSpace($type)) { throw "Action $($index + 1) has no type." }
        switch ($type) {
            'wait_window' {
                $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 15000 }
                if ($timeout -lt 100 -or $timeout -gt 300000) { throw "Action $($index + 1) wait_window timeoutMs must be between 100 and 300000." }
            }
            'focus_window' {
            }
            'click_control' {
                if ([string]::IsNullOrWhiteSpace([string]$action.automationId) -and [string]::IsNullOrWhiteSpace([string]$action.name)) {
                    throw "Action $($index + 1) click_control requires automationId or name."
                }
                $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 10000 }
                if ($timeout -lt 100 -or $timeout -gt 300000) { throw "Action $($index + 1) click_control timeoutMs must be between 100 and 300000." }
            }
            'click_relative' {
                if ($null -eq $action.x -or $null -eq $action.y) { throw "Action $($index + 1) click_relative requires x and y." }
                try { $null = [int]$action.x; $null = [int]$action.y }
                catch { throw "Action $($index + 1) click_relative x and y must be 32-bit integers." }
            }
            'type_text' {
                if ($null -eq $action.text) { throw "Action $($index + 1) type_text requires text." }
                if ([string]$action.text -and ([string]$action.text).Length -gt 65536) { throw "Action $($index + 1) type_text is limited to 65536 characters." }
            }
            'wait' {
                $milliseconds = [int]$action.ms
                if ($milliseconds -lt 0 -or $milliseconds -gt 300000) { throw "Action $($index + 1) wait ms must be between 0 and 300000." }
            }
            'wait_process_exit' {
                $timeout = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
                if ($timeout -lt 100 -or $timeout -gt 7200000) { throw "Action $($index + 1) wait_process_exit timeoutMs must be between 100 and 7200000." }
                if ($null -ne $action.expectedExitCode) {
                    try { $null = [int]$action.expectedExitCode }
                    catch { throw "Action $($index + 1) wait_process_exit expectedExitCode must be a 32-bit integer." }
                }
            }
            'wait_result_file' {
                if ([string]::IsNullOrWhiteSpace([string]$action.path)) { throw "Action $($index + 1) wait_result_file requires path." }
                $timeout = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
                if ($timeout -lt 100 -or $timeout -gt 7200000) { throw "Action $($index + 1) wait_result_file timeoutMs must be between 100 and 7200000." }
                $null = Get-ValidatedOutdirRelativePath -Value ([string]$action.path) -Context "Action $($index + 1) wait_result_file path"
            }
            'screenshot' {
                $name = if ([string]::IsNullOrWhiteSpace([string]$action.name)) { 'screenshot.png' } else { [string]$action.name }
                if ([IO.Path]::GetFileName($name) -ne $name -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                    throw "Action $($index + 1) screenshot name must be a valid leaf filename."
                }
                if ($name -in $screenshotNames) { throw "Duplicate screenshot evidence filename: $name" }
                $screenshotNames += $name
            }
            default { throw "Unsupported action type at position $($index + 1): $type" }
        }

        foreach ($property in @($action.PSObject.Properties | Where-Object { $_.Value -is [string] })) {
            $allowed = if ($property.Name -eq 'type' -or ($type -eq 'screenshot' -and $property.Name -eq 'name')) {
                @()
            }
            elseif ($type -eq 'wait_result_file' -and $property.Name -eq 'path') {
                @('OUTDIR')
            }
            else {
                @('PAYLOAD', 'OUTDIR')
            }
            Assert-SupportedReservedTokens -Value ([string]$property.Value) -Context "Action $($index + 1) '$($property.Name)'" -AllowedTokens $allowed
        }
    }
}

function Expand-HostTokens {
    param(
        [AllowNull()] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $PayloadRoot,
        [Parameter(Mandatory = $true)] [string] $OutputRoot
    )
    if ($null -eq $Value) { return $null }
    $Value.Replace('{PAYLOAD}', $PayloadRoot).Replace('{OUTDIR}', $OutputRoot)
}

function Import-HostControlNative {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('Codex.HostControl.HostControlRuntime' -as [type])) {
        $nativePath = Join-Path $PSScriptRoot 'HostControlNative.cs'
        if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) { throw "Host-control native source is missing: $nativePath" }
        Add-Type -Path $nativePath -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll')
    }
}

function Throw-IfHostControlCancelled {
    $snapshot = $script:runtime.GetSnapshot()
    if ($snapshot.CancelRequested) {
        throw [OperationCanceledException]::new('Host control was cancelled with Escape.')
    }
    $snapshot
}

function Get-TrackedHostProcessIds {
    if (-not $script:rootProcess) { return @() }
    try {
        $script:rootProcess.Refresh()
        $rootId = [int]$script:rootProcess.Id
    }
    catch { return @() }

    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, CreationDate)
    $accepted = New-Object 'Collections.Generic.HashSet[int]'
    [void]$accepted.Add($rootId)
    $script:trackedProcessStarts[$rootId] = $script:rootProcessStartedUtc
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($candidate in $all) {
            $candidateId = [int]$candidate.ProcessId
            if ($accepted.Contains($candidateId) -or -not $accepted.Contains([int]$candidate.ParentProcessId)) { continue }
            $createdUtc = try { ([DateTime]$candidate.CreationDate).ToUniversalTime() } catch { $script:rootProcessStartedUtc }
            if ($createdUtc -lt $script:rootProcessStartedUtc.AddSeconds(-2)) { continue }
            [void]$accepted.Add($candidateId)
            $script:trackedProcessStarts[$candidateId] = $createdUtc
            $changed = $true
        }
    }
    @($accepted)
}

function Get-ControlledWindow {
    $processIds = @(Get-TrackedHostProcessIds)
    if ($processIds.Count -eq 0) { return [IntPtr]::Zero }
    if ([Codex.HostControl.HostWindowControl]::IsUsable($script:windowHandle) -and
        [Codex.HostControl.HostWindowControl]::GetProcessId($script:windowHandle) -in $processIds) {
        return $script:windowHandle
    }
    foreach ($processId in $processIds) {
        $candidate = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $candidate) { continue }
        $candidate.Refresh()
        if ($candidate.MainWindowHandle -ne [IntPtr]::Zero -and [Codex.HostControl.HostWindowControl]::IsUsable($candidate.MainWindowHandle)) {
            $script:windowHandle = $candidate.MainWindowHandle
            return $script:windowHandle
        }
    }
    [IntPtr]::Zero
}

function Restore-ControlledWindowFocus {
    $window = Get-ControlledWindow
    if ($window -eq [IntPtr]::Zero) { return $false }
    $processIds = [int[]]@(Get-TrackedHostProcessIds)
    if (-not [Codex.HostControl.HostWindowControl]::Focus($window, $processIds)) {
        throw 'The controlled application could not be restored to the foreground. No input was injected.'
    }
    $script:windowHandle = $window
    $true
}

function Wait-ForHostControlReady {
    param([switch] $RefocusAfterResume)

    $snapshot = Throw-IfHostControlCancelled
    if (-not [Codex.HostControl.HostControlContract]::ShouldPauseForPhysicalInput(
        $script:pauseDetectionArmed,
        $snapshot.PhysicalInputVersion,
        $script:observedPhysicalInputVersion)) { return $false }

    $pauseStarted = [DateTime]::UtcNow
    $script:userPauseCount++
    $script:runtime.SetState([Codex.HostControl.HaloState]::Paused)
    while ($true) {
        $snapshot = Throw-IfHostControlCancelled
        $script:observedPhysicalInputVersion = [long]$snapshot.PhysicalInputVersion
        $resumeDelayMilliseconds = [Codex.HostControl.HostControlContract]::GetResumeDelayMilliseconds([DateTime]::UtcNow, $snapshot.LastPhysicalInputUtc)
        if ($resumeDelayMilliseconds -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(100, [Math]::Max(25, $resumeDelayMilliseconds)))
    }

    if ($RefocusAfterResume -and $script:rootProcess) {
        if (Restore-ControlledWindowFocus) { $script:focusRestoreCount++ }
    }
    $script:runtime.SetState([Codex.HostControl.HaloState]::Active)
    $script:totalPausedMilliseconds += [long]([DateTime]::UtcNow - $pauseStarted).TotalMilliseconds
    $true
}

function Wait-InitialHostControlWarning {
    $script:runtime.SetState([Codex.HostControl.HaloState]::Warning)
    $deadline = [DateTime]::UtcNow.AddSeconds($initialWarningSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $null = Throw-IfHostControlCancelled
        Start-Sleep -Milliseconds 50
    }
    $snapshot = Throw-IfHostControlCancelled
    $script:observedPhysicalInputVersion = [long]$snapshot.PhysicalInputVersion
    $script:runtime.SetState([Codex.HostControl.HaloState]::Active)
    $script:pauseDetectionArmed = $true
}

function Wait-HostControlDelay {
    param([ValidateRange(0, 7200000)] [int64] $Milliseconds, [switch] $RefocusAfterResume)
    $remaining = [int64]$Milliseconds
    while ($remaining -gt 0) {
        $paused = Wait-ForHostControlReady -RefocusAfterResume:$RefocusAfterResume
        if ($paused) { continue }
        $before = Throw-IfHostControlCancelled
        $slice = [int][Math]::Min(100, $remaining)
        Start-Sleep -Milliseconds $slice
        $after = Throw-IfHostControlCancelled
        if ($after.PhysicalInputVersion -eq $before.PhysicalInputVersion) { $remaining -= $slice }
    }
}

function Wait-ControlledMainWindow {
    param([ValidateRange(100, 300000)] [int] $TimeoutMilliseconds = 15000)
    $remaining = [int64]$TimeoutMilliseconds
    while ($remaining -gt 0) {
        $paused = Wait-ForHostControlReady -RefocusAfterResume
        if ($paused) { continue }
        $window = Get-ControlledWindow
        if ($window -ne [IntPtr]::Zero) {
            $script:windowHandle = $window
            if (-not (Restore-ControlledWindowFocus)) { throw 'The controlled application window could not be focused.' }
            return $window
        }
        $script:rootProcess.Refresh()
        if ($script:rootProcess.HasExited) { throw "Process $($script:rootProcess.Id) exited before creating a main window." }
        $slice = [int][Math]::Min(100, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    throw "Timed out waiting for the controlled application to create a main window after $TimeoutMilliseconds ms."
}

function Find-HostAutomationElement {
    param(
        [Parameter(Mandatory = $true)] [IntPtr] $Window,
        [string] $AutomationId,
        [string] $Name,
        [ValidateRange(100, 300000)] [int] $TimeoutMilliseconds = 10000
    )
    $remaining = [int64]$TimeoutMilliseconds
    $inventory = @()
    $lastError = $null
    while ($remaining -gt 0) {
        $paused = Wait-ForHostControlReady -RefocusAfterResume
        if ($paused) {
            $Window = Get-ControlledWindow
            continue
        }
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($Window)
            $elements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $seen = New-Object Collections.Generic.List[string]
            foreach ($element in $elements) {
                try {
                    $id = [string]$element.Current.AutomationId
                    $elementName = [string]$element.Current.Name
                    $controlType = [string]$element.Current.ControlType.ProgrammaticName
                    if ($seen.Count -lt 30 -and (-not [string]::IsNullOrWhiteSpace($id) -or -not [string]::IsNullOrWhiteSpace($elementName))) {
                        $seen.Add("$controlType id='$id' name='$elementName'")
                    }
                    $idMatch = -not [string]::IsNullOrWhiteSpace($AutomationId) -and [string]::Equals($id, $AutomationId, [StringComparison]::OrdinalIgnoreCase)
                    $nameMatch = -not [string]::IsNullOrWhiteSpace($Name) -and [string]::Equals($elementName, $Name, [StringComparison]::OrdinalIgnoreCase)
                    $idAsName = [string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($AutomationId) -and [string]::Equals($elementName, $AutomationId, [StringComparison]::OrdinalIgnoreCase)
                    if ($idMatch -or $nameMatch -or $idAsName) { return $element }
                }
                catch {
                }
            }
            $inventory = $seen.ToArray()
            $lastError = $null
        }
        catch { $lastError = $_.Exception.Message }
        $slice = [int][Math]::Min(100, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    $inventoryText = if ($inventory.Count -gt 0) { $inventory -join '; ' } else { '<none>' }
    $errorText = if ($lastError) { " Last provider error: $lastError" } else { '' }
    throw "Timed out finding automation element id='$AutomationId' name='$Name'. Available elements: $inventoryText.$errorText"
}

function Invoke-HostAutomationClick {
    param([Parameter(Mandatory = $true)] $Element)

    $paused = Wait-ForHostControlReady -RefocusAfterResume
    $null = Restore-ControlledWindowFocus
    $null = Wait-ForHostControlReady -RefocusAfterResume

    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        return [pscustomobject][ordered]@{ Method = 'UIAutomationInvoke'; X = $null; Y = $null }
    }
    $rectangle = $Element.Current.BoundingRectangle
    if ($rectangle.IsEmpty -or $rectangle.Width -le 0 -or $rectangle.Height -le 0) { throw 'The automation element has no clickable bounding rectangle.' }
    $x = [int]($rectangle.Left + ($rectangle.Width / 2))
    $y = [int]($rectangle.Top + ($rectangle.Height / 2))
    [Codex.HostControl.HostSyntheticInput]::ClickLeft($x, $y)
    [pscustomobject][ordered]@{ Method = 'SyntheticMouse'; X = $x; Y = $y }
}

function Send-HostText {
    param([AllowEmptyString()] [string] $Text)
    $null = Restore-ControlledWindowFocus
    $allowedProcessIds = [int[]]@(Get-TrackedHostProcessIds)
    foreach ($character in $Text.ToCharArray()) {
        $paused = Wait-ForHostControlReady -RefocusAfterResume
        if ($paused) { $allowedProcessIds = [int[]]@(Get-TrackedHostProcessIds) }
        if ([Codex.HostControl.HostWindowControl]::GetForegroundProcessId() -notin $allowedProcessIds) {
            $null = Restore-ControlledWindowFocus
            $allowedProcessIds = [int[]]@(Get-TrackedHostProcessIds)
        }
        $null = Wait-ForHostControlReady -RefocusAfterResume
        [Codex.HostControl.HostSyntheticInput]::TypeCharacter($character)
    }
}

function Capture-ControlledWindow {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $null = Wait-ForHostControlReady -RefocusAfterResume
    $window = Get-ControlledWindow
    if ($window -eq [IntPtr]::Zero) { throw 'The controlled application has no capturable top-level window.' }
    $null = Restore-ControlledWindowFocus
    $snapshot = Throw-IfHostControlCancelled
    $bounds = [Codex.HostControl.HostWindowControl]::GetBounds($window)
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw 'The controlled application window has invalid capture dimensions.' }
    $temporary = $Path + '.tmp.png'
    $suppressHalo = $snapshot.CaptureProtectionMode -ne 'ExcludeFromCapture'
    $captureMethod = if ($suppressHalo) { 'HaloSuppressedCopyFromScreen' } else { 'OsProtectedCopyFromScreen' }
    if ($suppressHalo) {
        $script:runtime.SetHaloVisible($false)
        Start-Sleep -Milliseconds 50
    }
    try {
        $bitmap = New-Object Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bounds.Size, [Drawing.CopyPixelOperation]::SourceCopy)
            $bitmap.Save($temporary, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
    finally {
        if ($suppressHalo) { $script:runtime.SetHaloVisible($true) }
    }
    Move-Item -LiteralPath $temporary -Destination $Path -Force
    [pscustomobject][ordered]@{
        Width = $bounds.Width
        Height = $bounds.Height
        CaptureMethod = $captureMethod
        OsCaptureProtection = $snapshot.CaptureProtectionMode -eq 'ExcludeFromCapture'
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Resolve-OutputEvidencePath {
    param([Parameter(Mandatory = $true)] [string] $TokenPath, [Parameter(Mandatory = $true)] [string] $OutputRoot)
    $relative = Get-ValidatedOutdirRelativePath -Value $TokenPath -Context 'Evidence path'
    $root = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
    if (-not $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence path escapes the host-control output directory.' }
    $candidate
}

function Resolve-JsonPointerValue {
    param([Parameter(Mandatory = $true)] $Root, [Parameter(Mandatory = $true)] [string] $Pointer)
    if ($Pointer.Length -eq 0) { return $Root }
    $current = $Root
    foreach ($segment in $Pointer.Substring(1).Split('/')) {
        $name = $segment.Replace('~1', '/').Replace('~0', '~')
        if ($current -is [Collections.IList]) {
            $index = 0
            if (-not [int]::TryParse($name, [ref]$index) -or $index -lt 0 -or $index -ge $current.Count) { throw "JSON pointer segment '$name' is outside the array." }
            $current = $current[$index]
        }
        else {
            $property = $current.PSObject.Properties[$name]
            if (-not $property) { throw "JSON pointer property '$name' does not exist." }
            $current = $property.Value
        }
    }
    $current
}

function Test-HostResultAssertion {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
    $actual = Resolve-JsonPointerValue -Root $document -Pointer $AssertResultJsonPointer
    $expectedWrapper = ('{"value":' + $AssertResultEqualsJson + '}') | ConvertFrom-Json
    $actualJson = ConvertTo-Json $actual -Compress -Depth 50
    $expectedJson = ConvertTo-Json $expectedWrapper.value -Compress -Depth 50
    [pscustomobject][ordered]@{ Passed = [string]::Equals($actualJson, $expectedJson, [StringComparison]::Ordinal); ActualJson = $actualJson; ExpectedJson = $expectedJson }
}

function Stop-ControlledProcessTree {
    if (-not $script:rootProcess) { return [pscustomobject][ordered]@{ Attempted = $false; Success = $true; ProcessIds = @() } }
    $processIds = @(Get-TrackedHostProcessIds)
    foreach ($processId in $processIds) {
        $candidate = Get-VerifiedTrackedProcess -ProcessId $processId
        if ($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero) {
            try { $candidate.CloseMainWindow() | Out-Null } catch { }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $survivors = @($processIds | Where-Object { $null -ne (Get-VerifiedTrackedProcess -ProcessId $_) })
        if ($survivors.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    foreach ($processId in $survivors) {
        $candidate = Get-VerifiedTrackedProcess -ProcessId $processId
        if (-not $candidate) { continue }
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        catch { }
    }
    $remaining = @($processIds | Where-Object { $null -ne (Get-VerifiedTrackedProcess -ProcessId $_) })
    [pscustomobject][ordered]@{ Attempted = $true; Success = $remaining.Count -eq 0; ProcessIds = $processIds; Survivors = $remaining }
}

function Get-VerifiedTrackedProcess {
    param([Parameter(Mandatory = $true)] [int] $ProcessId)
    $candidate = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $candidate) { return $null }
    $trackedStart = $script:trackedProcessStarts[$ProcessId]
    if (-not $trackedStart) { return $null }
    try {
        $startedUtc = $candidate.StartTime.ToUniversalTime()
        if ([Math]::Abs(($startedUtc - ([DateTime]$trackedStart)).TotalSeconds) -le 2) { return $candidate }
    }
    catch { }
    $null
}

Assert-HostExecutionAuthorization
$artifact = Get-Item -LiteralPath $ArtifactPath -Force -ErrorAction Stop
Assert-NoReparsePoint -Item $artifact -Context 'ArtifactPath'
$canonicalArtifactPath = [IO.Path]::GetFullPath($artifact.FullName)
if ($artifact.PSIsContainer) {
    $canonicalArtifactPath = $canonicalArtifactPath.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($ExecutableRelativePath) -or [IO.Path]::IsPathRooted($ExecutableRelativePath)) {
        throw 'ExecutableRelativePath is required and must be relative when ArtifactPath is a directory.'
    }
    $payloadPrefix = $canonicalArtifactPath + '\'
    $executablePath = [IO.Path]::GetFullPath([IO.Path]::Combine($canonicalArtifactPath, $ExecutableRelativePath))
    if (-not $executablePath.StartsWith($payloadPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ExecutableRelativePath escapes ArtifactPath.' }
    Assert-NoExecutableReparseTraversal -Root $canonicalArtifactPath -RelativePath $ExecutableRelativePath
}
else {
    if (-not [string]::IsNullOrWhiteSpace($ExecutableRelativePath)) { throw 'Do not specify ExecutableRelativePath when ArtifactPath is a file.' }
    $executablePath = $canonicalArtifactPath
    $canonicalArtifactPath = Split-Path -Parent $canonicalArtifactPath
}
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw "Executable not found: $executablePath" }

$hasPointer = $PSBoundParameters.ContainsKey('AssertResultJsonPointer')
$hasExpected = $PSBoundParameters.ContainsKey('AssertResultEqualsJson')
if ($hasPointer -xor $hasExpected) { throw 'AssertResultJsonPointer and AssertResultEqualsJson must be specified together.' }
if (($hasPointer -or $hasExpected) -and [string]::IsNullOrWhiteSpace($AssertResultFile)) { throw 'AssertResultFile is required when a JSON assertion is specified.' }
Assert-ValidJsonPointer -Value $AssertResultJsonPointer
if ($hasExpected) { Assert-ValidExpectedJson -Value $AssertResultEqualsJson }
if (-not [string]::IsNullOrWhiteSpace($AssertResultFile)) { $null = Get-ValidatedOutdirRelativePath -Value $AssertResultFile -Context 'AssertResultFile' }
Assert-SupportedReservedTokens -Value $Arguments -Context 'Arguments' -AllowedTokens @('PAYLOAD', 'OUTDIR')
$actions = @(Get-HostActions)
Assert-HostActions -Actions $actions

$contract = [ordered]@{
    InitialWarningSeconds = $initialWarningSeconds
    ResumeIdleSeconds = $resumeIdleSeconds
    CancelKey = 'Escape'
    ActiveHaloColor = '#F000FF'
    InitialGraceInputBehavior = 'IgnoreForPause'
    PostGraceInputBehavior = 'PauseImmediately'
    ResumeBehavior = 'RefocusThenContinue'
    HaloRendering = 'ContinuousNonOverlappingBands'
    HaloFrameThicknessPixels = $haloFrameThicknessPixels
    ExecutionTarget = 'PhysicalHost'
}
if ($ValidateOnly) {
    [pscustomobject][ordered]@{
        Success = $true
        Status = 'Validated'
        ArtifactPath = $artifact.FullName
        ExecutablePath = $executablePath
        ActionCount = $actions.Count
        HostControl = $contract
    } | ConvertTo-Json -Depth 10
    return
}

Assert-InteractiveHostSession
Import-HostControlNative
if ([Codex.HostControl.HostControlContract]::InitialWarningSeconds -ne $initialWarningSeconds -or
    [Codex.HostControl.HostControlContract]::ResumeIdleSeconds -ne $resumeIdleSeconds -or
    [Codex.HostControl.HostControlContract]::HaloFrameThicknessPixels -ne $haloFrameThicknessPixels) {
    throw 'The PowerShell and native host-control timing or visual contracts disagree.'
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $ResultsRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Codex\HostControl\Results'
}
$requestId = 'host-control-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
$outputRoot = Join-Path ([IO.Path]::GetFullPath($ResultsRoot)) $requestId
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$expandedArguments = Expand-HostTokens -Value $Arguments -PayloadRoot $canonicalArtifactPath -OutputRoot $outputRoot
$actionLog = New-Object Collections.Generic.List[object]
$startedUtc = [DateTime]::UtcNow
$status = 'Failed'
$success = $false
$cancelled = $false
$failureKind = $null
$errorMessage = $null
$processCleanup = $null
$assertion = $null

try {
    $script:runtime = New-Object Codex.HostControl.HostControlRuntime
    $initialSnapshot = $script:runtime.GetSnapshot()
    $script:observedPhysicalInputVersion = [long]$initialSnapshot.PhysicalInputVersion
    Write-Host "Host control armed for '$($artifact.Name)'. Fuchsia halo visible; control begins in five seconds. Mouse and keyboard activity will not pause this grace period; press Escape to cancel."
    Wait-InitialHostControlWarning
    $null = Wait-ForHostControlReady

    $startParameters = @{
        FilePath = $executablePath
        PassThru = $true
        WorkingDirectory = (Split-Path -Parent $executablePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($expandedArguments)) { $startParameters.ArgumentList = $expandedArguments }
    $script:rootProcess = Start-Process @startParameters
    $script:rootProcessStartedUtc = try { $script:rootProcess.StartTime.ToUniversalTime() } catch { [DateTime]::UtcNow }
    $script:trackedProcessStarts[[int]$script:rootProcess.Id] = $script:rootProcessStartedUtc

    for ($index = 0; $index -lt $actions.Count; $index++) {
        $action = $actions[$index]
        $type = [string]$action.type
        $actionStarted = [DateTime]::UtcNow
        $details = $null
        try {
            $null = Wait-ForHostControlReady -RefocusAfterResume
            switch ($type) {
                'wait_window' {
                    $script:windowHandle = Wait-ControlledMainWindow -TimeoutMilliseconds $(if ($action.timeoutMs) { [int]$action.timeoutMs } else { 15000 })
                    $details = [ordered]@{ WindowHandle = $script:windowHandle.ToInt64(); ProcessId = [Codex.HostControl.HostWindowControl]::GetProcessId($script:windowHandle) }
                }
                'focus_window' {
                    if ($script:windowHandle -eq [IntPtr]::Zero) { $script:windowHandle = Wait-ControlledMainWindow }
                    if (-not (Restore-ControlledWindowFocus)) { throw 'The controlled application window could not be focused.' }
                }
                'click_control' {
                    if ($script:windowHandle -eq [IntPtr]::Zero) { $script:windowHandle = Wait-ControlledMainWindow }
                    $element = Find-HostAutomationElement -Window $script:windowHandle -AutomationId ([string]$action.automationId) -Name ([string]$action.name) -TimeoutMilliseconds $(if ($action.timeoutMs) { [int]$action.timeoutMs } else { 10000 })
                    $details = Invoke-HostAutomationClick -Element $element
                }
                'click_relative' {
                    if ($script:windowHandle -eq [IntPtr]::Zero) { $script:windowHandle = Wait-ControlledMainWindow }
                    $null = Restore-ControlledWindowFocus
                    $null = Wait-ForHostControlReady -RefocusAfterResume
                    $bounds = [Codex.HostControl.HostWindowControl]::GetBounds($script:windowHandle)
                    $x = $bounds.Left + [int]$action.x
                    $y = $bounds.Top + [int]$action.y
                    if ($x -lt $bounds.Left -or $x -ge $bounds.Right -or $y -lt $bounds.Top -or $y -ge $bounds.Bottom) { throw 'click_relative coordinates are outside the controlled window.' }
                    [Codex.HostControl.HostSyntheticInput]::ClickLeft($x, $y)
                    $details = [ordered]@{ Method = 'SyntheticMouse'; X = $x; Y = $y }
                }
                'type_text' {
                    if ($script:windowHandle -eq [IntPtr]::Zero) { $script:windowHandle = Wait-ControlledMainWindow }
                    Send-HostText -Text (Expand-HostTokens -Value ([string]$action.text) -PayloadRoot $canonicalArtifactPath -OutputRoot $outputRoot)
                    $details = [ordered]@{ CharacterCount = ([string]$action.text).Length }
                }
                'wait' {
                    Wait-HostControlDelay -Milliseconds ([int64]$action.ms) -RefocusAfterResume
                }
                'wait_process_exit' {
                    $remaining = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
                    while ($remaining -gt 0) {
                        $paused = Wait-ForHostControlReady -RefocusAfterResume
                        if ($paused) { continue }
                        $script:rootProcess.Refresh()
                        if ($script:rootProcess.HasExited) { break }
                        $slice = [int][Math]::Min(100, $remaining)
                        Start-Sleep -Milliseconds $slice
                        $remaining -= $slice
                    }
                    $script:rootProcess.Refresh()
                    if (-not $script:rootProcess.HasExited) { throw 'Timed out waiting for the controlled process to exit.' }
                    if ($null -ne $action.expectedExitCode -and $script:rootProcess.ExitCode -ne [int]$action.expectedExitCode) { throw "Controlled process exit code $($script:rootProcess.ExitCode) did not match expected $([int]$action.expectedExitCode)." }
                    $details = [ordered]@{ ExitCode = $script:rootProcess.ExitCode }
                }
                'wait_result_file' {
                    $path = Resolve-OutputEvidencePath -TokenPath ([string]$action.path) -OutputRoot $outputRoot
                    $remaining = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
                    while ($remaining -gt 0 -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                        $paused = Wait-ForHostControlReady -RefocusAfterResume
                        if ($paused) { continue }
                        $slice = [int][Math]::Min(100, $remaining)
                        Start-Sleep -Milliseconds $slice
                        $remaining -= $slice
                    }
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Application result file was not created: $path" }
                    $details = [ordered]@{ Path = $path; Length = (Get-Item -LiteralPath $path).Length; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
                }
                'screenshot' {
                    $name = if ([string]::IsNullOrWhiteSpace([string]$action.name)) { 'screenshot.png' } else { [string]$action.name }
                    $details = Capture-ControlledWindow -Path (Join-Path $outputRoot $name)
                }
            }
            $actionLog.Add([ordered]@{ Index = $index + 1; Type = $type; StartedUtc = $actionStarted.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o'); Success = $true; Details = $details; Error = $null })
        }
        catch {
            $actionLog.Add([ordered]@{ Index = $index + 1; Type = $type; StartedUtc = $actionStarted.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o'); Success = $false; Details = $details; Error = $_.Exception.Message })
            throw
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AssertResultFile)) {
        $assertionPath = Resolve-OutputEvidencePath -TokenPath $AssertResultFile -OutputRoot $outputRoot
        if (-not (Test-Path -LiteralPath $assertionPath -PathType Leaf)) { throw "Asserted application result file does not exist: $assertionPath" }
        if ($hasPointer) {
            $assertion = Test-HostResultAssertion -Path $assertionPath
            if (-not $assertion.Passed) { throw "Application result assertion failed: expected $($assertion.ExpectedJson), actual $($assertion.ActualJson)." }
        }
    }
    $success = $true
    $status = 'Completed'
}
catch [OperationCanceledException] {
    $cancelled = $true
    $status = 'Cancelled'
    $failureKind = 'UserCancelled'
    $errorMessage = $_.Exception.Message
}
catch {
    $status = 'Failed'
    $failureKind = 'HostControlFailure'
    $errorMessage = $_.Exception.Message
}
finally {
    if (-not $LeaveRunning) { $processCleanup = Stop-ControlledProcessTree }
    else { $processCleanup = [pscustomobject][ordered]@{ Attempted = $false; Success = $true; ProcessIds = @(Get-TrackedHostProcessIds); LeftRunning = $true } }
    if (-not $LeaveRunning -and $processCleanup -and -not $processCleanup.Success) {
        $success = $false
        $cleanupMessage = 'The controlled application process tree could not be fully stopped.'
        if ($status -eq 'Completed') {
            $status = 'Failed'
            $failureKind = 'ProcessCleanupFailure'
            $errorMessage = $cleanupMessage
        }
        elseif ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = $cleanupMessage }
        else { $errorMessage += " $cleanupMessage" }
    }
    if ($script:runtime) {
        $script:runtime.Dispose()
        $script:runtime = $null
    }
}

$result = [ordered]@{
    Success = [bool]$success
    Status = $status
    FailureKind = $failureKind
    Error = $errorMessage
    Cancelled = [bool]$cancelled
    RequestId = $requestId
    ArtifactPath = $artifact.FullName
    ExecutablePath = $executablePath
    ApplicationProcessId = if ($script:rootProcess) { $script:rootProcess.Id } else { $null }
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    ResultPath = $outputRoot
    HostControl = [ordered]@{
        InitialWarningSeconds = $initialWarningSeconds
        ResumeIdleSeconds = $resumeIdleSeconds
        CancelKey = 'Escape'
        ActiveHaloColor = '#F000FF'
        InitialGraceInputBehavior = 'IgnoreForPause'
        PostGraceInputBehavior = 'PauseImmediately'
        HaloRendering = 'ContinuousNonOverlappingBands'
        HaloFrameThicknessPixels = [Codex.HostControl.HostControlContract]::HaloFrameThicknessPixels
        MonitorCount = if ($initialSnapshot) { $initialSnapshot.MonitorCount } else { 0 }
        OsCaptureProtectionSucceeded = if ($initialSnapshot) { [bool]$initialSnapshot.CaptureProtectionSucceeded } else { $false }
        FullCaptureExclusionSucceeded = if ($initialSnapshot) { [string]$initialSnapshot.CaptureProtectionMode -eq 'ExcludeFromCapture' } else { $false }
        CaptureProtectionMode = if ($initialSnapshot) { [string]$initialSnapshot.CaptureProtectionMode } else { 'NotStarted' }
        CaptureProtectionError = if ($initialSnapshot) { [int]$initialSnapshot.CaptureProtectionError } else { 0 }
        UserPauseCount = $script:userPauseCount
        FocusRestoreCount = $script:focusRestoreCount
        TotalPausedMilliseconds = $script:totalPausedMilliseconds
    }
    Actions = $actionLog.ToArray()
    Assertion = $assertion
    ProcessCleanup = $processCleanup
}
$resultPath = Join-Path $outputRoot 'host-control-result.json'
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 20
