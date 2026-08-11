[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DestinationDirectory,

    [string] $Language = 'Auto',

    [switch] $ResolveOnly,

    [switch] $ForceDownload,

    [string] $StatusPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$downloadPage = 'https://www.microsoft.com/en-us/software-download/windows11'
$startedUtc = [DateTime]::UtcNow

function Write-JsonAtomic {
    param([string] $Path, $Value)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Write-IsoStatus {
    param([string] $Phase, [string] $Message, $Details = $null, [Nullable[bool]] $Success = $null)
    Write-JsonAtomic -Path $StatusPath -Value ([ordered]@{
        Success = $Success
        Phase = $Phase
        Message = $Message
        StartedUtc = $startedUtc.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Details = $Details
    })
}

function Get-RequestedMicrosoftLanguage {
    param([string] $Requested)
    if (-not [string]::Equals($Requested, 'Auto', [StringComparison]::OrdinalIgnoreCase)) {
        return $Requested
    }

    $cultureName = [Globalization.CultureInfo]::CurrentUICulture.Name
    $map = @{
        'ar' = 'Arabic'; 'bg' = 'Bulgarian'; 'cs' = 'Czech'; 'da' = 'Danish'
        'de' = 'German'; 'el' = 'Greek'; 'es' = 'Spanish'; 'et' = 'Estonian'
        'fi' = 'Finnish'; 'fr' = 'French'; 'he' = 'Hebrew'; 'hr' = 'Croatian'
        'hu' = 'Hungarian'; 'it' = 'Italian'; 'ja' = 'Japanese'; 'ko' = 'Korean'
        'lt' = 'Lithuanian'; 'lv' = 'Latvian'; 'nb' = 'Norwegian'; 'nl' = 'Dutch'
        'pl' = 'Polish'; 'ro' = 'Romanian'; 'ru' = 'Russian'; 'sk' = 'Slovak'
        'sl' = 'Slovenian'; 'sv' = 'Swedish'; 'th' = 'Thai'; 'tr' = 'Turkish'
        'uk' = 'Ukrainian'
    }
    if ($cultureName -eq 'pt-BR') { return 'Brazilian Portuguese' }
    if ($cultureName -like 'pt-*') { return 'Portuguese' }
    if ($cultureName -eq 'fr-CA') { return 'French Canadian' }
    if ($cultureName -eq 'es-MX') { return 'Spanish (Mexico)' }
    if ($cultureName -eq 'zh-CN' -or $cultureName -eq 'zh-SG') { return 'Chinese (Simplified)' }
    if ($cultureName -like 'zh-*') { return 'Chinese (Traditional)' }
    if ($cultureName -eq 'en-GB' -or $cultureName -eq 'en-AU' -or $cultureName -eq 'en-NZ') { return 'English International' }
    $neutral = $cultureName.Split('-')[0].ToLowerInvariant()
    if ($map.ContainsKey($neutral)) { return [string]$map[$neutral] }
    'English'
}

function Get-EdgeExecutable {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $candidate
        if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "Microsoft Edge failed signature validation: $candidate"
        }
        return $candidate
    }
    throw 'Microsoft Edge is required to resolve the official Windows 11 ISO link, but msedge.exe was not found.'
}

function Get-FreeTcpPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function New-ByteSegment {
    param([byte[]] $Bytes)
    New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$Bytes)
}

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory = $true)] [Net.WebSockets.ClientWebSocket] $Socket,
        [Parameter(Mandatory = $true)] [int] $Id,
        [Parameter(Mandatory = $true)] [string] $Method,
        [hashtable] $Parameters = @{},
        [ValidateRange(1, 120)] [int] $TimeoutSeconds = 30
    )

    $payload = [ordered]@{ id = $Id; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $cancellation = New-Object Threading.CancellationTokenSource
    $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        [void]$Socket.SendAsync((New-ByteSegment -Bytes $bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancellation.Token).GetAwaiter().GetResult()
        while ($true) {
            $memory = New-Object IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $received = $Socket.ReceiveAsync((New-ByteSegment -Bytes $buffer), $cancellation.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'The Edge DevTools connection closed before the command completed.'
                    }
                    $memory.Write($buffer, 0, $received.Count)
                } while (-not $received.EndOfMessage)
                $message = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
                if ([int]$message.id -eq $Id) {
                    if ($message.error) { throw "Edge DevTools command failed: $($message.error.message)" }
                    return $message.result
                }
            }
            finally {
                $memory.Dispose()
            }
        }
    }
    finally {
        $cancellation.Dispose()
    }
}

function Invoke-CdpExpression {
    param(
        [Net.WebSockets.ClientWebSocket] $Socket,
        [ref] $NextId,
        [string] $Expression,
        [int] $TimeoutSeconds = 30
    )
    $id = [int]$NextId.Value
    $NextId.Value = $id + 1
    $result = Invoke-CdpCommand -Socket $Socket -Id $id -Method 'Runtime.evaluate' -Parameters @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    } -TimeoutSeconds $TimeoutSeconds
    if ($result.exceptionDetails) {
        throw "JavaScript evaluation failed: $($result.exceptionDetails.text)"
    }
    $result.result.value
}

function Wait-CdpCondition {
    param(
        [Net.WebSockets.ClientWebSocket] $Socket,
        [ref] $NextId,
        [string] $Expression,
        [ValidateRange(1, 120)] [int] $TimeoutSeconds = 30,
        [string] $Description = 'page condition'
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = Invoke-CdpExpression -Socket $Socket -NextId $NextId -Expression "Boolean($Expression)" -TimeoutSeconds 10
        if ([bool]$value) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Resolve-OfficialIsoLink {
    param([string] $MicrosoftLanguage)

    $edge = Get-EdgeExecutable
    $port = Get-FreeTcpPort
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $profile = Join-Path $temporaryParent ('codex-win11-iso-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profile | Out-Null
    $edgeProcess = $null
    $socket = $null
    try {
        $edgeProcess = Start-Process -FilePath $edge -ArgumentList @(
            '--headless=new',
            ('--remote-debugging-port=' + $port),
            ('--user-data-dir=' + $profile),
            '--disable-first-run-ui',
            '--no-first-run',
            '--disable-default-apps',
            $downloadPage
        ) -WindowStyle Hidden -PassThru

        $targets = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            try {
                $targets = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/json') -TimeoutSec 2
            }
            catch { }
            if ($targets) { break }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        $target = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://www.microsoft.com/*' } | Select-Object -First 1
        if (-not $target) { throw 'Microsoft Edge did not expose the Windows 11 download page to its local DevTools endpoint.' }

        $socket = New-Object Net.WebSockets.ClientWebSocket
        [void]$socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        $nextId = 1
        [void](Invoke-CdpCommand -Socket $socket -Id $nextId -Method 'Runtime.enable')
        $nextId++
        Wait-CdpCondition -Socket $socket -NextId ([ref]$nextId) -Expression 'document.readyState === "complete" && document.querySelector("#product-edition")' -TimeoutSeconds 45 -Description 'the official edition selector'

        $editionScript = @'
(function () {
  const select = document.querySelector('#product-edition');
  const option = Array.from(select.options).find(x => x.value && x.value !== 'null');
  if (!option) throw new Error('The Windows 11 multi-edition option was not found.');
  select.value = option.value;
  select.dispatchEvent(new Event('change', { bubbles: true }));
  document.querySelector('#submit-product-edition').click();
  return option.textContent.trim();
})()
'@
        $editionName = Invoke-CdpExpression -Socket $socket -NextId ([ref]$nextId) -Expression $editionScript
        Wait-CdpCondition -Socket $socket -NextId ([ref]$nextId) -Expression 'document.querySelectorAll("#product-languages option").length > 1' -TimeoutSeconds 45 -Description 'the official language selector'

        $optionsJson = Invoke-CdpExpression -Socket $socket -NextId ([ref]$nextId) -Expression 'JSON.stringify(Array.from(document.querySelectorAll("#product-languages option")).map(x => ({ value:x.value, text:x.textContent.trim() })))'
        $options = $optionsJson | ConvertFrom-Json
        $languageOption = $options | Where-Object {
            $_.value -and $_.value -ne 'null' -and (
                [string]::Equals([string]$_.text, $MicrosoftLanguage, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$_.value -match ('"language"\s*:\s*"' + [regex]::Escape($MicrosoftLanguage) + '"')
            )
        } | Select-Object -First 1
        if (-not $languageOption) {
            $available = @($options | Where-Object { $_.value -and $_.value -ne 'null' } | ForEach-Object { [string]$_.text }) -join ', '
            throw "Microsoft does not currently list '$MicrosoftLanguage' for this ISO. Available languages: $available"
        }
        $quotedValue = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$languageOption.value)
        $languageScript = "(function(){const s=document.querySelector('#product-languages');s.value='$quotedValue';s.dispatchEvent(new Event('change',{bubbles:true}));document.querySelector('#submit-sku').click();return s.options[s.selectedIndex].textContent.trim();})()"
        $selectedLanguage = Invoke-CdpExpression -Socket $socket -NextId ([ref]$nextId) -Expression $languageScript
        Wait-CdpCondition -Socket $socket -NextId ([ref]$nextId) -Expression 'Array.from(document.querySelectorAll("a[href]"), x => x.href).some(x => /\.iso(?:\?|$)/i.test(x))' -TimeoutSeconds 60 -Description 'the official ISO download link'

        $linksJson = Invoke-CdpExpression -Socket $socket -NextId ([ref]$nextId) -Expression 'JSON.stringify(Array.from(document.querySelectorAll("a[href]"), x => ({href:x.href,text:x.textContent.trim()})).filter(x => /\.iso(?:\?|$)/i.test(x.href)))'
        $links = @($linksJson | ConvertFrom-Json)
        $link = $links | Where-Object { $_.href -match 'x64|Win11|Windows11' } | Select-Object -First 1
        if (-not $link) { $link = $links | Select-Object -First 1 }
        if (-not $link) { throw 'Microsoft returned no ISO link.' }

        [pscustomobject][ordered]@{
            DownloadPage = $downloadPage
            EditionOption = [string]$editionName
            Language = $MicrosoftLanguage
            DisplayLanguage = [string]$selectedLanguage
            Url = [string]$link.href
            LinkText = [string]$link.text
            ResolvedUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    finally {
        if ($socket) {
            try {
                if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
                    [void]$socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None).GetAwaiter().GetResult()
                }
            }
            catch { }
            $socket.Dispose()
        }
        if ($edgeProcess -and -not $edgeProcess.HasExited) {
            try { $edgeProcess.Kill() } catch { }
        }
        $profilePath = [IO.Path]::GetFullPath($profile)
        $profileLeaf = [IO.Path]::GetFileName($profilePath)
        if (($profilePath + '\').StartsWith($temporaryParent + '\', [StringComparison]::OrdinalIgnoreCase) -and $profileLeaf -like 'codex-win11-iso-*') {
            Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-MicrosoftDownloadUri {
    param([string] $Url)
    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https') { throw "The resolved ISO URL is not HTTPS: $Url" }
    $downloadHost = $uri.DnsSafeHost.ToLowerInvariant()
    $allowed = $downloadHost -eq 'microsoft.com' -or $downloadHost.EndsWith('.microsoft.com') -or
        $downloadHost -eq 'windowsupdate.com' -or $downloadHost.EndsWith('.windowsupdate.com') -or
        $downloadHost -eq 'delivery.mp.microsoft.com' -or $downloadHost.EndsWith('.delivery.mp.microsoft.com')
    if (-not $allowed) { throw "The resolved ISO URL is not hosted on an allowed Microsoft domain: $downloadHost" }
    $uri
}

function Test-Windows11ProIso {
    param([string] $IsoPath)
    $mounted = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    try {
        $volume = $mounted | Get-Volume | Select-Object -First 1
        if (-not $volume -or -not $volume.DriveLetter) { throw 'The downloaded ISO mounted without a readable volume.' }
        $root = $volume.DriveLetter + ':\'
        $setup = Join-Path $root 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'The downloaded ISO does not contain setup.exe.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $setup
        if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw 'The Windows setup executable in the downloaded ISO is not validly signed by Microsoft.'
        }
        $installImage = Join-Path $root 'sources\install.wim'
        if (-not (Test-Path -LiteralPath $installImage -PathType Leaf)) { $installImage = Join-Path $root 'sources\install.esd' }
        if (-not (Test-Path -LiteralPath $installImage -PathType Leaf)) { throw 'The downloaded ISO contains neither sources\install.wim nor sources\install.esd.' }
        $images = @(Get-WindowsImage -ImagePath $installImage -ErrorAction Stop)
        $professional = @($images | Where-Object { [string]$_.EditionId -eq 'Professional' })
        if ($professional.Count -ne 1) { throw "Expected exactly one Professional image; found $($professional.Count)." }
        [pscustomobject][ordered]@{
            EditionId = [string]$professional[0].EditionId
            ImageIndex = [int]$professional[0].ImageIndex
            ImageName = [string]$professional[0].ImageName
            SetupSigner = [string]$signature.SignerCertificate.Subject
        }
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

try {
    $DestinationDirectory = [IO.Path]::GetFullPath($DestinationDirectory)
    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $selectedLanguage = Get-RequestedMicrosoftLanguage -Requested $Language
    $safeLanguage = ($selectedLanguage -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $isoPath = Join-Path $DestinationDirectory ("Windows11-x64-$safeLanguage.iso")
    $metadataPath = $isoPath + '.json'

    if (-not $ResolveOnly -and -not $ForceDownload -and (Test-Path -LiteralPath $isoPath -PathType Leaf) -and (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        Write-IsoStatus -Phase 'ValidatingCachedMedia' -Message 'Validating the cached official Windows 11 ISO.'
        $validation = Test-Windows11ProIso -IsoPath $isoPath
        $hash = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
        $cached = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if ([string]$cached.Sha256 -ne $hash) { throw 'The cached Windows 11 ISO no longer matches its recorded SHA-256.' }
        $result = [ordered]@{
            Success = $true; Reused = $true; IsoPath = $isoPath; Sha256 = $hash
            Length = [long](Get-Item -LiteralPath $isoPath).Length; Language = $selectedLanguage
            Edition = $validation; Source = $cached.Source
        }
        Write-IsoStatus -Phase 'Ready' -Message 'Reused the validated cached official Windows 11 ISO.' -Details $result -Success $true
        [pscustomobject]$result
        return
    }

    Write-IsoStatus -Phase 'ResolvingOfficialMedia' -Message 'Resolving a fresh ISO link through the official Microsoft Windows 11 download page.' -Details @{ Language = $selectedLanguage }
    $source = Resolve-OfficialIsoLink -MicrosoftLanguage $selectedLanguage
    [void](Assert-MicrosoftDownloadUri -Url $source.Url)
    if ($ResolveOnly) {
        $result = [ordered]@{ Success = $true; Reused = $false; Language = $selectedLanguage; Source = $source }
        Write-IsoStatus -Phase 'Resolved' -Message 'Resolved an official Microsoft Windows 11 ISO link.' -Details $result -Success $true
        [pscustomobject]$result
        return
    }

    Write-IsoStatus -Phase 'DownloadingMedia' -Message 'Downloading the official Windows 11 ISO from Microsoft.' -Details @{ Language = $selectedLanguage; Destination = $isoPath }
    $partialPath = $isoPath + '.partial.iso'
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    Start-BitsTransfer -Source $source.Url -Destination $partialPath -DisplayName 'Codex Hyper-V Windows 11 ISO' -Description 'Official Microsoft Windows 11 installation media'
    $length = [long](Get-Item -LiteralPath $partialPath).Length
    if ($length -lt 4GB) { throw "The downloaded ISO is unexpectedly small: $length bytes." }

    Write-IsoStatus -Phase 'ValidatingMedia' -Message 'Validating Microsoft signature and locating Windows 11 Pro in the ISO.' -Details @{ Length = $length }
    $validation = Test-Windows11ProIso -IsoPath $partialPath
    $hash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash
    Move-Item -LiteralPath $partialPath -Destination $isoPath -Force
    $metadata = [ordered]@{
        FormatVersion = 1; IsoPath = $isoPath; Length = $length; Sha256 = $hash
        Language = $selectedLanguage; Edition = $validation; Source = $source
        ValidatedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $metadataPath -Value $metadata
    $result = [ordered]@{
        Success = $true; Reused = $false; IsoPath = $isoPath; Length = $length
        Sha256 = $hash; Language = $selectedLanguage; Edition = $validation; Source = $source
    }
    Write-IsoStatus -Phase 'Ready' -Message 'The official Windows 11 ISO is downloaded and validated for Windows 11 Pro.' -Details $result -Success $true
    [pscustomobject]$result
}
catch {
    Write-IsoStatus -Phase 'Failed' -Message $_.Exception.Message -Details @{ ScriptStackTrace = $_.ScriptStackTrace } -Success $false
    throw
}
