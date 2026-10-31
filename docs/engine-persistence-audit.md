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

## Feasible policy boundary

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

## Validation isolation

The production executable must remain untouched. Use an explicit separate Zig
install prefix, checksum `zig-out/bin/sushi` before/after, and use temporary
prefix-cache roots for tests. Do not stop, restart or load models into the live
production server. No live workload comparison has yet been performed.

## Handoff status

The user requested conclusion before the full mission was complete. The initial
instrumentation milestone adds bounded logical-append receipts, filesystem
completion outcome counters, byte histograms, and per-model staging figures.
It changes no persistence policy or tensor ownership. Neither requested CLI
flag has been added. Phase 1 remains incomplete: confirmed hybrid recovery
cursors, token intervals and write-amplification denominators are still needed
before implementing the minimum-token gate.

Validation completed: host suite 748 passed / 7 skipped; focused disk-write,
DiskStats, props, metrics and Qwen prefill-grid tests 25 passed; ReleaseFast
build and isolated executable `--help` succeeded; suite guards and diff
whitespace check passed. The focused run disabled GPU tests. The broader suite
was launched with GPU tests disabled and serial compilation; its result was
still pending at handoff. No real-model A/B, restart workload, TTFT comparison
or measured GPU-memory non-regression has been performed. No SSD-write savings
are claimed. The production binary's checksum remained unchanged.

Continue by completing operation-to-confirmed-recovery attribution (including
QSA and branched prefixes), then write failing cumulative-threshold tests.
Gate before snapshot capture, preserve the existing checkpoint-retention cap,
and force existing behavior wherever an equivalent budgeted RAM recovery point
cannot be proved. Do not use the serialization `landed` counter as that proof.
