const std = @import("std");

/// Link a landed immutable file only when its complete bytes equal the candidate stream.
/// The caller has already ruled out queued writes to `source`; a failed comparison/link is
/// an ordinary miss. The two fixed buffers are transient stack space, never cache residency.
pub fn linkIfEqual(io: std.Io, source: []const u8, target: []const u8, stream: anytype, size: usize) !bool {
    const f = std.Io.Dir.openFileAbsolute(io, source, .{}) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    if (st.size != size) return false;
    var read_buf: [8192]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    var want: [16384]u8 = undefined;
    var got: [16384]u8 = undefined;
    var at: usize = 0;
    while (at < size) {
        const n = @min(want.len, size - at);
        try stream.fill(want[0..n]);
        reader.interface.readSliceAll(got[0..n]) catch return false;
        if (!std.mem.eql(u8, want[0..n], got[0..n])) return false;
        at += n;
    }
    const src_dir = std.fs.path.dirname(source) orelse return false;
    const dst_dir = std.fs.path.dirname(target) orelse return false;
    const src_name = std.fs.path.basename(source);
    const dst_name = std.fs.path.basename(target);
    var sd = std.Io.Dir.openDirAbsolute(io, src_dir, .{}) catch return false;
    defer sd.close(io);
    var dd = std.Io.Dir.openDirAbsolute(io, dst_dir, .{}) catch return false;
    defer dd.close(io);
    std.Io.Dir.hardLink(sd, src_name, dd, dst_name, io, .{}) catch return false;
    return true;
}

test "identical checkpoint bytes can be linked without writing a second file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "checkpoint-data" });
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source", .{root});
    defer std.testing.allocator.free(source);
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/target", .{root});
    defer std.testing.allocator.free(target);
    var stream = TestStream{ .bytes = "checkpoint-data" };
    try std.testing.expect(try linkIfEqual(io, source, target, &stream, 15));
    const linked = try tmp.dir.readFileAlloc(io, "target", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(linked);
    try std.testing.expectEqualStrings("checkpoint-data", linked);
}

test "a mismatched or partial checkpoint cannot authorize a link" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "checkpoint-data" });
    var buf: [512]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source", .{root});
    defer std.testing.allocator.free(source);
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/target", .{root});
    defer std.testing.allocator.free(target);
    var changed = TestStream{ .bytes = "checkpoint-DATA" };
    try std.testing.expect(!(try linkIfEqual(io, source, target, &changed, 15)));
    var partial = TestStream{ .bytes = "checkpoint-data-more" };
    try std.testing.expect(!(try linkIfEqual(io, source, target, &partial, 20)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "target", .{}));
}

const TestStream = struct {
    bytes: []const u8,
    at: usize = 0,

    fn fill(self: *TestStream, dst: []u8) !void {
        @memcpy(dst, self.bytes[self.at..][0..dst.len]);
        self.at += dst.len;
    }
};
