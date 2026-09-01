function Test-CodexByteArrayEqual {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [byte[]] $Left,
        [AllowEmptyCollection()] [byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    $true
}

function Read-CodexStrictUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [switch] $AllowMissing
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) {
        if ([IO.Directory]::Exists($fullPath)) { throw "Expected a text file but found a directory: $fullPath" }
        if (-not $AllowMissing) { throw "Required UTF-8 text file is missing: $fullPath" }
        return [pscustomobject][ordered]@{
            Path = $fullPath
            Exists = $false
            HasUtf8Bom = $false
            Text = ''
            Bytes = [byte[]]@()
        }
    }

    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    $offset = 0
    $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasUtf8Bom) {
        $offset = 3
    }
    elseif (($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) -or
            ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF)) {
        throw "Text file uses a non-UTF-8 byte-order mark and will not be rewritten: $fullPath"
    }

    [byte[]]$payload = New-Object byte[] ($bytes.Length - $offset)
    if ($payload.Length -gt 0) { [Array]::Copy($bytes, $offset, $payload, 0, $payload.Length) }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($payload)
    }
    catch [Text.DecoderFallbackException] {
        throw [IO.InvalidDataException]::new("Text file is not valid UTF-8 and will not be rewritten: $fullPath", $_.Exception)
    }
    if ($text.IndexOf([char]0) -ge 0) {
        throw "Text file contains NUL characters and has an ambiguous text encoding; it will not be rewritten: $fullPath"
    }

    [pscustomobject][ordered]@{
        Path = $fullPath
        Exists = $true
        HasUtf8Bom = $hasUtf8Bom
        Text = $text
        Bytes = $bytes
    }
}

function ConvertTo-CodexUtf8Bytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
        [switch] $IncludeBom
    )

    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    [byte[]]$payload = $strictUtf8.GetBytes($Text)
    if (-not $IncludeBom) { return ,$payload }

    [byte[]]$withBom = New-Object byte[] ($payload.Length + 3)
    $withBom[0] = 0xEF
    $withBom[1] = 0xBB
    $withBom[2] = 0xBF
    if ($payload.Length -gt 0) { [Array]::Copy($payload, 0, $withBom, 3, $payload.Length) }
    ,$withBom
}

function Assert-CodexAtomicTargetUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [bool] $ExpectedExists,
        [AllowEmptyCollection()] [byte[]] $ExpectedBytes
    )

    if ($ExpectedExists) {
        if (-not [IO.File]::Exists($Path)) { throw "Managed policy target changed before atomic replacement: $Path" }
        [byte[]]$currentBytes = [IO.File]::ReadAllBytes($Path)
        if (-not (Test-CodexByteArrayEqual -Left $currentBytes -Right $ExpectedBytes)) {
            throw "Managed policy target changed before atomic replacement: $Path"
        }
    }
    elseif ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        throw "Managed policy target appeared before atomic creation: $Path"
    }
}

function Write-CodexBytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [byte[]] $Bytes,
        [Parameter(Mandatory = $true)] [bool] $ExpectedExists,
        [AllowEmptyCollection()] [byte[]] $ExpectedBytes
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw "Managed policy target must have a parent directory: $fullPath" }
    [void][IO.Directory]::CreateDirectory($parent)

    $leaf = [IO.Path]::GetFileName($fullPath)
    $nonce = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $parent ('.' + $leaf + '.' + $nonce + '.tmp')
    $backup = Join-Path $parent ('.' + $leaf + '.' + $nonce + '.bak')
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        try {
            if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                Assert-CodexAtomicTargetUnchanged -Path $fullPath -ExpectedExists $ExpectedExists -ExpectedBytes $ExpectedBytes
                if ($ExpectedExists) {
                    [IO.File]::Replace($temporary, $fullPath, $backup, $true)
                }
                else {
                    [IO.File]::Move($temporary, $fullPath)
                }
                return
            }
            catch [IO.IOException] {
                if ($attempt -ge 20) { throw }
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge 20) { throw }
            }
            Start-Sleep -Milliseconds ([Math]::Min(250, 5 * $attempt))
        }
    }
    finally {
        try { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } } catch { }
        try { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } } catch { }
    }
}

function Set-CodexManagedPolicyBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PolicyPath,
        [Parameter(Mandatory = $true)] [string] $AgentsPath,
        [string] $StartMarker = '<!-- BEGIN CODEX HYPERV TEST HARNESS -->',
        [string] $EndMarker = '<!-- END CODEX HYPERV TEST HARNESS -->'
    )

    if ([string]::IsNullOrWhiteSpace($StartMarker) -or [string]::IsNullOrWhiteSpace($EndMarker) -or $StartMarker -eq $EndMarker) {
        throw 'Managed policy markers must be distinct, non-empty strings.'
    }

    $policy = Read-CodexStrictUtf8File -Path $PolicyPath
    $block = $policy.Text.Trim()
    $policyStartCount = [regex]::Matches($block, [regex]::Escape($StartMarker)).Count
    $policyEndCount = [regex]::Matches($block, [regex]::Escape($EndMarker)).Count
    if ($policyStartCount -ne 1 -or $policyEndCount -ne 1 -or
        -not $block.StartsWith($StartMarker, [StringComparison]::Ordinal) -or
        -not $block.EndsWith($EndMarker, [StringComparison]::Ordinal)) {
        throw "Managed policy source must contain exactly one complete marker block and no other content: $($policy.Path)"
    }

    $existingFile = Read-CodexStrictUtf8File -Path $AgentsPath -AllowMissing
    $existing = $existingFile.Text
    $lineEndingMatch = [regex]::Match($existing, "\r\n|\n|\r")
    $lineEnding = if ($lineEndingMatch.Success) { $lineEndingMatch.Value } else { "`r`n" }
    $normalizedBlock = [regex]::Replace($block, "\r\n|\n|\r", $lineEnding)

    $startCount = [regex]::Matches($existing, [regex]::Escape($StartMarker)).Count
    $endCount = [regex]::Matches($existing, [regex]::Escape($EndMarker)).Count
    $replaced = $false
    if ($startCount -eq 0 -and $endCount -eq 0) {
        if ($existing.Length -eq 0) {
            $updated = $normalizedBlock + $lineEnding
        }
        else {
            $separator = if ([regex]::IsMatch($existing, "(?:\r\n|\n|\r){2}$")) {
                ''
            }
            elseif ([regex]::IsMatch($existing, "(?:\r\n|\n|\r)$")) {
                $lineEnding
            }
            else {
                $lineEnding + $lineEnding
            }
            $updated = $existing + $separator + $normalizedBlock + $lineEnding
        }
    }
    elseif ($startCount -eq 1 -and $endCount -eq 1) {
        $startIndex = $existing.IndexOf($StartMarker, [StringComparison]::Ordinal)
        $endIndex = $existing.IndexOf($EndMarker, [StringComparison]::Ordinal)
        if ($startIndex -lt 0 -or $endIndex -lt ($startIndex + $StartMarker.Length)) {
            throw "Managed policy marker layout is invalid or ambiguous; the file was not rewritten: $($existingFile.Path)"
        }
        $afterEnd = $endIndex + $EndMarker.Length
        $updated = $existing.Substring(0, $startIndex) + $normalizedBlock + $existing.Substring($afterEnd)
        $replaced = $true
    }
    else {
        throw "Managed policy marker layout is invalid or ambiguous; expected zero or one complete block but found $startCount start marker(s) and $endCount end marker(s): $($existingFile.Path)"
    }

    if ([regex]::Matches($updated, [regex]::Escape($StartMarker)).Count -ne 1 -or
        [regex]::Matches($updated, [regex]::Escape($EndMarker)).Count -ne 1) {
        throw "Managed policy update did not produce exactly one marker pair; the file was not rewritten: $($existingFile.Path)"
    }

    [byte[]]$updatedBytes = ConvertTo-CodexUtf8Bytes -Text $updated -IncludeBom:$existingFile.HasUtf8Bom
    $changed = -not $existingFile.Exists -or -not (Test-CodexByteArrayEqual -Left $existingFile.Bytes -Right $updatedBytes)
    if ($changed) {
        Write-CodexBytesAtomic -Path $existingFile.Path -Bytes $updatedBytes -ExpectedExists $existingFile.Exists -ExpectedBytes $existingFile.Bytes
    }

    [pscustomobject][ordered]@{
        Path = $existingFile.Path
        Changed = $changed
        ReplacedExistingBlock = $replaced
        PreservedUtf8Bom = [bool]$existingFile.HasUtf8Bom
        ByteLength = [long]$updatedBytes.Length
        StartMarkerCount = 1
        EndMarkerCount = 1
    }
}
