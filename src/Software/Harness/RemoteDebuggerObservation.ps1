function Start-RemoteDebuggerObservationV1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z')] [string] $RequestId,
        [Parameter(Mandatory = $true)] [DateTime] $ExecutionDeadlineUtc
    )
    if ($ExecutionDeadlineUtc.ToUniversalTime() -le [DateTime]::UtcNow) { throw 'The observation deadline has expired.' }
    Invoke-Command -Session $Session -AsJob -ErrorAction Stop -ArgumentList $RequestId, $ExecutionDeadlineUtc.ToUniversalTime().ToString('o') -ScriptBlock {
        param([string] $RequestId, [string] $DeadlineText)
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        $deadline = [DateTime]::Parse($DeadlineText).ToUniversalTime()
        $root = 'C:\CodexGuest\Provisioning\' + $RequestId
        $receiptPath = Join-Path $root 'remote-debugger-provisioning.json'
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'The fixed observer requires successful protected provisioning evidence.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'The fixed observer requires the administrator Direct session.' }
        $outputPath = Join-Path $root 'remote-debugger-observation.json'
        $completedPath = 'C:\CodexGuest\Outbox\' + $RequestId + '\result.json'
        do {
            $power = [ordered]@{ ExitCode = -1; Stdout = ''; Stderr = '' }
            $firewall = [ordered]@{ ExitCode = -1; Stdout = ''; Stderr = '' }
            $services = @()
            try {
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.FileName = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'powercfg.exe'
                $start.Arguments = '/requests'
                $start.UseShellExecute = $false
                $start.CreateNoWindow = $true
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                $process = [Diagnostics.Process]::Start($start)
                try {
                    $stdout = $process.StandardOutput.ReadToEndAsync()
                    $stderr = $process.StandardError.ReadToEndAsync()
                    if (-not $process.WaitForExit(5000)) { try { $process.Kill() } catch { }; throw 'powercfg observation timed out.' }
                    $process.WaitForExit()
                    $power.ExitCode = $process.ExitCode
                    $power.Stdout = [string]$stdout.Result
                    $power.Stderr = [string]$stderr.Result
                    if ($power.Stdout.Length -gt 65536) { $power.Stdout = $power.Stdout.Substring(0, 65536) }
                }
                finally { $process.Dispose() }
            }
            catch { $power.Stderr = $_.Exception.Message }
            try {
                $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -like '*Remote Debugger*' -or $_.Name -like '*RemoteDebugger*' } | ForEach-Object {
                    $port = $_ | Get-NetFirewallPortFilter -ErrorAction Stop
                    $address = $_ | Get-NetFirewallAddressFilter -ErrorAction Stop
                    [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Enabled = $_.Enabled; Profile = $_.Profile; Direction = $_.Direction; Action = $_.Action; Protocol = $port.Protocol; LocalPort = $port.LocalPort; RemoteAddress = $address.RemoteAddress }
                } | Select-Object -First 32)
                $firewall.ExitCode = 0
                $firewall.Stdout = ConvertTo-Json -InputObject @($rules) -Compress -Depth 5
            }
            catch { $firewall.Stderr = $_.Exception.Message }
            try {
                $services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'RemoteDebugger%'" -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -First 16 Name, State, StartMode, StartName, PathName)
            }
            catch { $services = @([pscustomobject]@{ Error = $_.Exception.Message }) }
            $snapshot = [ordered]@{ FormatVersion = 1; RequestId = $RequestId; CapturedUtc = [DateTime]::UtcNow.ToString('o'); PowerRequests = $power; Firewall = $firewall; Services = @($services) }
            $temporaryPath = $outputPath + '.tmp'
            try {
                $snapshot | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
                if ([IO.File]::Exists($outputPath)) { [IO.File]::Replace($temporaryPath, $outputPath, [NullString]::Value, $true) }
                else { [IO.File]::Move($temporaryPath, $outputPath) }
            }
            finally { if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force } }
            if ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $completedPath -PathType Leaf)) { Start-Sleep -Seconds 2 }
        } while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $completedPath -PathType Leaf))
    }
}

function Stop-RemoteDebuggerObservationV1 {
    param($Job, $Session)
    try {
        if ($Job) {
            try { if ($Job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $Job -ErrorAction Stop } }
            finally { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue }
        }
    }
    finally { if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue } }
}
