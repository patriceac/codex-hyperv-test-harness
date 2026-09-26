[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\Skill\scripts\InstallerUacContract.ps1')
$manifest = [pscustomobject]@{ Files = @(
    [pscustomobject]@{RelativePath='setup.exe';Sha256=('A'*64)},
    [pscustomobject]@{RelativePath='verify.exe';Sha256=('B'*64)}
) }
$template = [ordered]@{
    Operation='RunGuestInstallerV2';ResetToBaseline=$true;StopAfter=$true
    Job=@{executable='{PAYLOAD}\setup.exe';actions=@()}
    HostInputs=@();Network=@{Profile='None';Cohort=$null;AllowHostInputs=$false}
    InstallerUac=@{
        FormatVersion=2;Decision='Accept';InitiatingUser='ManagedAdministrator';PromptTimeoutSeconds=120;ExpectedExitCode=0
        ExecutableRelativePath='setup.exe';ExecutableSha256=('A'*64)
        Verifier=@{
            Purpose='ReadOnlyObservation';ExecutableRelativePath='verify.exe';ExecutableSha256=('B'*64)
            Arguments=@('--phase','{PHASE}','--identity','{IDENTITY_FILE}','--outdir','{VERIFIER_OUTDIR}')
            TimeoutSeconds=120;ResultFile='check.json';JsonPointer='/passed';EqualsJson=$true
        }
        PrivilegedObservations=@()
    }
}
function New-Request { $template | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
$checks=0
function Assert-Rejected([scriptblock]$Change,[string]$Message) {
    $request=New-Request
    & $Change $request
    $caught=$null
    try { $null=Resolve-InstallerUacPolicyV2 $request $manifest } catch { $caught=$_.Exception.Message }
    if (-not $caught -or $caught -notlike ('*'+$Message+'*')) { throw "Expected rejection '$Message'; observed '$caught'." }
    $script:checks++
}
foreach($initiator in @('ManagedAdministrator','StandardUser')) {
    foreach($decision in @('Accept','Decline')) {
        $request=New-Request
        $request.InstallerUac.InitiatingUser=$initiator
        $request.InstallerUac.Decision=$decision
        if ($decision -eq 'Decline') { $request.InstallerUac.ExpectedExitCode=2 }
        $actual=Resolve-InstallerUacPolicyV2 $request $manifest
        if ($actual.Decision -cne $decision -or $actual.InitiatingUser -cne $initiator -or $actual.Verifier.ExecutableSha256 -cne ('B'*64)) { throw 'Validated authority changed.' }
        $checks++
    }
}
Assert-Rejected {param($r) $r.InstallerUac.ExecutableSha256=('C'*64)} 'exactly one payload-manifest'
Assert-Rejected {param($r) $r.Job.executable='{PAYLOAD}\verify.exe'} 'directly launched'
Assert-Rejected {param($r) $r.InstallerUac.Verifier.ExecutableSha256=('A'*64)} 'exactly one payload-manifest'
Assert-Rejected {param($r) $r.InstallerUac.Verifier.ExecutableRelativePath='..\verify.exe'} 'unsafe path'
Assert-Rejected {param($r) $r.InstallerUac.Verifier.Arguments=@('{GUEST_CREDENTIAL_FILE}')} 'unsupported token'
Assert-Rejected {param($r) $r.InstallerUac | Add-Member Password 'secret'} 'exact properties'
Assert-Rejected {param($r) $r.InstallerUac.FormatVersion='2'} 'integer'
Assert-Rejected {param($r) $r.InstallerUac.Decision='accept'} 'unsupported decision'
Assert-Rejected {param($r) $r.Job.actions=@(@{type='type_text';text='unsafe'})} 'no ordinary input'
Assert-Rejected {param($r) $r.Network.Profile='InternetOnly'} 'disconnected'
Assert-Rejected {param($r) $r.StopAfter=$false} 'StopAfter=true'
Assert-Rejected {param($r) $r | Add-Member GuestCredentialFixture $true} 'cannot be combined'
Assert-Rejected {param($r) $r.Operation='RunGuestJobSystemPromptsV1'} 'requires RunGuestInstallerV2'
Assert-Rejected {param($r) $r.InstallerUac.PrivilegedObservations=@(@{Name='admin';Root='AdministratorProfile';RelativePath='AppData\Local\Example'})} 'only for StandardUser'
Assert-Rejected {param($r) $r.InstallerUac.PrivilegedObservations=@(@{Name='private';Root='ProgramData';RelativePath='CodexHarness\private.json'})} 'private state'
$legacy=[pscustomobject]@{Operation='RunGuestJob'}
if($null -ne (Resolve-InstallerUacPolicyV2 $legacy $null)) { throw 'Legacy request acquired installer authority.' }
$checks++
& {
    Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    $user=[Microsoft.PowerShell.Commands.LocalUser]::new('synthetic')
    $user.SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
    $group='S-1-5-32-544'
    function Add-LocalGroupMember {
        param([Security.Principal.SecurityIdentifier]$SID,[Microsoft.PowerShell.Commands.LocalPrincipal[]]$Member)
        if($SID.Value -ne $group -or $Member.Count -ne 1 -or -not [object]::ReferenceEquals($Member[0],$user)){throw 'Account group membership did not bind the exact created principal.'}
    }
    $controller=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\GuestInstallerUac.ps1'),[ref]$null,[ref]$null)
    $membership=$controller.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-LocalGroupMember'},$true)
    Invoke-Expression $membership.Extent.Text
}
$checks++
function New-Receipt {
    $process=@{UserSid='S-1-5-21-1-2-3-1001';Elevated=$false;IntegrityRid=8192;SessionId=1;ProcessId=10;ImagePath='D:\Payload\setup.exe'}
    @{
        FormatVersion=2;InitialSessionFlags=1;RequestId='receipt-test';Decision='Accept';InitiatingUser='ManagedAdministrator'
        ExecutableSha256=('A'*64);VerifierSha256=('B'*64);ContractProven=$true;CleanupSucceeded=$true
        Identity=@{Initiator=@{Sid=$process.UserSid};ElevationAccount=@{Sid=$process.UserSid}}
        DesktopReady=@{Success=$true;Ready=@{InputDesktop='Default';Process=$process}}
        Input=@{Success=$true;Decision='Accept';CredentialEntered=$false;DesktopContext=@{Process=$process}}
        Before=@{Phase='Before';Process=$process;Passed=$true;CompletedUtc='2026-09-25T16:11:16.3269683Z'}
        After=@{Phase='After';Process=$process;Passed=$true;CompletedUtc='2026-09-25T16:12:34.5350262Z'}
        CleanupStartedUtc='2026-09-25T16:12:34.5528094Z'
        Prompt=@{Event=@{RequestorProcessId=11;EmitterProcessId=12};Requester=@{ProcessId=11};Consent=@{ProcessId=12};Root=$process}
        ElevatedProcess=@(@{UserSid=$process.UserSid;Elevated=$true;IntegrityRid=12288;SessionId=1;ProcessId=13;ImagePath=$process.ImagePath})
    }
}
$savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach($culture in @('fr-FR','en-US')) {
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach($representation in @('String','UtcDateTime','LocalDateTime','DateTimeOffset','Json')) {
            $receipt=New-Receipt
            if($representation -eq 'Json') { $receipt=$receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json }
            elseif($representation -ne 'String') {
                foreach($field in @(@($receipt.Before,'CompletedUtc'),@($receipt.After,'CompletedUtc'),@($receipt,'CleanupStartedUtc'))) {
                    $timestamp=[DateTimeOffset]$field[0][$field[1]]
                    $field[0][$field[1]]=switch($representation) {
                        UtcDateTime { $timestamp.UtcDateTime }
                        LocalDateTime { $timestamp.LocalDateTime }
                        DateTimeOffset { $timestamp.ToOffset([TimeSpan]::FromHours(2)) }
                    }
                }
            }
            if(-not (Test-InstallerUacReceipt $receipt $template.InstallerUac 'receipt-test')) { throw "Valid $representation timestamps rejected under $culture." }
            $checks++
        }
        foreach($change in @(
            {param($r) $r.Before.CompletedUtc=$r.After.CompletedUtc},
            {param($r) $r.Before.CompletedUtc='2026-09-25T16:12:34.5400000Z'},
            {param($r) $r.After.CompletedUtc=$r.CleanupStartedUtc},
            {param($r) $r.After.CompletedUtc='2026-09-25T16:12:34.5528095Z'},
            {param($r) $r.Before.CompletedUtc='invalid'},
            {param($r) $r.After.CompletedUtc=$null},
            {param($r) $r.CleanupStartedUtc=''},
            {param($r) $r.ExecutableSha256=('C'*64)}
        )) {
            $receipt=New-Receipt
            & $change $receipt
            if(Test-InstallerUacReceipt $receipt $template.InstallerUac 'receipt-test') { throw "Invalid receipt accepted under $culture." }
            $checks++
        }
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture }
@{Success=$true;ScenarioCount=$checks} | ConvertTo-Json
