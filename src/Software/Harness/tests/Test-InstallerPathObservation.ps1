[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\InstallerUacObservations.ps1')
Initialize-InstallerPathObservation
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$root=Join-Path $repositoryRoot ('work\installer-observation-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'sample.txt'
[IO.File]::WriteAllText($path,'Bounded metadata observation')
$observed=[CodexInstallerPathObservation]::Read($path,'sample')
if($observed.Status -cne 'Found' -or $observed.Kind -cne 'File' -or $observed.Sha256 -cne (Get-FileHash -LiteralPath $path).Hash -or -not $observed.OwnerSid -or -not $observed.Sddl) { throw ('File identity observation failed: '+($observed | ConvertTo-Json -Compress)) }
$missing=[CodexInstallerPathObservation]::Read((Join-Path $root 'absent.txt'),'absent')
if($missing.Status -cne 'Absent') { throw 'A genuinely missing path was not reported absent.' }
$held=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $locked=[CodexInstallerPathObservation]::Read($path,'locked')
    if($locked.Status -cne 'Unobservable' -or $locked.ErrorCode -ne 32) { throw 'A sharing denial was confused with absence or readable content.' }
} finally { $held.Dispose() }
$target=Join-Path $root 'target'
$null=[IO.Directory]::CreateDirectory($target)
[IO.File]::WriteAllText((Join-Path $target 'redirected.txt'),'Do not follow this link')
$link=Join-Path $root 'link'
$null=New-Item -ItemType Junction -Path $link -Value $target
$redirected=[CodexInstallerPathObservation]::Read((Join-Path $link 'redirected.txt'),'redirected')
if($redirected.Status -cne 'ReparsePointRefused' -or $redirected.Sha256) { throw 'Privileged observation followed a redirected ancestor.' }
$lease=[CodexInstallerPathObservation]::OpenBoundFile($path,$observed.Sha256,1048576)
try {
    $rejected=$false
    try{$writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$writer.Dispose()}catch{$rejected=$true}
    if(-not $rejected){throw 'A hash-bound executable could be modified while its lease was retained.'}
}finally{$lease.Dispose()}
$rejected=$false
try{$lease=[CodexInstallerPathObservation]::OpenBoundFile($path,('A'*64),1048576);$lease.Dispose()}catch{$rejected=$true}
if(-not $rejected){throw 'File lease accepted the wrong executable hash.'}
$controller=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\GuestInstallerUac.ps1'),[ref]$null,[ref]$null)
$readerFunction=$controller.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-InstallerBoundJson'},$true)
Invoke-Expression $readerFunction.Extent.Text
$jsonPath=Join-Path $root 'result.json'
[IO.File]::WriteAllText($jsonPath,'{"passed":true}')
if(-not (Read-InstallerBoundJson $jsonPath).passed){throw 'Bound verifier JSON could not be read without an executable hash.'}
@{Success=$true;ScenarioCount=7} | ConvertTo-Json
