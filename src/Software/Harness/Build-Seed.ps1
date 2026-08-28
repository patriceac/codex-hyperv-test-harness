param(
    [ValidateRange(0, 99)]
    [int] $ImageIndex = 0,
    [string] $InstallIso,
    [string] $ConfigPath,
    [string] $OutputIso,
    [ValidatePattern('^[a-z]{2,3}(?:-[A-Za-z0-9]+)+$')] [string] $UiLanguage = 'en-US',
    [string] $InputLocale,
    [string] $TimeZone,
    [switch] $RotateCredential
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
$templatePath = Join-Path $scriptRoot 'Autounattend.template.xml'
$guestSource = Join-Path $scriptRoot 'seed\guest'
$buildRoot = [IO.Path]::GetFullPath((Join-Path $scriptRoot 'seed-build'))
$expectedBuildRoot = [IO.Path]::GetFullPath((Join-Path $scriptRoot 'seed-build'))
$privateRoot = Join-Path $scriptRoot 'private'
$credentialPath = Join-Path $privateRoot 'guest-credential.json'
$mediaRoot = Join-Path ([string]$layout.RecoveryRoot) 'Media'
if ([string]::IsNullOrWhiteSpace($OutputIso)) { $OutputIso = Join-Path $mediaRoot 'CodexGuestSeed.iso' }
$outputIso = [IO.Path]::GetFullPath($OutputIso)
if ([string]::IsNullOrWhiteSpace($InputLocale)) { $InputLocale = $UiLanguage }
if ([string]::IsNullOrWhiteSpace($TimeZone)) { $TimeZone = [string](Get-TimeZone).Id }

if ($ImageIndex -eq 0) {
    if ([string]::IsNullOrWhiteSpace($InstallIso)) { throw 'Specify -InstallIso so Build-Seed can select the Professional image dynamically.' }
    $mountedImage = Mount-DiskImage -ImagePath $InstallIso -PassThru -ErrorAction Stop
    try {
        $installVolume = $mountedImage | Get-Volume | Select-Object -First 1
        $installRoot = $installVolume.DriveLetter + ':\'
        $installImage = Join-Path $installRoot 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $installImage -PathType Leaf)) { $installImage = Join-Path $installRoot 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $installImage -PathType Leaf)) { throw 'The Windows ISO contains neither sources\install.wim nor sources\install.esd.' }
        $professional = @(Get-WindowsImage -ImagePath $installImage -ErrorAction Stop | Where-Object { [string]$_.EditionId -eq 'Professional' })
        if ($professional.Count -ne 1) { throw "Expected exactly one Professional image; found $($professional.Count)." }
        $ImageIndex = [int]$professional[0].ImageIndex
    }
    finally {
        Dismount-DiskImage -ImagePath $InstallIso -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($buildRoot -ne $expectedBuildRoot -or -not $buildRoot.StartsWith($scriptRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean unexpected build path: $buildRoot"
}

New-Item -ItemType Directory -Force -Path $privateRoot, $mediaRoot | Out-Null

if ($RotateCredential -or -not (Test-Path -LiteralPath $credentialPath)) {
    $randomBytes = New-Object byte[] 32
    $randomNumberGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $randomNumberGenerator.GetBytes($randomBytes)
    }
    finally {
        $randomNumberGenerator.Dispose()
    }
    $password = 'Cx!' + [BitConverter]::ToString($randomBytes).Replace('-', '')
    [ordered]@{
        UserName = 'CodexTest'
        ComputerName = 'CODEX-W11'
        Password = $password
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $credentialPath -Encoding UTF8

    $credentialAcl = New-Object Security.AccessControl.FileSecurity
    $credentialAcl.SetAccessRuleProtection($true, $false)
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemIdentity = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $administratorsIdentity = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    foreach ($identity in @($currentIdentity, $systemIdentity, $administratorsIdentity)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $credentialAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $credentialPath -AclObject $credentialAcl
}

$credential = Get-Content -Raw -LiteralPath $credentialPath | ConvertFrom-Json
$escapedPassword = [Security.SecurityElement]::Escape([string]$credential.Password)
$imageIndexText = $ImageIndex.ToString([Globalization.CultureInfo]::InvariantCulture)
$escapedUiLanguage = [Security.SecurityElement]::Escape($UiLanguage)
$escapedInputLocale = [Security.SecurityElement]::Escape($InputLocale)
$escapedTimeZone = [Security.SecurityElement]::Escape($TimeZone)

try {
    if (Test-Path -LiteralPath $buildRoot) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $buildRoot 'guest') | Out-Null

$answerFile = (Get-Content -Raw -LiteralPath $templatePath).
    Replace('__CODEX_PASSWORD__', $escapedPassword).
    Replace('__CODEX_IMAGE_INDEX__', $imageIndexText).
    Replace('__CODEX_UI_LANGUAGE__', $escapedUiLanguage).
    Replace('__CODEX_INPUT_LOCALE__', $escapedInputLocale).
    Replace('__CODEX_TIME_ZONE__', $escapedTimeZone)
if ($answerFile.Contains('__CODEX_')) {
    throw 'The unattended answer file still contains an unresolved Codex template token.'
}
$answerFilePath = Join-Path $buildRoot 'Autounattend.xml'
[IO.File]::WriteAllText($answerFilePath, $answerFile, (New-Object Text.UTF8Encoding($true)))

Copy-Item -LiteralPath (Join-Path $guestSource 'GuestAgent.ps1') -Destination (Join-Path $buildRoot 'guest') -Force
Copy-Item -LiteralPath (Join-Path $guestSource 'GuestAgentSupervisor.ps1') -Destination (Join-Path $buildRoot 'guest') -Force
Copy-Item -LiteralPath (Join-Path $guestSource 'GuestLiveEvidence.ps1') -Destination (Join-Path $buildRoot 'guest') -Force
Copy-Item -LiteralPath (Join-Path $guestSource 'Install-GuestHarness.ps1') -Destination (Join-Path $buildRoot 'guest') -Force
$inputProbe = & (Join-Path $scriptRoot 'Build-GuestTools.ps1') -GuestSourceRoot $guestSource
Copy-Item -LiteralPath ([string]$inputProbe.Output) -Destination (Join-Path $buildRoot 'guest\InputProbe.exe') -Force

& (Join-Path $scriptRoot 'New-DataIso.ps1') -SourceDirectory $buildRoot -DestinationIso $outputIso -VolumeName 'CODEXSEED' | Out-Null

$answerXml = New-Object Xml.XmlDocument
$answerXml.PreserveWhitespace = $true
$answerXml.Load($answerFilePath)

    $result = [ordered]@{
        IsoPath = $outputIso
        IsoLength = (Get-Item -LiteralPath $outputIso).Length
        IsoSha256 = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash
        AnswerFile = $null
        UserName = [string]$credential.UserName
        ComputerName = [string]$credential.ComputerName
        ImageIndex = $ImageIndex
        UiLanguage = $UiLanguage
        InputLocale = $InputLocale
        TimeZone = $TimeZone
        CredentialRotated = [bool]$RotateCredential
    }
}
finally {
    if (Test-Path -LiteralPath $buildRoot -PathType Container) {
        Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$result | ConvertTo-Json
