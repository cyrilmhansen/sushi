# Measuring SSD persistence volume

`scripts/measure-persistence.sh` measures how many bytes the SSD prefix cache wrote in a window you
choose: one snapshot before the session, one after, then the diff between them.

It is an HTTP reader and nothing else. Each snapshot is two `GET`s (`/metrics.json`, `/props`) — never a
POST/PUT/DELETE, never an inference request, no model load, no process control, no cache mutation, no
polling loop, no background job, no GPU or MLX work. Its only writes go under its report directory,
`${SUSHI_RUNS_DIR:-$HOME/.sushi/runs}/persistence` by default, and it refuses a report directory inside
the SSD prefix cache root (`${SUSHI_PREFIX_CACHE_DIR:-$HOME/.sushi/kv-cache}`): a measurement must never
land in the cache it measures. Metrics are process-wide since boot and `/metrics.json` answers 503 while
they are off, so a server needs `--metrics` to be measurable through HTTP; the script says so rather
than inventing a number.

Read [engine-prefix-cache](engine-prefix-cache.md#write-counters) for what the counters mean and
[the cadence audit](engine-persistence-audit.md) for what a landed append does and does not prove.

## Commands

```bash
scripts/measure-persistence.sh [--url URL] [--dir DIR] start  SESSION
scripts/measure-persistence.sh [--url URL] [--dir DIR] stop   SESSION
scripts/measure-persistence.sh [--dir DIR] [--json]    report SESSION
```

`--url` defaults to `http://127.0.0.1:12345`, `--dir` to `${SUSHI_RUNS_DIR:-$HOME/.sushi/runs}/persistence`.
`SESSION` is a directory name (letters, digits, `.`, `_`, `-`). Nothing is ever overwritten: a session
that already has a start or a stop snapshot is refused, so pick a new name. `report` prints the table,
and writes `report.txt` plus `report.json` beside the two snapshots; `--json` prints only the machine-
readable diff. Raw bodies stay verbatim at `<dir>/<session>/{start,stop}/{metrics,props}.raw`.
Exit status: `0` a usable report, `1` a window whose write counters were never measurable, `2` a refused
comparison or a bad argument.

## A session measurement (stage A — the current production baseline)

The served binary carries the per-kind byte counters, the failed-byte counter and the append OUTCOME counters with
their size histogram. It does NOT yet carry the timing stages, origins or writer totals — those exist only in a
candidate build (stage B). Nothing here starts, stops or steers a server; the tool issues two `GET`s.

```bash
# immediately before the Pi session, against the server that will serve it
scripts/measure-persistence.sh start pi-baseline

# … run the Pi session against the same server, changing nothing …

# the matching end of the window, then the diff
scripts/measure-persistence.sh stop pi-baseline
scripts/measure-persistence.sh report pi-baseline
```

`report.json` keeps every raw delta the table was built from, so analysis can go past the printed rows:

```bash
R=~/.sushi/runs/persistence/pi-baseline/report.json
jq '.bytes.by_kind, .bytes.mb_per_min, .serializations, .histogram' "$R"
jq '.durations.stages | with_entries(select(.value != null and .value.n? > 0))' "$R"   # empty on stage A
jq '.origins, .writer' "$R"                                                            # empty on stage A
jq '.bytes.by_origin_kind' "$R"                                                        # available when origin-by-kind counters are served
```

## Stage B — the candidate instrumentation build

Build the candidate WITHOUT touching the production binary: an isolated install prefix, checksum first and after.

```bash
cd "${SUSHI_CHECKOUT:?set this to your sushi checkout}"   # e.g. export SUSHI_CHECKOUT="$HOME/src/sushi"
shasum -a 256 zig-out/bin/sushi | tee /tmp/prod-sushi.sha256        # record the production checksum
.zig-toolchain/zig build -Doptimize=ReleaseFast -p /tmp/sushi-candidate-prefix install
shasum -a 256 /tmp/sushi-candidate-prefix/bin/sushi                  # the candidate's own stamp — record it beside the git commit
shasum -a 256 -c /tmp/prod-sushi.sha256                              # zig-out/bin/sushi must be unchanged
DYLD_LIBRARY_PATH="$PWD/lib/mlx/lib" /tmp/sushi-candidate-prefix/bin/sushi --help | head   # CLI check only; loads no model
```

Then — ONLY if you, the operator, choose to run the candidate as a server; nothing in this repository does it for
you, and the tool itself never starts, stops or configures anything:

1. Stop the running server by your normal means (its supervisor or its own Ctrl-C).
2. Relaunch the SAME model with the SAME flags (`--kv-quant`, `--max-chunk`, cache budgets, effort, MTP policy) and
   `--metrics`, from the candidate binary. Keep the SAME `--prefix-cache-root` if you want the warm cache to carry
   over; give the candidate its OWN root if you want to measure two independent caches — and then know that a fresh
   root writes everything once from cold, so bytes-per-token is NOT comparable to a warm-cache window. Record which.
3. Run the same workload you ran in stage A, for a similar wall-clock length.
4. Measure the window and compare the two reports:

```bash
scripts/measure-persistence.sh start pi-candidate
# … the same session …
scripts/measure-persistence.sh stop pi-candidate
scripts/measure-persistence.sh report pi-candidate
```

5. Restore the environment by hand the same way: stop the candidate, relaunch the production binary with the
   original flags.

A report never spans addresses: it refuses two snapshots from different `--url`s and refuses a build, model,
architecture or KV-scheme change INSIDE one window, so stage A and stage B are two windows read side by side,
never one diff.

## Stage C — reading the two windows together

| question | stage A (production) | stage B (candidate) |
|---|---|---|
| how much did the cache write, by kind, per minute | rows 2–3 | rows 2–3 |
| how big are the appends (mean/P50/P95 bytes) | row 7 | row 7 |
| how long does persisting cost the inference thread | — (unmeasured) | row 8 `inference` and `wait` |
| how long does the filesystem take, and how far behind does completion trail | — (unmeasured) | row 8 `writer` and `e2e` |
| who triggers persistence | — (unmeasured) | row 6 origins |
| bytes per newly processed token | row 5, relative only | row 5, relative only |
| bytes per newly DURABLE token, write amplification, token intervals | withheld everywhere until a restorability counter exists | withheld everywhere until a restorability counter exists |

Useful diffs across the two reports:

```bash
A=~/.sushi/runs/persistence/pi-baseline/report.json
B=~/.sushi/runs/persistence/pi-candidate/report.json
jq -n --slurpfile a "$A" --slurpfile b "$B" '
  "MB/min: \($a[0].bytes.mb_per_min) -> \($b[0].bytes.mb_per_min)",
  "B/token processed: \($a[0].per_token.processed) -> \($b[0].per_token.processed)",
  "landed: \($a[0].serializations.landed) -> \($b[0].serializations.landed)"'
jq '.durations.stages | map_values({n, mean_us, p50, p95})' "$B"    # timing is candidate-only; A has nulls
jq '.origins' "$B"                                                  # candidate-only attempt mix by origin
```

The percentage of write traffic spent on state REWRITES (sidecars, re-indexed meta, QSA history extensions) cannot
be computed from either build yet: the per-kind totals count a rewrite exactly like a first write, and telling them
apart needs the same recovery-cursor bookkeeping as the durable-token metric
([audit](engine-persistence-audit.md#durable-token-attribution-blocked-documented)).

## Production against a candidate build

Two windows, one per server — a diff never spans addresses (it refuses two different `--url`s, and a
build change inside one window is itself a refusal):

```bash
scripts/measure-persistence.sh --url http://127.0.0.1:12345 start prod-window
# … the workload …
scripts/measure-persistence.sh --url http://127.0.0.1:12345 stop prod-window
scripts/measure-persistence.sh report prod-window

scripts/measure-persistence.sh --url http://127.0.0.1:12346 start cand-window
# … the same workload …
scripts/measure-persistence.sh --url http://127.0.0.1:12346 stop cand-window
scripts/measure-persistence.sh report cand-window
```

Give both windows the same workload and roughly the same length, and run the candidate on its own
`--prefix-cache-root`; sharing the production tree measures one cache twice, not two behaviours. Row 5
(bytes per newly processed token) is what a cadence change moves, and row 3 says which file kind moved.

## Reading the report

| row | number | what it is worth |
|---|---|---|
| 1 | duration, identity, capacity | the window and the server it belongs to; identity is what lets the diff refuse a reload |
| 2 | SSD bytes, MB/min (MiB/min), failed bytes | filesystem bytes the cache accepted — not NAND wear |
| 3 | bytes by kind | `kv`, `ssm`, `qsa`, `spec`, `ring`, `meta` shares of the window |
| 4 | work | forwarded prefill tokens (cache restores are excluded), generated tokens, restored tokens, request counts |
| 5 | bytes per token | PROCESSED counts every landed byte over every token computed here; DURABLE counts only tokens a restore can resume from |
| 6 | serializations | landed, no-op, partial, failed, untracked append operations, landed bytes, and this model's tier totals from `/props` |
| 7 | landed append size | mean from the delta sum over the delta count; P50/P95 from bucket DELTAS |
| 8 | persistence timing | landed appends get four stage histograms — `inference` (readback + serialization + sync writes + waits, on the inference thread), `wait` (permit waits inside that), `writer` (writer-thread filesystem time), `e2e` (begin to last piece landed, queueing included — NOT inference-blocking time); mean/P50/P95 from bucket deltas. Writer-busy and wait totals cover all work. Token intervals still print `unavailable` |
| 9 | write amplification | bytes per newly restorable token, and only with a durable-token metric |

Percentiles are never a subtraction of two snapshots' percentiles. Each is named as its own bucket upper
bound (`<= 1 MiB`), and an observation in the open-ended top bucket is a lower bound (`> 4 GiB`) — the
histogram cannot say more, so neither does the tool. A key present at one snapshot and absent at the
other is reported, not diffed. A `props_prefix_cache` total going backwards is this model's cache tier
reopening (a reload), which excludes those per-tier rows and warns; a *process* counter going backwards
is a reset and refuses the comparison; a gauge (`requests_running`, `memory_mb`, `generation_tokens_live`)
going backwards is normal and never reads as a reset.

## What is valid before durable-token instrumentation

Valid now, on the landed-append counters in `disk_write_stats.zig`:

- bytes written in the window by kind, and the rate;
- failed and dropped write bytes;
- landed / no-op / partial / failed / untracked append counts and landed bytes, and their mean/P50/P95 size;
- since the timing milestone, for builds that serve them (stage B): the four duration stages per landed append,
  persist attempts by origin, and the writer-busy / permit-wait totals.
- bytes per newly processed token, as a RELATIVE comparison between two windows that ran the same
  workload on the same model, KV scheme and build.

Not valid yet, and withheld rather than estimated:

- bytes per newly **durable** token and write amplification (row 9): they need a counter for tokens a
  restore can actually resume from. `landed` certifies filesystem completion only — the KV extent, the
  recurrent checkpoint and the QSA coverage each have their own rule
  ([audit](engine-persistence-audit.md#landed-data-and-restoration)) — and `server.diskBytesPerToken` is
  a budget estimate, not a theoretical serialization denominator, so neither may be used as the denominator.
- effective token intervals between successive recoverable states (row 8's last line): the same missing
  restorability counter; see
  [the blocker](engine-persistence-audit.md#durable-token-attribution-blocked-documented).

The tool looks for a counter named `*durable_tokens_total` or `*restorable_tokens_total`; when one
appears in both snapshots, rows 5 and 9 fill in and `report.json` records the key it used under
`tokens.durable_key`. Until then those rows print `unavailable` / `not reported` with the reason, and an
absent metric never prints as 0 — `untracked: 0` is a real zero (no receipt-pool overflow), which is why
it is worth reading.

## Guard

`tests/test_measure_persistence.sh` (tier hermetic, needs `jq`, `curl`, `python3`) drives the script
against the synthetic bodies of `tests/fixtures/persistence/gen.py`, served by
`tests/lib/fake_metrics_server.py`: the happy-path arithmetic, percentiles from bucket deltas, the
durable-token branch, a build without the counters, disabled metrics (503), an unavailable `/props`
(404), the refusals (reset, model/architecture/build change, moved histogram bounds, two addresses)
against the warnings they must not be confused with (a reopened tier, a backwards gauge, a changed
prefill chunk), no overwrite of a session, the cache-root placement refusal with nothing created inside
the cache, and that every request the script made was a `GET` of a metrics route. No GPU, no model,
seconds. `python3 tests/fixtures/persistence/gen.py tests/fixtures/persistence` regenerates the bodies.
