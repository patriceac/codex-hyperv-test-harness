function Get-InstallerProperty {
    param($Value, [string] $Name)
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    if ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.PSObject.Properties[$Name].Value }
    return $null
}

function Assert-InstallerProperties {
    param($Value, [string[]] $Names, [string] $Context)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [Array]) { throw "$Context must be a JSON object." }
    $actual = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    if ($actual.Count -ne $Names.Count -or @($actual | Where-Object { $_ -cnotin $Names }).Count -gt 0) {
        throw "$Context requires only these exact properties: $($Names -join ', ')."
    }
}

function Assert-InstallerInteger {
    param($Value, [long] $Minimum, [long] $Maximum, [string] $Context)
    if ($null -eq $Value -or $Value.GetType() -notin @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -or
        [decimal]$Value -lt $Minimum -or [decimal]$Value -gt $Maximum) { throw "$Context must be an integer from $Minimum to $Maximum." }
}

function Resolve-InstallerRelativePath {
    param($Value, [string] $Context, [switch] $Executable)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 240 -or
        [IO.Path]::IsPathRooted($Value) -or $Value -match '[:*?"<>|\x00-\x1F]') { throw "$Context must be a bounded relative path." }
    $path = $Value.Replace('/', '\')
    if (@($path.Split('\') | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') -or $_.EndsWith(' ') -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count -gt 0) {
        throw "$Context contains an unsafe path segment."
    }
    if ($Executable -and [IO.Path]::GetExtension($path) -ine '.exe') { throw "$Context must identify an executable." }
    $path
}

function Assert-InstallerManifestIdentity {
    param($Manifest, [string] $Path, $Sha256, [string] $Context)
    if ($Sha256 -isnot [string] -or $Sha256 -cnotmatch '^[A-F0-9]{64}$') { throw "$Context requires an uppercase SHA-256." }
    $matches = @($Manifest.Files | Where-Object { [string]::Equals(([string]$_.RelativePath).Replace('/', '\'), $Path, [StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -ne 1 -or [string]$matches[0].Sha256 -cne $Sha256) { throw "$Context must match exactly one payload-manifest file." }
}

function Resolve-InstallerUacPolicyV2 {
    param($Request, $PayloadManifest)
    $value = Get-InstallerProperty $Request 'InstallerUac'
    if ((Get-InstallerProperty $Request 'Operation') -cne 'RunGuestInstallerV2') {
        if ($null -ne $value) { throw 'InstallerUac requires RunGuestInstallerV2.' }
        return $null
    }
    $requestNames = if ($Request -is [Collections.IDictionary]) { @($Request.Keys) } else { @($Request.PSObject.Properties.Name) }
    if ($requestNames -cnotcontains 'InstallerUac') { throw 'The top-level property must use exact case: InstallerUac.' }
    foreach ($name in @('ResetToBaseline', 'StopAfter')) {
        $flag = Get-InstallerProperty $Request $name
        if ($flag -isnot [bool] -or -not $flag) { throw 'Installer UAC requires ResetToBaseline=true and StopAfter=true.' }
    }
    foreach ($name in @('GuestSetup','SystemPrompts','GuestRestartPlan','GuestCredentialFixture','ExpectGuestPowerOff')) {
        if ($null -ne (Get-InstallerProperty $Request $name)) { throw "Installer UAC cannot be combined with $name." }
    }
    $network = Get-InstallerProperty $Request 'Network'
    if (($network -and (Get-InstallerProperty $network 'Profile') -cne 'None') -or
        @((Get-InstallerProperty $Request 'HostInputs') | Where-Object { $null -ne $_ }).Count -gt 0) {
        throw 'Installer UAC requires disconnected networking and no host inputs.'
    }
    $job = Get-InstallerProperty $Request 'Job'
    foreach($field in @('assertResultFile','assertResultJsonPointer','assertResultEqualsJson','expectGuestPowerOff')) {
        if($null -ne (Get-InstallerProperty $job $field)){throw 'Installer UAC uses its separately bound Before/After verifier only.'}
    }
    if (@((Get-InstallerProperty $job 'actions') | Where-Object { $null -ne $_ }).Count -gt 0) {
        throw 'Installer UAC owns prompt handling and permits no ordinary input or capture actions.'
    }
    Assert-InstallerProperties $value @('FormatVersion','Decision','InitiatingUser','PromptTimeoutSeconds','ExpectedExitCode','ExecutableRelativePath','ExecutableSha256','Verifier','PrivilegedObservations') 'InstallerUac'
    Assert-InstallerInteger $value.FormatVersion 2 2 'InstallerUac.FormatVersion'
    Assert-InstallerInteger $value.PromptTimeoutSeconds 5 600 'InstallerUac.PromptTimeoutSeconds'
    Assert-InstallerInteger $value.ExpectedExitCode -2147483648 2147483647 'InstallerUac.ExpectedExitCode'
    if ($value.Decision -cnotin @('Accept','Decline') -or $value.InitiatingUser -cnotin @('ManagedAdministrator','StandardUser')) { throw 'Installer UAC has an unsupported decision or initiating user.' }
    $image = Resolve-InstallerRelativePath $value.ExecutableRelativePath 'Installer executable' -Executable
    if ([string]$job.executable -ine ('{PAYLOAD}\' + $image)) { throw 'Installer UAC must bind the directly launched job executable.' }
    Assert-InstallerManifestIdentity $PayloadManifest $image $value.ExecutableSha256 'Installer executable'

    $verifier = $value.Verifier
    Assert-InstallerProperties $verifier @('Purpose','ExecutableRelativePath','ExecutableSha256','Arguments','TimeoutSeconds','ResultFile','JsonPointer','EqualsJson') 'Installer verifier'
    if ($verifier.Purpose -cne 'ReadOnlyObservation') { throw 'Installer verifier must declare ReadOnlyObservation.' }
    $verifierImage = Resolve-InstallerRelativePath $verifier.ExecutableRelativePath 'Verifier executable' -Executable
    Assert-InstallerManifestIdentity $PayloadManifest $verifierImage $verifier.ExecutableSha256 'Verifier executable'
    if ($verifierImage -ieq $image) { throw 'The observer must be a separately bound executable.' }
    Assert-InstallerInteger $verifier.TimeoutSeconds 5 300 'Verifier.TimeoutSeconds'
    if ($verifier.Arguments -isnot [Array] -or $verifier.Arguments.Count -gt 24) { throw 'Verifier.Arguments must be an array of at most 24 strings.' }
    $argumentLength = 0
    foreach ($argument in $verifier.Arguments) {
        if ($argument -isnot [string] -or $argument.Length -gt 2048 -or $argument -match '[\x00\r\n]') { throw 'Verifier arguments must be bounded strings without NUL or newlines.' }
        foreach ($token in [regex]::Matches($argument, '\{[^{}]*\}')) {
            if ($token.Value -cnotin @('{PAYLOAD}','{PHASE}','{IDENTITY_FILE}','{VERIFIER_OUTDIR}')) { throw 'Verifier argument contains an unsupported token.' }
        }
        $argumentLength += $argument.Length
    }
    if ($argumentLength -gt 8192) { throw 'Verifier arguments exceed the total bound.' }
    $resultFile = Resolve-InstallerRelativePath $verifier.ResultFile 'Verifier.ResultFile'
    if ($resultFile.Contains('\') -or [IO.Path]::GetExtension($resultFile) -ine '.json') { throw 'Verifier.ResultFile must be one JSON filename.' }
    if ($verifier.JsonPointer -isnot [string] -or ($verifier.JsonPointer -ne '' -and -not $verifier.JsonPointer.StartsWith('/')) -or $verifier.JsonPointer -match '~(?![01])') { throw 'Verifier.JsonPointer is invalid.' }
    if ($value.PrivilegedObservations -isnot [Array] -or $value.PrivilegedObservations.Count -gt 32) { throw 'PrivilegedObservations must be an array of at most 32 paths.' }
    $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($observation in $value.PrivilegedObservations) {
        Assert-InstallerProperties $observation @('Name','Root','RelativePath') 'Privileged observation'
        if ($observation.Name -isnot [string] -or $observation.Name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$' -or -not $names.Add($observation.Name)) { throw 'Privileged observation names must be unique bounded identifiers.' }
        if ($observation.Root -cnotin @('InitiatorProfile','AdministratorProfile','ProgramData','ProgramFiles')) { throw 'Privileged observation root is unsupported.' }
        if ($observation.Root -ceq 'AdministratorProfile' -and $value.InitiatingUser -cne 'StandardUser') { throw 'A separate administrator profile exists only for StandardUser.' }
        $relative = Resolve-InstallerRelativePath $observation.RelativePath 'Privileged observation path'
        if ($observation.Root -ceq 'ProgramData' -and $relative.Split('\')[0] -ieq 'CodexHarness') { throw 'Harness private state cannot be observed by a product verifier.' }
    }
    # Normalize only validated paths; all authority stays in the versioned request.
    $normalized = $value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $normalized.ExecutableRelativePath = $image
    $normalized.Verifier.ExecutableRelativePath = $verifierImage
    $normalized.Verifier.ResultFile = $resultFile
    $normalized
}

function Test-InstallerUacReceipt {
    param($Receipt,$Policy,[string]$RequestId)
    try {
        foreach($flag in @('ContractProven','CleanupSucceeded')){if($Receipt.$flag -isnot [bool] -or -not $Receipt.$flag){return $false}}
        if($Receipt.FormatVersion -ne 2 -or $Receipt.RequestId -cne $RequestId -or $Receipt.Decision -cne $Policy.Decision -or
            $Receipt.InitiatingUser -cne $Policy.InitiatingUser -or $Receipt.ExecutableSha256 -cne $Policy.ExecutableSha256 -or
            $Receipt.VerifierSha256 -cne $Policy.Verifier.ExecutableSha256 -or $Receipt.Input.Success -isnot [bool] -or -not $Receipt.Input.Success -or $Receipt.Input.Decision -cne $Policy.Decision){return $false}
        $sid=$Receipt.Identity.Initiator.Sid
        foreach($phase in @('Before','After')){
            $record=$Receipt.$phase
            if($record.Phase -cne $phase -or $record.Process.UserSid -cne $sid -or $record.Process.Elevated -isnot [bool] -or $record.Process.Elevated -or
                $record.Process.IntegrityRid -ne 8192 -or $record.Passed -isnot [bool] -or
                [DateTimeOffset]::Parse($record.CompletedUtc) -ge [DateTimeOffset]::Parse($Receipt.CleanupStartedUtc)){return $false}
        }
        if([DateTimeOffset]::Parse($Receipt.Before.CompletedUtc) -ge [DateTimeOffset]::Parse($Receipt.After.CompletedUtc)){return $false}
        $prompt=$Receipt.Prompt
        if($prompt.Event.RequestorProcessId -ne $prompt.Requester.ProcessId -or $prompt.Event.EmitterProcessId -ne $prompt.Consent.ProcessId -or
            $prompt.Root.UserSid -cne $sid -or $prompt.Root.Elevated -or $prompt.Root.IntegrityRid -ne 8192 -or
            $prompt.Root.SessionId -ne $Receipt.Before.Process.SessionId -or $prompt.Root.SessionId -ne $Receipt.After.Process.SessionId){return $false}
        if($Policy.InitiatingUser -ceq 'StandardUser' -and ($prompt.Root.AdministratorGroup -or $Receipt.Before.Process.AdministratorGroup -or $Receipt.After.Process.AdministratorGroup -or
            $sid -ceq $Receipt.Identity.ElevationAccount.Sid)){return $false}
        if($Policy.Decision -ceq 'Decline'){return @($Receipt.ElevatedProcess).Count -eq 0 -and -not $Receipt.Input.CredentialEntered}
        $high=@($Receipt.ElevatedProcess)
        if($high.Count -ne 1 -or $high[0].UserSid -cne $Receipt.Identity.ElevationAccount.Sid -or -not $high[0].Elevated -or
            $high[0].IntegrityRid -lt 12288 -or $high[0].SessionId -ne $prompt.Root.SessionId -or $high[0].ProcessId -eq $prompt.Root.ProcessId -or
            $high[0].ImagePath -ine $prompt.Root.ImagePath){return $false}
        if($Policy.InitiatingUser -ceq 'StandardUser' -and -not $Receipt.Input.CredentialEntered){return $false}
        return $true
    } catch {return $false}
}
