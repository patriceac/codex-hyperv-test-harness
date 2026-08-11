param(
    [string] $VmName = 'Codex-Harness-Baseline',
    [string] $InstallIso,
    [string] $SeedIso,
    [string] $CredentialPath,
    [string] $StatusPath,
    [string] $ConfigPath,
    [ValidateRange(0, 99)]
    [int] $ImageIndex = 0,
    [switch] $DeferBaselineCheckpoint
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HarnessPaths.ps1')
$layout = Get-CodexHarnessConfig -ConfigPath $ConfigPath
if ([string]::IsNullOrWhiteSpace($InstallIso)) {
    $isoCandidates = @(Get-ChildItem -LiteralPath (Join-Path ([string]$layout.RecoveryRoot) 'Media') -Filter 'Windows11-x64-*.iso' -File -ErrorAction SilentlyContinue)
    if ($isoCandidates.Count -ne 1) { throw 'Specify -InstallIso, or leave exactly one Windows11-x64-*.iso in Recovery\Media.' }
    $InstallIso = $isoCandidates[0].FullName
}
if ([string]::IsNullOrWhiteSpace($SeedIso)) { $SeedIso = Join-Path ([string]$layout.RecoveryRoot) 'Media\CodexGuestSeed.iso' }
if ([string]::IsNullOrWhiteSpace($CredentialPath)) { $CredentialPath = Join-Path ([string]$layout.HarnessSourceRoot) 'private\guest-credential.json' }
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Get-CodexHarnessManagementStatusPath -Config $layout -Name 'provision-status.json' }
$requiredEditionId = 'Professional'
$baselineName = [string]$layout.BaselineCheckpointName
$vmMemoryBytes = [long]$layout.VmMemoryBytes
$vmProcessorCount = [int]$layout.VmProcessorCount
$displayWidth = [int]$layout.GuestDisplayWidth
$displayHeight = [int]$layout.GuestDisplayHeight
$startedUtc = [DateTime]::UtcNow

function Write-ProvisionJsonAtomic {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $backupPath = $temporaryPath + '.bak'
    try {
        $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                    [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
                }
                else { [IO.File]::Move($temporaryPath, $Path) }
                return
            }
            catch [IO.IOException] { if ($attempt -ge 20) { throw } }
            catch [UnauthorizedAccessException] { if ($attempt -ge 20) { throw } }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-ProvisionStatus {
    param(
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $true)] [string] $Message,
        [hashtable] $Details = @{}
    )

    $status = [ordered]@{
        Success = $null
        Phase = $Phase
        Message = $Message
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        StartedUtc = $startedUtc.ToString('o')
        VmName = $VmName
        Details = $Details
    }
    Write-ProvisionJsonAtomic -Path $StatusPath -Value $status
}

function Complete-ProvisionStatus {
    param(
        [Parameter(Mandatory = $true)] [bool] $Success,
        [Parameter(Mandatory = $true)] [string] $Phase,
        [Parameter(Mandatory = $true)] [string] $Message,
        [hashtable] $Details = @{}
    )

    $status = [ordered]@{
        Success = $Success
        Phase = $Phase
        Message = $Message
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        VmName = $VmName
        Details = $Details
    }
    Write-ProvisionJsonAtomic -Path $StatusPath -Value $status
}

function Send-VmKey {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [uint32] $VirtualKey
    )

    $escapedName = $Name.Replace("'", "''")
    $vmComputer = Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName Msvm_ComputerSystem -Filter "ElementName='$escapedName'" |
        Where-Object { $_.Caption -eq 'Virtual Machine' } |
        Select-Object -First 1
    if (-not $vmComputer) {
        throw "Hyper-V WMI object not found for VM: $Name"
    }
    $keyboard = Get-CimAssociatedInstance -InputObject $vmComputer -Association Msvm_SystemDevice -ResultClassName Msvm_Keyboard |
        Select-Object -First 1
    if (-not $keyboard) {
        throw "Virtual keyboard not found for VM: $Name"
    }
    $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey -Arguments @{ keyCode = $VirtualKey }
    if ([uint32]$result.ReturnValue -ne 0) {
        throw "Virtual keyboard TypeKey failed with code $($result.ReturnValue)."
    }
}

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Provisioning must run from an elevated administrator process.'
    }

    foreach ($requiredPath in @($InstallIso, $SeedIso, $CredentialPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required file not found: $requiredPath"
        }
    }

    Write-ProvisionStatus -Phase 'VerifyingMedia' -Message 'Inspecting the validated Microsoft ISO and selecting Windows 11 Pro.'
    $actualHash = (Get-FileHash -LiteralPath $InstallIso -Algorithm SHA256).Hash

    $mountedImage = Mount-DiskImage -ImagePath $InstallIso -PassThru
    try {
        $installVolume = $mountedImage | Get-Volume
        $installRoot = $installVolume.DriveLetter + ':\'
        $setupPath = Join-Path $installRoot 'setup.exe'
        if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'The ISO does not contain setup.exe.' }
        $setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
        if ($setupSignature.Status -ne 'Valid' -or [string]$setupSignature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw 'The ISO setup executable is not validly signed by Microsoft.'
        }
        $installImage = Join-Path $installRoot 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $installImage)) {
            $installImage = Join-Path $installRoot 'sources\install.esd'
        }
        if (-not (Test-Path -LiteralPath $installImage)) {
            throw 'The verified ISO does not contain sources\install.wim or sources\install.esd.'
        }
        if ($ImageIndex -gt 0) {
            $selectedImage = Get-WindowsImage -ImagePath $installImage -Index $ImageIndex -ErrorAction Stop
            if ([string]$selectedImage.EditionId -ne $requiredEditionId) {
                throw "Windows image index $ImageIndex is EditionId '$($selectedImage.EditionId)', not '$requiredEditionId'."
            }
        }
        else {
            $professionalImages = @(Get-WindowsImage -ImagePath $installImage -ErrorAction Stop | Where-Object { [string]$_.EditionId -eq $requiredEditionId })
            if ($professionalImages.Count -ne 1) {
                throw "Expected exactly one Windows 11 Pro image (EditionId Professional); found $($professionalImages.Count)."
            }
            $selectedImage = $professionalImages[0]
            $ImageIndex = [int]$selectedImage.ImageIndex
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $InstallIso -ErrorAction SilentlyContinue | Out-Null
    }

    Import-Module Hyper-V
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.Generation -ne 2) {
        throw "Windows 11 requires a generation 2 VM; $VmName is generation $($vm.Generation)."
    }
    if ($vm.State -ne 'Off') {
        throw "VM must be off before provisioning; current state is $($vm.State)."
    }

    # Keep setup and the clean reusable baseline isolated. Networking can be
    # attached temporarily later only for an explicitly network-dependent test.
    Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Disconnect-VMNetworkAdapter

    Write-ProvisionStatus -Phase 'ConfiguringVm' -Message 'Configuring Windows 11 hardware, Secure Boot, and virtual TPM.'
    Set-VM -Name $VmName `
        -AutomaticCheckpointsEnabled $false `
        -CheckpointType Standard `
        -MemoryStartupBytes $vmMemoryBytes `
        -AutomaticStartAction StartIfRunning `
        -AutomaticStopAction ShutDown
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $vmMemoryBytes
    Set-VMProcessor -VMName $VmName -Count $vmProcessorCount
    Set-VMVideo -VMName $VmName -HorizontalResolution $displayWidth -VerticalResolution $displayHeight -ResolutionType Single
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

    $security = Get-VMSecurity -VMName $VmName
    if (-not $security.TpmEnabled) {
        Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
        Enable-VMTPM -VMName $VmName
    }

    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'

    $vmRoot = [IO.Path]::GetFullPath($vm.Path)
    $osDiskPath = Join-Path $vmRoot 'Windows11-Pro-TestOS.vhdx'
    # Free the SCSI locations before attaching the fresh Pro OS disk.
    Get-VMDvdDrive -VMName $VmName | Remove-VMDvdDrive
    $attachedDisks = @(Get-VMHardDiskDrive -VMName $VmName)
    foreach ($disk in $attachedDisks) {
        if (-not [string]::Equals([IO.Path]::GetFullPath($disk.Path), $osDiskPath, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-VMHardDiskDrive -VMHardDiskDrive $disk
        }
    }

    $osDisk = Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue |
        Where-Object { [string]::Equals([IO.Path]::GetFullPath($_.Path), $osDiskPath, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if (-not $osDisk) {
        if (-not (Test-Path -LiteralPath $osDiskPath)) {
            New-VHD -Path $osDiskPath -Dynamic -SizeBytes 80GB | Out-Null
        }
        $vhd = Get-VHD -Path $osDiskPath
        if ($vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne 80GB) {
            throw "Existing OS disk does not match the expected dynamic 80 GB lab disk: $osDiskPath"
        }
        Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 3 -Path $osDiskPath
        $osDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $osDiskPath
    }

    $mediaController = Get-VMScsiController -VMName $VmName | Where-Object ControllerNumber -eq 1 | Select-Object -First 1
    if (-not $mediaController) {
        Add-VMScsiController -VMName $VmName
    }
    $installDrive = Add-VMDvdDrive -VMName $VmName -ControllerNumber 1 -ControllerLocation 0 -Path $InstallIso -Passthru
    Add-VMDvdDrive -VMName $VmName -ControllerNumber 1 -ControllerLocation 1 -Path $SeedIso | Out-Null
    Set-VMFirmware -VMName $VmName -FirstBootDevice $installDrive

    Write-ProvisionStatus -Phase 'Installing' -Message 'Starting unattended Windows 11 Pro installation.' -Details @{
        IsoSha256 = $actualHash
        ImageIndex = $ImageIndex
        EditionId = [string]$selectedImage.EditionId
        ImageName = [string]$selectedImage.ImageName
    }
    Start-VM -Name $VmName | Out-Null

    # Generation 2 Windows media briefly displays "Press any key to boot from
    # CD or DVD". Hyper-V's virtual keyboard works without opening VMConnect.
    $keySent = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Start-Sleep -Milliseconds 500
        try {
            Send-VmKey -Name $VmName -VirtualKey 13
            $keySent = $true
        }
        catch {
            # The virtual keyboard can be unavailable for the first few hundred
            # milliseconds of firmware startup; the next attempt retries it.
        }
    }
    if (-not $keySent) {
        throw 'Could not inject a boot key through the Hyper-V virtual keyboard.'
    }

    $credentialData = Get-Content -Raw -LiteralPath $CredentialPath | ConvertFrom-Json
    $securePassword = ConvertTo-SecureString ([string]$credentialData.Password) -AsPlainText -Force
    $guestCredential = New-Object Management.Automation.PSCredential([string]$credentialData.UserName, $securePassword)
    $deadline = [DateTime]::UtcNow.AddMinutes(60)
    $lastStatusWrite = [DateTime]::MinValue
    $guestInfo = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        $vm = Get-VM -Name $VmName
        if ($vm.State -eq 'Off') {
            throw 'The VM powered off before the guest harness became ready.'
        }

        if (([DateTime]::UtcNow - $lastStatusWrite).TotalSeconds -ge 15) {
            Write-ProvisionStatus -Phase 'Installing' -Message 'Waiting for Windows 11 setup and the interactive guest agent.' -Details @{
                VmState = [string]$vm.State
                UptimeSeconds = [int]$vm.Uptime.TotalSeconds
            }
            $lastStatusWrite = [DateTime]::UtcNow
        }

        try {
            $guestInfo = Invoke-Command -VMName $VmName -Credential $guestCredential -ErrorAction Stop -ScriptBlock {
                $readyPath = 'C:\CodexGuest\ready.json'
                $statePath = 'C:\CodexGuest\agent-state.json'
                if (-not (Test-Path -LiteralPath $readyPath) -or -not (Test-Path -LiteralPath $statePath)) {
                    return $null
                }
                $ready = Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json
                $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
                $os = Get-CimInstance Win32_OperatingSystem
                $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
                [ordered]@{
                    Ready = [bool]$ready.Ready
                    AgentReady = [bool]$state.Ready
                    AgentHeartbeatUtc = [string]$state.HeartbeatUtc
                    AgentSessionId = [int]$state.SessionId
                    AgentUserInteractive = [bool]$state.UserInteractive
                    AgentUserName = [string]$state.UserName
                    OsCaption = [string]$os.Caption
                    OsVersion = [string]$os.Version
                    OsBuildNumber = [string]$os.BuildNumber
                    ProductName = [string]$currentVersion.ProductName
                    DisplayVersion = [string]$currentVersion.DisplayVersion
                    EditionId = [string]$currentVersion.EditionID
                }
            }
            if ($guestInfo -and $guestInfo.Ready -and $guestInfo.AgentReady -and $guestInfo.AgentUserInteractive) {
                break
            }
        }
        catch {
            # PowerShell Direct is unavailable during setup and between reboots.
        }
        Start-Sleep -Seconds 5
    }

    if (-not $guestInfo -or -not $guestInfo.AgentReady -or -not $guestInfo.AgentUserInteractive) {
        throw 'Timed out waiting for the interactive Windows 11 guest agent.'
    }
    if ([string]$guestInfo.EditionId -ne $requiredEditionId) {
        throw "Installed guest EditionId is '$($guestInfo.EditionId)', not '$requiredEditionId'."
    }

    $osDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $osDiskPath | Select-Object -First 1
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
    Get-VMDvdDrive -VMName $VmName | Set-VMDvdDrive -Path $null

    if ($DeferBaselineCheckpoint) {
        Complete-ProvisionStatus -Success $true -Phase 'ReadyForCustomization' -Message 'Windows 11 Pro is ready; the caller explicitly deferred the clean checkpoint.' -Details @{
            IsoSha256 = $actualHash
            ImageIndex = $ImageIndex
            EditionId = $requiredEditionId
            Guest = $guestInfo
            Baseline = $null
            BaselineCheckpointCreated = $false
            VmState = [string](Get-VM -Name $VmName).State
            OsDisk = $osDiskPath
        }
        return
    }

    Write-ProvisionStatus -Phase 'CreatingBaseline' -Message 'Guest agent is ready; creating the clean reusable checkpoint.' -Details @{
        Guest = $guestInfo
    }

    try {
        Invoke-Command -VMName $VmName -Credential $guestCredential -ErrorAction Stop -ScriptBlock {
            shutdown.exe /s /t 0
        }
    }
    catch {
        # The PowerShell Direct transport normally drops as shutdown begins.
    }

    $shutdownDeadline = [DateTime]::UtcNow.AddMinutes(3)
    while ((Get-VM -Name $VmName).State -ne 'Off' -and [DateTime]::UtcNow -lt $shutdownDeadline) {
        Start-Sleep -Seconds 2
    }
    if ((Get-VM -Name $VmName).State -ne 'Off') {
        throw 'Guest did not shut down in time for the clean checkpoint.'
    }

    if (-not (Get-VMSnapshot -VMName $VmName -Name $baselineName -ErrorAction SilentlyContinue)) {
        Checkpoint-VM -VMName $VmName -SnapshotName $baselineName
    }

    Complete-ProvisionStatus -Success $true -Phase 'Ready' -Message 'Windows 11 Pro guest and clean automation baseline are ready.' -Details @{
        IsoSha256 = $actualHash
        ImageIndex = $ImageIndex
        EditionId = $requiredEditionId
        Guest = $guestInfo
        Baseline = $baselineName
        VmState = [string](Get-VM -Name $VmName).State
        OsDisk = $osDiskPath
    }
}
catch {
    Complete-ProvisionStatus -Success $false -Phase 'Failed' -Message $_.Exception.Message -Details @{
        ScriptStackTrace = $_.ScriptStackTrace
    }
    throw
}
