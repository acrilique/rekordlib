const std = @import("std");

pub const ReadError = error{UnexpectedEof};
pub const WriteError = error{OutOfMemory};

pub const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Cursor {
        return .{ .buf = buf };
    }

    pub fn seekTo(c: *Cursor, pos: usize) ReadError!void {
        if (pos > c.buf.len) return ReadError.UnexpectedEof;
        c.pos = pos;
    }

    pub fn seekBy(c: *Cursor, delta: i64) ReadError!void {
        if (delta < 0) {
            const back = @abs(delta);
            if (back > c.pos) return ReadError.UnexpectedEof;
            c.pos -= @intCast(back);
        } else {
            const fwd: usize = @intCast(delta);
            if (fwd > c.remaining()) return ReadError.UnexpectedEof;
            c.pos += fwd;
        }
    }

    pub fn remaining(c: *const Cursor) usize {
        return c.buf.len - c.pos;
    }

    pub fn atEnd(c: *const Cursor) bool {
        return c.pos == c.buf.len;
    }

    pub fn range(c: *const Cursor, start: usize, end: usize) ReadError![]const u8 {
        if (start > end or end > c.buf.len) return ReadError.UnexpectedEof;
        return c.buf[start..end];
    }

    pub fn takeArray(c: *Cursor, comptime n: usize) ReadError!*const [n]u8 {
        if (c.pos + n > c.buf.len) return ReadError.UnexpectedEof;
        defer c.pos += n;
        return c.buf[c.pos..][0..n];
    }

    pub fn takeBytes(c: *Cursor, n: usize) ReadError![]const u8 {
        if (n > c.remaining()) return ReadError.UnexpectedEof;
        defer c.pos += n;
        return c.buf[c.pos..][0..n];
    }

    pub fn takeInt(c: *Cursor, comptime T: type) ReadError!T {
        return std.mem.readInt(T, try c.takeArray(@sizeOf(T)), .little);
    }

    pub fn takeFloat(c: *Cursor, comptime T: type) ReadError!T {
        const I = std.meta.Int(.unsigned, @bitSizeOf(T));
        return @bitCast(try c.takeInt(I));
    }
};

pub const Emitter = struct {
    list: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Emitter {
        return .{ .alloc = alloc };
    }

    pub fn deinit(e: *Emitter) void {
        e.list.deinit(e.alloc);
    }

    pub fn pos(e: *const Emitter) usize {
        return e.list.items.len;
    }

    pub fn written(e: *const Emitter) []const u8 {
        return e.list.items;
    }

    pub fn toOwnedSlice(e: *Emitter) WriteError![]u8 {
        return e.list.toOwnedSlice(e.alloc);
    }

    pub fn putBytes(e: *Emitter, bytes: []const u8) WriteError!void {
        try e.list.appendSlice(e.alloc, bytes);
    }

    pub fn putInt(e: *Emitter, comptime T: type, value: T) WriteError!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try e.list.appendSlice(e.alloc, &bytes);
    }

    pub fn putFloat(e: *Emitter, comptime T: type, value: T) WriteError!void {
        const I = std.meta.Int(.unsigned, @bitSizeOf(T));
        try e.putInt(I, @bitCast(value));
    }

    pub fn pad(e: *Emitter, n: usize) WriteError!void {
        const len = e.list.items.len;
        try e.list.resize(e.alloc, len + n);
        @memset(e.list.items[len..], 0);
    }

    pub fn patchIntAt(e: *Emitter, offset: usize, comptime T: type, value: T) void {
        std.debug.assert(offset + @sizeOf(T) <= e.list.items.len);
        std.mem.writeInt(T, e.list.items[offset..][0..@sizeOf(T)], value, .little);
    }
};

const testing = std.testing;

test "cursor little-endian reads and position" {
    const bytes = [_]u8{ 0x34, 0x12, 0xFE, 0xFF, 0xAA, 0xBB, 0xCC };
    var c = Cursor.init(&bytes);
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16));
    try testing.expectEqual(@as(i16, -2), try c.takeInt(i16));
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, try c.takeArray(2));
    try testing.expectEqualSlices(u8, &.{0xCC}, try c.takeBytes(1));
    try testing.expect(c.atEnd());
    try testing.expectError(ReadError.UnexpectedEof, c.takeInt(u8));
}

test "cursor seek and range" {
    const bytes = [_]u8{ 10, 20, 30, 40 };
    var c = Cursor.init(&bytes);
    try c.seekBy(2);
    try testing.expectEqual(@as(u8, 30), try c.takeInt(u8));
    try c.seekBy(-3);
    try testing.expectEqual(@as(u8, 10), try c.takeInt(u8));
    try testing.expectEqual(@as(usize, 3), c.remaining());
    try testing.expectEqualSlices(u8, &.{ 20, 30 }, try c.range(1, 3));
    try c.seekTo(4);
    try testing.expect(c.atEnd());
    try testing.expectError(ReadError.UnexpectedEof, c.seekTo(5));
}

test "emitter and cursor roundtrip" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u32, 0xDEAD_BEEF);
    try e.putInt(u16, 0x1234);
    try e.putFloat(f32, 3.5);
    try e.putFloat(f64, -0.25);
    try e.putBytes("rekordlib");
    try e.pad(3);

    var c = Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try c.takeInt(u32));
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16));
    try testing.expectEqual(@as(f32, 3.5), try c.takeFloat(f32));
    try testing.expectEqual(@as(f64, -0.25), try c.takeFloat(f64));
    try testing.expectEqualStrings("rekordlib", try c.takeBytes(9));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, try c.takeBytes(3));
    try testing.expect(c.atEnd());
}

test "little-endian byte order" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u16, 0x1234);
    try e.putInt(u32, 0xABCD_EF01);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x01, 0xEF, 0xCD, 0xAB }, e.written());
}

test "patchIntAt" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    const at = e.pos();
    try e.putInt(u32, 0);
    try e.putInt(u16, 0xFFFF);
    e.patchIntAt(at, u32, 42);
    var c = Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 42), try c.takeInt(u32));
    try testing.expectEqual(@as(u16, 0xFFFF), try c.takeInt(u16));
}

test "emitter toOwnedSlice" {
    var e = Emitter.init(testing.allocator);
    try e.putInt(u8, 7);
    const out = try e.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{7}, out);
}
