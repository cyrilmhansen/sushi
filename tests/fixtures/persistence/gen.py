#!/usr/bin/env python3
"""Synthetic /metrics.json and /props bodies for tests/measure-persistence.sh.

Every number here is invented for the test: it is not a measurement of anything. One case dir holds
`start/{metrics.json,props.json}` and `stop/{metrics.json,props.json}`, and the test serves one pair
at a time, so each case is exactly two snapshots of one address.

  instrumented   the shape the append instrumentation serves: per-kind bytes, serialization counts
                 and a non-cumulative size histogram.
  legacy         the shape an older production build serves: no prefix_cache_writes, no serialization
                 fields in /props, and /metrics.json answers 503 (metrics off).
  durable        instrumented plus the durable-token counter the write-amplification row waits for.
"""
import json
import os
import sys

BOUNDS = [4096, 65536, 1048576, 4194304, 16777216, 67108864, 268435456, 1073741824, 2147483648, 4294967296]
DBOUNDS = [10, 100, 1000, 10000, 100000, 1000000, 10000000, 60000000, 600000000]


def durations(inference, inf_sum, wait, wait_sum, writer, wr_sum, e2e, e2e_sum):
    """The four landed-append timing histograms, one dict per stage (non-cumulative buckets)."""
    return {"bounds_us": DBOUNDS,
            "inference": {"buckets": inference, "sum_ns": inf_sum},
            "wait": {"buckets": wait, "sum_ns": wait_sum},
            "writer": {"buckets": writer, "sum_ns": wr_sum},
            "e2e": {"buckets": e2e, "sum_ns": e2e_sum}}


def metrics(counters, writes, gauges=None):
    body = {
        "counters": counters,
        "gauges": gauges if gauges is not None else {"requests_running": 0, "memory_mb": 40000},
        "decode_serial": {"mtp_off": 1},
        "histograms": {"time_to_first_token_seconds": {"count": 1, "sum": 0.2, "bounds": [0.1], "bucket_counts": [1]}},
        "sessions": [],
    }
    if writes is not None:
        body["prefix_cache_writes"] = writes
    return body


def props(model="qwen4_exp", version="1.5.0", scheme="affine8", prefix_cache=None, durable_tier=None,
          name="sushi-qwen4", prefill_chunk=8192):
    pc = {"ram_enabled": True, "mem_bytes": 8000000000, "disk_bytes": 64424509440,
          "disk_used_bytes": 10000000, "disk_entries": 9}
    if prefix_cache is not None:
        pc.update(prefix_cache)
    if durable_tier is not None:
        pc.update(durable_tier)
    return {
        # /props reports the served NAME here and the architecture in settings.model
        "default_generation_settings": {"model": name, "n_ctx": "131072"},
        "total_slots": 1,
        "memory": {"active_bytes": 40000000000, "peak_bytes": 41000000000, "available_bytes": 60000000000,
                   "max_safe_context": 131072, "cache_bytes": 1000000000, "kv_cache_bytes": 2000000000,
                   "owned_bytes": 42000000000},
        "batching": {"supported": True, "reason": "ok", "max_group": 4},
        "settings": {"version": version, "model": model, "engine": "exl3", "kv_quant": "8",
                     "kv_cache": {"scheme": scheme, "source": "default"}, "prefill_chunk": prefill_chunk,
                     "mtp": {"loaded": True, "default_on": True, "depth": 3}, "drafter": "none",
                     "max_concurrent": 4, "prefix_cache": pc},
    }


def write(root, case, label, body, pbody):
    d = os.path.join(root, case, label)
    os.makedirs(d, exist_ok=True)
    for name, doc in (("metrics.json", body), ("props.json", pbody)):
        with open(os.path.join(d, name), "w") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")


def main(root):
    # --- instrumented: the append counters exist. Deltas the test asserts:
    #     bytes by kind  kv 50 MiB, ssm 6 MiB, qsa 2 MiB, spec 0.5 MiB, ring 0, meta 0.125 MiB
    #     tokens         200000 forwarded + 5000 generated = 205000 newly processed
    #     serializations landed 56, noop 3, partial 2, failed 1, untracked 0
    #     buckets        [5,10,30,5,5,0,0,0,0,0,1] -> P50 "<= 1.0 MiB", P95 "<= 16.0 MiB"
    #     origins        attempts: prefill +20, decode +2, complete +28, idle +6, decline +2, other +4
    #     durations      every stage deltas to 56 landed appends; the byte-diff case is built so a
    #                    subtraction of the two snapshots' percentiles would lie for these too
    start_counters = {"prompt_tokens_total": 1000, "prefill_tokens_total": 1000,
                      "prefix_cache_tokens_total": 0, "generation_tokens_total": 500,
                      "requests_success_total": 4, "requests_cancelled_total": 0,
                      "requests_failed_total": 0, "requests_rejected_total": 0,
                      "prefix_cache_queries_total": 8, "prefix_cache_hits_total": 2}
    stop_counters = dict(start_counters, prompt_tokens_total=201000, prefill_tokens_total=201000,
                         prefix_cache_tokens_total=4000, generation_tokens_total=50500,
                         requests_success_total=20, prefix_cache_hits_total=14)
    origins_start = {"prefill_write_through": 4, "decode_point": 0, "request_complete": 6,
                     "idle_spill": 2, "decline_spill": 1, "other": 1}
    origins_stop = {"prefill_write_through": 24, "decode_point": 2, "request_complete": 34,
                    "idle_spill": 8, "decline_spill": 3, "other": 5}
    start_writes = {"written_bytes": {"kv": 10485760, "ssm": 2097152, "qsa": 1048576,
                                      "spec": 524288, "ring": 262144, "meta": 131072},
                    "failed_bytes": 4096,
                    "origins": origins_start,
                    "writer_busy_ns": 300000000, "writer_wait_ns": 60000000,
                    "serialization": {"landed": 12, "noop": 3, "partial": 1, "failed": 2, "untracked": 0,
                                      "bytes": 20000000, "byte_bounds": BOUNDS,
                                      "byte_buckets": [2, 3, 4, 2, 1, 0, 0, 0, 0, 0, 0],
                                      "durations": durations([2, 3, 4, 1, 0, 0, 0, 0, 0, 0], 9000000,
                                                             [3, 4, 2, 1, 0, 0, 0, 0, 0, 0], 500000,
                                                             [1, 8, 16, 4, 0, 0, 0, 0, 0, 0], 20000000,
                                                             [0, 2, 10, 20, 4, 0, 0, 0, 0, 0], 40000000)}}
    stop_writes = {"written_bytes": {"kv": 62914560, "ssm": 8388608, "qsa": 3145728,
                                     "spec": 1048576, "ring": 262144, "meta": 262144},
                   "failed_bytes": 8192,
                   "origins": origins_stop,
                   "writer_busy_ns": 800000000, "writer_wait_ns": 95000000,
                   "serialization": {"landed": 68, "noop": 6, "partial": 3, "failed": 3, "untracked": 0,
                                     "bytes": 132000000, "byte_bounds": BOUNDS,
                                     "byte_buckets": [7, 13, 34, 7, 6, 0, 0, 0, 0, 0, 1],
                                     "durations": durations([8, 23, 29, 5, 1, 0, 0, 0, 0, 0], 65000000,
                                                            [53, 10, 2, 1, 0, 0, 0, 0, 0, 0], 30500000,
                                                            [31, 28, 22, 4, 0, 0, 0, 0, 0, 0], 48000000,
                                                            [0, 7, 30, 45, 10, 0, 0, 0, 0, 0], 296000000)}}
    tier_start = {"disk_written_bytes": 14745600, "serialization_landed": 12, "serialization_bytes": 20000000,
                  "writer_staged_bytes": 0, "writer_staged_peak_bytes": 33554432}
    tier_stop = {"disk_written_bytes": 76218368, "serialization_landed": 68, "serialization_bytes": 132000000,
                 "writer_staged_bytes": 0, "writer_staged_peak_bytes": 33554432}
    # Gauges move in both directions by nature, so the stop row deliberately drops two of them:
    # a gauge going backwards must never read as a counter reset.
    start_gauges = {"requests_running": 2, "requests_waiting": 1, "memory_mb": 40000,
                    "generation_tokens_live": 500, "mlx_cache_bytes": 1000000000}
    stop_gauges = {"requests_running": 0, "requests_waiting": 0, "memory_mb": 41000,
                   "generation_tokens_live": 0, "mlx_cache_bytes": 900000000}
    write(root, "instrumented", "start", metrics(start_counters, start_writes, start_gauges),
          props(prefix_cache=tier_start))
    write(root, "instrumented", "stop", metrics(stop_counters, stop_writes, stop_gauges),
          props(prefix_cache=tier_stop))

    # --- legacy: an older served build. No write counters at all, and /props has no serialization
    #     fields; /metrics.json is switched to 503 by the test (metrics off on that boot).
    write(root, "legacy", "start", metrics(start_counters, None), props())
    write(root, "legacy", "stop", metrics(stop_counters, None), props())

    # --- durable: the same window once a durable-token counter exists. 104000 of the 205000
    #     processed tokens became restorable state, so amplification is 61472768 / 104000.
    d_start = dict(start_counters, durable_tokens_total=1000)
    d_stop = dict(stop_counters, durable_tokens_total=105000)
    write(root, "durable", "start", metrics(d_start, start_writes), props(prefix_cache=tier_start))
    write(root, "durable", "stop", metrics(d_stop, stop_writes), props(prefix_cache=tier_stop))

    # --- reset: the server restarted, so a process counter went backwards across the window.
    write(root, "reset", "start", metrics(stop_counters, stop_writes), props(prefix_cache=tier_stop))
    write(root, "reset", "stop", metrics(start_counters, start_writes), props(prefix_cache=tier_start))

    # --- modelchange: the default model was reloaded between the snapshots.
    write(root, "modelchange", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "modelchange", "stop", metrics(stop_counters, stop_writes),
          props(model="glm5_next", name="sushi-glm5", prefix_cache=tier_stop))

    # --- boundschange: the histogram's own bounds moved, so its buckets are not the same buckets.
    shifted = dict(stop_writes, serialization=dict(stop_writes["serialization"], byte_bounds=BOUNDS[1:]))
    write(root, "boundschange", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "boundschange", "stop", metrics(stop_counters, shifted), props(prefix_cache=tier_stop))

    # --- stagebounds: the DURATION histogram's bounds moved inside the window (a rebuild with a
    #     different stage grid). The byte histogram is untouched, so only the timings are un-diffable.
    shifted_stages = dict(stop_writes, serialization=dict(
        stop_writes["serialization"], durations=dict(stop_writes["serialization"]["durations"], bounds_us=DBOUNDS[1:])))
    write(root, "stagebounds", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "stagebounds", "stop", metrics(stop_counters, shifted_stages), props(prefix_cache=tier_stop))

    # --- chunkchange: the capture grid changed inside the window (a restart with a different
    #     --max-chunk), so the checkpoint cadence differs between the two halves. Same identity, so
    #     this is a warning, not a refusal.
    write(root, "chunkchange", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "chunkchange", "stop", metrics(stop_counters, stop_writes),
          props(prefix_cache=tier_stop, prefill_chunk=4096))

    # --- budgetchange: the server was relaunched with a smaller SSD budget. The setting moved, which
    #     is neither a counter reset nor a tier reopening, but the two halves are different sizes.
    tier_smaller = dict(tier_stop, disk_bytes=32212254720)
    write(root, "budgetchange", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "budgetchange", "stop", metrics(stop_counters, stop_writes), props(prefix_cache=tier_smaller))

    # --- tierreset: the per-tier totals reopened (model reloaded) while process counters held.
    tier_reopened = dict(tier_stop, disk_written_bytes=1000000, serialization_landed=1, serialization_bytes=1000000)
    write(root, "tierreset", "start", metrics(start_counters, start_writes), props(prefix_cache=tier_start))
    write(root, "tierreset", "stop", metrics(stop_counters, stop_writes), props(prefix_cache=tier_reopened))


if __name__ == "__main__":
    main(sys.argv[1])
