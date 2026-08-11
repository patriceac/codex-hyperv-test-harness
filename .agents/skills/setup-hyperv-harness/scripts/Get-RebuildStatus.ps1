[CmdletBinding()]
param([string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness')

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$statePath = Join-Path $InstallRoot 'Live\Setup\setup-state.json'
$resultPath = Join-Path $InstallRoot 'Live\Setup\setup-result.json'
$task = Get-ScheduledTask -TaskName 'Codex Hyper-V Source Rebuild Resume' -ErrorAction SilentlyContinue
[pscustomobject][ordered]@{
    InstallRoot = $InstallRoot
    State = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    Result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    ResumeTask = if ($task) { [pscustomobject]@{ State = [string]$task.State; TaskPath = [string]$task.TaskPath; TaskName = [string]$task.TaskName } } else { $null }
}
