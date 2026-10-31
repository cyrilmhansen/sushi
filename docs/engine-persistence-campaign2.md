# Persistence campaign 2: byte attribution before a cadence change

This experiment branches from `0352b5d7`. It changes accounting only. The live
pi-2 window (191 minutes, 107 successful requests, 434,050 computed tokens) wrote
28.81 GiB: SSM 15.67 GiB, QSA 5.71 GiB, KV 5.27 GiB, spec 2.16 GiB. These
rounded kind totals sum to 28.81 GiB; metadata and rounding account for any
small difference in a raw report. The measured rate is about 0.151 GiB/minute
and 71.3 KiB per **computed** token. Computed tokens are not newly restorable
tokens. None of these numbers establishes a saving from any proposed policy.

## Where those bytes can come from

- Prefill write-through calls `appendCommitWith` at chunk boundaries, with a
  one-chunk flush bound in RAM-backed mode. `settleCheckpoints` then releases
  older recurrent points to meet the existing memory bill, whether or not a
  write succeeded. The 8192-token Qwen checkpoint grid is independent of the
  actual 2048-token prefill chunk.
- Request completion first captures `pending_disk` from live state, before RAM
  budget trimming and slot teardown. Its whole append can serialize new SSM
  points, a growing QSA bank and a replacement spec sidecar. Retaining the
  pending snapshot for a later turn would retain tensor buffers outside the
  cache budget.
- Existing KV chunks are reused within an extending record; the old partial
  tail is rewritten. A new branched record may hard-link full KV chunks and an
  eligible QSA history. Token records append. SSM points are immutable by
  position **within one record**; an old position is skipped there, but a new
  branched record can serialize it again. QSA history is kept if its owned
  bank already covers the new point, otherwise `qsa.safetensors` is replaced
  wholesale; a growing history can therefore cost much more than its delta.
  `spec.safetensors` is one replaceable sidecar and is rewritten when an
  extension updates MTP/DFlash state. Metadata may be rewritten after an append
  and independently on restore.
- Idle spill writes old resident entries again when needed, then evicts only
  verified whole copies before shedding unpersistable entries under pressure.
  `PersistOutcome.persisted` alone can mean queued or superseded work; a landed
  receipt alone does not prove QSA-compatible hybrid restoration.

There were 206 prefill, 107 completion and 31 idle-spill attempts (plus other
origins), but the existing 188 landed, 124 partial and 32 no-op outcomes do
not cross-tabulate bytes with origins. In particular, 15.67 GiB of SSM traffic
cannot be assigned to completion. The new fixed 6×6 origin-by-kind counters
measure landed bytes at the actual file writer and synchronous write sites,
including partial operations. Their row/column totals reconcile with the
existing per-kind totals; receipts are not required for byte attribution, so
the 64-receipt overflow case also remains visible. No token path is touched.

## Hypothesis ranking

The ranges below are **ceilings, not predicted savings**. A 0 lower bound is
necessary because the baseline does not contain origin-by-kind bytes, verified
durable advancement, or an identical live replay under another policy. The
operator should rank again after collecting those fields.

| Rank | Hypothesis | Measured opportunity ceiling | Memory and recovery assessment | Risk |
|---|---:|---:|---|---|
| 1 | H2 selective completion | 0–28.81 GiB, narrowed by the new `request_complete` row | Only safe if write-through already left a confirmed matching hybrid/QSA recovery point and the RAM entry retains ordinary reuse within budget; completion can still add a prompt-end or thought point and MTP state | medium |
| 2 | H3 incremental auxiliary state | SSM+QSA+spec total 23.54 GiB (81.7%); avoidable fraction unknown | Existing immutable SSM files and QSA hard links already eliminate some duplicates. Segmenting growing QSA or spec needs a new on-disk restore contract, crash tests and budget accounting; it need not retain tensors | high |
| 3 | H1 cumulative token interval | 0–28.81 GiB before origin attribution; actual bound is writes safely eligible below N | Needs a per-lineage **confirmed** restorable cursor, not KV length or an append receipt. A short decode may add no GDN checkpoint; pending snapshots cannot wait in RAM. Forced writes for bootstrap, eviction, checkpoint release and failures may dominate | high |
| 4 | H4 coalesce prefill writes | 0–28.81 GiB before origin attribution; actual bound is the prefill row | Older checkpoint release is the existing RAM bound. A skipped write still needs the same release, which can lose that point after restart; preserving it in RAM would break the constraint. Changing `POINT_GRID` is unrelated | high |

H2 ranks first as a **measurement and proof target**, not as an enabled policy.
The existing superseded path already accounts for 32 no-op attempts, so a new
gate must demonstrate real bytes beyond those no-ops. H3 has the largest kind
ceiling, but a format change has much greater regression risk. A nominal
`--prefix-cache-persist-min-tokens` setting is withheld until a host fixture
can prove cumulative eligibility, branch isolation, QSA/MTP restoration and
zero extra retained tensor state. Thresholds 1024/4096/16384 cannot be
estimated from request counts: no restorable-token gaps were measured.

## Operator A/B procedure

The user performs all live runs and model/server control. Build each candidate
into its own isolated prefix; do not overwrite `zig-out/bin/sushi`. Each window
uses the same production-equivalent model, KV8, GDN16, MTP policy, 220k context,
2048 prefill chunk, cache budgets, prompts and temperature. For a future
policy-enabled build, vary only `--prefix-cache-persist-min-tokens` among
0/1024/4096/16384. Give every run a separate `SUSHI_PREFIX_CACHE_DIR`, and
compare warm windows after the same warm-up so cold cache creation does not
masquerade as policy cost.

After the operator has stopped the live server by their own procedure, the
candidate's production-equivalent launch shape is:

```bash
cd "${SUSHI_CHECKOUT:?set checkout}"
SUSHI_PREFIX_CACHE_DIR="/tmp/sushi-campaign2-cache-n0" \
DYLD_LIBRARY_PATH="$PWD/lib/mlx/lib" \
/tmp/sushi-campaign2-candidate/bin/sushi --serve --host 127.0.0.1 \
  --port "${SUSHI_PORT:-12345}" --model "${SUSHI_MODEL:?set model path}" \
  --mtp --no-vision --kv-quant 8 --max-resident-models 1 --timeout 900 \
  --mtp-greedy-tail --prefix-cache-mem 1GB --mtp-min-depth 1 \
  --mtp-max-depth 4 --prefill-chunk 2048 --mtp-head-kv-quant \
  --qwen-gdn 16 --ctx-size 220000 --max-tokens 20000 \
  --prefix-cache-disk 20GB --prefix-cache-entries 4 --temp 1 --metrics
```

Use a fresh cache directory suffix and the validated future flag for each
other arm. The present candidate has no persistence-threshold flag; it serves
only the baseline policy with better byte attribution. The command is for the
operator to run later, never part of automated validation.

```bash
cd "${SUSHI_CHECKOUT:?set checkout}"
shasum -a 256 zig-out/bin/sushi
./.zig-toolchain/zig build -Doptimize=ReleaseFast --prefix /tmp/sushi-campaign2-candidate
shasum -a 256 zig-out/bin/sushi /tmp/sushi-campaign2-candidate/bin/sushi

# Run these around each operator-controlled Pi session against its server URL:
scripts/measure-persistence.sh --url "${SUSHI_URL:?set URL}" --dir /tmp/sushi-campaign2-reports start pi-n0
# ... operator runs the fixed conversation ...
scripts/measure-persistence.sh --url "$SUSHI_URL" --dir /tmp/sushi-campaign2-reports stop pi-n0
scripts/measure-persistence.sh --dir /tmp/sushi-campaign2-reports report pi-n0
jq '.bytes.by_origin_kind, .bytes.by_kind, .serializations, .durations.stages' /tmp/sushi-campaign2-reports/pi-n0/report.json
```

Repeat the `start`, `stop`, `report` and `jq` commands with session names
`pi-n1024`, `pi-n4096`, `pi-n16384` only after a validated flag exists and the
operator has started the corresponding isolated configuration. Record cache
hits, post-restart restorable tokens, TTFT, throughput, resident cache bytes,
MLX/host peak and writer staging peak beside the byte report. Neither the
script nor this experiment starts, stops or reconfigures the live server.
