[CmdletBinding()]
param([string] $HarnessRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HarnessRoot)) { $HarnessRoot = Split-Path -Parent $PSScriptRoot }
$updateText = Get-Content -Raw -LiteralPath (Join-Path $HarnessRoot 'Update-GuestHarnessBaseline.ps1')
$initializeCallIndex = $updateText.LastIndexOf("Initialize-HyperVTestPool.ps1", [StringComparison]::Ordinal)
$installBrokerCallIndex = $updateText.LastIndexOf("Install-PoolHostBroker.ps1", [StringComparison]::Ordinal)
if ($initializeCallIndex -lt 0 -or $installBrokerCallIndex -le $initializeCallIndex) {
    throw 'The guest baseline update omits its pool or broker deployment call.'
}
$initializeCall = $updateText.Substring($initializeCallIndex, $installBrokerCallIndex - $initializeCallIndex)
$installBrokerCall = $updateText.Substring($installBrokerCallIndex)
if ($initializeCall -notlike '*-ConfigPath $ConfigPath*') {
    throw 'The guest baseline update does not pass the explicit configuration to pool initialization.'
}
if ($installBrokerCall -notlike '*-ConfigPath $ConfigPath*') {
    throw 'The guest baseline update does not pass the explicit configuration to broker installation.'
}

# Execute only the policy statements with registry commands mocked: never write host policy.
& {
    function New-Item { param($Path, [switch] $Force, $ErrorAction) }
    function New-ItemProperty {
        param($LiteralPath, $Name, $PropertyType, $Value, [switch] $Force, $ErrorAction)
        $policyWrite.Path = $LiteralPath; $policyWrite.Name = $Name
        $policyWrite.Type = $PropertyType; $policyWrite.Value = $Value
    }
    foreach ($relative in @('seed\guest\Install-GuestHarness.ps1', 'Update-GuestHarnessBaseline.ps1')) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $HarnessRoot $relative), [ref]$null, [ref]$null)
        $policy = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$autoPlayPolicy' }, $true)
        if (-not $policy) { throw "Guest AutoPlay policy is missing from $relative." }
        $statements = @($policy.Parent.Statements)
        $index = [Array]::IndexOf($statements, $policy)
        $policyWrite = @{}
        & ([scriptblock]::Create(($statements[$index..($index + 2)].Extent.Text -join "`n")))
        if ($policyWrite.Path -ine 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -or
            $policyWrite.Name -cne 'NoDriveTypeAutoRun' -or $policyWrite.Type -ine 'DWord' -or $policyWrite.Value -ne 255) {
            throw "Guest AutoPlay remains enabled for some drives or accounts in $relative."
        }
    }
    $readback = $ast.Find({ param($node) $node -is [Management.Automation.Language.BinaryExpressionAst] -and $node.Left.Extent.Text -like '*NoDriveTypeAutoRun*' }, $true)
    $guard = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '-not $guestHarness.AutoPlayDisabled' }, $true)
    if (-not $readback -or -not $guard) { throw 'Baseline sealing does not verify guest AutoPlay policy.' }
    function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction) [pscustomobject]@{ NoDriveTypeAutoRun = $policyValue } }
    foreach ($policyValue in @(0, 255)) {
        $guestHarness = [pscustomobject]@{ AutoPlayDisabled = & ([scriptblock]::Create($readback.Extent.Text)) }
        $rejected = $false
        try { & ([scriptblock]::Create($guard.Extent.Text)) } catch { $rejected = $true }
        if ($rejected -ne ($policyValue -ne 255)) { throw 'Baseline AutoPlay validation accepted an enabled policy or rejected the disabled policy.' }
    }
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = 3
    Scenarios = @('pool-config-path-propagated', 'broker-config-path-propagated', 'guest-autoplay-disabled-and-verified')
} | ConvertTo-Json -Depth 4
