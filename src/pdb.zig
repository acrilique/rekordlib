// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the rekordbox `export.pdb` database (DeviceSQL).
//!
//! Currently contains `DeviceSQLString`, the string type used by all row
//! types; the offset arrays that locate strings and other tail data
//! within rows; the page headers with index pages; and data pages with
//! the simple row types. The complex row types (artist, album, playlist
//! tree node, track), ext rows, tables, and the whole-file database are
//! not implemented yet.
//!
//! Initially ported from rekordcrate's `src/pdb/string.rs`,
//! `src/pdb/offset_array.rs`, `src/pdb/bitfields.rs`, and the page,
//! index-page, data-page, and simple-row parts of `src/pdb/mod.rs`
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
/// * `OffsetItem`: the item type, holding the `decode`/`encode`/`deinit`/
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
            // The comptime guard lets zero-item containers use `void`
            // items, whose type has no `decode`; items decoded before a
            // failure are freed, so a partially decoded container (a row
            // rejected mid-parse) never leaks.
            if (Item != void) {
                const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
                var decoded: usize = 0;
                errdefer {
                    for (items[0..decoded]) |*item| item.deinit(alloc);
                }
                for (values, &items) |offset, *item| {
                    const pos = base + @as(usize, offset);
                    if (pos > c.buf.len) return error.UnexpectedEof;
                    var sub_cursor = bin.Cursor{
                        .buf = c.buf[pos..],
                        .alloc = c.alloc,
                    };
                    item.* = try Item.decode(&sub_cursor);
                    decoded += 1;
                }
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

        /// Frees the items, which must have been allocated with `alloc`
        /// (by `decode` or by building the inner value); containers
        /// deinit-ed with the same allocator.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            if (Item == void) return;
            var items = T.offsetItems(self.inner);
            for (&items) |*item| item.deinit(alloc);
        }
    };
}

/// The type of rows a page holds, as stored in page headers and table
/// entries: the wire constants of `export.pdb` tables. In `exportExt.pdb`
/// databases values 3 and 4 carry the ext meanings (tags, track tags)
/// instead of albums and labels; distinguishing the two arrives with the
/// ext row support. Unknown values roundtrip verbatim.
pub const PageType = enum(u32) {
    /// Track metadata: title, artist, genre, artwork ID, playing time, etc.
    tracks = 0,
    /// Musical genres, for reference by tracks and searching.
    genres = 1,
    /// Artists, for reference by tracks and searching.
    artists = 2,
    /// Albums, for reference by tracks and searching.
    albums = 3,
    /// Music labels, for reference by tracks and searching.
    labels = 4,
    /// Musical keys, for reference by tracks, searching, and key matching.
    keys = 5,
    /// Color labels, for reference by tracks and searching.
    colors = 6,
    /// The hierarchical tree structure of playlists and folders grouping
    /// them.
    playlist_tree = 7,
    /// Links from tracks to playlists, in the right order.
    playlist_entries = 8,
    /// History playlists, recorded every time the device is mounted by a
    /// player.
    history_playlists = 11,
    /// Links from tracks to history playlists, in the right order.
    history_entries = 12,
    /// Album artwork images.
    artwork = 13,
    /// Metadata categories by which tracks can be browsed.
    columns = 16,
    /// The active menus on the CDJ.
    menu = 17,
    /// Synchronization of the USB with rekordbox or a device.
    history = 19,
    _,
};

/// Packed field in the page header containing the number of used row
/// offsets in the page (13 bits) and the number of valid rows (11 bits).
/// The first field occupies the low bits, matching `modular_bitfield`'s
/// LSB-first layout.
pub const PackedRowCounts = packed struct(u24) {
    num_rows: u13 = 0,
    num_rows_valid: u11 = 0,
};

/// Page flags stored in the page header, LSB-first: the first declared
/// field is bit 0, so the declaration order reads backwards compared to
/// typical bit notation. The default value is the typical data page
/// (`0x24`); index pages set `is_index_page` (`0x64`).
pub const PageFlags = packed struct(u8) {
    /// Unknown flag that appears to never be set.
    unknown0: bool = false,
    /// Unknown flag that appears to never be set.
    unknown1: bool = false,
    /// Unknown flag that appears to always be set.
    unknown2: bool = true,
    /// Unknown flag that appears to never be set.
    unknown3: bool = false,
    /// Set when the page contains a deleted row.
    contains_deleted: bool = false,
    /// Unknown flag that appears to always be set.
    unknown5: bool = true,
    /// Determines if the page is an index page.
    is_index_page: bool = false,
    /// Unknown flag that appears to never be set.
    unknown7: bool = false,
};

/// The header of a table page (0x20 bytes), shared by data and index
/// pages.
pub const PageHeader = struct {
    /// Magic signature for pages: always zero.
    magic: u32 = 0,
    /// Index of the page; should match the index used for lookup and can
    /// be used to verify that the correct page was loaded.
    page_index: u32 = 0,
    /// Type of information that the rows of this page contain; should
    /// match the page type of the table this page belongs to.
    page_type: PageType = .tracks,
    /// Index of the next page with the same page type; if this page is
    /// the last of that type, the stored index points past the end of the
    /// file.
    next_page: u32 = 0,
    /// Unknown field; appears to be a number between 1 and ~2500.
    unknown1: u32 = 0,
    /// Unknown field; appears to always be zero.
    unknown2: u32 = 0,
    /// Number of used row offsets and valid rows, packed.
    packed_row_counts: PackedRowCounts = .{},
    /// Page flags.
    page_flags: PageFlags = .{},
    /// Free space in bytes in the data section of the page, excluding the
    /// row offsets in the page footer.
    free_size: u16 = 0,
    /// Used space in bytes in the data section of the page.
    used_size: u16 = 0,

    pub const constant_fields = .{ .magic, .unknown2 };
};

/// An entry in an index page: bits 31-3 hold a page index pointing at a
/// data page with the same page type as the index page, bits 2-0 hold
/// index flags of unknown meaning. Valid page indexes are below
/// `0x03FF_FFFF`; that bound is checked when entries are followed, not on
/// parse.
pub const IndexEntry = packed struct(u32) {
    index_flags: u3 = 0,
    page_index: u29 = 0,

    /// The empty-slot sentinel `0x1FFF_FFF8`.
    pub const empty: IndexEntry = @bitCast(@as(u32, 0x1FFF_FFF8));

    pub fn isEmpty(entry: IndexEntry) bool {
        return @as(u32, @bitCast(entry)) == @as(u32, @bitCast(empty));
    }
};

/// The header of the index-containing part of a page (28 bytes). Defaults
/// describe an empty index page.
pub const IndexPageHeader = struct {
    /// Unknown field, usually `0x1fff` or `0x0001`.
    unknown_a: u16 = 0x1FFF,
    /// Unknown field, usually `0x1fff` or `0x0000`.
    unknown_b: u16 = 0x1FFF,
    /// Magic value `0x03ec`.
    magic: u16 = 0x03EC,
    /// Offset where the next index entry will be written, from the
    /// beginning of the entries array. Sometimes differs from
    /// `num_entries` for unknown reasons.
    next_offset: u16 = 0,
    /// Redundant copy of the page index.
    page_index: u32 = 0,
    /// Redundant copy of the next page index.
    next_page: u32 = 0,
    /// Magic value `0x0000_0000_03ff_ffff`.
    magic2: u64 = 0x0000_0000_03FF_FFFF,
    /// Number of index entries in this page; re-derived from `entries`
    /// when the content is written.
    num_entries: u16 = 0,
    /// Points to the first empty index entry, or `0x1fff` if none. In
    /// real databases this is either equal to `num_entries`, `0x1fff`
    /// (assumed to mean the same), or smaller, indicating the first
    /// empty slot.
    first_empty: u16 = 0x1FFF,

    pub const constant_fields = .{ .magic, .magic2 };
};

/// Decoding error of an index page: `UnexpectedValue` is a wrong header
/// magic.
pub const IndexPageDecodeError = bin.ReadError || error{UnexpectedValue};

/// Encoding error of an index page: `UnexpectedValue` is a page too small
/// for its header and trailing zeros, or more entries than it holds.
pub const IndexPageEncodeError = bin.WriteError || error{UnexpectedValue};

/// Zeros terminating every index page.
const index_page_zero_tail = 20;

/// The content of an index page: a header followed by the index entries
/// pointing at the table's data pages. Serializing writes the entries,
/// pads with empty entries up to the page's capacity, and terminates with
/// 20 zero bytes; parsing reads only the real entries.
pub const IndexPageContent = struct {
    header: IndexPageHeader = .{},
    entries: []IndexEntry = &.{},

    /// Reads the header (validating its magics) and exactly
    /// `num_entries` entries; the padding entries and trailing zeros are
    /// not read.
    pub fn decode(c: *bin.Cursor, alloc: std.mem.Allocator) IndexPageDecodeError!IndexPageContent {
        const header = try bin.takeStruct(c, IndexPageHeader, .little);
        try bin.validateConstantFields(IndexPageHeader, header);
        const entries = try bin.takeStructSlice(alloc, c, IndexEntry, .little, header.num_entries);
        return .{ .header = header, .entries = entries };
    }

    /// Writes the header with `num_entries` derived from `entries`, the
    /// entries, `totalEntries(page_size) - entries.len` empty entries,
    /// and the trailing zeros.
    pub fn encode(self: *const IndexPageContent, e: *bin.Emitter, page_size: usize) IndexPageEncodeError!void {
        if (self.entries.len > std.math.maxInt(u16)) return error.UnexpectedValue;
        const capacity = try totalEntries(page_size);
        if (self.entries.len > capacity) return error.UnexpectedValue;

        var header = self.header;
        header.num_entries = @intCast(self.entries.len);
        try bin.putStruct(e, header, .little);
        for (self.entries) |entry| try bin.putStruct(e, entry, .little);
        for (self.entries.len..capacity) |_| try bin.putStruct(e, IndexEntry.empty, .little);
        try e.pad(index_page_zero_tail);
    }

    pub fn deinit(content: *IndexPageContent, alloc: std.mem.Allocator) void {
        alloc.free(content.entries);
        content.entries = &.{};
    }
};

/// Number of entries a page of `page_size` bytes holds besides the page
/// header, the index page header, and the trailing zeros.
fn totalEntries(page_size: usize) error{UnexpectedValue}!usize {
    const fixed = bin.serializedLen(PageHeader) +
        bin.serializedLen(IndexPageHeader) + index_page_zero_tail;
    if (page_size < fixed) return error.UnexpectedValue;
    return (page_size - fixed) / bin.serializedLen(IndexEntry);
}

/// Indexed color identifiers used for tracks and memory cues, stored as a
/// single byte. Ported from rekordcrate's `util::ColorIndex`.
pub const ColorIndex = enum(u8) {
    /// No color.
    none = 0,
    /// Pink color.
    pink = 1,
    /// Red color.
    red = 2,
    /// Orange color.
    orange = 3,
    /// Yellow color.
    yellow = 4,
    /// Green color.
    green = 5,
    /// Aqua color.
    aqua = 6,
    /// Blue color.
    blue = 7,
    /// Purple color.
    purple = 8,
    _,
};

/// Visibility state of a menu on the CDJ. Experiments confirmed that
/// changing a menu from `hidden` to `visible` makes hidden menus (like
/// Genre) appear, although some menus stay invisible on a CDJ-350 even
/// when made visible here.
pub const MenuVisibility = enum(u8) {
    /// The menu is visible.
    visible = 0,
    /// The menu is hidden.
    hidden = 1,
    _,
};

/// Decoding error of a row: `InvalidFormat` comes from string bodies,
/// `UnexpectedValue` from the History magic constants, `NotImplemented`
/// from page types whose rows are not wired yet.
pub const RowDecodeError = bin.ReadError || error{ InvalidFormat, UnexpectedValue, NotImplemented };

/// Decoding error of a data page: row errors plus `UnexpectedValue` for
/// row groups not fitting the page or the parsed row count disagreeing
/// with `num_rows_valid`.
pub const DataPageDecodeError = RowDecodeError;

/// Encoding error of a data page: `UnexpectedValue` is row groups not
/// fitting the page.
pub const DataPageEncodeError = bin.WriteError || error{UnexpectedValue};

/// Magic value between a History row's `num_tracks` and `date` fields;
/// always zero.
const history_date_magic: u32 = 0;

/// Magic value between a History row's `date` and `version` fields;
/// always `0x1E19`.
const history_version_magic: u16 = 0x1E19;

/// Represents a musical genre.
pub const Genre = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the genre.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .genres;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Genre {
        const id = try c.takeInt(u32, .little);
        return .{ .id = id, .name = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const Genre, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.id, .little);
        try self.name.encode(e);
    }

    pub fn heapBytesRequired(self: *const Genre) u16 {
        return @intCast(4 + @as(u32, self.name.heapBytesRequired()));
    }

    pub fn eql(a: Genre, b: Genre) bool {
        return a.id == b.id and a.name.eql(b.name);
    }

    pub fn deinit(self: *Genre, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
    }
};

/// Represents a record label.
pub const Label = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the record label.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .labels;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Label {
        const id = try c.takeInt(u32, .little);
        return .{ .id = id, .name = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const Label, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.id, .little);
        try self.name.encode(e);
    }

    pub fn heapBytesRequired(self: *const Label) u16 {
        return @intCast(4 + @as(u32, self.name.heapBytesRequired()));
    }

    pub fn eql(a: Label, b: Label) bool {
        return a.id == b.id and a.name.eql(b.name);
    }

    pub fn deinit(self: *Label, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
    }
};

/// Represents a musical key.
pub const Key = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Apparently a second copy of the row ID.
    id2: u32 = 0,
    /// Name of the key.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .keys;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Key {
        const id = try c.takeInt(u32, .little);
        const id2 = try c.takeInt(u32, .little);
        return .{ .id = id, .id2 = id2, .name = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const Key, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.id, .little);
        try e.putInt(u32, self.id2, .little);
        try self.name.encode(e);
    }

    pub fn heapBytesRequired(self: *const Key) u16 {
        return @intCast(8 + @as(u32, self.name.heapBytesRequired()));
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.id == b.id and a.id2 == b.id2 and a.name.eql(b.name);
    }

    pub fn deinit(self: *Key, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
    }
};

/// Contains a numeric color ID and its user-defined name.
pub const Color = struct {
    /// Unknown field.
    unknown1: u32 = 0,
    /// Unknown field.
    unknown2: u8 = 0,
    /// Numeric color ID.
    color: ColorIndex = .none,
    /// Unknown field.
    unknown3: u16 = 0,
    /// User-defined name of the color.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .colors;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Color {
        const unknown1 = try c.takeInt(u32, .little);
        const unknown2 = try c.takeInt(u8, .little);
        const color: ColorIndex = @enumFromInt(try c.takeInt(u8, .little));
        const unknown3 = try c.takeInt(u16, .little);
        return .{
            .unknown1 = unknown1,
            .unknown2 = unknown2,
            .color = color,
            .unknown3 = unknown3,
            .name = try DeviceSQLString.decode(c),
        };
    }

    pub fn encode(self: *const Color, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.unknown1, .little);
        try e.putInt(u8, self.unknown2, .little);
        try e.putInt(u8, @intFromEnum(self.color), .little);
        try e.putInt(u16, self.unknown3, .little);
        try self.name.encode(e);
    }

    pub fn heapBytesRequired(self: *const Color) u16 {
        return @intCast(8 + @as(u32, self.name.heapBytesRequired()));
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.unknown1 == b.unknown1 and a.unknown2 == b.unknown2 and
            a.color == b.color and a.unknown3 == b.unknown3 and
            a.name.eql(b.name);
    }

    pub fn deinit(self: *Color, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
    }
};

/// Contains the artwork path and ID.
pub const Artwork = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Path to the album art file.
    path: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .artwork;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Artwork {
        const id = try c.takeInt(u32, .little);
        return .{ .id = id, .path = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const Artwork, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.id, .little);
        try self.path.encode(e);
    }

    pub fn heapBytesRequired(self: *const Artwork) u16 {
        return @intCast(4 + @as(u32, self.path.heapBytesRequired()));
    }

    pub fn eql(a: Artwork, b: Artwork) bool {
        return a.id == b.id and a.path.eql(b.path);
    }

    pub fn deinit(self: *Artwork, alloc: std.mem.Allocator) void {
        self.path.deinit(alloc);
    }
};

/// Represents a history playlist, recorded every time the device is
/// mounted by a player.
pub const HistoryPlaylist = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the playlist.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .history_playlists;

    pub fn decode(c: *bin.Cursor) RowDecodeError!HistoryPlaylist {
        const id = try c.takeInt(u32, .little);
        return .{ .id = id, .name = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const HistoryPlaylist, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, self.id, .little);
        try self.name.encode(e);
    }

    pub fn heapBytesRequired(self: *const HistoryPlaylist) u16 {
        return @intCast(4 + @as(u32, self.name.heapBytesRequired()));
    }

    pub fn eql(a: HistoryPlaylist, b: HistoryPlaylist) bool {
        return a.id == b.id and a.name.eql(b.name);
    }

    pub fn deinit(self: *HistoryPlaylist, alloc: std.mem.Allocator) void {
        self.name.deinit(alloc);
    }
};

/// Links a track to a history playlist, at its position.
pub const HistoryEntry = struct {
    /// ID of the track played at this position in the playlist.
    track_id: u32 = 0,
    /// ID of the history playlist.
    playlist_id: u32 = 0,
    /// Position within the playlist.
    entry_index: u32 = 0,

    pub const page_type: PageType = .history_entries;

    pub fn decode(c: *bin.Cursor) RowDecodeError!HistoryEntry {
        return bin.takeStruct(c, HistoryEntry, .little);
    }

    pub fn encode(self: *const HistoryEntry, e: *bin.Emitter) bin.WriteError!void {
        try bin.putStruct(e, self.*, .little);
    }

    pub fn heapBytesRequired(self: *const HistoryEntry) u16 {
        _ = self;
        return @intCast(bin.serializedLen(HistoryEntry));
    }

    pub fn eql(a: HistoryEntry, b: HistoryEntry) bool {
        return std.meta.eql(a, b);
    }

    pub fn deinit(self: *HistoryEntry, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// Links a track to a playlist, at its position.
pub const PlaylistEntry = struct {
    /// Position within the playlist.
    entry_index: u32 = 0,
    /// ID of the track played at this position in the playlist.
    track_id: u32 = 0,
    /// ID of the playlist tree node.
    playlist_id: u32 = 0,

    pub const page_type: PageType = .playlist_entries;

    pub fn decode(c: *bin.Cursor) RowDecodeError!PlaylistEntry {
        return bin.takeStruct(c, PlaylistEntry, .little);
    }

    pub fn encode(self: *const PlaylistEntry, e: *bin.Emitter) bin.WriteError!void {
        try bin.putStruct(e, self.*, .little);
    }

    pub fn heapBytesRequired(self: *const PlaylistEntry) u16 {
        _ = self;
        return @intCast(bin.serializedLen(PlaylistEntry));
    }

    pub fn eql(a: PlaylistEntry, b: PlaylistEntry) bool {
        return std.meta.eql(a, b);
    }

    pub fn deinit(self: *PlaylistEntry, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// A sync log row, written at least once per synchronization event (e.g.
/// a track added or removed). Previous rows are marked as deleted, but
/// their bytes are not overwritten, so they track the history of changes
/// to the database.
pub const History = struct {
    /// Subtype field, usually `0x0280`.
    subtype: u16 = 0,
    /// Unknown field; assumed to be the `index_shift` found in other row
    /// types.
    index_shift: u16 = 0,
    /// Tracks present in the database after this sync event.
    num_tracks: u32 = 0,
    /// Sync date, e.g. "2022-02-02".
    date: DeviceSQLString = DeviceSQLString.empty(),
    /// Format/protocol version string, "1000" in all known exports.
    version: DeviceSQLString = DeviceSQLString.empty(),
    /// Device or backup label; can be empty.
    label: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .history;

    pub fn decode(c: *bin.Cursor) RowDecodeError!History {
        const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
        const subtype = try c.takeInt(u16, .little);
        const index_shift = try c.takeInt(u16, .little);
        const num_tracks = try c.takeInt(u32, .little);
        if (try c.takeInt(u32, .little) != history_date_magic)
            return error.UnexpectedValue;
        var date = try DeviceSQLString.decode(c);
        errdefer date.deinit(alloc);
        if (try c.takeInt(u16, .little) != history_version_magic)
            return error.UnexpectedValue;
        var version = try DeviceSQLString.decode(c);
        errdefer version.deinit(alloc);
        return .{
            .subtype = subtype,
            .index_shift = index_shift,
            .num_tracks = num_tracks,
            .date = date,
            .version = version,
            .label = try DeviceSQLString.decode(c),
        };
    }

    pub fn encode(self: *const History, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u16, self.subtype, .little);
        try e.putInt(u16, self.index_shift, .little);
        try e.putInt(u32, self.num_tracks, .little);
        try e.putInt(u32, history_date_magic, .little);
        try self.date.encode(e);
        try e.putInt(u16, history_version_magic, .little);
        try self.version.encode(e);
        try self.label.encode(e);
    }

    pub fn heapBytesRequired(self: *const History) u16 {
        return @intCast(12 + @as(u32, self.date.heapBytesRequired()) +
            2 + self.version.heapBytesRequired() + self.label.heapBytesRequired());
    }

    pub fn eql(a: History, b: History) bool {
        return a.subtype == b.subtype and a.index_shift == b.index_shift and
            a.num_tracks == b.num_tracks and a.date.eql(b.date) and
            a.version.eql(b.version) and a.label.eql(b.label);
    }

    pub fn deinit(self: *History, alloc: std.mem.Allocator) void {
        self.date.deinit(alloc);
        self.version.deinit(alloc);
        self.label.deinit(alloc);
    }
};

/// One of the metadata categories tracks can be browsed by on CDJs.
pub const ColumnEntry = struct {
    /// Possibly the primary key, though there appear to be no references
    /// to these rows anywhere else; more likely a stable ID identifying
    /// the category in hardware (instead of by name).
    id: u16 = 0,
    /// Maybe a bitfield containing infos on sort order and which columns
    /// are displayed.
    unknown0: u16 = 0,
    /// Category name, wrapped in the Unicode "interlinear annotation"
    /// anchors `\u{fffa}` (before) and `\u{fffb}` (after) for some reason.
    /// The anchors force the long UCS-2LE string form even though the
    /// names are otherwise ASCII.
    column_name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .columns;

    pub fn decode(c: *bin.Cursor) RowDecodeError!ColumnEntry {
        const id = try c.takeInt(u16, .little);
        const unknown0 = try c.takeInt(u16, .little);
        return .{ .id = id, .unknown0 = unknown0, .column_name = try DeviceSQLString.decode(c) };
    }

    pub fn encode(self: *const ColumnEntry, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u16, self.id, .little);
        try e.putInt(u16, self.unknown0, .little);
        try self.column_name.encode(e);
    }

    pub fn heapBytesRequired(self: *const ColumnEntry) u16 {
        return @intCast(4 + @as(u32, self.column_name.heapBytesRequired()));
    }

    pub fn eql(a: ColumnEntry, b: ColumnEntry) bool {
        return a.id == b.id and a.unknown0 == b.unknown0 and
            a.column_name.eql(b.column_name);
    }

    pub fn deinit(self: *ColumnEntry, alloc: std.mem.Allocator) void {
        self.column_name.deinit(alloc);
    }
};

/// Defines one of the active menus on the CDJ.
pub const Menu = struct {
    /// Determines the label (e.g. "ARTIST"); matches IDs in the columns
    /// table.
    category_id: u16 = 0,
    /// Points to the data source, i.e. the list of artists is 0x02.
    content_pointer: u16 = 0,
    /// Unknown field. Swapping values here appears to have no effect on
    /// CDJ-350 behavior. Some observed values: 0x01 track, 0x02 artist,
    /// 0x03 album, 0x05 BPM, 0x63 (99) generic list (playlist, genre,
    /// key, history).
    unknown: u8 = 0,
    /// Visibility state of the menu item.
    visibility: MenuVisibility = .visible,
    /// Visual position in the menu list. 0 is valid and places the item
    /// at the very top (if visible).
    sort_order: u16 = 0,

    pub const page_type: PageType = .menu;

    pub fn decode(c: *bin.Cursor) RowDecodeError!Menu {
        return bin.takeStruct(c, Menu, .little);
    }

    pub fn encode(self: *const Menu, e: *bin.Emitter) bin.WriteError!void {
        try bin.putStruct(e, self.*, .little);
    }

    pub fn heapBytesRequired(self: *const Menu) u16 {
        _ = self;
        return @intCast(bin.serializedLen(Menu));
    }

    pub fn eql(a: Menu, b: Menu) bool {
        return std.meta.eql(a, b);
    }

    pub fn deinit(self: *Menu, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// A table row. Each variant declares its `page_type`, which selects it
/// in `decode`; page types without a wired row (and unknown page type
/// values) fail with `error.NotImplemented` until their rows land.
pub const Row = union(enum) {
    genre: Genre,
    label: Label,
    key: Key,
    color: Color,
    artwork: Artwork,
    history_playlist: HistoryPlaylist,
    history_entry: HistoryEntry,
    playlist_entry: PlaylistEntry,
    history: History,
    column_entry: ColumnEntry,
    menu: Menu,

    /// Reads the row for `page_type` from `c`, which starts at the row's
    /// heap offset.
    pub fn decode(c: *bin.Cursor, page_type: PageType) RowDecodeError!Row {
        return inline for (std.meta.fields(Row)) |field| {
            if (field.type.page_type == page_type)
                break @unionInit(Row, field.name, try field.type.decode(c));
        } else error.NotImplemented;
    }

    /// Writes the row, the inverse of the per-type `decode`.
    pub fn encode(self: Row, e: *bin.Emitter) bin.WriteError!void {
        return switch (self) {
            inline else => |row| try row.encode(e),
        };
    }

    /// Page heap space in bytes the row occupies.
    pub fn heapBytesRequired(self: *const Row) u16 {
        return switch (self.*) {
            inline else => |row| row.heapBytesRequired(),
        };
    }

    /// The page type rows of this variant belong to.
    pub fn pageType(self: Row) PageType {
        return switch (self) {
            inline else => |row| @TypeOf(row).page_type,
        };
    }

    pub fn eql(a: Row, b: Row) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            inline else => |row, tag| row.eql(@field(b, @tagName(tag))),
        };
    }

    /// Frees the row's strings; rows parsed or built with `alloc` must be
    /// deinit-ed with the same allocator.
    pub fn deinit(self: *Row, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*row| row.deinit(alloc),
        }
    }
};

/// The header of the data-containing part of a page (8 bytes).
pub const DataPageHeader = struct {
    /// Unknown field. Often 1 or `0x1fff`; also observed: 8, 27, 22, 17, 2.
    unknown5: u16 = 0,
    /// Unknown field related to the number of rows in the table, but not
    /// equal to it.
    unknown_not_num_rows_large: u16 = 0,
    /// Unknown field (usually zero).
    unknown6: u16 = 0,
    /// Unknown field (usually zero).
    unknown7: u16 = 0,
};

/// Maximum number of rows in a row group.
pub const row_group_max_rows: usize = 16;

/// Bytes one row group occupies: the sixteen offsets plus the presence
/// flags and the unknown field.
const row_group_size: usize = row_group_max_rows * 2 + 4;

/// A group of row offsets, built backwards from the end of the page heap
/// as pages fill. Holds up to sixteen offsets plus a presence bitmask:
/// bit `i` says whether the offset in slot `15 - i` holds a live row, so
/// rows occupy slots from the end of the array (bit 0 = slot 15) and
/// offsets descend through the array in allocation order.
///
/// Slots before the first present one are not row offsets — the page heap
/// may store row data in their bytes. Parsing and writing keep them
/// verbatim; the oracle instead writes only from the first present offset
/// onward, relying on its in-place file edits to leave the leading bytes
/// untouched.
pub const RowGroup = struct {
    /// Row offsets relative to the start of the page heap, in slot order:
    /// slot 15 holds the group's first-allocated row, later rows fill the
    /// slots below, so the values descend through the array.
    row_offsets: [row_group_max_rows]u16 = @splat(0),
    /// Bitmask marking which rows of the group are present: bit `i`
    /// belongs to slot `15 - i`.
    row_presence_flags: u16 = 0,
    /// Unknown field. Often zero, sometimes a multiple of 2, rarely
    /// something else. When a multiple of 2, the set bit often aligns
    /// with the last present row in the group, so maybe this is a bitset
    /// like the flags.
    unknown: u16 = 0,

    /// The offset of the present row at presence bit `bit`, or `null`
    /// when the bit is clear.
    pub fn presentOffset(group: *const RowGroup, bit: u4) ?u16 {
        if (group.row_presence_flags & (@as(u16, 1) << bit) == 0) return null;
        return group.row_offsets[row_group_max_rows - 1 - bit];
    }

    /// Number of rows present in the group.
    pub fn numPresent(group: *const RowGroup) u16 {
        return @popCount(group.row_presence_flags);
    }

    pub fn eql(a: *const RowGroup, b: *const RowGroup) bool {
        return a.unknown == b.unknown and
            a.row_presence_flags == b.row_presence_flags and
            std.mem.eql(u16, &a.row_offsets, &b.row_offsets);
    }
};

/// One row of a data page, at the heap offset it is stored at.
pub const RowAtOffset = struct {
    /// Offset relative to the start of the page heap.
    offset: u16,
    row: Row,
};

/// The data-containing part of a page: a header, the rows at their heap
/// offsets, and the row groups at the end of the heap that locate them.
/// Heap bytes covered by neither a row nor a row group are zero on write;
/// the fixtures roundtrip under that model.
pub const DataPageContent = struct {
    /// The header of the data page.
    header: DataPageHeader = .{},
    /// Row groups in the order they are read backwards from the end of
    /// the heap: the group holding the page's first rows ends at the heap
    /// end, later groups sit below it.
    row_groups: []RowGroup = &.{},
    /// Rows in allocation order: row-group order, presence bits ascending.
    rows: []RowAtOffset = &.{},

    /// Reads the data page header, the row groups backwards from the end
    /// of the heap (as many as `page_header.packed_row_counts.num_rows`
    /// implies), and every present row at its heap offset. `c` is
    /// positioned at the data page header; `page_size` bounds the heap.
    /// The parsed row count must equal `num_rows_valid`.
    pub fn decode(
        c: *bin.Cursor,
        alloc: std.mem.Allocator,
        page_size: usize,
        page_header: PageHeader,
    ) DataPageDecodeError!DataPageContent {
        const heap_size = try dataPageHeapSize(page_size);
        const header = try bin.takeStruct(c, DataPageHeader, .little);
        const heap_start = c.pos;
        const heap_end = heap_start + heap_size;
        const num_rows: usize = page_header.packed_row_counts.num_rows;
        const num_groups = std.math.divCeil(
            usize,
            num_rows,
            row_group_max_rows,
        ) catch unreachable;
        if (heap_size < row_group_size * num_groups) return error.UnexpectedValue;

        const groups = try alloc.alloc(RowGroup, num_groups);
        errdefer alloc.free(groups);
        for (groups, 0..) |*group, g| {
            const group_end = heap_end - row_group_size * g;
            const group_start = group_end - row_group_size;
            if (group_start < heap_start) return error.UnexpectedValue;
            var sub = bin.Cursor{ .buf = try c.range(group_start, group_end) };
            for (&group.row_offsets) |*offset|
                offset.* = try sub.takeInt(u16, .little);
            group.row_presence_flags = try sub.takeInt(u16, .little);
            group.unknown = try sub.takeInt(u16, .little);
        }

        var rows = std.ArrayList(RowAtOffset).empty;
        errdefer {
            for (rows.items) |*at| at.row.deinit(alloc);
            rows.deinit(alloc);
        }
        for (groups) |*group| {
            for (0..row_group_max_rows) |bit| {
                const offset = group.presentOffset(@intCast(bit)) orelse continue;
                const pos = heap_start + offset;
                if (pos > c.buf.len) return error.UnexpectedEof;
                var sub = bin.Cursor{ .buf = c.buf[pos..], .alloc = alloc };
                try rows.append(alloc, .{
                    .offset = offset,
                    .row = try Row.decode(&sub, page_header.page_type),
                });
            }
        }
        if (rows.items.len != page_header.packed_row_counts.num_rows_valid)
            return error.UnexpectedValue;

        return .{
            .header = header,
            .row_groups = groups,
            .rows = try rows.toOwnedSlice(alloc),
        };
    }

    /// Writes the data page header, every row at its heap offset, and the
    /// row groups at the end of the heap, zero-filling uncovered heap
    /// bytes. `e` is positioned at the data page header; on return it
    /// holds exactly `page_size - 0x20` bytes.
    pub fn encode(
        self: *const DataPageContent,
        e: *bin.Emitter,
        page_size: usize,
    ) DataPageEncodeError!void {
        const heap_size = try dataPageHeapSize(page_size);
        if (self.row_groups.len * row_group_size > heap_size)
            return error.UnexpectedValue;

        try bin.putStruct(e, self.header, .little);
        const heap_start = e.pos();
        const heap_end = heap_start + heap_size;

        for (self.rows) |at| {
            var sub = bin.Emitter.init(e.alloc);
            defer sub.deinit();
            try at.row.encode(&sub);
            try e.putBytesAt(heap_start + at.offset, sub.written());
        }

        var group_bytes: [row_group_size]u8 = undefined;
        for (self.row_groups, 0..) |group, g| {
            for (group.row_offsets, 0..) |offset, i| {
                std.mem.writeInt(
                    u16,
                    group_bytes[2 * i ..][0..2],
                    offset,
                    .little,
                );
            }
            std.mem.writeInt(
                u16,
                group_bytes[2 * row_group_max_rows ..][0..2],
                group.row_presence_flags,
                .little,
            );
            std.mem.writeInt(
                u16,
                group_bytes[2 * row_group_max_rows + 2 ..][0..2],
                group.unknown,
                .little,
            );
            const group_end = heap_end - row_group_size * g;
            try e.putBytesAt(group_end - row_group_size, &group_bytes);
        }
        if (e.pos() < heap_end) try e.pad(heap_end - e.pos());
    }

    pub fn eql(a: *const DataPageContent, b: *const DataPageContent) bool {
        if (!std.meta.eql(a.header, b.header)) return false;
        if (a.row_groups.len != b.row_groups.len) return false;
        for (a.row_groups, b.row_groups) |*ag, *bg| {
            if (!ag.eql(bg)) return false;
        }
        if (a.rows.len != b.rows.len) return false;
        for (a.rows, b.rows) |*ar, *br| {
            if (ar.offset != br.offset or !ar.row.eql(br.row)) return false;
        }
        return true;
    }

    pub fn deinit(content: *DataPageContent, alloc: std.mem.Allocator) void {
        for (content.rows) |*at| at.row.deinit(alloc);
        alloc.free(content.rows);
        content.rows = &.{};
        alloc.free(content.row_groups);
        content.row_groups = &.{};
    }
};

/// Bytes of the page heap: the page behind its 0x20-byte page header and
/// the 8-byte data page header.
fn dataPageHeapSize(page_size: usize) error{UnexpectedValue}!usize {
    const fixed = bin.serializedLen(PageHeader) + bin.serializedLen(DataPageHeader);
    if (page_size < fixed) return error.UnexpectedValue;
    return page_size - fixed;
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

test "offset array decode failure frees already decoded items" {
    const alloc = testing.allocator;
    // Offsets {3, 8}: the first item is "foo"; the second points one byte
    // past the buffer, so decoding fails after the first item allocated.
    const bytes = [_]u8{ 0x03, 0x03, 0x08, 0x07, 'f', 'o', 'o', 0x01 };
    var c = bin.Cursor.initAlloc(alloc, &bytes);
    try testing.expectError(
        error.UnexpectedEof,
        OffsetArrayContainer(TestStringPair).decode(&c, 0, .u8),
    );
}

test "offset array container deinit frees its items" {
    const alloc = testing.allocator;
    // Offsets {3, 7}: the first item is "foo", the second the empty
    // string.
    const bytes = [_]u8{ 0x03, 0x03, 0x07, 0x07, 'f', 'o', 'o', 0x03 };
    var c = bin.Cursor.initAlloc(alloc, &bytes);
    var container = try OffsetArrayContainer(TestStringPair).decode(&c, 0, .u8);
    container.deinit(alloc);
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

// Page and index page tests, ported from rekordcrate's `bitfields.rs` and
// the `index_page` test of `test_roundtrip.rs`.

test "page flags wire values" {
    // The typical data page: unknown2 and unknown5 set.
    try testing.expectEqual(@as(u8, 0x24), @as(u8, @bitCast(PageFlags{})));
    // An index page additionally sets is_index_page.
    try testing.expectEqual(
        @as(u8, 0x64),
        @as(u8, @bitCast(PageFlags{ .is_index_page = true })),
    );
    // A data page containing a deleted row.
    try testing.expectEqual(
        @as(u8, 0x34),
        @as(u8, @bitCast(PageFlags{ .contains_deleted = true })),
    );

    // Fields read back from a wire value.
    const parsed: PageFlags = @bitCast(@as(u8, 0x34));
    try testing.expect(parsed.unknown2 and parsed.unknown5 and parsed.contains_deleted);
    try testing.expect(!parsed.unknown0 and !parsed.is_index_page);
}

test "packed row counts occupy the low 13 and high 11 bits" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, PackedRowCounts{ .num_rows = 22, .num_rows_valid = 22 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x16, 0xC0, 0x02 }, e.written());
    try bin.putStruct(&e, PackedRowCounts{ .num_rows = 5, .num_rows_valid = 7 }, .little);
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xE0, 0x00 }, e.written()[3..]);

    var c = bin.Cursor.init(e.written()[0..3]);
    try testing.expectEqual(
        PackedRowCounts{ .num_rows = 22, .num_rows_valid = 22 },
        try bin.takeStruct(&c, PackedRowCounts, .little),
    );
    try testing.expect(c.atEnd());
}

test "page header roundtrips and validates its constants" {
    const header: PageHeader = .{
        .page_index = 1,
        .page_type = .tracks,
        .next_page = 2,
        .unknown1 = 29871,
        .page_flags = .{ .is_index_page = true },
    };
    try testing.expectEqual(@as(usize, 0x20), bin.serializedLen(PageHeader));

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
    try testing.expectEqual(header, try bin.takeStruct(&c, PageHeader, .little));
    try testing.expect(c.atEnd());
    try bin.validateConstantFields(PageHeader, header);

    // Unknown page types roundtrip verbatim.
    var page_type_bytes = [_]u8{0} ** 0x20;
    page_type_bytes[8] = 0x63;
    var c2 = bin.Cursor.init(&page_type_bytes);
    const exotic = try bin.takeStruct(&c2, PageHeader, .little);
    try testing.expectEqual(@as(u32, 0x63), @intFromEnum(exotic.page_type));

    // A nonzero magic or unknown2 is rejected.
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(PageHeader, .{ .magic = 1 }),
    );
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(PageHeader, .{ .unknown2 = 1 }),
    );
}

test "index entries pack page index and flags" {
    const entry = IndexEntry{ .page_index = 604 };
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try bin.putStruct(&e, entry, .little);
    // Bits 31-3 hold the page index: 604 << 3.
    try testing.expectEqualSlices(u8, &.{ 0xE0, 0x12, 0x00, 0x00 }, e.written());

    var c = bin.Cursor.init(e.written());
    try testing.expectEqual(entry, try bin.takeStruct(&c, IndexEntry, .little));
    try testing.expect(c.atEnd());

    // The empty sentinel and its recognition.
    try testing.expectEqual(@as(u32, 0x1FFF_FFF8), @as(u32, @bitCast(IndexEntry.empty)));
    try testing.expect(IndexEntry.empty.isEmpty());
    try testing.expect(!entry.isEmpty());

    var c2 = bin.Cursor.init(&.{ 0xF8, 0xFF, 0xFF, 0x1F });
    try testing.expect((try bin.takeStruct(&c2, IndexEntry, .little)).isEmpty());
}

test "index page header roundtrips and validates its magics" {
    const header: IndexPageHeader = .{
        .unknown_a = 2,
        .unknown_b = 179,
        .next_offset = 272,
        .page_index = 1,
        .next_page = 2,
        .num_entries = 272,
    };
    try testing.expectEqual(@as(usize, 28), bin.serializedLen(IndexPageHeader));

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
    try testing.expectEqual(header, try bin.takeStruct(&c, IndexPageHeader, .little));
    try testing.expect(c.atEnd());

    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(IndexPageHeader, .{ .magic = 0 }),
    );
    try testing.expectError(
        error.UnexpectedValue,
        bin.validateConstantFields(IndexPageHeader, .{ .magic2 = 0 }),
    );
}

test "index page content pads to capacity with empty entries and zeros" {
    const alloc = testing.allocator;
    const content = IndexPageContent{ .header = .{ .page_index = 1, .next_page = 2 } };

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try content.encode(&e, 4096);
    // The content fills the page behind a 0x20-byte page header: a
    // 28-byte index header, 1004 entries, and 20 trailing zeros.
    try testing.expectEqual(@as(usize, 4096 - 0x20), e.written().len);

    var c = bin.Cursor.initAlloc(alloc, e.written());
    var parsed = try IndexPageContent.decode(&c, alloc);
    defer parsed.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), parsed.entries.len);
    try testing.expectEqual(@as(u16, 0), parsed.header.num_entries);
    try testing.expectEqual(content.header, parsed.header);
    for (0..1004) |_| {
        try testing.expect((try bin.takeStruct(&c, IndexEntry, .little)).isEmpty());
    }
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 20), try c.takeBytes(20));
    try testing.expect(c.atEnd());
}

test "index page content rejects malformed input" {
    const alloc = testing.allocator;

    // A header claiming two entries when only one is on the wire.
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, IndexPageHeader{ .num_entries = 2 }, .little);
    try bin.putStruct(&e, IndexEntry{ .page_index = 7 }, .little);
    var c = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(error.UnexpectedEof, IndexPageContent.decode(&c, alloc));

    // A wrong 0x03ec magic.
    var e2 = bin.Emitter.init(alloc);
    defer e2.deinit();
    try bin.putStruct(&e2, IndexPageHeader{ .magic = 0 }, .little);
    var c2 = bin.Cursor.initAlloc(alloc, e2.written());
    try testing.expectError(error.UnexpectedValue, IndexPageContent.decode(&c2, alloc));

    // More entries than the page holds, and a page too small for the
    // fixed parts.
    const many = try alloc.alloc(IndexEntry, 1005);
    defer alloc.free(many);
    for (many) |*entry| entry.* = .{};
    const big = IndexPageContent{ .entries = many };
    var e3 = bin.Emitter.init(alloc);
    defer e3.deinit();
    try testing.expectError(error.UnexpectedValue, big.encode(&e3, 4096));
    var e4 = bin.Emitter.init(alloc);
    defer e4.deinit();
    try testing.expectError(error.UnexpectedValue, big.encode(&e4, 0x20));
}

test "index page fixture parses with known field values" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/pdb/unit_tests", .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, "index_page.bin", alloc, .limited(1 << 16));
    defer alloc.free(bytes);

    var c = bin.Cursor.initAlloc(alloc, bytes);
    const header = try bin.takeStruct(&c, PageHeader, .little);
    try bin.validateConstantFields(PageHeader, header);
    try testing.expectEqual(@as(u32, 1), header.page_index);
    try testing.expectEqual(PageType.tracks, header.page_type);
    try testing.expectEqual(@as(u32, 2), header.next_page);
    try testing.expectEqual(@as(u32, 29871), header.unknown1);
    try testing.expectEqual(PackedRowCounts{}, header.packed_row_counts);
    try testing.expect(header.page_flags.is_index_page);
    try testing.expect(!header.page_flags.contains_deleted);
    try testing.expectEqual(@as(u16, 0), header.free_size);
    try testing.expectEqual(@as(u16, 0), header.used_size);

    var content = try IndexPageContent.decode(&c, alloc);
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

const testutil = @import("testutil");

/// Parses `input` — a whole page, including the page header — and
/// re-serializes it, for `testutil.expectFixturesRoundtrip`. The page
/// size is the fixture length; pages whose row types are not implemented
/// yet fail with `error.NotImplemented`.
fn roundtripPage(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var c = bin.Cursor.initAlloc(alloc, input);
    const header = try bin.takeStruct(&c, PageHeader, .little);
    try bin.validateConstantFields(PageHeader, header);

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, header, .little);
    if (header.page_flags.is_index_page) {
        var content = try IndexPageContent.decode(&c, alloc);
        defer content.deinit(alloc);
        try content.encode(&e, input.len);
    } else {
        var content = try DataPageContent.decode(&c, alloc, input.len, header);
        defer content.deinit(alloc);
        try content.encode(&e, input.len);
    }
    return e.toOwnedSlice();
}

test "index page fixture roundtrips byte-identical" {
    try testutil.expectFixturesRoundtrip(roundtripPage, "index_page", 1);
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
        try testutil.expectFixturesRoundtrip(roundtripPage, prefix, 1);
}

// Data page and simple row tests, ported from the row tests of
// rekordcrate's `test_roundtrip.rs` and the page semantics of
// `mod.rs`.

/// Mirrors the row tests of rekordcrate's `test_roundtrip`: parses
/// `bytes` expecting `expected` and full consumption, re-encodes
/// `expected` expecting `bytes` back, and checks `heapBytesRequired`
/// against the serialized length. `expected` must not own memory, since
/// it is never deinit-ed; strings in it are borrowed from the caller.
fn expectRowRoundtrip(comptime T: type, bytes: []const u8, expected: T) !void {
    var c = bin.Cursor.initAlloc(testing.allocator, bytes);
    var parsed = try T.decode(&c);
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

test "label row roundtrips" {
    var name = try DeviceSQLString.fromUtf8(testing.allocator, "Loopmasters");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        Label,
        &.{ 1, 0, 0, 0, 25, 76, 111, 111, 112, 109, 97, 115, 116, 101, 114, 115 },
        .{ .id = 1, .name = name },
    );
}

test "key row roundtrips" {
    var name = try DeviceSQLString.fromUtf8(testing.allocator, "Dm");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        Key,
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 7, 68, 109 },
        .{ .id = 1, .id2 = 1, .name = name },
    );
}

test "color row roundtrips" {
    var name = try DeviceSQLString.fromUtf8(testing.allocator, "Pink");
    defer name.deinit(testing.allocator);
    try expectRowRoundtrip(
        Color,
        &.{ 0, 0, 0, 0, 1, 1, 0, 0, 11, 80, 105, 110, 107 },
        .{ .unknown2 = 1, .color = .pink, .name = name },
    );
}

test "playlist entry row roundtrips" {
    try expectRowRoundtrip(
        PlaylistEntry,
        &.{ 1, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0 },
        .{ .entry_index = 1, .track_id = 1, .playlist_id = 6 },
    );
}

test "column entry row wraps its name in interlinear annotation anchors" {
    var name = try DeviceSQLString.fromUtf8(testing.allocator, "\u{fffa}GENRE\u{fffb}");
    defer name.deinit(testing.allocator);
    // The anchors are non-ASCII, so the string takes the long UCS-2LE
    // form even though the name itself is ASCII.
    try testing.expect(std.meta.activeTag(name.long) == .ucs2le);
    try expectRowRoundtrip(
        ColumnEntry,
        &.{
            0x01, 0x00, 0x80, 0x00, 0x90, 0x12, 0x00, 0x00, 0xfa, 0xff, 0x47, 0x00, 0x45,
            0x00, 0x4e, 0x00, 0x52, 0x00, 0x45, 0x00, 0xfb, 0xff,
        },
        .{ .id = 1, .unknown0 = 128, .column_name = name },
    );
}

test "menu row roundtrips" {
    try expectRowRoundtrip(
        Menu,
        &.{ 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00 },
        .{
            .category_id = 2,
            .content_pointer = 2,
            .unknown = 2,
            .visibility = .visible,
            .sort_order = 1,
        },
    );
}

test "history row roundtrips" {
    var date = try DeviceSQLString.fromUtf8(testing.allocator, "2022-02-02");
    defer date.deinit(testing.allocator);
    var version = try DeviceSQLString.fromUtf8(testing.allocator, "1000");
    defer version.deinit(testing.allocator);
    // Extracted from demo_tracks' export.pdb, page 40, heap offset 0xa0.
    try expectRowRoundtrip(
        History,
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
            .label = DeviceSQLString.empty(),
        },
    );
}

test "history row with label roundtrips" {
    var date = try DeviceSQLString.fromUtf8(testing.allocator, "2024-04-18");
    defer date.deinit(testing.allocator);
    var version = try DeviceSQLString.fromUtf8(testing.allocator, "1000");
    defer version.deinit(testing.allocator);
    var label = try DeviceSQLString.fromUtf8(testing.allocator, "ZAKS BACKUP");
    defer label.deinit(testing.allocator);
    // Extracted from num_rows' export.pdb, page 40, heap offset 0x298.
    try expectRowRoundtrip(
        History,
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
    );
}

test "history row rejects wrong magics" {
    const alloc = testing.allocator;
    var date = try DeviceSQLString.fromUtf8(alloc, "2022-02-02");
    defer date.deinit(alloc);
    var row = History{
        .subtype = 0x0280,
        .num_tracks = 5,
        .date = date,
    };
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try row.encode(&e);
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
        try testing.expectError(error.UnexpectedValue, History.decode(&c));
    }
    var corrupt_date = try alloc.dupe(u8, bytes);
    defer alloc.free(corrupt_date);
    corrupt_date[13] ^= 0xFF;
    var c = bin.Cursor.initAlloc(alloc, corrupt_date);
    var parsed = try History.decode(&c);
    defer parsed.deinit(alloc);
}

test "row decode dispatches by page type" {
    const alloc = testing.allocator;

    var name = try DeviceSQLString.fromUtf8(alloc, "Techno");
    defer name.deinit(alloc);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try e.putInt(u32, 1, .little);
    try name.encode(&e);

    var c = bin.Cursor.initAlloc(alloc, e.written());
    var row = try Row.decode(&c, .genres);
    defer row.deinit(alloc);
    try testing.expect(std.meta.activeTag(row) == .genre);
    try testing.expectEqual(PageType.genres, row.pageType());

    // Unwired and unknown page types are rejected explicitly.
    var c3 = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(
        error.NotImplemented,
        Row.decode(&c3, .tracks),
    );
    var c4 = bin.Cursor.initAlloc(alloc, e.written());
    try testing.expectError(
        error.NotImplemented,
        Row.decode(&c4, @enumFromInt(0x63)),
    );
}

test "row group slots fill from the array end, presence bits upwards" {
    const group = RowGroup{
        .row_offsets = blk: {
            var offsets: [row_group_max_rows]u16 = @splat(0);
            offsets[14] = 0x0008; // second row, presence bit 1
            offsets[15] = 0x0000; // first row, presence bit 0
            break :blk offsets;
        },
        .row_presence_flags = 0x0003,
        .unknown = 0x0002,
    };

    try testing.expectEqual(@as(usize, 16), row_group_max_rows);
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
        PageHeader{
            .page_index = 3,
            .page_type = .menu,
            .next_page = 4,
            .packed_row_counts = .{ .num_rows = 2, .num_rows_valid = 2 },
            .free_size = 56 - 16 - row_group_size,
            .used_size = 16,
        },
        .little,
    ) catch unreachable;
    bin.putStruct(&e, DataPageHeader{ .unknown5 = 1 }, .little) catch unreachable;
    bin.putStruct(&e, Menu{ .category_id = 1, .unknown = 99 }, .little) catch unreachable;
    bin.putStruct(&e, Menu{ .category_id = 2, .content_pointer = 2 }, .little) catch unreachable;
    @memcpy(page[0..e.written().len], e.written());
    page[0x28 + 16] = fill_gap;

    // The row group is the last 36 bytes of the heap: fourteen leading
    // slots (heap bytes, here nonzero to pin verbatim preservation), the
    // two present offsets, presence flags, and the unknown field.
    const group_start = 96 - row_group_size;
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
    const header = try bin.takeStruct(&c, PageHeader, .little);
    var content = try DataPageContent.decode(&c, alloc, page.len, header);
    defer content.deinit(alloc);

    // The page parsed into its two rows in allocation order and one
    // group keeping the leading slots verbatim.
    try testing.expectEqual(@as(usize, 1), content.row_groups.len);
    try testing.expectEqual(@as(usize, 2), content.rows.len);
    try testing.expectEqual(@as(u16, 0), content.rows[0].offset);
    try testing.expectEqual(@as(u16, 8), content.rows[1].offset);
    try testing.expect(content.rows[0].row.eql(.{ .menu = .{ .category_id = 1, .unknown = 99 } }));
    try testing.expect(content.rows[1].row.eql(.{ .menu = .{ .category_id = 2, .content_pointer = 2 } }));
    try testing.expectEqual(@as(u16, 0x0101), content.row_groups[0].row_offsets[0]);

    const out = try roundtripPage(alloc, &page);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, &page, out);
}

test "data page encode derives page layout from row groups" {
    const alloc = testing.allocator;
    var page = menuPageBytes(0);
    // The constructed content carries zeros in the unused leading slots.
    @memset(page[96 - row_group_size ..][0 .. 2 * 14], 0);
    var rows = [_]RowAtOffset{
        .{ .offset = 0, .row = .{ .menu = .{ .category_id = 1, .unknown = 99 } } },
        .{ .offset = 8, .row = .{ .menu = .{ .category_id = 2, .content_pointer = 2 } } },
    };
    var offsets: [row_group_max_rows]u16 = @splat(0);
    offsets[14] = 0x0008;
    offsets[15] = 0x0000;
    var groups = [_]RowGroup{.{
        .row_offsets = offsets,
        .row_presence_flags = 0x0003,
        .unknown = 0x0002,
    }};
    const content = DataPageContent{
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
        std.mem.writeInt(u16, page[0x1A..][0..2], 0xC0 | 1, .little); // num_rows_valid = 1
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, PageHeader, .little);
        try testing.expectError(
            error.UnexpectedValue,
            DataPageContent.decode(&c, alloc, page.len, header),
        );
    }

    // A row offset pointing past the page.
    {
        var page = menuPageBytes(0);
        const group_start = 96 - row_group_size;
        std.mem.writeInt(u16, page[group_start + 30 ..][0..2], 0xFFF0, .little);
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, PageHeader, .little);
        try testing.expectError(
            error.UnexpectedEof,
            DataPageContent.decode(&c, alloc, page.len, header),
        );
    }

    // Row groups not fitting the page heap.
    {
        var page = menuPageBytes(0);
        std.mem.writeInt(u16, page[0x18..][0..2], 0x0112, .little); // num_rows = 18
        var c = bin.Cursor.initAlloc(alloc, &page);
        const header = try bin.takeStruct(&c, PageHeader, .little);
        try testing.expectError(
            error.UnexpectedValue,
            DataPageContent.decode(&c, alloc, page.len, header),
        );
    }

    // A page smaller than its headers, and a page whose heap fits no
    // row group.
    {
        var c = bin.Cursor.init(&.{});
        try testing.expectError(
            error.UnexpectedValue,
            DataPageContent.decode(&c, alloc, 0x20, .{}),
        );
    }
    {
        var c = bin.Cursor.init(&([_]u8{0} ** 8));
        try testing.expectError(
            error.UnexpectedValue,
            DataPageContent.decode(&c, alloc, 0x28, .{ .packed_row_counts = .{ .num_rows = 1 } }),
        );
    }

    // More row groups than the page holds on write.
    {
        var many = [_]RowGroup{.{}} ** 2;
        const content = DataPageContent{ .row_groups = &many };
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try testing.expectError(
            error.UnexpectedValue,
            content.encode(&e, 96 - 0x20),
        );
    }
}
