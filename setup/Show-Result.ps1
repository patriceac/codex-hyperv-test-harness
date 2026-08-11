[CmdletBinding()]
param(
    [string] $InstallRoot = 'D:\Disk\VMs\Codex-Harness',
    [ValidateRange(0, 21600)] [int] $WaitSeconds = 0
)

$resultPath = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'Live\Setup\setup-result.json'
$statePath = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) 'Live\Setup\setup-state.json'
$deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
$lastLine = $null
while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $line = "[{0}] {1}" -f $state.Phase, $state.Message
        if ($line -ne $lastLine) { Write-Host $line; $lastLine = $line }
    }
    Start-Sleep -Seconds 5
}
if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Write-Host $result.Message -ForegroundColor $(if ($result.Success) { 'Green' } else { 'Red' })
    Write-Host "Result: $resultPath"
    if (-not $result.Success) { exit 1 }
}
elseif (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Write-Host ("No terminal result yet. Current state: [{0}] {1}" -f $state.Phase, $state.Message) -ForegroundColor Yellow
    Write-Host "State: $statePath"
}
else {
    Write-Host "No setup result or state was found under $InstallRoot." -ForegroundColor Yellow
}
