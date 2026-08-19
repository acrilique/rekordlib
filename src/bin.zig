// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! low-level utils for reading and writing binary formats

const std = @import("std");

pub const ReadError = error{ UnexpectedEof, OutOfMemory };
pub const WriteError = error{OutOfMemory};

pub const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,
    /// Allocator available to custom codecs invoked by `takeStruct`. `null`
    /// unless the cursor was created with `initAlloc`.
    alloc: ?std.mem.Allocator = null,

    pub fn init(buf: []const u8) Cursor {
        return .{ .buf = buf };
    }

    /// Like `init`, but with an allocator that custom codec fields may use to
    /// copy variable-length data out of the buffer.
    pub fn initAlloc(alloc: std.mem.Allocator, buf: []const u8) Cursor {
        return .{ .buf = buf, .alloc = alloc };
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

    pub fn takeInt(c: *Cursor, comptime T: type, comptime endian: std.builtin.Endian) ReadError!T {
        return std.mem.readInt(T, try c.takeArray(intBytes(T)), endian);
    }

    pub fn takeFloat(c: *Cursor, comptime T: type, comptime endian: std.builtin.Endian) ReadError!T {
        const I = std.meta.Int(.unsigned, @bitSizeOf(T));
        return @bitCast(try c.takeInt(I, endian));
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

    pub fn putInt(e: *Emitter, comptime T: type, value: T, comptime endian: std.builtin.Endian) WriteError!void {
        var bytes: [intBytes(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, endian);
        try e.list.appendSlice(e.alloc, &bytes);
    }

    pub fn putFloat(e: *Emitter, comptime T: type, value: T, comptime endian: std.builtin.Endian) WriteError!void {
        const I = std.meta.Int(.unsigned, @bitSizeOf(T));
        try e.putInt(I, @bitCast(value), endian);
    }

    pub fn pad(e: *Emitter, n: usize) WriteError!void {
        const len = e.list.items.len;
        try e.list.resize(e.alloc, len + n);
        @memset(e.list.items[len..], 0);
    }

    pub fn putBytesAt(e: *Emitter, offset: usize, bytes: []const u8) WriteError!void {
        const end = offset + bytes.len;
        if (end > e.list.items.len) try e.pad(end - e.list.items.len);
        @memcpy(e.list.items[offset..end], bytes);
    }

    pub fn patchIntAt(e: *Emitter, offset: usize, comptime T: type, value: T, comptime endian: std.builtin.Endian) void {
        std.debug.assert(offset + @sizeOf(T) <= e.list.items.len);
        std.mem.writeInt(T, e.list.items[offset..][0..@sizeOf(T)], value, endian);
    }
};

/// Returns `true` if `T` declares both `decode` and `encode`, the custom
/// codec contract of `takeStruct`/`putStruct` (see `takeStruct`).
fn hasCodec(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "decode") and @hasDecl(T, "encode"),
        else => false,
    };
}

/// The unsigned integer a packed struct bitcasts through for serialization,
/// restricted to the sizes `std.mem.readInt`/`std.mem.writeInt` support.
fn PackedBacking(comptime T: type) type {
    return switch (@bitSizeOf(T)) {
        8 => u8,
        16 => u16,
        24 => u24,
        32 => u32,
        64 => u64,
        else => @compileError("bin: packed struct fields must be backed by u8/u16/u24/u32/u64, `" ++ @typeName(T) ++ "` is not"),
    };
}

fn isPackedStruct(comptime T: type) bool {
    const ti = @typeInfo(T);
    return ti == .@"struct" and ti.@"struct".layout == .@"packed";
}

/// Serialized byte count of an integer, its bit size in whole bytes — for
/// non-power-of-two ints like `u24` this is smaller than the ABI
/// `@sizeOf`, which includes padding.
fn intBytes(comptime T: type) usize {
    return @divExact(@bitSizeOf(T), 8);
}

/// Reads the fields of `T` in declaration order, at `endian`. Supported field
/// types are:
///
/// * integers and floats
/// * non-exhaustive enums, so that unknown enum values roundtrip verbatim
///   instead of tripping a safety check
/// * `[N]u8` arrays
/// * packed structs backed by u8/u16/u32/u64, bitcast through their backing
///   integer (Zig packs the first declared field into the least significant
///   bits)
/// * plain nested structs, walked recursively
/// * custom codecs: a type declaring both `decode` and `encode` handles its
///   own serialization via `T.decode(c: *Cursor) ReadError!T` and
///   `T.encode(self: T, e: *Emitter) WriteError!void`. Codecs pick their own
///   endianness and may copy memory through `Cursor.alloc` (set up with
///   `Cursor.initAlloc`); a codec that needs an allocator while `alloc` is
///   `null` fails with `error.OutOfMemory`.
/// * slices, which are skipped and left at their default value:
///   variable-length data is owned by the containing type's parse and write
///   logic. For that reason `T` and any nested struct types must have field
///   defaults.
pub fn takeStruct(c: *Cursor, comptime T: type, comptime endian: std.builtin.Endian) ReadError!T {
    if (comptime isPackedStruct(T)) {
        return @bitCast(try c.takeInt(PackedBacking(T), endian));
    }
    var out: T = .{};
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime hasCodec(field.type)) {
            @field(out, field.name) = try field.type.decode(c);
        } else switch (@typeInfo(field.type)) {
            .int => @field(out, field.name) = try c.takeInt(field.type, endian),
            .float => {
                const I = std.meta.Int(.unsigned, @bitSizeOf(field.type));
                @field(out, field.name) = @bitCast(try c.takeInt(I, endian));
            },
            .@"enum" => |e| {
                if (e.is_exhaustive) @compileError("takeStruct: enum fields must be non-exhaustive, `" ++ @typeName(field.type) ++ "` is not");
                @field(out, field.name) = @enumFromInt(try c.takeInt(e.tag_type, endian));
            },
            .array => |a| {
                if (a.child != u8) @compileError("takeStruct: array fields must be `[N]u8`, `" ++ @typeName(field.type) ++ "` is not");
                @field(out, field.name) = (try c.takeArray(a.len)).*;
            },
            .@"struct" => |s| {
                if (s.layout == .@"packed") {
                    @field(out, field.name) = @bitCast(try c.takeInt(PackedBacking(field.type), endian));
                } else {
                    @field(out, field.name) = try takeStruct(c, field.type, endian);
                }
            },
            .pointer => |p| {
                if (p.size == .slice) continue;
                @compileError("takeStruct: unsupported field type `" ++ @typeName(field.type) ++ "`");
            },
            else => @compileError("takeStruct: unsupported field type `" ++ @typeName(field.type) ++ "`"),
        }
    }
    return out;
}

/// Writes the fields of `value` in declaration order at `endian`, the mirror
/// image of `takeStruct` (whose documentation lists the supported field
/// types, including the custom codec contract). `value` may be passed by
/// value or as a pointer.
pub fn putStruct(e: *Emitter, value: anytype, comptime endian: std.builtin.Endian) WriteError!void {
    const T = switch (@typeInfo(@TypeOf(value))) {
        .pointer => |p| p.child,
        else => @TypeOf(value),
    };
    if (comptime isPackedStruct(T)) {
        const v: T = switch (@typeInfo(@TypeOf(value))) {
            .pointer => value.*,
            else => value,
        };
        return e.putInt(PackedBacking(T), @bitCast(v), endian);
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime hasCodec(field.type)) {
            try @field(value, field.name).encode(e);
        } else switch (@typeInfo(field.type)) {
            .int => try e.putInt(field.type, @field(value, field.name), endian),
            .float => try e.putFloat(field.type, @field(value, field.name), endian),
            .@"enum" => |en| try e.putInt(en.tag_type, @intFromEnum(@field(value, field.name)), endian),
            .array => |a| {
                if (a.child != u8) @compileError("putStruct: array fields must be `[N]u8`, `" ++ @typeName(field.type) ++ "` is not");
                try e.putBytes(&@field(value, field.name));
            },
            .@"struct" => |s| {
                if (s.layout == .@"packed") {
                    try e.putInt(PackedBacking(field.type), @bitCast(@field(value, field.name)), endian);
                } else {
                    try putStruct(e, @field(value, field.name), endian);
                }
            },
            .pointer => |p| {
                if (p.size == .slice) continue;
                @compileError("putStruct: unsupported field type `" ++ @typeName(field.type) ++ "`");
            },
            else => @compileError("putStruct: unsupported field type `" ++ @typeName(field.type) ++ "`"),
        }
    }
}

/// Reads `n` elements of `T` in declaration order at `endian` (see
/// `takeStruct` for the supported field types), allocating the returned
/// slice with `alloc`; the caller owns it. The partial slice is freed if any
/// element fails to read.
pub fn takeStructSlice(alloc: std.mem.Allocator, c: *Cursor, comptime T: type, comptime endian: std.builtin.Endian, n: usize) ReadError![]T {
    const out = try alloc.alloc(T, n);
    errdefer alloc.free(out);
    for (out) |*item| item.* = try takeStruct(c, T, endian);
    return out;
}

/// Number of bytes `takeStruct`/`putStruct` read/write for `T`. Structs with
/// slice fields (variable length) or codec fields (data-dependent length)
/// have no fixed size and fail to compile.
pub fn serializedLen(comptime T: type) usize {
    return comptime blk: {
        if (isPackedStruct(T)) break :blk intBytes(PackedBacking(T));
        var len: usize = 0;
        for (@typeInfo(T).@"struct".fields) |field| {
            if (hasCodec(field.type))
                @compileError("serializedLen: codec fields have a data-dependent length, `" ++ @typeName(T) ++ "." ++ field.name ++ "`");
            switch (@typeInfo(field.type)) {
                .int => len += @sizeOf(field.type),
                .float => len += @sizeOf(field.type),
                .@"enum" => |en| len += @sizeOf(en.tag_type),
                .array => |a| {
                    if (a.child != u8) @compileError("serializedLen: array fields must be `[N]u8`, `" ++ @typeName(field.type) ++ "` is not");
                    len += a.len;
                },
                .@"struct" => |s| {
                    if (s.layout == .@"packed") {
                        len += intBytes(PackedBacking(field.type));
                    } else {
                        len += serializedLen(field.type);
                    }
                },
                .pointer => |p| {
                    if (p.size == .slice)
                        @compileError("serializedLen: slice fields have a variable length, `" ++ @typeName(T) ++ "." ++ field.name ++ "`");
                    @compileError("serializedLen: unsupported field type `" ++ @typeName(field.type) ++ "`");
                },
                else => @compileError("serializedLen: unsupported field type `" ++ @typeName(field.type) ++ "`"),
            }
        }
        break :blk len;
    };
}

/// Checks the fields listed in `T.constant_fields` (an anonymous struct
/// listing field names, e.g. `.{ .magic, .checksum }`) against their default
/// values, which they must hold in all known files; other values are
/// rejected with `error.UnexpectedValue`. Fields not listed are accepted and
/// written verbatim. A `T` without a `constant_fields` declaration passes
/// as-is.
pub fn validateConstantFields(comptime T: type, value: T) error{UnexpectedValue}!void {
    if (!@hasDecl(T, "constant_fields")) return;
    const defaults = T{};
    inline for (T.constant_fields) |field| {
        const name = @tagName(field);
        if (!@hasField(T, name))
            @compileError("constant_fields of " ++ @typeName(T) ++ " reference unknown field '" ++ name ++ "'");
        switch (@typeInfo(@TypeOf(@field(value, name)))) {
            .array => if (!std.mem.eql(u8, &@field(value, name), &@field(defaults, name))) return error.UnexpectedValue,
            else => if (@field(value, name) != @field(defaults, name)) return error.UnexpectedValue,
        }
    }
}

const testing = std.testing;

/// Test-only custom codec: a little-endian u8 byte-count prefix followed by
/// that many raw bytes.
const TestPrefixed = struct {
    raw: []const u8 = &.{},

    pub fn decode(c: *Cursor) ReadError!TestPrefixed {
        const len = try c.takeInt(u8, .little);
        const alloc = c.alloc orelse return ReadError.OutOfMemory;
        return .{ .raw = try alloc.dupe(u8, try c.takeBytes(len)) };
    }

    pub fn encode(self: TestPrefixed, e: *Emitter) WriteError!void {
        try e.putInt(u8, @intCast(self.raw.len), .little);
        try e.putBytes(self.raw);
    }
};

test "cursor little-endian reads and position" {
    const bytes = [_]u8{ 0x34, 0x12, 0xFE, 0xFF, 0xAA, 0xBB, 0xCC };
    var c = Cursor.init(&bytes);
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .little));
    try testing.expectEqual(@as(i16, -2), try c.takeInt(i16, .little));
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, try c.takeArray(2));
    try testing.expectEqualSlices(u8, &.{0xCC}, try c.takeBytes(1));
    try testing.expect(c.atEnd());
    try testing.expectError(ReadError.UnexpectedEof, c.takeInt(u8, .little));
}

test "cursor big-endian reads" {
    const bytes = [_]u8{ 0x12, 0x34, 0xAB, 0xCD };
    var c = Cursor.init(&bytes);
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .big));
    try testing.expectEqual(@as(i16, -21555), try c.takeInt(i16, .big));
    try testing.expectError(ReadError.UnexpectedEof, c.takeInt(u16, .big));
}

test "cursor seek and range" {
    const bytes = [_]u8{ 10, 20, 30, 40 };
    var c = Cursor.init(&bytes);
    try c.seekBy(2);
    try testing.expectEqual(@as(u8, 30), try c.takeInt(u8, .little));
    try c.seekBy(-3);
    try testing.expectEqual(@as(u8, 10), try c.takeInt(u8, .little));
    try testing.expectEqual(@as(usize, 3), c.remaining());
    try testing.expectEqualSlices(u8, &.{ 20, 30 }, try c.range(1, 3));
    try c.seekTo(4);
    try testing.expect(c.atEnd());
    try testing.expectError(ReadError.UnexpectedEof, c.seekTo(5));
}

test "emitter and cursor roundtrip" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u32, 0xDEAD_BEEF, .little);
    try e.putInt(u16, 0x1234, .little);
    try e.putFloat(f32, 3.5, .little);
    try e.putFloat(f64, -0.25, .little);
    try e.putBytes("rekordlib");
    try e.pad(3);

    var c = Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try c.takeInt(u32, .little));
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .little));
    try testing.expectEqual(@as(f32, 3.5), try c.takeFloat(f32, .little));
    try testing.expectEqual(@as(f64, -0.25), try c.takeFloat(f64, .little));
    try testing.expectEqualStrings("rekordlib", try c.takeBytes(9));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, try c.takeBytes(3));
    try testing.expect(c.atEnd());
}

test "little-endian byte order" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u16, 0x1234, .little);
    try e.putInt(u32, 0xABCD_EF01, .little);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x01, 0xEF, 0xCD, 0xAB }, e.written());
}

test "big-endian byte order" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u16, 0x1234, .big);
    try e.putInt(u32, 0xABCD_EF01, .big);
    try e.putFloat(f32, 1.0, .big);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xAB, 0xCD, 0xEF, 0x01, 0x3F, 0x80, 0x00, 0x00 }, e.written());
}

test "patchIntAt" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    const at = e.pos();
    try e.putInt(u32, 0, .little);
    try e.putInt(u16, 0xFFFF, .little);
    e.patchIntAt(at, u32, 42, .little);
    e.patchIntAt(at + 2, u16, 0x0102, .big);
    var c = Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 0x0201_002A), try c.takeInt(u32, .little));
    try testing.expectEqual(@as(u16, 0xFFFF), try c.takeInt(u16, .little));
}

test "putBytesAt zero-fills gaps and overwrites" {
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putBytes(&.{ 1, 2, 3 });
    // Past the end: the gap becomes zeros.
    try e.putBytesAt(6, &.{ 7, 8 });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 0, 0, 7, 8 }, e.written());
    // Within the written range: existing bytes are replaced.
    try e.putBytesAt(1, &.{9});
    try testing.expectEqualSlices(u8, &.{ 1, 9, 3, 0, 0, 0, 7, 8 }, e.written());
}

test "emitter toOwnedSlice" {
    var e = Emitter.init(testing.allocator);
    try e.putInt(u8, 7, .little);
    const out = try e.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{7}, out);
}

test "takeStruct, putStruct and serializedLen roundtrip" {
    const Sample = struct {
        magic: [3]u8 = .{ 1, 2, 3 },
        kind: enum(u8) { a = 1, b = 2, _ } = .a,
        count: u16 = 0x1234,
    };

    try testing.expectEqual(@as(usize, 6), serializedLen(Sample));
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Sample{ .kind = @enumFromInt(0x7F) }, .little);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0x7F, 0x34, 0x12 }, e.written());

    var c = Cursor.init(e.written());
    const s = try takeStruct(&c, Sample, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &s.magic);
    try testing.expectEqual(@as(u8, 0x7F), @intFromEnum(s.kind));
    try testing.expectEqual(@as(u16, 0x1234), s.count);

    var e2 = Emitter.init(testing.allocator);
    defer e2.deinit();
    try putStruct(&e2, &s, .little);
    try testing.expectEqualSlices(u8, e.written(), e2.written());
}

test "takeStruct/putStruct walk floats and nested structs" {
    const Inner = struct {
        a: u8 = 0,
        ratio: f32 = 0,
    };
    const Outer = struct {
        prefix: u16 = 0,
        inner: Inner = .{},
        tail: f64 = 0,
    };

    try testing.expectEqual(@as(usize, 15), serializedLen(Outer));
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Outer{ .prefix = 0x0102, .inner = .{ .a = 3, .ratio = 1.5 }, .tail = -2.25 }, .big);

    var c = Cursor.init(e.written());
    const s = try takeStruct(&c, Outer, .big);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 3), s.inner.a);
    try testing.expectEqual(@as(f32, 1.5), s.inner.ratio);
    try testing.expectEqual(@as(f64, -2.25), s.tail);

    var e2 = Emitter.init(testing.allocator);
    defer e2.deinit();
    try putStruct(&e2, &s, .big);
    try testing.expectEqualSlices(u8, e.written(), e2.written());
}

test "takeStruct/putStruct walk packed structs, first field in the low bits" {
    const Bits = packed struct(u8) {
        top: u5 = 0,
        bottom: u3 = 0,
    };
    const Sample = struct {
        a: u8 = 0,
        bits: Bits = .{},
    };

    try testing.expectEqual(@as(usize, 2), serializedLen(Sample));
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Sample{ .a = 1, .bits = .{ .top = 0b10101, .bottom = 0b110 } }, .big);
    // Zig packs the first field into the least significant bits.
    try testing.expectEqualSlices(u8, &.{ 1, 0b110_10101 }, e.written());

    var c = Cursor.init(e.written());
    const s = try takeStruct(&c, Sample, .big);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u5, 0b10101), s.bits.top);
    try testing.expectEqual(@as(u3, 0b110), s.bits.bottom);

    // Packed structs also serialize standalone, through the same bitcast.
    var c2 = Cursor.init(e.written()[1..]);
    const bits = try takeStruct(&c2, Bits, .big);
    try testing.expect(c2.atEnd());
    try testing.expectEqual(@as(u5, 0b10101), bits.top);
    try testing.expectEqual(@as(u3, 0b110), bits.bottom);
    try testing.expectEqual(@as(usize, 1), serializedLen(Bits));

    var e2 = Emitter.init(testing.allocator);
    defer e2.deinit();
    try putStruct(&e2, bits, .big);
    try testing.expectEqualSlices(u8, e.written()[1..], e2.written());
}

test "takeStruct/putStruct walk u24-backed packed structs" {
    const Bits = packed struct(u24) {
        low: u13 = 0,
        high: u11 = 0,
    };

    try testing.expectEqual(@as(usize, 3), serializedLen(Bits));
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Bits{ .low = 22, .high = 22 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x16, 0xC0, 0x02 }, e.written());

    var c = Cursor.init(e.written());
    const s = try takeStruct(&c, Bits, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u13, 22), s.low);
    try testing.expectEqual(@as(u11, 22), s.high);
}

test "takeStruct/putStruct delegate to custom codecs" {
    const Sample = struct {
        tag: u8 = 0,
        data: TestPrefixed = .{},
        count: u16 = 0,
    };

    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Sample{ .tag = 7, .data = .{ .raw = "abc" }, .count = 9 }, .little);
    try testing.expectEqualSlices(u8, &.{ 7, 3, 'a', 'b', 'c', 9, 0 }, e.written());

    var c = Cursor.initAlloc(testing.allocator, e.written());
    const s = try takeStruct(&c, Sample, .little);
    defer testing.allocator.free(s.data.raw);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 7), s.tag);
    try testing.expectEqualStrings("abc", s.data.raw);
    try testing.expectEqual(@as(u16, 9), s.count);

    // A codec that needs memory fails without a cursor allocator.
    var bare = Cursor.init(e.written());
    try testing.expectError(ReadError.OutOfMemory, takeStruct(&bare, Sample, .little));
}

test "validateConstantFields" {
    const Sample = struct {
        magic: u32 = 0x1234,
        blob: [2]u8 = .{ 1, 2 },
        spare: u8 = 0,

        pub const constant_fields = .{ .magic, .blob };
    };

    // Listed fields at their defaults pass, regardless of unlisted fields.
    try validateConstantFields(Sample, Sample{});
    try validateConstantFields(Sample, .{ .magic = 0x1234, .blob = .{ 1, 2 }, .spare = 0xFF });
    // Scalar and array deviations are rejected.
    try testing.expectError(error.UnexpectedValue, validateConstantFields(Sample, .{ .magic = 1, .blob = .{ 1, 2 } }));
    try testing.expectError(error.UnexpectedValue, validateConstantFields(Sample, .{ .magic = 0x1234, .blob = .{ 1, 3 } }));
    // Types without the declaration pass untouched.
    try validateConstantFields(struct { spare: u8 = 0 }, .{ .spare = 7 });
}

test "takeStructSlice reads a run of structs" {
    const Sample = struct {
        tag: u8 = 0,
        value: u16 = 0,
    };
    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, Sample{ .tag = 1, .value = 0x0203 }, .big);
    try putStruct(&e, Sample{ .tag = 4, .value = 0x0506 }, .big);

    var c = Cursor.init(e.written());
    const items = try takeStructSlice(testing.allocator, &c, Sample, .big, 2);
    defer testing.allocator.free(items);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 1), items[0].tag);
    try testing.expectEqual(@as(u16, 0x0203), items[0].value);
    try testing.expectEqual(@as(u8, 4), items[1].tag);

    // A truncated run fails without leaking the partial slice.
    var short = Cursor.init(e.written()[0..2]);
    try testing.expectError(ReadError.UnexpectedEof, takeStructSlice(testing.allocator, &short, Sample, .big, 2));
}

test "takeStruct/putStruct skip slice fields" {
    const Sample = struct {
        count: u8 = 0,
        items: []const u8 = &.{},
        items2: []u32 = &.{},
        tag: u8 = 0,
    };

    var c = Cursor.init(&.{ 5, 9 });
    const s = try takeStruct(&c, Sample, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 5), s.count);
    try testing.expectEqual(@as(usize, 0), s.items.len);
    try testing.expectEqual(@as(usize, 0), s.items2.len);
    try testing.expectEqual(@as(u8, 9), s.tag);

    var e = Emitter.init(testing.allocator);
    defer e.deinit();
    try putStruct(&e, s, .little);
    try testing.expectEqualSlices(u8, &.{ 5, 9 }, e.written());
}
