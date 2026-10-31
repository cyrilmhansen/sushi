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

/// A bounded receipt, containing no cache arrays. The producer and each queued blob own a reference.
pub const Operation = struct {
    busy: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(0),
    written: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    owner: ?*Stats = null,
    outcome: Outcome = .partial,

    pub const Outcome = enum { complete, partial, skipped, failed };

    pub fn retain(self: *Operation) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn finish(self: *Operation, outcome: Outcome) void {
        self.outcome = outcome;
        self.release();
    }

    pub fn release(self: *Operation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.owner.?.recordOperation(self.outcome, self.written.load(.monotonic), self.failed.load(.monotonic));
        self.busy.store(false, .release);
    }
};

pub const Snapshot = struct {
    written: [kind_count]u64 = @splat(0),
    /// Bytes handed to a write that failed, or staged and then dropped; never part of `written`.
    failed: u64 = 0,
    operations: OperationSnapshot = .{},

    pub fn totalWritten(self: Snapshot) u64 {
        var n: u64 = 0;
        for (self.written) |b| n +|= b;
        return n;
    }
};

pub const Stats = struct {
    written: [kind_count]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0)),
    failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parent: ?*Stats = null,
    operations: [5]std.atomic.Value(u64) = @splat(.init(0)),
    operation_bytes: std.atomic.Value(u64) = .init(0),
    operation_buckets: [byte_bounds.len + 1]std.atomic.Value(u64) = @splat(.init(0)),
    receipts: [operation_capacity]Operation = @splat(.{}),
    /// Inference-thread-only receipt for synchronous writes. Writer threads pass their own explicitly.
    active: ?*Operation = null,

    pub fn beginOperation(self: *Stats) ?*Operation {
        for (&self.receipts) |*op| {
            if (op.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
            op.refs.store(1, .monotonic);
            op.written.store(0, .monotonic);
            op.failed.store(false, .monotonic);
            op.owner = self;
            op.outcome = .partial;
            return op;
        }
        self.incrementOperation(4);
        return null;
    }

    fn incrementOperation(self: *Stats, index: usize) void {
        _ = self.operations[index].fetchAdd(1, .monotonic);
        if (self.parent) |p| p.incrementOperation(index);
    }

    fn recordOperation(self: *Stats, outcome: Operation.Outcome, bytes: u64, failed: bool) void {
        const index: usize = if (failed or outcome == .failed) 3 else if (outcome == .partial) 2 else if (bytes == 0) 1 else if (outcome == .skipped) 2 else 0;
        self.incrementOperation(index);
        if (index == 0) self.recordOperationBytes(bytes);
    }

    fn recordOperationBytes(self: *Stats, bytes: u64) void {
        _ = self.operation_bytes.fetchAdd(bytes, .monotonic);
        var bucket: usize = 0;
        while (bucket < byte_bounds.len and bytes > byte_bounds[bucket]) : (bucket += 1) {}
        _ = self.operation_buckets[bucket].fetchAdd(1, .monotonic);
        if (self.parent) |p| p.recordOperationBytes(bytes);
    }

    pub fn recordWritten(self: *Stats, kind: Kind, bytes: u64) void {
        self.recordWrittenFor(kind, bytes, self.active);
    }

    pub fn recordWrittenFor(self: *Stats, kind: Kind, bytes: u64, op: ?*Operation) void {
        _ = self.written[@intFromEnum(kind)].fetchAdd(bytes, .monotonic);
        if (op) |o| _ = o.written.fetchAdd(bytes, .monotonic);
        if (self.parent) |p| p.recordWrittenFor(kind, bytes, null);
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
        s.operations = .{
            .landed = self.operations[0].load(.monotonic),
            .noop = self.operations[1].load(.monotonic),
            .partial = self.operations[2].load(.monotonic),
            .failed = self.operations[3].load(.monotonic),
            .untracked = self.operations[4].load(.monotonic),
            .bytes = self.operation_bytes.load(.monotonic),
        };
        for (&s.operations.buckets, &self.operation_buckets) |*dst, *src| dst.* = src.load(.monotonic);
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
    try w.print("sushi:prefix_cache_serialization_bytes_bucket{{le=\"+Inf\"}} {d}\nsushi:prefix_cache_serialization_bytes_count {d}\nsushi:prefix_cache_serialization_bytes_sum {d}\n", .{ op.landed, op.landed, op.bytes });
}

/// `"prefix_cache_writes":{...}` as one member of the `/metrics.json` object.
pub fn writeJson(snap: Snapshot, w: *std.Io.Writer) !void {
    try w.print("\"prefix_cache_writes\":{{\"written_bytes\":{{", .{});
    inline for (kind_names, 0..) |name, i| {
        try w.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", name, snap.written[i] });
    }
    try w.print("}},\"failed_bytes\":{d},\"serialization\":{{\"landed\":{d},\"noop\":{d},\"partial\":{d},\"failed\":{d},\"untracked\":{d},\"bytes\":{d},\"byte_bounds\":[", .{ snap.failed, snap.operations.landed, snap.operations.noop, snap.operations.partial, snap.operations.failed, snap.operations.untracked, snap.operations.bytes });
    for (byte_bounds, 0..) |bound, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", bound });
    try w.writeAll("],\"byte_buckets\":[");
    for (snap.operations.buckets, 0..) |count, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", count });
    try w.writeAll("]}}");
}

test "Stats: a write lands in its kind and in the parent, a failure in failed only" {
    var total: Stats = .{};
    var tier: Stats = .{ .parent = &total };
    tier.recordWritten(.kv, 100);
    tier.recordWritten(.kv, 28);
    tier.recordWritten(.qsa, 7);
    tier.recordFailed(5);
    const s = tier.snapshot();
    try std.testing.expectEqual(@as(u64, 128), s.written[@intFromEnum(Kind.kv)]);
    try std.testing.expectEqual(@as(u64, 7), s.written[@intFromEnum(Kind.qsa)]);
    try std.testing.expectEqual(@as(u64, 0), s.written[@intFromEnum(Kind.ssm)]);
    try std.testing.expectEqual(@as(u64, 135), s.totalWritten());
    try std.testing.expectEqual(@as(u64, 5), s.failed);
    try std.testing.expectEqual(s, total.snapshot());
}

test "operation accounting waits for every piece and separates no-op and failed work" {
    var stats: Stats = .{};
    const op = stats.beginOperation().?;
    op.retain();
    stats.recordWrittenFor(.meta, 40, op);
    op.finish(.complete);
    try std.testing.expectEqual(@as(u64, 0), stats.snapshot().operations.landed);
    stats.recordWrittenFor(.kv, 2 * 1024 * 1024 * 1024, op);
    op.release();
    const landed = stats.snapshot().operations;
    try std.testing.expectEqual(@as(u64, 1), landed.landed);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024 * 1024 + 40), landed.bytes);

    stats.beginOperation().?.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.noop);
    const failed = stats.beginOperation().?;
    stats.recordWrittenFor(.kv, 100, failed);
    stats.recordFailedFor(50, failed);
    failed.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.failed);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.landed);
    const snap = stats.snapshot();
    var sum: u64 = 0;
    for (snap.operations.buckets) |n| sum += n;
    try std.testing.expectEqual(snap.operations.landed, sum);
}

test "operation tracking is bounded and a completed slot can be reused" {
    var stats: Stats = .{};
    var held: [operation_capacity]*Operation = undefined;
    for (&held) |*op| op.* = stats.beginOperation().?;
    try std.testing.expect(stats.beginOperation() == null);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.untracked);
    for (held) |op| op.finish(.partial);
    const again = stats.beginOperation().?;
    stats.recordWrittenFor(.meta, 10, again);
    again.finish(.complete);
    try std.testing.expectEqual(@as(u64, 1), stats.snapshot().operations.landed);
}

test "the Prometheus and JSON renderings name every kind and the failed counter" {
    var snap: Snapshot = .{ .failed = 9 };
    for (&snap.written, 0..) |*b, i| b.* = 1000 + i;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePrometheus(snap, &w);
    const prom = w.buffered();
    var json_buf: [2048]u8 = undefined;
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
