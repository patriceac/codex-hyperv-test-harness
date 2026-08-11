[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [ValidateRange(1, 4)] [int] $PoolSize = 4,
    [ValidateRange(2, 64)] [int] $VmMemoryGiB = 8,
    [switch] $AllowLowResources,
    [switch] $AsJson,
    [switch] $ReportOnly
)

$ErrorActionPreference = 'Stop'
$checks = New-Object Collections.Generic.List[object]
function Add-Check {
    param([string] $Name, [bool] $Passed, [bool] $Required, [string] $Message, $Details = $null)
    $checks.Add([pscustomobject][ordered]@{ Name = $Name; Passed = $Passed; Required = $Required; Message = $Message; Details = $Details })
}

$os = Get-CimInstance Win32_OperatingSystem
$windows11 = [version]$os.Version -ge [version]'10.0.22000.0'
Add-Check -Name 'Windows11' -Passed $windows11 -Required $true -Message $(if ($windows11) { 'Windows 11 detected.' } else { "Windows 11 is required; detected $($os.Caption) $($os.Version)." }) -Details $os.Caption

$edition = $null
try { $edition = [string](Get-WindowsEdition -Online -ErrorAction Stop).Edition } catch { }
if ([string]::IsNullOrWhiteSpace($edition)) {
    try { $edition = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID } catch { }
}
$supportedEdition = $edition -in @('Professional', 'ProfessionalN', 'Enterprise', 'EnterpriseN', 'Education', 'EducationN')
Add-Check -Name 'HostEdition' -Passed $supportedEdition -Required $true -Message $(if ($supportedEdition) { "Host edition $edition supports Hyper-V." } else { "A Windows Pro, Enterprise, or Education host is required; detected '$edition'." }) -Details $edition

$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$computer = Get-CimInstance Win32_ComputerSystem
$hypervisorPresent = [bool]$computer.HypervisorPresent
$virtualization = $hypervisorPresent -or ([bool]$processor.VirtualizationFirmwareEnabled -and [bool]$processor.SecondLevelAddressTranslationExtensions)
$virtualizationMessage = if ($hypervisorPresent) { 'The Windows hypervisor is already active.' } elseif ($virtualization) { 'Firmware virtualization and SLAT are available.' } else { 'Enable hardware virtualization in firmware; SLAT is also required.' }
Add-Check -Name 'Virtualization' -Passed $virtualization -Required $true -Message $virtualizationMessage -Details @{ HypervisorPresent = $hypervisorPresent; VirtualizationFirmwareEnabled = $processor.VirtualizationFirmwareEnabled; Slat = $processor.SecondLevelAddressTranslationExtensions }

$root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($InstallRoot))
$drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $root.TrimEnd('\') + "'") -ErrorAction SilentlyContinue
$freeGiB = if ($drive) { [Math]::Round([double]$drive.FreeSpace / 1GB, 1) } else { 0 }
$minimumFreeBytes = [long]200GB
$diskOkay = $drive -and $drive.DriveType -eq 3 -and $drive.FreeSpace -ge $minimumFreeBytes
Add-Check -Name 'Storage' -Passed ($diskOkay -or $AllowLowResources) -Required $true -Message $(if ($diskOkay) { "$freeGiB GiB free on $root." } else { "$root should be a local fixed drive with at least 200 GiB free; detected $freeGiB GiB." }) -Details @{ Root = $root; FreeGiB = $freeGiB; RequiredFreeGiB = 200; DriveType = $(if ($drive) { $drive.DriveType } else { $null }) }

$totalGiB = [Math]::Round([double]$computer.TotalPhysicalMemory / 1GB, 1)
$recommendedGiB = [Math]::Max(16, ($PoolSize * $VmMemoryGiB) + 8)
$memoryOkay = $computer.TotalPhysicalMemory -ge ($recommendedGiB * 1GB)
Add-Check -Name 'Memory' -Passed ($memoryOkay -or $AllowLowResources) -Required $true -Message $(if ($memoryOkay) { "$totalGiB GiB host RAM detected." } else { "$recommendedGiB GiB host RAM is recommended for $PoolSize workers at $VmMemoryGiB GiB each; detected $totalGiB GiB." }) -Details @{ TotalGiB = $totalGiB; RecommendedGiB = $recommendedGiB }

$edgePaths = @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'), (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
$edge = $edgePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
$edgeValid = $false
if ($edge) {
    $signature = Get-AuthenticodeSignature -LiteralPath $edge
    $edgeValid = $signature.Status -eq 'Valid' -and [string]$signature.SignerCertificate.Subject -match 'Microsoft'
}
Add-Check -Name 'MicrosoftEdge' -Passed $edgeValid -Required $true -Message $(if ($edgeValid) { 'Signed Microsoft Edge is available for official ISO resolution.' } else { 'Signed Microsoft Edge is required to resolve the official ISO link.' }) -Details $edge

$bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
Add-Check -Name 'BitsTransfer' -Passed ($null -ne $bits) -Required $true -Message $(if ($bits) { 'BITS is available for resumable official-media download.' } else { 'The BitsTransfer module and Start-BitsTransfer are required.' }) -Details $(if ($bits) { $bits.Source } else { $null })

$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
Add-Check -Name 'CSharpCompiler' -Passed ($null -ne $compiler) -Required $true -Message $(if ($compiler) { 'The inbox .NET Framework C# compiler is available.' } else { 'The inbox .NET Framework C# compiler is required to rebuild guest tools and canaries.' }) -Details $compiler

$imapiAvailable = $false
$imapiError = $null
$imapi = $null
try {
    $imapi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $imapiAvailable = $null -ne $imapi
}
catch { $imapiError = $_.Exception.Message }
finally {
    if ($imapi) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($imapi) }
}
Add-Check -Name 'Imapi' -Passed $imapiAvailable -Required $true -Message $(if ($imapiAvailable) { 'Windows IMAPI is available for native seed-ISO creation.' } else { 'Windows IMAPI is required to create the unattended seed ISO.' }) -Details $imapiError

$mediaPage = 'https://www.microsoft.com/software-download/windows11'
$mediaReachable = $false
$mediaReachability = $null
try {
    $response = Invoke-WebRequest -Uri $mediaPage -UseBasicParsing -Method Head -TimeoutSec 20 -ErrorAction Stop
    $mediaReachable = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
    $mediaReachability = [ordered]@{ StatusCode = [int]$response.StatusCode; FinalUri = [string]$response.BaseResponse.ResponseUri.AbsoluteUri }
}
catch { $mediaReachability = [ordered]@{ Error = $_.Exception.Message } }
Add-Check -Name 'OfficialMediaPage' -Passed $mediaReachable -Required $true -Message $(if ($mediaReachable) { 'The official Microsoft Windows 11 download page is reachable.' } else { 'The official Microsoft Windows 11 download page is not reachable; check internet, proxy, and TLS settings.' }) -Details $mediaReachability

$feature = $null
try { $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop } catch { }
$featureState = if ($feature) { [string]$feature.State } else { 'UnknownWithoutElevation' }
Add-Check -Name 'HyperVFeature' -Passed $true -Required $false -Message $(if ($featureState -eq 'Enabled') { 'Hyper-V is enabled.' } elseif ($featureState -eq 'UnknownWithoutElevation') { 'Hyper-V feature state will be checked after elevation.' } else { 'Hyper-V is not enabled; the installer can enable it and resume after restart.' }) -Details $featureState

$result = [pscustomobject][ordered]@{
    Success = @($checks | Where-Object { $_.Required -and -not $_.Passed }).Count -eq 0
    CheckedUtc = [DateTime]::UtcNow.ToString('o')
    InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    Checks = $checks.ToArray()
}
if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
if (-not $result.Success -and -not $ReportOnly) { exit 1 }
