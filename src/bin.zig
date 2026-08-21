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

    /// Discards the written bytes while keeping the buffer's capacity, for
    /// serializing many values through one emitter.
    pub fn clear(e: *Emitter) void {
        e.list.clearRetainingCapacity();
    }

    pub fn toOwnedSlice(e: *Emitter) WriteError![]u8 {
        return e.list.toOwnedSlice(e.alloc);
    }

    /// Reserves room for `n` bytes in total, so an output of known size can
    /// be written without intermediate reallocations and the copies they
    /// cause.
    pub fn ensureTotalCapacity(e: *Emitter, n: usize) WriteError!void {
        try e.list.ensureTotalCapacity(e.alloc, n);
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
/// element fails to read. Runs whose `n` elements cannot fit the remaining
/// input fail with `UnexpectedEof` before anything is allocated, so
/// attacker-controlled counts cannot amplify into oversized allocations.
pub fn takeStructSlice(alloc: std.mem.Allocator, c: *Cursor, comptime T: type, comptime endian: std.builtin.Endian, n: usize) ReadError![]T {
    const elem_len = comptime serializedLen(T);
    const run_len: u64 = @as(u64, n) * elem_len;
    if (run_len > c.remaining()) return ReadError.UnexpectedEof;
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
