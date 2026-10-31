#!/bin/bash
# measure-persistence.sh — read-only measurement of what the SSD prefix cache wrote in one window.
#
#   ./scripts/measure-persistence.sh [--url URL] [--dir DIR] start  SESSION
#   ./scripts/measure-persistence.sh [--url URL] [--dir DIR] stop   SESSION
#   ./scripts/measure-persistence.sh [--dir DIR] [--json]    report SESSION
#
# `start` and `stop` each take one snapshot (timestamp, raw /metrics.json, raw /props, the derived
# counters); `report` diffs the two and writes report.txt + report.json beside them.
#
# The script is an HTTP reader and nothing else: two GETs per snapshot, never a POST/PUT/DELETE, no
# inference request, no model load, no process control, no cache mutation, no polling loop, no
# background job, no GPU or MLX work. Its only writes are under --dir, which defaults beside the
# other run outputs (${SUSHI_RUNS_DIR:-$HOME/.sushi/runs}/persistence) and is refused outright if it
# sits inside the SSD prefix cache root (${SUSHI_PREFIX_CACHE_DIR:-$HOME/.sushi/kv-cache}).
#
# A metric that is absent, disabled (the /metrics routes answer 503 while metrics are off) or older
# than the instrumentation is reported as NOT MEASURED with a diagnostic. Absent is never printed as
# 0, and no percentile is ever interpolated past a histogram's own bounds.
#
# Exit status: 0 a usable report, 1 a window whose write counters were never measurable,
# 2 a refused comparison or a bad argument.
#
# Docs: docs/engine-persistence-measurements.md. Guard: tests/test_measure_persistence.sh.
# Written for bash 3.2 (the system /bin/bash on macOS) and jq 1.6+.

set -u
LC_ALL=C

PROG=$(basename "$0")
URL_DEFAULT='http://127.0.0.1:12345'
TIMEOUT_S=${SUSHI_MEASURE_TIMEOUT_S:-10}

die() { echo "$PROG: $*" >&2; exit 2; }
note() { echo "$PROG: $*" >&2; }

usage() {
    cat >&2 <<EOF
usage:
  $PROG [--url URL] [--dir DIR] start  SESSION    snapshot the server before the window
  $PROG [--url URL] [--dir DIR] stop   SESSION    snapshot the server after the window
  $PROG [--dir DIR] [--json]            report SESSION    diff the two and write the report

  --url URL   server to read (default $URL_DEFAULT)
  --dir DIR   report directory (default \${SUSHI_RUNS_DIR:-\$HOME/.sushi/runs}/persistence)
  --json      report: print the machine-readable diff instead of the table
  SUSHI_MEASURE_TIMEOUT_S   per-request curl timeout in seconds (default 10)
EOF
    exit 2
}

# ------------------------------------------------------------------ arguments

CMD=
SESSION=
URL=$URL_DEFAULT
OUT_DIR=${SUSHI_RUNS_DIR:-$HOME/.sushi/runs}/persistence
AS_JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --url) [ $# -ge 2 ] || die "--url needs a value"; URL="${2%/}"; shift ;;
        --url=*) URL="${1#--url=}"; URL="${URL%/}" ;;
        --dir) [ $# -ge 2 ] || die "--dir needs a value"; OUT_DIR="$2"; shift ;;
        --dir=*) OUT_DIR="${1#--dir=}" ;;
        --json) AS_JSON=1 ;;
        -h | --help) usage ;;
        start | stop | report)
            [ -z "$CMD" ] || die "two subcommands given ($CMD, $1)"
            if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then die "$1 needs a SESSION name"; fi
            CMD=$1
            SESSION=$2
            shift
            ;;
        *) die "unknown argument '$1'" ;;
    esac
    shift
done

[ -n "$CMD" ] || usage
case "$SESSION" in
    *[!A-Za-z0-9._-]* | '') die "session name '$SESSION' takes letters, digits, dot, dash and underscore only" ;;
esac
case "$URL" in
    http://* | https://*) ;;
    *) die "--url must be an http:// or https:// address, got '$URL'" ;;
esac
for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required and not on PATH"
done

# ------------------------------------------------------------------ report dir placement

# Absolute, with every existing component resolved, so a symlinked cache root still compares.
absnorm() {
    local path=$1 rest= probe= cur=
    case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
    probe=$path
    while [ ! -d "$probe" ]; do
        cur=$(basename "$probe")
        rest="$cur/${rest}"
        probe=$(dirname "$probe")
        [ "$probe" != "/" ] || break
    done
    if [ -d "$probe" ]; then
        cur=$(cd "$probe" 2>/dev/null && pwd -P) || die "cannot resolve $path"
        printf '%s\n' "$cur/${rest}" | sed 's://*:/:g'
    else
        printf '%s\n' "$path" | sed 's://*:/:g'
    fi
}

OUT_DIR=$(absnorm "$OUT_DIR")
OUT_DIR="${OUT_DIR%/}"
[ -n "$OUT_DIR" ] || OUT_DIR=/
CACHE_ROOT=$(absnorm "${SUSHI_PREFIX_CACHE_DIR:-$HOME/.sushi/kv-cache}")
CACHE_ROOT="${CACHE_ROOT%/}"
inside() { case "$1" in "$2" | "$2"/*) return 0 ;; *) return 1 ;; esac; }
if [ "$CMD" != report ] && inside "$OUT_DIR" "$CACHE_ROOT"; then
    die "report dir $OUT_DIR sits inside the SSD prefix cache root $CACHE_ROOT: a measurement must never land in the cache it measures"
fi

SESSION_DIR="$OUT_DIR/$SESSION"

# ------------------------------------------------------------------ snapshot

# fetch URL OUTFILE ERRFILE -> prints the HTTP status code, 000 when the request itself failed.
fetch() {
    local code
    code=$(curl -sS --get --max-time "$TIMEOUT_S" -H 'Accept: application/json' \
        -o "$2" -w '%{http_code}' "$1" 2>"$3") || code=000
    printf '%s' "${code:-000}"
}

snapshot() { # $1 = start | stop
    local label=$1 snap code pcode err mjson pjson ts iso
    if [ "$CMD" = start ]; then
        if [ -e "$SESSION_DIR/start/snapshot.json" ]; then
            die "session '$SESSION' already has a start snapshot: nothing is overwritten, pick a new session name"
        fi
    else
        [ -f "$SESSION_DIR/start/snapshot.json" ] || die "session '$SESSION' has no start snapshot under $SESSION_DIR: run '$PROG start $SESSION' first"
        if [ -e "$SESSION_DIR/stop/snapshot.json" ]; then
            die "session '$SESSION' already has a stop snapshot: pick a new session name"
        fi
    fi

    # mkdir without -p on the label dir, so two starts of one name cannot both proceed.
    mkdir -p "$SESSION_DIR" || die "cannot create $SESSION_DIR"
    if ! mkdir "$SESSION_DIR/$label" 2>/dev/null; then
        die "$SESSION_DIR/$label already exists: refusing to reuse a snapshot directory"
    fi
    snap="$SESSION_DIR/$label"

    code=$(fetch "$URL/metrics.json" "$snap/metrics.raw" "$snap/metrics.err")
    pcode=$(fetch "$URL/props" "$snap/props.raw" "$snap/props.err")
    printf '%s\n' "$code" >"$snap/metrics.status"
    printf '%s\n' "$pcode" >"$snap/props.status"
    err=""
    if [ "$code" = 000 ] && [ -s "$snap/metrics.err" ]; then err=$(tr '\n' ' ' <"$snap/metrics.err"); fi
    if [ -z "$err" ] && [ "$pcode" = 000 ] && [ -s "$snap/props.err" ]; then err=$(tr '\n' ' ' <"$snap/props.err"); fi
    if [ "$code" != 200 ] && [ "$pcode" != 200 ]; then
        rm -rf "$snap"
        rmdir "$SESSION_DIR" 2>/dev/null
        die "neither $URL/metrics.json ($code) nor $URL/props ($pcode) answered: nothing was captured, and $SESSION/$label is not left behind"
    fi

    # a 200 whose body is not JSON (a proxy page, a truncated reply) yields nothing: the raw stays,
    # and the snapshot records WHY it is empty rather than reading the absence as a zero
    printf '{}\n' >"$snap/absent.json"
    mjson="$snap/absent.json"; mbad=0
    pjson="$snap/absent.json"; pbad=0
    if [ "$code" = 200 ]; then
        if jq -e . "$snap/metrics.raw" >/dev/null 2>&1; then mjson="$snap/metrics.raw"; else mbad=1; fi
    fi
    if [ "$pcode" = 200 ]; then
        if jq -e . "$snap/props.raw" >/dev/null 2>&1; then pjson="$snap/props.raw"; else pbad=1; fi
    fi

    ts=$(date -u +%s)
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n --arg label "$label" --arg url "$URL" --arg iso "$iso" --argjson ts "$ts" \
        --arg ms "$code" --arg ps "$pcode" --arg err "$err" --arg mbad "$mbad" --arg pbad "$pbad" \
        --slurpfile m "$mjson" --slurpfile p "$pjson" \
        "$EXTRACT_PROG" >"$snap/snapshot.json" 2>"$snap/derive.err" \
        || die "could not derive the $label snapshot (see $snap/derive.err)"
    rm -f "$snap/derive.err" "$snap/metrics.err" "$snap/props.err" "$snap/absent.json" "$snap/absent.json"

    note "$label snapshot of $URL -> $snap/snapshot.json"
    jq -r '.diagnostics[] | "  note: " + .' "$snap/snapshot.json" >&2
}

# One snapshot's derived view: every counter the report can diff, under ONE flat map `n` whose keys
# name their source, plus the histogram arrays and the identity the diff needs. `flat` copies only
# numeric leaves, so a metric this build does not serve simply has no key — there is nothing that
# could be read as a zero. `durable_keys` is where a future durable-token counter would appear.
extract_prog() {
cat <<'JQ'
def num($v): ($v|type)=="number";
def obj: if type=="object" then . else {} end;
def flat($p): . as $o | reduce ($o|keys[]) as $k ({}; if num($o[$k]) then . + {($p + $k): $o[$k]} else . end);
($m[0] | obj) as $mm
| ($p[0] | obj) as $pp
| ($mm.prefix_cache_writes | obj) as $pw
| ($pw.serialization | obj) as $ser
| ($mm.counters | obj) as $ctr
| ($pp.settings | obj) as $st
| ($st.prefix_cache | obj) as $pc
| ({}
   | . + ($ctr | flat("counters."))
   | . + ($mm.gauges | obj | flat("gauges."))
   | . + ($pw.written_bytes | obj | flat("ssd_written_bytes."))
   | . + (if num($pw.failed_bytes) then {ssd_failed_bytes: $pw.failed_bytes} else {} end)
   | . + ($ser | flat("serialization."))
   | . + ($pc | flat("props_prefix_cache."))) as $n
| ([ $n | keys[] | select(test("(durable|restorable)_tokens_total$")) ] | sort) as $durable
| ([
    (if ($ms == "200") and ($mbad == "1") then "GET \($url)/metrics.json -> 200 but the body is not JSON (a proxy page, a truncated reply): it is kept verbatim at metrics.raw and nothing was derived from it."
     elif $ms == "200" then empty
     elif $ms == "503" then "GET \($url)/metrics.json -> 503: metrics are off on this server (a boot with --metrics turns them on). The process-wide SSD write counters are served only on this route, so write bytes are not measurable here."
     elif $ms == "000" then "GET \($url)/metrics.json got no answer\(if $err == "" then "." else ": \($err)" end)"
     else "GET \($url)/metrics.json -> \($ms): no usable JSON body." end),
    (if ($ms == "200") and ($mbad == "0") and (($pw | length) == 0) then "/metrics.json has no prefix_cache_writes object: this build carries no per-kind SSD write counters, so write volume stays unmeasured rather than 0." else empty end),
    (if ($ms == "200") and ($mbad == "0") and (($pw | length) > 0) and (($ser | length) == 0) then "/metrics.json has prefix_cache_writes but no serialization object: logical append counts and their size histogram are absent in this build." else empty end),
    (if ($ms == "200") and ($mbad == "0") and (num($ctr.prefill_tokens_total) | not) then "counters.prefill_tokens_total is absent: tokens actually forwarded through prefill cannot be counted." else empty end),
    (if ($ms == "200") and ($mbad == "0") and (num($ctr.generation_tokens_total) | not) then "counters.generation_tokens_total is absent: generated tokens cannot be counted." else empty end),
    (if ($ps == "200") and ($pbad == "1") then "GET \($url)/props -> 200 but the body is not JSON: it is kept verbatim at props.raw and nothing was derived from it, so a reload inside the window would be invisible."
     elif $ps == "000" then "GET \($url)/props got no answer: cache capacity, per-tier totals and model/build identity are not captured, so report cannot detect a reload inside the window."
     elif ($ps == "200") and (($pc | length) == 0) then "/props answered but carries no settings.prefix_cache: no model is loaded in this snapshot, or the build predates the per-tier cache totals."
     elif $ps == "200" then empty
     else "GET \($url)/props -> \($ps): cache capacity, per-tier totals and model/build identity are not captured." end),
    (if ($durable | length) == 0 then "No durable/restorable token counter (a counter named *durable_tokens_total or *restorable_tokens_total) exists here: bytes per newly durable token and write amplification cannot be computed." else "Durable-token counter present: \($durable | join(", "))." end),
    (if (num($n["counters.persistence_duration_seconds"]) | not) and (num($n["gauges.persistence_last_token_interval"]) | not) then "Persistence duration and effective token-interval metrics are not implemented in this build: section 8 is skipped, never zeroed." else empty end)
  ]) as $diag
| { label: $label, url: $url, ts: $ts, iso: $iso,
    http: { metrics: $ms, props: $ps },
    identity: {
      model: ($pp.default_generation_settings.model // null),
      version: ($st.version // null),
      engine: ($st.engine // null),
      kv_cache_scheme: (($st.kv_cache | obj).scheme // null),
      kv_quant: ($st.kv_quant // null),
      arch: ($st.model // null),
      prefill_chunk: ($st.prefill_chunk // null)
    },
    durable_keys: $durable,
    bounds: (if (($ser.byte_bounds | type) == "array") then $ser.byte_bounds else [] end),
    buckets: (if (($ser.byte_buckets | type) == "array") then $ser.byte_buckets else [] end),
    n: $n,
    diagnostics: $diag }
JQ
}
EXTRACT_PROG=$(extract_prog)

# The diff. Percentiles come from bucket DELTAS: subtracting two snapshots' percentiles is
# meaningless, so they are never even computed.
report_prog() {
cat <<'JQ'
def num($v): ($v|type)=="number";
def r2($v): (($v * 100) | round) / 100;
def s2($v): if num($v) then (r2($v) | tostring) else $NA end;
def si($v): if num($v) then (($v | floor) | tostring) else $NA end;
def hum($v): if num($v) then
      (if $v >= 1073741824 then (s2($v / 1073741824) + " GiB")
       elif $v >= 1048576 then (s2($v / 1048576) + " MiB")
       elif $v >= 1024 then (s2($v / 1024) + " KiB")
       else (($v | floor) | tostring) + " B" end)
    else $NA end;
def humb($v): if num($v) then (hum($v) + " (" + ($v | floor | tostring) + " B)") else $NA end;
def pad($str; $n): if (($str | length) >= $n) then $str else pad($str + " "; $n) end;
def kinds: ["kv", "ssm", "qsa", "spec", "ring", "meta"];
def ident($i): if $i == null then $NA else (($i.model // $NA) | tostring) + "  arch " + (($i.arch // $NA) | tostring) + "  build " + (($i.version // $NA) | tostring) + "  engine " + (($i.engine // $NA) | tostring) + "  kv " + (($i.kv_cache_scheme // $NA) | tostring) + "/" + (($i.kv_quant // $NA) | tostring) + "  chunk " + (($i.prefill_chunk // $NA) | tostring) end;

($s[0]) as $a | ($b[0]) as $b0
| def dd($k): if (num($a.n[$k]) and num($b0.n[$k])) then {k: $k, from: $a.n[$k], to: $b0.n[$k], delta: ($b0.n[$k] - $a.n[$k])} else null end;
  def delta($k): (dd($k)) as $r | if $r == null then null else $r.delta end;
  def is_process($k): ($k | startswith("counters.")) or ($k | startswith("ssd_written_bytes.")) or ($k | startswith("serialization.")) or ($k == "ssd_failed_bytes");
  # a props_prefix_cache total that can only go up for this model's tier, so a decrease is the tier
  # reopening; used bytes, entry count, staging and the budgets are gauges or settings, not totals
  def is_tier($k): ($k | startswith("props_prefix_cache."))
      and (($k | test("disk_used_bytes|disk_entries|writer_staged|disk_bytes$|mem_bytes$")) | not);
  def is_budget($k): ($k == "props_prefix_cache.disk_bytes") or ($k == "props_prefix_cache.mem_bytes");
  def pidx($cum; $bounds; $p): if ($cum == null) or (($cum | last) <= 0) then null
      else ([ range(0; $cum | length) | select($cum[.] >= ($p * ($cum | last))) ] | (if length > 0 then .[0] else null end)) end;
  def plabel($cum; $bounds; $p): pidx($cum; $bounds; $p) as $i
      | if $i == null then $NA + " (no landed append in this window, or no histogram in this build)"
        elif $i < ($bounds | length) then ("<= " + hum($bounds[$i]) + " (bucket upper bound; the histogram has no finer resolution)")
        else ("> " + hum($bounds[($bounds | length) - 1]) + " (open-ended top bucket: only a lower bound is known)") end;
  # every decreasing key, split by what a decrease can mean
  ([ $a.n | keys[] as $k | select(num($b0.n[$k])) | select($b0.n[$k] < $a.n[$k]) | {k:$k, from:$a.n[$k], to:$b0.n[$k]} ]) as $neg
  | ([ $neg[] | select(is_process(.k)) ]) as $resets
  | ([ $neg[] | select(is_tier(.k)) | .k ]) as $tier_bad
  | ([ $neg[] | select(is_budget(.k)) ]) as $budgets_back
  | ([ $neg[] | select((is_process(.k) | not) and (is_tier(.k) | not) and (is_budget(.k) | not)) ]) as $gauges_back
  | ([ $a.n | keys[] | select(is_process(.) and (num($b0.n[.]) | not)) ]) as $gone
  | ([ $b0.n | keys[] | select(is_process(.) and (num($a.n[.]) | not)) ]) as $came
  | (if (num($a.n["serialization.bytes"]) and num($b0.n["serialization.bytes"])) and (($b0.n["serialization.bytes"] - $a.n["serialization.bytes"]) >= 0) then ($b0.n["serialization.bytes"] - $a.n["serialization.bytes"]) else null end) as $ser_bytes
  | ([ $a.durable_keys[] | select(num($b0.n[.])) ]) as $durable_both
  | ($b0.ts - $a.ts) as $dur
  | ([ (if $a.url != $b0.url then "the two snapshots were taken from different addresses (\($a.url) then \($b0.url)): those are two servers' counters, not one window" else empty end),
       (if ($a.identity != null) and ($b0.identity != null) and (($a.identity.model != null) and ($b0.identity.model != null)) and ($a.identity.model != $b0.identity.model) then "the served model changed inside the window (\($a.identity.model) -> \($b0.identity.model)): a reload resets every cache tier" else empty end),
       (if ($a.identity != null) and ($b0.identity != null) and (($a.identity.version != null) and ($b0.identity.version != null)) and ($a.identity.version != $b0.identity.version) then "the server build changed inside the window (\($a.identity.version) -> \($b0.identity.version)): the counters are not comparable" else empty end),
       (if ($a.identity != null) and ($b0.identity != null) and (($a.identity.kv_cache_scheme != null) and ($b0.identity.kv_cache_scheme != null)) and ($a.identity.kv_cache_scheme != $b0.identity.kv_cache_scheme) then "the KV scheme changed inside the window (\($a.identity.kv_cache_scheme) -> \($b0.identity.kv_cache_scheme)): bytes per token is a different quantity on each side" else empty end),
       (if ($a.identity != null) and ($b0.identity != null) and (($a.identity.arch != null) and ($b0.identity.arch != null)) and ($a.identity.arch != $b0.identity.arch) then "the served architecture changed inside the window (\($a.identity.arch) -> \($b0.identity.arch)): the caches and the write shapes are different" else empty end),
       (if ($resets | length) > 0 then "a process counter went backwards, so the server restarted or reset inside the window: " + ($resets | map("\(.k) \(.from) -> \(.to)") | join("; ")) else empty end),
       (if $dur < 0 then "the stop snapshot (\($b0.iso)) precedes the start snapshot (\($a.iso)): the clock moved during the window" else empty end),
       (if (($a.buckets | length) > 0) and (($b0.buckets | length) > 0) and (($a.bounds != $b0.bounds) or (($a.buckets | length) != ($b0.buckets | length))) then "the serialization histogram bounds differ between the snapshots (\($a.buckets | length) vs \($b0.buckets | length) buckets): their buckets are not the same buckets" else empty end),
       (if (($a.identity.model != null) or ($a.identity.version != null)) != (($b0.identity.model != null) or ($b0.identity.version != null))
        then "one snapshot carries a /props identity and the other does not: a model change or reload inside the window would be invisible, so the comparison is refused" else empty end)
     ]) as $refusals
  # ---- bytes by kind, over the kinds both snapshots report
  | ([ kinds[] | select((num($a.n["ssd_written_bytes." + .])) and (num($b0.n["ssd_written_bytes." + .]))) ]) as $kk
  | ([ $kk[] | { kind: ., bytes: delta("ssd_written_bytes." + .) } ]) as $by_kind
  | (if ($by_kind | length) == 0 then null else ([ $by_kind[].bytes ] | add) end) as $total
  | ([ kinds[] | select((num($a.n["ssd_written_bytes." + .]) or num($b0.n["ssd_written_bytes." + .])) and (($kk | index(.)) == null)) ]) as $kind_gaps
  | (if num($a.n["ssd_failed_bytes"]) and num($b0.n["ssd_failed_bytes"]) then (delta("ssd_failed_bytes")) else null end) as $failed
  # ---- tokens
  | delta("counters.prefill_tokens_total") as $prefill
  | delta("counters.generation_tokens_total") as $generated
  | (if ($prefill != null) and ($generated != null) then ($prefill + $generated) else null end) as $processed
  | delta("counters.prompt_tokens_total") as $prompt
  | delta("counters.prefix_cache_tokens_total") as $restored
  | (if ($durable_both | length) > 0 then $durable_both[0] else null end) as $dkey
  | (if $dkey == null then null else delta($dkey) end) as $durable
  # ---- logical serializations
  | { landed: delta("serialization.landed"), noop: delta("serialization.noop"), partial: delta("serialization.partial"),
      failed: delta("serialization.failed"), untracked: delta("serialization.untracked"), bytes: $ser_bytes } as $ser
  | (if ($tier_bad | index("props_prefix_cache.serialization_landed")) then null else delta("props_prefix_cache.serialization_landed") end) as $tier_landed
  | (if ($tier_bad | index("props_prefix_cache.serialization_bytes")) then null else delta("props_prefix_cache.serialization_bytes") end) as $tier_bytes
  | (if ($tier_bad | index("props_prefix_cache.disk_written_bytes")) then null else delta("props_prefix_cache.disk_written_bytes") end) as $tier_written
  # ---- landed-append size histogram, from bucket deltas
  | (if (($a.buckets | length) > 0) and (($a.buckets | length) == ($b0.buckets | length)) and ($a.bounds == $b0.bounds)
     then [ range(0; $b0.buckets | length) as $i | ($b0.buckets[$i] - $a.buckets[$i]) ] else null end) as $h0
  | (if $h0 == null then null elif ([ $h0[] | select(. < 0) ] | length) > 0 then null else $h0 end) as $hist
  | (if $hist == null then null else ([ $hist[] ] | add) end) as $hn
  | (if $hist == null then null else [ range(0; $hist | length) as $i | ($hist[0 : $i + 1] | add) ] end) as $cum
  | $b0.bounds as $bounds
  | (if ($ser.bytes != null) and ($hn != null) and ($hn > 0) then ($ser.bytes / $hn) else null end) as $mean
  # ---- rows that wait on instrumentation the served build does not have
  | delta("counters.persistence_duration_seconds") as $persist_s
  | (if (num($a.n["gauges.persistence_last_token_interval"]) and num($b0.n["gauges.persistence_last_token_interval"])) then {from:$a.n["gauges.persistence_last_token_interval"], to:$b0.n["gauges.persistence_last_token_interval"]} else null end) as $interval
  # ---- write amplification needs a VERIFIED durable-token counter, never activity as a proxy
  | (if ($dkey != null) and ($durable != null) and ($durable > 0) and ($total != null) then ($total / $durable) else null end) as $amp
  | ([ (if (($a.identity.model == null) and ($a.identity.version == null)) and (($b0.identity.model == null) and ($b0.identity.version == null))
        then "neither snapshot carries a /props identity (no model loaded, or a metrics-only /props): a model change or reload inside the window cannot be seen here, only a counter reset can" else empty end) ]) as $idgap
  | ([ $idgap[],
     (if ($tier_bad | length) > 0 then "this model's cache tier reopened inside the window, so its per-tier totals are excluded: "
        + ($tier_bad | map(ltrimstr("props_prefix_cache.") + " " + ($a.n[.] | tostring) + " -> " + ($b0.n[.] | tostring)) | join(", ")) else empty end),
       ($gauges_back[] | "\(.k) went backwards (\(.from) -> \(.to)): a gauge, not a counter, so this is not a reset"),
       ($budgets_back[] | "\(.k) changed (\(.from) -> \(.to)): the cache budget is a setting, so the two halves of this window ran under different sizes"),
       (if ($a.identity != null) and ($b0.identity != null) and (($a.identity.prefill_chunk // null) != ($b0.identity.prefill_chunk // null)) then "prefill_chunk changed inside the window (\($a.identity.prefill_chunk) -> \($b0.identity.prefill_chunk)): the capture grid, so the checkpoint cadence, differs between the two halves" else empty end),
       ($gone[] | "\(.) is present at start but not at stop: metrics were disabled, or the server changed underneath the window"),
       ($came[] | "\(.) is present at stop but not at start: metrics were enabled mid-window, so its delta does not cover the whole window")
     ]) as $warnings
  | (if ($refusals | length) > 0 then "refused"
     elif ($total == null) and ($dkey == null) then "incomplete"
     else "ok" end) as $status
  | ($a.diagnostics + $b0.diagnostics + $warnings) as $notes
  | ([ "1. Window",
       "   start:    \($a.iso)  from \($a.url)  (GET /metrics.json \($a.http.metrics), GET /props \($a.http.props))",
       "   stop:     \($b0.iso)  from \($b0.url)  (GET /metrics.json \($b0.http.metrics), GET /props \($b0.http.props))",
       "   duration: " + (if $dur >= 0 then (s2($dur / 60) + " min (" + ($dur | tostring) + " s)") else $NA end),
       "   identity: model " + ident($a.identity),
       "      ->     model " + ident($b0.identity),
       "   capacity: " + humb($b0.n["props_prefix_cache.disk_bytes"]) + " SSD budget, " + humb($b0.n["props_prefix_cache.disk_used_bytes"]) + " used, " + si($b0.n["props_prefix_cache.disk_entries"]) + " entries",
       "",
       "2. SSD bytes written by the prefix cache",
       "   total:    " + (if $total == null then $NA + " (no per-kind write counter in this build)" else (hum($total) + " (" + ($total | floor | tostring) + " bytes)") end),
       "   rate:     " + (if ($total != null) and ($dur > 0) then (s2($total / 1000000 / ($dur / 60)) + " MB/min (" + s2($total / 1048576 / ($dur / 60)) + " MiB/min)") else $NA + " (the window is under a second, or no write counter)" end),
       "   failed:   " + (if $failed == null then $NA + " (no failed-write counter)" else (hum($failed) + " handed to a write that failed or was dropped") end),
       "",
       "3. Bytes written by file kind"
     ]
     + (if ($by_kind | length) == 0 then [ "   " + $NA + " (no per-kind write counter)" ]
        else ([ $by_kind[] | (if ($total != null) and ($total > 0) then (s2(.bytes * 100 / $total) + "%") else "n/a" end) as $pct
                 | "   " + pad(.kind; 6) + "  " + pad($pct; 8) + hum(.bytes) ])
             + ([ "   " + pad("total"; 6) + "  " + pad("100%"; 8) + humb($total) ])
             + (if ($kind_gaps | length) > 0 then [ "   kinds reported on one side only: " + ($kind_gaps | join(", ")) ] else [] end) end)
     + [ "",
         "4. Work in the window",
         "   prefill tokens forwarded:       " + si($prefill),
         "   generated tokens:               " + si($generated),
         "   newly processed tokens:         " + si($processed) + "   (forwarded prefill + generated: the token was computed here)",
         "   prompt tokens (incl. restored): " + si($prompt),
         "   tokens restored from cache:     " + si($restored),
         "   requests completed:             " + si(delta("counters.requests_success_total")),
         "   requests failed / rejected:     " + si(delta("counters.requests_failed_total")) + " / " + si(delta("counters.requests_rejected_total")),
         "",
         "5. Bytes per token",
         "   per newly PROCESSED token: " + (if ($total != null) and ($processed != null) and ($processed > 0) then (s2($total / $processed) + " B/token") else $NA end)
           + "   (every landed byte, including state no restore will ever use)",
         "   per newly DURABLE token:   " + (if $dkey == null then "unavailable: this build has no verified durable-token metric"
             elif ($durable != null) and ($durable > 0) and ($total != null) then (s2($total / $durable) + " B/token")
             else $NA + " (the durable counter did not move, or write bytes are unavailable)" end),
         "",
         "6. Logical serializations (append operations)",
         "   landed:     " + si($ser.landed) + "   (filesystem completion, not proof of hybrid restorability)",
         "   no-op:      " + si($ser.noop),
         "   partial:    " + si($ser.partial),
         "   failed:     " + si($ser.failed),
         "   untracked:  " + si($ser.untracked) + (if ($ser.untracked != null) and ($ser.untracked > 0) then "   (the receipt pool was full: these bytes stay in the totals but miss the histogram)" else "" end),
         "   landed bytes: " + hum($ser.bytes),
         "   this model's tier (props): landed " + si($tier_landed) + ", bytes " + hum($tier_bytes) + ", written since load " + hum($tier_written),
         "",
         "7. Landed append size (bucket DELTAS; a delta of two percentiles would be meaningless)",
         "   appends measured: " + si($hn) + (if ($h0 != null) and ($hist == null) then "  (a bucket count went backwards: not diffable)" else "" end),
         "   mean:     " + (if $mean != null then (hum($mean) + " (" + ($ser.bytes | floor | tostring) + " B / " + ($hn | tostring) + ")") else $NA end),
         "   P50:      " + plabel($cum;$bounds;0.5),
         "   P95:      " + plabel($cum;$bounds;0.95)
       ]
     + (if $hist != null then [ "   bucket deltas (bounds " + ($bounds | map(tostring) | join(" ")) + " B): " + ($hist | map(tostring) | join(" ")) ]
        else [ "   bucket deltas: " + $NA + " (these snapshots carry no diffable histogram)" ] end)
     + [ "",
         "8. Persistence duration and effective token intervals",
         "   time spent persisting:  " + (if $persist_s != null then (s2($persist_s) + " s") else "unavailable: not implemented in this build" end),
         "   effective token interval: " + (if $interval != null then (si($interval.from) + " -> " + si($interval.to) + " tokens") else "unavailable: not implemented in this build" end),
         "",
         "9. Write amplification (bytes per newly restorable token)"
       ]
     + (if $amp != null then [ "   " + s2($amp) + " B/token over " + si($durable) + " newly durable tokens (source: " + $dkey + ")",
         "   filesystem bytes, not NAND wear, and a landed append does not certify hybrid restoration" ]
        else [ "   not reported: needs a verified durable-token metric (looked for a counter named *durable_tokens_total or *restorable_tokens_total; neither snapshot has one)" ] end)
     + [ "", "Diagnostics and capture notes:" ]
     + ([ (($notes | map(select((. != null) and (. != "")))) | unique)[] | "   - " + . ]
        | (if length == 0 then ["   - none"] else . end))
   ) as $lines
| { session: $session, status: $status,
    window: { start_iso: $a.iso, stop_iso: $b0.iso, seconds: $dur,
              start_http: $a.http, stop_http: $b0.http, start_url: $a.url, stop_url: $b0.url },
    identity: { start: $a.identity, stop: $b0.identity },
    capacity: { disk_bytes: $b0.n["props_prefix_cache.disk_bytes"], disk_used_bytes: $b0.n["props_prefix_cache.disk_used_bytes"],
                disk_entries: $b0.n["props_prefix_cache.disk_entries"] },
    bytes: { total: $total, by_kind: $by_kind, failed: $failed,
             mb_per_min: (if ($total != null) and ($dur > 0) then r2($total / 1000000 / ($dur / 60)) else null end),
             mib_per_min: (if ($total != null) and ($dur > 0) then r2($total / 1048576 / ($dur / 60)) else null end) },
    tokens: { prefill: $prefill, generated: $generated, processed: $processed, prompt: $prompt, restored: $restored,
              requests_success: delta("counters.requests_success_total"), requests_failed: delta("counters.requests_failed_total"),
              requests_rejected: delta("counters.requests_rejected_total"), durable_key: $dkey, durable: $durable },
    per_token: { processed: (if ($total != null) and ($processed != null) and ($processed > 0) then r2($total / $processed) else null end),
                 durable: (if $amp != null then r2($amp) else null end) },
    serializations: ($ser + { tier_landed: $tier_landed, tier_bytes: $tier_bytes, tier_written: $tier_written }),
    histogram: { bounds: $bounds, bucket_deltas: $hist, n: $hn, mean_bytes: $mean,
                 p50: plabel($cum;$bounds;0.5), p95: plabel($cum;$bounds;0.95),
                 p50_bucket: (if (pidx($cum;$bounds;0.5) == null) then null else ($bounds[pidx($cum;$bounds;0.5)] // "open") end),
                 p95_bucket: (if (pidx($cum;$bounds;0.95) == null) then null else ($bounds[pidx($cum;$bounds;0.95)] // "open") end) },
    persistence: { duration_seconds: $persist_s, token_interval: $interval },
    write_amplification: (if $amp != null then r2($amp) else null end),
    refusals: $refusals, warnings: $warnings, diagnostics: $notes, lines: $lines }
JQ
}
REPORT_PROG=$(report_prog)

case "$CMD" in
    start) snapshot start ;;
    stop) snapshot stop ;;
    report)
        SA="$SESSION_DIR/start/snapshot.json"
        SB="$SESSION_DIR/stop/snapshot.json"
        [ -f "$SA" ] || die "session '$SESSION' has no start snapshot at $SA"
        [ -f "$SB" ] || die "session '$SESSION' has no stop snapshot at $SB: run '$PROG stop $SESSION'"
        jq -n --arg session "$SESSION" --arg NA "not measured" \
            --slurpfile s "$SA" --slurpfile b "$SB" "$REPORT_PROG" >"$SESSION_DIR/report.json.tmp" 2>"$SESSION_DIR/report.err" \
            || { rm -f "$SESSION_DIR/report.json.tmp"; die "could not build the report (see $SESSION_DIR/report.err)"; }
        mv "$SESSION_DIR/report.json.tmp" "$SESSION_DIR/report.json"
        rm -f "$SESSION_DIR/report.err"
        STATUS=$(jq -r '.status' "$SESSION_DIR/report.json")

        if [ "$STATUS" = refused ]; then
            {
                echo "Persistence measurement — session $SESSION: REFUSED, the two snapshots are not comparable."
                jq -r '.refusals[] | "  - " + .' "$SESSION_DIR/report.json"
                echo "  (the raw snapshots stay at $SESSION_DIR/{start,stop}; nothing was averaged or extrapolated)"
            } >"$SESSION_DIR/report.txt"
            cat "$SESSION_DIR/report.txt" >&2
            exit 2
        fi

        {
            echo "Persistence measurement — session $SESSION (two read-only HTTP snapshots)"
            echo "  'not measured' means the metric is absent, disabled or not served by this build: it is"
            echo "  never printed as a zero, and a window whose counters moved backwards is refused outright."
            jq -r '.lines[]' "$SESSION_DIR/report.json"
            echo "  report json: $SESSION_DIR/report.json"
        } >"$SESSION_DIR/report.txt"
        if [ "$AS_JSON" = 1 ]; then jq 'del(.lines)' "$SESSION_DIR/report.json"; else cat "$SESSION_DIR/report.txt"; fi
        if [ "$STATUS" = incomplete ]; then
            note "incomplete: neither snapshot carried a per-kind SSD write counter, so no write-volume conclusion can be drawn"
            exit 1
        fi
        ;;
esac
