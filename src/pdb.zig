// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the rekordbox `export.pdb` database (DeviceSQL).
//!
//! Currently contains `DeviceSQLString`, the string type used by all row
//! types, and the offset arrays that locate strings and other tail data
//! within rows; pages, rows, and tables are not implemented yet.
//!
//! Initially ported from rekordcrate's `src/pdb/string.rs` and
//! `src/pdb/offset_array.rs`
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

/// Magic preceding every offset array: `0x03` as a `u8` before `u8`
/// offsets, `0x0003` as a `u16` before `u16` offsets.
const offset_array_magic = 0x03;

/// Decoding error of an offset array container: `InvalidFormat` is a wrong
/// magic; `UnexpectedValue` is an `array_offset` argument exceeding the
/// cursor position, which would underflow the base.
pub const OffsetArrayDecodeError = bin.ReadError || error{ InvalidFormat, UnexpectedValue };

/// Encoding error of an offset array container: `UnexpectedValue` is a
/// provided-offset width disagreeing with the argument, an offset too large
/// for its width, or an `array_offset` argument exceeding the emitter
/// position; `NotImplemented` is the unwired calculated mode.
pub const OffsetArrayEncodeError = bin.WriteError || error{ UnexpectedValue, NotImplemented };

/// Specifies whether the offsets of an offset array are stored as `u8` or
/// `u16`; the surrounding row's subtype selects the width (bit `0x04` set
/// means `u16`, see `fromSubtype`).
pub const OffsetSize = enum {
    /// Offsets are stored as `u8`, preceded by the `u8` magic `0x03`.
    u8,
    /// Offsets are stored as `u16`, preceded by the `u16` magic `0x0003`.
    u16,

    /// Bytes one stored offset occupies, magic excluded.
    fn bytes(size: OffsetSize) usize {
        return switch (size) {
            .u8 => 1,
            .u16 => 2,
        };
    }

    /// The offset size a row subtype selects: bit `0x04` not set means
    /// `u8` offsets, set means `u16`.
    pub fn fromSubtype(subtype: u16) OffsetSize {
        return if (subtype & 0x04 == 0) .u8 else .u16;
    }
};

/// The offsets of an `OffsetArrayContainer`: either exactly as stored in
/// the file or computed from the items during serialization. This is
/// rekordcrate's `MaybeCalculated<OffsetArray<N>>` collapsed into one flag
/// with the stored width.
pub fn Offsets(comptime n: usize) type {
    return union(enum) {
        const Self = @This();

        /// The offsets as they appear in the file (or as explicitly chosen
        /// by the caller), written verbatim.
        provided: struct {
            /// Width the offsets are stored at; on write it must equal the
            /// offset size the surrounding row's subtype selects.
            size: OffsetSize,
            /// Offset values, relative to the row start.
            values: [n]u16,
        },

        /// Offsets are computed from the items during serialization and
        /// patched back in; writing this mode is not implemented yet.
        calculated,

        pub fn eql(a: Self, b: Self) bool {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                .provided => |p| p.size == b.provided.size and
                    std.mem.eql(u16, &p.values, &b.provided.values),
                .calculated => true,
            };
        }
    };
}

/// An array of `n` offsets followed by the data at those offsets, the tail
/// structure rows use to locate strings (and other heap objects) after
/// their fixed fields: a magic sized by `OffsetSize`, the `n` offsets, and
/// the items at positions computed from the offsets. Offsets are relative
/// to the row start, not to the array, which is what the `array_offset`
/// arguments of `decode` and `encode` compensate for.
///
/// The inner type `T` combines the items into one value and must declare:
///
/// * `offset_count`: how many items (and offsets) it comprises
/// * `OffsetItem`: the item type, holding the `decode`/`encode`/
///   `heapBytesRequired`/`requiredAlignment`/`eql` protocol of
///   `DeviceSQLString` (the alignment matters to calculated offsets)
/// * `offsetItems(T) [n]OffsetItem`, a borrowing view, and
///   `fromOffsetItems([n]OffsetItem) T`, which takes item ownership
/// * `eql(a: T, b: T) bool`
pub fn OffsetArrayContainer(comptime T: type) type {
    const n = T.offset_count;
    const Item = T.OffsetItem;
    return struct {
        const Self = @This();

        /// Number of offsets and items, re-exposed from `T`.
        pub const offset_count = n;

        /// The offsets; see `Offsets`.
        offsets: Offsets(n) = .calculated,

        /// The inner value the items combine into.
        inner: T = .{},

        /// Reads the offsets from `c`, then each item from its own
        /// sub-cursor at `base + offset`, where `base` is the cursor
        /// position the array starts at minus `array_offset` — the row
        /// start. Track passes `0x5C` (its fixed-field size), Artist `8`,
        /// Album `20`. The cursor is left directly after the offsets;
        /// items may lie beyond that, and are not required to fill the
        /// buffer they occupy.
        pub fn decode(c: *bin.Cursor, array_offset: usize, size: OffsetSize) OffsetArrayDecodeError!Self {
            const start = c.pos;
            if (array_offset > start) return error.UnexpectedValue; // base underflow
            var values: [n]u16 = undefined;
            switch (size) {
                .u8 => {
                    if (try c.takeInt(u8, .little) != offset_array_magic)
                        return error.InvalidFormat;
                    for (&values) |*value| value.* = try c.takeInt(u8, .little);
                },
                .u16 => {
                    if (try c.takeInt(u16, .little) != offset_array_magic)
                        return error.InvalidFormat;
                    for (&values) |*value| value.* = try c.takeInt(u16, .little);
                },
            }
            const base = start - array_offset;
            var items: [n]Item = undefined;
            // `inline for` so zero-item containers can use `void` items:
            // the body referencing `Item.decode` is never analyzed.
            inline for (values, &items) |offset, *item| {
                const pos = base + @as(usize, offset);
                if (pos > c.buf.len) return error.UnexpectedEof;
                var sub_cursor = bin.Cursor{
                    .buf = c.buf[pos..],
                    .alloc = c.alloc,
                };
                item.* = try Item.decode(&sub_cursor);
            }
            return .{
                .offsets = .{ .provided = .{ .size = size, .values = values } },
                .inner = T.fromOffsetItems(items),
            };
        }

        /// Writes the offsets, then each item at `base + offset` (the
        /// inverse of `decode`, same `array_offset` convention); gaps the
        /// offsets skip over are zero-filled. Writing with calculated
        /// offsets is not implemented yet.
        pub fn encode(
            self: *const Self,
            e: *bin.Emitter,
            array_offset: usize,
            size: OffsetSize,
        ) OffsetArrayEncodeError!void {
            const provided = switch (self.offsets) {
                .provided => |p| p,
                .calculated => return error.NotImplemented,
            };
            if (provided.size != size) return error.UnexpectedValue;
            const start = e.pos();
            if (array_offset > start) return error.UnexpectedValue; // base underflow
            const base = start - array_offset;
            switch (size) {
                .u8 => {
                    try e.putInt(u8, offset_array_magic, .little);
                    for (provided.values) |value| {
                        if (value > std.math.maxInt(u8)) return error.UnexpectedValue;
                        try e.putInt(u8, @intCast(value), .little);
                    }
                },
                .u16 => {
                    try e.putInt(u16, offset_array_magic, .little);
                    for (provided.values) |value| try e.putInt(u16, value, .little);
                },
            }
            // `inline for` so zero-item containers can use `void` items:
            // the body referencing `Item.encode` is never analyzed.
            inline for (T.offsetItems(self.inner), provided.values) |item, offset| {
                var sub_emitter = bin.Emitter.init(e.alloc);
                defer sub_emitter.deinit();
                try item.encode(&sub_emitter);
                try e.putBytesAt(base + @as(usize, offset), sub_emitter.written());
            }
        }

        /// Page heap space in bytes the container occupies: the magic and
        /// offsets plus every item, with each item's start aligned per its
        /// `requiredAlignment` when the offsets are calculated (provided
        /// offsets measure the file's actual placement, so gaps between
        /// items do not count).
        pub fn heapBytesRequired(self: *const Self, size: OffsetSize) u16 {
            const calculated = switch (self.offsets) {
                .calculated => true,
                .provided => false,
            };
            var total: u32 = @intCast((n + 1) * size.bytes());
            // `inline for` so zero-item containers can use `void` items:
            // the body referencing the item methods is never analyzed.
            inline for (T.offsetItems(self.inner)) |item| {
                if (calculated) {
                    const alignment: u32 = @max(item.requiredAlignment(), 1);
                    total = std.mem.alignForward(u32, total, alignment);
                }
                total += item.heapBytesRequired();
            }
            return @intCast(total);
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.offsets.eql(b.offsets) and a.inner.eql(b.inner);
        }
    };
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

        pub fn offsetItems(inner: @This()) [offset_count]Item {
            return .{inner.value};
        }

        pub fn fromOffsetItems(items: [offset_count]Item) @This() {
            return .{ .value = items[0] };
        }

        pub fn eql(a: @This(), b: @This()) bool {
            return a.value.eql(b.value);
        }
    };
}

/// Two-item inner type, the analogue of rekordcrate's test `Multiple`.
fn TestPair(comptime Item: type) type {
    return struct {
        a: Item = .{},
        b: Item = .{},

        pub const offset_count = 2;
        pub const OffsetItem = Item;

        pub fn offsetItems(inner: @This()) [offset_count]Item {
            return .{ inner.a, inner.b };
        }

        pub fn fromOffsetItems(items: [offset_count]Item) @This() {
            return .{ .a = items[0], .b = items[1] };
        }

        pub fn eql(x: @This(), y: @This()) bool {
            return x.a.eql(y.a) and x.b.eql(y.b);
        }
    };
}

/// Zero-item inner type, the analogue of rekordcrate's `()` implementation
/// of `OffsetArrayItems<0>`.
const TestEmpty = struct {
    pub const offset_count = 0;
    pub const OffsetItem = void;

    pub fn offsetItems(_: TestEmpty) [offset_count]void {
        return .{};
    }

    pub fn fromOffsetItems(_: [offset_count]void) TestEmpty {
        return .{};
    }

    pub fn eql(_: TestEmpty, _: TestEmpty) bool {
        return true;
    }
};

/// Two-string inner type for the heap-bytes tests, the analogue of
/// rekordcrate's `Multiple<DeviceSQLString>` (and a preview of the
/// `TrailingName`-style row types).
const TestStringPair = struct {
    a: DeviceSQLString = DeviceSQLString.empty(),
    b: DeviceSQLString = DeviceSQLString.empty(),

    pub const offset_count = 2;
    pub const OffsetItem = DeviceSQLString;

    pub fn offsetItems(inner: TestStringPair) [offset_count]DeviceSQLString {
        return .{ inner.a, inner.b };
    }

    pub fn fromOffsetItems(items: [offset_count]DeviceSQLString) TestStringPair {
        return .{ .a = items[0], .b = items[1] };
    }

    pub fn eql(x: TestStringPair, y: TestStringPair) bool {
        return x.a.eql(y.a) and x.b.eql(y.b);
    }
};

/// Mirrors rekordcrate's `test_roundtrip_with_args` at `array_offset` 0:
/// parses `bytes` expecting `expected`, with the cursor landing directly
/// after the offsets, and re-encodes `expected` expecting `bytes` back.
/// The items of `expected` must not own memory, since `expected` is never
/// deinit-ed.
fn expectOffsetsRoundtrip(bytes: []const u8, expected: anytype, size: OffsetSize) !void {
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
        OffsetArrayContainer(TestEmpty){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{} } },
        },
        .u8,
    );
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x00 },
        OffsetArrayContainer(TestEmpty){
            .offsets = .{ .provided = .{ .size = .u16, .values = .{} } },
        },
        .u16,
    );
}

test "near u8 offset roundtrips" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x02, 42 },
        OffsetArrayContainer(TestSingle(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{2} } },
            .inner = .{ .value = .{ .value = 42 } },
        },
        .u8,
    );
}

test "four-byte buffer item roundtrips" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x02, 0xDE, 0xAD, 0xBE, 0xEF },
        OffsetArrayContainer(TestSingle(TestBytes4Item)){
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
        OffsetArrayContainer(TestSingle(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{5} } },
            .inner = .{ .value = .{ .value = 42 } },
        },
        .u8,
    );
}

test "far remote u16 offsets roundtrip" {
    try expectOffsetsRoundtrip(
        &.{ 0x03, 0x00, 0x05, 0x00, 0x00, 42 },
        OffsetArrayContainer(TestSingle(TestU8Item)){
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
    const expected: OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{5} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    const bytes = [_]u8{ 0, 0, 0, 0x03, 0x05, 42 };

    var c = bin.Cursor.initAlloc(testing.allocator, &bytes);
    try c.seekBy(3);
    const parsed = try OffsetArrayContainer(Single).decode(&c, 3, .u8);
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
        OffsetArrayContainer(TestPair(TestU8Item)){
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
        OffsetArrayContainer(TestPair(TestU8Item)){
            .offsets = .{ .provided = .{ .size = .u8, .values = .{ 4, 3 } } },
            .inner = .{ .a = .{ .value = 0xC0 }, .b = .{ .value = 0xDE } },
        },
        .u8,
    );
}

test "offset size comes from the subtype bit 0x04" {
    // Artist subtypes 0x60/0x64 and Track's 0x24 are the known occupants
    // of each width; Album's usual 0x0080 stays u8.
    try testing.expectEqual(OffsetSize.u8, OffsetSize.fromSubtype(0x60));
    try testing.expectEqual(OffsetSize.u16, OffsetSize.fromSubtype(0x64));
    try testing.expectEqual(OffsetSize.u16, OffsetSize.fromSubtype(0x24));
    try testing.expectEqual(OffsetSize.u8, OffsetSize.fromSubtype(0x0080));
}

test "heapBytesRequired aligns calculated ucs2 items to 4 bytes" {
    const alloc = testing.allocator;

    var foo = try DeviceSQLString.fromUtf8(alloc, "foo");
    defer foo.deinit(alloc);
    var e_acute = try DeviceSQLString.fromUtf8(alloc, "é");
    defer e_acute.deinit(alloc);

    // Calculated: 3 bytes of magic+offsets, "foo" at 3 (4 bytes), then
    // "é" aligned from 7 up to 8, adding its 6 bytes — the placement the
    // oracle's calculated write produces.
    const calculated: OffsetArrayContainer(TestStringPair) = .{
        .offsets = .calculated,
        .inner = .{ .a = foo, .b = e_acute },
    };
    try testing.expectEqual(@as(u16, 14), calculated.heapBytesRequired(.u8));

    // Provided: the bytes of the array and the items, gaps not counted.
    const provided: OffsetArrayContainer(TestStringPair) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{ 3, 8 } } },
        .inner = .{ .a = foo, .b = e_acute },
    };
    try testing.expectEqual(@as(u16, 13), provided.heapBytesRequired(.u8));
}

test "offset array decode rejects malformed input" {
    const Single = TestSingle(TestBytes4Item);
    const alloc = testing.allocator;

    const invalid = [_]struct { bytes: []const u8, size: OffsetSize }{
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
            OffsetArrayContainer(Single).decode(&c, 0, case.size),
        );
    }

    const truncated = [_]struct { bytes: []const u8, size: OffsetSize }{
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
            OffsetArrayContainer(Single).decode(&c, 0, case.size),
        );
    }

    // A base underflowing the cursor position is rejected as well: an
    // array at position 0 has no row start 2 bytes before it.
    var c = bin.Cursor.initAlloc(alloc, &.{ 0x03, 0x01, 42 });
    try testing.expectError(
        error.UnexpectedValue,
        OffsetArrayContainer(Single).decode(&c, 2, .u8),
    );
}

test "offset array encode validates provided offsets" {
    const alloc = testing.allocator;
    const Single = TestSingle(TestU8Item);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();

    // Writing with calculated offsets is not wired yet.
    const calculated: OffsetArrayContainer(Single) = .{
        .offsets = .calculated,
        .inner = .{ .value = .{ .value = 42 } },
    };
    try testing.expectError(
        error.NotImplemented,
        calculated.encode(&e, 0, .u8),
    );

    // Provided width must match the write argument.
    const u16_stored: OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u16, .values = .{2} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    try testing.expectError(
        error.UnexpectedValue,
        u16_stored.encode(&e, 0, .u8),
    );

    // u8 offsets cannot hold values wider than a byte.
    const overflowing: OffsetArrayContainer(Single) = .{
        .offsets = .{ .provided = .{ .size = .u8, .values = .{0x0100} } },
        .inner = .{ .value = .{ .value = 42 } },
    };
    try testing.expectError(
        error.UnexpectedValue,
        overflowing.encode(&e, 0, .u8),
    );

    // The base must not underflow the emitter position: an empty emitter
    // has no row start 1 byte before it.
    const near: OffsetArrayContainer(Single) = .{
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
