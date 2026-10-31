#!/bin/bash
# sushi-test: tier=hermetic needs=jq,curl,python3
# test_measure_persistence.sh — scripts/measure-persistence.sh against synthetic JSON fixtures.
#
# Nothing here touches a model, a GPU, MLX or a real cache: the two endpoints the tool reads are
# served by tests/lib/fake_metrics_server.py from bodies written by tests/fixtures/persistence/gen.py.
#
# Checks:
#   1. the happy path: byte totals, per-kind shares, serialization counts, and percentiles computed
#      from BUCKET DELTAS (the fixtures are built so a delta of the two snapshots' P95s would lie)
#   2. bytes per newly processed token vs per newly durable token, and write amplification only when
#      a durable-token counter exists
#   3. a build without the write counters: every absent row says "not measured", never 0
#   4. metrics disabled (/metrics.json 503), /props unavailable (404) and a 200 whose body is not JSON:
#      explicit diagnostics naming the reason, with the raw body kept
#   5. refused comparisons: counter reset, model change, histogram bounds change; a per-tier reopen is
#      a warning, and a gauge going backwards is not a reset at all
#   6. safety: GETs only, no overwrite of an existing session, no report dir inside the SSD prefix
#      cache root, and no file created inside that root
#
# No GPU, no model, seconds.
#
# Usage: ./tests/test_measure_persistence.sh

set -u
cd "$(dirname "$0")/.." || exit 1

TOOL=scripts/measure-persistence.sh
SERVER=tests/lib/fake_metrics_server.py
PASS=0
FAIL=0
check() { if [ "$1" = 0 ]; then PASS=$((PASS + 1)); echo "PASS $2"; else FAIL=$((FAIL + 1)); echo "FAIL $2"; fi; }
has() { grep -qF -- "$2" "$1"; }

for t in jq curl python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP $t missing"; exit 3; }
done
[ -f "$TOOL" ] || { echo "FAIL $TOOL missing"; exit 1; }

CASES="instrumented legacy durable reset modelchange boundschange tierreset chunkchange budgetchange"

TMP=$(mktemp -d)
SRV=
cleanup() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT

FX=tests/fixtures/persistence           # the committed synthetic bodies the tool is tested against
FIX="$TMP/fixtures"                     # a fresh regeneration, for the drift check below
SERVE="$TMP/serve"
CACHE="$TMP/cache"
RUNS="$TMP/runs"
mkdir -p "$FIX" "$SERVE" "$CACHE" "$RUNS"
python3 "$FX/gen.py" "$FIX" || { echo "FAIL fixture generator"; exit 1; }

# The committed bodies are the baseline: a fixture edited without regenerating it, or gen.py changed
# without landing its output, is drift.
DRIFT=0
for case in $CASES; do
    for label in start stop; do
        for f in metrics.json props.json; do
            cmp -s "$FX/$case/$label/$f" "$FIX/$case/$label/$f" || { echo "  drift: $case/$label/$f"; DRIFT=$((DRIFT + 1)); }
        done
    done
done
check "$DRIFT" "the committed fixtures are what gen.py generates"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
ACCESS="$TMP/access.log"
: >"$ACCESS"
python3 "$SERVER" "$SERVE" "$PORT" "$ACCESS" >/dev/null 2>&1 &
SRV=$!
i=0
while [ $i -lt 50 ]; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/ping" && break
    i=$((i + 1))
    sleep 0.1
done

# the readiness probe was a GET too; the access-log assertions are about the tool
: >"$ACCESS"
U="http://127.0.0.1:$PORT"
# serve_case <fixture case> <session>: snapshot the case's start bodies, swap in its stop bodies,
# snapshot again, report. The tool sees one address throughout, as it does against a live server.
# Sets RC (report exit), REPORT/RJSON paths, SO/TO (start/stop tool output).
serve_case() {
    local case=$1 session=$2
    cp "$FX/$case/start/metrics.json" "$SERVE/metrics.json" 2>/dev/null || rm -f "$SERVE/metrics.json"
    cp "$FX/$case/start/props.json" "$SERVE/props"
    "$TOOL" --url "$U" --dir "$RUNS" start "$session" >"$TMP/$session.start" 2>&1
    sleep 1
    cp "$FX/$case/stop/metrics.json" "$SERVE/metrics.json" 2>/dev/null || rm -f "$SERVE/metrics.json"
    cp "$FX/$case/stop/props.json" "$SERVE/props"
    "$TOOL" --url "$U" --dir "$RUNS" stop "$session" >"$TMP/$session.stop" 2>&1
    cat "$TMP/$session.start" "$TMP/$session.stop" >"$TMP/$session.snapshots"
    "$TOOL" --dir "$RUNS" --json report "$session" >"$TMP/$session.report" 2>&1
    RC=$?
    REPORT="$RUNS/$session/report.txt"
    RJSON="$RUNS/$session/report.json"
}

# ---------------------------------------------------------------- 1. the happy path

serve_case instrumented full
has "$TMP/full.snapshots" "start snapshot of"; check $? "start snapshot taken"
has "$TMP/full.snapshots" "stop snapshot of"; check $? "stop snapshot taken"
[ -f "$REPORT" ]; check $? "report written"
grep -qE "total:[[:space:]]+58\.63 MiB \(61472768 bytes\)" "$REPORT"; check $? "total SSD bytes is the delta of the per-kind counters"
grep -qE 'rate:.*MiB/min' "$REPORT"; check $? "average MB/min computed"
grep -qE 'kv[[:space:]]+85\.29%' "$REPORT"; check $? "kv share of the window's bytes (52428800 of 61472768)"
grep -qE 'ring[[:space:]]+0%[[:space:]]+0 B' "$REPORT"; check $? "a kind that did not move reads 0 B, its true delta"
grep -qE 'newly processed tokens:[[:space:]]+250000' "$REPORT"; check $? "newly processed = forwarded prefill + generated"
grep -qE 'generated tokens:[[:space:]]+50000' "$REPORT"; check $? "generated token delta"
grep -qE 'restored from cache:[[:space:]]+4000' "$REPORT"; check $? "cache-restored tokens named apart from forwarded ones"
grep -qE 'requests completed:[[:space:]]+16' "$REPORT"; check $? "request count delta"
grep -qE "per newly PROCESSED token:[[:space:]]+245\.89 B/token" "$REPORT"; check $? "bytes per newly processed token"
grep -qE 'per newly DURABLE token:[[:space:]]+unavailable: this build has no verified durable-token metric' "$REPORT"; check $? "no durable metric yet: withheld, not guessed"
grep -qE 'landed:[[:space:]]+56[[:space:]]' "$REPORT"; check $? "landed serializations delta"
grep -qE 'no-op:[[:space:]]+3' "$REPORT"; check $? "no-op serializations delta"
grep -qE 'partial:[[:space:]]+2' "$REPORT"; check $? "partial serializations delta"
grep -qE 'failed:[[:space:]]+1' "$REPORT"; check $? "failed serializations delta"
grep -qE 'untracked:[[:space:]]+0' "$REPORT"; check $? "untracked serializations delta (a real zero)"
has "$REPORT" "5 10 30 5 5 0 0 0 0 0 1"; check $? "histogram from bucket deltas, never a subtraction of percentiles"
grep -qE "mean:[[:space:]]+1\.91 MiB \(112000000 B / 56\)" "$REPORT"; check $? "mean landed append size from the delta sum over the delta count"
grep -qE 'P50:[[:space:]]+<= 1 MiB' "$REPORT"; check $? "P50 named as a bucket upper bound"
grep -qE 'P95:[[:space:]]+<= 16 MiB' "$REPORT"; check $? "P95 named as a bucket upper bound (subtracting the two snapshots' P95s would have said 0 B)"
grep -qE 'time spent persisting:[[:space:]]+unavailable: not implemented' "$REPORT"; check $? "persistence duration row skipped, not zeroed"
grep -qE 'effective token interval:[[:space:]]+unavailable: not implemented' "$REPORT"; check $? "token interval row skipped, not zeroed"
has "$REPORT" "not reported: needs a verified durable-token metric"; check $? "write amplification withheld without durability"
grep -qE "capacity:[[:space:]]+60 GiB" "$REPORT"; check $? "cache capacity captured from /props"
grep -qE "identity: model sushi-qwen4  arch qwen4_exp  build 1\.5\.0  engine exl3  kv affine8/8  chunk 8192" "$REPORT"; check $? "served model and build identity captured"
jq -e '.status=="ok"' "$RJSON" >/dev/null; check $? "report.json records a usable comparison"
jq -e '.histogram.bucket_deltas==[5,10,30,5,5,0,0,0,0,0,1] and .histogram.n==56' "$RJSON" >/dev/null; check $? "report.json carries the same bucket deltas"
jq -e '.histogram.p50_bucket==1048576 and .histogram.p95_bucket==16777216' "$RJSON" >/dev/null; check $? "report.json names the percentile buckets, not invented values"
jq -e '.bytes.total==61472768 and (.bytes.by_kind|length==6)' "$RJSON" >/dev/null; check $? "report.json carries total and all six kinds"
jq -e '.bytes.failed==4096' "$RJSON" >/dev/null; check $? "failed-write bytes delta"
jq -e '.tokens.processed==250000 and .per_token.processed==245.89 and .per_token.durable==null' "$RJSON" >/dev/null
check $? "processed and durable per-token figures kept apart in JSON"

# ---------------------------------------------------------------- 2. durable instrumentation

serve_case durable dur
grep -qE 'per newly DURABLE token:[[:space:]]+591\.08 B/token' "$REPORT"; check $? "bytes per newly durable token once the counter exists"
grep -qE '591\.08 B/token over 104000 newly durable tokens' "$REPORT"; check $? "write amplification computed from durability, not activity"
jq -e '.tokens.durable_key=="counters.durable_tokens_total" and .write_amplification==591.08' "$RJSON" >/dev/null
check $? "the durable counter's own name is recorded in the JSON"

# ---------------------------------------------------------------- 3. a build without the counters

serve_case legacy legacy
[ "$RC" = 1 ]; check $? "a window with no write counter at all exits 1, not 0"
has "$REPORT" "no per-kind SSD write counters"; check $? "missing prefix_cache_writes is named as a build gap"
grep -E 'total:|failed:|landed:|mean:' "$REPORT" | grep -qE '[0-9]'; [ $? != 0 ]; check $? "an absent metric is never rendered as a fabricated zero"
grep -qE "total:[[:space:]]+not measured" "$REPORT"; check $? "no total is invented"
grep -qE "failed:[[:space:]]+not measured" "$REPORT"; check $? "no failed-byte figure is invented"
grep -qE 'landed:[[:space:]]+not measured' "$REPORT"; check $? "serialization counts reported as absent"
grep -qE 'mean:[[:space:]]+not measured' "$REPORT"; check $? "no mean is extrapolated from nothing"
jq -e '.status=="incomplete" and (.bytes.total==null) and (.serializations.landed==null)' "$RJSON" >/dev/null
check $? "JSON report keeps absence as null"

# ---------------------------------------------------------------- 4. disabled and unavailable endpoints

python3 -c 'import sys;open(sys.argv[1]+"/OFF","w").close()' "$SERVE"  # the fake server 503s /metrics.json
serve_case instrumented off
has "$TMP/off.snapshots" "metrics are off"; check $? "a 503 from /metrics.json is explained, not swallowed"
has "$REPORT" "metrics are off on this server"; check $? "the report carries the disabled-metrics diagnostic"
jq -e '.status=="incomplete"' "$RJSON" >/dev/null; check $? "a metrics-off window is not reportable as a measurement"

python3 -c 'import os,sys;os.remove(sys.argv[1]+"/OFF");open(sys.argv[1]+"/NOPROPS","w").close()' "$SERVE"
serve_case instrumented noprops
has "$TMP/noprops.snapshots" "/props -> 404"; check $? "an unavailable /props is reported"
grep -qE "capacity:[[:space:]]+not measured" "$REPORT"; check $? "capacity reads as absent when /props is missing"
has "$REPORT" "neither snapshot carries a /props identity"; check $? "a window with no identity anywhere warns about it"

# identity on one side only: a reload inside the window would be invisible, so the diff is refused
python3 -c 'import os,sys; os.path.exists(sys.argv[1]+"/NOPROPS") and os.remove(sys.argv[1]+"/NOPROPS")' "$SERVE"
cp "$FX/instrumented/start/metrics.json" "$SERVE/metrics.json"
cp "$FX/instrumented/start/props.json" "$SERVE/props"
"$TOOL" --url "$U" --dir "$RUNS" start halfprops >/dev/null 2>&1
sleep 1
python3 -c 'import sys;open(sys.argv[1]+"/NOPROPS","w").close()' "$SERVE"
cp "$FX/instrumented/stop/metrics.json" "$SERVE/metrics.json"
"$TOOL" --url "$U" --dir "$RUNS" stop halfprops >/dev/null 2>&1
python3 -c 'import os,sys;os.remove(sys.argv[1]+"/NOPROPS")' "$SERVE"
"$TOOL" --dir "$RUNS" report halfprops >"$TMP/halfprops" 2>&1
[ $? = 2 ]; check $? "identity on one side only is refused"
has "$TMP/halfprops" "carries a /props identity and the other does not"; check $? "the one-sided identity refusal says why"
rm -rf "$RUNS/halfprops"

# a 200 whose body is not JSON (a proxy page, a truncated reply): the raw is kept, nothing is derived,
# and the absence is named as a broken body rather than as a build without the counters
printf '<html>502 from the proxy</html>' > "$SERVE/metrics.json"
cp "$FX/instrumented/start/props.json" "$SERVE/props"
"$TOOL" --url "$U" --dir "$RUNS" start junk >"$TMP/junk.start" 2>&1
[ $? = 0 ]; check $? "a snapshot survives a non-JSON metrics body"
has "$TMP/junk.start" "body is not JSON"; check $? "the broken body is named as the reason"
grep -qF "no per-kind SSD write counters" "$TMP/junk.start"; [ $? != 0 ]; check $? "a broken body is not blamed on the build"
has "$RUNS/junk/start/metrics.raw" "502 from the proxy"; check $? "the broken body is still kept verbatim"
rm -rf "$RUNS/junk"

# ---------------------------------------------------------------- 5. refused and warned comparisons

serve_case reset reset
[ "$RC" = 2 ]; check $? "a process counter going backwards is refused"
has "$REPORT" "went backwards"; check $? "the refusal names the reset"
jq -e '.status=="refused" and (.refusals|length>0)' "$RJSON" >/dev/null; check $? "the refusal is recorded in the JSON"

serve_case modelchange model
[ "$RC" = 2 ]; check $? "a model change inside the window is refused"
has "$REPORT" "served model changed"; check $? "the refusal says why"

serve_case boundschange bounds
[ "$RC" = 2 ]; check $? "a histogram whose bounds moved is refused"
has "$REPORT" "histogram bounds differ"; check $? "the refusal names the bounds"

serve_case tierreset tier
[ "$RC" = 0 ]; check $? "a per-tier reopen is not a process reset"
has "$REPORT" "cache tier reopened"; check $? "the reopened tier is called out as a warning"
grep -qE "tier \(props\): landed not measured" "$REPORT"; check $? "the reopened tier's own totals are excluded from the report"
jq -e '.serializations.landed==56 and (.bytes.total==61472768)' "$RJSON" >/dev/null
check $? "the process-wide deltas survive a tier reopen"

serve_case chunkchange chunk
[ "$RC" = 0 ]; check $? "a prefill-chunk change warns, it does not refuse"
has "$REPORT" "prefill_chunk changed inside the window"; check $? "the changed capture grid is named"
has "$REPORT" "chunk 8192"; check $? "both chunk sizes appear in the identity rows"

serve_case budgetchange budget
[ "$RC" = 0 ]; check $? "a changed cache budget warns, it does not refuse"
has "$REPORT" "cache budget is a setting"; check $? "the changed budget is named as a setting"
grep -qE "capacity:[[:space:]]+30 GiB" "$REPORT"; check $? "capacity shows the window's end"

serve_case instrumented gauge
[ "$RC" = 0 ]; check $? "gauges moving backwards does not refuse the window"
has "$REPORT" "a gauge, not a counter"; check $? "a backwards gauge is explained as not a reset"

# ---------------------------------------------------------------- 6. safety

"$TOOL" --dir "$RUNS" start full >"$TMP/dup" 2>&1
[ $? != 0 ]; check $? "a second start of one session is refused"
has "$TMP/dup" "nothing is overwritten"; check $? "the refusal says nothing is overwritten"
has "$RUNS/full/report.txt" "58.63 MiB"; check $? "the first session's report is untouched by the refused start"

"$TOOL" --dir "$RUNS" report nosuch >/dev/null 2>&1; [ $? != 0 ]; check $? "report without snapshots fails"
"$TOOL" --dir "$RUNS" stop fresh >/dev/null 2>&1; [ $? != 0 ]; check $? "stop without start fails"
[ ! -e "$RUNS/fresh" ]; check $? "a refused stop created no session directory"

SUSHI_PREFIX_CACHE_DIR="$CACHE" "$TOOL" --dir "$CACHE/reports" start inside >/dev/null 2>&1
[ $? != 0 ]; check $? "a report dir inside the SSD prefix cache root is refused"
[ -z "$(ls -A "$CACHE")" ]; check $? "nothing was created inside the cache root"

"$TOOL" --url "not-a-url" --dir "$RUNS" start badurl >/dev/null 2>&1; [ $? != 0 ]; check $? "a bad --url is rejected before any request"
[ ! -e "$RUNS/badurl" ]; check $? "a rejected launch created no session directory"
"$TOOL" --dir "$RUNS" start "bad name" >/dev/null 2>&1; [ $? != 0 ]; check $? "a session name with a space is rejected"

! (grep -v '^GET ' "$ACCESS" | grep -q .); check $? "every request the tool made was a GET"
grep -qE ' (POST|PUT|DELETE|PATCH) ' "$ACCESS"; [ $? != 0 ]; check $? "no write method was ever used"
grep -qE '^GET /(v1|metrics/enable|api)' "$ACCESS"; [ $? != 0 ]; check $? "the inference and control surface was never touched"
grep -qE '^GET /(metrics\.json|props) ' "$ACCESS"; check $? "the only reads are the metrics routes"
[ -f "$RUNS/full/start/metrics.raw" ] && [ -f "$RUNS/full/start/props.raw" ]; check $? "raw responses are preserved for later analysis"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
