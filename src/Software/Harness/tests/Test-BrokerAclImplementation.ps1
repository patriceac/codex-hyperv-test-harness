[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$harnessRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $harnessRoot 'Install-PoolHostBroker.ps1'
$auditPath = Join-Path $harnessRoot 'Audit-HyperVTestPool.ps1'

function Import-ScriptFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0].Message }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Function not found: $Name" }
    $body = $definition.Body.Extent.Text
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}

Import-ScriptFunction -Path $installerPath -Name 'Set-BrokerAcl'
Import-ScriptFunction -Path $auditPath -Name 'Get-ExplicitAllowRights'
Import-ScriptFunction -Path $auditPath -Name 'Test-BrokerAclProfile'

function Get-PathOwnerSid {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).Owner
    try { ([Security.Principal.NTAccount]$owner).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { [string]$owner }
}

$ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$workRoot = Join-Path $temporaryRoot ('CodexBrokerAcl-' + [Guid]::NewGuid().ToString('N'))
if (-not ([IO.Path]::GetFullPath($workRoot) + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($workRoot) -notlike 'CodexBrokerAcl-*') {
    throw 'ACL test work path failed its temporary-directory safety check.'
}

function Remove-AclFixtureSafe {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (($resolved + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'CodexBrokerAcl-*')) {
        throw "Refusing to remove an unvalidated ACL fixture path: $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return }
    foreach ($cleanupFile in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        Set-BrokerAcl -Path $cleanupFile.FullName -ClientMode Modify -PreserveOwner
    }
    foreach ($cleanupDirectory in @(Get-ChildItem -LiteralPath $resolved -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
        Set-BrokerAcl -Path $cleanupDirectory.FullName -ClientMode Modify -ClientInherits -PreserveOwner
    }
    Set-BrokerAcl -Path $resolved -ClientMode Modify -ClientInherits -PreserveOwner
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

foreach ($stale in @(Get-ChildItem -LiteralPath $temporaryRoot -Directory -Filter 'CodexBrokerAcl-*' -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTimeUtc -lt ([DateTime]::UtcNow.AddMinutes(-1)))) {
    Remove-AclFixtureSafe -Path $stale.FullName
}

$scenarios = New-Object Collections.Generic.List[string]
try {
    $child = Join-Path $workRoot 'child'
    $file = Join-Path $child 'probe.txt'
    New-Item -ItemType Directory -Force -Path $child | Out-Null
    New-Item -ItemType File -Force -Path $file | Out-Null

    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $seedAcl = Get-Acl -LiteralPath $workRoot
    $seedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($usersSid, [Security.AccessControl.FileSystemRights]::Write, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $workRoot -AclObject $seedAcl

    Set-BrokerAcl -Path $workRoot -ClientMode ReadExecute -PreserveOwner
    $rootProfile = Test-BrokerAclProfile -Path $workRoot -ClientMode ReadExecute -ResolvedClientSid $ClientSid -AllowedOwnerSids @((Get-PathOwnerSid -Path $workRoot))
    if (-not $rootProfile.Passed -or @($rootProfile.UnexpectedAccessRules).Count -ne 0) { throw "Canonical root ACL validation failed: $($rootProfile | ConvertTo-Json -Depth 8 -Compress)" }
    $scenarios.Add('unrelated-explicit-allow-removed')
    $scenarios.Add('root-read-execute-profile-passes')

    Set-BrokerAcl -Path $child -ClientMode Modify -ClientInherits -PreserveOwner
    $childProfile = Test-BrokerAclProfile -Path $child -ClientMode Modify -ResolvedClientSid $ClientSid -ClientInherits -AllowedOwnerSids @((Get-PathOwnerSid -Path $child))
    if (-not $childProfile.Passed) { throw "Canonical writable-directory ACL validation failed: $($childProfile | ConvertTo-Json -Depth 8 -Compress)" }
    $scenarios.Add('writable-directory-profile-passes')

    $childAcl = [IO.Directory]::GetAccessControl($child, [Security.AccessControl.AccessControlSections]::Access)
    foreach ($rule in @($childAcl.Access | Where-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $ClientSid } catch { $false } })) {
        [void]$childAcl.RemoveAccessRuleSpecific($rule)
    }
    $childAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($ClientSid), [Security.AccessControl.FileSystemRights]::Modify, [Security.AccessControl.InheritanceFlags]::None, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    [IO.Directory]::SetAccessControl($child, $childAcl)
    $wrongInheritance = Test-BrokerAclProfile -Path $child -ClientMode Modify -ResolvedClientSid $ClientSid -ClientInherits -AllowedOwnerSids @((Get-PathOwnerSid -Path $child))
    if ($wrongInheritance.Passed -or @($wrongInheritance.MissingAccessRules).Count -eq 0 -or @($wrongInheritance.UnexpectedAccessRules).Count -eq 0) { throw 'ACL audit accepted a non-inheriting client ACE where inheritance was required.' }
    $scenarios.Add('wrong-inheritance-flags-rejected')
    Set-BrokerAcl -Path $child -ClientMode Modify -ClientInherits -PreserveOwner

    Set-BrokerAcl -Path $file -ClientMode Read -PreserveOwner
    $fileOwnerSid = Get-PathOwnerSid -Path $file
    $fileProfile = Test-BrokerAclProfile -Path $file -ClientMode Read -ResolvedClientSid $ClientSid -AllowedOwnerSids @($fileOwnerSid)
    if (-not $fileProfile.Passed) { throw "Canonical read-only file ACL validation failed: $($fileProfile | ConvertTo-Json -Depth 8 -Compress)" }
    $scenarios.Add('read-only-file-profile-passes')

    $wrongRights = Test-BrokerAclProfile -Path $file -ClientMode ReadExecute -ResolvedClientSid $ClientSid -AllowedOwnerSids @($fileOwnerSid)
    if ($wrongRights.Passed -or @($wrongRights.MissingAccessRules).Count -eq 0 -or @($wrongRights.UnexpectedAccessRules).Count -eq 0) { throw 'ACL audit accepted Read where ReadAndExecute was expected.' }
    $scenarios.Add('wrong-rights-rejected')

    $disallowedOwnerSid = if ($fileOwnerSid -ne 'S-1-5-18') { 'S-1-5-18' } else { 'S-1-5-32-545' }
    $wrongOwner = Test-BrokerAclProfile -Path $file -ClientMode Read -ResolvedClientSid $ClientSid -AllowedOwnerSids @($disallowedOwnerSid)
    if ($wrongOwner.Passed -or $wrongOwner.OwnerAllowed) { throw 'ACL audit accepted a disallowed owner.' }
    $scenarios.Add('wrong-owner-rejected')
}
finally {
    Remove-AclFixtureSafe -Path $workRoot
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
