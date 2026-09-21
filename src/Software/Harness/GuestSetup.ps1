function Get-GuestSetupPropertyNames {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys | ForEach-Object { [string]$_ }) }
    @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-GuestSetupPropertyValue {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $result = $Value[$Name]
        if ($null -eq $result) { return $null }
        Write-Output -NoEnumerate $result
        return
    }
    $property = $Value.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $null }
    Write-Output -NoEnumerate $property.Value
}

function ConvertTo-GuestSetupRelativePath {
    param([Parameter(Mandatory = $true)] [string] $Value)

    $normalized = $Value.Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -cne $normalized.Trim() -or
        $normalized.Length -gt 240 -or [IO.Path]::IsPathRooted($normalized) -or
        $normalized.IndexOfAny([char[]](':*?"<>|' + [string][char]0)) -ge 0 -or $normalized -match '[\x00-\x1F]') {
        throw 'GuestSetup ExecutableRelativePath must be a traversal-free relative Windows path of at most 240 characters.'
    }
    $segments = @($normalized.Split('\'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object {
        $_ -in @('', '.', '..') -or $_.EndsWith('.') -or $_.EndsWith(' ')
    }).Count -gt 0) {
        throw 'GuestSetup ExecutableRelativePath contains an empty, traversal, or trailing-dot/space segment.'
    }
    if (-not [string]::Equals([IO.Path]::GetExtension($normalized), '.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'GuestSetup ExecutableRelativePath must identify an executable file.'
    }
    $normalized
}

function Resolve-GuestSetupPolicyV1 {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [AllowNull()] $PayloadManifest
    )

    $operation = [string](Get-GuestSetupPropertyValue -Value $Request -Name 'Operation')
    $profile = Get-GuestSetupPropertyValue -Value $Request -Name 'GuestSetup'
    $exactProperty = @(Get-GuestSetupPropertyNames -Value $Request | Where-Object { $_ -ceq 'GuestSetup' }) | Select-Object -First 1
    if ($null -ne $profile -and -not $exactProperty) {
        throw 'The top-level guest-setup property name must use exact case: GuestSetup.'
    }
    $supportedOperations = @('RunGuestJobSetupV1', 'RunGuestJobSetupSystemPromptsV1', 'RunGuestJobPowerTestV1')
    if ($operation -notin $supportedOperations) {
        if ($null -ne $profile) { throw 'GuestSetup requires the versioned guest-setup operation.' }
        return $null
    }
    if ($null -eq $profile) {
        if ($operation -eq 'RunGuestJobPowerTestV1') { return $null }
        throw "$operation requires GuestSetup."
    }
    $systemPrompts = Get-GuestSetupPropertyValue -Value $Request -Name 'SystemPrompts'
    if ($operation -eq 'RunGuestJobSetupSystemPromptsV1' -and $null -eq $systemPrompts) {
        throw 'RunGuestJobSetupSystemPromptsV1 requires SystemPrompts.'
    }
    if ($operation -eq 'RunGuestJobSetupV1' -and $null -ne $systemPrompts) {
        throw 'Guest setup and system prompts require RunGuestJobSetupSystemPromptsV1.'
    }
    if ($null -eq $PayloadManifest) { throw 'GuestSetup requires a canonical application payload manifest.' }

    $allowed = @('FormatVersion', 'ExecutableRelativePath', 'ExecutableSha256', 'Arguments', 'TimeoutSeconds')
    $names = @(Get-GuestSetupPropertyNames -Value $profile)
    $unexpected = @($names | Where-Object { $_ -notin $allowed })
    if ($unexpected.Count -gt 0) { throw ('GuestSetup contains unsupported properties: ' + ($unexpected -join ', ')) }
    foreach ($required in $allowed) {
        if ($names -cnotcontains $required) { throw "GuestSetup is missing the exact $required property." }
    }

    $integralTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $formatVersion = Get-GuestSetupPropertyValue -Value $profile -Name 'FormatVersion'
    $timeoutSeconds = Get-GuestSetupPropertyValue -Value $profile -Name 'TimeoutSeconds'
    if ($null -eq $formatVersion -or $formatVersion.GetType() -notin $integralTypes -or [int64]$formatVersion -ne 1) {
        throw 'GuestSetup FormatVersion must be exact integer 1.'
    }
    if ($null -eq $timeoutSeconds -or $timeoutSeconds.GetType() -notin $integralTypes -or
        [int64]$timeoutSeconds -lt 5 -or [int64]$timeoutSeconds -gt 600) {
        throw 'GuestSetup TimeoutSeconds must be an integer between 5 and 600.'
    }

    $relativePath = ConvertTo-GuestSetupRelativePath -Value ([string](Get-GuestSetupPropertyValue -Value $profile -Name 'ExecutableRelativePath'))
    $expectedSha256 = [string](Get-GuestSetupPropertyValue -Value $profile -Name 'ExecutableSha256')
    if ($expectedSha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'GuestSetup ExecutableSha256 must be an uppercase exact SHA-256 hash.' }

    $argumentsValue = Get-GuestSetupPropertyValue -Value $profile -Name 'Arguments'
    if ($null -eq $argumentsValue -or $argumentsValue -is [string] -or $argumentsValue -isnot [Array]) {
        throw 'GuestSetup Arguments must be a JSON array.'
    }
    $arguments = @($argumentsValue)
    if ($arguments.Count -gt 16) { throw 'GuestSetup accepts at most 16 arguments.' }
    $totalArgumentLength = 0
    foreach ($argument in $arguments) {
        if ($argument -isnot [string] -or $argument.Length -gt 1024 -or $argument -match '[\x00\r\n]') {
            throw 'Each GuestSetup argument must be a string of at most 1024 characters without NUL or line breaks.'
        }
        $totalArgumentLength += $argument.Length
    }
    if ($totalArgumentLength -gt 4096) { throw 'GuestSetup arguments exceed the 4096-character aggregate limit.' }

    $manifestMatch = @($PayloadManifest.Files | Where-Object {
        [string]::Equals(([string]$_.RelativePath).Replace('/', '\'), $relativePath, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($manifestMatch.Count -ne 1 -or -not [string]::Equals([string]$manifestMatch[0].Sha256, $expectedSha256, [StringComparison]::Ordinal)) {
        throw 'GuestSetup executable identity does not exactly match one payload-manifest file.'
    }

    [pscustomobject][ordered]@{
        FormatVersion = 1
        ExecutableRelativePath = $relativePath
        ExecutableSha256 = $expectedSha256
        Arguments = @($arguments)
        TimeoutSeconds = [int]$timeoutSeconds
        EvidenceFileName = 'guest-setup.json'
    }
}

function Invoke-GuestSetupV1 {
    param(
        [Parameter(Mandatory = $true)] [Management.Automation.Runspaces.PSSession] $Session,
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)] [string] $GuestPayloadRoot,
        [Parameter(Mandatory = $true)] [string] $GuestSetupRoot,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z')] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc,
        [scriptblock] $ActivityCheck
    )

    $remainingSeconds = [int][Math]::Floor(($ExecutionDeadlineUtc.ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds)
    if ($remainingSeconds -lt 5) { throw 'GuestSetup has insufficient request time remaining.' }
    $guestTimeoutSeconds = [Math]::Min([int]$Policy.TimeoutSeconds, $remainingSeconds)
    $guestOperation = {
        param(
            [string] $PayloadRoot,
            [string] $RelativePath,
            [string] $ExpectedSha256,
            [string] $ArgumentsJson,
            [int] $TimeoutSeconds,
            [string] $SetupRoot,
            [string] $RequestId,
            [string] $EvidenceFileName
        )

        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest

        function Get-FixedSha256([string] $Path) {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $hash = [Security.Cryptography.SHA256]::Create()
                try { ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '') }
                finally { $hash.Dispose() }
            }
            finally { $stream.Dispose() }
        }

        function ConvertTo-WindowsArgument([string] $Value) {
            if ($Value.Length -eq 0) { return '""' }
            if ($Value -notmatch '[\s"]') { return $Value }
            $builder = [Text.StringBuilder]::new()
            $null = $builder.Append('"')
            $slashes = 0
            foreach ($character in $Value.ToCharArray()) {
                if ($character -eq '\') { $slashes++; continue }
                if ($character -eq '"') {
                    $null = $builder.Append([string]::new([char]'\', (($slashes * 2) + 1)))
                    $null = $builder.Append('"')
                    $slashes = 0
                    continue
                }
                if ($slashes -gt 0) { $null = $builder.Append([string]::new([char]'\', $slashes)); $slashes = 0 }
                $null = $builder.Append($character)
            }
            if ($slashes -gt 0) { $null = $builder.Append([string]::new([char]'\', ($slashes * 2))) }
            $null = $builder.Append('"')
            $builder.ToString()
        }

        function Set-SetupAcl([string] $Path) {
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            foreach ($entry in @(
                @{ Sid = 'S-1-5-18'; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid = 'S-1-5-32-544'; Rights = [Security.AccessControl.FileSystemRights]::FullControl },
                @{ Sid = 'S-1-5-32-545'; Rights = [Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize' }
            )) {
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new([string]$entry.Sid),
                    $entry.Rights,
                    [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [Security.AccessControl.PropagationFlags]::None,
                    [Security.AccessControl.AccessControlType]::Allow)
                $null = $acl.AddAccessRule($rule)
            }
            [IO.Directory]::SetAccessControl($Path, $acl)
        }

        $argumentsValue = ConvertFrom-Json -InputObject $ArgumentsJson -ErrorAction Stop
        $Arguments = @($argumentsValue)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'GuestSetup requires the administrator Hyper-V Direct session.'
        }
        $payload = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
        $source = [IO.Path]::GetFullPath((Join-Path $payload $RelativePath))
        if (-not $source.StartsWith($payload + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw 'GuestSetup executable escaped or is missing from the mounted payload.'
        }
        for ($cursor = Get-Item -LiteralPath $source -Force; $cursor -and
            -not [string]::Equals([IO.Path]::GetFullPath($cursor.FullName).TrimEnd('\'), $payload, [StringComparison]::OrdinalIgnoreCase);
            $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }) {
            if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'GuestSetup executable path traverses a reparse point.'
            }
        }
        $sourceSha256 = Get-FixedSha256 -Path $source
        if (-not [string]::Equals($sourceSha256, $ExpectedSha256, [StringComparison]::Ordinal)) {
            throw 'GuestSetup mounted executable differs from the request-bound SHA-256.'
        }
        $setupParent = Split-Path -Parent $SetupRoot
        if (-not (Test-Path -LiteralPath $setupParent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $setupParent -Force
        }
        Set-SetupAcl -Path $setupParent
        if (Test-Path -LiteralPath $SetupRoot) { throw 'GuestSetup refuses to reuse an existing request directory.' }
        $null = New-Item -ItemType Directory -Path $SetupRoot
        Set-SetupAcl -Path $SetupRoot
        $stageRoot = Join-Path $SetupRoot 'stage'
        $null = New-Item -ItemType Directory -Path $stageRoot
        $stagedExecutable = Join-Path $stageRoot ([IO.Path]::GetFileName($RelativePath))
        $input = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $output = [IO.File]::Open($stagedExecutable, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output); $output.Flush($true) }
            finally { $output.Dispose() }
        }
        finally { $input.Dispose() }
        $stagedSha256 = Get-FixedSha256 -Path $stagedExecutable
        if (-not [string]::Equals($stagedSha256, $ExpectedSha256, [StringComparison]::Ordinal)) {
            throw 'GuestSetup staged executable differs from the request-bound SHA-256.'
        }

        $startedUtc = [DateTime]::UtcNow
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $stagedExecutable
        $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) }) -join ' ')
        $start.WorkingDirectory = $stageRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        if ($null -eq $process) { throw 'GuestSetup could not start the request-bound executable.' }
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.Id /T /F 2>$null | Out-Null
                throw "GuestSetup exceeded its $TimeoutSeconds-second timeout."
            }
            $process.WaitForExit()
            $stdout = [string]$stdoutTask.Result
            $stderr = [string]$stderrTask.Result
            $stdoutTruncated = $stdout.Length -gt 65536
            $stderrTruncated = $stderr.Length -gt 65536
            if ($stdoutTruncated) { $stdout = $stdout.Substring(0, 65536) }
            if ($stderrTruncated) { $stderr = $stderr.Substring(0, 65536) }
            $completedUtc = [DateTime]::UtcNow
            $evidence = [ordered]@{
                FormatVersion = 1
                Contract = 'GuestSetupV1'
                RequestId = $RequestId
                ExecutableRelativePath = $RelativePath
                ExecutableSha256 = $ExpectedSha256
                StagedExecutablePath = $stagedExecutable
                StagedExecutableSha256 = $stagedSha256
                Arguments = @($Arguments | ForEach-Object { [string]$_ })
                TimeoutSeconds = $TimeoutSeconds
                ProcessId = [int]$process.Id
                StartedUtc = $startedUtc.ToString('o')
                CompletedUtc = $completedUtc.ToString('o')
                ExitCode = [int]$process.ExitCode
                Identity = [ordered]@{
                    Name = [string]$identity.Name
                    UserSid = [string]$identity.User.Value
                    IsAdministrator = $true
                }
                Stdout = $stdout
                Stderr = $stderr
                OutputTruncated = [ordered]@{ Stdout = $stdoutTruncated; Stderr = $stderrTruncated }
                Succeeded = [bool]($process.ExitCode -eq 0)
            }
            $evidencePath = Join-Path $SetupRoot $EvidenceFileName
            $temporaryEvidencePath = $evidencePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
            try {
                [IO.File]::WriteAllText($temporaryEvidencePath, ($evidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
                [IO.File]::Move($temporaryEvidencePath, $evidencePath)
            }
            finally { if (Test-Path -LiteralPath $temporaryEvidencePath) { Remove-Item -LiteralPath $temporaryEvidencePath -Force } }
            [pscustomobject]$evidence
        }
        finally { $process.Dispose() }
    }

    $remoteJob = $null
    try {
        $argumentsJson = ConvertTo-Json -Compress -InputObject @($Policy.Arguments)
        $remoteJob = Invoke-Command -Session $Session -ScriptBlock $guestOperation -ArgumentList @(
            [IO.Path]::GetFullPath($GuestPayloadRoot),
            [string]$Policy.ExecutableRelativePath,
            [string]$Policy.ExecutableSha256,
            $argumentsJson,
            $guestTimeoutSeconds,
            [IO.Path]::GetFullPath($GuestSetupRoot),
            $RequestId,
            [string]$Policy.EvidenceFileName
        ) -AsJob -ErrorAction Stop
        while ([string]$remoteJob.State -in @('NotStarted', 'Running')) {
            if ($ActivityCheck) { & $ActivityCheck }
            if ([DateTime]::UtcNow -ge $ExecutionDeadlineUtc.ToUniversalTime()) {
                Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue
                throw 'GuestSetup exceeded the request execution deadline.'
            }
            Wait-Job -Job $remoteJob -Timeout 1 | Out-Null
        }
        if ([string]$remoteJob.State -ne 'Completed') {
            $reason = if ($remoteJob.ChildJobs.Count -gt 0 -and $remoteJob.ChildJobs[0].JobStateInfo.Reason) {
                [string]$remoteJob.ChildJobs[0].JobStateInfo.Reason.Message
            }
            else { "Remote job entered state $($remoteJob.State)." }
            throw "GuestSetup failed: $reason"
        }
        $results = @(Receive-Job -Job $remoteJob -ErrorAction Stop | Where-Object {
            $_ -and $_.PSObject.Properties['Contract'] -and [string]$_.Contract -eq 'GuestSetupV1'
        })
        if ($results.Count -ne 1) { throw 'GuestSetup returned no normalized evidence.' }
        $evidence = $results[0]
        if ([int]$evidence.FormatVersion -ne 1 -or $evidence.Succeeded -isnot [bool] -or
            [bool]$evidence.Succeeded -ne ([int]$evidence.ExitCode -eq 0) -or
            -not [string]::Equals([string]$evidence.RequestId, $RequestId, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$evidence.ExecutableRelativePath, [string]$Policy.ExecutableRelativePath, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$evidence.ExecutableSha256, [string]$Policy.ExecutableSha256, [StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$evidence.StagedExecutableSha256, [string]$Policy.ExecutableSha256, [StringComparison]::Ordinal) -or
            -not [bool]$evidence.Identity.IsAdministrator) {
            throw 'GuestSetup evidence does not match the request-bound executable identity and elevated execution contract.'
        }
        $evidence
    }
    finally {
        if ($remoteJob) {
            if ([string]$remoteJob.State -in @('NotStarted', 'Running')) { Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue }
            Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
        }
    }
}
