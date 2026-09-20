[CmdletBinding()]
param([string] $SourceRoot)
$ErrorActionPreference = 'Stop'
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$tokens = $null; $parseIssues = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'HostBroker.ps1'), [ref]$tokens, [ref]$parseIssues)
if ($parseIssues.Count) { throw $parseIssues[0].Message }
foreach ($name in @('Wait-GuestSession', 'Test-GuestSessionBootIdentity')) {
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$probePath = Join-Path ([IO.Path]::GetTempPath()) ('codex-readiness-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probePath | Out-Null
$script:stopped = 0
$script:mode = 'Ready'
function Assert-RequestActive {
    param($RequestId, $ExecutionDeadlineUtc)
    if ($script:stopped -ge $(if ($script:mode -eq 'TransientAuthentication') { 2 } else { 1 })) { throw [TimeoutException]::new('Synthetic overall deadline.') }
}
function Write-BrokerState { param($Status, $RequestId, $Message) }
function Stop-GuestProbeProcess { param($Process, $LeasePath) $script:stopped++ }
function Start-GuestSessionProbe {
    param($VmName, $OutputPath)
    if ($script:mode -ne 'Hung') {
        $state = @{Ready=$true;UserInteractive=$true;HeartbeatUtc=[DateTime]::UtcNow.ToString('o');GuestAccountPolicyHealthy=($script:mode -ne 'AccountPolicy')}
        if ($script:mode -eq 'Stale') { $state.HeartbeatUtc = [DateTime]::UtcNow.AddDays(-1).ToString('o') }
        $authenticationFailed = $script:mode -eq 'Authentication' -or ($script:mode -eq 'TransientAuthentication' -and $script:stopped -eq 0)
        @{Success=(-not $authenticationFailed);State=$state;Error='The credential is invalid.';ErrorFullyQualifiedId='PSSessionStateBroken';AuthenticationFailed=$authenticationFailed} |
            ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    $process = [pscustomobject]@{HasExited=($script:mode -ne 'Hung');ExitCode=0}
    $process | Add-Member ScriptMethod Refresh {}
    [pscustomobject]@{Process=$process;LeasePath=$OutputPath+'.process.json'}
}
$credential = New-Object Management.Automation.PSCredential('Synthetic', (ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
$scenarios = @()
try {
    foreach ($case in @('Ready', 'Authentication', 'TransientAuthentication', 'AccountPolicy', 'Stale', 'Hung')) {
        $script:mode = $case; $script:stopped = 0; $failure = $null
        $started = [DateTime]::UtcNow
        try { $result = Wait-GuestSession -VmName 'Synthetic' -Credential $credential -NotBeforeUtc $started -RequestId 'synthetic' -ExecutionDeadlineUtc $started.AddMinutes(4) -ProbeTimeoutSeconds 1 }
        catch { $failure = $_.Exception }
        if ($case -in @('Ready','TransientAuthentication')) { Assert-True ($null -eq $failure -and $result.Ready) 'Fresh interactive readiness was rejected after a recoverable boot-time probe.' }
        elseif ($case -eq 'Authentication') { Assert-True ($failure -is [Security.Authentication.AuthenticationException] -and $failure.Message -like 'GuestAuthenticationFailed:*') 'Invalid credentials were hidden as a generic timeout.' }
        elseif ($case -eq 'AccountPolicy') { Assert-True ($failure -is [Security.Authentication.AuthenticationException] -and $failure.Message -like 'GuestAccountPolicyInvalid:*') 'An expiring automation account was accepted.' }
        elseif ($case -eq 'Stale') { Assert-True ($failure -is [TimeoutException] -and $failure.Message -like '*stale heartbeat*') 'Stale readiness lost its diagnostic or was accepted.' }
        else { Assert-True ($failure -is [TimeoutException] -and $failure.Message -like '*probe exceeded 1 seconds*' -and ([DateTime]::UtcNow-$started).TotalSeconds -lt 5) 'A hung probe consumed the overall readiness budget.' }
        $expectedProbes = if ($case -eq 'TransientAuthentication') { 2 } else { 1 }
        Assert-True ($script:stopped -eq $expectedProbes -and @(Get-ChildItem -LiteralPath $probePath -File).Count -eq 0) 'Probe process/output cleanup did not run.'
        $scenarios += $case
    }
    . (Join-Path $SourceRoot 'PoolCommon.ps1')
    $patch = New-PoolFaultStatePatch -State ([pscustomobject]@{WorkerId=1}) -Config ([pscustomobject]@{}) -ErrorMessage 'GuestAuthenticationFailed: synthetic' -FailureUtc ([DateTime]::UtcNow)
    Assert-True (([DateTime]::Parse($patch.FaultRecoveryNotBeforeUtc)-[DateTime]::Parse($patch.LastFailureUtc)).TotalSeconds -eq 600 -and $patch.LastFailureReason -eq $patch.LastError) 'An account failure was retried aggressively or lost its diagnostic.'
    $scenarios += 'AccountFailureBackoff'
    foreach ($path in @('seed\guest\Install-GuestHarness.ps1', 'Update-GuestHarnessBaseline.ps1')) {
        $content = Get-Content -LiteralPath (Join-Path $SourceRoot $path) -Raw
        Assert-True ($content.Contains('Set-LocalUser -PasswordNeverExpires $true -AccountNeverExpires')) "Guest account expiry protection is absent from $path."
    }
    $scenarios += 'ProvisioningAndBaselineAccountPolicy'
} finally {
    $resolved = [IO.Path]::GetFullPath($probePath)
    if ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'codex-readiness-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
[pscustomobject]@{Success=$true;ScenarioCount=$scenarios.Count;Scenarios=$scenarios} | ConvertTo-Json -Depth 5
