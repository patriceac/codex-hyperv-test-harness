[CmdletBinding()]
param(
    [string] $HostBrokerPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HostBrokerPath)) {
    $HostBrokerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'HostBroker.ps1'
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($HostBrokerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
$writerAst = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-JsonAtomic'
}, $true)) | Select-Object -First 1
if (-not $writerAst) { throw 'Write-JsonAtomic was not found.' }
$writerBody = $writerAst.Body.Extent.Text
$writerBody = $writerBody.Substring(1, $writerBody.Length - 2)
$writerBodyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($writerBody))

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-atomic-json-' + [Guid]::NewGuid().ToString('N'))
$targetPath = Join-Path $testRoot 'state.json'
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$processes = New-Object Collections.Generic.List[object]
$scenarios = New-Object Collections.Generic.List[string]
# HostBroker is installed as a Windows PowerShell SYSTEM task. Exercise its
# contention behavior in that exact runtime even when the umbrella source test
# itself was launched from PowerShell 7.
$testPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
try {
    Set-Item -LiteralPath 'Function:\script:Write-JsonAtomic' -Value ([scriptblock]::Create($writerBody))
    Write-JsonAtomic -Path $targetPath -Value ([ordered]@{ Writer = -1; Iteration = -1; Token = [Guid]::NewGuid().ToString('N') })

    for ($writer = 0; $writer -lt 6; $writer++) {
        $stdoutPath = Join-Path $testRoot ("writer-$writer.stdout.txt")
        $stderrPath = Join-Path $testRoot ("writer-$writer.stderr.txt")
        $successPath = Join-Path $testRoot ("writer-$writer.success")
        $workerCommand = @"
`$ErrorActionPreference = 'Stop'
`$body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$writerBodyBase64'))
Set-Item -LiteralPath 'Function:\script:Write-JsonAtomic' -Value ([scriptblock]::Create(`$body))
for (`$iteration = 0; `$iteration -lt 80; `$iteration++) {
    Write-JsonAtomic -Path '$($targetPath.Replace("'", "''"))' -Value ([ordered]@{ Writer = $writer; Iteration = `$iteration; Token = [Guid]::NewGuid().ToString('N') })
}
[IO.File]::WriteAllText('$($successPath.Replace("'", "''"))', 'ok')
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
        $process = Start-Process -FilePath $testPowerShell -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand
        ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        $processes.Add([pscustomobject]@{ Process = $process; StdOut = $stdoutPath; StdErr = $stderrPath; Success = $successPath })
    }

    $parseFailures = 0
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $allExited = $true
        foreach ($entry in $processes) {
            $entry.Process.Refresh()
            if (-not $entry.Process.HasExited) { $allExited = $false }
        }
        try { $json = Get-Content -Raw -LiteralPath $targetPath -ErrorAction Stop }
        catch { $json = $null }
        if ($null -ne $json) {
            try { $null = $json | ConvertFrom-Json -ErrorAction Stop }
            catch { $parseFailures++ }
        }
        if (-not $allExited) { Start-Sleep -Milliseconds 5 }
    } while (-not $allExited -and [DateTime]::UtcNow -lt $deadline)

    $failedWriters = New-Object Collections.Generic.List[string]
    foreach ($entry in $processes) {
        $entry.Process.Refresh()
        if (-not $entry.Process.HasExited) {
            Stop-Process -Id $entry.Process.Id -Force -ErrorAction SilentlyContinue
            $failedWriters.Add("PID $($entry.Process.Id) timed out")
            continue
        }
        $entry.Process.WaitForExit()
        if (-not (Test-Path -LiteralPath $entry.Success -PathType Leaf)) {
            $stderr = if (Test-Path -LiteralPath $entry.StdErr) { Get-Content -Raw -LiteralPath $entry.StdErr } else { '' }
            $failedWriters.Add("PID $($entry.Process.Id) did not publish success: $stderr")
        }
    }
    Assert-True ($failedWriters.Count -eq 0) ("Concurrent atomic writers failed: " + ($failedWriters -join ' | '))
    Assert-True ($parseFailures -eq 0) "Readers observed $parseFailures partial or invalid JSON documents."
    $final = Get-Content -Raw -LiteralPath $targetPath | ConvertFrom-Json
    Assert-True ($null -ne $final.Writer -and $null -ne $final.Iteration -and -not [string]::IsNullOrWhiteSpace([string]$final.Token)) 'The final atomic JSON document was incomplete.'
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter 'state.json.*.tmp' -File -ErrorAction SilentlyContinue).Count -eq 0) 'An atomic writer leaked temporary files.'
    $scenarios.Add('six-process-writer-reader-contention')

    $requiredFiles = @(
        $HostBrokerPath,
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'PoolCommon.ps1'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'seed\guest\GuestAgent.ps1'),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Skill\scripts\Invoke-HyperVExecutableTest.ps1'),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Recovery\RecoveryCommon.ps1')
    )
    foreach ($path in $requiredFiles) {
        $text = Get-Content -Raw -LiteralPath $path
        Assert-True ($text.Contains('[IO.File]::Replace') -and $text.Contains("[Guid]::NewGuid().ToString('N')")) "Atomic replacement hardening is missing from $path"
    }
    $scenarios.Add('all-json-writer-boundaries-use-replace-and-unique-staging')
}
finally {
    foreach ($entry in $processes) {
        try {
            $entry.Process.Refresh()
            if (-not $entry.Process.HasExited) { Stop-Process -Id $entry.Process.Id -Force -ErrorAction SilentlyContinue }
            $entry.Process.Dispose()
        }
        catch { }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
