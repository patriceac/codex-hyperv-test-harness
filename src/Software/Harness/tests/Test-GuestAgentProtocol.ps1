[CmdletBinding()]
param(
    [string] $GuestAgentPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'seed\guest\GuestAgent.ps1')
)

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($GuestAgentPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }

function Import-GuestFunction {
    param([Parameter(Mandatory = $true)] [string] $Name)
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $definition) { throw "Guest function not found: $Name" }
    $body = $definition.Body.Extent.Text
    $body = $body.Substring(1, $body.Length - 2)
    Set-Item -LiteralPath ("Function:\script:$Name") -Value ([scriptblock]::Create($body))
}

foreach ($name in @(
    'Resolve-JsonPointerValue',
    'Test-IsJsonNumber',
    'Test-JsonValuesEqual',
    'Test-GuestResultAssertion',
    'Wait-GuestResultFile',
    'Get-GuestProcessTree',
    'Capture-Screen'
)) {
    Import-GuestFunction -Name $name
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-guest-protocol-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$scenarios = New-Object Collections.Generic.List[string]
try {
    $resultPath = Join-Path $testRoot 'result.json'
    [ordered]@{ passed = $true; nested = [ordered]@{ 'a/b' = @(1, 2, 3) } } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    $pass = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/passed' -ExpectedJson 'true'
    Assert-True $pass.Passed 'A typed boolean JSON assertion did not pass.'
    $scenarios.Add('typed-json-boolean-pass')

    $failure = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/passed' -ExpectedJson 'false'
    Assert-True (-not $failure.Passed -and $failure.FailureKind -eq 'TestAssertion') 'A false JSON assertion was not classified as TestAssertion.'
    $scenarios.Add('typed-json-boolean-failure')

    $escaped = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/nested/a~1b/1' -ExpectedJson '2'
    Assert-True $escaped.Passed 'RFC 6901 slash escaping or array traversal failed.'
    $scenarios.Add('json-pointer-escape-and-array')

    $missing = Test-GuestResultAssertion -Path $resultPath -JsonPointer '/missing' -ExpectedJson 'true'
    Assert-True (-not $missing.Passed -and $missing.FailureKind -eq 'JsonPointerMissing') 'A missing JSON pointer was not classified correctly.'
    $scenarios.Add('missing-json-pointer')

    $presentWait = Wait-GuestResultFile -Path $resultPath -TimeoutMilliseconds 500
    Assert-True ($presentWait.Found -and $presentWait.Length -gt 0) 'wait_result_file did not recognize existing non-empty evidence.'
    $missingWait = Wait-GuestResultFile -Path (Join-Path $testRoot 'never-created.json') -TimeoutMilliseconds 300
    Assert-True (-not $missingWait.Found -and $missingWait.ElapsedMilliseconds -ge 250 -and $missingWait.ElapsedMilliseconds -lt 1500) 'wait_result_file did not honor its bounded timeout.'
    $scenarios.Add('wait-result-file-bounded')

    $syntheticProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 10; Name = 'wrapper.exe'; ExecutablePath = 'C:\payload\wrapper.exe' },
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'electron.exe'; ExecutablePath = 'C:\payload\electron.exe' },
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = 'node.exe'; ExecutablePath = 'C:\payload\node.exe' },
        [pscustomobject]@{ ProcessId = 103; ParentProcessId = 102; Name = 'helper.exe'; ExecutablePath = 'C:\payload\helper.exe' },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 10; Name = 'unrelated.exe'; ExecutablePath = 'C:\Windows\unrelated.exe' }
    )
    $processTree = @(Get-GuestProcessTree -RootProcessId 100 -ProcessSnapshot $syntheticProcesses)
    Assert-True ($processTree.Count -eq 4) 'Process-tree discovery omitted descendants or included an unrelated process.'
    Assert-True (($processTree.ProcessId -join ',') -eq '103,102,101,100') 'Process-tree discovery was not deepest-child-first.'
    Assert-True (($processTree.Depth -join ',') -eq '3,2,1,0') 'Process-tree depth calculation was incorrect.'
    $orphanTree = @(Get-GuestProcessTree -RootProcessId 100 -ProcessSnapshot @($syntheticProcesses | Where-Object ProcessId -ne 100))
    Assert-True (($orphanTree.ProcessId -join ',') -eq '103,102,101') 'Detached descendants were not discoverable after their root process exited.'
    $scenarios.Add('process-tree-discovers-detached-descendants')

    $invokeGuestJobAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GuestJob' }, $true)) | Select-Object -First 1
    $invokeGuestJobText = $invokeGuestJobAst.Extent.Text
    $cleanupIndex = $invokeGuestJobText.LastIndexOf('$processCleanup = Stop-GuestProcessTree', [StringComparison]::Ordinal)
    $leaseRemovalIndex = $invokeGuestJobText.LastIndexOf('Remove-Item -LiteralPath $leasePath', [StringComparison]::Ordinal)
    $resultWriteIndex = $invokeGuestJobText.LastIndexOf('Write-JsonAtomic -Path $resultFile', [StringComparison]::Ordinal)
    Assert-True ($cleanupIndex -ge 0 -and $cleanupIndex -lt $leaseRemovalIndex -and $leaseRemovalIndex -lt $resultWriteIndex) 'The guest publishes completion before verified process-tree cleanup.'
    Assert-True ($invokeGuestJobText -like '*ProcessCleanup = $processCleanup*') 'The guest result omits process-tree cleanup evidence.'
    $scenarios.Add('process-tree-cleanup-precedes-terminal-result')

    function Wait-CaptureDesktopReady {
        param([int] $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ Ready = $true; Error = $null; SessionId = 1; Width = 1920; Height = 1080 }
    }
    $script:captureAttempt = 0
    function Invoke-ScreenCaptureHelper {
        param([string] $Path, [string] $ErrorPath, [int] $TimeoutMilliseconds)
        $script:captureAttempt++
        if ($script:captureAttempt -lt 3) {
            return [pscustomobject][ordered]@{ Success = $false; Error = 'synthetic invalid handle'; TimedOut = $false }
        }
        [pscustomobject][ordered]@{ Success = $true; Error = $null; TimedOut = $false }
    }
    $capture = Capture-Screen -Path (Join-Path $testRoot 'synthetic.png') -TimeoutMilliseconds 5000 -Attempts 5
    Assert-True ($capture.Attempts -eq 3 -and $capture.AttemptLog.Count -eq 3) 'Capture retry did not recover on the third attempt.'
    Assert-True ($capture.ElapsedMilliseconds -ge 1400 -and $capture.ElapsedMilliseconds -lt 5000) 'Capture retry did not use bounded exponential backoff.'
    $scenarios.Add('capture-exponential-retry-recovers')

    function Invoke-ScreenCaptureHelper {
        param([string] $Path, [string] $ErrorPath, [int] $TimeoutMilliseconds)
        [pscustomobject][ordered]@{ Success = $false; Error = 'synthetic invalid handle'; TimedOut = $false }
    }
    $captureFailure = $null
    try { Capture-Screen -Path (Join-Path $testRoot 'failure.png') -TimeoutMilliseconds 3000 -Attempts 2 | Out-Null }
    catch { $captureFailure = $_.Exception.Message }
    Assert-True ($captureFailure -like '[[]CAPTURE_INFRASTRUCTURE[]]*' -and $captureFailure -like '*after 2 attempts*') 'Persistent capture failure was not classified for worker replay.'
    $scenarios.Add('capture-failure-classified')
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    Success = $true
    ScenarioCount = $scenarios.Count
    Scenarios = $scenarios.ToArray()
} | ConvertTo-Json -Depth 8
