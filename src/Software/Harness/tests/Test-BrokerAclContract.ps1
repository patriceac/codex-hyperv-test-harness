[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-PoolHostBroker.ps1'
$auditPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Audit-HyperVTestPool.ps1'
$installer = Get-Content -LiteralPath $installerPath -Raw
$audit = Get-Content -LiteralPath $auditPath -Raw
$scenarios = New-Object Collections.Generic.List[string]

if ($installer -notmatch 'function\s+Set-BrokerAcl' -or $installer -notmatch 'DirectorySecurity\]::new' -or $installer -notmatch 'FileSecurity\]::new' -or $installer -notmatch 'SetAccessControl') {
    throw 'Broker installation does not replace the complete DACL with a canonical access policy.'
}
$scenarios.Add('canonical-dacl-replaces-existing-rules')

if ($installer -notmatch 'ClientSid\s*=\s*\$ClientSid') {
    throw 'Broker configuration does not persist the intended client SID for later ACL audit.'
}
$scenarios.Add('client-sid-persisted')

foreach ($required in @('BrokerAclsMatchPolicy', "ClientMode = 'None'", "ClientMode = 'Modify'", "ClientMode = 'ReadExecute'", "ClientMode = 'Read'")) {
    if (-not $audit.Contains($required)) { throw "Broker ACL audit contract is missing: $required" }
}
$scenarios.Add('acl-profiles-audited')

if ($audit -notmatch "S-1-5-18" -or $audit -notmatch "S-1-5-32-544" -or $audit -notmatch 'AreAccessRulesProtected' -or $audit -notmatch 'UnexpectedAccessRules' -or $audit -notmatch 'MissingAccessRules' -or $audit -notmatch 'OwnerAllowed') {
    throw 'Broker ACL audit does not verify exact protected descriptors, ownership, and missing or unrelated access rules.'
}
$scenarios.Add('exact-ace-tuples-and-owner-audited')

if ($installer -notmatch 'Unregister-ScheduledTask.+-Confirm:\$false' -or $installer -notmatch 'Register-ScheduledTask.+-Xml\s+\$previousTaskXml' -or $installer -notmatch '\$restoredTaskXml' -or $installer -notmatch 'Rollback left a SYSTEM broker task behind' -or $installer -notmatch '\$taskRegistrationAttempted') {
    throw 'Broker rollback does not verify fresh-task removal plus exact pre-existing task definition and state restoration.'
}
$scenarios.Add('scheduled-job-rollback-postconditions-verified')

$successStatusPosition = $installer.IndexOf("Write-InstallStatus -Success `$true", [StringComparison]::Ordinal)
$maintenanceRemovalPosition = $installer.IndexOf('Remove-Item -LiteralPath $maintenancePath -Force -ErrorAction Stop', [StringComparison]::Ordinal)
$commitPosition = $installer.IndexOf('$installCommitted = $true', [StringComparison]::Ordinal)
$postCommitCleanupPosition = $installer.IndexOf("Backup cleanup is deliberately post-commit", [StringComparison]::Ordinal)
$finallyPosition = $installer.LastIndexOf('finally {', [StringComparison]::Ordinal)
$finallyText = if ($finallyPosition -ge 0) { $installer.Substring($finallyPosition) } else { '' }
if ($successStatusPosition -lt 0 -or $maintenanceRemovalPosition -le $successStatusPosition -or $commitPosition -le $maintenanceRemovalPosition -or $postCommitCleanupPosition -le $commitPosition -or $finallyText -match 'Start-ScheduledTask') {
    throw 'Broker success/rollback ordering can drop maintenance or backups too early, or start an unverified task from finally.'
}
$scenarios.Add('success-commit-and-finally-are-fail-closed')

if ($installer -notmatch '\$installCommitted\s*=\s*\$true' -or $finallyText -notmatch 'if\s*\(\$maintenanceCreated\s+-and\s+\(\$installCommitted\s+-or\s+\$rollbackSucceeded\)\)') {
    throw 'Broker rollback failure can clear maintenance mode and re-enable an unverified broker.'
}
$scenarios.Add('rollback-failure-preserves-maintenance-lock')

if ($installer -notmatch '\$installationMutationStarted' -or $installer -notmatch '\$credentialExistedBefore') {
    throw 'Broker rollback does not distinguish untouched state from files created during this attempt.'
}
$scenarios.Add('file-and-credential-rollback-is-state-aware')

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
