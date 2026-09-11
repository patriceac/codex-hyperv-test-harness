[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'RemoteDebuggerProvisioning.ps1'
$checks = New-Object Collections.Generic.List[string]

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [scriptblock] $Action,
        [string] $ExpectedMessage
    )

    $message = $null
    try { $null = & $Action }
    catch { $message = $_.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($message) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedMessage) -and $message -notlike ('*' + $ExpectedMessage + '*'))) {
        throw "$Name did not fail as expected: $message"
    }
    $checks.Add($Name)
}

$strictModeLeaked = & {
    Set-StrictMode -Off
    . $modulePath
    try { $null = $variableThatDoesNotExist; $false }
    catch { $true }
}
if ($strictModeLeaked) { throw 'RemoteDebuggerProvisioning.ps1 leaked strict mode into its dot-sourcing caller.' }
$checks.Add('dot-source-does-not-leak-strict-mode')

. $modulePath
$approvedHash = 'A' * 64
$publisherPin = 'B' * 64
$config = [pscustomobject]@{
    FormatVersion = 1
    Enabled = $true
    PublisherThumbprint = $publisherPin
    ApprovedExecutableSha256 = @($approvedHash)
}
function New-RequestProfile([string] $Path = 'release\RemoteDebugger.exe') {
    [pscustomobject]@{ FixtureRelativePath = $Path; ExpectedSha256 = $approvedHash }
}

$resolved = Resolve-RemoteDebuggerProvisionRequestV1 -RequestProfile (New-RequestProfile) -ConfigProfile $config -RequestId 'pure-validator-01'
if ($resolved.FixtureRelativePath -cne 'release\RemoteDebugger.exe' -or
    $resolved.ExpectedSha256 -cne $approvedHash -or
    $resolved.PublisherThumbprint -cne $publisherPin) {
    throw 'The pure provisioning validator did not preserve the exact approved identity.'
}
$checks.Add('valid-request-resolves-before-allocation')

$badPaths = @(
    ' release\RemoteDebugger.exe',
    'release\RemoteDebugger.exe ',
    'release\\RemoteDebugger.exe',
    '.\RemoteDebugger.exe',
    '..\RemoteDebugger.exe',
    'release\..\RemoteDebugger.exe',
    'release.\RemoteDebugger.exe',
    'release \RemoteDebugger.exe',
    'release\bad*\RemoteDebugger.exe',
    'release\bad?\RemoteDebugger.exe',
    'release\bad<\RemoteDebugger.exe',
    'release\bad>\RemoteDebugger.exe',
    'release\bad|\RemoteDebugger.exe',
    'release\bad"\RemoteDebugger.exe',
    'release\RemoteDebugger.exe:stream',
    'C:\RemoteDebugger.exe',
    '\\server\share\RemoteDebugger.exe',
    'release\Other.exe'
)
foreach ($badPath in $badPaths) {
    Assert-Rejected -Name ('invalid-relative-path-' + $checks.Count) -Action {
        Resolve-RemoteDebuggerProvisionRequestV1 -RequestProfile (New-RequestProfile -Path $badPath) -ConfigProfile $config -RequestId 'pure-validator-02'
    }
}
$tooLong = ('a' * 230) + '\RemoteDebugger.exe'
Assert-Rejected -Name 'relative-path-length-bound' -Action {
    Resolve-RemoteDebuggerProvisionRequestV1 -RequestProfile (New-RequestProfile -Path $tooLong) -ConfigProfile $config -RequestId 'pure-validator-03'
} -ExpectedMessage 'at most 240'

$unapprovedRequest = New-RequestProfile
$unapprovedRequest.ExpectedSha256 = 'C' * 64
Assert-Rejected -Name 'protected-hash-allowlist' -Action {
    Resolve-RemoteDebuggerProvisionRequestV1 -RequestProfile $unapprovedRequest -ConfigProfile $config -RequestId 'pure-validator-04'
} -ExpectedMessage 'allowlist'

$sourceText = Get-Content -LiteralPath $modulePath -Raw
if ($sourceText -notmatch [regex]::Escape("Arguments = 'cli platform-provision'") -or
    $sourceText -match 'Invoke-Expression' -or
    $sourceText -notmatch 'CodexRemoteDebuggerAuthenticode' -or
    $sourceText -notmatch 'CheckSignature\(true\)' -or
    $sourceText -notmatch 'ComputeAuthenticodeDigest' -or
    $sourceText -notmatch 'SetAccessRuleProtection\(\$true, \$false\)' -or
    $sourceText -notmatch [regex]::Escape("[Security.AccessControl.FileSystemRights]::ReadAndExecute")) {
    throw 'The fixed command, Authenticode integrity verifier, or protected evidence ACL contract is missing.'
}
$checks.Add('fixed-command-signature-and-acl-contract')

$match = [regex]::Match($sourceText, "Add-Type -ReferencedAssemblies @\('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Security.dll'\) -TypeDefinition @'\r?\n(?<Code>[\s\S]*?)\r?\n'@")
if (-not $match.Success) { throw 'The embedded PowerShell 5.1 Authenticode verifier source was not found.' }
Add-Type -ErrorAction Stop -ReferencedAssemblies @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Security.dll') -TypeDefinition $match.Groups['Code'].Value
$tempPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-rd-invalid-pe-' + [Guid]::NewGuid().ToString('N') + '.exe')
try {
    [IO.File]::WriteAllBytes($tempPath, [byte[]](0..255))
    Assert-Rejected -Name 'authenticode-verifier-rejects-invalid-pe' -Action {
        [CodexRemoteDebuggerAuthenticode]::Verify($tempPath, $publisherPin)
    } -ExpectedMessage 'DOS header'
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $checks.Count
    Scenarios = $checks.ToArray()
} | ConvertTo-Json -Depth 4
