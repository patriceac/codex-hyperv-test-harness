# Shared by the unprivileged runner and SYSTEM broker. No host/guest side effects.
function Assert-PowerTestFields {
    param($Value, [string[]] $Required, [string[]] $Optional = @())
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [Array]) { throw 'Power-test objects must be JSON objects.' }
    $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) { if (($Required + $Optional) -cnotcontains $name) { throw "Unsupported power-test property: $name" } }
    foreach ($name in $Required) { if ($names -cnotcontains $name) { throw "Missing power-test property: $name" } }
}

function Assert-PowerTestInteger {
    param($Value, [long] $Minimum, [long] $Maximum)
    if ($null -eq $Value -or $Value.GetType() -notin @([int], [long], [int16], [byte], [uint32], [uint64]) -or
        $Value -lt $Minimum -or $Value -gt $Maximum) { throw "Power-test integer must be between $Minimum and $Maximum." }
}

function Resolve-GuestRestartPlan {
    param($Plan, $PayloadManifest, [bool] $CredentialFixture = $false)
    Assert-PowerTestFields $Plan @('FormatVersion', 'Boots')
    Assert-PowerTestInteger $Plan.FormatVersion 1 1
    if ($Plan.Boots -isnot [Array] -or $Plan.Boots.Count -lt 1 -or $Plan.Boots.Count -gt 4) { throw 'GuestRestartPlan requires one to four Boots.' }
    $markerPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($boot in $Plan.Boots) {
        Assert-PowerTestFields $boot @('ExpectedSignIn', 'BootTimeoutSeconds', 'SignedOutObservationSeconds', 'BeforeRestart', 'Continuation')
        if ($boot.ExpectedSignIn -cnotin @('Automatic', 'Manual')) { throw 'ExpectedSignIn must be Automatic or Manual.' }
        Assert-PowerTestInteger $boot.BootTimeoutSeconds 30 900
        Assert-PowerTestInteger $boot.SignedOutObservationSeconds 0 3900
        if (($boot.ExpectedSignIn -ceq 'Manual' -and $boot.SignedOutObservationSeconds -lt 10) -or
            ($boot.ExpectedSignIn -ceq 'Automatic' -and $boot.SignedOutObservationSeconds -ne 0)) { throw 'Manual sign-in requires at least ten signed-out seconds; Automatic requires zero.' }
        $marker = $boot.BeforeRestart
        Assert-PowerTestFields $marker @('ResultFile', 'JsonPointer', 'EqualsJson')
        if ($marker.ResultFile -isnot [string] -or $marker.ResultFile -cnotmatch '^\{OUTDIR\}\\[A-Za-z0-9][A-Za-z0-9_.-]{0,100}\.json$' -or
            $marker.ResultFile -match '\\(result|lease|agent-error)\.json$' -or -not $markerPaths.Add($marker.ResultFile)) { throw 'BeforeRestart requires a distinct JSON leaf under {OUTDIR}, outside reserved protocol files.' }
        if ($marker.JsonPointer -isnot [string] -or ($marker.JsonPointer -ne '' -and -not $marker.JsonPointer.StartsWith('/')) -or $marker.JsonPointer -match '~(?![01])') { throw 'Invalid BeforeRestart JSON pointer.' }
        if ($marker.EqualsJson -isnot [string] -or $marker.EqualsJson.Length -gt 4096) { throw 'BeforeRestart EqualsJson must be a bounded JSON string.' }
        $null = ('{"value":' + $marker.EqualsJson + '}') | ConvertFrom-Json -ErrorAction Stop
        $step = $boot.Continuation
        Assert-PowerTestFields $step @('ExecutableRelativePath', 'ExecutableSha256', 'Arguments', 'Actions')
        if ($step.ExecutableRelativePath -isnot [string] -or $step.ExecutableRelativePath -match '(^[\\/]|:|(^|[\\/])\.{0,2}([\\/]|$)|[\x00-\x1f*?"<>|]|[. ]([\\/]|$))' -or
            $step.ExecutableRelativePath -notmatch '\.exe$' -or $step.ExecutableRelativePath.Length -gt 240) { throw 'Continuation executable must be a traversal-free relative .exe path.' }
        if ($step.ExecutableSha256 -isnot [string] -or $step.ExecutableSha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Continuation executable requires an exact uppercase SHA-256.' }
        $match = @($PayloadManifest.Files | Where-Object { ([string]$_.RelativePath).Replace('/', '\') -ieq $step.ExecutableRelativePath.Replace('/', '\') })
        if ($match.Count -ne 1 -or $match[0].Sha256 -cne $step.ExecutableSha256) { throw 'Continuation executable does not match exactly one canonical payload-manifest file.' }
        if ($step.Arguments -isnot [string] -or $step.Arguments.Length -gt 8192 -or $step.Arguments -match '[\x00\r\n]') { throw 'Continuation Arguments must be a bounded command-line string.' }
        if ($step.Actions -isnot [Array] -or $step.Actions.Count -gt 64) { throw 'Continuation Actions must be an array of at most 64 actions.' }
        foreach ($value in @($step.Arguments) + @($step.Actions | ConvertTo-Json -Depth 10 -Compress)) {
            foreach ($token in [regex]::Matches($value, '\{([A-Z][A-Z0-9_:.-]*)\}')) {
                if ($token.Value -cnotin @('{PAYLOAD}', '{OUTDIR}') -and -not ($CredentialFixture -and $token.Value -ceq '{GUEST_CREDENTIAL_FILE}')) { throw "Unsupported continuation token: $($token.Value)" }
            }
        }
    }
    $Plan
}

function Resolve-GuestPowerTestPolicy {
    param($Request, $PayloadManifest)
    $names = @($Request.PSObject.Properties.Name)
    foreach ($name in @('GuestRestartPlan', 'GuestCredentialFixture')) {
        if ($names -contains $name -and $names -cnotcontains $name) { throw "Power-test property must use exact case: $name" }
    }
    $hasPlan = $names -contains 'GuestRestartPlan'
    $hasFixture = $names -contains 'GuestCredentialFixture'
    foreach ($name in @('restartRequestId', 'restartPhase', 'awaitGuestRestart')) { if (@($Request.Job.PSObject.Properties.Name) -contains $name) { throw 'Restart phase fields are broker-owned.' } }
    if ($Request.Operation -cne 'RunGuestJobPowerTestV1') {
        if ($hasPlan -or $hasFixture) { throw 'Power-test options require RunGuestJobPowerTestV1.' }
        return $null
    }
    if (-not ($hasPlan -or $hasFixture)) { throw 'Power-test operation requires a restart plan or credential fixture.' }
    if ($hasFixture -and ($Request.GuestCredentialFixture -isnot [bool] -or -not $Request.GuestCredentialFixture)) { throw 'GuestCredentialFixture must be exact Boolean true.' }
    foreach ($flag in @('ResetToBaseline', 'StopAfter')) { if ($Request.$flag -isnot [bool] -or -not $Request.$flag) { throw "Power tests require $flag=true." } }
    if ($Request.ExpectGuestPowerOff -or $Request.SystemPrompts -or @($Request.HostInputs).Count -gt 0 -or $Request.Network.Profile -notin @('None', 'IsolatedTestNet')) { throw 'Power tests permit only None or IsolatedTestNet, without host inputs, system prompts, or expected power-off.' }
    $plan = if ($hasPlan) { Resolve-GuestRestartPlan $Request.GuestRestartPlan $PayloadManifest ([bool]$hasFixture) } else { $null }
    [pscustomobject]@{ Plan = $plan; CredentialFixture = [bool]$hasFixture }
}
