# SSD persistence cadence audit

Starting revision: `fafc69c81cd62601beb7a92f73d43939a987756a` (detached HEAD).
This is an implementation audit, not a measurement of write savings.

## Ownership and capture

- `Generator.initWithOptions` captures evaluated recurrent state on the effective
  prefill grid and at the backed-off prompt end. The default effective Qwen grid
  is 8192, including when actual chunks are 2048; the 40k-prefill test in
  `qwen4_generate_test.zig` covers widths 8192, 4096, 2048 and 512.
- The write-through callback runs at chunk boundaries, independently of that
  grid. `writeThroughArmed` requires SSD-first, a writer and at least one disk
  chunk of new prefill (with architecture-specific dispatch).
- `writeThroughHybrid` writes a bounded piece, then `settleCheckpoints` releases
  every held checkpoint except the newest. It drains older checkpoint files,
  but releases even failed/unwritten points because admission relies on the
  memory bound. Released positions are not usable RAM recovery points. A policy
  must force this write or explicitly preserve the existing release bound;
  merely skipping the call would retain extra recurrent state.
- Completion calls `settleThoughtPoint`, moves prefill/thought checkpoints out
  through `takeSsmCheckpoints`, and hands live QSA history to the latest point
  when needed. MTP history is truncated to committed rows before capture.
  This does not create an arbitrary decode-end GDN recovery point.
- `commitImpl` captures `pending_disk` **before** RAM trimming. That record
  shares live KV, checkpoint, ring and speculative buffers and copies token
  identifiers. The RAM entry separately retains a budgeted snapshot and
  checkpoints; with a pending disk record it sheds older checkpoints.
- `finishSlot` commits before publishing completion, releases checkouts and
  native GLM state, then flushes and spills. Publication permits slot teardown:
  the disk flush cannot subsequently borrow the slot. `Slot.deinit` drops the
  generator, KV, grouped SSM membership, recurrent arrays and QSA state.
  `releaseNativeState` itself resets GLM state, not Qwen recurrent state.
- `flushPendingRecord` removes the pending record, attempts all pieces and
  frees it on every exit. Keeping it across turns to wait for a threshold would
  retain buffers outside the resident-entry budget and is inadmissible.

## Landed data and restoration

- `appendCommitWith` is the logical operation boundary; `appendCommitPieces`
  can serialize many pieces. `PersistOutcome.persisted` also represents
  superseded/no-op work and, with a writer, queued work. It is not a completion
  notification. `persistTargetLen` uses initialized KV offsets as well as step,
  since hybrid layer zero need not advance KV step.
- The writer owns host buffers only, bounded by its existing byte permit.
  Files are FIFO, with metadata submitted last; large files use temporary-file
  parts. Failures and epoch fencing drop work, and harvested failures poison
  entries. No path fsyncs. The relevant guarantee is process-crash
  recoverability of landed filesystem data, not power-loss durability.
- `entryWritesPending` excludes staged/in-flight entries.
  `fullPrefixEntryId` checks token identity, quantization, KV extent and indexed
  chunk presence. `entryWholeOnDisk` checks actual **KV chunk sizes only**.
  Neither proves that GDN plus QSA restoration is valid.
- Hybrid selection ranks checkpoint positions within the matching prefix,
  not raw KV lengths. Restoration loads the SSM point and validates its QSA
  pooled-history coverage (possibly through a separate history file or newer
  point). Speculative sidecars are optional for trunk correctness.
- Idle spilling first attempts writes, then evicts confirmed whole copies,
  then sheds unpersistable entries to enforce its allowance. Admission eviction
  directly drops entries until the live-memory constraint is met. Checkouts
  release entry handles immediately before the slot appends, allowing donation;
  an uncommitted checked-out entry cannot be treated as retained recovery state.

## Reading the numbers

The read-only before/after tool for this area is `scripts/measure-persistence.sh`
([measurements](engine-persistence-measurements.md)): two `GET` snapshots either side of a session and the diff
between them. It changes nothing, and it withholds bytes-per-newly-durable-token and write amplification until a
verified durable-token metric exists, because this audit's own conclusion is that `landed` is not that proof.
The [second campaign](engine-persistence-campaign2.md) adds fixed origin-by-kind
landed-byte accounting so a future window can distinguish prefill, completion
and spill costs, including bytes in partial appends.

## Feasible policy boundary

The optional `--prefix-cache-persist-min-tokens` policy intentionally relaxes
post-restart recovery coverage. It checks a matching landed hybrid SSD anchor
before skipping live capture, discards the new tail at process exit, and
recomputes it from a later full client prompt. Its RAM entry still sheds older
checkpoints under the baseline limit. A queued write, KV-only record, or
missing QSA bank is never counted as that anchor.

Campaign 2 now includes `--prefix-cache-ssm-dedup`, a narrower opt-in write
reduction that does not defer a completion. It compares a newly serialized Qwen
checkpoint byte for byte with a landed checkpoint file at the same position in
another entry, then hard-links only an exact match. QSA bank files retain their
existing independent persistence and restore checks. A miss follows the
existing writer. Disk budget accounting still charges the same logical file
size as the baseline, so reuse and eviction thresholds are unchanged. No
checkpoint or pending snapshot is held for a future request. The donor read
occurs on the inference thread; live latency and eligible fraction are not yet
measured.

The least invasive candidate is to defer only when existing budgeted RAM state
already preserves normal reuse, before `capturePendingDisk`. There must be a
confirmed matching SSD recovery anchor, and a cumulative token difference from
that anchor; a request count or global model cursor is incorrect for branches.
Force existing persistence for checkpoint release, trimming, eviction,
ownership transfer, missing anchors and writer failure. Never keep a deferred
pending snapshot. A future completion must observe the same older SSD anchor.

A decode-end transfer is not established safe by this audit: grouped recurrent
state and MLX views can pin parent allocations, and QSA history has independent
coverage rules. Do not add a copy or shallow share to enable the throttle.
Checkpoint-backed deferral needs tests against baseline retained buffers and
restored positions before it can be enabled. Unsupported cases must retain
legacy behavior and expose a fallback reason.

## Instrumentation boundary

Count one operation around `appendCommitWith`, not one file, blob or piece.
Associate actual writer completion/failure with that operation without retaining
tensor handles. Count synchronous token and metadata writes too. Report no-op,
partial and failed work separately; a queued operation cannot enter the
successful histogram. Any bounded tracking overflow must be explicit, never
misreported as success.

`server.diskBytesPerToken` includes serialized KV/QSA/head geometry and amortizes
fixed recurrent checkpoints over `POINT_GRID`. It excludes per-file headers and
does not model arbitrary prompt-end checkpoint spacing, sidecar rewrites or all
fixed per-entry state. It is a budget estimate, not an exact theoretical unique
serialization denominator. Do not label its ratio exact write amplification.

`--ssm-checkpoint-stride` was intentionally removed (`docs/flags.md`); changing
that grid is separate from completion cadence. `POINT_GRID` remains unchanged.

## Timing and origin instrumentation (landed)

The receipt around `appendCommitWith` now also carries, in the same 64 fixed
slots and with no new allocation:

- an **origin** per attempt (`prefill_write_through`, `decode_point`,
  `request_complete`, `idle_spill`, `decline_spill`, `other`), named at each
  production call site and counted at begin (attempts, not outcomes);
- four **duration stages** for landed appends: `inference` (the inference
  thread's own span — GPU→host readback, serialization, synchronous writes and
  permit waits; readback cannot be split out without touching MLX internals,
  so it rides inside this stage), `wait` (the part blocked on the writer's
  host-byte permit, measured inside `waitForRoomLocked`), `writer` (the writer
  thread's `open`/`write`/`rename` time of this operation's landed blobs) and
  `e2e` (begin to last reference released — wall-clock including queueing; it
  is NOT time blocking inference and must never be read as a stall);
- two process-wide counters, `writer_busy_ns` and `writer_wait_ns`, which
  cover ALL writer work including receipt-less (untracked, restore-time and
  bare-writer) spans, so the totals never under-count while the histograms
  only ever show landed appends.

Without a writer thread the synchronous write time lands in `inference`, not
`writer`; `wait` ⊆ `inference` and `writer` + queueing ≈ `e2e − inference`.
Overflow (`untracked`) drops that operation's stage observations but not its
total contributions. Timestamps are boot-clock reads at begin/finish/last-
release only — never per token, never per blob part beyond the one stopwatch
per write.

## Durable-token attribution (blocked, documented)

The interval and amplification rows still have NO metric, and a plausible-
looking approximation was rejected rather than built:

- `landed` counts filesystem completion; restorability additionally requires
  the KV extent, the hybrid checkpoint rule and QSA pooled-history coverage,
  each with its own check (`fullPrefixEntryId`, `entryWholeOnDisk`, hybrid
  selection) — none is per-operation proof.
- A restorable-token counter must be MONOTONIC to be diffable by the
  measurement tool (a falling process counter is refused as a reset), yet
  budget eviction, poisoning, trimming and fence drops REMOVE previously
  restorable prefixes. A correct counter therefore needs an ownership audit
  of every removal path — that is a persistence-machinery redesign, not an
  instrumentation edit.
- Attribution must also survive branching: an append may re-land an already
  recoverable prefix (spec sidecar rewrite, checkpoint thinning) and add
  zero new restorable tokens; distinguishing new coverage needs the
  recovery-cursor bookkeeping the audit's "Feasible policy boundary" section
  already lists as a prerequisite for throttling.

Until that lands, `scripts/measure-persistence.sh` keeps rows 5 (durable
column) and 9 withheld, and looks for a counter named
`*durable_tokens_total` or `*restorable_tokens_total`; the engine serves
neither.

## Validation isolation

The production executable must remain untouched. Use an explicit separate Zig
install prefix, checksum `zig-out/bin/sushi` before/after, and use temporary
prefix-cache roots for tests. Do not stop, restart or load models into the live
production server. No live workload comparison has yet been performed.

## Handoff status

The initial instrumentation milestone added bounded logical-append receipts,
filesystem completion outcome counters, byte histograms, and per-model staging
figures. `scripts/measure-persistence.sh` landed beside it, and the receipts
now also carry timing stages and origins (see "Timing and origin
instrumentation") — still no engine flag and no persistence-policy change.
Phase 1 remains incomplete: confirmed hybrid recovery
cursors, token intervals and write-amplification denominators are still needed
before implementing the minimum-token gate (see "Durable-token attribution
(blocked, documented)").

Validation completed: host suite 748 passed / 7 skipped; focused disk-write,
DiskStats, props, metrics and Qwen prefill-grid tests 25 passed; ReleaseFast
build and isolated executable `--help` succeeded; suite guards and diff
whitespace check passed. The focused run disabled GPU tests. The broader suite
was launched with GPU tests disabled and serial compilation; its result was
still pending at handoff. No real-model A/B, restart workload, TTFT comparison
or measured GPU-memory non-regression has been performed. No SSD-write savings
are claimed. The production binary's checksum remained unchanged.

Resume validation (timing and origins): full `test-host` tier green with the
timing receipts, writer-attribution and origin counters added; the candidate
ReleaseFast binary builds to an isolated prefix and its `--help` runs without
touching a model; `zig-out/bin/sushi`'s checksum is byte-identical before and
after. `tests/test_measure_persistence.sh` covers the tool's use of the new
fields (107 assertions). MLX-tier tests that exercise the renamed signatures
(`prefix_cache`, `qwen4_prefix_cache_test`, `glm5_prefix_cache_test`,
`dsv41_prefix_cache_test`, `kv_disk_cache`, `metrics`, `models_api`,
`model_registry`) are compile-checked by the ReleaseFast build but NOT
EXECUTED here (they need MLX); a full `zig build test` run is deferred to the
user. No live workload has been measured yet.

Continue by completing operation-to-confirmed-recovery attribution (including
QSA and branched prefixes and the eviction-aware monotonicity problem
documented under "Durable-token attribution (blocked, documented)"), then
write failing cumulative-threshold tests.
Gate before snapshot capture, preserve the existing checkpoint-retention cap,
and force existing behavior wherever an equivalent budgeted RAM recovery point
cannot be proved. Do not use the serialization `landed` counter as that proof.
