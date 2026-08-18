[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [switch] $AsJson
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'README.md') -PathType Leaf)) { throw "Repository root is invalid: $RepositoryRoot" }

$violations = New-Object Collections.Generic.List[object]
function Add-Violation([string] $Path, [string] $Rule, [string] $Message) {
    $violations.Add([pscustomobject][ordered]@{ Path = $Path; Rule = $Rule; Message = $Message })
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
$files = @()
if ($git -and (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.git') -PathType Container)) {
    $relativeFiles = @(& $git.Source -C $RepositoryRoot ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed during public-payload inspection.' }
    $files = @($relativeFiles | Where-Object { $_ } | ForEach-Object { Get-Item -LiteralPath (Join-Path $RepositoryRoot $_) -ErrorAction Stop } | Where-Object { -not $_.PSIsContainer })
}
else {
    $files = @(Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File -Force | Where-Object {
        $_.FullName -notlike (Join-Path $RepositoryRoot '.git\*') -and
        $_.FullName -notlike (Join-Path $RepositoryRoot 'artifacts\*')
    })
}

$forbiddenExtensions = @('.iso','.vhd','.vhdx','.avhdx','.vmcx','.vmrs','.vmgs','.exe','.dll','.msi','.pfx','.p12','.key')
$forbiddenNames = @('guest-credential.json','pool-definition.json','pool-provision-status.json','pool-broker-install-status.json')
$forbiddenNamePatterns = @('*request-network-policy*.json','*request-network-plan*.json','*request-network-deployment*.json','*trusted-lan-endpoint-inventory*.json')
$textExtensions = @('.ps1','.psm1','.psd1','.md','.txt','.json','.yaml','.yml','.xml','.cmd','.cs','.gitignore','.gitattributes')
$secretPatterns = [ordered]@{
    'LiteralUserProfilePath' = 'C:\\Users\\(?!Public(?:\\|\b)|Default(?: User)?(?:\\|\b)|All Users(?:\\|\b)|<[^>]+>)[^\\\s`"'']+'
    'GitHubToken' = '(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'
    'OpenAiKey' = '(?:sk-[A-Za-z0-9_-]{24,})'
    'PrivateKey' = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    'AwsAccessKey' = '\bAKIA[0-9A-Z]{16}\b'
}

foreach ($file in $files) {
    $relative = $file.FullName.Substring($RepositoryRoot.Length).TrimStart('\').Replace('\','/')
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) { Add-Violation $relative 'ForbiddenBinaryOrImage' "Public source must not contain $($file.Extension) files." }
    if ($forbiddenNames -contains $file.Name.ToLowerInvariant()) { Add-Violation $relative 'GeneratedPrivateState' 'Generated broker or credential state must not be published.' }
    if (@($forbiddenNamePatterns | Where-Object { $file.Name -like $_ }).Count -gt 0) { Add-Violation $relative 'PrivateRequestNetworkState' 'Host-specific request-network policies, plans, deployment receipts, and endpoint inventories must not be published.' }
    if ($file.FullName -match '[\\/]private[\\/]') { Add-Violation $relative 'PrivateDirectory' 'Files below a private directory must not be published.' }
    if ($file.Length -gt 10MB) { Add-Violation $relative 'UnexpectedLargeFile' "File is $($file.Length) bytes; public source files must remain under 10 MiB." }
    $isText = $textExtensions -contains $file.Extension.ToLowerInvariant() -or $file.Name -in @('.gitignore','.gitattributes')
    if (-not $isText) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    foreach ($entry in $secretPatterns.GetEnumerator()) {
        if ($content -match $entry.Value) { Add-Violation $relative $entry.Key 'Content matched a public-release secret or personal-data rule.' }
    }
}

$result = [pscustomobject][ordered]@{
    Success = $violations.Count -eq 0
    RepositoryRoot = $RepositoryRoot
    CheckedUtc = [DateTime]::UtcNow.ToString('o')
    FileCount = $files.Count
    Violations = $violations.ToArray()
}
if ($AsJson) { $result | ConvertTo-Json -Depth 10 } else { $result }
if (-not $result.Success) { exit 1 }
