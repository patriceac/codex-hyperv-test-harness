# Payload-cache performance and garbage collection

`ArtifactPath` remains the canonical application payload. The runner records each relative path, file length, and UTC last-write timestamp in a source index. On the next run it enumerates this cheap metadata first. Only new files and files whose length or timestamp changed become hash candidates; unchanged files reuse their prior SHA-256. Deletions are detected from missing relative paths. The resulting content manifest drives incremental additions, replacements, and deletions in the immutable parent VHDX.

This is deliberately a likely-change detector, not a claim that metadata is cryptographic proof. A tool that changes bytes while restoring both the original length and exact timestamp can evade candidate selection. Normal build tools update timestamps. If a producer deliberately preserves both values, touch the affected files or remove that payload's source index while the broker is idle so the next run performs a cold hash.

## Reproduce the timing proof

From the repository root:

```powershell
.\setup\Measure-PayloadFingerprint.ps1
```

The default benchmark generates 1,000 files totaling 62.5 MiB in a validated temporary directory, then reports three measured passes:

- `Cold`: every file is hashed.
- `WarmUnchanged`: all 1,000 hashes are reused and `FilesHashed` must be zero.
- `OneChanged`: exactly one file is hashed and 999 hashes are reused.

Each pass reports enumeration, candidate-hash, and end-to-end milliseconds plus candidate counts and bytes. The deterministic source suite runs the same contract at smaller scale in CI. Real harness results expose `PayloadFingerprintEnumerationMilliseconds`, `PayloadCandidateHashMilliseconds`, `PayloadDetectionTotalMilliseconds`, `PayloadFilesHashed`, `PayloadHashesReused`, `PayloadCacheOperationMilliseconds`, and `PayloadVhdxSyncMilliseconds`.

One release-validation run on 2026-08-11 used Windows 11, NTFS, and an AMD Ryzen 9 5950X. These figures are evidence of the algorithm, not a performance guarantee:

| Pass | Total ms | Enumeration ms | Hash ms | Files hashed | Hashes reused |
|---|---:|---:|---:|---:|---:|
| Cold | 1170.014 | 116.168 | 921.169 | 1000 | 0 |
| Warm, unchanged | 145.605 | 96.928 | 0 | 0 | 1000 |
| One file changed | 137.382 | 95.640 | 1.203 | 1 | 999 |

The unchanged pass therefore read metadata for all entries but hashed zero payload bytes. Run the benchmark on the rebuilt machine for current hardware-specific values; CI also emits its own compact-run metrics.

## Immutable reuse and cleanup

Once synchronized, a cache generation is read-only. Concurrent workers may attach separate disposable differencing children to the same immutable parent. Leases prevent garbage collection or chain compaction under an active child; run cleanup detaches and deletes only that run's child.

The SYSTEM broker performs garbage collection only while the queue is empty, no lease is active, and all pool workers are off. It removes abandoned temporary mounts and children, evicts inactive entries after 30 days, enforces a 64 GiB high-water and 56 GiB low-water LRU target, and flattens deep immutable chains. Inspect `Live\Broker\State\payload-cache-gc.json` and `Inspect-PayloadCache.ps1`; do not delete VHDX files behind the broker.
