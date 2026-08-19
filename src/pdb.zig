// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the rekordbox `export.pdb` database (DeviceSQL).
//!
//! Currently contains `DeviceSQLString`, the string type used by all row
//! types; pages, rows, and tables are not implemented yet.
//!
//! Initially ported from rekordcrate's `src/pdb/string.rs`
//!
//! - <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/exports.html#devicesql-strings>

const std = @import("std");
const bin = @import("bin");

/// Decoding error; `InvalidFormat` means the bytes do not follow the
/// DeviceSQL string format.
pub const DecodeError = bin.ReadError || error{InvalidFormat};

/// Longest content that fits the short form: the header
/// `((len + 1) << 1) | 1` must fit a `u8`.
const max_short_len: usize = (std.math.maxInt(u8) >> 1) - 1;

/// Longest string `fromUtf8` accepts, in UTF-8 bytes, as in rekordcrate.
const max_len: usize = std.math.maxInt(i16);

/// Bytes a long-form header occupies: flags byte, `u16` length, padding.
const long_header_len: u16 = 4;

/// Flags byte of a long string with a raw-ASCII body.
const long_flags_ascii: u8 = 0x40;
/// Flags byte of a long string whose body is an ISRC or UCS-2LE text; which
/// of the two it is gets decided by the body's shape.
const long_flags_isrc_or_ucs2: u8 = 0x90;

/// An immutable DeviceSQL string, as stored in the page heaps of
/// `export.pdb`.
///
/// Two forms exist, told apart by the least significant bit of the first
/// byte:
///
/// * short ASCII: one header byte `((len + 1) << 1) | 1` (bit set) followed
///   by `len` content bytes. The empty string is the single byte `0x03`.
/// * long: a flags byte (bit clear), a little-endian `u16` length covering
///   all four header bytes, a `0x00` padding byte, and a body selected by
///   the flags:
///   * `0x40`: `length - 4` raw ASCII bytes.
///   * `0x90`: an ISRC — `0x03` magic byte, NUL-terminated ASCII, a Pioneer
///     quirk, see `fromIsrc` — or UCS-2LE code units. The ISRC shape is
///     tried first, so a body of that shape is an ISRC even when its bytes
///     would also read as valid UCS-2LE.
pub const DeviceSQLString = union(enum) {
    /// Short-form content: raw ASCII bytes, at most `max_short_len`.
    short_ascii: []const u8,
    /// Long-form body.
    long: LongBody,

    /// Body of a long-form string, selected by the flags byte.
    pub const LongBody = union(enum) {
        /// ISRC characters, without the `0x03` magic byte and NUL
        /// terminator they are serialized with.
        isrc: []const u8,
        /// Raw ASCII bytes.
        ascii: []const u8,
        /// UCS-2 code units, serialized little-endian.
        ucs2le: []const u16,

        fn eql(a: LongBody, b: LongBody) bool {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                .isrc => |a_chars| std.mem.eql(u8, a_chars, b.isrc),
                .ascii => |a_bytes| std.mem.eql(u8, a_bytes, b.ascii),
                .ucs2le => |a_units| std.mem.eql(u16, a_units, b.ucs2le),
            };
        }

        fn deinit(body: *LongBody, alloc: std.mem.Allocator) void {
            switch (body.*) {
                .isrc, .ascii => |chars| alloc.free(chars),
                .ucs2le => |units| alloc.free(units),
            }
        }

        /// Bytes the body occupies, excluding the 4 long-form header bytes.
        fn byteCount(body: LongBody) u16 {
            return switch (body) {
                .isrc => |chars| @intCast(chars.len + 2),
                .ascii => |bytes| @intCast(bytes.len),
                .ucs2le => |units| @intCast(units.len * 2),
            };
        }

        /// Flags byte selecting this body.
        fn flags(body: LongBody) u8 {
            return switch (body) {
                .isrc, .ucs2le => long_flags_isrc_or_ucs2,
                .ascii => long_flags_ascii,
            };
        }

        fn decode(
            c: *bin.Cursor,
            alloc: std.mem.Allocator,
            flags_byte: u8,
            len: u16,
        ) DecodeError!LongBody {
            switch (flags_byte) {
                long_flags_ascii => return .{ .ascii = try alloc.dupe(
                    u8,
                    try c.takeBytes(len),
                ) },
                long_flags_isrc_or_ucs2 => {
                    if (try decodeIsrc(c, alloc, len)) |body| return body;
                    if (len % 2 != 0) return error.InvalidFormat;
                    const bytes = try c.takeBytes(len);
                    const units = try alloc.alloc(u16, len / 2);
                    for (units, 0..) |*unit, i| {
                        unit.* = std.mem.readInt(
                            u16,
                            bytes[2 * i ..][0..2],
                            .little,
                        );
                    }
                    return .{ .ucs2le = units };
                },
                else => return error.InvalidFormat,
            }
        }

        /// Parses an ISRC body — `0x03` magic byte, NUL-terminated ASCII,
        /// exactly filling `len` bytes — or returns `null` when the body is
        /// not of that shape, so UCS-2LE gets a chance. The exact fill is
        /// required so parsing stays in sync with the length field and
        /// roundtrips stay byte-identical.
        fn decodeIsrc(
            c: *bin.Cursor,
            alloc: std.mem.Allocator,
            len: u16,
        ) DecodeError!?LongBody {
            if (len < 2) return null; // no room for magic byte and NUL
            const body = try c.range(c.pos, c.pos + len);
            if (body[0] != 0x03 or body[len - 1] != 0) return null;
            if (std.mem.indexOfScalar(u8, body[1 .. len - 1], 0) != null)
                return null; // the NUL terminator must be the only one
            try c.seekBy(len);
            return .{ .isrc = try alloc.dupe(u8, body[1 .. len - 1]) };
        }

        fn encode(body: LongBody, e: *bin.Emitter) bin.WriteError!void {
            switch (body) {
                .isrc => |chars| {
                    try e.putInt(u8, 0x03, .little);
                    try e.putBytes(chars);
                    try e.putInt(u8, 0, .little);
                },
                .ascii => |bytes| try e.putBytes(bytes),
                .ucs2le => |units| {
                    for (units) |unit| try e.putInt(u16, unit, .little);
                },
            }
        }
    };

    /// Encodes `text`, picking the form the way rekordbox does: short ASCII
    /// while it fits, otherwise the long form, as ASCII when possible and
    /// UCS-2LE for anything else.
    pub fn fromUtf8(
        alloc: std.mem.Allocator,
        text: []const u8,
    ) error{ TooLong, InvalidEncoding, OutOfMemory }!DeviceSQLString {
        const only_ascii = allAscii(text);
        if (only_ascii and text.len <= max_short_len) {
            return .{ .short_ascii = try alloc.dupe(u8, text) };
        }
        if (text.len > max_len) return error.TooLong;
        if (only_ascii) {
            return .{ .long = .{ .ascii = try alloc.dupe(u8, text) } };
        }
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidEncoding;
        // InvalidUtf8 is impossible after the validation above.
        const units = std.unicode.utf8ToUtf16LeAlloc(
            alloc,
            text,
        ) catch |err| switch (err) {
            error.InvalidUtf8 => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
        // ASCII characters expand from one UTF-8 byte to two UCS-2LE bytes,
        // so the UTF-8 cap above does not bound the encoded size; a body
        // that would overflow the `u16` length field is rejected.
        if (@as(u32, @intCast(units.len)) * 2 +
            long_header_len > std.math.maxInt(u16))
        {
            alloc.free(units);
            return error.TooLong;
        }
        return .{ .long = .{ .ucs2le = units } };
    }

    /// Creates the long-form encoding Pioneer uses for a track's ISRC in
    /// place of a regular string: flags `0x90` with an ISRC-shaped body.
    /// An empty `text` becomes the regular empty string; anything but 12
    /// ASCII characters without a NUL byte is rejected (basic validation
    /// from <https://isrc.ifpi.org/downloads/ISRC_Bulletin-2015-01.pdf>; a
    /// NUL would make `decode` read the body back as UCS-2LE.
    pub fn fromIsrc(
        alloc: std.mem.Allocator,
        text: []const u8,
    ) error{ InvalidIsrc, OutOfMemory }!DeviceSQLString {
        if (text.len == 0) return empty();
        if (text.len != 12) return error.InvalidIsrc;
        if (!allAscii(text)) return error.InvalidIsrc;
        if (std.mem.indexOfScalar(u8, text, 0) != null)
            return error.InvalidIsrc;
        return .{ .long = .{ .isrc = try alloc.dupe(u8, text) } };
    }

    /// The empty string: the single short-form byte `0x03`. Allocates
    /// nothing.
    pub fn empty() DeviceSQLString {
        return .{ .short_ascii = &.{} };
    }

    pub fn eql(a: DeviceSQLString, b: DeviceSQLString) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .short_ascii => |a_bytes| std.mem.eql(u8, a_bytes, b.short_ascii),
            .long => |a_body| a_body.eql(b.long),
        };
    }

    /// Frees the content, which must have been allocated with `alloc` (by
    /// `fromUtf8`, `fromIsrc`, or a `Cursor` set up with `initAlloc`).
    pub fn deinit(s: *DeviceSQLString, alloc: std.mem.Allocator) void {
        switch (s.*) {
            .short_ascii => |content| alloc.free(content),
            .long => |*body| body.deinit(alloc),
        }
    }

    /// Extracts the text as UTF-8, strictly: invalid UTF-8 or UTF-16
    /// contents are rejected instead of being replaced.
    pub fn utf8(
        s: DeviceSQLString,
        alloc: std.mem.Allocator,
    ) error{ InvalidEncoding, OutOfMemory }![]u8 {
        switch (s) {
            .short_ascii => |content| return dupeUtf8(alloc, content),
            .long => |body| switch (body) {
                .isrc, .ascii => |chars| return dupeUtf8(alloc, chars),
                .ucs2le => |units| return std.unicode.utf16LeToUtf8Alloc(
                    alloc,
                    units,
                ) catch |err|
                    switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.DanglingSurrogateHalf,
                        error.ExpectedSecondSurrogateHalf,
                        error.UnexpectedSecondSurrogateHalf,
                        => error.InvalidEncoding,
                    },
            },
        }
    }

    /// Page heap space in bytes the serialized string occupies.
    pub fn heapBytesRequired(s: DeviceSQLString) u16 {
        return switch (s) {
            .short_ascii => |content| @intCast(1 + content.len),
            .long => |body| @intCast(
                @as(u32, long_header_len) + body.byteCount(),
            ),
        };
    }

    /// Byte alignment the string's start offset must have when placed by a
    /// calculated offset array: UCS-2LE strings need 4-byte alignment,
    /// everything else none.
    pub fn requiredAlignment(s: DeviceSQLString) u16 {
        return switch (s) {
            .short_ascii => 1,
            .long => |body| switch (body) {
                .ucs2le => 4,
                .isrc, .ascii => 1,
            },
        };
    }

    /// Reads a string from `c`, which must have an allocator set (see
    /// `bin.Cursor.initAlloc`). Content bytes are not validated on parse,
    /// only by `utf8`; structural constants (flag values, the padding
    /// byte, the ISRC body shape) are. The error set is wider than the
    /// custom-codec contract of `bin.takeStruct` (`ReadError!T`): strings
    /// in pdb rows are read through dedicated cursors rather than as
    /// inline struct fields.
    pub fn decode(c: *bin.Cursor) DecodeError!DeviceSQLString {
        const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
        const first = try c.takeInt(u8, .little);
        if (first & 1 != 0) {
            if (first == 1)
                return error.InvalidFormat; // content length would be -1
            const len = (first >> 1) - 1;
            return .{ .short_ascii = try alloc.dupe(u8, try c.takeBytes(len)) };
        }
        const length = try c.takeInt(u16, .little);
        const padding = try c.takeInt(u8, .little);
        if (padding != 0) return error.InvalidFormat;
        if (length < long_header_len)
            return error.InvalidFormat; // shorter than its own header
        const body = try LongBody.decode(
            c,
            alloc,
            first,
            length - long_header_len,
        );
        return .{ .long = body };
    }

    /// Writes the string, the inverse of `decode`.
    pub fn encode(s: DeviceSQLString, e: *bin.Emitter) bin.WriteError!void {
        switch (s) {
            .short_ascii => |content| {
                try e.putInt(
                    u8,
                    @intCast(((content.len + 1) << 1) | 1),
                    .little,
                );
                try e.putBytes(content);
            },
            .long => |body| {
                try e.putInt(u8, body.flags(), .little);
                try e.putInt(
                    u16,
                    @intCast(@as(u32, body.byteCount()) + long_header_len),
                    .little,
                );
                try e.putInt(u8, 0, .little);
                try body.encode(e);
            },
        }
    }
};

/// Duplicates `bytes` as a UTF-8 string, rejecting invalid UTF-8.
fn dupeUtf8(
    alloc: std.mem.Allocator,
    bytes: []const u8,
) error{ InvalidEncoding, OutOfMemory }![]u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidEncoding;
    return alloc.dupe(u8, bytes);
}

fn allAscii(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isAscii(ch)) return false;
    return true;
}

const testing = std.testing;

/// Mirrors rekordcrate's `test_roundtrip`: parses `bytes` expecting
/// `expected` and full consumption, re-encodes `expected` expecting `bytes`
/// back, and checks `heapBytesRequired` against the serialized length.
fn expectRoundtrip(bytes: []const u8, expected: DeviceSQLString) !void {
    var c = bin.Cursor.initAlloc(testing.allocator, bytes);
    var parsed = try DeviceSQLString.decode(&c);
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
    var s = try DeviceSQLString.fromUtf8(testing.allocator, text);
    defer s.deinit(testing.allocator);
    try expectRoundtrip(serialized, s);

    const out = try s.utf8(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(text, out);
}

test "empty string is the single byte 0x03" {
    try expectRoundtrip(&.{0x03}, DeviceSQLString.empty());

    var from_utf8 = try DeviceSQLString.fromUtf8(testing.allocator, "");
    defer from_utf8.deinit(testing.allocator);
    try expectRoundtrip(&.{0x03}, from_utf8);
    try testing.expect(DeviceSQLString.empty().eql(from_utf8));
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
        DeviceSQLString.fromUtf8(testing.allocator, &humongous),
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
        DeviceSQLString.fromUtf8(alloc, &text),
    );

    // One ASCII char less the encoded form fits exactly: 32765 units,
    // 65530 body bytes, 65534 with the header.
    var max_mixed = try DeviceSQLString.fromUtf8(alloc, text[1..]);
    defer max_mixed.deinit(alloc);
    try testing.expect(std.meta.activeTag(max_mixed.long) == .ucs2le);
    try testing.expectEqual(
        @as(u16, std.math.maxInt(u16) - 1),
        max_mixed.heapBytesRequired(),
    );
}

test "isrc strings roundtrip" {
    var s = try DeviceSQLString.fromIsrc(testing.allocator, "GBAYE6700149");
    defer s.deinit(testing.allocator);
    try expectRoundtrip(&.{
        0x90, 0x12, 0x00, 0x00, 0x03, 0x47, 0x42, 0x41, 0x59, 0x45, 0x36, 0x37, 0x30, 0x30,
        0x31, 0x34, 0x39, 0x00,
    }, s);

    // An empty ISRC becomes the regular empty string.
    var empty_isrc = try DeviceSQLString.fromIsrc(testing.allocator, "");
    defer empty_isrc.deinit(testing.allocator);
    try expectRoundtrip(&.{0x03}, empty_isrc);

    // Anything but 12 ASCII characters is rejected.
    try testing.expectError(
        error.InvalidIsrc,
        DeviceSQLString.fromIsrc(testing.allocator, "non-conforming garbage"),
    );
    try testing.expectError(
        error.InvalidIsrc,
        DeviceSQLString.fromIsrc(testing.allocator, "ÉBCDEFGHIJK"),
    );
    // A NUL byte is ASCII but would not survive the roundtrip.
    try testing.expectError(
        error.InvalidIsrc,
        DeviceSQLString.fromIsrc(testing.allocator, "A\x00AAAAAAAAAA"),
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
    var short_max = try DeviceSQLString.fromUtf8(alloc, ascii[0..126]);
    defer short_max.deinit(alloc);
    try testing.expect(std.meta.activeTag(short_max) == .short_ascii);

    var long_min = try DeviceSQLString.fromUtf8(alloc, ascii[0..]);
    defer long_min.deinit(alloc);
    try testing.expect(std.meta.activeTag(long_min) == .long);
    try testing.expect(std.meta.activeTag(long_min.long) == .ascii);

    // Non-ASCII always takes the long form, as UCS-2LE.
    var ucs2 = try DeviceSQLString.fromUtf8(alloc, "é");
    defer ucs2.deinit(alloc);
    try testing.expect(std.meta.activeTag(ucs2) == .long);
    try testing.expect(std.meta.activeTag(ucs2.long) == .ucs2le);

    // 32767 UTF-8 bytes still pass, 32768 are too long.
    var big: [32768]u8 = undefined;
    @memset(&big, 'a');
    var max = try DeviceSQLString.fromUtf8(alloc, big[0 .. big.len - 1]);
    defer max.deinit(alloc);
    try testing.expectError(
        error.TooLong,
        DeviceSQLString.fromUtf8(alloc, &big),
    );

    // Invalid UTF-8 is rejected without reaching the encoder.
    try testing.expectError(
        error.InvalidEncoding,
        DeviceSQLString.fromUtf8(alloc, &[_]u8{0xFF}),
    );
}

test "eql distinguishes different strings" {
    const alloc = testing.allocator;

    // Same length, different content.
    var foo = try DeviceSQLString.fromUtf8(alloc, "foo");
    defer foo.deinit(alloc);
    var bar = try DeviceSQLString.fromUtf8(alloc, "bar");
    defer bar.deinit(alloc);
    try testing.expect(!foo.eql(bar));

    // Different lengths.
    var fo = try DeviceSQLString.fromUtf8(alloc, "fo");
    defer fo.deinit(alloc);
    try testing.expect(!foo.eql(fo));

    // Same content, different form.
    const long_foo: DeviceSQLString = .{ .long = .{ .ascii = "foo" } };
    try testing.expect(!foo.eql(long_foo));

    // Same long-form tag, different content.
    const long_bar: DeviceSQLString = .{ .long = .{ .ascii = "bar" } };
    try testing.expect(!long_foo.eql(long_bar));
}

test "flags 0x90 dispatches isrc before ucs2le" {
    const alloc = testing.allocator;

    // 0x03 'A' 'B' 0x00 would also read as valid UCS-2LE ([0x4103,
    // 0x0042]), but the ISRC shape claims it because it is tried first.
    {
        const s: DeviceSQLString = .{ .long = .{ .isrc = "AB" } };
        try expectRoundtrip(&.{ 0x90, 0x08, 0x00, 0x00, 0x03, 'A', 'B', 0x00 }, s);
    }

    // An interior NUL breaks the ISRC shape, so the same leading 0x03
    // becomes the UCS-2LE code unit U+0003.
    {
        const bytes = [_]u8{ 0x90, 0x08, 0x00, 0x00, 0x03, 0x00, 'A', 0x00 };
        var c = bin.Cursor.initAlloc(alloc, &bytes);
        var s = try DeviceSQLString.decode(&c);
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
        var s = try DeviceSQLString.decode(&c);
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
        try testing.expectError(error.InvalidFormat, DeviceSQLString.decode(&c));
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
        try testing.expectError(error.UnexpectedEof, DeviceSQLString.decode(&c));
    }
}

test "utf8 conversion is strict" {
    const alloc = testing.allocator;

    // Content bytes are not validated on parse, only on conversion.
    var c = bin.Cursor.initAlloc(alloc, &.{ 0x05, 0xFF });
    var bad_ascii = try DeviceSQLString.decode(&c);
    defer bad_ascii.deinit(alloc);
    try testing.expectError(error.InvalidEncoding, bad_ascii.utf8(alloc));

    // A lone surrogate half is rejected as well.
    var c2 = bin.Cursor.initAlloc(alloc, &.{ 0x90, 0x06, 0x00, 0x00, 0x00, 0xD8 });
    var bad_ucs2 = try DeviceSQLString.decode(&c2);
    defer bad_ucs2.deinit(alloc);
    try testing.expect(std.meta.activeTag(bad_ucs2.long) == .ucs2le);
    try testing.expectError(error.InvalidEncoding, bad_ucs2.utf8(alloc));
}

test "heap bytes and alignment" {
    const alloc = testing.allocator;

    try testing.expectEqual(@as(u16, 1), DeviceSQLString.empty().heapBytesRequired());
    try testing.expectEqual(@as(u16, 1), DeviceSQLString.empty().requiredAlignment());

    var isrc = try DeviceSQLString.fromIsrc(alloc, "GBAYE6700149");
    defer isrc.deinit(alloc);
    try testing.expectEqual(@as(u16, 18), isrc.heapBytesRequired());
    try testing.expectEqual(@as(u16, 1), isrc.requiredAlignment());

    var ucs2 = try DeviceSQLString.fromUtf8(alloc, "I ❤ Rust");
    defer ucs2.deinit(alloc);
    try testing.expectEqual(@as(u16, 20), ucs2.heapBytesRequired());
    try testing.expectEqual(@as(u16, 4), ucs2.requiredAlignment());

    // Long-form ASCII bodies need no alignment either.
    const long_ascii_bytes = [_]u8{'a'} ** 127;
    var long_ascii = try DeviceSQLString.fromUtf8(alloc, &long_ascii_bytes);
    defer long_ascii.deinit(alloc);
    try testing.expect(std.meta.activeTag(long_ascii.long) == .ascii);
    try testing.expectEqual(@as(u16, 1), long_ascii.requiredAlignment());
}
