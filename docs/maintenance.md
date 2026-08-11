# Maintenance

## Refresh the fast local recovery image

Run `REFRESH-LOCAL-RECOVERY.cmd` after an intentional baseline, sizing, guest-agent, broker, or runtime-skill change. The command drains the queue, enters maintenance, stops workers, exports the baseline, snapshots current software and the sanitized Codex policy, computes checksums, verifies staging, rotates `Current` to `Previous`, and resumes the broker.

The recovery directory keeps two generations by default. Stale staging directories are garbage-collected. Payload cache garbage collection remains broker-managed and independent of recovery generation rotation.

## Verify

`VERIFY.cmd` performs the privileged pool audit, checks the broker pointer/task and installed skill, runs an isolated canary unless skipped, and structurally verifies the current recovery bundle. Pass `-DeepRecoveryVerification` to hash every recovery file; the default is intentionally faster for a multi-gigabyte baseline export.

## Update source

Pull or download a new repository revision, run the public-safety check, inspect `setup\Install.ps1 -PlanOnly`, then rerun the installer without `-ForceRebuild`. A matching baseline is reused while source, canaries, pool definition, broker, skill, audit, and local recovery are refreshed.
