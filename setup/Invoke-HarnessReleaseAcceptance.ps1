[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [string] $EvidenceRoot,
    [string] $ClientSid,
    [switch] $InvocationPreflightOnly
)

$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) { throw 'InstallRoot must be a specific non-root directory.' }

function New-HarnessReleaseAcceptanceInvocations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $SoftwareRoot,
        [Parameter(Mandatory = $true)] [string] $BrokerRoot
    )

    $canaryRoot = Join-Path $SoftwareRoot 'Canaries'
    @(
        [pscustomobject][ordered]@{
            Name = 'LegacyLaunch'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'PoolCanary.exe'
                ActionsPath = Join-Path $canaryRoot 'smoke-actions.json'
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        },
        [pscustomobject][ordered]@{
            Name = 'KeyboardInput'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'HarnessContractCanary.exe'
                Arguments = '--result "{OUTDIR}\keyboard-result.json" --delay-ms 2500 --stay-ms 6500'
                ActionsPath = Join-Path $canaryRoot 'release-keyboard-actions.json'
                AssertResultFile = '{OUTDIR}\keyboard-result.json'
                AssertResultJsonPointer = '/passed'
                AssertResultEqualsJson = 'true'
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        },
        [pscustomobject][ordered]@{
            Name = 'ExpectedGuestPowerOff'
            Parameters = @{
                ArtifactPath = Join-Path $canaryRoot 'ShutdownProbe.exe'
                Arguments = '--marker "{OUTDIR}\shutdown-marker.json" --delay-ms 3000'
                AssertResultFile = '{OUTDIR}\shutdown-marker.json'
                AssertResultJsonPointer = '/passed'
                AssertResultEqualsJson = 'true'
                ExpectGuestPowerOff = $true
                GuestPowerOffRecoveryTimeoutSeconds = 180
                BrokerRoot = $BrokerRoot
                QueueTimeoutSeconds = 900
                ExecutionTimeoutSeconds = 300
                ThrowOnFailure = $true
            }
        }
    )
}

if ($InvocationPreflightOnly) {
    $preview = @(New-HarnessReleaseAcceptanceInvocations -SoftwareRoot (Join-Path $InstallRoot 'Software') -BrokerRoot (Join-Path $InstallRoot 'Live\Broker'))
    [pscustomobject][ordered]@{
        Success = $preview.Count -eq 3
        NoMutationPerformed = $true
        TestNames = @($preview.Name)
        Invocations = $preview
    }
    return
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator rights are required for release acceptance.'
}
if ([string]::IsNullOrWhiteSpace($ClientSid)) { $ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try { [void][Security.Principal.SecurityIdentifier]::new($ClientSid) } catch { throw "Invalid client SID: $ClientSid" }

$configPath = Join-Path $InstallRoot 'Software\harness-config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Harness configuration is missing: $configPath" }
. (Join-Path $InstallRoot 'Software\Harness\HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $configPath
$softwareRoot = [string]$layout.SoftwareRoot
$brokerRoot = [string]$layout.BrokerRoot
$definitionPath = Join-Path ([string]$layout.HarnessSourceRoot) 'pool-definition.json'
$runner = Join-Path $softwareRoot 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = Join-Path $InstallRoot ('Live\Setup\ReleaseAcceptance\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not ($EvidenceRoot + '\').StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceRoot must remain below InstallRoot.'
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

function Invoke-PoolAudit {
    param([Parameter(Mandatory = $true)] [string] $Name)

    $statusPath = Join-Path $EvidenceRoot ($Name + '.json')
    & (Join-Path ([string]$layout.HarnessSourceRoot) 'Audit-HyperVTestPool.ps1') `
        -DefinitionPath $definitionPath `
        -BrokerRoot $brokerRoot `
        -StatusPath $statusPath `
        -ExpectedIdleTimeoutSeconds ([int]$layout.PoolIdleTimeoutSeconds) `
        -ConfigPath $configPath `
        -ClientSid $ClientSid
    $audit = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if (-not [bool]$audit.Success) { throw "The $Name release audit failed." }
    $statusPath
}

function Invoke-AcceptanceTest {
    param([Parameter(Mandatory = $true)] $Definition)

    $requiredPaths = @([string]$Definition.Parameters['ArtifactPath'])
    if ($Definition.Parameters.ContainsKey('ActionsPath')) {
        $requiredPaths += [string]$Definition.Parameters['ActionsPath']
    }
    foreach ($requiredPath in $requiredPaths) {
        if (-not [string]::IsNullOrWhiteSpace($requiredPath) -and -not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Release acceptance input is missing: $requiredPath"
        }
    }
    $parameters = $Definition.Parameters
    $output = @(& $runner @parameters)
    $json = $output | Select-Object -Last 1
    if ($null -eq $json) { throw "$($Definition.Name) returned no summary." }
    $summary = if ($json -is [string]) { $json | ConvertFrom-Json } else { $json }
    if (-not [bool]$summary.Success -or -not [bool]$summary.PayloadChildDeleted -or [string]$summary.VmFinalState -ne 'Off') {
        throw "$($Definition.Name) did not satisfy the isolated harness contract: $($summary.Error)"
    }
    $summary
}

$startedUtc = [DateTime]::UtcNow
$preAuditPath = Invoke-PoolAudit -Name 'pre-acceptance-audit'
$invocations = @(New-HarnessReleaseAcceptanceInvocations -SoftwareRoot $softwareRoot -BrokerRoot $brokerRoot)
$results = [ordered]@{}
foreach ($invocation in $invocations) {
    $results[[string]$invocation.Name] = Invoke-AcceptanceTest -Definition $invocation
}

$legacy = $results.LegacyLaunch
if (-not (Test-Path -LiteralPath (Join-Path ([string]$legacy.ResultPath) 'recovery-smoke.png') -PathType Leaf)) {
    throw 'Legacy launch acceptance did not return its screenshot.'
}

$keyboard = $results.KeyboardInput
foreach ($fileName in @('keyboard-before.png', 'keyboard-after.png')) {
    if (-not (Test-Path -LiteralPath (Join-Path ([string]$keyboard.ResultPath) $fileName) -PathType Leaf)) {
        throw "Keyboard acceptance did not return $fileName."
    }
}
$keyboardGuest = Get-Content -LiteralPath ([string]$keyboard.GuestResultPath) -Raw | ConvertFrom-Json
$keyboardActions = @($keyboardGuest.Actions | Where-Object { [string]$_.Type -eq 'send_keys' })
if ($keyboardActions.Count -ne 1 -or
    -not [bool]$keyboardActions[0].Success -or
    [string]$keyboardActions[0].Details.KeySpec -ne 'WIN+LEFT' -or
    (@($keyboardActions[0].Details.VirtualKeyCodes) -join ',') -ne '0x5B,0x25') {
    throw 'Keyboard acceptance did not prove the exact WIN+LEFT key chord and virtual-key sequence.'
}

$shutdown = $results.ExpectedGuestPowerOff
if (-not [bool]$shutdown.ExpectedGuestPowerOffContractProven -or
    -not [bool]$shutdown.ExpectedGuestPowerOffContractSatisfied -or
    [bool]$shutdown.ApplicationRelaunchedByHarnessAfterGuestPowerOff) {
    throw 'Expected-guest-power-off acceptance did not prove ordered shutdown and no replay.'
}

$postAuditPath = Invoke-PoolAudit -Name 'post-acceptance-audit'
[pscustomobject][ordered]@{
    Success = $true
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    EvidenceRoot = $EvidenceRoot
    PreAuditPath = $preAuditPath
    PostAuditPath = $postAuditPath
    Tests = @($invocations | ForEach-Object {
        $summary = $results[[string]$_.Name]
        [pscustomobject][ordered]@{
            Name = [string]$_.Name
            RequestId = [string]$summary.RequestId
            ResultPath = [string]$summary.ResultPath
            Success = [bool]$summary.Success
        }
    })
}
