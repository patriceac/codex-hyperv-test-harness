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

## Physical screen

Normal native tests never use the host keyboard, mouse, or desktop. VM evidence is captured from the interactive guest session, so locking the physical host is compatible as long as the host does not sleep.
