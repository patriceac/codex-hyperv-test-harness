$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CodexGuestInput
{
    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUTUNION data;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out RECT rectangle);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static void TypeUnicode(string text)
    {
        foreach (char character in text)
        {
            INPUT down = new INPUT();
            down.type = INPUT_KEYBOARD;
            down.data.keyboard.scanCode = character;
            down.data.keyboard.flags = KEYEVENTF_UNICODE;

            INPUT up = down;
            up.data.keyboard.flags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

            INPUT[] inputs = new INPUT[] { down, up };
            if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length)
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }

    public static void ClickLeft(int x, int y)
    {
        if (!SetCursorPos(x, y))
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }

        INPUT down = new INPUT();
        down.type = INPUT_MOUSE;
        down.data.mouse.dwFlags = MOUSEEVENTF_LEFTDOWN;

        INPUT up = new INPUT();
        up.type = INPUT_MOUSE;
        up.data.mouse.dwFlags = MOUSEEVENTF_LEFTUP;

        INPUT[] inputs = new INPUT[] { down, up };
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static int ProbeInputDesktop()
    {
        const uint DESKTOP_READOBJECTS = 0x0001;
        const uint DESKTOP_SWITCHDESKTOP = 0x0100;
        IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_READOBJECTS | DESKTOP_SWITCHDESKTOP);
        if (desktop == IntPtr.Zero)
        {
            return Marshal.GetLastWin32Error();
        }
        CloseDesktop(desktop);
        return 0;
    }
}
'@

$agentRoot = 'C:\CodexGuest'
$inboxPath = Join-Path $agentRoot 'Inbox'
$processingPath = Join-Path $agentRoot 'Processing'
$completedPath = Join-Path $agentRoot 'Completed'
$outboxPath = Join-Path $agentRoot 'Outbox'
$statePath = Join-Path $agentRoot 'agent-state.json'
$guestBootTimeUtc = $null

foreach ($path in @($inboxPath, $processingPath, $completedPath, $outboxPath)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else {
                    [IO.File]::Move($temporaryPath, $Path)
                }
                return
            }
            catch [IO.IOException] {
                if ($attempt -ge 20) { throw }
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge 20) { throw }
            }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-AgentState {
    param(
        [string] $Status = 'Idle',
        [string] $JobId = $null,
        [string] $ActionType = $null,
        [Nullable[int]] $ActionIndex = $null
    )

    Write-JsonAtomic -Path $statePath -Value ([ordered]@{
        Ready = $true
        Status = $Status
        JobId = $JobId
        ActionType = $ActionType
        ActionIndex = if ($null -ne $ActionIndex) { [int]$ActionIndex } else { $null }
        HeartbeatUtc = [DateTime]::UtcNow.ToString('o')
        ProcessId = $PID
        SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        UserInteractive = [Environment]::UserInteractive
        MachineName = $env:COMPUTERNAME
        GuestBootTimeUtc = (Get-CachedGuestBootTimeUtc)
    })
}

function Get-GuestProcessTree {
    param(
        [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $RootProcessId,
        [AllowEmptyCollection()] [object[]] $ProcessSnapshot
    )

    if (-not $PSBoundParameters.ContainsKey('ProcessSnapshot')) {
        $ProcessSnapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath)
    }

    $depthByProcessId = @{}
    $depthByProcessId[$RootProcessId] = 0
    do {
        $changed = $false
        foreach ($record in @($ProcessSnapshot)) {
            $processId = [int]$record.ProcessId
            $parentProcessId = [int]$record.ParentProcessId
            if ($processId -le 0 -or $processId -eq $RootProcessId -or $depthByProcessId.ContainsKey($processId)) {
                continue
            }
            if ($depthByProcessId.ContainsKey($parentProcessId)) {
                $depthByProcessId[$processId] = [int]$depthByProcessId[$parentProcessId] + 1
                $changed = $true
            }
        }
    } while ($changed)

    @($ProcessSnapshot | Where-Object { $depthByProcessId.ContainsKey([int]$_.ProcessId) } | ForEach-Object {
        [pscustomobject][ordered]@{
            ProcessId = [int]$_.ProcessId
            ParentProcessId = [int]$_.ParentProcessId
            Depth = [int]$depthByProcessId[[int]$_.ProcessId]
            Name = [string]$_.Name
            ExecutablePath = [string]$_.ExecutablePath
        }
    } | Sort-Object @{ Expression = { [int]$_.Depth }; Descending = $true }, @{ Expression = { [int]$_.ProcessId } })
}

function Stop-GuestProcessTree {
    param(
        [Parameter(Mandatory = $true)] [ValidateRange(1, 2147483647)] [int] $RootProcessId,
        [ValidateRange(0, 10000)] [int] $GracefulTimeoutMilliseconds = 2000,
        [ValidateRange(500, 30000)] [int] $ForceTimeoutMilliseconds = 5000
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $observed = New-Object 'Collections.Generic.HashSet[int]'
    $errors = New-Object Collections.Generic.List[string]
    $finalSnapshotVerified = $false
    [void]$observed.Add($RootProcessId)

    try {
        foreach ($entry in @(Get-GuestProcessTree -RootProcessId $RootProcessId)) {
            [void]$observed.Add([int]$entry.ProcessId)
        }
    }
    catch {
        $errors.Add("Initial process-tree enumeration failed: $($_.Exception.Message)")
    }

    $rootProcess = Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue
    if ($rootProcess -and -not $rootProcess.HasExited -and $GracefulTimeoutMilliseconds -gt 0) {
        try {
            if ($rootProcess.CloseMainWindow()) {
                [void]$rootProcess.WaitForExit($GracefulTimeoutMilliseconds)
            }
        }
        catch {
            $errors.Add("Graceful process close failed: $($_.Exception.Message)")
        }
    }

    # taskkill handles the normal live-parent case efficiently. The explicit
    # descendant walk below also handles wrappers whose root process already
    # exited while detached Electron, Node, or helper children stayed alive.
    if (Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue) {
        try {
            $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $taskKillPath -PathType Leaf) {
                $null = & $taskKillPath /PID $RootProcessId /T /F 2>&1
            }
        }
        catch {
            $errors.Add("taskkill process-tree termination failed: $($_.Exception.Message)")
        }
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($ForceTimeoutMilliseconds)
    do {
        $tree = @()
        try {
            $tree = @(Get-GuestProcessTree -RootProcessId $RootProcessId)
            $finalSnapshotVerified = $true
            foreach ($entry in $tree) {
                [void]$observed.Add([int]$entry.ProcessId)
            }
        }
        catch {
            $finalSnapshotVerified = $false
            $errors.Add("Process-tree verification failed: $($_.Exception.Message)")
        }

        foreach ($entry in @($tree | Sort-Object @{ Expression = { [int]$_.Depth }; Descending = $true })) {
            Stop-Process -Id ([int]$entry.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        foreach ($processId in @($observed)) {
            Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue
        }

        Start-Sleep -Milliseconds 200
        try {
            $remainingTree = @(Get-GuestProcessTree -RootProcessId $RootProcessId)
            $finalSnapshotVerified = $true
        }
        catch {
            $remainingTree = @()
            $finalSnapshotVerified = $false
            $errors.Add("Final process-tree verification failed: $($_.Exception.Message)")
        }
        $remainingObserved = @($observed | Where-Object { Get-Process -Id ([int]$_) -ErrorAction SilentlyContinue })
        if ($finalSnapshotVerified -and $remainingTree.Count -eq 0 -and $remainingObserved.Count -eq 0) {
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    $survivors = New-Object 'Collections.Generic.HashSet[int]'
    if ($finalSnapshotVerified) {
        foreach ($entry in @($remainingTree)) { [void]$survivors.Add([int]$entry.ProcessId) }
        foreach ($processId in @($remainingObserved)) { [void]$survivors.Add([int]$processId) }
    }
    $watch.Stop()

    [pscustomobject][ordered]@{
        Attempted = $true
        RootProcessId = $RootProcessId
        Success = [bool]$finalSnapshotVerified -and $survivors.Count -eq 0
        VerificationSucceeded = [bool]$finalSnapshotVerified
        ObservedProcessIds = @($observed | Sort-Object)
        SurvivorProcessIds = @($survivors | Sort-Object)
        Errors = $errors.ToArray()
        ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    }
}

function Resolve-GuestOutputPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Value,
        [Parameter(Mandatory = $true)] [string] $JobOutputPath,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    $expanded = $Value.Replace('{OUTDIR}', $JobOutputPath)
    $resolved = [IO.Path]::GetFullPath($expanded)
    $outputPrefix = [IO.Path]::GetFullPath($JobOutputPath).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must resolve inside the request-specific output directory."
    }
    $resolved
}

function Wait-GuestResultFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(100, 7200000)] [int64] $TimeoutMilliseconds = 300000
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (Get-Command -Name Invoke-GuestLiveEvidenceHeartbeat -CommandType Function -ErrorAction SilentlyContinue) {
            Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc $deadline
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and -not $item.PSIsContainer -and $item.Length -gt 0) {
            $watch.Stop()
            return [pscustomobject][ordered]@{
                Found = $true
                Path = $Path
                Length = [long]$item.Length
                ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
            }
        }
        $remainingMilliseconds = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMilliseconds -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(100, $remainingMilliseconds))
    } while ([DateTime]::UtcNow -lt $deadline)
    $watch.Stop()
    [pscustomobject][ordered]@{
        Found = $false
        Path = $Path
        Length = 0
        ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
    }
}

function Resolve-JsonPointerValue {
    param(
        [AllowNull()] $Document,
        [AllowEmptyString()] [string] $Pointer
    )

    if ($Pointer.Length -eq 0) {
        return [pscustomobject][ordered]@{ Found = $true; Value = $Document }
    }
    if (-not $Pointer.StartsWith('/', [StringComparison]::Ordinal) -or [regex]::IsMatch($Pointer, '~(?![01])')) {
        return [pscustomobject][ordered]@{ Found = $false; Value = $null }
    }

    $current = $Document
    foreach ($encodedToken in $Pointer.Substring(1).Split('/')) {
        $token = $encodedToken.Replace('~1', '/').Replace('~0', '~')
        if ($current -is [Array] -or $current -is [Collections.IList]) {
            if ($token -notmatch '^(0|[1-9][0-9]*)$') {
                return [pscustomobject][ordered]@{ Found = $false; Value = $null }
            }
            $index = [int64]$token
            if ($index -lt 0 -or $index -ge $current.Count) {
                return [pscustomobject][ordered]@{ Found = $false; Value = $null }
            }
            $current = $current[[int]$index]
            continue
        }
        if ($current -is [Collections.IDictionary]) {
            $matchingKey = @($current.Keys | Where-Object { [string]$_ -ceq $token }) | Select-Object -First 1
            if ($null -eq $matchingKey) {
                return [pscustomobject][ordered]@{ Found = $false; Value = $null }
            }
            $current = $current[$matchingKey]
            continue
        }
        if ($null -eq $current) {
            return [pscustomobject][ordered]@{ Found = $false; Value = $null }
        }
        $property = @($current.PSObject.Properties | Where-Object { $_.Name -ceq $token }) | Select-Object -First 1
        if (-not $property) {
            return [pscustomobject][ordered]@{ Found = $false; Value = $null }
        }
        $current = $property.Value
    }
    [pscustomobject][ordered]@{ Found = $true; Value = $current }
}

function Test-IsJsonNumber {
    param([AllowNull()] $Value)
    $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
}

function Test-JsonValuesEqual {
    param(
        [AllowNull()] $Actual,
        [AllowNull()] $Expected
    )

    if ($null -eq $Actual -or $null -eq $Expected) {
        return $null -eq $Actual -and $null -eq $Expected
    }
    if ((Test-IsJsonNumber -Value $Actual) -and (Test-IsJsonNumber -Value $Expected)) {
        return [decimal]$Actual -eq [decimal]$Expected
    }
    if ($Actual -is [string] -or $Expected -is [string] -or $Actual -is [bool] -or $Expected -is [bool]) {
        return $Actual.GetType() -eq $Expected.GetType() -and [object]::Equals($Actual, $Expected)
    }
    $actualIsList = $Actual -is [Array] -or $Actual -is [Collections.IList]
    $expectedIsList = $Expected -is [Array] -or $Expected -is [Collections.IList]
    if ($actualIsList -or $expectedIsList) {
        if (-not $actualIsList -or -not $expectedIsList -or $Actual.Count -ne $Expected.Count) { return $false }
        for ($index = 0; $index -lt $Actual.Count; $index++) {
            if (-not (Test-JsonValuesEqual -Actual $Actual[$index] -Expected $Expected[$index])) { return $false }
        }
        return $true
    }

    $actualProperties = @($Actual.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property'))
    $expectedProperties = @($Expected.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property'))
    if ($actualProperties.Count -ne $expectedProperties.Count) { return $false }
    foreach ($expectedProperty in $expectedProperties) {
        $actualProperty = @($actualProperties | Where-Object { $_.Name -ceq $expectedProperty.Name }) | Select-Object -First 1
        if (-not $actualProperty -or -not (Test-JsonValuesEqual -Actual $actualProperty.Value -Expected $expectedProperty.Value)) { return $false }
    }
    $true
}

function Test-GuestResultAssertion {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [AllowEmptyString()] [string] $JsonPointer,
        [Parameter(Mandatory = $true)] [string] $ExpectedJson
    )

    try {
        $document = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject][ordered]@{
            Passed = $false
            FailureKind = 'ResultJsonInvalid'
            Message = "Result file is not valid JSON: $($_.Exception.Message)"
            JsonPointer = $JsonPointer
            ExpectedJson = $ExpectedJson
            ActualJson = $null
        }
    }
    $resolved = Resolve-JsonPointerValue -Document $document -Pointer $JsonPointer
    if (-not $resolved.Found) {
        return [pscustomobject][ordered]@{
            Passed = $false
            FailureKind = 'JsonPointerMissing'
            Message = "JSON Pointer '$JsonPointer' was not found in the application result."
            JsonPointer = $JsonPointer
            ExpectedJson = $ExpectedJson
            ActualJson = $null
        }
    }
    try {
        $expected = ('{"value":' + $ExpectedJson + '}') | ConvertFrom-Json -ErrorAction Stop
        $expectedValue = $expected.value
    }
    catch {
        throw "The broker supplied invalid assertion JSON: $($_.Exception.Message)"
    }
    $actualJson = $resolved.Value | ConvertTo-Json -Depth 20 -Compress
    $passed = Test-JsonValuesEqual -Actual $resolved.Value -Expected $expectedValue
    [pscustomobject][ordered]@{
        Passed = [bool]$passed
        FailureKind = if ($passed) { $null } else { 'TestAssertion' }
        Message = if ($passed) { $null } else { "JSON assertion failed at '$JsonPointer': expected $ExpectedJson, actual $actualJson." }
        JsonPointer = $JsonPointer
        ExpectedJson = $ExpectedJson
        ActualJson = $actualJson
    }
}

function Test-ExpectedGuestPowerOffJob {
    param([AllowNull()] $Job)

    if ($null -eq $Job) { return $false }
    $property = @($Job.PSObject.Properties | Where-Object { $_.Name -ceq 'expectGuestPowerOff' }) | Select-Object -First 1
    $null -ne $property -and $property.Value -is [bool] -and [bool]$property.Value
}

function Get-GuestResultFileEvidence {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $isFile = $null -ne $item -and -not $item.PSIsContainer
    $length = if ($isFile) { [long]$item.Length } else { 0L }
    $hasContent = $isFile -and $length -gt 0
    [pscustomobject][ordered]@{
        Path = $Path
        Exists = [bool]$isFile
        HasContent = [bool]$hasContent
        Length = $length
        LastWriteUtc = if ($isFile) { $item.LastWriteTimeUtc.ToString('o') } else { $null }
        Sha256 = if ($hasContent) { [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
        InspectedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-GuestBootTimeUtc {
    $bootValue = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    $bootTime = if ($bootValue -is [DateTime]) {
        [DateTime]$bootValue
    }
    else {
        [Management.ManagementDateTimeConverter]::ToDateTime([string]$bootValue)
    }
    $bootTime.ToUniversalTime()
}

function Get-CachedGuestBootTimeUtc {
    if ([string]::IsNullOrWhiteSpace([string]$script:guestBootTimeUtc)) {
        $script:guestBootTimeUtc = (Get-GuestBootTimeUtc).ToString('o')
    }
    [string]$script:guestBootTimeUtc
}

function ConvertTo-GuestUtcInstant {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Get-ExpectedGuestPowerOffBootEvidence {
    param([AllowNull()] $Lease)

    $currentBootUtc = (Get-GuestBootTimeUtc).ToUniversalTime()
    $source = $null
    $originalText = $null
    $originalValue = $null
    if ($Lease -and $Lease.PSObject.Properties.Name -contains 'GuestBootTimeUtc') {
        $source = 'Lease'
        $originalValue = $Lease.GuestBootTimeUtc
    }

    $originalBootOffset = [DateTimeOffset]::MinValue
    if ($originalValue -is [DateTime]) {
        $originalBootUtc = ([DateTime]$originalValue).ToUniversalTime()
        $originalText = $originalBootUtc.ToString('o')
        $parsed = $true
    }
    elseif ($originalValue -is [DateTimeOffset]) {
        $originalBootUtc = ([DateTimeOffset]$originalValue).UtcDateTime
        $originalText = $originalBootUtc.ToString('o')
        $parsed = $true
    }
    else {
        $originalText = [string]$originalValue
        $parsed = -not [string]::IsNullOrWhiteSpace($originalText) -and [DateTimeOffset]::TryParse(
            $originalText,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces,
            [ref]$originalBootOffset
        )
        $originalBootUtc = if ($parsed) { $originalBootOffset.UtcDateTime } else { [DateTime]::MinValue }
    }
    $laterBoot = $parsed -and $currentBootUtc -gt $originalBootUtc

    [pscustomobject][ordered]@{
        OriginalBootTimeUtc = if ($parsed) { $originalBootUtc.ToString('o') } else { $originalText }
        CurrentBootTimeUtc = $currentBootUtc.ToString('o')
        OriginalBootTimeSource = $source
        OriginalBootTimeParsed = [bool]$parsed
        ControlledRebootProven = [bool]$laterBoot
        SameBoot = [bool]$parsed -and $currentBootUtc -eq $originalBootUtc
    }
}

function Get-RedactedGuestActionSummary {
    param(
        [AllowEmptyCollection()] [object[]] $Actions,
        [ValidateRange(1, 100)] [int] $MaximumItems = 32
    )

    $allActions = @($Actions)
    $items = New-Object Collections.Generic.List[object]
    for ($index = 0; $index -lt [Math]::Min($allActions.Count, $MaximumItems); $index++) {
        $items.Add([pscustomobject][ordered]@{
            Index = $index + 1
            Type = [string]$allActions[$index].type
        })
    }
    [pscustomobject][ordered]@{
        Count = $allActions.Count
        Items = $items.ToArray()
        Truncated = $allActions.Count -gt $MaximumItems
    }
}

function Complete-ExpectedGuestPowerOffJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Job,
        [Parameter(Mandatory = $true)] [string] $JobFile,
        [Parameter(Mandatory = $true)] [ValidateSet('Processing', 'Completed')] [string] $RecoverySource,
        [string] $OutboxRoot = $outboxPath
    )

    if (-not (Test-ExpectedGuestPowerOffJob -Job $Job)) {
        throw 'Expected guest power-off recovery requires an exact Boolean expectGuestPowerOff=true contract.'
    }

    $jobId = [string]$Job.id
    if ($jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
        throw "Invalid job id: $jobId"
    }
    $jobOutputPath = Join-Path $OutboxRoot $jobId
    New-Item -ItemType Directory -Force -Path $jobOutputPath | Out-Null
    $resultFile = Join-Path $jobOutputPath 'result.json'
    $leasePath = Join-Path $jobOutputPath 'lease.json'
    $agentErrorPath = Join-Path $jobOutputPath 'agent-error.json'

    $recoveryStartedUtc = [DateTime]::UtcNow
    $recoveryCompletedUtc = $null
    $harnessSucceeded = $true
    $failureKind = $null
    $errorMessage = $null
    $testEvaluated = $false
    $testPassed = $null
    $testFailureKind = $null
    $testFailureMessage = $null
    $testAssertion = $null
    $assertionPath = $null
    $markerEvidence = $null
    $lease = $null
    $leaseReadError = $null
    $existingResult = $null
    $existingResultReadError = $null
    $existingTerminalResultValidated = $false
    $bootEvidence = $null
    $bootEvidenceError = $null

    if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
        try { $lease = Get-Content -Raw -LiteralPath $leasePath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $leaseReadError = $_.Exception.Message }
    }
    if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
        try { $existingResult = Get-Content -Raw -LiteralPath $resultFile -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $existingResultReadError = $_.Exception.Message }
    }
    try { $bootEvidence = Get-ExpectedGuestPowerOffBootEvidence -Lease $lease }
    catch { $bootEvidenceError = $_.Exception.Message }

    if ($bootEvidence -and $bootEvidence.SameBoot) {
        return [pscustomobject][ordered]@{
            JobId = $jobId
            Completed = $false
            ExistingResult = $null -ne $existingResult
            Deferred = $true
            DeferReason = 'SameBoot'
            ResultFile = $resultFile
            BootEvidence = $bootEvidence
        }
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($bootEvidenceError)) {
            throw "Could not read the guest boot epoch: $bootEvidenceError"
        }
        if (-not $bootEvidence -or -not $bootEvidence.OriginalBootTimeParsed) {
            throw 'Expected guest power-off recovery has no readable application boot epoch.'
        }
        if (-not $bootEvidence.ControlledRebootProven) {
            throw 'Expected guest power-off recovery could not prove a later guest boot epoch.'
        }
        if (-not [string]::IsNullOrWhiteSpace($existingResultReadError)) {
            throw "Could not read the existing guest result envelope: $existingResultReadError"
        }

        $hasResultFile = $Job.PSObject.Properties.Name -contains 'assertResultFile'
        if (-not $hasResultFile -or [string]::IsNullOrWhiteSpace([string]$Job.assertResultFile)) {
            throw 'Expected guest power-off recovery requires assertResultFile.'
        }

        $hasAssertionPointer = $Job.PSObject.Properties.Name -contains 'assertResultJsonPointer'
        $hasAssertionExpected = $Job.PSObject.Properties.Name -contains 'assertResultEqualsJson'
        if ($hasAssertionPointer -ne $hasAssertionExpected) {
            throw 'assertResultJsonPointer and assertResultEqualsJson must be supplied together.'
        }

        $assertionPath = Resolve-GuestOutputPath -Value ([string]$Job.assertResultFile) -JobOutputPath $jobOutputPath -Context 'assertResultFile'
        foreach ($reservedPath in @($resultFile, $leasePath, (Join-Path $jobOutputPath 'agent-error.json'))) {
            if ([string]::Equals($assertionPath, $reservedPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "assertResultFile cannot use the reserved guest protocol file '$([IO.Path]::GetFileName($reservedPath))'."
            }
        }
        $markerEvidence = Get-GuestResultFileEvidence -Path $assertionPath
        $markerPredatesRecoveryBoot = $false
        if ($markerEvidence.Exists -and $bootEvidence -and $bootEvidence.ControlledRebootProven) {
            try {
                $markerLastWriteUtc = ConvertTo-GuestUtcInstant -Value $markerEvidence.LastWriteUtc
                $recoveryBootUtc = ConvertTo-GuestUtcInstant -Value $bootEvidence.CurrentBootTimeUtc
                $markerPredatesRecoveryBoot = $markerLastWriteUtc -and $recoveryBootUtc -and $markerLastWriteUtc -lt $recoveryBootUtc
            }
            catch { $markerPredatesRecoveryBoot = $false }
        }
        $markerEvidence | Add-Member -NotePropertyName PredatesRecoveryBoot -NotePropertyValue ([bool]$markerPredatesRecoveryBoot) -Force
        if ($existingResult) {
            $existingJobIdProperty = $existingResult.PSObject.Properties['JobId']
            $existingSuccessProperty = $existingResult.PSObject.Properties['Success']
            $existingHarnessProperty = $existingResult.PSObject.Properties['HarnessSucceeded']
            $existingTestEvaluatedProperty = $existingResult.PSObject.Properties['TestEvaluated']
            $existingTestPassedProperty = $existingResult.PSObject.Properties['TestPassed']
            $existingActionsProperty = $existingResult.PSObject.Properties['Actions']
            if (-not $existingJobIdProperty -or -not [string]::Equals([string]$existingResult.JobId, $jobId, [StringComparison]::Ordinal) -or
                -not $existingSuccessProperty -or $existingResult.Success -isnot [bool] -or
                -not $existingHarnessProperty -or $existingResult.HarnessSucceeded -isnot [bool] -or
                [bool]$existingResult.Success -ne [bool]$existingResult.HarnessSucceeded -or
                -not $existingTestEvaluatedProperty -or $existingResult.TestEvaluated -isnot [bool] -or
                -not $existingTestPassedProperty -or -not $existingActionsProperty) {
                throw 'The existing result.json is not a valid terminal guest result envelope for this job.'
            }
            if (([bool]$existingResult.TestEvaluated -and $existingResult.TestPassed -isnot [bool]) -or
                (-not [bool]$existingResult.TestEvaluated -and $null -ne $existingResult.TestPassed)) {
                throw 'The existing terminal guest result has an invalid TestPassed value for its TestEvaluated state.'
            }
            $existingTerminalResultValidated = $true
            $harnessSucceeded = [bool]$existingResult.HarnessSucceeded
            $failureKind = [string]$existingResult.FailureKind
            $errorMessage = [string]$existingResult.Error
            $testEvaluated = [bool]$existingResult.TestEvaluated
            $testPassed = if ($testEvaluated) { [bool]$existingResult.TestPassed } else { $null }
            $testFailureKind = [string]$existingResult.TestFailureKind
            $testFailureMessage = [string]$existingResult.TestFailureMessage
            $testAssertion = $existingResult.TestAssertion
            $recoveredMarkerPassed = $true
            $recoveredMarkerFailureKind = $null
            $recoveredMarkerFailureMessage = $null
            $recoveredAssertion = $null
            if (-not $markerEvidence.Exists) {
                $recoveredMarkerPassed = $false
                $recoveredMarkerFailureKind = 'ResultFileMissing'
                $recoveredMarkerFailureMessage = "Expected application result file was not preserved through guest power-off: $assertionPath"
            }
            elseif (-not $markerEvidence.HasContent) {
                $recoveredMarkerPassed = $false
                $recoveredMarkerFailureKind = 'ResultFileEmpty'
                $recoveredMarkerFailureMessage = "Expected application result file was empty after guest power-off: $assertionPath"
            }
            elseif (-not $markerPredatesRecoveryBoot) {
                $recoveredMarkerPassed = $false
                $recoveredMarkerFailureKind = 'ResultFileNotPrePowerOff'
                $recoveredMarkerFailureMessage = "Expected application result file was not proven to predate the controlled recovery boot: $assertionPath"
            }
            elseif ($hasAssertionPointer) {
                $recoveredAssertion = Test-GuestResultAssertion -Path $assertionPath -JsonPointer ([string]$Job.assertResultJsonPointer) -ExpectedJson ([string]$Job.assertResultEqualsJson)
                $recoveredMarkerPassed = [bool]$recoveredAssertion.Passed
                if (-not $recoveredMarkerPassed) {
                    $recoveredMarkerFailureKind = [string]$recoveredAssertion.FailureKind
                    $recoveredMarkerFailureMessage = [string]$recoveredAssertion.Message
                }
            }
            if (-not $recoveredMarkerPassed) {
                $testEvaluated = $true
                $testPassed = $false
                $testFailureKind = $recoveredMarkerFailureKind
                $testFailureMessage = $recoveredMarkerFailureMessage
                $testAssertion = $recoveredAssertion
            }
            elseif (-not $testEvaluated) {
                $testEvaluated = $true
                $testPassed = $true
                $testFailureKind = $null
                $testFailureMessage = $null
                $testAssertion = $recoveredAssertion
            }
            elseif ($hasAssertionPointer) {
                $testAssertion = $recoveredAssertion
            }
        }
        else {
            $testEvaluated = $true
            if (-not $markerEvidence.Exists) {
                $testPassed = $false
                $testFailureKind = 'ResultFileMissing'
                $testFailureMessage = "Expected application result file was not created before guest power-off: $assertionPath"
            }
            elseif (-not $markerEvidence.HasContent) {
                $testPassed = $false
                $testFailureKind = 'ResultFileEmpty'
                $testFailureMessage = "Expected application result file was empty after guest power-off: $assertionPath"
            }
            elseif (-not $markerPredatesRecoveryBoot) {
                $testPassed = $false
                $testFailureKind = 'ResultFileNotPrePowerOff'
                $testFailureMessage = "Expected application result file was not proven to predate the controlled recovery boot: $assertionPath"
            }
            elseif ($hasAssertionPointer) {
                $testAssertion = Test-GuestResultAssertion -Path $assertionPath -JsonPointer ([string]$Job.assertResultJsonPointer) -ExpectedJson ([string]$Job.assertResultEqualsJson)
                $testPassed = [bool]$testAssertion.Passed
                if (-not $testPassed) {
                    $testFailureKind = [string]$testAssertion.FailureKind
                    $testFailureMessage = [string]$testAssertion.Message
                }
            }
            else {
                $testPassed = $true
            }
        }
    }
    catch {
        $harnessSucceeded = $false
        $failureKind = 'ExpectedGuestPowerOffRecoveryContract'
        $errorMessage = $_.Exception.Message
        $testEvaluated = $false
        $testPassed = $null
        $testFailureKind = $null
        $testFailureMessage = $null
    }

    $hostInputDefinitions = @()
    if ($Job.PSObject.Properties.Name -contains 'hostInputs') {
        $hostInputDefinitions = @($Job.hostInputs)
    }
    try {
        $hostInputCleanup = Dismount-GuestHostInputs -MountedInputs $hostInputDefinitions
    }
    catch {
        $hostInputCleanup = [pscustomobject][ordered]@{
            Attempted = $hostInputDefinitions.Count -gt 0
            Success = $false
            Errors = @($_.Exception.Message)
            UnmountedCount = 0
        }
    }
    if (-not $hostInputCleanup.Success) {
        $cleanupError = 'Guest read-only host-input cleanup failed after expected power-off: ' + (@($hostInputCleanup.Errors) -join ' | ')
        $harnessSucceeded = $false
        $failureKind = 'HostInputCleanup'
        $errorMessage = if ([string]::IsNullOrWhiteSpace($errorMessage)) { $cleanupError } else { "$errorMessage $cleanupError" }
    }

    $existingRecoveryVerified = $false
    if ($existingTerminalResultValidated -and $hostInputCleanup.Success -and $bootEvidence -and $bootEvidence.ControlledRebootProven) {
        try {
            $existingRecovery = $existingResult.ExpectedGuestPowerOffRecovery
            $existingRecoveryBoot = if ($existingRecovery) { $existingRecovery.BootEvidence } else { $null }
            $currentBootInstant = ConvertTo-GuestUtcInstant -Value $bootEvidence.CurrentBootTimeUtc
            $resultRecoveryBootInstant = if ($existingRecoveryBoot) { ConvertTo-GuestUtcInstant -Value $existingRecoveryBoot.CurrentBootTimeUtc } else { $null }
            $leaseRecoveryBootInstant = ConvertTo-GuestUtcInstant -Value $lease.RecoveryBootTimeUtc
            $existingResultHash = (Get-FileHash -LiteralPath $resultFile -Algorithm SHA256 -ErrorAction Stop).Hash
            $markerHashMatches = [string]::Equals([string]$lease.RecoveryMarkerSha256, [string]$markerEvidence.Sha256, [StringComparison]::OrdinalIgnoreCase)
            $resultMarkerHashMatches = [string]::Equals([string]$existingResult.ResultFileEvidence.Sha256, [string]$markerEvidence.Sha256, [StringComparison]::OrdinalIgnoreCase)
            $testOutcomeMatches = $existingResult.TestEvaluated -is [bool] -and [bool]$existingResult.TestEvaluated -eq [bool]$testEvaluated -and
                (-not $testEvaluated -or ($existingResult.TestPassed -is [bool] -and [bool]$existingResult.TestPassed -eq [bool]$testPassed)) -and
                [string]::Equals([string]$existingResult.TestFailureKind, [string]$testFailureKind, [StringComparison]::Ordinal)
            $existingRecoveryVerified =
                $existingResult.ExpectGuestPowerOff -is [bool] -and [bool]$existingResult.ExpectGuestPowerOff -and
                [string]::Equals([string]$existingResult.GuestPowerOffEvidenceRecoveryMode, 'ControlledReboot', [StringComparison]::Ordinal) -and
                $existingResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff -is [bool] -and -not [bool]$existingResult.ApplicationRelaunchedByHarnessAfterGuestPowerOff -and
                $existingResult.HarnessSucceeded -is [bool] -and [bool]$existingResult.HarnessSucceeded -eq [bool]$harnessSucceeded -and
                $testOutcomeMatches -and
                $existingRecovery -and [string]::Equals([string]$existingRecovery.Mode, 'ControlledReboot', [StringComparison]::Ordinal) -and
                $existingRecovery.ApplicationRelaunchedByHarness -is [bool] -and -not [bool]$existingRecovery.ApplicationRelaunchedByHarness -and
                $existingRecoveryBoot -and $existingRecoveryBoot.ControlledRebootProven -is [bool] -and [bool]$existingRecoveryBoot.ControlledRebootProven -and
                [string]::Equals([string]$existingRecoveryBoot.OriginalBootTimeSource, 'Lease', [StringComparison]::Ordinal) -and
                $currentBootInstant -and $resultRecoveryBootInstant -and $leaseRecoveryBootInstant -and
                $resultRecoveryBootInstant -eq $currentBootInstant -and $leaseRecoveryBootInstant -eq $currentBootInstant -and
                $existingResult.ProcessCleanup.SatisfiedByGuestPowerCycle -is [bool] -and [bool]$existingResult.ProcessCleanup.SatisfiedByGuestPowerCycle -and
                $existingResult.HostInputCleanup.Success -is [bool] -and
                [string]::Equals([string]$lease.JobId, $jobId, [StringComparison]::Ordinal) -and
                $lease.ApplicationRelaunchedByHarnessAfterGuestPowerOff -is [bool] -and -not [bool]$lease.ApplicationRelaunchedByHarnessAfterGuestPowerOff -and
                [string]::Equals([string]$lease.RecoveryResultSha256, [string]$existingResultHash, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$lease.RecoveryMarkerPath, [string]$assertionPath, [StringComparison]::OrdinalIgnoreCase) -and
                $lease.RecoveryMarkerExists -is [bool] -and [bool]$lease.RecoveryMarkerExists -eq [bool]$markerEvidence.Exists -and
                [int64]$lease.RecoveryMarkerLength -eq [int64]$markerEvidence.Length -and $markerHashMatches -and
                $existingResult.ResultFileEvidence.Exists -is [bool] -and [bool]$existingResult.ResultFileEvidence.Exists -eq [bool]$markerEvidence.Exists -and
                $existingResult.ResultFileEvidence.PredatesRecoveryBoot -is [bool] -and [bool]$existingResult.ResultFileEvidence.PredatesRecoveryBoot -eq [bool]$markerEvidence.PredatesRecoveryBoot -and
                [int64]$existingResult.ResultFileEvidence.Length -eq [int64]$markerEvidence.Length -and $resultMarkerHashMatches
        }
        catch {
            $existingRecoveryVerified = $false
        }
    }
    if ($existingRecoveryVerified) {
        # A transient recovery attempt may have left agent-error.json behind.
        # Remove it before the already-validated success becomes observable so
        # the host cannot mistake stale error evidence for the final outcome.
        Remove-Item -LiteralPath $agentErrorPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject][ordered]@{
            JobId = $jobId
            Completed = $false
            ExistingResult = $true
            Deferred = $false
            AlreadyRecovered = $true
            ResultFile = $resultFile
            BootEvidence = $bootEvidence
            HostInputCleanup = $hostInputCleanup
        }
    }

    $recoveryCompletedUtc = [DateTime]::UtcNow
    $processId = if ($lease -and $lease.PSObject.Properties.Name -contains 'ProcessId' -and [int64]$lease.ProcessId -gt 0) {
        [int]$lease.ProcessId
    }
    else {
        $null
    }
    $startedUtc = if ($lease -and $lease.PSObject.Properties.Name -contains 'StartedUtc' -and -not [string]::IsNullOrWhiteSpace([string]$lease.StartedUtc)) {
        [string]$lease.StartedUtc
    }
    else {
        $recoveryStartedUtc.ToString('o')
    }
    $processCleanup = [pscustomobject][ordered]@{
        Attempted = $false
        RootProcessId = $processId
        Success = $true
        VerificationSucceeded = $true
        ObservedProcessIds = @()
        SurvivorProcessIds = @()
        Errors = @()
        ElapsedMilliseconds = 0
        SatisfiedByGuestPowerCycle = [bool]($bootEvidence -and $bootEvidence.ControlledRebootProven)
        RecoveryMode = if ($bootEvidence -and $bootEvidence.ControlledRebootProven) { 'ControlledReboot' } else { $null }
    }
    $redactedActions = Get-RedactedGuestActionSummary -Actions @($Job.actions)
    $recovery = [pscustomobject][ordered]@{
        Mode = if ($bootEvidence -and $bootEvidence.ControlledRebootProven) { 'ControlledReboot' } else { $null }
        Source = $RecoverySource
        JobFile = $JobFile
        StartedUtc = $recoveryStartedUtc.ToString('o')
        CompletedUtc = $recoveryCompletedUtc.ToString('o')
        ApplicationRelaunchedByHarness = $false
        OutputDirectoryPreserved = $true
        ExistingResultAnnotated = [bool]$existingTerminalResultValidated
        Marker = $markerEvidence
        LeaseMetadataAvailable = $null -ne $lease
        LeaseReadError = $leaseReadError
        BootEvidence = $bootEvidence
        HostInputCleanup = $hostInputCleanup
        RequestedActions = $redactedActions
    }
    $recoveryAction = [ordered]@{
        Type = 'expected_guest_power_off_recovery'
        Index = 0
        StartedUtc = $recoveryStartedUtc.ToString('o')
        CompletedUtc = $recoveryCompletedUtc.ToString('o')
        Success = [bool]$harnessSucceeded
        TestPassed = if ($testEvaluated) { [bool]$testPassed } else { $null }
        Details = $recovery
        Error = $errorMessage
    }

    $sanitizedHostInputs = @($hostInputDefinitions | ForEach-Object {
        [ordered]@{
            Name = [string]$_.Name
            DriveLetter = [string]$_.DriveLetter
            GuestSubPath = [string]$_.GuestSubPath
        }
    })
    if ($existingTerminalResultValidated) {
        $resultEnvelope = [ordered]@{}
        foreach ($property in $existingResult.PSObject.Properties) {
            $resultEnvelope[$property.Name] = $property.Value
        }
        $resultEnvelope['TestEvaluated'] = [bool]$testEvaluated
        $resultEnvelope['TestPassed'] = if ($testEvaluated) { [bool]$testPassed } else { $null }
        $resultEnvelope['TestFailureKind'] = if ($testEvaluated -and -not $testPassed) { $testFailureKind } else { $null }
        $resultEnvelope['TestFailureMessage'] = if ($testEvaluated -and -not $testPassed) { $testFailureMessage } else { $null }
        $resultEnvelope['TestAssertion'] = $testAssertion
        $resultEnvelope['OverallSucceeded'] = [bool]$harnessSucceeded -and $testEvaluated -and [bool]$testPassed
        if (-not $harnessSucceeded) {
            $resultEnvelope['Success'] = $false
            $resultEnvelope['HarnessSucceeded'] = $false
            $resultEnvelope['OverallSucceeded'] = $false
            $resultEnvelope['FailureKind'] = $failureKind
            $resultEnvelope['Error'] = $errorMessage
        }
        $resultEnvelope['RecoveryCompletedUtc'] = $recoveryCompletedUtc.ToString('o')
        $resultEnvelope['ExpectGuestPowerOff'] = $true
        $resultEnvelope['GuestPowerOffEvidenceRecoveryMode'] = if ($bootEvidence -and $bootEvidence.ControlledRebootProven) { 'ControlledReboot' } else { $null }
        $resultEnvelope['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = $false
        $resultEnvelope['ResultFileEvidence'] = $markerEvidence
        if ($resultEnvelope.Contains('GuestBootTimeUtc')) {
            $resultEnvelope['ApplicationGuestBootTimeUtc'] = $resultEnvelope['GuestBootTimeUtc']
        }
        $resultEnvelope['GuestBootTimeUtc'] = if ($bootEvidence) { [string]$bootEvidence.CurrentBootTimeUtc } else { $null }
        if ($resultEnvelope.Contains('ProcessCleanup')) {
            $resultEnvelope['PrePowerOffProcessCleanup'] = $resultEnvelope['ProcessCleanup']
        }
        $resultEnvelope['ProcessCleanup'] = $processCleanup
        if ($resultEnvelope.Contains('HostInputCleanup')) {
            $resultEnvelope['PrePowerOffHostInputCleanup'] = $resultEnvelope['HostInputCleanup']
        }
        $resultEnvelope['HostInputCleanup'] = $hostInputCleanup
        $resultEnvelope['ExpectedGuestPowerOffRecovery'] = $recovery
    }
    else {
        $resultEnvelope = [ordered]@{
            JobId = $jobId
            Success = [bool]$harnessSucceeded
            HarnessSucceeded = [bool]$harnessSucceeded
            TestEvaluated = [bool]$testEvaluated
            TestPassed = if ($testEvaluated) { [bool]$testPassed } else { $null }
            OverallSucceeded = [bool]$harnessSucceeded -and $testEvaluated -and [bool]$testPassed
            FailureKind = if ($harnessSucceeded) { $null } else { $failureKind }
            TestFailureKind = if ($testEvaluated -and -not $testPassed) { $testFailureKind } else { $null }
            TestFailureMessage = if ($testEvaluated -and -not $testPassed) { $testFailureMessage } else { $null }
            TestAssertion = $testAssertion
            Error = $errorMessage
            StartedUtc = $startedUtc
            CompletedUtc = $recoveryCompletedUtc.ToString('o')
            RecoveryCompletedUtc = $recoveryCompletedUtc.ToString('o')
            AgentProcessId = $PID
            AgentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
            UserInteractive = [Environment]::UserInteractive
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            ExpectGuestPowerOff = $true
            GuestPowerOffEvidenceRecoveryMode = if ($bootEvidence -and $bootEvidence.ControlledRebootProven) { 'ControlledReboot' } else { $null }
            ApplicationRelaunchedByHarnessAfterGuestPowerOff = $false
            ResultFileEvidence = $markerEvidence
            GuestBootTimeUtc = if ($bootEvidence) { [string]$bootEvidence.CurrentBootTimeUtc } else { $null }
            ProcessCleanup = $processCleanup
            HostInputs = $sanitizedHostInputs
            HostInputCleanup = $hostInputCleanup
            Actions = @($recoveryAction)
            ExpectedGuestPowerOffRecovery = $recovery
        }
    }

    if ($harnessSucceeded) {
        Remove-Item -LiteralPath $agentErrorPath -Force -ErrorAction SilentlyContinue
    }
    Write-JsonAtomic -Path $resultFile -Value $resultEnvelope
    if ($lease -and $bootEvidence -and $bootEvidence.ControlledRebootProven) {
        $recoveryResultHash = (Get-FileHash -LiteralPath $resultFile -Algorithm SHA256 -ErrorAction Stop).Hash
        $recoveryLease = [ordered]@{}
        foreach ($property in $lease.PSObject.Properties) {
            $recoveryLease[$property.Name] = $property.Value
        }
        $recoveryLease['RecoveryCompletedUtc'] = $recoveryCompletedUtc.ToString('o')
        $recoveryLease['RecoveryBootTimeUtc'] = [string]$bootEvidence.CurrentBootTimeUtc
        $recoveryLease['RecoveryMarkerPath'] = [string]$assertionPath
        $recoveryLease['RecoveryMarkerExists'] = [bool]$markerEvidence.Exists
        $recoveryLease['RecoveryMarkerLength'] = [int64]$markerEvidence.Length
        $recoveryLease['RecoveryMarkerSha256'] = [string]$markerEvidence.Sha256
        $recoveryLease['RecoveryResultSha256'] = [string]$recoveryResultHash
        $recoveryLease['ApplicationRelaunchedByHarnessAfterGuestPowerOff'] = $false
        Write-JsonAtomic -Path $leasePath -Value $recoveryLease
    }

    [pscustomobject][ordered]@{
        JobId = $jobId
        Completed = $true
        ExistingResult = [bool]$existingTerminalResultValidated
        Deferred = $false
        ResultFile = $resultFile
        HarnessSucceeded = [bool]$harnessSucceeded
        TestEvaluated = [bool]$testEvaluated
        TestPassed = if ($testEvaluated) { [bool]$testPassed } else { $null }
    }
}

function Wait-MainWindow {
    param(
        [Parameter(Mandatory = $true)] [System.Diagnostics.Process] $Process,
        [int] $TimeoutMilliseconds = 15000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if ($Process.HasExited) {
            throw "Process $($Process.Id) exited before creating a main window."
        }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for process $($Process.Id) to create a main window."
}

function Focus-Window {
    param([Parameter(Mandatory = $true)] [IntPtr] $WindowHandle)

    [CodexGuestInput]::ShowWindowAsync($WindowHandle, 9) | Out-Null
    [CodexGuestInput]::SetForegroundWindow($WindowHandle) | Out-Null
    Start-Sleep -Milliseconds 250
}

function Find-AutomationElement {
    param(
        [Parameter(Mandatory = $true)] [IntPtr] $WindowHandle,
        [string] $AutomationId,
        [string] $Name,
        [int] $TimeoutMilliseconds = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $availableElements = @()
    $lastLookupError = $null
    do {
        if ([string]::IsNullOrWhiteSpace($AutomationId) -and [string]::IsNullOrWhiteSpace($Name)) {
            throw 'click_control requires automationId or name.'
        }
        try {
            # Refresh the root and enumerate the current tree on every pass;
            # WinForms and Electron providers can publish descendants after the
            # main window handle itself becomes available.
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
            $elements = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
            $inventory = New-Object System.Collections.Generic.List[string]
            foreach ($element in $elements) {
                try {
                    $elementId = [string]$element.Current.AutomationId
                    $elementName = [string]$element.Current.Name
                    $controlType = [string]$element.Current.ControlType.ProgrammaticName
                    if ($inventory.Count -lt 30 -and (-not [string]::IsNullOrWhiteSpace($elementId) -or -not [string]::IsNullOrWhiteSpace($elementName))) {
                        $inventory.Add("$controlType id='$elementId' name='$elementName'")
                    }

                    $idMatch = -not [string]::IsNullOrWhiteSpace($AutomationId) -and
                        [string]::Equals($elementId, $AutomationId, [StringComparison]::OrdinalIgnoreCase)
                    $explicitNameMatch = -not [string]::IsNullOrWhiteSpace($Name) -and
                        [string]::Equals($elementName, $Name, [StringComparison]::OrdinalIgnoreCase)
                    # Many WinForms controls expose AccessibleName as UIA Name
                    # while leaving AutomationId blank. Treat the requested ID
                    # as a Name fallback when no explicit name was supplied.
                    $idAsNameMatch = [string]::IsNullOrWhiteSpace($Name) -and
                        -not [string]::IsNullOrWhiteSpace($AutomationId) -and
                        [string]::Equals($elementName, $AutomationId, [StringComparison]::OrdinalIgnoreCase)
                    if ($idMatch -or $explicitNameMatch -or $idAsNameMatch) {
                        return $element
                    }
                }
                catch {
                    # Providers may invalidate individual elements while the
                    # tree is changing; continue with the remaining elements.
                }
            }
            $availableElements = $inventory.ToArray()
            $lastLookupError = $null
        }
        catch {
            $lastLookupError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $inventoryText = if ($availableElements.Count -gt 0) { $availableElements -join '; ' } else { '<none>' }
    $lookupDetail = if ($lastLookupError) { " Last provider error: $lastLookupError" } else { '' }
    throw "Timed out finding automation element id='$AutomationId' name='$Name'. Available elements: $inventoryText.$lookupDetail"
}

function Click-AutomationElement {
    param([Parameter(Mandatory = $true)] $Element)

    $rectangle = $Element.Current.BoundingRectangle
    if ($rectangle.IsEmpty -or $rectangle.Width -le 0 -or $rectangle.Height -le 0) {
        throw 'The automation element has no clickable bounding rectangle.'
    }

    $x = [int]($rectangle.Left + ($rectangle.Width / 2))
    $y = [int]($rectangle.Top + ($rectangle.Height / 2))
    [CodexGuestInput]::ClickLeft($x, $y)
    Start-Sleep -Milliseconds 250
}

function Test-CaptureDesktopReady {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($sessionId -le 0) {
        return [pscustomobject][ordered]@{ Ready = $false; Error = "Guest agent is not in an interactive session."; SessionId = $sessionId }
    }
    if (-not [Environment]::UserInteractive) {
        return [pscustomobject][ordered]@{ Ready = $false; Error = "Guest agent is not marked UserInteractive."; SessionId = $sessionId }
    }
    $desktopError = [CodexGuestInput]::ProbeInputDesktop()
    if ($desktopError -ne 0) {
        return [pscustomobject][ordered]@{ Ready = $false; Error = "OpenInputDesktop failed with Win32 error $desktopError."; SessionId = $sessionId }
    }
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($screen.Width -le 0 -or $screen.Height -le 0) {
        return [pscustomobject][ordered]@{ Ready = $false; Error = "Interactive desktop has invalid dimensions $($screen.Width)x$($screen.Height)."; SessionId = $sessionId }
    }
    $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $sessionId)
    $dwm = @(Get-Process -Name dwm -ErrorAction SilentlyContinue | Where-Object SessionId -eq $sessionId)
    if ($explorer.Count -eq 0 -or $dwm.Count -eq 0) {
        return [pscustomobject][ordered]@{ Ready = $false; Error = "Interactive shell is not ready (Explorer=$($explorer.Count), DWM=$($dwm.Count))."; SessionId = $sessionId }
    }
    [pscustomobject][ordered]@{
        Ready = $true
        Error = $null
        SessionId = $sessionId
        Width = [int]$screen.Width
        Height = [int]$screen.Height
    }
}

function Wait-CaptureDesktopReady {
    param([ValidateRange(100, 30000)] [int] $TimeoutMilliseconds = 5000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $probe = Test-CaptureDesktopReady
        if ($probe.Ready) { return $probe }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $probe
}

function Invoke-ScreenCaptureHelper {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ErrorPath,
        [ValidateRange(100, 30000)] [int] $TimeoutMilliseconds
    )

    $escapedOutputPath = $Path.Replace("'", "''")
    $escapedErrorPath = $ErrorPath.Replace("'", "''")
    $helperTemplate = @'
$ErrorActionPreference = 'Stop'
$outputPath = '__OUTPUT_PATH__'
$errorPath = '__ERROR_PATH__'
$temporaryPath = $outputPath + '.capture.tmp.png'
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($screen.Width -le 0 -or $screen.Height -le 0) {
        throw "The interactive desktop has invalid dimensions: $($screen.Width)x$($screen.Height)."
    }
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    $bitmap = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(
            $screen.Left,
            $screen.Top,
            0,
            0,
            $screen.Size,
            [System.Drawing.CopyPixelOperation]::SourceCopy
        )
        $bitmap.Save($temporaryPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    exit 0
}
catch {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($errorPath, $_.Exception.ToString())
    exit 1
}
'@
    $helperSource = $helperTemplate.
        Replace('__OUTPUT_PATH__', $escapedOutputPath).
        Replace('__ERROR_PATH__', $escapedErrorPath)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperSource))
    Remove-Item -LiteralPath $Path, $ErrorPath -Force -ErrorAction SilentlyContinue
    $captureProcess = $null
    try {
        $captureProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand
        ) -WindowStyle Hidden -PassThru

        if (-not $captureProcess.WaitForExit($TimeoutMilliseconds)) {
            try {
                $captureProcess.Kill()
                $captureProcess.WaitForExit(5000) | Out-Null
            }
            catch {
            }
            return [pscustomobject][ordered]@{
                Success = $false
                Error = "screen-capture helper timed out after $TimeoutMilliseconds ms"
                TimedOut = $true
            }
        }
        if ($captureProcess.ExitCode -ne 0) {
            $message = if (Test-Path -LiteralPath $ErrorPath -PathType Leaf) {
                (Get-Content -Raw -LiteralPath $ErrorPath).Trim()
            }
            else {
                "screen-capture helper exited with code $($captureProcess.ExitCode)"
            }
            return [pscustomobject][ordered]@{ Success = $false; Error = $message; TimedOut = $false }
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 0) {
            return [pscustomobject][ordered]@{ Success = $false; Error = 'screen-capture helper exited without producing a non-empty PNG'; TimedOut = $false }
        }
        [pscustomobject][ordered]@{ Success = $true; Error = $null; TimedOut = $false }
    }
    catch {
        [pscustomobject][ordered]@{ Success = $false; Error = $_.Exception.ToString(); TimedOut = $false }
    }
    finally {
        if ($captureProcess) { $captureProcess.Dispose() }
    }
}

function Capture-Screen {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [ValidateRange(3000, 30000)] [int] $TimeoutMilliseconds = 30000,
        [ValidateRange(1, 5)] [int] $Attempts = 5
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $errorPath = $Path + '.error.txt'
    $attemptLog = New-Object Collections.Generic.List[object]
    $lastError = $null

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -le 0) {
            $lastError = "screen-capture action exhausted its $TimeoutMilliseconds ms deadline"
            break
        }

        $readinessTimeout = [Math]::Max(100, [Math]::Min(5000, $remaining))
        $desktop = Wait-CaptureDesktopReady -TimeoutMilliseconds $readinessTimeout
        if (-not $desktop.Ready) {
            $capture = [pscustomobject][ordered]@{ Success = $false; Error = $desktop.Error; TimedOut = $false }
        }
        else {
            $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -le 0) {
                $capture = [pscustomobject][ordered]@{ Success = $false; Error = "screen-capture action exhausted its $TimeoutMilliseconds ms deadline"; TimedOut = $true }
            }
            else {
                $capture = Invoke-ScreenCaptureHelper -Path $Path -ErrorPath $errorPath -TimeoutMilliseconds ([Math]::Max(100, [Math]::Min(30000, $remaining)))
            }
        }

        $attemptLog.Add([ordered]@{
            Attempt = $attempt
            DesktopReady = [bool]$desktop.Ready
            SessionId = if ($null -ne $desktop.SessionId) { [int]$desktop.SessionId } else { $null }
            Success = [bool]$capture.Success
            Error = [string]$capture.Error
            ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        })
        if ($capture.Success) {
            Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
            $watch.Stop()
            return [pscustomobject][ordered]@{
                Attempts = $attempt
                ElapsedMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds, 3)
                Width = [int]$desktop.Width
                Height = [int]$desktop.Height
                AttemptLog = $attemptLog.ToArray()
            }
        }

        $lastError = [string]$capture.Error
        if ($attempt -lt $Attempts) {
            $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -le 0) { break }
            $backoff = [Math]::Min(4000, 500 * [Math]::Pow(2, $attempt - 1))
            Start-Sleep -Milliseconds ([int][Math]::Min($backoff, $remaining))
        }
    }

    $watch.Stop()
    $diagnostic = $attemptLog.ToArray() | ConvertTo-Json -Depth 8 -Compress
    throw "[CAPTURE_INFRASTRUCTURE] Screen capture failed after $($attemptLog.Count) attempts over $([Math]::Round($watch.Elapsed.TotalMilliseconds, 3)) ms: $lastError Attempts=$diagnostic"
}

$guestLiveEvidenceModule = Join-Path $agentRoot 'GuestLiveEvidence.ps1'
if (-not (Test-Path -LiteralPath $guestLiveEvidenceModule -PathType Leaf)) {
    throw "Guest live evidence module is missing: $guestLiveEvidenceModule"
}
. $guestLiveEvidenceModule

function Mount-GuestHostInputs {
    param([object[]] $Definitions)

    $mounted = New-Object Collections.Generic.List[object]
    try {
        foreach ($definition in @($Definitions)) {
            $name = [string]$definition.Name
            $driveLetter = ([string]$definition.DriveLetter).ToUpperInvariant()
            $remotePath = [string]$definition.RemotePath
            if ($name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or $driveLetter -notmatch '^[A-Z]$' -or $remotePath -notmatch '^\\\\[^\\]+\\CHVRO_[A-Za-z0-9_]+$') {
                throw "Invalid guest read-only host input mapping: $name"
            }
            if ([string]::IsNullOrWhiteSpace([string]$definition.Username) -or [string]::IsNullOrWhiteSpace([string]$definition.Password)) {
                throw "Guest read-only host input '$name' has no ephemeral credential."
            }
            Remove-PSDrive -Name $driveLetter -Scope Global -Force -ErrorAction SilentlyContinue
            Get-SmbMapping -LocalPath "$driveLetter`:" -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue
            $securePassword = ConvertTo-SecureString -String ([string]$definition.Password) -AsPlainText -Force
            $credential = [Management.Automation.PSCredential]::new([string]$definition.Username, $securePassword)
            New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root $remotePath -Credential $credential -Persist -Scope Global -ErrorAction Stop | Out-Null
            $driveRoot = "$driveLetter`:\"
            if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
                throw "Guest read-only host input '$name' did not become accessible at $driveRoot"
            }
            $mounted.Add([pscustomobject][ordered]@{
                Name = $name
                DriveLetter = $driveLetter
                DriveRoot = $driveRoot
                RemotePath = $remotePath
                GuestSubPath = [string]$definition.GuestSubPath
                MountedUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        $mounted.ToArray()
    }
    catch {
        Dismount-GuestHostInputs -MountedInputs $mounted.ToArray() | Out-Null
        throw
    }
}

function Dismount-GuestHostInputs {
    param([object[]] $MountedInputs)

    $errors = New-Object Collections.Generic.List[string]
    $reverseMappings = @($MountedInputs)
    [array]::Reverse($reverseMappings)
    foreach ($mapping in $reverseMappings) {
        $driveLetter = ([string]$mapping.DriveLetter).ToUpperInvariant()
        try {
            Remove-PSDrive -Name $driveLetter -Scope Global -Force -ErrorAction SilentlyContinue
            Get-SmbMapping -LocalPath "$driveLetter`:" -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue
            if (Get-SmbMapping -LocalPath "$driveLetter`:" -ErrorAction SilentlyContinue) {
                throw "SMB mapping $driveLetter`: remained present."
            }
        }
        catch { $errors.Add("$driveLetter`: $($_.Exception.Message)") }
    }
    [pscustomobject][ordered]@{
        Attempted = @($MountedInputs).Count -gt 0
        Success = $errors.Count -eq 0
        Errors = $errors.ToArray()
        UnmountedCount = @($MountedInputs).Count - $errors.Count
    }
}

function Invoke-GuestJob {
    param(
        [Parameter(Mandatory = $true)] $Job,
        [Parameter(Mandatory = $true)] [string] $JobFile
    )

    $jobId = [string]$Job.id
    if ($jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
        throw "Invalid job id: $jobId"
    }
    $expectGuestPowerOff = Test-ExpectedGuestPowerOffJob -Job $Job

    $jobOutputPath = Join-Path $outboxPath $jobId
    $leasePath = Join-Path $jobOutputPath 'lease.json'
    if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
        try {
            $priorLease = Get-Content -Raw -LiteralPath $leasePath | ConvertFrom-Json
            if ([int]$priorLease.ProcessId -gt 0) {
                $priorCleanup = Stop-GuestProcessTree -RootProcessId ([int]$priorLease.ProcessId)
                if (-not $priorCleanup.Success) {
                    throw "Could not clean the prior application process tree for job $jobId."
                }
            }
        }
        catch {
            throw "Could not recover the prior guest-job lease: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $jobOutputPath -PathType Container) {
        Remove-Item -LiteralPath $jobOutputPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $jobOutputPath | Out-Null
    $leasePath = Join-Path $jobOutputPath 'lease.json'
    $resultFile = Join-Path $jobOutputPath 'result.json'
    $actionLog = New-Object System.Collections.Generic.List[object]
    $startedUtc = [DateTime]::UtcNow
    $guestBootTimeUtc = (Get-GuestBootTimeUtc).ToString('o')
    $process = $null
    $windowHandle = [IntPtr]::Zero
    $success = $false
    $errorMessage = $null
    $failureKind = $null
    $testEvaluated = $false
    $testPassed = $null
    $testFailureKind = $null
    $testFailureMessage = $null
    $testAssertion = $null
    $assertionEvaluated = $false
    $assertionPath = $null
    $mountedHostInputs = @()
    $hostInputCleanup = [pscustomobject][ordered]@{
        Attempted = $false
        Success = $true
        Errors = @()
        UnmountedCount = 0
    }
    $processCleanup = [pscustomobject][ordered]@{
        Attempted = $false
        RootProcessId = $null
        Success = $true
        VerificationSucceeded = $true
        ObservedProcessIds = @()
        SurvivorProcessIds = @()
        Errors = @()
        ElapsedMilliseconds = 0
    }

    try {
        if ($Job.PSObject.Properties.Name -contains 'hostInputs' -and @($Job.hostInputs).Count -gt 0) {
            Write-AgentState -Status 'PreparingHostInputs' -JobId $jobId
            $mountedHostInputs = @(Mount-GuestHostInputs -Definitions @($Job.hostInputs))
        }
        $executable = [Environment]::ExpandEnvironmentVariables([string]$Job.executable)
        if (-not (Test-Path -LiteralPath $executable)) {
            throw "Executable not found: $executable"
        }

        $arguments = [string]$Job.arguments
        $arguments = $arguments.Replace('{OUTDIR}', $jobOutputPath)
        if ([string]::IsNullOrWhiteSpace($arguments)) {
            $process = Start-Process -FilePath $executable -PassThru
        }
        else {
            $process = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru
        }
        Write-JsonAtomic -Path $leasePath -Value ([ordered]@{
            JobId = $jobId
            ProcessId = $process.Id
            Executable = $executable
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            GuestBootTimeUtc = $guestBootTimeUtc
        })
        Set-GuestLiveEvidenceContext -RequestId $jobId -OutputPath $jobOutputPath -ApplicationProcessId ([int]$process.Id) -LifecycleStage 'ApplicationRunning'
        Invoke-GuestLiveEvidenceHeartbeat

        if ($Job.assertResultFile) {
            $assertionPath = Resolve-GuestOutputPath -Value ([string]$Job.assertResultFile) -JobOutputPath $jobOutputPath -Context 'assertResultFile'
        }

        $actionIndex = 0
        $stoppedAfterActionIndex = $null
        foreach ($action in @($Job.actions)) {
            $actionIndex++
            $actionStarted = [DateTime]::UtcNow
            $actionType = [string]$action.type
            $actionDetails = $null
            $actionTestPassed = $null
            $stopActions = $false
            Write-AgentState -Status 'RunningJob' -JobId $jobId -ActionType $actionType -ActionIndex $actionIndex
            Update-GuestLiveEvidenceContext -LifecycleStage 'GuestAction'
            try {
                switch ($actionType) {
                    'wait_window' {
                        $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 15000 }
                        if ($timeout -lt 100 -or $timeout -gt 300000) {
                            throw 'wait_window timeoutMs must be between 100 and 300000.'
                        }
                        $windowHandle = Wait-MainWindow -Process $process -TimeoutMilliseconds $timeout
                        Focus-Window -WindowHandle $windowHandle
                    }
                    'focus_window' {
                        if ($windowHandle -eq [IntPtr]::Zero) {
                            $windowHandle = Wait-MainWindow -Process $process
                        }
                        Focus-Window -WindowHandle $windowHandle
                    }
                    'click_control' {
                        if ($windowHandle -eq [IntPtr]::Zero) {
                            $windowHandle = Wait-MainWindow -Process $process
                        }
                        Focus-Window -WindowHandle $windowHandle
                        $element = Find-AutomationElement `
                            -WindowHandle $windowHandle `
                            -AutomationId ([string]$action.automationId) `
                            -Name ([string]$action.name) `
                            -TimeoutMilliseconds $(if ($action.timeoutMs) { [int]$action.timeoutMs } else { 10000 })
                        Click-AutomationElement -Element $element
                    }
                    'type_text' {
                        if ($windowHandle -eq [IntPtr]::Zero) {
                            $windowHandle = Wait-MainWindow -Process $process
                        }
                        Focus-Window -WindowHandle $windowHandle
                        [CodexGuestInput]::TypeUnicode([string]$action.text)
                        Start-Sleep -Milliseconds 250
                    }
                    'click_relative' {
                        if ($windowHandle -eq [IntPtr]::Zero) {
                            $windowHandle = Wait-MainWindow -Process $process
                        }
                        Focus-Window -WindowHandle $windowHandle
                        $rectangle = New-Object CodexGuestInput+RECT
                        if (-not [CodexGuestInput]::GetWindowRect($windowHandle, [ref]$rectangle)) {
                            throw 'Could not read the target window rectangle.'
                        }
                        $clickX = $rectangle.Left + [int]$action.x
                        $clickY = $rectangle.Top + [int]$action.y
                        if ($clickX -lt $rectangle.Left -or $clickX -ge $rectangle.Right -or
                            $clickY -lt $rectangle.Top -or $clickY -ge $rectangle.Bottom) {
                            throw 'click_relative coordinates are outside the target window.'
                        }
                        [CodexGuestInput]::ClickLeft($clickX, $clickY)
                        Start-Sleep -Milliseconds 250
                    }
                    'wait' {
                        $waitMilliseconds = [int]$action.ms
                        if ($waitMilliseconds -lt 0 -or $waitMilliseconds -gt 300000) {
                            throw 'wait ms must be between 0 and 300000.'
                        }
                        $waitDeadline = [DateTime]::UtcNow.AddMilliseconds($waitMilliseconds)
                        do {
                            Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc $waitDeadline
                            $remainingWait = [int][Math]::Ceiling(($waitDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                            if ($remainingWait -le 0) { break }
                            Start-Sleep -Milliseconds ([Math]::Min(100, $remainingWait))
                        } while ([DateTime]::UtcNow -lt $waitDeadline)
                    }
                    'wait_process_exit' {
                        $timeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 300000 }
                        if ($timeout -lt 100 -or $timeout -gt 7200000) {
                            throw 'wait_process_exit timeoutMs must be between 100 and 7200000.'
                        }
                        $waitWatch = [Diagnostics.Stopwatch]::StartNew()
                        $waitDeadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
                        $exited = $false
                        do {
                            Invoke-GuestLiveEvidenceHeartbeat -NotAfterUtc $waitDeadline
                            $process.Refresh()
                            if ($process.HasExited) {
                                $exitWithinDeadline = try { $process.ExitTime.ToUniversalTime() -le $waitDeadline } catch { [DateTime]::UtcNow -le $waitDeadline }
                                if ($exitWithinDeadline) { $exited = $true }
                                break
                            }
                            $remainingWait = [int][Math]::Ceiling(($waitDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                            if ($remainingWait -le 0) { break }
                            $null = $process.WaitForExit([Math]::Min(100, $remainingWait))
                        } while ([DateTime]::UtcNow -lt $waitDeadline)
                        $waitWatch.Stop()
                        $testEvaluated = $true
                        if (-not $exited) {
                            $testPassed = $false
                            $actionTestPassed = $false
                            $testFailureKind = 'ProcessExitTimeout'
                            $testFailureMessage = "Application process $($process.Id) did not exit within $timeout ms."
                            $stopActions = $true
                            $actionDetails = [ordered]@{
                                ProcessId = $process.Id
                                Exited = $false
                                TimeoutMilliseconds = $timeout
                                ElapsedMilliseconds = [Math]::Round($waitWatch.Elapsed.TotalMilliseconds, 3)
                            }
                        }
                        else {
                            $process.Refresh()
                            $exitCode = [int]$process.ExitCode
                            $expectedSpecified = $action.PSObject.Properties.Name -contains 'expectedExitCode' -and $null -ne $action.expectedExitCode
                            $expectedExitCode = if ($expectedSpecified) { [int]$action.expectedExitCode } else { $null }
                            $passed = -not $expectedSpecified -or $exitCode -eq $expectedExitCode
                            if ($null -eq $testPassed) { $testPassed = $true }
                            if (-not $passed) {
                                $testPassed = $false
                                $testFailureKind = 'ProcessExitCode'
                                $testFailureMessage = "Application process exited with code $exitCode; expected $expectedExitCode."
                                $stopActions = $true
                            }
                            $actionTestPassed = [bool]$passed
                            $actionDetails = [ordered]@{
                                ProcessId = $process.Id
                                Exited = $true
                                ExitCode = $exitCode
                                ExpectedExitCode = $expectedExitCode
                                TimeoutMilliseconds = $timeout
                                ElapsedMilliseconds = [Math]::Round($waitWatch.Elapsed.TotalMilliseconds, 3)
                            }
                        }
                    }
                    'wait_result_file' {
                        $waitPath = Resolve-GuestOutputPath -Value ([string]$action.path) -JobOutputPath $jobOutputPath -Context 'wait_result_file path'
                        $timeout = if ($action.timeoutMs) { [int64]$action.timeoutMs } else { 300000 }
                        if ($timeout -lt 100 -or $timeout -gt 7200000) {
                            throw 'wait_result_file timeoutMs must be between 100 and 7200000.'
                        }
                        $waitResult = Wait-GuestResultFile -Path $waitPath -TimeoutMilliseconds $timeout
                        $testEvaluated = $true
                        $actionDetails = [ordered]@{
                            Path = $waitPath
                            Found = [bool]$waitResult.Found
                            Length = [long]$waitResult.Length
                            TimeoutMilliseconds = $timeout
                            ElapsedMilliseconds = [double]$waitResult.ElapsedMilliseconds
                        }
                        if (-not $waitResult.Found) {
                            $testPassed = $false
                            $actionTestPassed = $false
                            $testFailureKind = 'ResultFileTimeout'
                            $testFailureMessage = "Application result file was not created within $timeout ms: $waitPath"
                            $stopActions = $true
                        }
                        else {
                            if ($null -eq $testPassed) { $testPassed = $true }
                            $actionTestPassed = $true
                            $hasJsonAssertion = $Job.PSObject.Properties.Name -contains 'assertResultJsonPointer' -and
                                $Job.PSObject.Properties.Name -contains 'assertResultEqualsJson'
                            if ($hasJsonAssertion -and $assertionPath -and [string]::Equals($waitPath, $assertionPath, [StringComparison]::OrdinalIgnoreCase)) {
                                $testAssertion = Test-GuestResultAssertion -Path $assertionPath -JsonPointer ([string]$Job.assertResultJsonPointer) -ExpectedJson ([string]$Job.assertResultEqualsJson)
                                $assertionEvaluated = $true
                                $actionDetails['Assertion'] = $testAssertion
                                $actionTestPassed = [bool]$testAssertion.Passed
                                if (-not $testAssertion.Passed) {
                                    $testPassed = $false
                                    $testFailureKind = [string]$testAssertion.FailureKind
                                    $testFailureMessage = [string]$testAssertion.Message
                                    $stopActions = $true
                                }
                            }
                        }
                    }
                    'screenshot' {
                        $fileName = [string]$action.name
                        if ([string]::IsNullOrWhiteSpace($fileName)) {
                            $fileName = 'screenshot.png'
                        }
                        if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                            throw 'screenshot name must be a valid leaf filename.'
                        }
                        $screenshotTimeout = if ($action.timeoutMs) { [int]$action.timeoutMs } else { 30000 }
                        $screenshotAttempts = if ($action.attempts) { [int]$action.attempts } else { 5 }
                        $actionDetails = Capture-Screen -Path (Join-Path $jobOutputPath $fileName) -TimeoutMilliseconds $screenshotTimeout -Attempts $screenshotAttempts
                    }
                    default {
                        throw "Unsupported action type: $actionType"
                    }
                }

                $actionLog.Add([ordered]@{
                    Type = $actionType
                    Index = $actionIndex
                    StartedUtc = $actionStarted.ToString('o')
                    CompletedUtc = [DateTime]::UtcNow.ToString('o')
                    Success = $true
                    TestPassed = $actionTestPassed
                    Details = $actionDetails
                    Error = $null
                })
                if ($stopActions) {
                    $stoppedAfterActionIndex = $actionIndex
                    break
                }
                Update-GuestLiveEvidenceContext -LifecycleStage 'ApplicationRunning'
                Invoke-GuestLiveEvidenceHeartbeat
            }
            catch {
                if ($actionType -eq 'screenshot' -and $_.Exception.Message.StartsWith('[CAPTURE_INFRASTRUCTURE]', [StringComparison]::Ordinal)) {
                    $failureKind = 'CaptureInfrastructure'
                }
                elseif ([string]::IsNullOrWhiteSpace($failureKind)) {
                    $failureKind = 'ActionFailure'
                }
                $actionLog.Add([ordered]@{
                    Type = $actionType
                    Index = $actionIndex
                    StartedUtc = $actionStarted.ToString('o')
                    CompletedUtc = [DateTime]::UtcNow.ToString('o')
                    Success = $false
                    TestPassed = $null
                    Details = $actionDetails
                    Error = $_.Exception.Message
                })
                throw
            }
        }

        # A test assertion or bounded wait can stop the ordinary action sequence
        # immediately. Preserve requested screenshot evidence without honoring
        # any later waits or input actions: remaining screenshots become an
        # immediate diagnostic finalizer.
        if ($null -ne $stoppedAfterActionIndex -and $testEvaluated -and -not $testPassed) {
            $allActions = @($Job.actions)
            for ($remainingIndex = [int]$stoppedAfterActionIndex; $remainingIndex -lt $allActions.Count; $remainingIndex++) {
                $remainingAction = $allActions[$remainingIndex]
                if ([string]$remainingAction.type -ne 'screenshot') { continue }

                $diagnosticIndex = $remainingIndex + 1
                $diagnosticStarted = [DateTime]::UtcNow
                Write-AgentState -Status 'RunningJob' -JobId $jobId -ActionType 'screenshot' -ActionIndex $diagnosticIndex
                try {
                    $fileName = [string]$remainingAction.name
                    if ([string]::IsNullOrWhiteSpace($fileName)) {
                        $fileName = 'screenshot.png'
                    }
                    if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                        throw 'screenshot name must be a valid leaf filename.'
                    }
                    $screenshotTimeout = if ($remainingAction.timeoutMs) { [int]$remainingAction.timeoutMs } else { 30000 }
                    $screenshotAttempts = if ($remainingAction.attempts) { [int]$remainingAction.attempts } else { 5 }
                    $captureDetails = Capture-Screen -Path (Join-Path $jobOutputPath $fileName) -TimeoutMilliseconds $screenshotTimeout -Attempts $screenshotAttempts
                    $actionDetails = [ordered]@{
                        DiagnosticAfterTestFailure = $true
                        Capture = $captureDetails
                    }
                    $actionLog.Add([ordered]@{
                        Type = 'screenshot'
                        Index = $diagnosticIndex
                        StartedUtc = $diagnosticStarted.ToString('o')
                        CompletedUtc = [DateTime]::UtcNow.ToString('o')
                        Success = $true
                        TestPassed = $null
                        Details = $actionDetails
                        Error = $null
                    })
                }
                catch {
                    if ($_.Exception.Message.StartsWith('[CAPTURE_INFRASTRUCTURE]', [StringComparison]::Ordinal)) {
                        $failureKind = 'CaptureInfrastructure'
                    }
                    elseif ([string]::IsNullOrWhiteSpace($failureKind)) {
                        $failureKind = 'ActionFailure'
                    }
                    $actionLog.Add([ordered]@{
                        Type = 'screenshot'
                        Index = $diagnosticIndex
                        StartedUtc = $diagnosticStarted.ToString('o')
                        CompletedUtc = [DateTime]::UtcNow.ToString('o')
                        Success = $false
                        TestPassed = $null
                        Details = $null
                        Error = $_.Exception.Message
                    })
                    throw
                }
            }
        }

        if ($assertionPath -and -not ($testEvaluated -and -not $testPassed)) {
            $assertionWait = Wait-GuestResultFile -Path $assertionPath -TimeoutMilliseconds 10000
            $testEvaluated = $true
            if (-not $assertionWait.Found) {
                $testPassed = $false
                $testFailureKind = 'ResultFileMissing'
                $testFailureMessage = "Expected application result file was not created: $assertionPath"
            }
            else {
                if ($null -eq $testPassed) { $testPassed = $true }
                $hasJsonAssertion = $Job.PSObject.Properties.Name -contains 'assertResultJsonPointer' -and
                    $Job.PSObject.Properties.Name -contains 'assertResultEqualsJson'
                if ($hasJsonAssertion -and -not $assertionEvaluated) {
                    $testAssertion = Test-GuestResultAssertion -Path $assertionPath -JsonPointer ([string]$Job.assertResultJsonPointer) -ExpectedJson ([string]$Job.assertResultEqualsJson)
                    $assertionEvaluated = $true
                    if (-not $testAssertion.Passed) {
                        $testPassed = $false
                        $testFailureKind = [string]$testAssertion.FailureKind
                        $testFailureMessage = [string]$testAssertion.Message
                    }
                }
            }
        }

        $success = $true
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($failureKind)) { $failureKind = 'Harness' }
    }
    finally {
        Clear-GuestLiveEvidenceContext
        if ($process -and -not $expectGuestPowerOff) {
            Write-AgentState -Status 'CleaningUpJob' -JobId $jobId
            $processCleanup = Stop-GuestProcessTree -RootProcessId ([int]$process.Id)
            if (-not $processCleanup.Success) {
                $cleanupError = if ($processCleanup.SurvivorProcessIds.Count -gt 0) {
                    "Application process-tree cleanup left survivor PIDs: $($processCleanup.SurvivorProcessIds -join ', ')."
                }
                else {
                    'Application process-tree cleanup could not be verified.'
                }
                $success = $false
                $failureKind = 'ProcessCleanup'
                $errorMessage = if ([string]::IsNullOrWhiteSpace($errorMessage)) { $cleanupError } else { "$errorMessage $cleanupError" }
            }
        }
        elseif ($process -and $expectGuestPowerOff) {
            $processCleanup = [pscustomobject][ordered]@{
                Attempted = $false
                RootProcessId = [int]$process.Id
                Success = $true
                VerificationSucceeded = $false
                ObservedProcessIds = @()
                SurvivorProcessIds = @()
                Errors = @()
                ElapsedMilliseconds = 0
                DeferredUntilGuestPowerOffRecovery = $true
            }
        }
        if ($expectGuestPowerOff) {
            $hostInputCleanup = [pscustomobject][ordered]@{
                Attempted = $false
                Success = $true
                Errors = @()
                UnmountedCount = 0
                DeferredUntilGuestPowerOffRecovery = $true
            }
        }
        else {
            $hostInputCleanup = Dismount-GuestHostInputs -MountedInputs $mountedHostInputs
            if (-not $hostInputCleanup.Success) {
                $cleanupError = 'Guest read-only host-input cleanup failed: ' + (@($hostInputCleanup.Errors) -join ' | ')
                $success = $false
                $failureKind = 'HostInputCleanup'
                $errorMessage = if ([string]::IsNullOrWhiteSpace($errorMessage)) { $cleanupError } else { "$errorMessage $cleanupError" }
            }
        }
        if (-not $expectGuestPowerOff) {
            Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
        }

        $resultEnvelope = [ordered]@{
            JobId = $jobId
            Success = $success
            HarnessSucceeded = $success
            TestEvaluated = [bool]$testEvaluated
            TestPassed = if ($testEvaluated) { [bool]$testPassed } else { $null }
            OverallSucceeded = [bool]$success -and (-not $testEvaluated -or [bool]$testPassed)
            FailureKind = if ($success) { $null } else { $failureKind }
            TestFailureKind = if ($testEvaluated -and -not $testPassed) { $testFailureKind } else { $null }
            TestFailureMessage = if ($testEvaluated -and -not $testPassed) { $testFailureMessage } else { $null }
            TestAssertion = $testAssertion
            Error = $errorMessage
            StartedUtc = $startedUtc.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            AgentProcessId = $PID
            AgentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
            UserInteractive = [Environment]::UserInteractive
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            ProcessCleanup = $processCleanup
            HostInputs = @($mountedHostInputs | ForEach-Object {
                [ordered]@{
                    Name = [string]$_.Name
                    DriveLetter = [string]$_.DriveLetter
                    DriveRoot = [string]$_.DriveRoot
                    GuestSubPath = [string]$_.GuestSubPath
                    MountedUtc = [string]$_.MountedUtc
                }
            })
            HostInputCleanup = $hostInputCleanup
            Actions = $actionLog.ToArray()
        }
        if ($expectGuestPowerOff) {
            # The boot epoch is part of the opt-in recovery protocol only; keep
            # the legacy result envelope byte-for-schema compatible.
            $resultEnvelope['GuestBootTimeUtc'] = $guestBootTimeUtc
        }
        Write-JsonAtomic -Path $resultFile -Value $resultEnvelope
        Write-AgentState
    }

    if (-not $success) {
        throw $errorMessage
    }
}

function Repair-InterruptedGuestJobs {
    [CmdletBinding()]
    param(
        [string] $InboxRoot = $inboxPath,
        [string] $ProcessingRoot = $processingPath,
        [string] $CompletedRoot = $completedPath,
        [string] $OutboxRoot = $outboxPath
    )

    $legacyRequeued = 0
    $expectedRecovered = 0
    $expectedAlreadyComplete = 0
    $expectedDeferred = 0
    $recoveryErrors = 0
    $completedJobsAtStartup = @(Get-ChildItem -LiteralPath $CompletedRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)

    foreach ($orphanedJob in @(Get-ChildItem -LiteralPath $ProcessingRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $job = $null
        try { $job = Get-Content -Raw -LiteralPath $orphanedJob.FullName -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $job = $null }

        if (-not (Test-ExpectedGuestPowerOffJob -Job $job)) {
            # Preserve the legacy orphan behavior exactly: an interrupted
            # ordinary job returns to Inbox for clean retry and lease cleanup.
            Move-Item -LiteralPath $orphanedJob.FullName -Destination (Join-Path $InboxRoot $orphanedJob.Name) -Force
            $legacyRequeued++
            continue
        }

        $deferred = $false
        try {
            $completion = Complete-ExpectedGuestPowerOffJob -Job $job -JobFile $orphanedJob.FullName -RecoverySource Processing -OutboxRoot $OutboxRoot
            if ($completion.Deferred) {
                $deferred = $true
                $expectedDeferred++
            }
            elseif ($completion.Completed) { $expectedRecovered++ }
            else { $expectedAlreadyComplete++ }
        }
        catch {
            $recoveryErrors++
            $fallbackId = [IO.Path]::GetFileNameWithoutExtension($orphanedJob.Name)
            $fallbackOutput = Join-Path $OutboxRoot $fallbackId
            New-Item -ItemType Directory -Force -Path $fallbackOutput | Out-Null
            Write-JsonAtomic -Path (Join-Path $fallbackOutput 'agent-error.json') -Value ([ordered]@{
                Success = $false
                Error = $_.Exception.Message
                ExceptionType = $_.Exception.GetType().FullName
                ScriptStackTrace = $_.ScriptStackTrace
                ExpectedGuestPowerOffRecovery = $true
                ApplicationRelaunchedByHarnessAfterGuestPowerOff = $false
                TimestampUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        finally {
            if (-not $deferred -and (Test-Path -LiteralPath $orphanedJob.FullName -PathType Leaf)) {
                Move-Item -LiteralPath $orphanedJob.FullName -Destination (Join-Path $CompletedRoot $orphanedJob.Name) -Force
            }
        }
    }

    foreach ($completedJob in $completedJobsAtStartup) {
        $job = $null
        try { $job = Get-Content -Raw -LiteralPath $completedJob.FullName -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if (-not (Test-ExpectedGuestPowerOffJob -Job $job)) { continue }

        try {
            $completion = Complete-ExpectedGuestPowerOffJob -Job $job -JobFile $completedJob.FullName -RecoverySource Completed -OutboxRoot $OutboxRoot
            if ($completion.Deferred) { $expectedDeferred++ }
            elseif ($completion.Completed) { $expectedRecovered++ }
            else { $expectedAlreadyComplete++ }
        }
        catch {
            $recoveryErrors++
            $fallbackId = [IO.Path]::GetFileNameWithoutExtension($completedJob.Name)
            $fallbackOutput = Join-Path $OutboxRoot $fallbackId
            New-Item -ItemType Directory -Force -Path $fallbackOutput | Out-Null
            Write-JsonAtomic -Path (Join-Path $fallbackOutput 'agent-error.json') -Value ([ordered]@{
                Success = $false
                Error = $_.Exception.Message
                ExceptionType = $_.Exception.GetType().FullName
                ScriptStackTrace = $_.ScriptStackTrace
                ExpectedGuestPowerOffRecovery = $true
                ApplicationRelaunchedByHarnessAfterGuestPowerOff = $false
                TimestampUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
    }

    [pscustomobject][ordered]@{
        LegacyJobsRequeued = $legacyRequeued
        ExpectedJobsRecovered = $expectedRecovered
        ExpectedJobsAlreadyComplete = $expectedAlreadyComplete
        ExpectedJobsDeferred = $expectedDeferred
        RecoveryErrors = $recoveryErrors
    }
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexGuestAgent', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    # Ordinary interrupted work keeps the legacy clean-retry behavior. An
    # expected self-power-off is different: the power cycle already stopped
    # the application, so relaunching it would destroy causal evidence and
    # could shut the recovery boot down again. Finalize only its persisted
    # result marker and keep the request-specific output directory intact.
    Repair-InterruptedGuestJobs | Out-Null

    while ($true) {
        Write-AgentState
        foreach ($jobFile in @(Get-ChildItem -LiteralPath $inboxPath -Filter '*.json' -File | Sort-Object LastWriteTimeUtc)) {
            $processingFile = Join-Path $processingPath $jobFile.Name
            try {
                Move-Item -LiteralPath $jobFile.FullName -Destination $processingFile -Force
                $job = Get-Content -Raw -LiteralPath $processingFile | ConvertFrom-Json
                Invoke-GuestJob -Job $job -JobFile $processingFile
            }
            catch {
                $fallbackId = [IO.Path]::GetFileNameWithoutExtension($jobFile.Name)
                $fallbackOutput = Join-Path $outboxPath $fallbackId
                New-Item -ItemType Directory -Force -Path $fallbackOutput | Out-Null
                Write-JsonAtomic -Path (Join-Path $fallbackOutput 'agent-error.json') -Value ([ordered]@{
                    Success = $false
                    Error = $_.Exception.Message
                    ExceptionType = $_.Exception.GetType().FullName
                    ScriptStackTrace = $_.ScriptStackTrace
                    TimestampUtc = [DateTime]::UtcNow.ToString('o')
                })
            }
            finally {
                if (Test-Path -LiteralPath $processingFile) {
                    Move-Item -LiteralPath $processingFile -Destination (Join-Path $completedPath $jobFile.Name) -Force
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
