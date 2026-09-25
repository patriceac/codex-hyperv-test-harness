function Get-RequestGroupDefinition {
    param(
        [Parameter(Mandatory = $true)] $Request,
        [ValidateRange(1, 64)] [int] $MaxWorkers = 64
    )

    $groupProperty = $Request.PSObject.Properties['Group']
    if (-not $groupProperty -and $Request.Operation -ine 'RunGuestJobGroupV1') { return $null }
    if ($Request.Operation -cne 'RunGuestJobGroupV1' -or -not $groupProperty -or $groupProperty.Name -cne 'Group') {
        throw 'Grouped requests require Operation=RunGuestJobGroupV1 and a Group object.'
    }
    $group = $groupProperty.Value
    if ($null -eq $group -or $group -isnot [pscustomobject] -or
        @($group.PSObject.Properties.Name).Count -ne 3 -or
        @($group.PSObject.Properties.Name | Where-Object { $_ -cnotin @('Id','Size','Operation') }).Count -gt 0) {
        throw 'Group must contain exactly Id, Size, and Operation.'
    }
    if ($group.Id -isnot [string] -or $group.Id -cnotmatch '^[a-f0-9]{32}$') {
        throw 'Group.Id must be a unique lowercase GUID without separators.'
    }
    if ($group.Size -isnot [int] -and $group.Size -isnot [long]) { throw 'Group.Size must be an integer.' }
    if ($group.Size -lt 1 -or $group.Size -gt $MaxWorkers) {
        throw "Group.Size must be between 1 and the configured pool capacity ($MaxWorkers)."
    }
    if ($group.Operation -cnotin @('RunGuestJob','RunGuestJobNetworkV1','RunGuestJobSetupV1',
        'RunGuestJobSystemPromptsV1','RunGuestJobSetupSystemPromptsV1','RunGuestJobPowerTestV1','RunGuestInstallerV2')) {
        throw 'Group.Operation must be a supported single-worker operation.'
    }
    $group
}
