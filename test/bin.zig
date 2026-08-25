const std = @import("std");
const bin = @import("bin");

const testing = std.testing;

/// Test-only custom codec: a little-endian u8 byte-count prefix followed by
/// that many raw bytes.
const TestPrefixed = struct {
    raw: []const u8 = &.{},

    pub fn decode(c: *bin.Cursor) bin.ReadError!TestPrefixed {
        const len = try c.takeInt(u8, .little);
        const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
        return .{ .raw = try alloc.dupe(u8, try c.takeBytes(len)) };
    }

    pub fn encode(self: TestPrefixed, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u8, @intCast(self.raw.len), .little);
        try e.putBytes(self.raw);
    }
};

test "cursor little-endian reads and position" {
    const bytes = [_]u8{ 0x34, 0x12, 0xFE, 0xFF, 0xAA, 0xBB, 0xCC };
    var c = bin.Cursor.init(&bytes);
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .little));
    try testing.expectEqual(@as(i16, -2), try c.takeInt(i16, .little));
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, try c.takeArray(2));
    try testing.expectEqualSlices(u8, &.{0xCC}, try c.takeBytes(1));
    try testing.expect(c.atEnd());
    try testing.expectError(bin.ReadError.UnexpectedEof, c.takeInt(u8, .little));
}

test "cursor big-endian reads" {
    const bytes = [_]u8{ 0x12, 0x34, 0xAB, 0xCD };
    var c = bin.Cursor.init(&bytes);
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .big));
    try testing.expectEqual(@as(i16, -21555), try c.takeInt(i16, .big));
    try testing.expectError(bin.ReadError.UnexpectedEof, c.takeInt(u16, .big));
}

test "cursor seek and range" {
    const bytes = [_]u8{ 10, 20, 30, 40 };
    var c = bin.Cursor.init(&bytes);
    try c.seekBy(2);
    try testing.expectEqual(@as(u8, 30), try c.takeInt(u8, .little));
    try c.seekBy(-3);
    try testing.expectEqual(@as(u8, 10), try c.takeInt(u8, .little));
    try testing.expectEqual(@as(usize, 3), c.remaining());
    try testing.expectEqualSlices(u8, &.{ 20, 30 }, try c.range(1, 3));
    try c.seekTo(4);
    try testing.expect(c.atEnd());
    try testing.expectError(bin.ReadError.UnexpectedEof, c.seekTo(5));
}

test "emitter and cursor roundtrip" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u32, 0xDEAD_BEEF, .little);
    try e.putInt(u16, 0x1234, .little);
    try e.putFloat(f32, 3.5, .little);
    try e.putFloat(f64, -0.25, .little);
    try e.putBytes("rekordlib");
    try e.pad(3);

    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try c.takeInt(u32, .little));
    try testing.expectEqual(@as(u16, 0x1234), try c.takeInt(u16, .little));
    try testing.expectEqual(@as(f32, 3.5), try c.takeFloat(f32, .little));
    try testing.expectEqual(@as(f64, -0.25), try c.takeFloat(f64, .little));
    try testing.expectEqualStrings("rekordlib", try c.takeBytes(9));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, try c.takeBytes(3));
    try testing.expect(c.atEnd());
}

test "little-endian byte order" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u16, 0x1234, .little);
    try e.putInt(u32, 0xABCD_EF01, .little);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x01, 0xEF, 0xCD, 0xAB }, e.written());
}

test "big-endian byte order" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putInt(u16, 0x1234, .big);
    try e.putInt(u32, 0xABCD_EF01, .big);
    try e.putFloat(f32, 1.0, .big);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0xAB, 0xCD, 0xEF, 0x01, 0x3F, 0x80, 0x00, 0x00 }, e.written());
}

test "patchIntAt" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    const at = e.pos();
    try e.putInt(u32, 0, .little);
    try e.putInt(u16, 0xFFFF, .little);
    e.patchIntAt(at, u32, 42, .little);
    e.patchIntAt(at + 2, u16, 0x0102, .big);
    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(@as(u32, 0x0201_002A), try c.takeInt(u32, .little));
    try testing.expectEqual(@as(u16, 0xFFFF), try c.takeInt(u16, .little));
}

test "putBytesAt zero-fills gaps and overwrites" {
    var e = bin.Emitter.init(testing.allocator);
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
    var e = bin.Emitter.init(testing.allocator);
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

    try testing.expectEqual(@as(usize, 6), bin.serializedLen(Sample));
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .kind = @enumFromInt(0x7F) }, .little);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0x7F, 0x34, 0x12 }, e.written());

    var c = bin.Cursor.init(e.written());
    const s = try bin.takeStruct(&c, Sample, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &s.magic);
    try testing.expectEqual(@as(u8, 0x7F), @intFromEnum(s.kind));
    try testing.expectEqual(@as(u16, 0x1234), s.count);

    var e2 = bin.Emitter.init(testing.allocator);
    defer e2.deinit();
    try bin.putStruct(&e2, &s, .little);
    try testing.expectEqualSlices(u8, e.written(), e2.written());
}

test "bin.takeStruct/bin.putStruct walk floats and nested structs" {
    const Inner = struct {
        a: u8 = 0,
        ratio: f32 = 0,
    };
    const Outer = struct {
        prefix: u16 = 0,
        inner: Inner = .{},
        tail: f64 = 0,
    };

    try testing.expectEqual(@as(usize, 15), bin.serializedLen(Outer));
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Outer{ .prefix = 0x0102, .inner = .{ .a = 3, .ratio = 1.5 }, .tail = -2.25 }, .big);

    var c = bin.Cursor.init(e.written());
    const s = try bin.takeStruct(&c, Outer, .big);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 3), s.inner.a);
    try testing.expectEqual(@as(f32, 1.5), s.inner.ratio);
    try testing.expectEqual(@as(f64, -2.25), s.tail);

    var e2 = bin.Emitter.init(testing.allocator);
    defer e2.deinit();
    try bin.putStruct(&e2, &s, .big);
    try testing.expectEqualSlices(u8, e.written(), e2.written());
}

test "bin.takeStruct/bin.putStruct walk packed structs, first field in the low bits" {
    const Bits = packed struct(u8) {
        top: u5 = 0,
        bottom: u3 = 0,
    };
    const Sample = struct {
        a: u8 = 0,
        bits: Bits = .{},
    };

    try testing.expectEqual(@as(usize, 2), bin.serializedLen(Sample));
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .a = 1, .bits = .{ .top = 0b10101, .bottom = 0b110 } }, .big);
    // Zig packs the first field into the least significant bits.
    try testing.expectEqualSlices(u8, &.{ 1, 0b110_10101 }, e.written());

    var c = bin.Cursor.init(e.written());
    const s = try bin.takeStruct(&c, Sample, .big);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u5, 0b10101), s.bits.top);
    try testing.expectEqual(@as(u3, 0b110), s.bits.bottom);

    // Packed structs also serialize standalone, through the same bitcast.
    var c2 = bin.Cursor.init(e.written()[1..]);
    const bits = try bin.takeStruct(&c2, Bits, .big);
    try testing.expect(c2.atEnd());
    try testing.expectEqual(@as(u5, 0b10101), bits.top);
    try testing.expectEqual(@as(u3, 0b110), bits.bottom);
    try testing.expectEqual(@as(usize, 1), bin.serializedLen(Bits));

    var e2 = bin.Emitter.init(testing.allocator);
    defer e2.deinit();
    try bin.putStruct(&e2, bits, .big);
    try testing.expectEqualSlices(u8, e.written()[1..], e2.written());
}

test "bin.takeStruct/bin.putStruct walk u24-backed packed structs" {
    const Bits = packed struct(u24) {
        low: u13 = 0,
        high: u11 = 0,
    };

    try testing.expectEqual(@as(usize, 3), bin.serializedLen(Bits));
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Bits{ .low = 22, .high = 22 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x16, 0xC0, 0x02 }, e.written());

    var c = bin.Cursor.init(e.written());
    const s = try bin.takeStruct(&c, Bits, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u13, 22), s.low);
    try testing.expectEqual(@as(u11, 22), s.high);
}

test "serializedLen counts bare u24 fields at their bit size" {
    const Sample = struct {
        narrow: u24 = 0,
        tag: enum(u24) { a = 1, _ } = .a,
        wide: u16 = 0,
    };

    // The walkers read `intBytes` (bit size / 8), not the padded `@sizeOf`
    // — 3 bytes per u24, not 4.
    try testing.expectEqual(@as(usize, 8), bin.serializedLen(Sample));
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .narrow = 0xABCDEF, .tag = @enumFromInt(2), .wide = 0x0102 }, .big);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD, 0xEF, 0x00, 0x00, 0x02, 0x01, 0x02 }, e.written());

    var c = bin.Cursor.init(e.written());
    const s = try bin.takeStruct(&c, Sample, .big);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u24, 0xABCDEF), s.narrow);
    try testing.expectEqual(@as(u24, 2), @intFromEnum(s.tag));
    try testing.expectEqual(@as(u16, 0x0102), s.wide);
}

test "bin.takeStruct/bin.putStruct delegate to custom codecs" {
    const Sample = struct {
        tag: u8 = 0,
        data: TestPrefixed = .{},
        count: u16 = 0,
    };

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .tag = 7, .data = .{ .raw = "abc" }, .count = 9 }, .little);
    try testing.expectEqualSlices(u8, &.{ 7, 3, 'a', 'b', 'c', 9, 0 }, e.written());

    var c = bin.Cursor.initAlloc(testing.allocator, e.written());
    const s = try bin.takeStruct(&c, Sample, .little);
    defer testing.allocator.free(s.data.raw);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 7), s.tag);
    try testing.expectEqualStrings("abc", s.data.raw);
    try testing.expectEqual(@as(u16, 9), s.count);

    // A codec that needs memory fails without a cursor allocator.
    var bare = bin.Cursor.init(e.written());
    try testing.expectError(bin.ReadError.OutOfMemory, bin.takeStruct(&bare, Sample, .little));
}

test "validateConstantFields" {
    const Sample = struct {
        magic: u32 = 0x1234,
        blob: [2]u8 = .{ 1, 2 },
        spare: u8 = 0,

        pub const constant_fields = .{ .magic, .blob };
    };

    // Listed fields at their defaults pass, regardless of unlisted fields.
    try bin.validateConstantFields(Sample, Sample{});
    try bin.validateConstantFields(Sample, .{ .magic = 0x1234, .blob = .{ 1, 2 }, .spare = 0xFF });
    // Scalar and array deviations are rejected.
    try testing.expectError(error.UnexpectedValue, bin.validateConstantFields(Sample, .{ .magic = 1, .blob = .{ 1, 2 } }));
    try testing.expectError(error.UnexpectedValue, bin.validateConstantFields(Sample, .{ .magic = 0x1234, .blob = .{ 1, 3 } }));
    // Types without the declaration pass untouched.
    try bin.validateConstantFields(struct { spare: u8 = 0 }, .{ .spare = 7 });
}

test "bin.takeStructSlice reads a run of structs" {
    const Sample = struct {
        tag: u8 = 0,
        value: u16 = 0,
    };
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .tag = 1, .value = 0x0203 }, .big);
    try bin.putStruct(&e, Sample{ .tag = 4, .value = 0x0506 }, .big);

    var c = bin.Cursor.init(e.written());
    const items = try bin.takeStructSlice(testing.allocator, &c, Sample, .big, 2);
    defer testing.allocator.free(items);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 1), items[0].tag);
    try testing.expectEqual(@as(u16, 0x0203), items[0].value);
    try testing.expectEqual(@as(u8, 4), items[1].tag);

    // A truncated run fails without leaking the partial slice.
    var short = bin.Cursor.init(e.written()[0..2]);
    try testing.expectError(bin.ReadError.UnexpectedEof, bin.takeStructSlice(testing.allocator, &short, Sample, .big, 2));
}

test "bin.takeStruct/bin.putStruct skip slice fields" {
    const Sample = struct {
        count: u8 = 0,
        items: []const u8 = &.{},
        items2: []u32 = &.{},
        tag: u8 = 0,
    };

    var c = bin.Cursor.init(&.{ 5, 9 });
    const s = try bin.takeStruct(&c, Sample, .little);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 5), s.count);
    try testing.expectEqual(@as(usize, 0), s.items.len);
    try testing.expectEqual(@as(usize, 0), s.items2.len);
    try testing.expectEqual(@as(u8, 9), s.tag);

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, s, .little);
    try testing.expectEqualSlices(u8, &.{ 5, 9 }, e.written());
}
