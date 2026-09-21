# Troubleshooting

## Read state before retrying

- Source rebuild: `Live\Setup\setup-state.json`, `setup-result.json`, and `setup.log`
- Official media: `Live\Setup\iso-status.json`
- Windows install: `Live\Setup\provision-status.json`
- Pool and broker management: `Live\Broker\State\Management`
- Per-request progress: the request's `request-state.json`

If setup is in `RebootPending`, confirm that the `Codex Hyper-V Source Rebuild Resume` task exists and restart once. If it is actively installing Windows or building the pool, do not launch a second installer.

## Official link resolution

Confirm signed Microsoft Edge is installed and can reach `https://www.microsoft.com/en-us/software-download/windows11`. Temporary ISO links expire; rerun the resolver rather than saving a link. The local ISO is accepted only after media validation.

## Existing VM without a clean checkpoint

The installer stops instead of guessing ownership. Inspect the named VM. Use `-ForceRebuild` only after confirming that `Codex-Harness-Baseline` and `Codex-Harness-01` through `-04` are disposable harness VMs.

## Application request stalls

Use the runtime queue script and request state. `Assigned` means the broker claimed work, not that the application is running. Look for payload staging, VM preparation, guest-agent readiness, and `ApplicationRunning`. Cancellation and execution timeouts remain authoritative.

## Repeated recycling or an apparently healthy stalled pool

Use `Get-HyperVExecutableTestQueue.ps1` and check `PlatformHealthy`, `PlatformStatus`, and `HealthReasons`. `BrokerHealthy` means only that the broker process and heartbeat are alive. `QueuedDemandStalled` detects queued work with no active or ready worker after 120 seconds. Three consecutive lifecycle failures, a lifecycle running beyond 300 seconds, and an authentication/account-policy failure also report degradation. An idle off pool is healthy; intentional maintenance suppresses demand and repeated-recovery alarms, but not orphaned work or an overlong lifecycle.

`LastFailureReason` survives the next recycle attempt. Readiness probes retry a stuck PowerShell Direct connection after 15 seconds and preserve the final cause. Transient credential rejections during boot are retried within the readiness deadline; a verified unhealthy account policy stops immediately. `GuestAuthenticationFailed` requires checking the stored credential identity and the disposable guest account; repeated OS recreation cannot repair an expired password. Such failures back off to the configured maximum instead of rapidly rebooting identical disks. An already-expired legacy account can block PowerShell Direct and refuse an interactive password change. Recover the managed baseline's account policy using a backed-up, exact-target recovery plan that preserves its protected credential. Then let the canonical release verify the non-expiring policy, replace the workers, and refresh recovery. Worker state older than the rebuilt pool is discarded; failure records from the current pool remain authoritative. Never change host-wide password policy or patch individual workers as a durable repair.

Regression guardrails cover queued demand behind failed recyclers, duplicate-start prevention, normal cold/idle/maintenance states, immediate account-failure detection, bounded readiness probes, diagnostic retention, and account policy in both provisioning and baseline promotion. Release acceptance must still pass in real isolated guests; synthetic tests alone do not establish pool health.

For external monitoring, poll the queue JSON once a minute and alert on `PlatformStatus = Degraded`, including `HealthReasons`; treat planned `Maintenance` separately. Keep the eight isolated release checks as the deployment gate.

## Physical screen

Normal native tests never use the host keyboard, mouse, or desktop. VM evidence is captured from the interactive guest session, so locking the physical host is compatible as long as the host does not sleep.
