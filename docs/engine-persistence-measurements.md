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

## A session measurement

```bash
# immediately before the Pi session, against the server that will serve it
scripts/measure-persistence.sh start pi-baseline

# … run the Pi session against the same server, changing nothing …

# the matching end of the window, then the diff
scripts/measure-persistence.sh stop pi-baseline
scripts/measure-persistence.sh report pi-baseline
```

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
| 8 | persistence duration, token intervals | only once those counters exist; until then the row says so |
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
- landed / no-op / partial / failed / untracked append counts and landed bytes;
- the size distribution of landed appends;
- bytes per newly processed token, as a RELATIVE comparison between two windows that ran the same
  workload on the same model, KV scheme and build.

Not valid yet, and withheld rather than estimated:

- bytes per newly **durable** token and write amplification (row 9): they need a counter for tokens a
  restore can actually resume from. `landed` certifies filesystem completion only — the KV extent, the
  recurrent checkpoint and the QSA coverage each have their own rule
  ([audit](engine-persistence-audit.md#landed-data-and-restoration)) — and `server.diskBytesPerToken` is
  a budget estimate, not a theoretical serialization denominator, so neither may be used as the denominator.
- persistence duration and effective token intervals (row 8): no such metric exists in a served build.

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
