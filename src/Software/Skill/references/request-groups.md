# Tests requiring several VMs

Use `-GroupId <unique-lowercase-GUID-without-separators> -GroupSize <count>` on every runner call belonging to one simultaneous test. Create the ID with `[Guid]::NewGuid().ToString('N')`. Start every member concurrently; waiting for the first runner to finish before submitting the next would leave the group incomplete.

The first member establishes the group's FIFO position. Until all declared members are queued and that many clean workers are ready, the group receives no workers and later requests wait behind it. A valid group queues when capacity is occupied. A size exceeding the configured pool capacity is rejected because it can never fit. Each request retains its queue deadline; its execution deadline begins at assignment.

For example, launch a two-VM test from Windows PowerShell:

```powershell
$runner = Join-Path $env:USERPROFILE '.agents\skills\hyperv-test-executables\scripts\Invoke-HyperVExecutableTest.ps1'
$group = [Guid]::NewGuid().ToString('N')
$jobs = foreach ($role in @('server','client')) {
    Start-Job -ScriptBlock {
        param($runner, $group, $role)
        & $runner -ArtifactPath 'D:\build\NetworkTest.exe' -Arguments "--role $role" `
            -NetworkProfile IsolatedTestNet -NetworkCohort $group `
            -GroupId $group -GroupSize 2
    } -ArgumentList $runner, $group, $role
}
$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
```

Networking remains explicit and governed by the selected profile. Group IDs coordinate scheduling; network cohorts coordinate connectivity. Group admission guarantees the required VM capacity, while applications still need their normal readiness handshake.

Cancel any member with `Cancel-HyperVExecutableTest.ps1`; the broker signals every unfinished peer. A queue timeout, application assertion failure, infrastructure failure, or interrupted admission also cancels peers. Grouped requests never replay individually after a crash or transient capture failure. To retry, submit every member under a new group ID. Already completed results remain available.

Admission writes the full member-to-worker assignment to the protected `State\RequestGroups` journal before launching a member. Broker restart during that step cancels the group; an already running group can continue. Each completed member recycles normally, so a later group may start once its entire capacity is available. Keep the group's required worker count fixed for its lifetime; submit independent tests without group options.

The `RunGuestJobGroupV1` envelope makes an older broker reject grouped requests instead of silently treating them as unrelated jobs.
