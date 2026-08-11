function Resolve-HyperVBrokerRoot {
    [CmdletBinding()]
    param([string] $BrokerRoot)

    if (-not [string]::IsNullOrWhiteSpace($BrokerRoot)) {
        return [IO.Path]::GetFullPath($BrokerRoot)
    }
    $pointerPath = 'C:\ProgramData\CodexHyperVBroker\location.json'
    if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
        try {
            $pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$pointer.BrokerRoot)) {
                return [IO.Path]::GetFullPath([string]$pointer.BrokerRoot)
            }
        }
        catch {
            throw "The Hyper-V broker location pointer is invalid: $pointerPath"
        }
    }
    throw "The Hyper-V broker location pointer is missing: $pointerPath. Run the repository installer or pass -BrokerRoot explicitly."
}
