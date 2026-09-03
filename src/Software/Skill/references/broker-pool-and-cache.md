# Broker, pool, and cache internals

Read this reference only when diagnosing payload staging, pool lifecycle, replay/recovery behavior, cache performance, or cleanup. Ordinary tests should submit the canonical artifact path and let the broker own these mechanisms.

## Immutable payload transport

The broker maintains immutable VHDX generations for each canonical `ArtifactPath`. It enumerates paths with cheap size/write-time fingerprints, reuses saved SHA-256 hashes for unchanged files, and hashes only additions or likely changes. When a manifest changes, it builds a cached differencing generation over the previous generation, applies additions, modifications, and deletions, verifies changed files, then seals the generation read-only. Unchanged files remain inherited.

Every request receives its own disposable differencing child on top. The VM launches from that child; afterward the broker powers it off, detaches the child, and deletes it. Several pool workers may pin one immutable generation concurrently, but each request has a separate writable child. Generation leases prevent garbage collection or compaction until all children are detached and deleted. PowerShell Direct carries only small control JSON and evidence, not payload trees.

## Pool and state integrity

The FIFO broker assigns work across up to four isolated VMs and keeps a warm-spare invariant subject to the ceiling and maintenance drain. Shared JSON state is published through unique same-directory staging files and retrying replacement so readers and independent worker writers see a complete old or new document. A transient denied read retains the last confirmed lifecycle stage rather than visibly regressing.

Each VM boots from a disposable OS differencing child of sealed `Clean-Windows11-Harness`. The broker refuses pre-existing connected network adapters. It uses guest session 1 for input, preserves evidence under its configured `Results` directory, powers the worker off after collection, and recreates its OS child asynchronously before reuse. The installed-location pointer resolves the broker root after host recovery.

Do not connect networking, delete VHDXs, change the baseline, start workers, or restore checkpoints behind the broker.

## Recovery and replay

For ordinary requests, the broker reconciles interrupted submissions before retrying, reconnects dropped Hyper-V Direct sessions without launching the application twice, and requeues unfinished `Processing` requests only after recycling the affected VM. Readiness probes run in disposable child processes so a stuck PowerShell Direct handshake cannot block cancellation or deadlines.

The interactive guest agent is supervised. If it exits mid-job during an ordinary request, its application lease and processing record are recovered and rerun without overlapping instances. Expected guest power-off is different: once its durable ambiguity marker exists, interruption is terminal and neither broker nor guest relaunches the application. See [expected guest power-off](expected-guest-power-off.md).

Guest completion includes bounded, verified termination of the entire process tree rooted at the launched app, including detached Electron, Node, command-wrapper, and helper descendants. The guest publishes `result.json` only after cleanup and records `ProcessCleanup`. Evidence collection creates a stable guest-side snapshot before transfer. Locked optional diagnostics are retried; if still unavailable, they appear in `EvidenceFilesSkipped`, `EvidenceSkippedFiles`, and `EvidenceWarnings` without hiding an otherwise valid terminal result. Missing `result.json` or `agent-error.json` remains a harness failure.

Faulted workers recover asynchronously without queue pressure. Consecutive lifecycle failures use worker-staggered exponential backoff capped at ten minutes; successful readiness resets it. Recovery respects the lifecycle-concurrency limit and warm-spare invariant. Queue reporting leaves raw warm-spare counts visible during maintenance but marks `WarmSparePolicyApplicable=false`, so maintenance drain alone is not an invariant violation; concurrency and orphaned-processing violations remain active.

Controlled broker and baseline updates drain active requests while preserving FIFO order.

## Cache garbage collection and performance

Payload-cache garbage collection runs automatically only while the pool is fully idle and off. It excludes queued, processing, leased, attached, and parent-referenced generations; evicts inactive entries older than 30 days; applies a 64 GiB high-water and 56 GiB low-water LRU cap; removes abandoned mounts and disposable children; and periodically flattens deep immutable chains. Inspect `State\payload-cache-gc.json` when reclamation matters. Never remove cache VHDXs manually.

For performance claims, report:

- `PayloadFilesHashed`
- `PayloadHashesReused`
- `PayloadFingerprintEnumerationMilliseconds`
- `PayloadCandidateHashMilliseconds`
- `PayloadCacheOperationMilliseconds`
- `PayloadVhdxSyncMilliseconds`

An unchanged repeat run should be a cache hit with zero files hashed.
