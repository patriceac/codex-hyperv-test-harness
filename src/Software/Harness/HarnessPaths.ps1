Set-StrictMode -Version Latest

function Get-CodexHarnessConfig {
    [CmdletBinding()]
    param([string] $ConfigPath)

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'harness-config.json'
    }
    $resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Harness configuration is missing: $resolvedConfigPath"
    }
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
    if ([int]$config.FormatVersion -ne 1) {
        throw "Unsupported harness configuration version: $($config.FormatVersion)"
    }
    $installRoot = [IO.Path]::GetFullPath([string]$config.InstallRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($installRoot) -or [IO.Path]::GetPathRoot($installRoot) -eq $installRoot) {
        throw 'InstallRoot must be a specific non-root directory.'
    }
    foreach ($name in @('LiveRoot', 'BaselineRoot', 'BrokerRoot', 'SoftwareRoot', 'HarnessSourceRoot', 'SkillSourceRoot', 'RecoveryRoot')) {
        $value = [IO.Path]::GetFullPath([string]$config.$name)
        if (-not ($value + '\').StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "$name escapes InstallRoot: $value"
        }
    }
    if ([int]$config.PoolSize -lt 1 -or [int]$config.PoolSize -gt 4) {
        throw 'PoolSize must be between one and four.'
    }
    if ([long]$config.VmMemoryBytes -lt 2GB -or [long]$config.VmMemoryBytes -gt 64GB) {
        throw 'VmMemoryBytes must be between 2 GiB and 64 GiB.'
    }
    if ([int]$config.VmProcessorCount -lt 1 -or [int]$config.VmProcessorCount -gt 64) {
        throw 'VmProcessorCount must be between one and 64.'
    }
    if ([int]$config.GuestDisplayWidth -lt 1024 -or [int]$config.GuestDisplayWidth -gt 7680 -or
        [int]$config.GuestDisplayHeight -lt 768 -or [int]$config.GuestDisplayHeight -gt 4320) {
        throw 'Guest display dimensions must be between 1024x768 and 7680x4320.'
    }
    $config | Add-Member -NotePropertyName ConfigPath -NotePropertyValue $resolvedConfigPath -Force
    $config
}

function Get-CodexHarnessManagementStatusPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Config,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    Join-Path ([string]$Config.BrokerRoot) (Join-Path 'State\Management' $Name)
}
