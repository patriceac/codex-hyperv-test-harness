[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $LauncherProcessId,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [long]::MaxValue)]
    [long] $LauncherStartTimeUtcTicks,

    [Parameter(Mandatory = $true)]
    [string] $CancellationPath,

    [ValidateRange(100, 5000)]
    [int] $PollMilliseconds = 500
)

$ErrorActionPreference = 'Stop'
$CancellationPath = [IO.Path]::GetFullPath($CancellationPath)

while ($true) {
    $launcher = Get-Process -Id $LauncherProcessId -ErrorAction SilentlyContinue
    if (-not $launcher) { break }
    if ($launcher.StartTime.ToUniversalTime().Ticks -ne $LauncherStartTimeUtcTicks) { break }
    Start-Sleep -Milliseconds $PollMilliseconds
}

$parent = Split-Path -Parent $CancellationPath
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$temporary = $CancellationPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
try {
    [ordered]@{
        RequestedUtc = [DateTime]::UtcNow.ToString('o')
        Reason = 'The visible image-maintenance launcher exited.'
        LauncherProcessId = $LauncherProcessId
        LauncherStartTimeUtcTicks = $LauncherStartTimeUtcTicks
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $CancellationPath -Force
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
