//! Cumulative bytes the SSD prefix cache wrote to the filesystem, by file kind. One `Stats` per tier
//! (`/props` per model) chains into `process` (`/metrics`), so a model that unloads keeps its bytes in
//! the process total. Counting does not depend on `--metrics`: the totals run from process start.

const std = @import("std");

/// What a written file holds. A new file kind is a new variant here, never a filename test.
pub const Kind = enum {
    /// `c*.safetensors` KV chunks.
    kv,
    /// `s*.safetensors` restore points and their `g*.safetensors` row segments.
    ssm,
    /// `qsa.safetensors` history.
    qsa,
    /// `spec.safetensors` draft-state sidecar.
    spec,
    /// `r*.safetensors` ring restore points.
    ring,
    /// `meta.json` and `tokens.bin`.
    meta,
};

const kind_names = @typeInfo(Kind).@"enum".field_names;
pub const kind_count = kind_names.len;

/// Why a logical persist ran. Counted at the operation's BEGIN (an attempt), so it reads next to
/// the outcome counters, not instead of them. A new origin is a new variant, never a log grep.
pub const Origin = enum {
    /// Prefill write-through: the chunk-boundary hook banking the prompt as it is computed.
    prefill_write_through,
    /// A DeepSeek decode restore point written mid-request (the `held` label "decode").
    decode_point,
    /// The flush after a finished request (`pending_disk` and the dirty-entry flush).
    request_complete,
    /// The SSD-first idle spill of an old resident entry.
    idle_spill,
    /// The spill of a candidate RAM admission declined.
    decline_spill,
    /// Any other logical append (a bare tier, a test, a path not named above).
    other,
};
const origin_names = @typeInfo(Origin).@"enum".field_names;
pub const origin_count = origin_names.len;

/// Where the time in one landed logical append went. `inference` contains `wait`; `e2e` contains
/// the whole async round trip (begin to the last piece landing). Without a writer thread the
/// filesystem time is synchronous and shows up in `inference`, not in `writer`.
pub const Stage = enum {
    /// Inference-thread time from begin to finish: readback, serialization, sync writes, permit waits.
    inference,
    /// Inference-thread time blocked waiting for the writer's host-byte permit.
    wait,
    /// Writer-thread time in the filesystem write (open, write, rename) of this operation's blobs.
    writer,
    /// Wall-clock from begin to the completion of the last piece, queueing included.
    e2e,
};
const stage_names = @typeInfo(Stage).@"enum".field_names;
pub const stage_count = stage_names.len;

/// Histogram bounds in microseconds; the open-ended bucket is index `duration_bounds_us.len`.
pub const duration_bounds_us = [_]u64{ 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 60_000_000, 600_000_000 };
const duration_bucket_count = duration_bounds_us.len + 1;

pub const operation_capacity = 64;
pub const byte_bounds = [_]u64{ 4096, 65536, 1048576, 4194304, 16777216, 67108864, 268435456, 1073741824, 2147483648, 4294967296 };
pub const OperationSnapshot = struct {
    landed: u64 = 0,
    noop: u64 = 0,
    partial: u64 = 0,
    failed: u64 = 0,
    untracked: u64 = 0,
    bytes: u64 = 0,
    buckets: [byte_bounds.len + 1]u64 = @splat(0),
};

/// One duration histogram: non-cumulative bucket counts plus the exact ns sum.
pub const StageSnapshot = struct {
    buckets: [duration_bucket_count]u64 = @splat(0),
    sum_ns: u64 = 0,
};

/// A bounded receipt, containing no cache arrays. The producer and each queued blob own a reference.
pub const Operation = struct {
    busy: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(0),
    written: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    owner: ?*Stats = null,
    outcome: Outcome = .partial,
    /// Clock source and start point, stored by the producer at begin; read by whichever thread
    /// drops the last reference, on the same boot clock.
    io: ?std.Io = null,
    started_at: ?std.Io.Timestamp = null,
    /// Producer-only: written by `finish` before its release, read after the refcount barrier.
    inference_ns: u64 = 0,
    origin: Origin = .other,
    /// Written by the inference thread (wait) and the writer thread (busy) while a reference is
    /// held, so the slot cannot be recycled under them.
    wait_ns: std.atomic.Value(u64) = .init(0),
    writer_ns: std.atomic.Value(u64) = .init(0),

    pub const Outcome = enum { complete, partial, skipped, failed };

    pub fn retain(self: *Operation) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn finish(self: *Operation, outcome: Outcome) void {
        self.outcome = outcome;
        self.inference_ns = self.elapsedNs();
        self.release();
    }

    /// Nanoseconds since `beginOperation`, 0 for a receipt that never carried a clock.
    pub fn elapsedNs(self: *const Operation) u64 {
        const io = self.io orelse return 0;
        const at = self.started_at orelse return 0;
        const ns = at.untilNow(io, .boot).nanoseconds;
        return if (ns > 0) @intCast(ns) else 0;
    }

    pub fn release(self: *Operation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const spans = [_]u64{ self.inference_ns, self.wait_ns.load(.monotonic), self.writer_ns.load(.monotonic), self.elapsedNs() };
        self.owner.?.recordOperation(self.outcome, self.written.load(.monotonic), self.failed.load(.monotonic), spans);
        self.busy.store(false, .release);
    }
};

pub const Snapshot = struct {
    written: [kind_count]u64 = @splat(0),
    /// Landed filesystem bytes, including partial logical appends and standalone writes.
    by_origin_kind: [origin_count][kind_count]u64 = @splat(@splat(0)),
    /// Bytes handed to a write that failed, or staged and then dropped; never part of `written`.
    failed: u64 = 0,
    operations: OperationSnapshot = .{},
    /// Persist attempts by origin (counted at begin, before any outcome is known).
    origins: [origin_count]u64 = @splat(0),
    /// Duration histograms of LANDED appends, one per stage.
    stages: [stage_count]StageSnapshot = @splat(.{}),
    /// Writer-thread filesystem time and inference-thread permit waits, ALL work (even receipt-less).
    writer_busy_ns: u64 = 0,
    writer_wait_ns: u64 = 0,

    pub fn totalWritten(self: Snapshot) u64 {
        var n: u64 = 0;
        for (self.written) |b| n +|= b;
        return n;
    }
};

pub const Stats = struct {
    written: [kind_count]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    by_origin_kind: [origin_count][kind_count]std.atomic.Value(u64) = @splat(@splat(.init(0))),
    failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parent: ?*Stats = null,
    operations: [5]std.atomic.Value(u64) = @splat(.init(0)),
    operation_bytes: std.atomic.Value(u64) = .init(0),
    operation_buckets: [byte_bounds.len + 1]std.atomic.Value(u64) = @splat(.init(0)),
    receipts: [operation_capacity]Operation = @splat(.{}),
    origins: [origin_count]std.atomic.Value(u64) = @splat(.init(0)),
    stage_buckets: [stage_count][duration_bucket_count]std.atomic.Value(u64) = @splat(@splat(.init(0))),
    stage_sums_ns: [stage_count]std.atomic.Value(u64) = @splat(.init(0)),
    writer_busy_ns: std.atomic.Value(u64) = .init(0),
    writer_wait_ns: std.atomic.Value(u64) = .init(0),
    /// Inference-thread-only receipt for synchronous writes. Writer threads pass their own explicitly.
    active: ?*Operation = null,
    active_origin: Origin = .other,

    pub fn beginOperation(self: *Stats, io: std.Io, origin: Origin) ?*Operation {
        self.noteOrigin(origin);
        for (&self.receipts) |*op| {
            if (op.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
            op.refs.store(1, .monotonic);
            op.written.store(0, .monotonic);
            op.failed.store(false, .monotonic);
            op.wait_ns.store(0, .monotonic);
            op.writer_ns.store(0, .monotonic);
            op.inference_ns = 0;
            op.owner = self;
            op.io = io;
            op.started_at = std.Io.Timestamp.now(io, .boot);
            op.origin = origin;
            op.outcome = .partial;
            return op;
        }
        self.incrementOperation(4);
        return null;
    }

    fn noteOrigin(self: *Stats, origin: Origin) void {
        _ = self.origins[@backingInt(origin)].fetchAdd(1, .monotonic);
        if (self.parent) |p| p.noteOrigin(origin);
    }

    /// The inference thread blocked on the writer's permit for `ns`. `op` is the producer's current
    /// receipt (null outside a logical append; the total still counts it).
    pub fn recordWait(self: *Stats, ns: u64, op: ?*Operation) void {
        _ = self.writer_wait_ns.fetchAdd(ns, .monotonic);
        if (op) |o| _ = o.wait_ns.fetchAdd(ns, .monotonic);
        if (self.parent) |p| p.recordWait(ns, null);
    }

    /// Writer-thread filesystem time for one landed blob. `op` is that blob's receipt.
    pub fn recordWriterBusy(self: *Stats, ns: u64, op: ?*Operation) void {
        _ = self.writer_busy_ns.fetchAdd(ns, .monotonic);
        if (op) |o| _ = o.writer_ns.fetchAdd(ns, .monotonic);
        if (self.parent) |p| p.recordWriterBusy(ns, null);
    }

    fn incrementOperation(self: *Stats, index: usize) void {
        _ = self.operations[index].fetchAdd(1, .monotonic);
        if (self.parent) |p| p.incrementOperation(index);
    }

    fn recordOperation(self: *Stats, outcome: Operation.Outcome, bytes: u64, failed: bool, spans: [stage_count]u64) void {
        const index: usize = if (failed or outcome == .failed) 3 else if (outcome == .partial) 2 else if (bytes == 0) 1 else if (outcome == .skipped) 2 else 0;
        self.incrementOperation(index);
        if (index == 0) {
            self.recordOperationBytes(bytes);
            for (spans, 0..) |ns, stage| self.recordDuration(@fromBackingInt(@intCast(stage)), ns);
        }
    }

    fn recordDuration(self: *Stats, stage: Stage, ns: u64) void {
        const micros = ns / 1_000;
        var bucket: usize = 0;
        while (bucket < duration_bounds_us.len and micros > duration_bounds_us[bucket]) : (bucket += 1) {}
        _ = self.stage_buckets[@backingInt(stage)][bucket].fetchAdd(1, .monotonic);
        _ = self.stage_sums_ns[@backingInt(stage)].fetchAdd(ns, .monotonic);
        if (self.parent) |p| p.recordDuration(stage, ns);
    }

    fn recordOperationBytes(self: *Stats, bytes: u64) void {
        _ = self.operation_bytes.fetchAdd(bytes, .monotonic);
        var bucket: usize = 0;
        while (bucket < byte_bounds.len and bytes > byte_bounds[bucket]) : (bucket += 1) {}
        _ = self.operation_buckets[bucket].fetchAdd(1, .monotonic);
        if (self.parent) |p| p.recordOperationBytes(bytes);
    }

    pub fn recordWritten(self: *Stats, kind: Kind, bytes: u64) void {
        self.recordWrittenAttributed(kind, bytes, self.active, self.active_origin);
    }

    pub fn recordWrittenFor(self: *Stats, kind: Kind, bytes: u64, op: ?*Operation) void {
        self.recordWrittenAttributed(kind, bytes, op, if (op) |o| o.origin else .other);
    }

    pub fn recordWrittenAttributed(self: *Stats, kind: Kind, bytes: u64, op: ?*Operation, origin: Origin) void {
        _ = self.written[@backingInt(kind)].fetchAdd(bytes, .monotonic);
        _ = self.by_origin_kind[@backingInt(origin)][@backingInt(kind)].fetchAdd(bytes, .monotonic);
        if (op) |o| _ = o.written.fetchAdd(bytes, .monotonic);
        if (self.parent) |p| p.recordWrittenAttributed(kind, bytes, null, origin);
    }

    pub fn recordFailed(self: *Stats, bytes: u64) void {
        self.recordFailedFor(bytes, self.active);
    }

    pub fn recordFailedFor(self: *Stats, bytes: u64, op: ?*Operation) void {
        _ = self.failed.fetchAdd(bytes, .monotonic);
        if (op) |o| o.failed.store(true, .monotonic);
        if (self.parent) |p| p.recordFailedFor(bytes, null);
    }

    pub fn snapshot(self: *const Stats) Snapshot {
        var s: Snapshot = .{ .failed = self.failed.load(.monotonic) };
        for (&s.written, &self.written) |*dst, *src| dst.* = src.load(.monotonic);
        for (&s.by_origin_kind, &self.by_origin_kind) |*dst, *src| {
            for (dst, src) |*cell, *atomic| cell.* = atomic.load(.monotonic);
        }
        s.operations = .{
            .landed = self.operations[0].load(.monotonic),
            .noop = self.operations[1].load(.monotonic),
            .partial = self.operations[2].load(.monotonic),
            .failed = self.operations[3].load(.monotonic),
            .untracked = self.operations[4].load(.monotonic),
            .bytes = self.operation_bytes.load(.monotonic),
        };
        for (&s.operations.buckets, &self.operation_buckets) |*dst, *src| dst.* = src.load(.monotonic);
        for (&s.origins, &self.origins) |*dst, *src| dst.* = src.load(.monotonic);
        for (&s.stages, &self.stage_buckets, &self.stage_sums_ns) |*dst, *buckets, *sum| {
            for (&dst.buckets, buckets) |*db, *sb| db.* = sb.load(.monotonic);
            dst.sum_ns = sum.load(.monotonic);
        }
        s.writer_busy_ns = self.writer_busy_ns.load(.monotonic);
        s.writer_wait_ns = self.writer_wait_ns.load(.monotonic);
        return s;
    }
};

/// Every tier of this process.
pub var process: Stats = .{};

pub fn writePrometheus(snap: Snapshot, w: *std.Io.Writer) !void {
    try w.print("# HELP sushi:prefix_cache_write_bytes_total Bytes the SSD prefix cache wrote to the filesystem since process start, by file kind\n# TYPE sushi:prefix_cache_write_bytes_total counter\n", .{});
    inline for (kind_names, 0..) |name, i| {
        try w.print("sushi:prefix_cache_write_bytes_total{{kind=\"{s}\"}} {d}\n", .{ name, snap.written[i] });
    }
    try w.writeAll("# HELP sushi:prefix_cache_write_origin_bytes_total Landed filesystem bytes by persistence origin and file kind, including partial appends\n# TYPE sushi:prefix_cache_write_origin_bytes_total counter\n");
    inline for (origin_names, 0..) |origin, oi| {
        inline for (kind_names, 0..) |kind, ki| {
            try w.print("sushi:prefix_cache_write_origin_bytes_total{{origin=\"{s}\",kind=\"{s}\"}} {d}\n", .{ origin, kind, snap.by_origin_kind[oi][ki] });
        }
    }
    try w.print("\n# HELP sushi:prefix_cache_write_failed_bytes_total Bytes of SSD prefix cache writes that failed or were dropped before landing\n# TYPE sushi:prefix_cache_write_failed_bytes_total counter\nsushi:prefix_cache_write_failed_bytes_total {d}\n\n", .{snap.failed});
    const op = snap.operations;
    try w.writeAll("# HELP sushi:prefix_cache_serialization_operations_total Logical append operations by filesystem completion outcome; landed does not imply hybrid restorability\n# TYPE sushi:prefix_cache_serialization_operations_total counter\n");
    inline for (.{ "landed", "noop", "partial", "failed", "untracked" }, .{ op.landed, op.noop, op.partial, op.failed, op.untracked }) |name, n| {
        try w.print("sushi:prefix_cache_serialization_operations_total{{outcome=\"{s}\"}} {d}\n", .{ name, n });
    }
    try w.writeAll("# HELP sushi:prefix_cache_serialization_bytes Filesystem bytes per fully landed logical append, including all pieces and metadata\n# TYPE sushi:prefix_cache_serialization_bytes histogram\n");
    var cumulative: u64 = 0;
    for (byte_bounds, op.buckets[0..byte_bounds.len]) |bound, count| {
        cumulative +|= count;
        try w.print("sushi:prefix_cache_serialization_bytes_bucket{{le=\"{d}\"}} {d}\n", .{ bound, cumulative });
    }
    try w.print("sushi:prefix_cache_serialization_bytes_bucket{{le=\"+Inf\"}} {d}\nsushi:prefix_cache_serialization_bytes_count {d}\nsushi:prefix_cache_serialization_bytes_sum {d}\n\n", .{ op.landed, op.landed, op.bytes });
    try w.writeAll("# HELP sushi:prefix_cache_persist_origin_total Logical persist calls begun since process start, by origin (attempts, not outcomes)\n# TYPE sushi:prefix_cache_persist_origin_total counter\n");
    inline for (origin_names, 0..) |name, i| {
        try w.print("sushi:prefix_cache_persist_origin_total{{origin=\"{s}\"}} {d}\n", .{ name, snap.origins[i] });
    }
    try w.print("\n# HELP sushi:prefix_cache_writer_busy_ns_total Writer-thread filesystem time (open, write, rename) of landed blobs since process start\n# TYPE sushi:prefix_cache_writer_busy_ns_total counter\nsushi:prefix_cache_writer_busy_ns_total {d}\n", .{snap.writer_busy_ns});
    try w.print("\n# HELP sushi:prefix_cache_writer_wait_ns_total Inference-thread time blocked on the writer's host-byte permit since process start\n# TYPE sushi:prefix_cache_writer_wait_ns_total counter\nsushi:prefix_cache_writer_wait_ns_total {d}\n", .{snap.writer_wait_ns});
    try w.writeAll("\n# HELP sushi:prefix_cache_serialization_duration_us Time per fully landed logical append, by stage; inference contains wait; e2e spans begin to the last piece landing, queueing included\n# TYPE sushi:prefix_cache_serialization_duration_us histogram\n");
    inline for (stage_names, 0..) |stage, i| {
        var cum: u64 = 0;
        for (duration_bounds_us, snap.stages[i].buckets[0..duration_bounds_us.len]) |bound, count| {
            cum += count;
            try w.print("sushi:prefix_cache_serialization_duration_us_bucket{{stage=\"{s}\",le=\"{d}\"}} {d}\n", .{ stage, bound, cum });
        }
        try w.print("sushi:prefix_cache_serialization_duration_us_bucket{{stage=\"{s}\",le=\"+Inf\"}} {d}\nsushi:prefix_cache_serialization_duration_us_count{{stage=\"{s}\"}} {d}\nsushi:prefix_cache_serialization_duration_us_sum{{stage=\"{s}\"}} {d}\n", .{ stage, op.landed, stage, op.landed, stage, snap.stages[i].sum_ns / 1_000 });
    }
}

/// `"prefix_cache_writes":{...}` as one member of the `/metrics.json` object.
pub fn writeJson(snap: Snapshot, w: *std.Io.Writer) !void {
    try w.print("\"prefix_cache_writes\":{{\"written_bytes\":{{", .{});
    inline for (kind_names, 0..) |name, i| {
        try w.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", name, snap.written[i] });
    }
    try w.writeAll("},\"by_origin_kind\":{");
    inline for (origin_names, 0..) |origin, oi| {
        try w.print("{s}\"{s}\":{{", .{ if (oi == 0) "" else ",", origin });
        inline for (kind_names, 0..) |kind, ki| {
            try w.print("{s}\"{s}\":{d}", .{ if (ki == 0) "" else ",", kind, snap.by_origin_kind[oi][ki] });
        }
        try w.writeAll("}");
    }
    try w.print("}},\"failed_bytes\":{d},\"origins\":{{", .{snap.failed});
    inline for (origin_names, 0..) |name, i| {
        try w.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", name, snap.origins[i] });
    }
    try w.print("}},\"writer_busy_ns\":{d},\"writer_wait_ns\":{d},\"serialization\":{{\"landed\":{d},\"noop\":{d},\"partial\":{d},\"failed\":{d},\"untracked\":{d},\"bytes\":{d},\"byte_bounds\":[", .{
        snap.writer_busy_ns,       snap.writer_wait_ns,
        snap.operations.landed,    snap.operations.noop,
        snap.operations.partial,   snap.operations.failed,
        snap.operations.untracked, snap.operations.bytes,
    });
    for (byte_bounds, 0..) |bound, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", bound });
    try w.writeAll("],\"byte_buckets\":[");
    for (snap.operations.buckets, 0..) |count, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", count });
    try w.writeAll("],\"durations\":{\"bounds_us\":[");
    for (duration_bounds_us, 0..) |bound, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", bound });
    try w.writeAll("]");
    inline for (stage_names, 0..) |stage, i| {
        try w.print(",\"{s}\":{{\"buckets\":[", .{stage});
        for (snap.stages[i].buckets, 0..) |count, b| try w.print("{s}{d}", .{ if (b == 0) "" else ",", count });
        try w.print("],\"sum_ns\":{d}}}", .{snap.stages[i].sum_ns});
    }
    try w.writeAll("}}}");
}

test "Stats: a write lands in its kind and in the parent, a failure in failed only" {
    var total: Stats = .{};
    var tier: Stats = .{ .parent = &total };
    tier.recordWritten(.kv, 100);
    tier.recordWritten(.kv, 28);
    tier.recordWritten(.qsa, 7);
    tier.recordFailed(5);
    const s = tier.snapshot();
    try std.testing.expectEqual(@as(u64, 128), s.written[@backingInt(Kind.kv)]);
    try std.testing.expectEqual(@as(u64, 7), s.written[@backingInt(Kind.qsa)]);
    try std.testing.expectEqual(@as(u64, 0), s.written[@backingInt(Kind.ssm)]);
    try std.testing.expectEqual(@as(u64, 135), s.totalWritten());
    try std.testing.expectEqual(@as(u64, 5), s.failed);
    try std.testing.expectEqual(s, total.snapshot());
}

test "operation accounting waits for every piece and separates no-op and failed work" {
    var stats: Stats = .{};
    const op = stats.beginOperation(std.testing.io, .other).?;
    op.retain();
    stats.recordWrittenFor(.meta, 40, op);
    op.finish(.complete);
    try std.testing.expectEqual(@as(u64, 0), stats.snapshot().operations.landed);
    stats.recordWrittenFor(.kv, 2 * 1024 * 1024 * 1024, op);
    op.release();
    const landed = stats.snapshot().operations;
    try std.testing.expectEqual(@as(u64, 1), landed.landed);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024 + 40), landed.bytes);

    stats.beginOperation(std.testing.io, .other).?.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.noop);
    const failed = stats.beginOperation(std.testing.io, .other).?;
    stats.recordWrittenFor(.kv, 100, failed);
    stats.recordFailedFor(50, failed);
    failed.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.failed);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.landed);
    const snap = stats.snapshot();
    var sum: u64 = 0;
    for (snap.operations.buckets) |n| sum += n;
    try std.testing.expectEqual(snap.operations.landed, sum);
    var stage_total: u64 = 0;
    for (snap.stages[@backingInt(Stage.inference)].buckets) |n| stage_total += n;
    try std.testing.expectEqual(@as(u64, 1), stage_total); // only the one landed append is timed
}

test "operation tracking is bounded and a completed slot can be reused" {
    var stats: Stats = .{};
    var held: [operation_capacity]*Operation = undefined;
    for (&held) |*op| op.* = stats.beginOperation(std.testing.io, .other).?;
    try std.testing.expect(stats.beginOperation(std.testing.io, .other) == null);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.untracked);
    try std.testing.expectEqual(@as(u64, operation_capacity + 1), stats.snapshot().origins[origin_count - 1]);
    for (held) |op| op.finish(.partial);
    const again = stats.beginOperation(std.testing.io, .other).?;
    stats.recordWrittenFor(.meta, 10, again);
    again.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.landed);
}

test "landed byte attribution includes partial and receiptless operations exactly once" {
    var parent: Stats = .{};
    var tier: Stats = .{ .parent = &parent };
    const partial = tier.beginOperation(std.testing.io, .prefill_write_through).?;
    tier.recordWrittenAttributed(.ssm, 120, partial, .prefill_write_through);
    partial.finish(.partial);
    tier.recordWrittenAttributed(.qsa, 40, null, .request_complete);
    const snap = tier.snapshot();
    try std.testing.expectEqual(@as(u64, 120), snap.by_origin_kind[@backingInt(Origin.prefill_write_through)][@backingInt(Kind.ssm)]);
    try std.testing.expectEqual(@as(u64, 40), snap.by_origin_kind[@backingInt(Origin.request_complete)][@backingInt(Kind.qsa)]);
    try std.testing.expectEqual(@as(u64, 0), snap.operations.landed);
    try std.testing.expectEqual(snap.by_origin_kind, parent.snapshot().by_origin_kind);
    var by_kind: [kind_count]u64 = @splat(0);
    for (snap.by_origin_kind) |row| for (row, 0..) |bytes, kind| {
        by_kind[kind] += bytes;
    };
    try std.testing.expectEqual(snap.written, by_kind);
}

test "timing receipts: a landed append records its four spans; other outcomes do not" {
    var stats: Stats = .{};
    const op = stats.beginOperation(std.testing.io, .idle_spill).?;
    op.retain();
    stats.recordWrittenFor(.kv, 4096, op);
    stats.recordWait(2_500, op);
    stats.recordWriterBusy(150_000, op);
    op.finish(.complete);
    op.release();
    const snap = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snap.origins[@backingInt(Origin.idle_spill)]);
    try std.testing.expectEqual(@as(u64, 2_500), snap.writer_wait_ns);
    try std.testing.expectEqual(@as(u64, 150_000), snap.writer_busy_ns);
    const wait = snap.stages[@backingInt(Stage.wait)];
    try std.testing.expectEqual(@as(u64, 1), wait.buckets[0]); // 2 us fits the <= 10 us bound
    try std.testing.expectEqual(@as(u64, 2_500), wait.sum_ns);
    const wr = snap.stages[@backingInt(Stage.writer)];
    try std.testing.expectEqual(@as(u64, 1), wr.buckets[2]); // 150 us fits the <= 1 ms bound
    try std.testing.expectEqual(@as(u64, 150_000), wr.sum_ns);
    for ([_]Stage{ .inference, .e2e }) |st| {
        var n: u64 = 0;
        for (snap.stages[@backingInt(st)].buckets) |b| n += b;
        try std.testing.expectEqual(@as(u64, 1), n);
        try std.testing.expect(snap.stages[@backingInt(st)].sum_ns > 0);
    }
    // A wait inside an operation that never lands stays in the total only: the histograms hold
    // fully landed appends, and an unlanded span must not pose as a persistence duration.
    const partial = stats.beginOperation(std.testing.io, .other).?;
    stats.recordWait(9_000, partial);
    partial.finish(.partial);
    const after = stats.snapshot();
    try std.testing.expectEqual(@as(u64, 11_500), after.writer_wait_ns);
    try std.testing.expectEqual(@as(u64, 1), after.origins[@backingInt(Origin.other)]);
    var n: u64 = 0;
    for (after.stages[@backingInt(Stage.wait)].buckets) |b| n += b;
    try std.testing.expectEqual(@as(u64, 1), n);
}

test "timing receipts chain into the parent and survive receipt reuse" {
    var total: Stats = .{};
    var tier: Stats = .{ .parent = &total };
    const op = tier.beginOperation(std.testing.io, .prefill_write_through).?;
    tier.recordWrittenFor(.kv, 8, op);
    tier.recordWait(3_000, op);
    tier.recordWriterBusy(4_000, op);
    op.finish(.complete);
    const s = total.snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.operations.landed);
    try std.testing.expectEqual(@as(u64, 1), s.origins[@backingInt(Origin.prefill_write_through)]);
    try std.testing.expectEqual(@as(u64, 3_000), s.stages[@backingInt(Stage.wait)].sum_ns);
    try std.testing.expectEqual(@as(u64, 4_000), s.stages[@backingInt(Stage.writer)].sum_ns);
    try std.testing.expectEqual(@as(u64, 3_000), s.writer_wait_ns);
    try std.testing.expectEqual(@as(u64, 4_000), s.writer_busy_ns);
}

test "the renderings name every origin, stage and writer total" {
    var stats: Stats = .{};
    const op = stats.beginOperation(std.testing.io, .request_complete).?;
    stats.recordWrittenFor(.meta, 10, op);
    stats.recordWait(1_500, op);
    stats.recordWriterBusy(2_500, op);
    op.finish(.complete);
    var snap = stats.snapshot();
    snap.written[@backingInt(Kind.kv)] = 1;
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePrometheus(snap, &w);
    const prom = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_persist_origin_total{origin=\"request_complete\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_write_origin_bytes_total{origin=\"request_complete\",kind=\"meta\"} 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_writer_busy_ns_total 2500") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_writer_wait_ns_total 1500") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_serialization_duration_us_bucket{stage=\"writer\",le=\"10\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_serialization_duration_us_bucket{stage=\"writer\",le=\"100\"} 1") != null);
    var json_buf: [8192]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&json_buf);
    try jw.writeAll("{");
    try writeJson(snap, &jw);
    try jw.writeAll("}");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, jw.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object.get("prefix_cache_writes").?.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("origins").?.object.get("request_complete").?.integer);
    try std.testing.expectEqual(@as(i64, 10), obj.get("by_origin_kind").?.object.get("request_complete").?.object.get("meta").?.integer);
    try std.testing.expectEqual(@as(i64, 2500), obj.get("writer_busy_ns").?.integer);
    try std.testing.expectEqual(@as(i64, 1500), obj.get("writer_wait_ns").?.integer);
    const stages = obj.get("serialization").?.object.get("durations").?.object;
    try std.testing.expectEqual(duration_bounds_us.len + 1, stages.get("writer").?.object.get("buckets").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), stages.get("writer").?.object.get("buckets").?.array.items[0].integer); // 2.5 us fits the <= 10 us bound
    try std.testing.expectEqual(@as(i64, 2_500), stages.get("writer").?.object.get("sum_ns").?.integer);
}

test "the Prometheus and JSON renderings name every kind and the failed counter" {
    var snap: Snapshot = .{ .failed = 9 };
    for (&snap.written, 0..) |*b, i| b.* = 1000 + i;
    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePrometheus(snap, &w);
    const prom = w.buffered();
    var json_buf: [8192]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&json_buf);
    try jw.writeAll("{");
    try writeJson(snap, &jw);
    try jw.writeAll("}");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, jw.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object.get("prefix_cache_writes").?.object;
    inline for (kind_names, 0..) |name, i| {
        var line: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&line, "sushi:prefix_cache_write_bytes_total{{kind=\"{s}\"}} {d}\n", .{ name, 1000 + i });
        try std.testing.expect(std.mem.indexOf(u8, prom, want) != null);
        try std.testing.expectEqual(@as(i64, 1000 + i), obj.get("written_bytes").?.object.get(name).?.integer);
    }
    try std.testing.expect(std.mem.indexOf(u8, prom, "sushi:prefix_cache_write_failed_bytes_total 9\n") != null);
    try std.testing.expectEqual(@as(i64, 9), obj.get("failed_bytes").?.integer);
}
