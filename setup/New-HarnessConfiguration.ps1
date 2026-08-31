[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [ValidateRange(1, 4)] [int] $PoolSize = 4,
    [ValidateRange(2, 64)] [int] $VmMemoryGiB = 8,
    [ValidateRange(1, 64)] [int] $VmProcessorCount = 4,
    [ValidateRange(60, 86400)] [int] $IdleTimeoutSeconds = 600,
    [ValidateRange(1024, 7680)] [int] $DisplayWidth = 1920,
    [ValidateRange(768, 4320)] [int] $DisplayHeight = 1080,
    [string] $OutputPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')] [string] $ExpectedExistingConfigurationSha256,
    [switch] $ResetRequestNetworkPolicy,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'

function Get-HarnessFileSha256 {
    param([Parameter(Mandatory = $true)] [string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-HarnessStringSha256 {
    param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Value)

    $encoding = New-Object Text.UTF8Encoding($false)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        -join @($algorithm.ComputeHash($encoding.GetBytes($Value)) | ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-HarnessConfigurationIdentity {
    param(
        [Parameter(Mandatory = $true)] $Configuration,
        [Parameter(Mandatory = $true)] [string] $ExpectedInstallRoot,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    if ($Configuration -is [array] -or $Configuration -is [string] -or $Configuration -is [ValueType]) {
        throw "$Context must be a JSON object."
    }
    $formatProperty = $Configuration.PSObject.Properties['FormatVersion']
    $rootProperty = $Configuration.PSObject.Properties['InstallRoot']
    if ($null -eq $formatProperty -or
        $formatProperty.Value -is [bool] -or
        ($formatProperty.Value -isnot [int16] -and $formatProperty.Value -isnot [int32] -and $formatProperty.Value -isnot [int64]) -or
        [int64]$formatProperty.Value -ne 1) {
        throw "$Context has an unsupported or malformed FormatVersion."
    }
    if ($null -eq $rootProperty -or [string]::IsNullOrWhiteSpace([string]$rootProperty.Value)) {
        throw "$Context is missing InstallRoot."
    }
    try { $actualRoot = [IO.Path]::GetFullPath([string]$rootProperty.Value).TrimEnd('\') }
    catch { throw "$Context has an invalid InstallRoot." }
    if (-not [string]::Equals($actualRoot, $ExpectedInstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context belongs to a different install root: $actualRoot"
    }
    $true
}

function Read-HarnessConfigurationDocument {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $ExpectedInstallRoot,
        [Parameter(Mandatory = $true)] [string] $Context
    )

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $configuration = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Could not read $Context as JSON: $($_.Exception.Message)"
    }
    $null = Assert-HarnessConfigurationIdentity -Configuration $configuration -ExpectedInstallRoot $ExpectedInstallRoot -Context $Context
    $configuration
}

function Write-HarnessConfigurationAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Json,
        [Parameter(Mandatory = $true)] [bool] $ExpectedExisting,
        [AllowEmptyString()] [string] $ExpectedCurrentSha256,
        [Parameter(Mandatory = $true)] [scriptblock] $ValidateCommittedPath
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $leaf = Split-Path -Leaf $Path
    $transactionId = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $parent ($leaf + '.' + $transactionId + '.tmp')
    $backup = Join-Path $parent ($leaf + '.' + $transactionId + '.bak')
    $rejected = Join-Path $parent ($leaf + '.' + $transactionId + '.rejected')
    $backupMayBeRemoved = $false
    $encoding = New-Object Text.UTF8Encoding($false)

    try {
        $exists = Test-Path -LiteralPath $Path -PathType Leaf
        if ($exists -ne $ExpectedExisting) {
            throw 'The installed configuration existence changed after review.'
        }
        if ($exists) {
            $currentHash = Get-HarnessFileSha256 -Path $Path
            if (-not [string]::Equals($currentHash, $ExpectedCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The installed configuration changed after review. Expected SHA-256 $ExpectedCurrentSha256 but found $currentHash."
            }
        }

        [IO.File]::WriteAllText($temporary, $Json, $encoding)
        & $ValidateCommittedPath $temporary | Out-Null

        $exists = Test-Path -LiteralPath $Path -PathType Leaf
        if ($exists -ne $ExpectedExisting) {
            throw 'The installed configuration existence changed before commit.'
        }
        if ($exists) {
            $currentHash = Get-HarnessFileSha256 -Path $Path
            if (-not [string]::Equals($currentHash, $ExpectedCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The installed configuration changed before commit. Expected SHA-256 $ExpectedCurrentSha256 but found $currentHash."
            }
            [IO.File]::Replace($temporary, $Path, $backup, $true)
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }

        try {
            & $ValidateCommittedPath $Path | Out-Null
            $committedHash = Get-HarnessFileSha256 -Path $Path
        }
        catch {
            $commitFailure = $_
            try {
                if ($ExpectedExisting) {
                    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                        throw 'The transaction backup is missing.'
                    }
                    [IO.File]::Replace($backup, $Path, $rejected, $true)
                    $restoredHash = Get-HarnessFileSha256 -Path $Path
                    if (-not [string]::Equals($restoredHash, $ExpectedCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Rollback restored unexpected SHA-256 $restoredHash."
                    }
                    Remove-Item -LiteralPath $rejected -Force -ErrorAction SilentlyContinue
                }
                elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                }
            }
            catch {
                throw "Configuration commit validation failed, and rollback also failed. Commit error: $($commitFailure.Exception.Message) Rollback error: $($_.Exception.Message) Backup: $backup"
            }
            throw "Configuration commit validation failed and was rolled back: $($commitFailure.Exception.Message)"
        }

        $backupMayBeRemoved = $true
        $committedHash
    }
    catch {
        if ((Test-Path -LiteralPath $backup -PathType Leaf) -and (Test-Path -LiteralPath $Path -PathType Leaf) -and $ExpectedExisting) {
            try {
                $currentHash = Get-HarnessFileSha256 -Path $Path
                if ([string]::Equals($currentHash, $ExpectedCurrentSha256, [StringComparison]::OrdinalIgnoreCase)) {
                    $backupMayBeRemoved = $true
                }
            }
            catch { }
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $rejected -Force -ErrorAction SilentlyContinue
        if ($backupMayBeRemoved) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallRoot) -or [IO.Path]::GetPathRoot($InstallRoot) -eq $InstallRoot) {
    throw 'InstallRoot must be a specific non-root directory.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $InstallRoot 'Software\harness-config.json' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

$requestNetworkCandidates = @(
    (Join-Path $PSScriptRoot '..\src\Software\Harness\RequestNetwork.ps1'),
    (Join-Path $PSScriptRoot '..\Harness\RequestNetwork.ps1')
)
$requestNetworkPath = @($requestNetworkCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
if ($requestNetworkPath.Count -ne 1) {
    throw 'RequestNetwork.ps1 is missing; the installed request-network policy cannot be validated safely.'
}
. $requestNetworkPath[0]

$existingConfigurationDetected = Test-Path -LiteralPath $OutputPath -PathType Leaf
$existingHarnessStateDetected = @(
    (Join-Path $InstallRoot 'Live'),
    (Join-Path $InstallRoot 'Recovery'),
    (Join-Path $InstallRoot 'Software\Harness'),
    (Join-Path $InstallRoot 'Software\Setup')
) | Where-Object { Test-Path -LiteralPath $_ }
$existingConfigurationSha256 = $null
$existingConfiguration = $null
if ($existingConfigurationDetected) {
    $existingConfigurationSha256 = Get-HarnessFileSha256 -Path $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExistingConfigurationSha256) -and
        -not [string]::Equals($existingConfigurationSha256, $ExpectedExistingConfigurationSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The installed configuration changed after review. Expected SHA-256 $ExpectedExistingConfigurationSha256 but found $existingConfigurationSha256."
    }
    $existingConfiguration = Read-HarnessConfigurationDocument -Path $OutputPath -ExpectedInstallRoot $InstallRoot -Context 'the installed harness configuration'
}
elseif (-not [string]::IsNullOrWhiteSpace($ExpectedExistingConfigurationSha256)) {
    throw 'The installed configuration reviewed by fingerprint no longer exists.'
}
elseif (@($existingHarnessStateDetected).Count -gt 0) {
    throw 'Existing harness state was found without harness-config.json; refusing to treat this as a first installation or synthesize a replacement policy.'
}

if ($ResetRequestNetworkPolicy -and -not $existingConfigurationDetected) {
    throw 'ResetRequestNetworkPolicy is valid only for an existing harness configuration.'
}

$requestNetworkPolicyDisposition = $null
if (-not $existingConfigurationDetected) {
    $requestNetworkPolicy = Get-RequestNetworkDefaultPolicy
    $requestNetworkPolicyDisposition = 'CreatedFailClosed'
}
elseif ($ResetRequestNetworkPolicy) {
    $requestNetworkPolicy = Get-RequestNetworkDefaultPolicy
    $requestNetworkPolicyDisposition = 'ResetToFailClosed'
}
else {
    $policyProperty = $existingConfiguration.PSObject.Properties['RequestNetworkPolicy']
    if ($null -eq $policyProperty -or $null -eq $policyProperty.Value) {
        throw 'The installed harness configuration has no RequestNetworkPolicy. Use a separately reviewed ResetRequestNetworkPolicy operation to replace it with fail-closed defaults.'
    }
    try { $null = Assert-RequestNetworkPolicySchema -Policy $policyProperty.Value }
    catch {
        throw "The installed RequestNetworkPolicy is malformed or incompatible and cannot be refreshed implicitly: $($_.Exception.Message) Use a separately reviewed ResetRequestNetworkPolicy operation to replace it with fail-closed defaults."
    }
    $requestNetworkPolicy = $policyProperty.Value
    $requestNetworkPolicyDisposition = 'PreservedExisting'
}
$null = Assert-RequestNetworkPolicySchema -Policy $requestNetworkPolicy

$configuration = [ordered]@{
    FormatVersion = 1
    InstallRoot = $InstallRoot
    LiveRoot = Join-Path $InstallRoot 'Live'
    BaselineRoot = Join-Path $InstallRoot 'Live\Baseline'
    BrokerRoot = Join-Path $InstallRoot 'Live\Broker'
    SoftwareRoot = Join-Path $InstallRoot 'Software'
    HarnessSourceRoot = Join-Path $InstallRoot 'Software\Harness'
    SkillSourceRoot = Join-Path $InstallRoot 'Software\Skill'
    RecoveryRoot = Join-Path $InstallRoot 'Recovery'
    BaselineVmName = 'Codex-Harness-Baseline'
    BaselineCheckpointName = 'Clean-Windows11-Harness'
    PoolVmPrefix = 'Codex-Harness'
    PoolSize = $PoolSize
    PoolIdleTimeoutSeconds = $IdleTimeoutSeconds
    PoolLifecycleConcurrency = 2
    VmMemoryBytes = [long]$VmMemoryGiB * 1GB
    VmProcessorCount = $VmProcessorCount
    GuestDisplayWidth = $DisplayWidth
    GuestDisplayHeight = $DisplayHeight
    BrokerTaskName = 'Codex Hyper-V Broker'
    BrokerLocationPointer = Join-Path $env:ProgramData 'CodexHyperVBroker\location.json'
    RecoveryResumeTaskName = 'Codex Hyper-V Recovery Resume'
    RecoveryGenerations = 2
    NetworkPolicy = 'DisconnectedExceptEphemeralReadOnlyHostInput'
    RequestNetworkPolicy = $requestNetworkPolicy
}

$configurationJson = $configuration | ConvertTo-Json -Depth 30
$requestNetworkPolicySha256 = Get-HarnessStringSha256 -Value ($requestNetworkPolicy | ConvertTo-Json -Depth 30 -Compress)
$result = [pscustomobject]$configuration
$result | Add-Member -NotePropertyName ExistingConfigurationDetected -NotePropertyValue $existingConfigurationDetected
$result | Add-Member -NotePropertyName ExistingConfigurationSha256 -NotePropertyValue $existingConfigurationSha256
$result | Add-Member -NotePropertyName RequestNetworkPolicyDisposition -NotePropertyValue $requestNetworkPolicyDisposition
$result | Add-Member -NotePropertyName RequestNetworkPolicySha256 -NotePropertyValue $requestNetworkPolicySha256
$result | Add-Member -NotePropertyName IntentionalPolicyReset -NotePropertyValue ([bool]$ResetRequestNetworkPolicy)
$result | Add-Member -NotePropertyName NoMutationPerformed -NotePropertyValue ([bool]$PlanOnly)

if ($PlanOnly) {
    $result | Add-Member -NotePropertyName CommittedConfigurationSha256 -NotePropertyValue $null
    $result
    return
}
if ($existingConfigurationDetected -and [string]::IsNullOrWhiteSpace($ExpectedExistingConfigurationSha256)) {
    throw 'An existing harness configuration can be changed only with its exact ExpectedExistingConfigurationSha256 from PlanOnly.'
}

$validateCommittedPath = {
    param([string] $Path)
    $candidate = Read-HarnessConfigurationDocument -Path $Path -ExpectedInstallRoot $InstallRoot -Context 'the candidate harness configuration'
    $candidatePolicyProperty = $candidate.PSObject.Properties['RequestNetworkPolicy']
    if ($null -eq $candidatePolicyProperty -or $null -eq $candidatePolicyProperty.Value) {
        throw 'The candidate harness configuration has no RequestNetworkPolicy.'
    }
    $null = Assert-RequestNetworkPolicySchema -Policy $candidatePolicyProperty.Value
    $candidatePolicySha256 = Get-HarnessStringSha256 -Value ($candidatePolicyProperty.Value | ConvertTo-Json -Depth 30 -Compress)
    if (-not [string]::Equals($candidatePolicySha256, $requestNetworkPolicySha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The candidate RequestNetworkPolicy fingerprint differs from the reviewed policy.'
    }
}

$committedConfigurationSha256 = Write-HarnessConfigurationAtomic -Path $OutputPath -Json $configurationJson -ExpectedExisting $existingConfigurationDetected -ExpectedCurrentSha256 ([string]$existingConfigurationSha256) -ValidateCommittedPath $validateCommittedPath
$result | Add-Member -NotePropertyName CommittedConfigurationSha256 -NotePropertyValue $committedConfigurationSha256
$result.NoMutationPerformed = $false
$result
