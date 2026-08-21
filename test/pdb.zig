const std = @import("std");
const pdb = @import("pdb");
const bin = @import("bin");
const util = @import("util");
const testutil = @import("util.zig");

const testing = std.testing;

/// Mirrors rekordcrate's `test_roundtrip`: parses `bytes` expecting
/// `expected` and full consumption, re-encodes `expected` expecting `bytes`
/// back, and checks `heapBytesRequired` against the serialized length.
fn expectRoundtrip(bytes: []const u8, expected: pdb.DeviceSQLString) !void {
    var c = bin.Cursor.initAlloc(testing.allocator, bytes);
    var parsed = try pdb.DeviceSQLString.decode(&c);
    defer parsed.deinit(testing.allocator);
    try testing.expect(c.atEnd());
    try testing.expect(expected.eql(parsed));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try expected.encode(&e);
    try testing.expectEqualSlices(u8, bytes, e.written());

    try testing.expectEqual(
        @as(u16, @intCast(bytes.len)),
        expected.heapBytesRequired(),
    );
}

/// Builds `text` with `fromUtf8`, roundtrips it against `serialized`, and
/// checks that `utf8` returns `text`.
fn expectUtf8Roundtrip(text: []const u8, serialized: []const u8) !void {
    var s = try pdb.DeviceSQLString.fromUtf8(testing.allocator, text);
    defer s.deinit(testing.allocator);
    try expectRoundtrip(serialized, s);

    const out = try s.utf8(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "empty string is the single byte 0x03" {
    try expectRoundtrip(&.{0x03}, pdb.DeviceSQLString.empty());

    var from_utf8 = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "");
    defer from_utf8.deinit(testing.allocator);
    try expectRoundtrip(&.{0x03}, from_utf8);
    try testing.expect(pdb.DeviceSQLString.empty().eql(from_utf8));
}

test "short ascii string roundtrips" {
    try expectUtf8Roundtrip("foo", &.{ 0x09, 0x66, 0x6F, 0x6F });
}

test "long ascii string roundtrips" {
    const long_string = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliqu";
    const long_string_serialized = [_]u8{
        0x40, 0x83, 0x00, 0x00, 0x4C, 0x6F, 0x72, 0x65, 0x6D, 0x20, 0x69, 0x70, 0x73, 0x75,
        0x6D, 0x20, 0x64, 0x6F, 0x6C, 0x6F, 0x72, 0x20, 0x73, 0x69, 0x74, 0x20, 0x61, 0x6D,
        0x65, 0x74, 0x2C, 0x20, 0x63, 0x6F, 0x6E, 0x73, 0x65, 0x74, 0x65, 0x74, 0x75, 0x72,
        0x20, 0x73, 0x61, 0x64, 0x69, 0x70, 0x73, 0x63, 0x69, 0x6E, 0x67, 0x20, 0x65, 0x6C,
        0x69, 0x74, 0x72, 0x2C, 0x20, 0x73, 0x65, 0x64, 0x20, 0x64, 0x69, 0x61, 0x6D, 0x20,
        0x6E, 0x6F, 0x6E, 0x75, 0x6D, 0x79, 0x20, 0x65, 0x69, 0x72, 0x6D, 0x6F, 0x64, 0x20,
        0x74, 0x65, 0x6D, 0x70, 0x6F, 0x72, 0x20, 0x69, 0x6E, 0x76, 0x69, 0x64, 0x75, 0x6E,
        0x74, 0x20, 0x75, 0x74, 0x20, 0x6C, 0x61, 0x62, 0x6F, 0x72, 0x65, 0x20, 0x65, 0x74,
        0x20, 0x64, 0x6F, 0x6C, 0x6F, 0x72, 0x65, 0x20, 0x6D, 0x61, 0x67, 0x6E, 0x61, 0x20,
        0x61, 0x6C, 0x69, 0x71, 0x75,
    };
    try expectUtf8Roundtrip(long_string, &long_string_serialized);
}

test "non-ascii string roundtrips as ucs2le" {
    try expectUtf8Roundtrip("I ❤ Rust", &.{
        0x90, 0x14, 0x00, 0x00, 0x49, 0x00, 0x20, 0x00, 0x64, 0x27, 0x20, 0x00, 0x52, 0x00,
        0x75, 0x00, 0x73, 0x00, 0x74, 0x00,
    });
}

test "too long string is rejected" {
    const humongous = [_]u8{'A'} ** 65536;
    try testing.expectError(
        error.TooLong,
        pdb.DeviceSQLString.fromUtf8(testing.allocator, &humongous),
    );
}

test "mixed charset is rejected once its encoded body outgrows u16" {
    const alloc = testing.allocator;

    // 32765 ASCII chars plus one 2-byte char pass the UTF-8 cap (32767
    // bytes) but encode to 32766 units — 65532 body bytes plus the 4
    // header bytes overflow u16.
    var text: [32767]u8 = undefined;
    @memset(&text, 'a');
    text[32765] = 0xC3; // "é", two UTF-8 bytes
    text[32766] = 0xA9;
    try testing.expectError(
        error.TooLong,
        pdb.DeviceSQLString.fromUtf8(alloc, &text),
    );

    // One ASCII char less the encoded form fits exactly: 32765 units,
    // 65530 body bytes, 65534 with the header.
    var max_mixed = try pdb.DeviceSQLString.fromUtf8(alloc, text[1..]);
    defer max_mixed.deinit(alloc);
    try testing.expect(std.meta.activeTag(max_mixed.long) == .ucs2le);
    try testing.expectEqual(
        @as(u16, std.math.maxInt(u16) - 1),
        max_mixed.heapBytesRequired(),
    );
}

test "isrc strings roundtrip" {
    var s = try pdb.DeviceSQLString.fromIsrc(testing.allocator, "GBAYE6700149");
    defer s.deinit(testing.allocator);
    try expectRoundtrip(&.{
        0x90, 0x12, 0x00, 0x00, 0x03, 0x47, 0x42, 0x41, 0x59, 0x45, 0x36, 0x37, 0x30, 0x30,
        0x31, 0x34, 0x39, 0x00,
    }, s);

    // An empty ISRC becomes the regular empty string.
    var empty_isrc = try pdb.DeviceSQLString.fromIsrc(testing.allocator, "");
    defer empty_isrc.deinit(testing.allocator);
    try expectRoundtrip(&.{0x03}, empty_isrc);

    // Anything but 12 ASCII characters is rejected.
    try testing.expectError(
        error.InvalidIsrc,
        pdb.DeviceSQLString.fromIsrc(testing.allocator, "non-conforming garbage"),
    );
    try testing.expectError(
        error.InvalidIsrc,
        pdb.DeviceSQLString.fromIsrc(testing.allocator, "ÉBCDEFGHIJK"),
    );
    // A NUL byte is ASCII but would not survive the roundtrip.
    try testing.expectError(
        error.InvalidIsrc,
        pdb.DeviceSQLString.fromIsrc(testing.allocator, "A\x00AAAAAAAAAA"),
    );

    const text = try s.utf8(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("GBAYE6700149", text);
}

test "fromUtf8 picks the form by charset and length" {
    const alloc = testing.allocator;

    var ascii: [127]u8 = undefined;
    @memset(&ascii, 'a');

    // 126 ASCII bytes still fit the short form, 127 go long.
    var short_max = try pdb.DeviceSQLString.fromUtf8(alloc, ascii[0..126]);
    defer short_max.deinit(alloc);
    try testing.expect(std.meta.activeTag(short_max) == .short_ascii);

    var long_min = try pdb.DeviceSQLString.fromUtf8(alloc, ascii[0..]);
    defer long_min.deinit(alloc);
    try testing.expect(std.meta.activeTag(long_min) == .long);
    try testing.expect(std.meta.activeTag(long_min.long) == .ascii);

    // Non-ASCII always takes the long form, as UCS-2LE.
    var ucs2 = try pdb.DeviceSQLString.fromUtf8(alloc, "é");
    defer ucs2.deinit(alloc);
    try testing.expect(std.meta.activeTag(ucs2) == .long);
    try testing.expect(std.meta.activeTag(ucs2.long) == .ucs2le);

    // 32767 UTF-8 bytes still pass, 32768 are too long.
    var big: [32768]u8 = undefined;
    @memset(&big, 'a');
    var max = try pdb.DeviceSQLString.fromUtf8(alloc, big[0 .. big.len - 1]);
    defer max.deinit(alloc);
    try testing.expectError(
        error.TooLong,
        pdb.DeviceSQLString.fromUtf8(alloc, &big),
    );

    // Invalid UTF-8 is rejected without reaching the encoder.
    try testing.expectError(
        error.InvalidEncoding,
        pdb.DeviceSQLString.fromUtf8(alloc, &[_]u8{0xFF}),
    );
}

test "eql distinguishes different strings" {
    const alloc = testing.allocator;

    // Same length, different content.
    var foo = try pdb.DeviceSQLString.fromUtf8(alloc, "foo");
    defer foo.deinit(alloc);
    var bar = try pdb.DeviceSQLString.fromUtf8(alloc, "bar");
    defer bar.deinit(alloc);
    try testing.expect(!foo.eql(bar));

    // Different lengths.
    var fo = try pdb.DeviceSQLString.fromUtf8(alloc, "fo");
    defer fo.deinit(alloc);
    try testing.expect(!foo.eql(fo));

    // Same content, different form.
    const long_foo: pdb.DeviceSQLString = .{ .long = .{ .ascii = "foo" } };
    try testing.expect(!foo.eql(long_foo));

    // Same long-form tag, different content.
    const long_bar: pdb.DeviceSQLString = .{ .long = .{ .ascii = "bar" } };
    try testing.expect(!long_foo.eql(long_bar));
}

test "flags 0x90 dispatches isrc before ucs2le" {
    const alloc = testing.allocator;

    // 0x03 'A' 'B' 0x00 would also read as valid UCS-2LE ([0x4103,
    // 0x0042]), but the ISRC shape claims it because it is tried first.
    {
        const s: pdb.DeviceSQLString = .{ .long = .{ .isrc = "AB" } };
        try expectRoundtrip(&.{ 0x90, 0x08, 0x00, 0x00, 0x03, 'A', 'B', 0x00 }, s);
    }

    // An interior NUL breaks the ISRC shape, so the same leading 0x03
    // becomes the UCS-2LE code unit U+0003.
    {
        const bytes = [_]u8{ 0x90, 0x08, 0x00, 0x00, 0x03, 0x00, 'A', 0x00 };
        var c = bin.Cursor.initAlloc(alloc, &bytes);
        var s = try pdb.DeviceSQLString.decode(&c);
        defer s.deinit(alloc);
        try testing.expect(std.meta.activeTag(s.long) == .ucs2le);
        try expectRoundtrip(&bytes, s);
        const text = try s.utf8(alloc);
        defer alloc.free(text);
        try testing.expectEqualStrings("\u{3}A", text);
    }

    // A bare 0x03 0x00 body is an empty ISRC even though it would also be
    // an empty UCS-2LE string.
    {
        const bytes = [_]u8{ 0x90, 0x06, 0x00, 0x00, 0x03, 0x00 };
        var c = bin.Cursor.initAlloc(alloc, &bytes);
        var s = try pdb.DeviceSQLString.decode(&c);
        defer s.deinit(alloc);
        try testing.expect(std.meta.activeTag(s.long) == .isrc);
        try expectRoundtrip(&bytes, s);
    }
}

test "decode rejects malformed strings" {
    const invalid = [_][]const u8{
        // long form with a nonzero padding byte
        &.{ 0x40, 0x05, 0x00, 0x01, 'a' },
        // long form with a length shorter than its own 4 header bytes
        &.{ 0x40, 0x02, 0x00, 0x00 },
        // unknown flags
        &.{ 0x00, 0x04, 0x00, 0x00 },
        // flags 0x90 with an odd body that is not of the ISRC shape
        &.{ 0x90, 0x05, 0x00, 0x00, 'a', 'b', 'c' },
        // short-form header 0x01 would imply a content length of -1
        &.{0x01},
    };
    for (invalid) |bytes| {
        var c = bin.Cursor.initAlloc(testing.allocator, bytes);
        try testing.expectError(error.InvalidFormat, pdb.DeviceSQLString.decode(&c));
    }

    const truncated = [_][]const u8{
        // short form promising a content byte that is not there
        &.{0x05},
        // long form promising a body byte that is not there
        &.{ 0x40, 0x05, 0x00, 0x00 },
        // ISRC-shaped body extending past the buffer
        &.{ 0x90, 0x08, 0x00, 0x00, 0x03, 'A' },
    };
    for (truncated) |bytes| {
        var c = bin.Cursor.initAlloc(testing.allocator, bytes);
        try testing.expectError(error.UnexpectedEof, pdb.DeviceSQLString.decode(&c));
    }
}

test "utf8 conversion is strict" {
    const alloc = testing.allocator;

    // Content bytes are not validated on parse, only on conversion.
    var c = bin.Cursor.initAlloc(alloc, &.{ 0x05, 0xFF });
    var bad_ascii = try pdb.DeviceSQLString.decode(&c);
    defer bad_ascii.deinit(alloc);
    try testing.expectError(error.InvalidEncoding, bad_ascii.utf8(alloc));

    // A lone surrogate half is rejected as well.
    var c2 = bin.Cursor.initAlloc(alloc, &.{ 0x90, 0x06, 0x00, 0x00, 0x00, 0xD8 });
    var bad_ucs2 = try pdb.DeviceSQLString.decode(&c2);
    defer bad_ucs2.deinit(alloc);
    try testing.expect(std.meta.activeTag(bad_ucs2.long) == .ucs2le);
    try testing.expectError(error.InvalidEncoding, bad_ucs2.utf8(alloc));
}

test "heap bytes and alignment" {
    const alloc = testing.allocator;

    try testing.expectEqual(@as(u16, 1), pdb.DeviceSQLString.empty().heapBytesRequired());
    try testing.expectEqual(@as(u16, 1), pdb.DeviceSQLString.empty().requiredAlignment());

    var isrc = try pdb.DeviceSQLString.fromIsrc(alloc, "GBAYE6700149");
    defer isrc.deinit(alloc);
    try testing.expectEqual(@as(u16, 18), isrc.heapBytesRequired());
    try testing.expectEqual(@as(u16, 1), isrc.requiredAlignment());

    var ucs2 = try pdb.DeviceSQLString.fromUtf8(alloc, "I ❤ Rust");
    defer ucs2.deinit(alloc);
    try testing.expectEqual(@as(u16, 20), ucs2.heapBytesRequired());
    try testing.expectEqual(@as(u16, 4), ucs2.requiredAlignment());

    // Long-form ASCII bodies need no alignment either.
    const long_ascii_bytes = [_]u8{'a'} ** 127;
    var long_ascii = try pdb.DeviceSQLString.fromUtf8(alloc, &long_ascii_bytes);
    defer long_ascii.deinit(alloc);
    try testing.expect(std.meta.activeTag(long_ascii.long) == .ascii);
    try testing.expectEqual(@as(u16, 1), long_ascii.requiredAlignment());
}

// Offset array tests, ported from rekordcrate's offset_array.rs test module.

/// Test item holding one little-endian `u8`.
const TestU8Item = struct {
    value: u8 = 0,

    pub fn decode(c: *bin.Cursor) bin.ReadError!TestU8Item {
        return .{ .value = try c.takeInt(u8, .little) };
    }

    pub fn encode(item: TestU8Item, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u8, item.value, .little);
    }

    pub fn heapBytesRequired(item: TestU8Item) u16 {
        _ = item;
        return 1;
    }

    pub fn requiredAlignment(item: TestU8Item) u16 {
        _ = item;
        return 1;
    }

    pub fn deinit(item: *TestU8Item, alloc: std.mem.Allocator) void {
        _ = item;
        _ = alloc;
    }

    pub fn eql(a: TestU8Item, b: TestU8Item) bool {
        return a.value == b.value;
    }
};

/// Test item holding four raw bytes, as-is on the wire.
const TestBytes4Item = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn decode(c: *bin.Cursor) bin.ReadError!TestBytes4Item {
        return .{ .bytes = (try c.takeArray(4)).* };
    }

    pub fn encode(item: TestBytes4Item, e: *bin.Emitter) bin.WriteError!void {
        try e.putBytes(&item.bytes);
    }

    pub fn heapBytesRequired(item: TestBytes4Item) u16 {
        _ = item;
        return 4;
    }

    pub fn requiredAlignment(item: TestBytes4Item) u16 {
        _ = item;
        return 1;
    }

    pub fn deinit(item: *TestBytes4Item, alloc: std.mem.Allocator) void {
        _ = item;
        _ = alloc;
    }

    pub fn eql(a: TestBytes4Item, b: TestBytes4Item) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// Single-item inner type, the analogue of rekordcrate's test `SingleTarget`
/// (and of its `TrailingName`).
fn TestSingle(comptime Item: type) type {
    return struct {
        value: Item = .{},

        pub const offset_count = 1;
        pub const OffsetItem = Item;
    };
}

/// Two-item inner type, the analogue of rekordcrate's test `Multiple`.
fn TestPair(comptime Item: type) type {
    return struct {
        a: Item = .{},
        b: Item = .{},

        pub const offset_count = 2;
        pub const OffsetItem = Item;
    };
}

/// Zero-item inner type, the analogue of rekordcrate's `()` implementation
/// of `OffsetArrayItems<0>`.
const TestEmpty = struct {
    pub const offset_count = 0;
    pub const OffsetItem = void;
};

/// Two-string inner type for the heap-bytes tests, the analogue of
/// rekordcrate's `Multiple<pdb.DeviceSQLString>` (and a preview of the
/// `TrailingName`-style row types).
const TestStringPair = struct {
    a: pdb.DeviceSQLString = pdb.DeviceSQLString.empty(),
    b: pdb.DeviceSQLString = pdb.DeviceSQLString.empty(),

    pub const offset_count = 2;
    pub const OffsetItem = pdb.DeviceSQLString;
};

/// Mirrors rekordcrate's `test_roundtrip_with_args` at `array_offset` 0:
/// parses `bytes` expecting `expected`, with the cursor landing directly
/// after the offsets, and re-encodes `expected` expecting `bytes` back.
/// The items of `expected` must not own memory, since `expected` is never
/// deinit-ed.
fn expectOffsetsRoundtrip(bytes: []const u8, expected: anytype, size: pdb.OffsetSize) !void {
    const Container = @TypeOf(expected);

    var c = bin.Cursor.initAlloc(testing.allocator, bytes);
    const parsed = try Container.decode(&c, 0, size);
    try testing.expectEqual(
        @as(usize, (Container.offset_count + 1) * size.bytes()),
        c.pos,
    );
    try testing.expect(expected.eql(parsed));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try expected.encode(&e, 0, size);
    try testing.expectEqualSlices(u8, bytes, e.written());
}

test "empty offset array roundtrips" {
    try expectOffsetsRoundtrip(
        &.{0x03},
        pdb.OffsetArrayContainer(TestEmpty){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{} } },
        },
        .u8,
    );
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x00 },
        pdb.OffsetArrayContainer(TestEmpty){
            .offsets = .{ .provided = .{ .size = .u16, .values = .{} } },
        },
        .u16,
    );
}

test "near u8 offset roundtrips" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x02, 42 },
        pdb.OffsetArrayContainer(TestSingle(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{2} } },
            .inner = .{ .value = .{ .value = 42 } },
        },
        .u8,
    );
}

test "four-byte buffer item roundtrips" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x02, 0xDE, 0xAD, 0xBE, 0xEF },
        pdb.OffsetArrayContainer(TestSingle(TestBytes4Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{2} } },
            .inner = .{ .value = .{ .bytes = .{ 0xDE, 0xAD, 0xBE, 0xEF } } },
        },
        .u8,
    );
}

test "near remote offset roundtrips" {
    // The item lives three bytes past the offsets; the gap is zero-filled
    // on write.
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x05, 0x00, 0x00, 0x00, 42 },
        pdb.OffsetArrayContainer(TestSingle(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{5} } },
            .inner = .{ .value = .{ .value = 42 } },
        },
        .u8,
    );
}

test "far remote u16 offsets roundtrip" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x00, 0x05, 0x00, 0x00, 42 },
        pdb.OffsetArrayContainer(TestSingle(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u16, .values = .{5} } },
            .inner = .{ .value = .{ .value = 42 } },
        },
        .u16,
    );
}

test "nonzero base offset roundtrips" {
    // Three padding bytes stand in for the fixed fields of a row: the
    // array starts at position 3, its offsets are relative to position 0.
    const Single = TestSingle(TestU8Item);
    const expected: pdb.OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{5} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    const bytes = [_]u8{ 0, 0, 0, 0x03, 0x05, 42 };

    var c = bin.Cursor.initAlloc(testing.allocator, &bytes);
    try c.seekBy(3);
    const parsed = try pdb.OffsetArrayContainer(Single).decode(&c, 3, .u8);
    try testing.expect(expected.eql(parsed));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try e.pad(3);
    try expected.encode(&e, 3, .u8);
    try testing.expectEqualSlices(u8, &bytes, e.written());
}

test "multiple offsets roundtrip" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x03, 0x04, 0xC0, 0xDE },
        pdb.OffsetArrayContainer(TestPair(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{ 3, 4 } } },
            .inner = .{ .a = .{ .value = 0xC0 }, .b = .{ .value = 0xDE } },
        },
        .u8,
    );
}

test "switched ordering roundtrips" {
    // Items live at their offsets in wire order, independent of the inner
    // type's field order: a's offset points past b's.
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x04, 0x03, 0xDE, 0xC0 },
        pdb.OffsetArrayContainer(TestPair(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{ 4, 3 } } },
            .inner = .{ .a = .{ .value = 0xC0 }, .b = .{ .value = 0xDE } },
        },
        .u8,
    );
}

test "offset size comes from the subtype bit 0x04" {
    // Artist subtypes 0x60/0x64 and Track's 0x24 are the known occupants
    // of each width; Album's usual 0x0080 stays u8.
    try testing.expectEqual(pdb.OffsetSize.u8, pdb.OffsetSize.fromSubtype(0x60));
    try testing.expectEqual(pdb.OffsetSize.u16, pdb.OffsetSize.fromSubtype(0x64));
    try testing.expectEqual(pdb.OffsetSize.u16, pdb.OffsetSize.fromSubtype(0x24));
    try testing.expectEqual(pdb.OffsetSize.u8, pdb.OffsetSize.fromSubtype(0x0080));
}

test "heapBytesRequired aligns calculated ucs2 items to 4 bytes" {
    const alloc = testing.allocator;

    var foo = try pdb.DeviceSQLString.fromUtf8(alloc, "foo");
    defer foo.deinit(alloc);
    var e_acute = try pdb.DeviceSQLString.fromUtf8(alloc, "é");
    defer e_acute.deinit(alloc);

    // Calculated: 3 bytes of magic+offsets, "foo" at 3 (4 bytes), then
    // "é" aligned from 7 up to 8, adding its 6 bytes — the placement the
    // oracle's calculated write produces.
    const calculated: pdb.OffsetArrayContainer(TestStringPair) = .{
        .offsets = .calculated,
        .inner = .{ .a = foo, .b = e_acute },
    };
    try testing.expectEqual(@as(u16, 14), calculated.heapBytesRequired(.u8));

    // Provided: the bytes of the array and the items, gaps not counted.
    const provided: pdb.OffsetArrayContainer(TestStringPair) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{ 3, 8 } } },
        .inner = .{ .a = foo, .b = e_acute },
    };
    try testing.expectEqual(@as(u16, 13), provided.heapBytesRequired(.u8));
}

test "offset array decode rejects malformed input" {
    const Single = TestSingle(TestBytes4Item);
    const alloc = testing.allocator;

    const invalid = [_]struct { bytes: []const u8, size: pdb.OffsetSize }{
        // u16 width, but the bytes are a u8 magic plus an offset, which
        // reads as the u16 magic 0x0503.
        .{ .bytes = &.{ 0x03, 0x05, 0x00, 0x00, 42 }, .size = .u16 },
        // wrong u8 magic
        .{ .bytes = &.{ 0x02, 0x01, 42 }, .size = .u8 },
    };
    for (invalid) |case| {
        var c = bin.Cursor.initAlloc(alloc, case.bytes);
        try testing.expectError(
            error.InvalidFormat,
            pdb.OffsetArrayContainer(Single).decode(&c, 0, case.size),
        );
    }

    const truncated = [_]struct { bytes: []const u8, size: pdb.OffsetSize }{
        // u16 magic cut in half
        .{ .bytes = &.{0x03}, .size = .u16 },
        // u8 offsets truncated after the magic
        .{ .bytes = &.{0x03}, .size = .u8 },
        // offset pointing past the buffer
        .{ .bytes = &.{ 0x03, 0x09, 42 }, .size = .u8 },
        // item truncated mid-decode
        .{ .bytes = &.{ 0x03, 0x01, 0xDE, 0xAD }, .size = .u8 },
    };
    for (truncated) |case| {
        var c = bin.Cursor.initAlloc(alloc, case.bytes);
        try testing.expectError(
            error.UnexpectedEof,
            pdb.OffsetArrayContainer(Single).decode(&c, 0, case.size),
        );
    }

    // A base underflowing the cursor position is rejected as well: an
    // array at position 0 has no row start 2 bytes before it.
    var c = bin.Cursor.initAlloc(alloc, &.{ 0x03, 0x01, 42 });
    try testing.expectError(
        error.UnexpectedValue,
        pdb.OffsetArrayContainer(Single).decode(&c, 2, .u8),
    );
}

test "offset array decode failure frees already decoded items" {
    const alloc = testing.allocator;
    // Offsets {3, 8}: the first item is "foo"; the second points one byte
    // past the buffer, so decoding fails after the first item allocated.
    const bytes = [_]u8{ 0x03, 0x03, 0x08, 0x07, 'f', 'o', 'o', 0x01 };
    var c = bin.Cursor.initAlloc(alloc, &bytes);
    try testing.expectError(
        error.UnexpectedEof,
        pdb.OffsetArrayContainer(TestStringPair).decode(&c, 0, .u8),
    );
}

test "offset array container deinit frees its items" {
    const alloc = testing.allocator;
    // Offsets {3, 7}: the first item is "foo", the second the empty
    // string.
    const bytes = [_]u8{ 0x03, 0x03, 0x07, 0x07, 'f', 'o', 'o', 0x03 };
    var c = bin.Cursor.initAlloc(alloc, &bytes);
    var container = try pdb.OffsetArrayContainer(TestStringPair).decode(&c, 0, .u8);
    container.deinit(alloc);
}

test "offset array encode validates provided offsets" {
    const alloc = testing.allocator;
    const Single = TestSingle(TestU8Item);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();

    // Provided width must match the write argument.
    const u16_stored: pdb.OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u16, .values = .{2} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    try testing.expectError(
        error.UnexpectedValue,
        u16_stored.encode(&e, 0, .u8),
    );

    // u8 offsets cannot hold values wider than a byte.
    const overflowing: pdb.OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{0x0100} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    try testing.expectError(
        error.UnexpectedValue,
        overflowing.encode(&e, 0, .u8),
    );

    // The base must not underflow the emitter position: an empty emitter
    // has no row start 1 byte before it.
    const near: pdb.OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{1} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    var empty = bin.Emitter.init(alloc);
    defer empty.deinit();
    try testing.expectError(
        error.UnexpectedValue,
        near.encode(&empty, 1, .u8),
    );
}

test "calculated offsets append items in order and patch back" {
    // Ported from rekordcrate's `calculated` test: offsets {3, 4} are
    // computed from where the items land, not provided.
    const alloc = testing.allocator;
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    const multiple: pdb.OffsetArrayContainer(TestPair(TestU8Item)) = .{
        .offsets = .calculated,
        .inner = .{ .a = .{ .value = 0xC0 }, .b = .{ .value = 0xDE } },
    };
    try multiple.encode(&e, 0, .u8);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x03, 0x03, 0x04, 0xC0, 0xDE },
        e.written(),
    );
}

test "calculated offsets align ucs2 items to 4 bytes" {
    // Ported from rekordcrate's `calculated_aligns_ucs2_item_to_4bytes`:
    // "foo" ends at 7, so the UCS-2LE "é" is padded to start at 8 (one
    // zero byte), and both patched offsets point at their items.
    const alloc = testing.allocator;
    var foo = try pdb.DeviceSQLString.fromUtf8(alloc, "foo");
    defer foo.deinit(alloc);
    var e_acute = try pdb.DeviceSQLString.fromUtf8(alloc, "é");
    defer e_acute.deinit(alloc);

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    const pair: pdb.OffsetArrayContainer(TestStringPair) = .{
        .offsets = .calculated,
        .inner = .{ .a = foo, .b = e_acute },
    };
    try pair.encode(&e, 0, .u8);
    try testing.expectEqualSlices(
        u8,
        &.{
            0x03, 0x03, 0x08, 0x09, 0x66, 0x6F, 0x6F, 0x00,
            0x90, 0x06, 0x00, 0x00, 0xE9, 0x00,
        },
        e.written(),
    );

    // The patched offsets point where a decode would look.
    var c = bin.Cursor.initAlloc(alloc, e.written());
    var parsed = try pdb.OffsetArrayContainer(TestStringPair).decode(&c, 0, .u8);
    defer parsed.deinit(alloc);
    try testing.expectEqualSlices(u16, &.{ 3, 8 }, &parsed.offsets.provided.values);
}

test "calculated offsets reject items past the offset width" {
    // A u8 offset cannot reach an item placed past byte 255: the long
    // ASCII filler ends at 307.
    const alloc = testing.allocator;
    const filler = try alloc.alloc(u8, 300);
    defer alloc.free(filler);
    @memset(filler, 'a');
    var long = try pdb.DeviceSQLString.fromUtf8(alloc, filler);
    defer long.deinit(alloc);

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    const pair: pdb.OffsetArrayContainer(TestStringPair) = .{
        .offsets = .calculated,
        .inner = .{ .a = long, .b = pdb.DeviceSQLString.empty() },
    };
    try testing.expectError(
        error.UnexpectedValue,
        pair.encode(&e, 0, .u8),
    );
}

// Page and index page tests, ported from rekordcrate's `bitfields.rs` and
// the `index_page` test of `test_roundtrip.rs`.

test "page flags wire values" {
    // The typical data page: unknown2 and unknown5 set.
    try testing.expectEqual(@as(u8, 0x24), @as(u8, @bitCast(pdb.PageFlags{})));
    // An index page additionally sets is_index_page.
    try testing.expectEqual(
        @as(u8, 0x64),
        @as(u8, @bitCast(pdb.PageFlags{ .is_index_page = true })),
    );
    // A data page containing a deleted row.
    try testing.expectEqual(
        @as(u8, 0x34),
        @as(u8, @bitCast(pdb.PageFlags{ .contains_deleted = true })),
    );

    // Fields read back from a wire value.
    const parsed: pdb.PageFlags = @bitCast(@as(u8, 0x34));
    try testing.expect(parsed.unknown2 and parsed.unknown5 and parsed.contains_deleted);
    try testing.expect(!parsed.unknown0 and !parsed.is_index_page);
}

test "packed row counts occupy the low 13 and high 11 bits" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, pdb.PackedRowCounts{ .num_rows = 22, .num_rows_valid = 22 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x16, 0xC0, 0x02 }, e.written());
    try bin.putStruct(&e, pdb.PackedRowCounts{ .num_rows = 5, .num_rows_valid = 7 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xE0, 0x00 }, e.written()[3..]);

    var c = bin.Cursor.init(e.written()[0..3]);
    try testing.expectEqual(
        pdb.PackedRowCounts{ .num_rows = 22, .num_rows_valid = 22 },
        try bin.takeStruct(&c, pdb.PackedRowCounts, .little),
    );
    try testing.expect(c.atEnd());
}

test "page header roundtrips and validates its constants" {
    const header: pdb.PageHeader = .{
        .page_index = 1,
        .page_type = .tracks,
        .next_page = 2,
        .unknown1 = 29871,
        .page_flags = .{ .is_index_page = true },
    };
    try testing.expectEqual(@as(usize, 0x20), bin.serializedLen(pdb.PageHeader));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, header, .little);
    try testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0x00, // magic
        0x01, 0x00, 0x00, 0x00, // page_index
        0x00, 0x00, 0x00, 0x00, // page_type = tracks
        0x02, 0x00, 0x00, 0x00, // next_page
        0xAF, 0x74, 0x00, 0x00, // unknown1
        0x00, 0x00, 0x00, 0x00, // unknown2
        0x00, 0x00, 0x00, // packed_row_counts
        0x64, // page_flags
        0x00, 0x00, // free_size
        0x00, 0x00, // used_size
    }, e.written());

    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(header, try bin.takeStruct(&c, pdb.PageHeader, .little));
    try testing.expect(c.atEnd());
    try bin.validateConstantFields(pdb.PageHeader, header);

    // Unknown page types roundtrip verbatim.
    var page_type_bytes = [_]u8{0} ** 0x20;
    page_type_bytes[8] = 0x63;
    var c2 = bin.Cursor.init(&page_type_bytes);
    const exotic = try bin.takeStruct(&c2, pdb.PageHeader, .little);
    try testing.expectEqual(@as(u32, 0x63), @intFromEnum(exotic.page_type));

    // A nonzero magic or unknown2 is rejected.
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(pdb.PageHeader, .{ .magic = 1 }),
    );
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(pdb.PageHeader, .{ .unknown2 = 1 }),
    );
}

test "index entries pack page index and flags" {
    const entry = pdb.IndexEntry{ .page_index = 604 };
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, entry, .little);
    // Bits 31-3 hold the page index: 604 << 3.
    try testing.expectEqualSlices(u8, &.{ 0xE0, 0x12, 0x00, 0x00 }, e.written());

    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(entry, try bin.takeStruct(&c, pdb.IndexEntry, .little));
    try testing.expect(c.atEnd());

    // The empty sentinel and its recognition.
    try testing.expectEqual(@as(u32, 0x1FFF_FFF8), @as(u32, @bitCast(pdb.IndexEntry.empty)));
    try testing.expect(pdb.IndexEntry.empty.isEmpty());
    try testing.expect(!entry.isEmpty());

    var c2 = bin.Cursor.init(&.{ 0xF8, 0xFF, 0xFF, 0x1F });
    try testing.expect((try bin.takeStruct(&c2, pdb.IndexEntry, .little)).isEmpty());
}

test "index page header roundtrips and validates its magics" {
    const header: pdb.IndexPageHeader = .{
        .unknown_a = 2,
        .unknown_b = 179,
        .next_offset = 272,
        .page_index = 1,
        .next_page = 2,
        .num_entries = 272,
    };
    try testing.expectEqual(@as(usize, 28), bin.serializedLen(pdb.IndexPageHeader));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, header, .little);
    try testing.expectEqualSlices(u8, &.{
        0x02, 0x00, // unknown_a
        0xB3, 0x00, // unknown_b
        0xEC, 0x03, // magic
        0x10, 0x01, // next_offset
        0x01, 0x00, 0x00, 0x00, // page_index
        0x02, 0x00, 0x00, 0x00, // next_page
        0xFF, 0xFF, 0xFF, 0x03, 0x00, 0x00, 0x00, 0x00, // magic2
        0x10, 0x01, // num_entries
        0xFF, 0x1F, // first_empty
    }, e.written());

    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(header, try bin.takeStruct(&c, pdb.IndexPageHeader, .little));
    try testing.expect(c.atEnd());

    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(pdb.IndexPageHeader, .{ .magic = 0 }),
    );
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(pdb.IndexPageHeader, .{ .magic2 = 0 }),
    );
}

test "index page content pads to capacity with empty entries and zeros" {
    const alloc = testing.allocator;
    const content = pdb.IndexPageContent{ .header = .{ .page_index = 1, .next_page = 2 } };

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try content.encode(&e, 4096);
    // The content fills the page behind a 0x20-byte page header: a
    // 28-byte index header, 1004 entries, and 20 trailing zeros.
    try testing.expectEqual(@as(usize, 4096 - 0x20), e.written().len);

    var c = bin.Cursor.initAlloc(alloc, e.written());
    var parsed = try pdb.IndexPageContent.decode(&c, alloc);
    defer parsed.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), parsed.entries.len);
    try testing.expectEqual(@as(u16, 0), parsed.header.num_entries);
    try testing.expectEqual(content.header, parsed.header);
    for (0..1004) |_| {
        try testing.expect((try bin.takeStruct(&c, pdb.IndexEntry, .little)).isEmpty());
    }
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 20), try c.takeBytes(20));
    try testing.expect(c.atEnd());
}

test "index page content rejects malformed input" {
    const alloc = testing.allocator;

    // A header claiming two entries when only one is on the wire.
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, pdb.IndexPageHeader{ .num_entries = 2 }, .little);
    try bin.putStruct(&e, pdb.IndexEntry{ .page_index = 7 }, .little);
    var c = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(error.UnexpectedEof, pdb.IndexPageContent.decode(&c, alloc));

    // A wrong 0x03ec magic.
    var e2 = bin.Emitter.init(alloc);
    defer e2.deinit();
    try bin.putStruct(&e2, pdb.IndexPageHeader{ .magic = 0 }, .little);
    var c2 = bin.Cursor.initAlloc(alloc, e2.written());
    try testing.expectError(error.UnexpectedValue, pdb.IndexPageContent.decode(&c2, alloc));

    // More entries than the page holds, and a page too small for the
    // fixed parts.
    const many = try alloc.alloc(pdb.IndexEntry, 1005);
    defer alloc.free(many);
    for (many) |*entry| entry.* = .{};
    const big = pdb.IndexPageContent{ .entries = many };
    var e3 = bin.Emitter.init(alloc);
    defer e3.deinit();
    try testing.expectError(error.UnexpectedValue, big.encode(&e3, 4096));
    var e4 = bin.Emitter.init(alloc);
    defer e4.deinit();
    try testing.expectError(error.UnexpectedValue, big.encode(&e4, 0x20));
}

test "index page fixture parses with known field values" {
    const alloc = testing.allocator;
    const bytes = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/index_page.bin",
        .limited(1 << 16),
    );
    defer alloc.free(bytes);

    var c = bin.Cursor.initAlloc(alloc, bytes);
    const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
    try bin.validateConstantFields(pdb.PageHeader, header);
    try testing.expectEqual(@as(u32, 1), header.page_index);
    try testing.expectEqual(pdb.PageType.tracks, header.page_type);
    try testing.expectEqual(@as(u32, 2), header.next_page);
    try testing.expectEqual(@as(u32, 29871), header.unknown1);
    try testing.expectEqual(pdb.PackedRowCounts{}, header.packed_row_counts);
    try testing.expect(header.page_flags.is_index_page);
    try testing.expect(!header.page_flags.contains_deleted);
    try testing.expectEqual(@as(u16, 0), header.free_size);
    try testing.expectEqual(@as(u16, 0), header.used_size);

    var content = try pdb.IndexPageContent.decode(&c, alloc);
    defer content.deinit(alloc);
    const h = content.header;
    try testing.expectEqual(@as(u16, 2), h.unknown_a);
    try testing.expectEqual(@as(u16, 179), h.unknown_b);
    try testing.expectEqual(@as(u16, 272), h.next_offset);
    try testing.expectEqual(@as(u32, 1), h.page_index);
    try testing.expectEqual(@as(u32, 2), h.next_page);
    try testing.expectEqual(@as(u16, 272), h.num_entries);
    try testing.expectEqual(@as(u16, 8191), h.first_empty);

    // The first entries point at pages 604, 371, 441; exactly two entries
    // carry nonzero flags (page 603 with flags 5 and 3, the latter last).
    try testing.expectEqual(@as(usize, 272), content.entries.len);
    try testing.expectEqual(@as(u29, 604), content.entries[0].page_index);
    try testing.expectEqual(@as(u29, 371), content.entries[1].page_index);
    try testing.expectEqual(@as(u29, 441), content.entries[2].page_index);
    var flagged: usize = 0;
    for (content.entries) |entry| {
        if (entry.index_flags != 0) {
            try testing.expectEqual(@as(u29, 603), entry.page_index);
            flagged += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), flagged);
    const last = content.entries[content.entries.len - 1];
    try testing.expectEqual(@as(u29, 603), last.page_index);
    try testing.expectEqual(@as(u3, 3), last.index_flags);
}

/// Parses `input` — a whole page, including the page header — of a
/// database of `db_type` and re-serializes it, for
/// `testutil.expectFixturesRoundtrip`. The page size is the fixture
/// length; page types whose rows are not wired for `db_type` fail with
/// `error.NotImplemented`.
fn roundtripPage(
    alloc: std.mem.Allocator,
    input: []const u8,
    db_type: pdb.DatabaseType,
) ![]u8 {
    var c = bin.Cursor.initAlloc(alloc, input);
    var page = try pdb.Page.decode(&c, alloc, input.len, db_type);
    defer page.deinit(alloc);

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try page.encode(&e, input.len);
    return e.toOwnedSlice();
}

/// `roundtripPage` for plain databases, in the shape
/// `testutil.expectFixturesRoundtrip` takes.
fn roundtripPlainPage(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return roundtripPage(alloc, input, .plain);
}

/// `roundtripPage` for ext databases.
fn roundtripExtPage(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return roundtripPage(alloc, input, .ext);
}

test "index page fixture roundtrips byte-identical" {
    try testutil.expectFixturesRoundtrip(roundtripPlainPage, "index_page", 1);
}

test "data page fixtures roundtrip byte-identical" {
    const prefixes = [_][]const u8{
        "genres",          "labels",
        "keys",            "colors",
        "artworks",        "history_playlists",
        "history_entries", "playlist_entries",
        "menu",
    };
    inline for (prefixes) |prefix|
        try testutil.expectFixturesRoundtrip(roundtripPlainPage, prefix, 1);
}

test "artist, album, and playlist tree page fixtures roundtrip byte-identical" {
    const prefixes = [_][]const u8{
        "artists", "artist_page_long", "albums", "playlist_tree",
    };
    inline for (prefixes) |prefix|
        try testutil.expectFixturesRoundtrip(roundtripPlainPage, prefix, 1);
}

test "track page fixture roundtrips byte-identical" {
    // The full prefix, so the ext-database track_tag_page fixture does
    // not match.
    try testutil.expectFixturesRoundtrip(roundtripPlainPage, "track_page", 1);
}

test "tag page fixture roundtrips byte-identical" {
    try testutil.expectFixturesRoundtrip(roundtripExtPage, "tag_page", 1);
}

test "tag page fixture parses with known field values" {
    const alloc = testing.allocator;
    const bytes = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/tag_page.bin",
        .limited(1 << 16),
    );
    defer alloc.free(bytes);

    var c = bin.Cursor.initAlloc(alloc, bytes);
    const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
    try testing.expectEqual(@as(u32, 8), header.page_index);
    try testing.expectEqual(
        @intFromEnum(pdb.ExtPageType.tag),
        @intFromEnum(header.page_type),
    );
    try testing.expectEqual(@as(u32, 20), header.next_page);
    try testing.expectEqual(@as(u32, 2), header.unknown1);
    try testing.expectEqual(@as(u32, 23), header.packed_row_counts.num_rows);
    try testing.expectEqual(@as(u32, 23), header.packed_row_counts.num_rows_valid);
    try testing.expectEqual(@as(u16, 2770), header.free_size);
    try testing.expectEqual(@as(u16, 1232), header.used_size);

    var content = try pdb.DataPageContent.decode(&c, alloc, bytes.len, header, .ext);
    defer content.deinit(alloc);
    try testing.expectEqual(@as(u16, 23), content.header.unknown5);

    // Two row groups; both carry the same value in `unknown` as in the
    // presence flags (a full group and a 7-of-16 one).
    try testing.expectEqual(@as(usize, 2), content.row_groups.len);
    try testing.expectEqual(@as(u16, 0xFFFF), content.row_groups[0].row_presence_flags);
    try testing.expectEqual(@as(u16, 0xFFFF), content.row_groups[0].unknown);
    try testing.expectEqual(@as(u16, 0x007F), content.row_groups[1].row_presence_flags);
    try testing.expectEqual(@as(u16, 0x007F), content.row_groups[1].unknown);

    // 23 rows: 16 in the first group, 7 in the second.
    try testing.expectEqual(@as(usize, 23), content.rows.len);
    try testing.expectEqual(@as(u16, 0x0000), content.rows[0].offset);
    try testing.expectEqual(@as(u16, 0x0038), content.rows[1].offset);
    try testing.expectEqual(@as(u16, 0x0354), content.rows[16].offset);

    // The first row is the category "TagCategory1".
    var category_name = try pdb.DeviceSQLString.fromUtf8(alloc, "TagCategory1");
    defer category_name.deinit(alloc);
    const first = content.rows[0].row.tag;
    try testing.expectEqual(@as(u16, 0x0680), first.subtype);
    try testing.expectEqual(@as(u16, 0), first.index_shift);
    try testing.expectEqual(@as(u32, 0), first.unknown1);
    try testing.expectEqual(@as(u32, 0), first.unknown2);
    try testing.expectEqual(@as(u32, 0), first.parent_id);
    try testing.expectEqual(@as(u32, 0), first.position);
    try testing.expectEqual(@as(u32, 1), first.id);
    try testing.expectEqual(@as(u32, 1) << 24, first.raw_is_category);
    try testing.expect(category_name.eql(first.offsets.inner.name));
    try testing.expect(pdb.DeviceSQLString.empty().eql(first.offsets.inner.unknown));

    // The second is a tag in that category, with a random-looking id.
    const second = content.rows[1].row.tag;
    try testing.expectEqual(@as(u16, 0x20), second.index_shift);
    try testing.expectEqual(@as(u32, 1), second.parent_id);
    try testing.expectEqual(@as(u32, 0xCE03_BAA5), second.id);
    try testing.expectEqual(@as(u32, 0), second.raw_is_category);

    // The fourth is the second category, a root like the first.
    const fourth = content.rows[3].row.tag;
    try testing.expectEqual(@as(u16, 0x60), fourth.index_shift);
    try testing.expectEqual(@as(u32, 0), fourth.parent_id);
    try testing.expectEqual(@as(u32, 1), fourth.position);
    try testing.expectEqual(@as(u32, 2), fourth.id);
    try testing.expectEqual(@as(u32, 1) << 24, fourth.raw_is_category);
}

test "track tag page fixture roundtrips byte-identical" {
    try testutil.expectFixturesRoundtrip(roundtripExtPage, "track_tag_page", 1);
}

test "track tag page fixture parses with known field values" {
    const alloc = testing.allocator;
    const bytes = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/track_tag_page.bin",
        .limited(1 << 16),
    );
    defer alloc.free(bytes);

    var c = bin.Cursor.initAlloc(alloc, bytes);
    const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
    try testing.expectEqual(@as(u32, 10), header.page_index);
    try testing.expectEqual(
        @intFromEnum(pdb.ExtPageType.track_tag),
        @intFromEnum(header.page_type),
    );
    try testing.expectEqual(@as(u32, 21), header.next_page);
    try testing.expectEqual(@as(u32, 54), header.unknown1);
    try testing.expectEqual(@as(u32, 52), header.packed_row_counts.num_rows);
    try testing.expectEqual(@as(u32, 52), header.packed_row_counts.num_rows_valid);
    try testing.expectEqual(@as(u16, 3104), header.free_size);
    try testing.expectEqual(@as(u16, 832), header.used_size);

    var content = try pdb.DataPageContent.decode(&c, alloc, bytes.len, header, .ext);
    defer content.deinit(alloc);
    try testing.expectEqual(@as(u16, 1), content.header.unknown5);
    try testing.expectEqual(@as(u16, 51), content.header.unknown_not_num_rows_large);

    // Four row groups: three full ones, the last holding rows 49-52 in
    // slots 12-15 with only bits 0-3 present.
    try testing.expectEqual(@as(usize, 4), content.row_groups.len);
    try testing.expectEqual(@as(u16, 0xFFFF), content.row_groups[0].row_presence_flags);
    try testing.expectEqual(@as(u16, 0x000F), content.row_groups[3].row_presence_flags);
    try testing.expectEqual(@as(u16, 0x0008), content.row_groups[3].unknown);

    // 52 rows of 16 bytes each: tracks appear once per tag they carry
    // (track 2 with two different tags in the first rows).
    try testing.expectEqual(@as(usize, 52), content.rows.len);
    const first = content.rows[0].row.track_tag;
    try testing.expectEqual(@as(u32, 1), first.track_id);
    try testing.expectEqual(@as(u32, 2498240426), first.tag_id);
    try testing.expectEqual(@as(u32, 3), first.unknown_const);
    const second = content.rows[1].row.track_tag;
    try testing.expectEqual(@as(u32, 2), second.track_id);
    try testing.expectEqual(@as(u32, 4052665282), second.tag_id);
    const third = content.rows[2].row.track_tag;
    try testing.expectEqual(@as(u32, 2), third.track_id);
    try testing.expectEqual(@as(u32, 2498240426), third.tag_id);
}

// File header, page, and whole-database tests, ported from the header
// vector of rekordcrate's `test_roundtrip.rs`, the chain semantics of
// `io.rs`'s `PageIterator`, and `tests/test_pdb_num_rows.rs`.

test "file header roundtrips, validates constants, and derives num_tables" {
    const alloc = testing.allocator;
    var tables = [_]pdb.Table{
        .{ .page_type = .tracks, .empty_candidate = 47, .first_page = 1, .last_page = 2 },
        .{ .page_type = .genres, .empty_candidate = 4, .first_page = 3, .last_page = 3 },
    };
    var header = pdb.Header{
        .page_size = 256,
        .next_unused_page = 51,
        .unknown = 5,
        .sequence = 34,
        .tables = &tables,
    };

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try header.encode(&e);
    const bytes = e.written();
    // The header fills exactly page 0: fixed fields, the two table
    // entries (ending at byte 60), and zero padding.
    try testing.expectEqual(@as(usize, 256), bytes.len);
    try testing.expect(std.mem.allEqual(u8, bytes[60..], 0));

    var c = bin.Cursor.init(bytes);
    const decoded = try pdb.Header.decode(&c, alloc);
    defer alloc.free(decoded.tables);
    // Decoding stops after the tables; the zero padding of page 0 is not
    // part of the model.
    try testing.expectEqual(@as(usize, 60), c.pos);
    try testing.expectEqual(@as(u32, 256), decoded.page_size);
    try testing.expectEqual(@as(u32, 2), decoded.num_tables);
    try testing.expectEqual(@as(u32, 51), decoded.next_unused_page);
    try testing.expectEqual(@as(u32, 5), decoded.unknown);
    try testing.expectEqual(@as(u32, 34), decoded.sequence);
    try testing.expectEqual(@as(usize, 2), decoded.tables.len);
    try testing.expectEqual(pdb.PageType.genres, decoded.tables[1].page_type);
    try testing.expectEqual(@as(u32, 4), decoded.tables[1].empty_candidate);
    try testing.expectEqual(@as(u32, 3), decoded.tables[1].first_page);
    try testing.expectEqual(@as(u32, 3), decoded.tables[1].last_page);
    try testing.expectEqual(header.findTable(.tracks).?.last_page, 2);

    // Encoding derives `num_tables` from the tables slice.
    header.tables = header.tables[0..1];
    var e2 = bin.Emitter.init(alloc);
    defer e2.deinit();
    try header.encode(&e2);
    var c2 = bin.Cursor.init(e2.written());
    const decoded2 = try pdb.Header.decode(&c2, alloc);
    defer alloc.free(decoded2.tables);
    try testing.expectEqual(@as(u32, 1), decoded2.num_tables);

    // The magics are structural constants.
    const corruptible = try alloc.dupe(u8, bytes);
    defer alloc.free(corruptible);
    corruptible[0] = 1; // magic
    var bad = bin.Cursor.init(corruptible);
    try testing.expectError(error.UnexpectedValue, pdb.Header.decode(&bad, alloc));
    corruptible[0] = 0;
    corruptible[24] = 1; // gap
    var bad2 = bin.Cursor.init(corruptible);
    try testing.expectError(error.UnexpectedValue, pdb.Header.decode(&bad2, alloc));

    // A table count whose entries would not fit in page 0 is rejected on
    // both sides, before anything is read or written.
    corruptible[24] = 0;
    corruptible[8] = 0xFF; // num_tables
    corruptible[9] = 0xFF;
    var bad3 = bin.Cursor.init(corruptible);
    try testing.expectError(error.UnexpectedValue, pdb.Header.decode(&bad3, alloc));
    var cramped = pdb.Header{ .page_size = 28, .tables = &tables };
    var e3 = bin.Emitter.init(alloc);
    defer e3.deinit();
    try testing.expectError(error.UnexpectedValue, cramped.encode(&e3));
}

test "page decode dispatches content by the index flag" {
    const alloc = testing.allocator;

    const index_bytes = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/index_page.bin",
        .limited(1 << 16),
    );
    defer alloc.free(index_bytes);
    var index_cursor = bin.Cursor.initAlloc(alloc, index_bytes);
    var index_page = try pdb.Page.decode(&index_cursor, alloc, index_bytes.len, .plain);
    defer index_page.deinit(alloc);
    try testing.expect(index_page.header.page_flags.is_index_page);
    try testing.expectEqual(pdb.PageType.tracks, index_page.header.page_type);
    try testing.expect(index_page.content == .index);

    const data_bytes = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/genres_page.bin",
        .limited(1 << 16),
    );
    defer alloc.free(data_bytes);
    var data_cursor = bin.Cursor.initAlloc(alloc, data_bytes);
    var data_page = try pdb.Page.decode(&data_cursor, alloc, data_bytes.len, .plain);
    defer data_page.deinit(alloc);
    try testing.expect(!data_page.header.page_flags.is_index_page);
    try testing.expectEqual(pdb.PageType.genres, data_page.header.page_type);
    try testing.expect(data_page.content == .data);
}

/// Parses the database fixture at `path` (relative to `testdata`) of
/// `db_type` and checks the P7 acceptance: the header page roundtrips
/// byte-identical, the only allowed difference elsewhere is dead-space
/// zeroing (every differing output byte is zero — deleted-row remnants
/// the writer does not preserve, which real files also carry on pages
/// without the `contains_deleted` flag), re-writing the first output is
/// byte-stable, and re-parsing it yields the same database.
fn expectDatabaseRoundtrip(path: []const u8, db_type: pdb.DatabaseType) !void {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(alloc, path, .limited(1 << 22));
    defer alloc.free(input);

    var db = try pdb.Database.parse(alloc, input, db_type);
    defer db.deinit();
    const out1 = try db.serialize(alloc);
    defer alloc.free(out1);

    try testing.expectEqual(input.len, out1.len);
    const page_size: usize = db.header.page_size;
    if (!std.mem.eql(u8, input[0..page_size], out1[0..page_size])) {
        std.debug.print("header page mismatch: {s}\n", .{path});
        try testing.expectEqualSlices(u8, input[0..page_size], out1[0..page_size]);
    }
    var zeroed: usize = 0;
    for (input, out1) |in_byte, out_byte| {
        if (in_byte == out_byte) continue;
        zeroed += 1;
        if (out_byte != 0) {
            std.debug.print(
                "non-zeroing difference at byte {d}: {s}\n",
                .{ zeroed, path },
            );
            try testing.expectEqual(@as(u8, 0), out_byte);
        }
    }

    var db2 = try pdb.Database.parse(alloc, out1, db_type);
    defer db2.deinit();
    const out2 = try db2.serialize(alloc);
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, out1, out2);
    try testing.expect(db.eql(&db2));
}

test "whole databases roundtrip byte-identical except zeroed dead space" {
    const cases = .{
        .{ .path = "pdb/num_rows/export.pdb", .db_type = pdb.DatabaseType.plain },
        .{ .path = "complete_export/demo_tracks/PIONEER/rekordbox/export.pdb", .db_type = pdb.DatabaseType.plain },
        .{ .path = "complete_export/demo_tracks/PIONEER/rekordbox/exportExt.pdb", .db_type = pdb.DatabaseType.ext },
        .{ .path = "complete_export/empty/PIONEER/rekordbox/export.pdb", .db_type = pdb.DatabaseType.plain },
        .{ .path = "complete_export/empty/PIONEER/rekordbox/exportExt.pdb", .db_type = pdb.DatabaseType.ext },
        .{ .path = "complete_export/with_anlz/PIONEER/rekordbox/export.pdb", .db_type = pdb.DatabaseType.plain },
        .{ .path = "complete_export/with_anlz/PIONEER/rekordbox/exportExt.pdb", .db_type = pdb.DatabaseType.ext },
    };
    inline for (cases) |case|
        try expectDatabaseRoundtrip(case.path, case.db_type);
}

/// Counts the valid rows of the table for `page_type` by walking its page
/// chain from `first_page` to `last_page` the way the oracle's
/// `PageIterator` does, rejecting non-increasing links, pages outside the
/// file, and pages that did not parse.
fn countTableRows(db: *const pdb.Database, page_type: pdb.PageType) !usize {
    var it = try db.rows(page_type);
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    return count;
}

test "num_rows database row counts per table" {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(alloc, "pdb/num_rows/export.pdb", .limited(1 << 22));
    defer alloc.free(input);

    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();

    // Ported from rekordcrate's `tests/test_pdb_num_rows.rs`, plus the
    // menu rows the oracle test does not cover.
    const expectations = .{
        .{ .page_type = pdb.PageType.tracks, .count = 3886 },
        .{ .page_type = pdb.PageType.genres, .count = 315 },
        .{ .page_type = pdb.PageType.artists, .count = 2216 },
        .{ .page_type = pdb.PageType.albums, .count = 2226 },
        .{ .page_type = pdb.PageType.labels, .count = 688 },
        .{ .page_type = pdb.PageType.keys, .count = 67 },
        .{ .page_type = pdb.PageType.colors, .count = 8 },
        .{ .page_type = pdb.PageType.playlist_tree, .count = 104 },
        .{ .page_type = pdb.PageType.playlist_entries, .count = 7440 },
        .{ .page_type = pdb.PageType.history_playlists, .count = 1 },
        .{ .page_type = pdb.PageType.history_entries, .count = 73 },
        .{ .page_type = pdb.PageType.artwork, .count = 2178 },
        .{ .page_type = pdb.PageType.columns, .count = 27 },
        .{ .page_type = pdb.PageType.menu, .count = 22 },
        .{ .page_type = pdb.PageType.history, .count = 1 },
    };
    inline for (expectations) |case|
        try testing.expectEqual(case.count, try countTableRows(&db, case.page_type));

    // The database carries a table of an unknown page type (wire value
    // 18) with 17 rows; the row model does not cover it, so its data
    // page is kept raw and written back verbatim.
    try testing.expectError(
        error.UnparsedPage,
        countTableRows(&db, @enumFromInt(18)),
    );
}

test "deleted-row page fixture pins dead-space zeroing and idempotent writes" {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(
        alloc,
        "pdb/unit_tests/history_page_deleted.bin",
        .limited(1 << 16),
    );
    defer alloc.free(input);

    var c = bin.Cursor.initAlloc(alloc, input);
    var page = try pdb.Page.decode(&c, alloc, input.len, .plain);
    defer page.deinit(alloc);
    // demo_tracks history page 40: twelve used row slots, one valid row.
    try testing.expect(page.header.page_flags.contains_deleted);
    try testing.expectEqual(pdb.PageType.history, page.header.page_type);
    try testing.expectEqual(@as(u32, 12), page.header.packed_row_counts.num_rows);
    try testing.expectEqual(@as(u32, 1), page.header.packed_row_counts.num_rows_valid);
    try testing.expectEqual(@as(usize, 1), page.content.data.rows.len);

    var e1 = bin.Emitter.init(alloc);
    defer e1.deinit();
    try page.encode(&e1, input.len);
    const out1 = e1.written();

    // The write is allowed to differ from the fixture only by zeroing:
    // every differing output byte is zero (deleted-row remnants).
    var differing: usize = 0;
    for (input, out1) |in_byte, out_byte| {
        if (in_byte == out_byte) continue;
        differing += 1;
        try testing.expectEqual(@as(u8, 0), out_byte);
    }
    try testing.expect(differing > 0);

    // And it is idempotent: re-parsing the output and writing again is
    // byte-stable and keeps the same page.
    var c2 = bin.Cursor.initAlloc(alloc, out1);
    var reparsed = try pdb.Page.decode(&c2, alloc, input.len, .plain);
    defer reparsed.deinit(alloc);
    var e2 = bin.Emitter.init(alloc);
    defer e2.deinit();
    try reparsed.encode(&e2, input.len);
    try testing.expectEqualSlices(u8, out1, e2.written());
    try testing.expect(page.eql(&reparsed));
}

/// Perf budget of the full-image model on the largest fixture, in
/// milliseconds of Debug build: the tripwire for the lazy-pages fallback
/// (see PLAN.md, "Revisit triggers").
const num_rows_perf_budget_ms = 2000;

test "num_rows parses and serializes within the perf budget" {
    const alloc = testing.allocator;
    const io = testing.io;
    const input = try testutil.readFixture(alloc, "pdb/num_rows/export.pdb", .limited(1 << 22));
    defer alloc.free(input);

    const start = std.Io.Timestamp.now(io, .awake);
    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();
    const out = try db.serialize(alloc);
    defer alloc.free(out);
    const elapsed_ns: u64 = @intCast(start.durationTo(
        std.Io.Timestamp.now(io, .awake),
    ).nanoseconds);

    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    try testing.expect(elapsed_ms < num_rows_perf_budget_ms);
}

// Data page and simple row tests, ported from the row tests of
// rekordcrate's `test_roundtrip.rs` and the page semantics of
// `mod.rs`.

/// Mirrors the row tests of rekordcrate's `test_roundtrip`: parses
/// `bytes` expecting `expected`, re-encodes `expected` expecting `bytes`
/// back, and checks `rowHeapBytesRequired` against the serialized
/// length, all through the generic row codec. `expected` must not own
/// memory, since it is never deinit-ed; strings in it are borrowed from
/// the caller. `end_pos` is the cursor position the parse must end at —
/// the buffer end for rows whose strings are inline, directly after the
/// offsets for rows with a trailing offset array (whose items are read
/// via sub-cursors at their offsets).
fn expectRowRoundtrip(
    comptime T: type,
    bytes: []const u8,
    expected: T,
    end_pos: ?usize,
) !void {
    var c = bin.Cursor.initAlloc(testing.allocator, bytes);
    var parsed = try pdb.decodeRow(T, &c);
    defer pdb.rowDeinit(T, &parsed, testing.allocator);
    try testing.expectEqual(end_pos orelse bytes.len, c.pos);
    try testing.expect(pdb.rowEql(T, &expected, &parsed));

    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try pdb.encodeRow(T, &expected, &e);
    try testing.expectEqualSlices(u8, bytes, e.written());

    try testing.expectEqual(
        @as(u16, @intCast(bytes.len)),
        pdb.rowHeapBytesRequired(T, &expected),
    );
}

test "label row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "Loopmasters");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        pdb.Label,
        &.{ 1, 0, 0, 0, 25, 76, 111, 111, 112, 109, 97, 115, 116, 101, 114, 115 },
        .{ .id = 1, .name = name },
        null,
    );
}

test "key row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "Dm");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        pdb.Key,
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 7, 68, 109 },
        .{ .id = 1, .id2 = 1, .name = name },
        null,
    );
}

test "color row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "Pink");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        pdb.Color,
        &.{ 0, 0, 0, 0, 1, 1, 0, 0, 11, 80, 105, 110, 107 },
        .{ .unknown2 = 1, .color = .pink, .name = name },
        null,
    );
}

test "playlist entry row roundtrips" {
    try expectRowRoundtrip(
        pdb.PlaylistEntry,
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0 },
        .{ .entry_index = 1, .track_id = 1, .playlist_id = 6 },
        null,
    );
}

test "column entry row wraps its name in interlinear annotation anchors" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "\u{fffa}GENRE\u{fffb}");
    defer name.deinit(testing.allocator);
    // The anchors are non-ASCII, so the string takes the long UCS-2LE
    // form even though the name itself is ASCII.
    try testing.expect(std.meta.activeTag(name.long) == .ucs2le);
    try expectRowRoundtrip(
        pdb.ColumnEntry,
        &.{
            0x01, 0x00, 0x80, 0x00, 0x90, 0x12, 0x00, 0x00, 0xfa, 0xff, 0x47, 0x00, 0x45,
            0x00, 0x4e, 0x00, 0x52, 0x00, 0x45, 0x00, 0xfb, 0xff,
        },
        .{ .id = 1, .unknown0 = 128, .column_name = name },
        null,
    );
}

test "menu row roundtrips" {
    try expectRowRoundtrip(
        pdb.Menu,
        &.{ 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00 },
        .{
            .category_id = 2,
            .content_pointer = 2,
            .unknown = 2,
            .visibility = .visible,
            .sort_order = 1,
        },
        null,
    );
}

test "artist row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "Loopmasters");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        pdb.Artist,
        &.{
            96,  0, 0, 0, 1, 0, 0, 0, 3, 10, 25, 76, 111, 111, 112, 109, 97, 115, 116, 101, 114,
            115,
        },
        .{
            .subtype = 0x60,
            .id = 1,
            .offsets = .{
                .offsets = .{ .provided = .{ .size = .u8, .values = .{10} } },
                .inner = .{ .name = name },
            },
        },
        10,
    );
}

test "album rows roundtrip" {
    const alloc = testing.allocator;
    {
        var name = try pdb.DeviceSQLString.fromUtf8(alloc, "GOOD LUCK");
        defer name.deinit(alloc);
        try expectRowRoundtrip(
            pdb.Album,
            &.{
                0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x16, 0x15, 0x47, 0x4f, 0x4f,
                0x44, 0x20, 0x4c, 0x55, 0x43, 0x4b,
            },
            .{
                .subtype = 0x80,
                .artist_id = 2,
                .id = 2,
                .offsets = .{
                    .offsets = .{ .provided = .{ .size = .u8, .values = .{0x16} } },
                    .inner = .{ .name = name },
                },
            },
            22,
        );
    }
    {
        var name = try pdb.DeviceSQLString.fromUtf8(alloc, "Techno Rave 2023");
        defer name.deinit(alloc);
        try expectRowRoundtrip(
            pdb.Album,
            &.{
                0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x16, 0x23, 0x54, 0x65, 0x63,
                0x68, 0x6e, 0x6f, 0x20, 0x52, 0x61, 0x76, 0x65, 0x20, 0x32, 0x30, 0x32, 0x33,
            },
            .{
                .subtype = 0x80,
                .artist_id = 0,
                .id = 3,
                .offsets = .{
                    .offsets = .{ .provided = .{ .size = .u8, .values = .{0x16} } },
                    .inner = .{ .name = name },
                },
            },
            22,
        );
    }
}

test "playlist tree node row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(
        testing.allocator,
        "current set 2021 reduced",
    );
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        pdb.PlaylistTreeNode,
        &.{
            0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    0,    1,    0,    0,    0,    1,    0,    0,    0,    0x33, 0x63, 0x75, 0x72,
            0x72, 0x65, 0x6e, 0x74, 0x20, 0x73, 0x65, 0x74, 0x20, 0x32, 0x30, 0x32, 0x31, 0x20, 0x72, 0x65, 0x64, 0x75, 0x63, 0x65, 0x64,
        },
        .{ .id = 1, .node_is_folder = 1, .name = name },
        null,
    );
    try testing.expect((pdb.PlaylistTreeNode{ .node_is_folder = 1 }).isFolder());
    try testing.expect(!(pdb.PlaylistTreeNode{}).isFolder());
}

test "track row roundtrips" {
    const alloc = testing.allocator;
    var row = pdb.Track{
        .subtype = 0x24,
        .bitmask = 788224,
        .sample_rate = 44100,
        .file_size = 6899624,
        .unknown2 = 214020570,
        .unknown3 = 64128,
        .unknown4 = 1511,
        .key_id = 5,
        .label_id = 1,
        .bitrate = 320,
        .tempo = 12800,
        .artist_id = 1,
        .id = 1,
        .sample_depth = 16,
        .duration = 172,
        .unknown5 = 41,
        .file_type = .mp3,
        .offsets = .{
            .offsets = .{ .provided = .{ .size = .u16, .values = .{
                136, 137, 138, 140, 142, 143, 144, 145, 148, 149,
                150, 161, 162, 163, 164, 208, 219, 249, 262, 263,
                280,
            } } },
            .inner = .{
                .isrc = pdb.DeviceSQLString.empty(),
                .lyricist = pdb.DeviceSQLString.empty(),
                .unknown_string2 = try pdb.DeviceSQLString.fromUtf8(alloc, "3"),
                .unknown_string3 = try pdb.DeviceSQLString.fromUtf8(alloc, "3"),
                .unknown_string4 = pdb.DeviceSQLString.empty(),
                .message = pdb.DeviceSQLString.empty(),
                .publish_track_information = pdb.DeviceSQLString.empty(),
                .autoload_hotcues = try pdb.DeviceSQLString.fromUtf8(alloc, "ON"),
                .unknown_string5 = pdb.DeviceSQLString.empty(),
                .unknown_string6 = pdb.DeviceSQLString.empty(),
                .date_added = try pdb.DeviceSQLString.fromUtf8(alloc, "2018-05-25"),
                .release_date = pdb.DeviceSQLString.empty(),
                .mix_name = pdb.DeviceSQLString.empty(),
                .unknown_string7 = pdb.DeviceSQLString.empty(),
                .analyze_path = try pdb.DeviceSQLString.fromUtf8(
                    alloc,
                    "/PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT",
                ),
                .analyze_date = try pdb.DeviceSQLString.fromUtf8(alloc, "2022-02-02"),
                .comment = try pdb.DeviceSQLString.fromUtf8(
                    alloc,
                    "Tracks by www.loopmasters.com",
                ),
                .title = try pdb.DeviceSQLString.fromUtf8(alloc, "Demo Track 1"),
                .unknown_string8 = pdb.DeviceSQLString.empty(),
                .filename = try pdb.DeviceSQLString.fromUtf8(alloc, "Demo Track 1.mp3"),
                .file_path = try pdb.DeviceSQLString.fromUtf8(
                    alloc,
                    "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3",
                ),
            },
        },
    };
    defer row.offsets.deinit(alloc);
    // From a demo_tracks export; the parse ends directly after the
    // offsets, at the first string: 0x5C fixed fields plus the u16 magic
    // and 21 u16 offsets.
    try expectRowRoundtrip(
        pdb.Track,
        &.{
            36,  0,   0,   0,   0,   7,   12,  0,   68,  172, 0,   0,   0,   0,   0,   0,   168, 71,  105, 0,   218, 177, 193,
            12,  128, 250, 231, 5,   0,   0,   0,   0,   5,   0,   0,   0,   0,   0,   0,   0,   1,   0,   0,   0,   0,   0,
            0,   0,   64,  1,   0,   0,   0,   0,   0,   0,   0,   50,  0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,
            0,   0,   0,   1,   0,   0,   0,   0,   0,   0,   0,   0,   0,   16,  0,   172, 0,   41,  0,   0,   0,   1,   0,
            3,   0,   136, 0,   137, 0,   138, 0,   140, 0,   142, 0,   143, 0,   144, 0,   145, 0,   148, 0,   149, 0,   150,
            0,   161, 0,   162, 0,   163, 0,   164, 0,   208, 0,   219, 0,   249, 0,   6,   1,   7,   1,   24,  1,   3,   3,
            5,   51,  5,   51,  3,   3,   3,   7,   79,  78,  3,   3,   23,  50,  48,  49,  56,  45,  48,  53,  45,  50,  53,
            3,   3,   3,   89,  47,  80,  73,  79,  78,  69,  69,  82,  47,  85,  83,  66,  65,  78,  76,  90,  47,  80,  48,
            49,  54,  47,  48,  48,  48,  48,  56,  55,  53,  69,  47,  65,  78,  76,  90,  48,  48,  48,  48,  46,  68,  65,
            84,  23,  50,  48,  50,  50,  45,  48,  50,  45,  48,  50,  61,  84,  114, 97,  99,  107, 115, 32,  98,  121, 32,
            119, 119, 119, 46,  108, 111, 111, 112, 109, 97,  115, 116, 101, 114, 115, 46,  99,  111, 109, 27,  68,  101, 109,
            111, 32,  84,  114, 97,  99,  107, 32,  49,  3,   35,  68,  101, 109, 111, 32,  84,  114, 97,  99,  107, 32,  49,
            46,  109, 112, 51,  105, 47,  67,  111, 110, 116, 101, 110, 116, 115, 47,  76,  111, 111, 112, 109, 97,  115, 116,
            101, 114, 115, 47,  85,  110, 107, 110, 111, 119, 110, 65,  108, 98,  117, 109, 47,  68,  101, 109, 111, 32,  84,
            114, 97,  99,  107, 32,  49,  46,  109, 112, 51,
        },
        row,
        0x5C + 22 * 2,
    );
}

test "tag row roundtrips" {
    var name = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "TagCategory1");
    defer name.deinit(testing.allocator);
    // The first row of the tag_page fixture: a category. The parse ends
    // directly after the offsets: 0x1C fixed fields plus the u8 magic and
    // 2 u8 offsets.
    try expectRowRoundtrip(
        pdb.TagOrCategory,
        &.{
            0x80, 0x06, // subtype 0x0680
            0x00, 0x00, // index_shift
            0x00, 0x00, 0x00, 0x00, // unknown1
            0x00, 0x00, 0x00, 0x00, // unknown2
            0x00, 0x00, 0x00, 0x00, // parent_id
            0x00, 0x00, 0x00, 0x00, // position
            0x01, 0x00, 0x00, 0x00, // id
            0x00, 0x00, 0x00, 0x01, // raw_is_category = 1 << 24
            0x03, 0x1F, 0x2C, // offset array
            0x1B, 'T',  'a',
            'g',  'C',  'a',
            't',  'e',  'g',
            'o',  'r',  'y',
            '1',
            0x03, // unknown: empty
        },
        .{
            .id = 1,
            .raw_is_category = 1 << 24,
            .offsets = .{
                .offsets = .{ .provided = .{ .size = .u8, .values = .{ 0x1F, 0x2C } } },
                .inner = .{ .name = name, .unknown = pdb.DeviceSQLString.empty() },
            },
        },
        0x1C + 3,
    );
}

test "track tag row roundtrips" {
    // The first row of the track_tag_page fixture.
    try expectRowRoundtrip(
        pdb.TrackTag,
        &.{
            0x00, 0x00, 0x00, 0x00, // magic
            0x01, 0x00, 0x00, 0x00, // track_id
            0xAA, 0x1F, 0xE8, 0x94, // tag_id
            0x03, 0x00, 0x00, 0x00, // unknown_const
        },
        .{ .track_id = 1, .tag_id = 2498240426 },
        null,
    );

    // A nonzero magic is rejected on parse.
    const alloc = testing.allocator;
    var c = bin.Cursor.initAlloc(alloc, &.{
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xAA, 0x1F, 0xE8, 0x94,
        0x03, 0x00, 0x00, 0x00,
    });
    try testing.expectError(error.UnexpectedValue, pdb.decodeRow(pdb.TrackTag, &c));
}

test "history row roundtrips" {
    var date = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "2022-02-02");
    defer date.deinit(testing.allocator);
    var version = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "1000");
    defer version.deinit(testing.allocator);
    // Extracted from demo_tracks' export.pdb, page 40, heap offset 0xa0.
    try expectRowRoundtrip(
        pdb.History,
        &.{
            0x80, 0x02, 0x80, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17, 0x32,
            0x30, 0x32, 0x32, 0x2d, 0x30, 0x32, 0x2d, 0x30, 0x32, 0x19, 0x1e, 0x0b, 0x31, 0x30,
            0x30, 0x30, 0x03,
        },
        .{
            .subtype = 0x0280,
            .index_shift = 0x0080,
            .num_tracks = 5,
            .date = date,
            .version = version,
            .label = pdb.DeviceSQLString.empty(),
        },
        null,
    );
}

test "history row with label roundtrips" {
    var date = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "2024-04-18");
    defer date.deinit(testing.allocator);
    var version = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "1000");
    defer version.deinit(testing.allocator);
    var label = try pdb.DeviceSQLString.fromUtf8(testing.allocator, "ZAKS BACKUP");
    defer label.deinit(testing.allocator);
    // Extracted from num_rows' export.pdb, page 40, heap offset 0x298.
    try expectRowRoundtrip(
        pdb.History,
        &.{
            0x80, 0x02, 0xc0, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17, 0x32,
            0x30, 0x32, 0x34, 0x2d, 0x30, 0x34, 0x2d, 0x31, 0x38, 0x19, 0x1e, 0x0b, 0x31, 0x30,
            0x30, 0x30, 0x19, 0x5a, 0x41, 0x4b, 0x53, 0x20, 0x42, 0x41, 0x43, 0x4b, 0x55, 0x50,
        },
        .{
            .subtype = 0x0280,
            .index_shift = 0x01c0,
            .num_tracks = 12,
            .date = date,
            .version = version,
            .label = label,
        },
        null,
    );
}

test "history row rejects wrong magics" {
    const alloc = testing.allocator;
    var date = try pdb.DeviceSQLString.fromUtf8(alloc, "2022-02-02");
    defer date.deinit(alloc);
    const row = pdb.History{
        .subtype = 0x0280,
        .num_tracks = 5,
        .date = date,
    };
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try pdb.encodeRow(pdb.History, &row, &e);
    const bytes = e.written();

    // The row layout: subtype(2) index_shift(2) num_tracks(4) | zero
    // magic(4) at 8 | date at 12 | 0x1E19 magic(2) at 23 | version.
    // Corrupting a magic byte must fail the parse; corrupting the date
    // content must not trip the magic check.
    for ([_]usize{ 8, 23, 24 }) |i| {
        var corrupt = try alloc.dupe(u8, bytes);
        defer alloc.free(corrupt);
        corrupt[i] ^= 0xFF;
        var c = bin.Cursor.initAlloc(alloc, corrupt);
        try testing.expectError(error.UnexpectedValue, pdb.decodeRow(pdb.History, &c));
    }
    var corrupt_date = try alloc.dupe(u8, bytes);
    defer alloc.free(corrupt_date);
    corrupt_date[13] ^= 0xFF;
    var c = bin.Cursor.initAlloc(alloc, corrupt_date);
    var parsed = try pdb.decodeRow(pdb.History, &c);
    defer pdb.rowDeinit(pdb.History, &parsed, alloc);
}

test "row decode dispatches by page type" {
    const alloc = testing.allocator;

    var name = try pdb.DeviceSQLString.fromUtf8(alloc, "Techno");
    defer name.deinit(alloc);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try e.putInt(u32, 1, .little);
    try name.encode(&e);

    var c = bin.Cursor.initAlloc(alloc, e.written());
    var row = try pdb.Row.decode(&c, .genres, .plain);
    defer row.deinit(alloc);
    try testing.expect(std.meta.activeTag(row) == .genre);
    try testing.expectEqual(pdb.PageType.genres, row.pageType());

    // Unknown page type values, and plain page types in an ext database,
    // are rejected explicitly.
    var c4 = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(
        error.NotImplemented,
        pdb.Row.decode(&c4, @enumFromInt(0x63), .plain),
    );
    var c5 = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(
        error.NotImplemented,
        pdb.Row.decode(&c5, .genres, .ext),
    );
}

test "row decode gates plain and ext dispatch by database type" {
    const alloc = testing.allocator;

    // The wire value 3 means albums in plain databases: valid album bytes
    // parse as an album row only there.
    var album_name = try pdb.DeviceSQLString.fromUtf8(alloc, "GOOD LUCK");
    defer album_name.deinit(alloc);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try pdb.encodeRow(
        pdb.Album,
        &.{
            .subtype = 0x80,
            .artist_id = 2,
            .id = 2,
            .offsets = .{
                .offsets = .{ .provided = .{ .size = .u8, .values = .{0x16} } },
                .inner = .{ .name = album_name },
            },
        },
        &e,
    );
    var c = bin.Cursor.initAlloc(alloc, e.written());
    var album = try pdb.Row.decode(&c, .albums, .plain);
    defer album.deinit(alloc);
    try testing.expect(std.meta.activeTag(album) == .album);
    // In an ext database the same wire value dispatches to the tag codec,
    // which rejects the album layout.
    var c2 = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(error.InvalidFormat, pdb.Row.decode(&c2, .albums, .ext));

    // The same wire value means tags in ext databases: valid tag bytes
    // parse as a tag row there (and as an album in a plain database,
    // whose codec rejects the tag layout).
    var tag_name = try pdb.DeviceSQLString.fromUtf8(alloc, "TagCategory1");
    defer tag_name.deinit(alloc);
    var te = bin.Emitter.init(alloc);
    defer te.deinit();
    try pdb.encodeRow(
        pdb.TagOrCategory,
        &.{
            .id = 1,
            .raw_is_category = 1 << 24,
            .offsets = .{
                .offsets = .{ .provided = .{ .size = .u8, .values = .{ 0x1F, 0x2C } } },
                .inner = .{ .name = tag_name, .unknown = pdb.DeviceSQLString.empty() },
            },
        },
        &te,
    );
    var c3 = bin.Cursor.initAlloc(alloc, te.written());
    var tag = try pdb.Row.decode(
        &c3,
        @enumFromInt(@intFromEnum(pdb.ExtPageType.tag)),
        .ext,
    );
    defer tag.deinit(alloc);
    try testing.expect(std.meta.activeTag(tag) == .tag);
    try testing.expectEqual(
        @intFromEnum(pdb.ExtPageType.tag),
        @intFromEnum(tag.pageType()),
    );
    var c4 = bin.Cursor.initAlloc(alloc, te.written());
    try testing.expectError(error.InvalidFormat, pdb.Row.decode(&c4, .albums, .plain));
}

test "row group slots fill from the array end, presence bits upwards" {
    const group = pdb.RowGroup{
        .row_offsets = blk: {
            var offsets: [pdb.row_group_max_rows]u16 = @splat(0);
            offsets[14] = 0x0008; // second row, presence bit 1
            offsets[15] = 0x0000; // first row, presence bit 0
            break :blk offsets;
        },
        .row_presence_flags = 0x0003,
        .unknown = 0x0002,
    };

    try testing.expectEqual(@as(usize, 16), pdb.row_group_max_rows);
    try testing.expectEqual(@as(u16, 2), group.numPresent());
    try testing.expectEqual(@as(?u16, 0x0000), group.presentOffset(0));
    try testing.expectEqual(@as(?u16, 0x0008), group.presentOffset(1));
    try testing.expectEqual(@as(?u16, null), group.presentOffset(2));
    try testing.expectEqual(@as(?u16, null), group.presentOffset(15));
}

/// Builds a whole menu page (`page_size` 96, heap 56 bytes) around two
/// rows at offsets 0 and 8 and one row group, using `fill_gap` for the
/// four heap bytes the rows and group leave free.
fn menuPageBytes(fill_gap: u8) [96]u8 {
    var page: [96]u8 = @splat(0);
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    bin.putStruct(
        &e,
        pdb.PageHeader{
            .page_index = 3,
            .page_type = .menu,
            .next_page = 4,
            .packed_row_counts = .{ .num_rows = 2, .num_rows_valid = 2 },
            .free_size = 56 - 16 - pdb.row_group_size,
            .used_size = 16,
        },
        .little,
    ) catch unreachable;
    bin.putStruct(&e, pdb.DataPageHeader{ .unknown5 = 1 }, .little) catch unreachable;
    bin.putStruct(&e, pdb.Menu{ .category_id = 1, .unknown = 99 }, .little) catch unreachable;
    bin.putStruct(&e, pdb.Menu{ .category_id = 2, .content_pointer = 2 }, .little) catch unreachable;
    @memcpy(page[0..e.written().len], e.written());
    page[0x28 + 16] = fill_gap;

    // The row group is the last 36 bytes of the heap: fourteen leading
    // slots (heap bytes, here nonzero to pin verbatim preservation), the
    // two present offsets, presence flags, and the unknown field.
    const group_start = 96 - pdb.row_group_size;
    for (0..14, 0..) |slot, i| {
        std.mem.writeInt(u16, page[group_start + 2 * slot ..][0..2], @intCast(0x0101 + i), .little);
    }
    std.mem.writeInt(u16, page[group_start + 28 ..][0..2], 0x0008, .little);
    std.mem.writeInt(u16, page[group_start + 30 ..][0..2], 0x0000, .little);
    std.mem.writeInt(u16, page[group_start + 32 ..][0..2], 0x0003, .little);
    std.mem.writeInt(u16, page[group_start + 34 ..][0..2], 0x0002, .little);
    return page;
}

test "data page roundtrips with heap bytes in unused row group slots" {
    const alloc = testing.allocator;
    // The gap byte must be zero: heap bytes covered by neither a row nor
    // a row group are zero on write, as in the oracle's fresh writes.
    const page = menuPageBytes(0);

    var c = bin.Cursor.initAlloc(alloc, &page);
    const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
    var content = try pdb.DataPageContent.decode(&c, alloc, page.len, header, .plain);
    defer content.deinit(alloc);

    // The page parsed into its two rows in allocation order and one
    // group keeping the leading slots verbatim.
    try testing.expectEqual(@as(usize, 1), content.row_groups.len);
    try testing.expectEqual(@as(usize, 2), content.rows.len);
    try testing.expectEqual(@as(u16, 0), content.rows[0].offset);
    try testing.expectEqual(@as(u16, 8), content.rows[1].offset);
    var expected_a = pdb.Menu{ .category_id = 1, .unknown = 99 };
    var expected_b = pdb.Menu{ .category_id = 2, .content_pointer = 2 };
    try testing.expect(content.rows[0].row.eql(&.{ .menu = &expected_a }));
    try testing.expect(content.rows[1].row.eql(&.{ .menu = &expected_b }));
    try testing.expectEqual(@as(u16, 0x0101), content.row_groups[0].row_offsets[0]);

    const out = try roundtripPage(alloc, &page, .plain);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, &page, out);
}

test "data page encode rejects rows that overlap or reach the row groups" {
    const alloc = testing.allocator;
    var menu_row = pdb.Menu{};

    // Two 8-byte rows overlapping by four bytes.
    {
        var rows = [_]pdb.RowAtOffset{
            .{ .offset = 0, .row = .{ .menu = &menu_row } },
            .{ .offset = 4, .row = .{ .menu = &menu_row } },
        };
        var offsets: [pdb.row_group_max_rows]u16 = @splat(0);
        offsets[14] = 4;
        offsets[15] = 0;
        var groups = [_]pdb.RowGroup{.{
            .row_offsets = offsets,
            .row_presence_flags = 0x0003,
        }};
        const content = pdb.DataPageContent{ .row_groups = &groups, .rows = &rows };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try testing.expectError(error.UnexpectedValue, content.encode(&e, 96));
    }

    // The heap's row region ends at the row groups' first used byte. With
    // a full group (presence 0xffff) that is the block start, heap byte
    // 20 (the block spans heap bytes 20-55): a row may end exactly at 20,
    // one byte further is rejected. Offsets are heap-relative.
    {
        var rows = [_]pdb.RowAtOffset{
            .{ .offset = 4, .row = .{ .menu = &menu_row } },
            .{ .offset = 12, .row = .{ .menu = &menu_row } }, // ends at 20, the limit
        };
        var offsets: [pdb.row_group_max_rows]u16 = @splat(0);
        offsets[14] = 12;
        offsets[15] = 4;
        var groups = [_]pdb.RowGroup{.{
            .row_offsets = offsets,
            .row_presence_flags = 0xFFFF,
        }};
        const content = pdb.DataPageContent{ .row_groups = &groups, .rows = &rows };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try content.encode(&e, 96);
        try testing.expectEqual(@as(usize, 96 - 0x20), e.written().len);

        var late = [_]pdb.RowAtOffset{
            .{ .offset = 4, .row = .{ .menu = &menu_row } },
            .{ .offset = 13, .row = .{ .menu = &menu_row } }, // ends at 21, in the group
        };
        const reaching = pdb.DataPageContent{ .row_groups = &groups, .rows = &late };
        var e2 = bin.Emitter.init(alloc);
        defer e2.deinit();
        try testing.expectError(error.UnexpectedValue, reaching.encode(&e2, 96));
    }

    // The same row further up is legal when the leading slots are unused:
    // presence 0x0001 leaves heap bytes 20-49 as leading slots, and the
    // row ends exactly at the first used byte, 50.
    {
        var rows = [_]pdb.RowAtOffset{
            .{ .offset = 42, .row = .{ .menu = &menu_row } }, // ends at 50, the limit
        };
        var offsets: [pdb.row_group_max_rows]u16 = @splat(0);
        offsets[15] = 42;
        var groups = [_]pdb.RowGroup{.{
            .row_offsets = offsets,
            .row_presence_flags = 0x0001,
        }};
        const content = pdb.DataPageContent{ .row_groups = &groups, .rows = &rows };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try content.encode(&e, 96);
        try testing.expectEqual(@as(usize, 96 - 0x20), e.written().len);

        var over = [_]pdb.RowAtOffset{
            .{ .offset = 43, .row = .{ .menu = &menu_row } }, // ends at 51, past it
        };
        const reaching = pdb.DataPageContent{ .row_groups = &groups, .rows = &over };
        var e2 = bin.Emitter.init(alloc);
        defer e2.deinit();
        try testing.expectError(error.UnexpectedValue, reaching.encode(&e2, 96));
    }

    // Without row groups the whole heap is available, but not beyond it.
    {
        var rows = [_]pdb.RowAtOffset{
            .{ .offset = 56 - 8 + 1, .row = .{ .menu = &menu_row } },
        };
        const content = pdb.DataPageContent{ .rows = &rows };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try testing.expectError(error.UnexpectedValue, content.encode(&e, 96));
    }
}

test "data page encode derives page layout from row groups" {
    const alloc = testing.allocator;
    var page = menuPageBytes(0);
    // The constructed content carries zeros in the unused leading slots.
    @memset(page[96 - pdb.row_group_size ..][0 .. 2 * 14], 0);
    var menu_a = pdb.Menu{ .category_id = 1, .unknown = 99 };
    var menu_b = pdb.Menu{ .category_id = 2, .content_pointer = 2 };
    var rows = [_]pdb.RowAtOffset{
        .{ .offset = 0, .row = .{ .menu = &menu_a } },
        .{ .offset = 8, .row = .{ .menu = &menu_b } },
    };
    var offsets: [pdb.row_group_max_rows]u16 = @splat(0);
    offsets[14] = 0x0008;
    offsets[15] = 0x0000;
    var groups = [_]pdb.RowGroup{.{
        .row_offsets = offsets,
        .row_presence_flags = 0x0003,
        .unknown = 0x0002,
    }};
    const content = pdb.DataPageContent{
        .header = .{ .unknown5 = 1 },
        .row_groups = &groups,
        .rows = &rows,
    };

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try content.encode(&e, 96);
    try testing.expectEqualSlices(u8, page[0x20..], e.written());
}

test "data page decode rejects malformed pages" {
    const alloc = testing.allocator;

    // num_rows_valid disagreeing with the parsed row count.
    {
        var page = menuPageBytes(0);
        // num_rows_valid = 1: bit 13 of the packed counts; num_rows stays 2.
        page[0x19] = 0x20;
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
        try testing.expectError(
            error.UnexpectedValue,
            pdb.DataPageContent.decode(&c, alloc, page.len, header, .plain),
        );
    }

    // A row offset pointing past the page.
    {
        var page = menuPageBytes(0);
        const group_start = 96 - pdb.row_group_size;
        std.mem.writeInt(u16, page[group_start + 30 ..][0..2], 0xFFF0, .little);
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
        try testing.expectError(
            error.UnexpectedEof,
            pdb.DataPageContent.decode(&c, alloc, page.len, header, .plain),
        );
    }

    // A row offset pointing past the heap but inside the cursor's buffer
    // (what a whole-file cursor sees): the zero bytes there would parse
    // as a valid row; the heap-end bound rejects it.
    {
        var page = menuPageBytes(0);
        const group_start = 96 - pdb.row_group_size;
        std.mem.writeInt(u16, page[group_start + 28 ..][0..2], 0x1000, .little); // slot 14
        const bigger = try alloc.alloc(u8, 0x28 + 0x1000 + 8);
        defer alloc.free(bigger);
        @memset(bigger, 0);
        @memcpy(bigger[0..96], &page);
        var c = bin.Cursor.initAlloc(alloc, bigger);
        const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
        try testing.expectError(
            error.UnexpectedEof,
            pdb.DataPageContent.decode(&c, alloc, 96, header, .plain),
        );
    }

    // Row groups not fitting the page heap.
    {
        var page = menuPageBytes(0);
        page[0x18] = 0x12; // num_rows = 18: two row groups, one past the heap
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, pdb.PageHeader, .little);
        try testing.expectError(
            error.UnexpectedValue,
            pdb.DataPageContent.decode(&c, alloc, page.len, header, .plain),
        );
    }

    // A page smaller than its headers, and a page whose heap fits no
    // row group.
    {
        var c = bin.Cursor.init(&.{});
        try testing.expectError(
            error.UnexpectedValue,
            pdb.DataPageContent.decode(&c, alloc, 0x20, .{}, .plain),
        );
    }
    {
        var c = bin.Cursor.init(&([_]u8{0} ** 8));
        try testing.expectError(
            error.UnexpectedValue,
            pdb.DataPageContent.decode(&c, alloc, 0x28, .{ .packed_row_counts = .{ .num_rows = 1 } }, .plain),
        );
    }

    // More row groups than the page holds on write.
    {
        var many = [_]pdb.RowGroup{.{}} ** 2;
        const content = pdb.DataPageContent{ .row_groups = &many };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try testing.expectError(
            error.UnexpectedValue,
            content.encode(&e, 96 - 0x20),
        );
    }
}

// Modification layer tests, ported from rekordcrate's
// `src/pdb/test_modification.rs`, the `add_row`/`create` tests of
// `src/pdb/io.rs`, its `src/pdb/defaults.rs`, and
// `tests/test_pdb_write.rs`.

/// Parses the `num_rows` fixture as a plain database.
fn parseNumRows(alloc: std.mem.Allocator) !pdb.Database {
    const input = try testutil.readFixture(
        alloc,
        "pdb/num_rows/export.pdb",
        .limited(1 << 22),
    );
    defer alloc.free(input);
    return pdb.Database.parse(alloc, input, .plain);
}

/// Deep-clones a row by encoding and re-decoding it, allocating the copy
/// (strings included) with `alloc`. The roundtrip is byte-exact, so string
/// forms and provided offsets are preserved — the test stand-in for
/// Rust's `Clone`.
fn cloneRow(
    alloc: std.mem.Allocator,
    row: *const pdb.Row,
    db_type: pdb.DatabaseType,
) !pdb.Row {
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try row.encode(&e);
    var c = bin.Cursor.initAlloc(alloc, e.written());
    return pdb.Row.decode(&c, row.pageType(), db_type);
}

/// Builds a boxed pdb.Key row with `id` duplicated into `id2`, for the
/// allocate tests ported from rekordcrate's `test_modification.rs`.
fn testKeyRow(a: std.mem.Allocator, id: u32, name: []const u8) !pdb.Row {
    const key = try a.create(pdb.Key);
    key.* = .{
        .id = id,
        .id2 = id,
        .name = try pdb.DeviceSQLString.fromUtf8(a, name),
    };
    return pdb.Row{ .key = key };
}

/// A Keys data page holding one full row group of sixteen rows (the setup
/// of rekordcrate's `allocate_row_full_row_group`).
fn fullKeysPage(a: std.mem.Allocator) !pdb.Page {
    const names = [pdb.row_group_max_rows][]const u8{
        "Emin",  "Fmaj", "E",    "Amin", "2d", "Bmin", "Cmin",  "Cmaj",
        "Abmin", "Dmin", "Gmin", "Dm",   "Am", "A#",   "G#min", "A#min",
    };
    const offsets = [pdb.row_group_max_rows]u16{
        0x0000, 0x0010, 0x0020, 0x002C, 0x003C, 0x0048, 0x0058, 0x0068,
        0x0078, 0x0088, 0x0098, 0x00A8, 0x00B4, 0x00C0, 0x00CC, 0x00DC,
    };
    var group = pdb.RowGroup{ .row_presence_flags = 0xFFFF };
    const rows = try a.alloc(pdb.RowAtOffset, pdb.row_group_max_rows);
    for (names, offsets, 0..) |name, offset, i| {
        group.row_offsets[pdb.row_group_max_rows - 1 - i] = offset;
        rows[i] = .{ .offset = offset, .row = try testKeyRow(a, @intCast(i + 1), name) };
    }
    return pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 16, .num_rows_valid = 16 },
            .free_size = 2000,
            .used_size = 0x00EC,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{group}),
            .rows = rows,
        } },
    };
}

test "allocRow on an empty page charges row, group header, and offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var page = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .free_size = 3000,
        },
        .content = .{ .data = .{} },
    };

    var row = try testKeyRow(a, 1, "Emin");
    const ticket = (try page.allocRow(a, row.heapBytesRequired())).?;
    try page.commitRow(a, ticket, row);

    const expected = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 1, .num_rows_valid = 1 },
            // The 13-byte row aligns to 16 bytes; the new group's header
            // (4) and the offset slot (2) are charged besides.
            .free_size = 2978,
            .used_size = 16,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{.{ .row_presence_flags = 0x0001 }}),
            .rows = try a.dupe(pdb.RowAtOffset, &.{.{ .offset = 0x0000, .row = row }}),
        } },
    };
    try testing.expect(page.eql(&expected));
}

test "allocRow with room in the existing group charges only the offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row1 = try testKeyRow(a, 1, "Emin");
    var page = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 1, .num_rows_valid = 1 },
            .free_size = 2978,
            .used_size = 16,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{.{ .row_presence_flags = 0x0001 }}),
            .rows = try a.dupe(pdb.RowAtOffset, &.{.{ .offset = 0x0000, .row = row1 }}),
        } },
    };

    var row2 = try testKeyRow(a, 2, "Fmaj");
    const ticket = (try page.allocRow(a, row2.heapBytesRequired())).?;
    try page.commitRow(a, ticket, row2);

    var expected_group = pdb.RowGroup{ .row_presence_flags = 0x0003 };
    expected_group.row_offsets[14] = 0x0010;
    const expected = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 2, .num_rows_valid = 2 },
            // Again 16 aligned bytes plus the one offset slot.
            .free_size = 2960,
            .used_size = 32,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{expected_group}),
            .rows = try a.dupe(pdb.RowAtOffset, &.{
                .{ .offset = 0x0000, .row = row1 },
                .{ .offset = 0x0010, .row = row2 },
            }),
        } },
    };
    try testing.expect(page.eql(&expected));
}

test "an uncommitted allocRow leaves the interrupted state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row1 = try testKeyRow(a, 1, "Emin");
    var page = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 1, .num_rows_valid = 1 },
            .free_size = 2978,
            .used_size = 16,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{.{ .row_presence_flags = 0x0001 }}),
            .rows = try a.dupe(pdb.RowAtOffset, &.{.{ .offset = 0x0000, .row = row1 }}),
        } },
    };

    // Dropped without a commit: the offset slot and `num_rows` account
    // for the row, the presence bit and `num_rows_valid` do not.
    _ = (try page.allocRow(a, 16)).?;

    var expected_group = pdb.RowGroup{ .row_presence_flags = 0x0001 };
    expected_group.row_offsets[14] = 0x0010;
    const expected = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .packed_row_counts = .{ .num_rows = 2, .num_rows_valid = 1 },
            .free_size = 2960,
            .used_size = 32,
        },
        .content = .{ .data = .{
            .row_groups = try a.dupe(pdb.RowGroup, &.{expected_group}),
            .rows = try a.dupe(pdb.RowAtOffset, &.{.{ .offset = 0x0000, .row = row1 }}),
        } },
    };
    try testing.expect(page.eql(&expected));
}

test "allocRow opens a second row group when the first is full" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var page = try fullKeysPage(a);
    var row = try testKeyRow(a, 17, "Amaj");
    const ticket = (try page.allocRow(a, row.heapBytesRequired())).?;
    try page.commitRow(a, ticket, row);

    var second_group = pdb.RowGroup{ .row_presence_flags = 0x0001 };
    second_group.row_offsets[15] = 0x00EC;
    var expected = try fullKeysPage(a);
    expected.header.packed_row_counts = .{ .num_rows = 17, .num_rows_valid = 17 };
    expected.header.free_size = 1978;
    expected.header.used_size = 0x00FC;
    expected.content.data.row_groups = try a.realloc(
        expected.content.data.row_groups,
        2,
    );
    expected.content.data.row_groups[1] = second_group;
    expected.content.data.rows = try a.realloc(expected.content.data.rows, 17);
    expected.content.data.rows[16] = .{ .offset = 0x00EC, .row = row };
    try testing.expect(page.eql(&expected));
}

test "allocRow returns null on a full page without mutating it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tiny free size fakes a full page without constructing any rows.
    var page = pdb.Page{
        .header = .{
            .page_index = 12,
            .page_type = .keys,
            .next_page = 51,
            .unknown1 = 13484,
            .free_size = 1,
        },
        .content = .{ .data = .{} },
    };

    var row = try testKeyRow(a, 1, "Emin");
    try testing.expect((try page.allocRow(a, row.heapBytesRequired())) == null);
    try testing.expectEqual(@as(u16, 0), page.header.used_size);
    try testing.expectEqual(@as(u16, 1), page.header.free_size);
    try testing.expectEqual(@as(u13, 0), page.header.packed_row_counts.num_rows);

    // Index pages never allocate rows at all.
    var index_page = pdb.Page.newIndex(12, .keys, 0x03FF_FFFF);
    try testing.expect((try index_page.allocRow(a, 16)) == null);
}

test "allocDataPage updates the header and grows storage" {
    const alloc = testing.allocator;
    var db = try parseNumRows(alloc);
    defer db.deinit();
    const next_unused_before = db.header.next_unused_page;

    const new_page_index = try db.allocDataPage(.keys);

    try testing.expectEqual(next_unused_before, new_page_index);
    // Storage covers every page index up to the new one, plus gap slots
    // for any indexes the file lacked.
    try testing.expectEqual(@as(usize, new_page_index), db.pages.len);
    try testing.expectEqual(next_unused_before + 1, db.header.next_unused_page);

    const new_page = db.pages[new_page_index - 1].page;
    try testing.expectEqual(new_page_index, new_page.header.page_index);
    try testing.expectEqual(pdb.PageType.keys, new_page.header.page_type);
    try testing.expectEqual(pdb.page_chain_end, new_page.header.next_page);
    try testing.expect(new_page.content == .data);
    // The whole heap free: the page behind its 0x20-byte header and the
    // 8-byte data page header.
    try testing.expectEqual(@as(u16, 4056), new_page.header.free_size);
    try testing.expectEqual(@as(u16, 0), new_page.header.used_size);
}

test "addRow patches both next_page copies when linking a new page" {
    const alloc = testing.allocator;
    var db = try parseNumRows(alloc);
    defer db.deinit();

    const tracks_table = db.header.findTableMut(.tracks).?;
    const first_page_index = tracks_table.first_page;
    const original_last_page = tracks_table.last_page;

    // A template track cloned from the original tail page.
    const template = blk: {
        const page = db.pages[original_last_page - 1].page;
        try testing.expect(page.content == .data);
        try testing.expect(page.content.data.rows.len > 0);
        break :blk try cloneRow(
            db.arena.allocator(),
            &page.content.data.rows[0].row,
            .plain,
        );
    };

    // The first page is an index page; disconnecting it and naming it the
    // tail forces `addRow` down the fresh-page path.
    {
        const first = &db.pages[first_page_index - 1].page;
        try testing.expect(first.content == .index);
        first.header.next_page = pdb.page_chain_end;
        first.content.index.header.next_page = pdb.page_chain_end;
    }
    db.header.findTableMut(.tracks).?.last_page = first_page_index;

    var row = template;
    const row_ref = try db.addRow(&row);

    try testing.expectEqual(@as(u16, 0), row_ref.row_offset);
    const first = db.pages[first_page_index - 1].page;
    try testing.expectEqual(row_ref.page_index, first.header.next_page);
    try testing.expectEqual(row_ref.page_index, first.content.index.header.next_page);
    try testing.expectEqual(row_ref.page_index, db.header.findTable(.tracks).?.last_page);
}

test "addRow-allocated pages are reachable through the chain" {
    const alloc = testing.allocator;
    var db = try parseNumRows(alloc);
    defer db.deinit();
    const next_unused_before = db.header.next_unused_page;
    const entries_before = try countTableRows(&db, .history_entries);

    // The tail page has 8 bytes free — less than a HistoryEntry row — so
    // appending forces a fresh page (rekordcrate's fixture note).
    const template = blk: {
        const table = db.header.findTable(.history_entries).?;
        var current = table.first_page;
        while (true) {
            const page = db.pages[current - 1].page;
            if (page.content == .data and page.content.data.rows.len > 0)
                break :blk try cloneRow(
                    db.arena.allocator(),
                    &page.content.data.rows[0].row,
                    .plain,
                );
            if (current == table.last_page) return error.TestUnexpectedResult;
            current = page.header.next_page;
        }
    };
    var first = template;
    var second = try cloneRow(db.arena.allocator(), &template, .plain);
    _ = try db.addRow(&first);
    // The second append lands on the freshly allocated page, exercising
    // link-following too.
    _ = try db.addRow(&second);

    try testing.expect(db.header.next_unused_page > next_unused_before);

    const out = try db.serialize(alloc);
    defer alloc.free(out);
    var reparsed = try pdb.Database.parse(alloc, out, .plain);
    defer reparsed.deinit();
    try testing.expectEqual(
        entries_before + 2,
        try countTableRows(&reparsed, .history_entries),
    );
}

test "create initializes an index/data page pair per table" {
    const table_page_types = [_]pdb.PageType{ .tracks, .artists };
    var db = try pdb.Database.create(testing.allocator, .plain, &table_page_types);
    defer db.deinit();

    try testing.expectEqual(@as(u32, 4096), db.header.page_size);
    try testing.expectEqual(@as(u32, 2), db.header.num_tables);
    try testing.expectEqual(@as(u32, 5), db.header.next_unused_page);
    try testing.expectEqual(@as(usize, 4), db.pages.len);

    const tracks_table = &db.header.tables[0];
    try testing.expectEqual(@as(u32, 1), tracks_table.first_page);
    // Empty table: the logical chain tail is the index page.
    try testing.expectEqual(@as(u32, 1), tracks_table.last_page);
    try testing.expectEqual(@as(u32, 2), tracks_table.empty_candidate);
    const artists_table = &db.header.tables[1];
    try testing.expectEqual(@as(u32, 3), artists_table.first_page);
    try testing.expectEqual(@as(u32, 3), artists_table.last_page);
    try testing.expectEqual(@as(u32, 4), artists_table.empty_candidate);

    const tracks_index = db.pages[0].page;
    try testing.expect(tracks_index.content == .index);
    try testing.expectEqual(@as(u32, 1), tracks_index.header.page_index);
    try testing.expectEqual(pdb.page_chain_end, tracks_index.header.next_page);
    try testing.expectEqual(pdb.page_chain_end, tracks_index.content.index.header.next_page);

    const tracks_data = db.pages[1].page;
    try testing.expect(tracks_data.content == .data);
    try testing.expectEqual(@as(u32, 2), tracks_data.header.page_index);
    try testing.expectEqual(pdb.page_chain_end, tracks_data.header.next_page);
    try testing.expectEqual(@as(u16, 4056), tracks_data.header.free_size);
    try testing.expectEqual(@as(u16, 0), tracks_data.header.used_size);
}

test "create closes every new data page with the chain-end sentinel" {
    const table_page_types = [_]pdb.PageType{ .tracks, .genres, .artists };
    var db = try pdb.Database.create(testing.allocator, .plain, &table_page_types);
    defer db.deinit();

    for (db.pages) |slot| switch (slot) {
        .page => |page| if (page.content == .data) {
            try testing.expectEqual(pdb.page_chain_end, page.header.next_page);
        },
        .raw => unreachable,
    };
}

/// The undersized Track row of rekordcrate's
/// `test_add_row_rejects_undersized_track_row`: 200 heap bytes (92 fixed
/// + 44 offset array + 64 string bytes), already 4-aligned, still below
/// the 221-byte minimum.
fn undersizedTestTrack(a: std.mem.Allocator) !pdb.Track {
    return .{
        .id = 1,
        .artist_id = 1,
        .album_id = 1,
        .offsets = .{ .inner = .{
            .title = try pdb.DeviceSQLString.fromUtf8(a, "Music"),
            .filename = try pdb.DeviceSQLString.fromUtf8(a, "02 - Music.mp3"),
            .file_path = try pdb.DeviceSQLString.fromUtf8(a, "/Contents/02 - Music.mp3"),
        } },
    };
}

test "addRow rejects undersized track rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const track = try undersizedTestTrack(a);
    try testing.expectEqual(@as(u16, 200), pdb.rowHeapBytesRequired(pdb.Track, &track));
    try testing.expectEqual(@as(u16, 200), pdb.allocatedRowSize(pdb.rowHeapBytesRequired(pdb.Track, &track)));

    const table_page_types = [_]pdb.PageType{.tracks};
    var db = try pdb.Database.create(testing.allocator, .plain, &table_page_types);
    defer db.deinit();

    const boxed = try a.create(pdb.Track);
    boxed.* = track;
    var row = pdb.Row{ .track = boxed };
    try testing.expectError(error.TrackRowTooSmall, db.addRow(&row));
    // Nothing was inserted anywhere.
    try testing.expectEqual(@as(usize, 0), try countTableRows(&db, .tracks));
}

test "padTrackCommentToMinimum grows the comment to the row minimum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var track = try undersizedTestTrack(a);
    try pdb.padTrackCommentToMinimum(&track, a);
    try pdb.validateTrackRowSize(&track);

    // 21 spaces grow the empty comment from 1 to 22 bytes: 200 + 21 = 221
    // heap bytes, 224 allocated.
    try testing.expectEqual(
        @as(u16, 224),
        pdb.allocatedRowSize(pdb.rowHeapBytesRequired(pdb.Track, &track)),
    );
    const text = try track.offsets.inner.comment.utf8(a);
    try testing.expectEqual(@as(usize, 21), text.len);
    try testing.expect(std.mem.allEqual(u8, text, ' '));
}

/// The first row of the table for `page_type`, by page-chain order.
fn firstTableRow(db: *const pdb.Database, page_type: pdb.PageType) !*const pdb.Row {
    const table = db.header.findTable(page_type) orelse return error.NoTable;
    var current = table.first_page;
    while (true) {
        const page = switch (db.pages[current - 1]) {
            .page => |*page| page,
            .raw => return error.UnparsedPage,
        };
        switch (page.content) {
            .data => |*content| if (content.rows.len > 0)
                return &content.rows[0].row,
            .index => {},
        }
        if (current == table.last_page) break;
        current = page.header.next_page;
    }
    return error.NoRows;
}

test "created databases carry the default color, column, and menu rows" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
    defer db.deinit();
    try pdb.insertDefaultColors(&db);
    try pdb.insertDefaultColumns(&db);
    try pdb.insertDefaultMenus(&db);

    try testing.expectEqual(@as(usize, 8), try countTableRows(&db, .colors));
    try testing.expectEqual(@as(usize, 27), try countTableRows(&db, .columns));
    try testing.expectEqual(@as(usize, 22), try countTableRows(&db, .menu));

    // Spot-check the first color row and the GENRE column row.
    const color_row = try firstTableRow(&db, .colors);
    try testing.expectEqual(@as(u32, 0), color_row.color.unknown1);
    try testing.expectEqual(@as(u8, 1), color_row.color.unknown2);
    try testing.expectEqual(util.ColorIndex.pink, color_row.color.color);
    try testing.expectEqualStrings(
        "Pink",
        try color_row.color.name.utf8(db.arena.allocator()),
    );
    const column_row = try firstTableRow(&db, .columns);
    try testing.expectEqual(@as(u16, 1), column_row.column_entry.id);
    try testing.expectEqual(@as(u16, 128), column_row.column_entry.unknown0);
    try testing.expectEqualStrings(
        "\u{FFFA}GENRE\u{FFFB}",
        try column_row.column_entry.column_name.utf8(db.arena.allocator()),
    );

    // The created database serializes, re-parses with the same defaults,
    // and re-serializes byte-stable.
    const out = try db.serialize(alloc);
    defer alloc.free(out);
    var reparsed = try pdb.Database.parse(alloc, out, .plain);
    defer reparsed.deinit();
    try testing.expectEqual(@as(usize, 8), try countTableRows(&reparsed, .colors));
    try testing.expectEqual(@as(usize, 27), try countTableRows(&reparsed, .columns));
    try testing.expectEqual(@as(usize, 22), try countTableRows(&reparsed, .menu));
    const out2 = try reparsed.serialize(alloc);
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

/// Counts the track rows with `rating`, by walking the tracks table's
/// page chain.
fn countTracks(db: *const pdb.Database, rating: u8) !usize {
    var it = try db.rows(.tracks);
    var count: usize = 0;
    while (try it.next()) |row| switch (row.*) {
        .track => |track| {
            if (track.rating == rating) count += 1;
        },
        else => {},
    };
    return count;
}

test "num_rows mutation: set all track ratings and round-trip" {
    const alloc = testing.allocator;
    var db = try parseNumRows(alloc);
    defer db.deinit();

    // Set the rating of every track to 5 stars (ported from rekordcrate's
    // tests/test_pdb_write.rs); the fixed-size edit leaves every row's
    // serialized length unchanged.
    const table = db.header.findTable(.tracks).?;
    var current = table.first_page;
    while (true) {
        const page = &db.pages[current - 1].page;
        switch (page.content) {
            .data => |*content| for (content.rows) |*at| switch (at.row) {
                .track => |track| track.rating = 5,
                else => {},
            },
            .index => {},
        }
        if (current == table.last_page) break;
        current = page.header.next_page;
    }

    // rekordcrate's flush validates every track row before writing.
    try db.validateAllTrackRows();

    const out = try db.serialize(alloc);
    defer alloc.free(out);
    var reparsed = try pdb.Database.parse(alloc, out, .plain);
    defer reparsed.deinit();

    try testing.expectEqual(@as(usize, 3886), try countTracks(&reparsed, 5));
    try testing.expectEqual(@as(usize, 0), try countTracks(&reparsed, 0));

    // The mutated image re-serializes byte-stable.
    const out2 = try reparsed.serialize(alloc);
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

/// Finds the track row with `id`, by walking the tracks table's page
/// chain.
fn findTrack(db: *const pdb.Database, id: u32) !*const pdb.Track {
    const table = db.header.findTable(.tracks) orelse return error.NoTable;
    var current = table.first_page;
    while (true) {
        const page = switch (db.pages[current - 1]) {
            .page => |*page| page,
            .raw => return error.UnparsedPage,
        };
        switch (page.content) {
            .data => |*content| for (content.rows) |*at| switch (at.row) {
                .track => |track| if (track.id == id) return track,
                else => {},
            },
            .index => {},
        }
        if (current == table.last_page) break;
        current = page.header.next_page;
    }
    return error.NoRows;
}

test "num_rows append: track row with new strings via calculated offsets" {
    const alloc = testing.allocator;
    var db = try parseNumRows(alloc);
    defer db.deinit();
    const before = try countTableRows(&db, .tracks);

    // A track built from scratch — its offset array defaults to calculated,
    // so all 21 offsets are computed and patched during serialization. The
    // title is non-ASCII, placing a UCS-2LE item that must land 4-byte
    // aligned behind the strings before it.
    const a = db.arena.allocator();
    const track = pdb.Track{
        .id = 999_999,
        .artist_id = 1,
        .album_id = 1,
        .sample_rate = 44_100,
        .bitrate = 320,
        .tempo = 12_800,
        .duration = 200,
        .rating = 3,
        .offsets = .{ .inner = .{
            .title = try pdb.DeviceSQLString.fromUtf8(a, "I ♥ Zig"),
            .filename = try pdb.DeviceSQLString.fromUtf8(a, "01 - Calculated.mp3"),
            .file_path = try pdb.DeviceSQLString.fromUtf8(a, "/Contents/01 - Calculated.mp3"),
        } },
    };
    try pdb.validateTrackRowSize(&track);

    const boxed = try a.create(pdb.Track);
    boxed.* = track;
    var row = pdb.Row{ .track = boxed };
    _ = try db.addRow(&row);
    try db.validateAllTrackRows();

    const out = try db.serialize(alloc);
    defer alloc.free(out);
    var reparsed = try pdb.Database.parse(alloc, out, .plain);
    defer reparsed.deinit();

    // The appended row is reachable and carries the new strings.
    try testing.expectEqual(before + 1, try countTableRows(&reparsed, .tracks));
    const added = try findTrack(&reparsed, 999_999);
    try testing.expectEqual(@as(u32, 12_800), added.tempo);
    try testing.expectEqual(@as(u8, 3), added.rating);
    const ra = reparsed.arena.allocator();
    try testing.expectEqualStrings(
        "I ♥ Zig",
        try added.offsets.inner.title.utf8(ra),
    );
    try testing.expectEqualStrings(
        "/Contents/01 - Calculated.mp3",
        try added.offsets.inner.file_path.utf8(ra),
    );

    // The calculated offsets are canonical: the re-parsed image
    // re-serializes byte-stable.
    const out2 = try reparsed.serialize(alloc);
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}
