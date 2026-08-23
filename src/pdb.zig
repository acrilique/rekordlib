// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the rekordbox `export.pdb` database (DeviceSQL):
//! the string type, the offset arrays that locate row tail data, page
//! headers with index pages, data pages with their rows — including
//! the tag rows of `exportExt.pdb` — and whole databases assembled from
//! the file header, its table of contents, and every page. The
//! modification layer allocates rows inside pages, appends rows to tables
//! with page-chain relinking, and creates new databases with the default
//! color, column, and menu rows.
//!
//! Ported from rekordcrate's `src/pdb/string.rs`, `src/pdb/offset_array.rs`,
//! `src/pdb/bitfields.rs`, `src/pdb/ext.rs`, and `src/pdb/defaults.rs`,
//! the page, index-page, data-page, row, header, and table parts of
//! `src/pdb/mod.rs`, and the modification parts of `src/pdb/io.rs`
//! (`create`, `add_row`, `allocate_row`).
//!
//! - <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/exports.html#devicesql-strings>

const std = @import("std");
const bin = @import("bin");
const util = @import("util");

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
        /// exactly filling `len` bytes — or returns `null` when the body
        /// is not of that shape, so UCS-2LE gets a chance.
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

    /// Frees the content.
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
    /// byte, the ISRC body shape) are.
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
/// provided-offset width disagreeing with the argument, an offset too
/// large for its width (computed offsets included), or an `array_offset`
/// argument exceeding the emitter position.
pub const OffsetArrayEncodeError = bin.WriteError || error{UnexpectedValue};

/// Specifies whether the offsets of an offset array are stored as `u8` or
/// `u16`; the surrounding row's subtype selects the width (see
/// `fromSubtype`).
pub const OffsetSize = enum {
    u8,
    u16,

    /// Bytes one stored offset occupies, magic excluded.
    pub fn bytes(size: OffsetSize) usize {
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

    /// Reads one stored offset at this width, widened to `u16`.
    fn takeOffset(size: OffsetSize, c: *bin.Cursor) bin.ReadError!u16 {
        return switch (size) {
            .u8 => try c.takeInt(u8, .little),
            .u16 => try c.takeInt(u16, .little),
        };
    }

    /// Writes one stored offset at this width, rejecting a value too
    /// wide for it.
    fn putOffset(size: OffsetSize, e: *bin.Emitter, value: u16) OffsetArrayEncodeError!void {
        switch (size) {
            .u8 => {
                if (value > std.math.maxInt(u8)) return error.UnexpectedValue;
                try e.putInt(u8, @intCast(value), .little);
            },
            .u16 => try e.putInt(u16, value, .little),
        }
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
            /// Width the offsets are stored at.
            size: OffsetSize,
            /// Offset values, relative to the row start.
            values: [n]u16,
        },

        /// Offsets computed during serialization, the mode for newly
        /// built rows; see `OffsetArrayContainer.encode`.
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
///   `DeviceSQLString`; `requiredAlignment` returns the power-of-two
///   alignment, at least 1, that a calculated offset must respect
///
/// Plus the item glue — `offsetItems(T) [n]OffsetItem` (a borrowing view),
/// `fromOffsetItems([n]OffsetItem) T` (which takes item ownership), and
/// `eql(a: T, b: T) bool` — declared either wholesale by `T` itself or,
/// when every field of `T` is an `OffsetItem`, generated from the field
/// list via `OffsetItemsOf`.
pub fn OffsetArrayContainer(comptime T: type) type {
    const n = T.offset_count;
    const Item = T.OffsetItem;
    // Item glue resolved once: the inner type's own declarations when it
    // provides any of them, otherwise the ones generated from its fields.
    const Protocol = if (@hasDecl(T, "offsetItems")) T else OffsetItemsOf(T, Item);
    return struct {
        const Self = @This();

        /// Number of offsets and items, re-exposed from `T`.
        pub const offset_count = n;

        /// The offsets; see `Offsets`.
        offsets: Offsets(n) = .calculated,

        /// The inner value the items combine into.
        inner: T = .{},

        /// Reads the offsets from `c`, then each item from its own
        /// sub-cursor at `base + offset`, `base` being the row start
        /// (the row walkers pass `fixedLen`). The cursor is left
        /// directly after the offsets; items may lie beyond that and
        /// need not fill the buffer they occupy. Items decoded before
        /// a failure are freed.
        pub fn decode(c: *bin.Cursor, array_offset: usize, size: OffsetSize) OffsetArrayDecodeError!Self {
            const start = c.pos;
            if (array_offset > start) return error.UnexpectedValue; // base underflow
            var values: [n]u16 = undefined;
            // The magic is stored like an offset of the chosen width.
            if (try size.takeOffset(c) != offset_array_magic)
                return error.InvalidFormat;
            for (&values) |*value| value.* = try size.takeOffset(c);
            const base = start - array_offset;
            var items: [n]Item = undefined;
            // The comptime guard lets zero-item containers use `void`
            // items, whose type has no `decode`.
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
                .inner = Protocol.fromOffsetItems(items),
            };
        }

        /// Writes the magic and offsets, then each item — placed at
        /// `base + offset` for provided offsets (the inverse of `decode`,
        /// same `array_offset` convention; gaps the offsets skip over are
        /// zero-filled), or appended in order for calculated ones, each
        /// start aligned per its `requiredAlignment`, with the computed
        /// offsets patched back into their reserved slots.
        pub fn encode(
            self: *const Self,
            e: *bin.Emitter,
            array_offset: usize,
            size: OffsetSize,
        ) OffsetArrayEncodeError!void {
            const start = e.pos();
            if (array_offset > start) return error.UnexpectedValue; // base underflow
            const base = start - array_offset;
            switch (self.offsets) {
                .provided => |provided| {
                    if (provided.size != size) return error.UnexpectedValue;
                    try size.putOffset(e, offset_array_magic);
                    for (provided.values) |value| try size.putOffset(e, value);
                    var sub = bin.Emitter.init(e.alloc);
                    defer sub.deinit();
                    inline for (Protocol.offsetItems(self.inner), provided.values) |item, offset| {
                        sub.clear();
                        try item.encode(&sub);
                        try e.putBytesAt(base + @as(usize, offset), sub.written());
                    }
                },
                .calculated => {
                    try size.putOffset(e, offset_array_magic);
                    try e.pad(n * size.bytes());
                    if (comptime Item != void) {
                        inline for (Protocol.offsetItems(self.inner), 0..) |item, i| {
                            const alignment: usize = item.requiredAlignment();
                            const current = e.pos() - base;
                            const aligned = std.mem.alignForward(usize, current, alignment);
                            if (aligned > current) try e.pad(aligned - current);
                            const offset = e.pos() - base;
                            if (offset > std.math.maxInt(u16) or
                                (size == .u8 and offset > std.math.maxInt(u8)))
                                return error.UnexpectedValue;
                            try item.encode(e);
                            const slot = start + size.bytes() * (i + 1);
                            switch (size) {
                                .u8 => e.patchIntAt(slot, u8, @intCast(offset), .little),
                                .u16 => e.patchIntAt(slot, u16, @intCast(offset), .little),
                            }
                        }
                    }
                },
            }
        }

        /// Page heap space in bytes the container occupies: the magic and
        /// offsets plus every item, alignment padding included when the
        /// offsets are calculated. Provided offsets measure the file's
        /// actual placement, so gaps between items do not count.
        pub fn heapBytesRequired(self: *const Self, size: OffsetSize) u32 {
            const calculated = switch (self.offsets) {
                .calculated => true,
                .provided => false,
            };
            var total: u32 = @intCast((n + 1) * size.bytes());
            inline for (Protocol.offsetItems(self.inner)) |item| {
                if (calculated) {
                    const alignment: u32 = item.requiredAlignment();
                    total = std.mem.alignForward(u32, total, alignment);
                }
                total += item.heapBytesRequired();
            }
            return total;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.offsets.eql(b.offsets) and Protocol.eql(a.inner, b.inner);
        }

        /// Frees the items.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            if (Item == void) return;
            var items = Protocol.offsetItems(self.inner);
            for (&items) |*item| item.deinit(alloc);
        }
    };
}

/// Generates the offset-array inner-type declarations — `offsetItems`,
/// `fromOffsetItems`, and `eql` — for a `T` whose fields are all `Item`,
/// mapping slots to fields in declaration order, which is the wire slot
/// order. Zero-field types are allowed, with `Item` of `void`.
fn OffsetItemsOf(comptime T: type, comptime Item: type) type {
    const fields = std.meta.fields(T);
    for (fields) |field| {
        if (field.type != Item)
            @compileError(
                "OffsetItemsOf: every field of " ++ @typeName(T) ++
                    " must be a " ++ @typeName(Item) ++ ", `" ++
                    field.name ++ "` is not",
            );
    }
    return struct {
        pub fn offsetItems(inner: T) [fields.len]Item {
            var items: [fields.len]Item = undefined;
            inline for (fields, 0..) |field, i| {
                items[i] = @field(inner, field.name);
            }
            return items;
        }

        pub fn fromOffsetItems(items: [fields.len]Item) T {
            var inner: T = undefined;
            inline for (fields, 0..) |field, i| {
                @field(inner, field.name) = items[i];
            }
            return inner;
        }

        pub fn eql(a: T, b: T) bool {
            const a_items = offsetItems(a);
            const b_items = offsetItems(b);
            inline for (0..fields.len) |i| {
                if (!a_items[i].eql(b_items[i])) return false;
            }
            return true;
        }
    };
}

/// The type of database being parsed, which selects the meaning of the
/// page-type values in page headers and table entries: standard
/// `export.pdb` files or extended `exportExt.pdb` files, whose tables
/// reuse values 3 and 4 for tags and track tags instead of albums and
/// labels. Row dispatch is gated on this (see `Row.decode`).
pub const DatabaseType = enum {
    /// Standard `export.pdb` files.
    plain,
    /// Extended `exportExt.pdb` files.
    ext,
};

/// The type of rows a page holds, as stored in page headers and table
/// entries: the wire constants of `export.pdb` tables (see `DatabaseType`
/// for the ext meanings of values 3 and 4). Unknown values roundtrip
/// verbatim.
pub const PageType = enum(u32) {
    /// Track metadata: title, artist, genre, artwork ID, playing time, etc.
    tracks = 0,
    /// Musical genres.
    genres = 1,
    /// Artists.
    artists = 2,
    /// Albums.
    albums = 3,
    /// Music labels.
    labels = 4,
    /// Musical keys.
    keys = 5,
    /// Color labels.
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

/// Page types of `exportExt.pdb` databases whose wire values collide
/// with plain meanings (see `DatabaseType`). Unknown values fail row
/// dispatch with `error.NotImplemented`.
pub const ExtPageType = enum(u32) {
    /// Rows that can be assigned to tracks for the purpose of
    /// categorization.
    tag = 3,
    /// Rows holding the associations between tag ids and track ids.
    track_tag = 4,
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
/// field is bit 0. The default value is the typical data page (`0x24`);
/// index pages set `is_index_page` (`0x64`).
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
    /// `num_entries` for unknown reasons; observed naming a slot past the
    /// declared entries, and the slots it covers can hold live entries
    /// that `num_entries` does not count — `decode` reads up to it so
    /// those entries survive a write.
    next_offset: u16 = 0,
    /// Redundant copy of the page index.
    page_index: u32 = 0,
    /// Redundant copy of the next page index.
    next_page: u32 = 0,
    /// Magic value `0x0000_0000_03ff_ffff`.
    magic2: u64 = 0x0000_0000_03FF_FFFF,
    /// Number of index entries this page declares. Real pages sometimes
    /// carry meaningful entries beyond this count (see `next_offset`);
    /// written verbatim, never re-derived.
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
/// pointing at the table's data pages.
pub const IndexPageContent = struct {
    header: IndexPageHeader = .{},
    entries: []IndexEntry = &.{},

    /// Reads the header (validating its magics) and
    /// `max(num_entries, next_offset)` entries; the padding entries and
    /// trailing zeros are not read.
    pub fn decode(c: *bin.Cursor, alloc: std.mem.Allocator) IndexPageDecodeError!IndexPageContent {
        const header = try bin.takeStruct(c, IndexPageHeader, .little);
        try bin.validateConstantFields(IndexPageHeader, header);
        const read_count: usize = @max(header.num_entries, header.next_offset);
        const entries = try bin.takeStructSlice(alloc, c, IndexEntry, .little, read_count);
        return .{ .header = header, .entries = entries };
    }

    /// Writes the header with its verbatim `num_entries`, the entries,
    /// `totalEntries(page_size) - entries.len` empty entries, and the
    /// trailing zeros.
    pub fn encode(self: *const IndexPageContent, e: *bin.Emitter, page_size: usize) IndexPageEncodeError!void {
        if (self.entries.len > std.math.maxInt(u16) or
            self.entries.len < self.header.num_entries) return error.UnexpectedValue;
        const capacity = try totalEntries(page_size);
        if (self.entries.len > capacity) return error.UnexpectedValue;

        try bin.putStruct(e, self.header, .little);
        for (self.entries) |entry| try bin.putStruct(e, entry, .little);
        for (self.entries.len..capacity) |_| try bin.putStruct(e, IndexEntry.empty, .little);
        try e.pad(index_page_zero_tail);
    }

    pub fn deinit(content: *IndexPageContent, alloc: std.mem.Allocator) void {
        alloc.free(content.entries);
        content.entries = &.{};
    }

    pub fn eql(a: *const IndexPageContent, b: *const IndexPageContent) bool {
        if (!std.meta.eql(a.header, b.header)) return false;
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |ae, be| {
            if (@as(u32, @bitCast(ae)) != @as(u32, @bitCast(be))) return false;
        }
        return true;
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

/// Audio file formats tracks reference, stored as the Track row's
/// `file_type` field. Ported from rekordcrate's `util::FileType`; unknown
/// values roundtrip verbatim.
pub const FileType = enum(u16) {
    /// Unknown file type.
    unknown = 0,
    /// MP3.
    mp3 = 1,
    /// M4A.
    m4a = 4,
    /// FLAC.
    flac = 5,
    /// WAV.
    wav = 0x0B,
    /// AIFF.
    aiff = 0x0C,
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
/// from page types whose rows are not wired for the database type being
/// parsed.
pub const RowDecodeError = bin.ReadError || error{ InvalidFormat, UnexpectedValue, NotImplemented };

/// Decoding error of a data page: row errors plus `UnexpectedValue` for
/// row groups not fitting the page or the parsed row count disagreeing
/// with `num_rows_valid`.
pub const DataPageDecodeError = RowDecodeError;

/// Encoding error of a row: the trailing offset array's errors, the only
/// fallible part of a row write (see `OffsetArrayEncodeError`).
pub const RowEncodeError = OffsetArrayEncodeError;

/// Encoding error of a data page: row encoding errors; `UnexpectedValue`
/// covers row groups not fitting the page, rows overlapping each other or
/// reaching past the row groups' first used byte, and content overrunning
/// the heap.
pub const DataPageEncodeError = RowEncodeError;

const history_date_magic: u32 = 0;
const history_version_magic: u16 = 0x1E19;

/// Whether `T` is an `OffsetArrayContainer` instantiation, recognized by
/// its `offset_count` declaration.
fn isOffsetContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "offset_count"),
        else => false,
    };
}

/// The field kinds the row walkers understand, classified in one place
/// (see `rowFieldKind`).
const RowFieldKind = enum {
    int,
    @"enum",
    /// An inline `DeviceSQLString`.
    string,
    /// An `OffsetArrayContainer`.
    offset_container,
};

/// Classifies a row field for the walkers (`fixedLen`, `decodeRow`,
/// `encodeRow`, `rowHeapBytesRequired`, `rowEql`, `rowDeinit`): the single
/// place a field type's kind is decided, so every walker handles every
/// kind or fails to compile.
fn rowFieldKind(comptime T: type) RowFieldKind {
    return if (isOffsetContainer(T))
        .offset_container
    else if (T == DeviceSQLString)
        .string
    else switch (@typeInfo(T)) {
        .int => .int,
        .@"enum" => .@"enum",
        else => @compileError("rowFieldKind: unsupported field type `" ++ @typeName(T) ++ "`"),
    };
}

/// Compile-time contract of the row walkers: an offset-array container
/// field must be preceded by the row's `subtype` field, which selects
/// its offset width.
fn validateRowType(comptime T: type) void {
    comptime {
        const fields = std.meta.fields(T);
        for (fields, 0..) |field, i| {
            if (!isOffsetContainer(field.type)) continue;
            for (fields[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, "subtype") and prev.type == u16) break;
            } else @compileError(
                @typeName(T) ++ "." ++ field.name ++
                    ": offset containers must be preceded by a `subtype: u16` field",
            );
        }
    }
}

/// Bytes a row's fixed fields occupy: every field except the
/// variable-length strings and offset-array containers.
fn fixedLen(comptime T: type) usize {
    return comptime blk: {
        var len: usize = 0;
        for (std.meta.fields(T)) |field| {
            switch (rowFieldKind(field.type)) {
                .int => len += @sizeOf(field.type),
                .@"enum" => len += @sizeOf(@typeInfo(field.type).@"enum".tag_type),
                .string, .offset_container => {},
            }
        }
        break :blk len;
    };
}

/// Reads the fields of row type `T` in declaration order at
/// little-endian: the row-layer analogue of `bin.takeStruct`. Supported
/// field types are integers, non-exhaustive enums (so unknown values
/// roundtrip verbatim), inline `DeviceSQLString`s, and a trailing
/// offset-array container whose offsets reach back past the row's
/// fixed fields (`fixedLen`). Fields a failing decode leaves behind
/// are freed, and a `constant_fields` declaration is validated after
/// the walk, as for page headers.
pub fn decodeRow(comptime T: type, c: *bin.Cursor) RowDecodeError!T {
    comptime validateRowType(T);
    var row: T = .{};
    errdefer {
        if (c.alloc) |alloc| rowDeinit(T, &row, alloc);
    }
    inline for (std.meta.fields(T)) |field| {
        switch (comptime rowFieldKind(field.type)) {
            .offset_container => {
                @field(row, field.name) = try field.type.decode(
                    c,
                    fixedLen(T),
                    OffsetSize.fromSubtype(row.subtype),
                );
            },
            .string => @field(row, field.name) = try DeviceSQLString.decode(c),
            .int => @field(row, field.name) = try c.takeInt(field.type, .little),
            .@"enum" => {
                const en = @typeInfo(field.type).@"enum";
                if (en.is_exhaustive)
                    @compileError("decodeRow: enum fields must be non-exhaustive, `" ++ @typeName(field.type) ++ "` is not");
                @field(row, field.name) = @enumFromInt(try c.takeInt(en.tag_type, .little));
            },
        }
    }
    try bin.validateConstantFields(T, row);
    return row;
}

/// Writes the fields of `row` in declaration order; see `decodeRow` for
/// the supported field types.
pub fn encodeRow(comptime T: type, row: *const T, e: *bin.Emitter) RowEncodeError!void {
    inline for (std.meta.fields(T)) |field| {
        switch (comptime rowFieldKind(field.type)) {
            .offset_container => try @field(row.*, field.name).encode(
                e,
                fixedLen(T),
                OffsetSize.fromSubtype(@field(row.*, "subtype")),
            ),
            .string => try @field(row.*, field.name).encode(e),
            .int => try e.putInt(field.type, @field(row.*, field.name), .little),
            .@"enum" => try e.putInt(
                @typeInfo(field.type).@"enum".tag_type,
                @intFromEnum(@field(row.*, field.name)),
                .little,
            ),
        }
    }
}

/// Page heap space in bytes the row occupies: its fixed fields plus the
/// strings and the trailing offset-array container at their actual
/// sizes.
pub fn rowHeapBytesRequired(comptime T: type, row: *const T) u32 {
    var total: u32 = @intCast(fixedLen(T));
    inline for (std.meta.fields(T)) |field| {
        switch (comptime rowFieldKind(field.type)) {
            .offset_container => total += @field(row.*, field.name).heapBytesRequired(
                OffsetSize.fromSubtype(@field(row.*, "subtype")),
            ),
            .string => total += @field(row.*, field.name).heapBytesRequired(),
            .int, .@"enum" => {},
        }
    }
    return total;
}

/// Field-by-field equality: strings and offset-array containers through
/// their `eql`, everything else by value.
pub fn rowEql(comptime T: type, a: *const T, b: *const T) bool {
    inline for (std.meta.fields(T)) |field| {
        switch (comptime rowFieldKind(field.type)) {
            .offset_container, .string => {
                if (!@field(a.*, field.name).eql(@field(b.*, field.name))) return false;
            },
            .int, .@"enum" => {
                if (@field(a.*, field.name) != @field(b.*, field.name)) return false;
            },
        }
    }
    return true;
}

/// Frees the row's strings and offset-array containers.
pub fn rowDeinit(comptime T: type, row: *T, alloc: std.mem.Allocator) void {
    inline for (std.meta.fields(T)) |field| {
        switch (comptime rowFieldKind(field.type)) {
            .offset_container, .string => @field(row.*, field.name).deinit(alloc),
            .int, .@"enum" => {},
        }
    }
}

pub const Genre = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the genre.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .genres;
};

pub const Label = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the record label.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .labels;
};

pub const Key = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Apparently a second copy of the row ID.
    id2: u32 = 0,
    /// Name of the key.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .keys;
};

pub const Color = struct {
    /// Unknown field.
    unknown1: u32 = 0,
    /// Unknown field.
    unknown2: u8 = 0,
    /// Numeric color ID.
    color: util.ColorIndex = .none,
    /// Unknown field.
    unknown3: u16 = 0,
    /// User-defined name of the color.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .colors;
};

pub const Artwork = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Path to the album art file.
    path: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .artwork;
};

pub const HistoryPlaylist = struct {
    /// ID of this row.
    id: u32 = 0,
    /// Name of the playlist.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .history_playlists;
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
    /// Magic value between `num_tracks` and `date`; always zero.
    date_magic: u32 = history_date_magic,
    /// Sync date, e.g. "2022-02-02".
    date: DeviceSQLString = DeviceSQLString.empty(),
    /// Magic value between `date` and `version`; always `0x1E19`.
    version_magic: u16 = history_version_magic,
    /// Format/protocol version string, "1000" in all known exports.
    version: DeviceSQLString = DeviceSQLString.empty(),
    /// Device or backup label; can be empty.
    label: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .history;

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see `bin.validateConstantFields`).
    pub const constant_fields = .{ .date_magic, .version_magic };
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
};

/// The single name string at the end of Artist and Album rows, located by
/// the row's offset array.
pub const TrailingName = struct {
    /// The name at the end of the row.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const offset_count = 1;
    pub const OffsetItem = DeviceSQLString;
};

/// Contains the artist name and ID.
pub const Artist = struct {
    /// Selects the trailing offset array's width (see
    /// `OffsetSize.fromSubtype`); observed values `0x60` and `0x64`.
    subtype: u16 = 0x60,
    /// Unknown field, called `index_shift` by flesniak; appears to always
    /// be `0x20 * row index`.
    index_shift: u16 = 0,
    /// ID of this row.
    id: u32 = 0,
    /// The offsets and the name at the end of the row.
    offsets: OffsetArrayContainer(TrailingName) = .{},

    pub const page_type: PageType = .artists;
};

/// Contains the album name, the ID of its artist, and its own ID.
pub const Album = struct {
    /// Selects the trailing offset array's width (see
    /// `OffsetSize.fromSubtype`); the usual value is `0x0080`.
    subtype: u16 = 0x0080,
    /// Unknown field; appears to always be `0x20 * row index`.
    index_shift: u16 = 0,
    /// Unknown field.
    unknown2: u32 = 0,
    /// ID of the artist row associated with this row.
    artist_id: u32 = 0,
    /// ID of this row.
    id: u32 = 0,
    /// Unknown field.
    unknown3: u32 = 0,
    /// The offsets and the name at the end of the row.
    offsets: OffsetArrayContainer(TrailingName) = .{},

    pub const page_type: PageType = .albums;
};

/// A node in the playlist tree: a folder grouping other nodes or a leaf
/// playlist.
pub const PlaylistTreeNode = struct {
    /// ID of the parent row (which must be a folder); nodes parented to
    /// `PlaylistTreeNodeId.root` (0) sit at the top level.
    parent_id: u32 = 0,
    /// Unknown field.
    unknown: u32 = 0,
    /// Sort order indicator.
    sort_order: u32 = 0,
    /// ID of this row.
    id: u32 = 0,
    /// Non-zero when the node is a folder, zero when it is a leaf
    /// playlist (rekordcrate's doc comment inverts the meaning; its
    /// code and the fixtures agree on this one).
    node_is_folder: u32 = 0,
    /// Name of this node, as shown when navigating the menu.
    name: DeviceSQLString = DeviceSQLString.empty(),

    pub const page_type: PageType = .playlist_tree;

    /// Whether the node is a folder (grouping other nodes) rather than a
    /// leaf playlist.
    pub fn isFolder(self: *const PlaylistTreeNode) bool {
        return self.node_is_folder > 0;
    }
};

/// The string fields of a Track row, stored behind its offset array.
pub const TrackStrings = struct {
    /// International Standard Recording Code (ISRC), in mangled format.
    isrc: DeviceSQLString = DeviceSQLString.empty(),
    /// Lyricist of the track.
    lyricist: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field containing a number; appears to increment
    /// when the track is exported or modified in rekordbox.
    unknown_string2: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field containing a number.
    unknown_string3: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field.
    unknown_string4: DeviceSQLString = DeviceSQLString.empty(),
    /// Track "message", a field in the rekordbox UI.
    message: DeviceSQLString = DeviceSQLString.empty(),
    /// "Publish track information" in rekordbox; "ON" or empty. Appears
    /// related to the Stagehand product for controlling DJ equipment
    /// remotely.
    publish_track_information: DeviceSQLString = DeviceSQLString.empty(),
    /// Whether hotcues should be autoloaded; "ON" or empty.
    autoload_hotcues: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field (usually empty).
    unknown_string5: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field (usually empty).
    unknown_string6: DeviceSQLString = DeviceSQLString.empty(),
    /// Date the track was added to the rekordbox collection (YYYY-MM-DD).
    date_added: DeviceSQLString = DeviceSQLString.empty(),
    /// Date the track was released (YYYY-MM-DD).
    release_date: DeviceSQLString = DeviceSQLString.empty(),
    /// Name of the remix (if any).
    mix_name: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field (usually empty).
    unknown_string7: DeviceSQLString = DeviceSQLString.empty(),
    /// File path of the track analysis file.
    analyze_path: DeviceSQLString = DeviceSQLString.empty(),
    /// Date the track analysis was performed (YYYY-MM-DD).
    analyze_date: DeviceSQLString = DeviceSQLString.empty(),
    /// Track comment.
    comment: DeviceSQLString = DeviceSQLString.empty(),
    /// Track title.
    title: DeviceSQLString = DeviceSQLString.empty(),
    /// Unknown string field (usually empty).
    unknown_string8: DeviceSQLString = DeviceSQLString.empty(),
    /// Name of the file.
    filename: DeviceSQLString = DeviceSQLString.empty(),
    /// Path of the file.
    file_path: DeviceSQLString = DeviceSQLString.empty(),

    pub const offset_count = std.meta.fields(@This()).len;
    pub const OffsetItem = DeviceSQLString;
};

/// The subtype every observed Track row carries.
const track_subtype: u16 = 0x24;

/// Contains a track: its metadata, foreign-key IDs into the other tables,
/// and the 21 strings behind the row's trailing offset array.
pub const Track = struct {
    /// Selects the trailing offset array's width (see
    /// `OffsetSize.fromSubtype` and `track_subtype`).
    subtype: u16 = track_subtype,
    /// Unknown field; appears to always be `0x20 * row index`.
    index_shift: u16 = 0,
    /// Unknown field, called `bitmask` by flesniak; appears to always be
    /// `0x000c0700`.
    bitmask: u32 = 0,
    /// Sample rate in Hz.
    sample_rate: u32 = 0,
    /// Composer of this track as artist row ID (non-zero if set).
    composer_id: u32 = 0,
    /// File size in bytes.
    file_size: u32 = 0,
    /// Unknown field; observed values are effectively random.
    unknown2: u32 = 0,
    /// Unknown field; observed values 19048, 64128, 31844 — the same for
    /// all tracks in a given database.
    unknown3: u16 = 0,
    /// Unknown field; observed values 30967, 1511, 9043 — the same for
    /// all tracks in a given database.
    unknown4: u16 = 0,
    /// Artwork row ID for the cover art (non-zero if set).
    artwork_id: u32 = 0,
    /// Key row ID for this track (non-zero if set).
    key_id: u32 = 0,
    /// Artist row ID of the original performer (non-zero if set).
    orig_artist_id: u32 = 0,
    /// Label row ID for this track (non-zero if set).
    label_id: u32 = 0,
    /// Artist row ID of the remixer (non-zero if set).
    remixer_id: u32 = 0,
    /// Bitrate of the track.
    bitrate: u32 = 0,
    /// Track number of the track.
    track_number: u32 = 0,
    /// Track tempo in centi-BPM (= 1/100 BPM).
    tempo: u32 = 0,
    /// Genre row ID for this track (non-zero if set).
    genre_id: u32 = 0,
    /// Album row ID for this track (non-zero if set).
    album_id: u32 = 0,
    /// Artist row ID for this track (non-zero if set).
    artist_id: u32 = 0,
    /// Row ID of this track.
    id: u32 = 0,
    /// Disc number of this track.
    disc_number: u16 = 0,
    /// Number of times this track was played.
    play_count: u16 = 0,
    /// Year this track was released.
    year: u16 = 0,
    /// Bits per sample of the track's audio file.
    sample_depth: u16 = 0,
    /// Playback duration of this track in seconds (at normal speed).
    duration: u16 = 0,
    /// Unknown field, apparently always `0x29` (41).
    unknown5: u16 = 0,
    /// Color row ID for this track (non-zero if set).
    color: util.ColorIndex = .none,
    /// User rating of this track (0 to 5 stars).
    rating: u8 = 0,
    /// Format of the file.
    file_type: FileType = .unknown,
    /// The offsets and the strings at the end of the row.
    offsets: OffsetArrayContainer(TrackStrings) = .{},

    pub const page_type: PageType = .tracks;
};

/// The strings associated with a tag or category, stored behind the row's
/// offset array.
pub const TagOrCategoryStrings = struct {
    /// The name of the tag or category.
    name: DeviceSQLString = DeviceSQLString.empty(),
    /// String with unknown purpose, often empty.
    unknown: DeviceSQLString = DeviceSQLString.empty(),

    pub const offset_count = 2;
    pub const OffsetItem = DeviceSQLString;
};

/// A tag or category that can be assigned to tracks for the purpose of
/// categorization, from the tag tables of `exportExt.pdb`. A non-zero
/// `raw_is_category` marks a category row; tag rows reference their
/// category through `parent_id`.
pub const TagOrCategory = struct {
    /// Selects the trailing offset array's width (see
    /// `OffsetSize.fromSubtype`); observed values `0x0680` and `0x0684`.
    subtype: u16 = 0x0680,
    /// Unknown field; appears to always be `0x20 * row index`.
    index_shift: u16 = 0,
    /// Unknown purpose; not always zero.
    unknown1: u32 = 0,
    /// Unknown purpose; not always zero.
    unknown2: u32 = 0,
    /// ID of the parent category row, or 0 when there is no parent
    /// (rekordcrate's `Option<NonZero<u32>>` collapsed to the wire
    /// value it serializes to).
    parent_id: u32 = 0,
    /// Zero-based position at which this tag is displayed within its
    /// category; for a category row, the position of the category within
    /// the category list.
    position: u32 = 0,
    /// Numeric ID of the tag or category.
    id: u32 = 0,
    /// Non-zero (observed: `1 << 24`) when this row represents a category
    /// rather than a tag.
    raw_is_category: u32 = 0,
    /// The offsets and the strings at the end of the row.
    offsets: OffsetArrayContainer(TagOrCategoryStrings) = .{},

    pub const ext_page_type: ExtPageType = .tag;
};

/// An M*N junction row between tags and tracks, from the track-tag
/// tables of `exportExt.pdb`.
pub const TrackTag = struct {
    /// Magic value; always zero.
    magic: u32 = 0,
    /// The ID of the track.
    track_id: u32 = 0,
    /// The ID of the tag.
    tag_id: u32 = 0,
    /// Unknown purpose; seems to be always 3.
    unknown_const: u32 = 3,

    pub const ext_page_type: ExtPageType = .track_tag;

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see
    /// `bin.validateConstantFields`).
    pub const constant_fields = .{.magic};
};

/// Whether rows of type `T` live in pages of `page_type` in a database of
/// `db_type`: plain row types declare `page_type`, ext row types declare
/// `ext_page_type` (see `DatabaseType`).
fn rowMatchesPageType(
    comptime T: type,
    page_type: PageType,
    db_type: DatabaseType,
) bool {
    if (comptime @hasDecl(T, "page_type")) {
        return db_type == .plain and T.page_type == page_type;
    } else {
        return db_type == .ext and
            @intFromEnum(page_type) == @intFromEnum(T.ext_page_type);
    }
}

/// The page-type wire value rows of type `T` dispatch on: the `page_type`
/// decl of plain row types, or the raw value of an ext row type's
/// `ext_page_type`.
fn rowPageType(comptime T: type) PageType {
    if (@hasDecl(T, "page_type")) return T.page_type;
    return @enumFromInt(@intFromEnum(T.ext_page_type));
}

/// A table row: one of the row types below, boxed behind a pointer so the
/// union costs a tag and a pointer instead of the size of its largest
/// variant — pages full of twelve-byte entries must not pay `Track`'s
/// 21 strings each. The payload is allocated by `decode` (with the
/// cursor's allocator) or by the caller (with the database's arena, for
/// rows moved into `addRow`), and freed by `deinit`. Each variant declares
/// its `page_type` (plain rows) or `ext_page_type` (ext rows), which
/// selects it in `decode`; page types of the other database type and
/// unknown values fail with `error.NotImplemented`.
pub const Row = union(enum) {
    genre: *Genre,
    label: *Label,
    key: *Key,
    color: *Color,
    artwork: *Artwork,
    artist: *Artist,
    album: *Album,
    playlist_tree_node: *PlaylistTreeNode,
    track: *Track,
    history_playlist: *HistoryPlaylist,
    history_entry: *HistoryEntry,
    playlist_entry: *PlaylistEntry,
    history: *History,
    column_entry: *ColumnEntry,
    menu: *Menu,
    tag: *TagOrCategory,
    track_tag: *TrackTag,

    /// Reads the row for `page_type` from `c`, which starts at the row's
    /// heap offset, dispatching per `rowMatchesPageType` and boxing the
    /// decoded payload — so `c` must carry an allocator (see
    /// `bin.Cursor.initAlloc`) even for rows whose fields allocate
    /// nothing.
    pub fn decode(
        c: *bin.Cursor,
        page_type: PageType,
        db_type: DatabaseType,
    ) RowDecodeError!Row {
        const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
        return inline for (std.meta.fields(Row)) |field| {
            if (rowMatchesPageType(RowPayload(field.type), page_type, db_type)) {
                const payload = try alloc.create(RowPayload(field.type));
                errdefer alloc.destroy(payload);
                payload.* = try decodeRow(RowPayload(field.type), c);
                break @unionInit(Row, field.name, payload);
            }
        } else error.NotImplemented;
    }

    pub fn encode(self: *const Row, e: *bin.Emitter) RowEncodeError!void {
        return switch (self.*) {
            inline else => |row| try encodeRow(@TypeOf(row.*), row, e),
        };
    }

    /// Page heap space in bytes the row occupies.
    pub fn heapBytesRequired(self: *const Row) u32 {
        return switch (self.*) {
            inline else => |row| rowHeapBytesRequired(@TypeOf(row.*), row),
        };
    }

    /// The page type rows of this variant belong to; pair it with the
    /// database type before comparing against page headers (see
    /// `DatabaseType`).
    pub fn pageType(self: Row) PageType {
        return switch (self) {
            inline else => |row| comptime rowPageType(@TypeOf(row.*)),
        };
    }

    pub fn eql(a: *const Row, b: *const Row) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            inline else => |row, tag| rowEql(@TypeOf(row.*), row, @field(b.*, @tagName(tag))),
        };
    }

    /// Frees the row's strings and the boxed payload.
    pub fn deinit(self: *Row, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |row| {
                rowDeinit(@TypeOf(row.*), row, alloc);
                alloc.destroy(row);
            },
        }
    }
};

/// The payload type behind a boxed `Row` variant field.
fn RowPayload(comptime boxed: type) type {
    return switch (@typeInfo(boxed)) {
        .pointer => |p| p.child,
        else => boxed,
    };
}

// Row types must declare pairwise distinct dispatch keys within each
// database type: `Row.decode` dispatches on first match, so a duplicate
// would silently parse one type's bytes as another.
comptime {
    const fields = std.meta.fields(Row);
    for (fields, 0..) |a, i| {
        const a_type = RowPayload(a.type);
        for (fields[i + 1 ..]) |b| {
            const b_type = RowPayload(b.type);
            const clash =
                if (@hasDecl(a_type, "page_type") and @hasDecl(b_type, "page_type"))
                    a_type.page_type == b_type.page_type
                else if (@hasDecl(a_type, "ext_page_type") and @hasDecl(b_type, "ext_page_type"))
                    @intFromEnum(a_type.ext_page_type) == @intFromEnum(b_type.ext_page_type)
                else
                    false;
            if (clash)
                @compileError(
                    "row types " ++ @typeName(a_type) ++ " and " ++
                        @typeName(b_type) ++ " declare the same page type",
                );
        }
    }
}

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

pub const row_group_size: usize = row_group_max_rows * 2 + 4;

/// Bytes a row group's presence flags and unknown field occupy, charged to
/// the page's free space when a new group is allocated.
const row_group_header_size: u16 = 4;

/// Bytes one row-group offset slot occupies, charged per allocated row.
const row_group_offset_size: u16 = 2;

/// Byte alignment every row allocation is rounded up to.
const row_alignment: usize = 4;

/// A group of row offsets, built backwards from the end of the page heap
/// as pages fill. Holds up to sixteen offsets plus a presence bitmask:
/// bit `i` says whether the offset in slot `15 - i` holds a live row, so
/// rows occupy slots from the end of the array (bit 0 = slot 15) and
/// offsets descend through the array in allocation order.
///
/// Slots before the first present one are not row offsets — the page heap
/// may store row data in their bytes. Parsing and writing keep them
/// verbatim.
pub const RowGroup = struct {
    /// Row offsets relative to the start of the page heap, in slot order.
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

    pub fn decode(c: *bin.Cursor) bin.ReadError!RowGroup {
        var group: RowGroup = undefined;
        for (&group.row_offsets) |*offset|
            offset.* = try c.takeInt(u16, .little);
        group.row_presence_flags = try c.takeInt(u16, .little);
        group.unknown = try c.takeInt(u16, .little);
        return group;
    }

    pub fn encode(group: RowGroup, e: *bin.Emitter) bin.WriteError!void {
        for (group.row_offsets) |offset| try e.putInt(u16, offset, .little);
        try e.putInt(u16, group.row_presence_flags, .little);
        try e.putInt(u16, group.unknown, .little);
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
    /// Capacity of the `row_groups` allocation; see `appendElem`.
    row_groups_cap: usize = 0,
    /// Rows in allocation order: row-group order, presence bits ascending.
    rows: []RowAtOffset = &.{},
    /// Capacity of the `rows` allocation; see `appendElem`.
    rows_cap: usize = 0,

    /// Reads the data page header, the row groups backwards from the end
    /// of the heap (as many as `page_header.packed_row_counts.num_rows`
    /// implies), and every present row at its heap offset. `c` is
    /// positioned at the data page header; `page_size` bounds the heap;
    /// `db_type` selects the row dispatch for `page_header.page_type`.
    /// The parsed row count must equal `num_rows_valid`.
    pub fn decode(
        c: *bin.Cursor,
        alloc: std.mem.Allocator,
        page_size: usize,
        page_header: PageHeader,
        db_type: DatabaseType,
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
            group.* = try RowGroup.decode(&sub);
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
                // Bounded at the heap end, not the buffer end: a corrupt
                // offset must not read past this page.
                if (pos > heap_end) return error.UnexpectedEof;
                var sub = bin.Cursor{ .buf = c.buf[pos..heap_end], .alloc = alloc };
                try rows.append(alloc, .{
                    .offset = offset,
                    .row = try Row.decode(&sub, page_header.page_type, db_type),
                });
            }
        }
        if (rows.items.len != page_header.packed_row_counts.num_rows_valid)
            return error.UnexpectedValue;

        const owned_rows = try rows.toOwnedSlice(alloc);
        return .{
            .header = header,
            .row_groups = groups,
            .row_groups_cap = groups.len,
            .rows = owned_rows,
            .rows_cap = owned_rows.len,
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

        // Rows may reach into the row groups' unused leading slots —
        // which can legally carry row data (see `RowGroup`) — but not
        // past the lowest group's first used slot byte, `2 * @clz`
        // bytes into its block. Without row groups, any heap byte is
        // available.
        var rows_limit = heap_end;
        if (self.row_groups.len > 0) {
            const lowest = self.row_groups[self.row_groups.len - 1];
            const lowest_start = heap_end - row_group_size * self.row_groups.len;
            rows_limit = lowest_start + 2 * @as(usize, @clz(lowest.row_presence_flags));
        }

        // Each row's true extent is measured off its encoded bytes — gaps
        // between offset-array items included — because `putBytesAt` would
        // let overlapping rows overwrite each other without an error.
        var extents = std.ArrayList(RowExtent).empty;
        defer extents.deinit(e.alloc);
        var sub = bin.Emitter.init(e.alloc);
        defer sub.deinit();
        for (self.rows) |*at| {
            sub.clear();
            try at.row.encode(&sub);
            const start = heap_start + at.offset;
            try e.putBytesAt(start, sub.written());
            try extents.append(
                e.alloc,
                .{ .start = start, .end = start + sub.written().len },
            );
        }
        std.mem.sort(RowExtent, extents.items, {}, rowExtentBefore);
        // Sorted by start and disjoint, the running end is the maximum.
        var prev_end = heap_start;
        for (extents.items) |extent| {
            if (extent.start < prev_end) return error.UnexpectedValue; // rows overlap
            prev_end = extent.end;
        }
        if (prev_end > rows_limit)
            return error.UnexpectedValue; // a row reaches into the row groups

        for (self.row_groups, 0..) |group, g| {
            const group_end = heap_end - row_group_size * g;
            sub.clear();
            try group.encode(&sub);
            try e.putBytesAt(group_end - row_group_size, sub.written());
        }
        if (e.pos() < heap_end) try e.pad(heap_end - e.pos());
        if (e.pos() != heap_end) return error.UnexpectedValue; // overran the heap
    }

    pub fn eql(a: *const DataPageContent, b: *const DataPageContent) bool {
        if (!std.meta.eql(a.header, b.header)) return false;
        if (a.row_groups.len != b.row_groups.len) return false;
        for (a.row_groups, b.row_groups) |*ag, *bg| {
            if (!ag.eql(bg)) return false;
        }
        if (a.rows.len != b.rows.len) return false;
        for (a.rows, b.rows) |*ar, *br| {
            if (ar.offset != br.offset or !ar.row.eql(&br.row)) return false;
        }
        return true;
    }

    pub fn deinit(content: *DataPageContent, alloc: std.mem.Allocator) void {
        for (content.rows) |*at| at.row.deinit(alloc);
        // The allocations may be larger than the slices (geometric growth).
        alloc.free(content.rows.ptr[0..@max(content.rows.len, content.rows_cap)]);
        content.rows = &.{};
        content.rows_cap = 0;
        alloc.free(content.row_groups.ptr[0..@max(content.row_groups.len, content.row_groups_cap)]);
        content.row_groups = &.{};
        content.row_groups_cap = 0;
    }
};

/// Bytes of the page heap: the page behind its 0x20-byte page header and
/// the 8-byte data page header.
fn dataPageHeapSize(page_size: usize) error{UnexpectedValue}!usize {
    const fixed = bin.serializedLen(PageHeader) + bin.serializedLen(DataPageHeader);
    if (page_size < fixed) return error.UnexpectedValue;
    return page_size - fixed;
}

/// Byte range a serialized row occupies in the page heap, for
/// `DataPageContent.encode`'s overlap check.
const RowExtent = struct {
    start: usize,
    end: usize,
};

/// Orders row extents by start offset for the overlap check.
fn rowExtentBefore(_: void, a: RowExtent, b: RowExtent) bool {
    return a.start < b.start;
}

/// One table of the database: a chain of pages holding rows of one page
/// type, plus the page indexes the writer uses to allocate and relink.
pub const Table = struct {
    /// Identifies the type of rows that this table contains; the meaning
    /// of the stored value depends on the database type (see
    /// `DatabaseType`).
    page_type: PageType = .tracks,
    /// Unknown field, maybe links to a chain of empty pages if the database
    /// is ever garbage collected (?). Often points past the end of the
    /// file.
    empty_candidate: u32 = 0,
    /// Index of the first page that belongs to this table; the first page
    /// is an index page and contains no rows, so the row data of a
    /// non-empty table lives in the pages after.
    first_page: u32 = 0,
    /// Index of the last page that belongs to this table.
    last_page: u32 = 0,
};

const header_fixed_len = 7 * @sizeOf(u32);

/// Bytes the header's fixed fields plus `count` table entries occupy.
fn headerFixedAndTablesLen(count: u64) u64 {
    return header_fixed_len + count * bin.serializedLen(Table);
}

/// Decoding error of the file header: `UnexpectedValue` is a wrong magic,
/// a page size too small for the header and its tables, or a file shorter
/// than one page.
pub const HeaderDecodeError = bin.ReadError || error{UnexpectedValue};

/// Encoding error of the file header: `UnexpectedValue` is a table count
/// that does not fit the page, or a page size below `header_fixed_len`.
pub const HeaderEncodeError = bin.WriteError || error{UnexpectedValue};

/// The shared search behind `Header.findTable` and `Header.findTableMut`.
fn findTableIn(tables: []Table, page_type: PageType) ?*Table {
    for (tables) |*table| {
        if (table.page_type == page_type) return table;
    }
    return null;
}

/// The file header, occupying the start of page 0: the page geometry, the
/// allocation counter, and the table of contents. Serializing pads page 0
/// with zeros up to the page size, as observed in every known file.
pub const Header = struct {
    /// Magic signature; always zero.
    magic: u32 = 0,
    /// Size of a single page in bytes. The byte offset of a page is its
    /// (1-based) index multiplied by this value; page 0 is this header.
    page_size: u32 = 4096,
    /// Number of tables; re-derived from `tables` when the header is
    /// written.
    num_tables: u32 = 0,
    /// Index of the next page a writer may allocate. Not used as any
    /// table's `empty_candidate`; sometimes points past the end of the
    /// file.
    next_unused_page: u32 = 0,
    /// Unknown field; observed as 5 in real exports, and set to 5 by
    /// rekordcrate's `create`.
    unknown: u32 = 5,
    /// Unknown field; always incremented by at least one, sometimes by two
    /// or three.
    sequence: u32 = 1,
    /// Gap between the fixed fields and the tables; always zero.
    gap: u32 = 0,
    /// The table of contents, `num_tables` entries on the wire. The slice
    /// is skipped by the struct walker; `decode` and `encode` own it.
    tables: []Table = &.{},

    pub const constant_fields = .{ .magic, .gap };

    /// Reads the fixed fields (validating the magics and that the tables
    /// fit within page 0), then the `num_tables` table entries. The
    /// returned `tables` slice is allocated with `alloc`.
    pub fn decode(c: *bin.Cursor, alloc: std.mem.Allocator) HeaderDecodeError!Header {
        var header = try bin.takeStruct(c, Header, .little);
        try bin.validateConstantFields(Header, header);
        if (headerFixedAndTablesLen(header.num_tables) > header.page_size)
            return error.UnexpectedValue;
        header.tables = try bin.takeStructSlice(
            alloc,
            c,
            Table,
            .little,
            header.num_tables,
        );
        return header;
    }

    /// Writes the fixed fields with `num_tables` derived from `tables`,
    /// the table entries, and zero padding up to `page_size` — exactly one
    /// page, the whole of page 0.
    pub fn encode(header: *const Header, e: *bin.Emitter) HeaderEncodeError!void {
        if (header.tables.len > std.math.maxInt(u32) or
            headerFixedAndTablesLen(header.tables.len) > header.page_size)
            return error.UnexpectedValue;
        var fixed = header.*;
        fixed.num_tables = @intCast(header.tables.len);
        try bin.putStruct(e, fixed, .little);
        for (header.tables) |table| try bin.putStruct(e, table, .little);
        const pad_len: usize = @intCast(
            header.page_size - headerFixedAndTablesLen(header.tables.len),
        );
        try e.pad(pad_len);
    }

    /// Finds the first table whose page type equals `page_type`, or null.
    /// Ext callers pass the raw colliding value, e.g.
    /// `@enumFromInt(@intFromEnum(ExtPageType.tag))`.
    pub fn findTable(header: *const Header, page_type: PageType) ?*const Table {
        return findTableIn(header.tables, page_type);
    }

    /// The mutable counterpart of `findTable`.
    pub fn findTableMut(header: *Header, page_type: PageType) ?*Table {
        return findTableIn(header.tables, page_type);
    }
};

/// Decoding error of a page: row errors from the data content plus
/// `UnexpectedValue` from the index content.
pub const PageDecodeError = RowDecodeError;

/// Encoding error of a page: the data and index content errors
/// (`UnexpectedValue` covers a page too small for its content).
pub const PageEncodeError = bin.WriteError || error{UnexpectedValue};

/// The content of a page, selected by the page header's `is_index_page`
/// flag bit.
pub const PageContent = union(enum) {
    data: DataPageContent,
    index: IndexPageContent,

    /// Reads the content selected by `page_header.page_flags` from `c`,
    /// positioned after the page header; `page_size` bounds the heap of a
    /// data page and `db_type` selects its row dispatch.
    pub fn decode(
        c: *bin.Cursor,
        alloc: std.mem.Allocator,
        page_size: usize,
        page_header: PageHeader,
        db_type: DatabaseType,
    ) PageDecodeError!PageContent {
        if (page_header.page_flags.is_index_page)
            return .{ .index = try IndexPageContent.decode(c, alloc) };
        return .{
            .data = try DataPageContent.decode(
                c,
                alloc,
                page_size,
                page_header,
                db_type,
            ),
        };
    }

    /// Writes the content; together with the page header this fills
    /// exactly one page.
    pub fn encode(
        content: *const PageContent,
        e: *bin.Emitter,
        page_size: usize,
    ) PageEncodeError!void {
        switch (content.*) {
            .data => |*data| try data.encode(e, page_size),
            .index => |*index| try index.encode(e, page_size),
        }
    }

    pub fn eql(a: *const PageContent, b: *const PageContent) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .data => |*data| data.eql(&b.data),
            .index => |*index| index.eql(&b.index),
        };
    }

    pub fn deinit(content: *PageContent, alloc: std.mem.Allocator) void {
        switch (content.*) {
            .data => |*data| data.deinit(alloc),
            .index => |*index| index.deinit(alloc),
        }
    }
};

/// Ticket from `Page.allocRow` for `Page.commitRow`: where a row will sit
/// once committed.
pub const RowAlloc = struct {
    /// Heap offset assigned to the row; also its identity in the page's
    /// `rows`.
    row_offset: u16,
    /// Index of the row group holding the row, and the row's presence bit
    /// within that group.
    row_group_index: usize,
    row_subindex: u4,
};

/// Appends `item` to `slice`, growing its allocation geometrically through
/// `cap`, the allocation's element capacity: an exact-length reallocation
/// per element is O(n^2) in time and — because the modification layer's
/// arenas abandon the outgrown buffer — in peak memory too. An empty slice
/// owns no memory to grow from.
fn appendElem(
    comptime T: type,
    alloc: std.mem.Allocator,
    slice: *[]T,
    cap: *usize,
    item: T,
) error{OutOfMemory}!void {
    // A capacity at or below the length means none is tracked — an empty
    // slice, or one built externally (decode tracks an exact capacity):
    // grow by doubling from the length either way.
    if (cap.* <= slice.*.len) {
        const new_cap = @max(slice.*.len *| 2, 4);
        const grown = try alloc.alloc(T, new_cap);
        @memcpy(grown[0..slice.*.len], slice.*);
        // Frees an exact-length buffer of ours; a foreign slice (cap
        // below length) is left to its owner — the database's arena
        // reclaims it regardless.
        if (cap.* > 0) alloc.free(slice.ptr[0..cap.*]);
        cap.* = new_cap;
        slice.* = grown[0..slice.*.len];
    }
    slice.*.len += 1;
    slice.*[slice.*.len - 1] = item;
}

/// A table page: the 0x20-byte page header plus the content selected by
/// its flags. A serialized page is exactly the database's page size long.
pub const Page = struct {
    /// The page header.
    header: PageHeader = .{},
    /// The content of the page.
    content: PageContent = .{ .data = .{} },

    /// Reads the page header (validating its constants) and the content
    /// its flags select; `c` is positioned at the page start.
    pub fn decode(
        c: *bin.Cursor,
        alloc: std.mem.Allocator,
        page_size: usize,
        db_type: DatabaseType,
    ) PageDecodeError!Page {
        const header = try bin.takeStruct(c, PageHeader, .little);
        try bin.validateConstantFields(PageHeader, header);
        return .{
            .header = header,
            .content = try PageContent.decode(c, alloc, page_size, header, db_type),
        };
    }

    /// Writes the header and content — exactly `page_size` bytes.
    pub fn encode(page: *const Page, e: *bin.Emitter, page_size: usize) PageEncodeError!void {
        try bin.putStruct(e, page.header, .little);
        try page.content.encode(e, page_size);
    }

    pub fn eql(a: *const Page, b: *const Page) bool {
        if (!std.meta.eql(a.header, b.header)) return false;
        return a.content.eql(&b.content);
    }

    pub fn deinit(page: *Page, alloc: std.mem.Allocator) void {
        page.content.deinit(alloc);
    }

    /// Creates a new empty data page: default (data-page) flags, the whole
    /// heap free, nothing used.
    pub fn newData(
        page_size: u32,
        page_index: u32,
        page_type: PageType,
        next_page: u32,
    ) error{UnexpectedValue}!Page {
        const heap = try dataPageHeapSize(page_size);
        const free_size = std.math.cast(u16, heap) orelse
            return error.UnexpectedValue; // page too large for the header fields
        return .{
            .header = .{
                .page_index = page_index,
                .page_type = page_type,
                .next_page = next_page,
                .free_size = free_size,
            },
            .content = .{ .data = .{} },
        };
    }

    /// Creates a new empty index page.
    pub fn newIndex(
        page_index: u32,
        page_type: PageType,
        next_page: u32,
    ) Page {
        return .{
            .header = .{
                .page_index = page_index,
                .page_type = page_type,
                .next_page = next_page,
                .page_flags = .{ .is_index_page = true },
            },
            .content = .{ .index = .{
                .header = .{ .page_index = page_index, .next_page = next_page },
            } },
        };
    }

    /// Allocates `bytes` of page heap for a new row — rounded up to
    /// `row_alignment` — reserving a row-group offset slot and charging
    /// the page's free/used accounting, and returns the ticket for
    /// `commitRow`. Returns null when the page is an index page or has
    /// insufficient free space, leaving the page unchanged.
    ///
    /// The allocate/commit pair replaces rekordcrate's insert closure, so
    /// a row only moves once its space is known. Allocation without a
    /// following `commitRow` is a legal state — the offset slot and
    /// `num_rows` already account for the row while the presence bit and
    /// `num_rows_valid` do not, exactly a deleted row's footprint — and a
    /// later `allocRow` may follow an uncommitted one.
    pub fn allocRow(
        page: *Page,
        alloc: std.mem.Allocator,
        bytes: u32,
    ) error{OutOfMemory}!?RowAlloc {
        const dpc = switch (page.content) {
            .data => |*data| data,
            .index => return null,
        };
        const counts = &page.header.packed_row_counts;
        if (counts.num_rows == std.math.maxInt(u13)) return null;

        // Assume the upper bound of required space: a new group's header
        // plus one offset slot, even when the current group has room.
        const aligned = std.mem.alignForward(usize, bytes, row_alignment);
        const required = aligned + row_group_header_size + row_group_offset_size;
        if (page.header.free_size < required) return null;

        // Checked arithmetic: a page whose free/used accounting exceeds
        // the `u16` fields is treated as full, not wrapped.
        const used: usize = @as(usize, page.header.used_size) + aligned;
        var free: usize = @as(usize, page.header.free_size) - aligned;
        if (used > std.math.maxInt(u16)) return null;
        const offset: u16 = page.header.used_size;

        counts.num_rows += 1;
        const num_rows: usize = counts.num_rows;
        const row_group_index = (num_rows - 1) / row_group_max_rows;
        const row_subindex: u4 = @intCast((num_rows - 1) % row_group_max_rows);

        if (row_group_index == dpc.row_groups.len) {
            try appendElem(
                RowGroup,
                alloc,
                &dpc.row_groups,
                &dpc.row_groups_cap,
                .{},
            );
            free -= row_group_header_size;
        }
        dpc.row_groups[row_group_index].row_offsets[row_group_max_rows - 1 - row_subindex] = offset;
        page.header.free_size = @intCast(free - row_group_offset_size);
        page.header.used_size = @intCast(used);

        return .{
            .row_offset = offset,
            .row_group_index = row_group_index,
            .row_subindex = row_subindex,
        };
    }

    /// Commits the row of a completed `allocRow` ticket: places `row` at
    /// the ticket's heap offset, marks the offset slot present, and counts
    /// the row valid. The ticket must be this page's most recent
    /// allocation and not yet committed. On error the page keeps the
    /// interrupted state; on success the page owns `row`, which must share
    /// the page's allocator (the database's arena).
    pub fn commitRow(
        page: *Page,
        alloc: std.mem.Allocator,
        ticket: RowAlloc,
        row: Row,
    ) error{ OutOfMemory, UnexpectedValue }!void {
        const dpc = switch (page.content) {
            .data => |*data| data,
            .index => return error.UnexpectedValue,
        };
        if (page.header.packed_row_counts.num_rows_valid ==
            std.math.maxInt(u11)) return error.UnexpectedValue;
        if (ticket.row_group_index >= dpc.row_groups.len)
            return error.UnexpectedValue;
        const group = &dpc.row_groups[ticket.row_group_index];
        const slot = row_group_max_rows - 1 - @as(usize, ticket.row_subindex);
        if (group.row_offsets[slot] != ticket.row_offset)
            return error.UnexpectedValue; // stale ticket
        const presence: u16 = @as(u16, 1) << ticket.row_subindex;
        if (group.row_presence_flags & presence != 0)
            return error.UnexpectedValue; // already committed
        // Rows are stored in allocation order, which is ascending offset
        // order; the appended row must not overtake an existing one.
        if (dpc.rows.len > 0 and dpc.rows[dpc.rows.len - 1].offset >= ticket.row_offset)
            return error.UnexpectedValue;

        // Pre-size the rows slice on a page's first commit: the first
        // row's charge bounds how many rows of at least its size the page
        // heap can hold, so a table of uniform rows allocates the slice
        // once instead of doubling through abandoned arena buffers.
        // Smaller rows may still exceed the bound; appendElem then grows.
        if (dpc.rows_cap == 0 and dpc.rows.len == 0) {
            const charge: usize = allocatedRowSize(row.heapBytesRequired()) +
                row_group_offset_size;
            const heap: usize = @as(usize, page.header.free_size) +
                page.header.used_size;
            const bound = heap / charge + 1;
            dpc.rows = (try alloc.alloc(RowAtOffset, bound))[0..0];
            dpc.rows_cap = bound;
        }

        try appendElem(
            RowAtOffset,
            alloc,
            &dpc.rows,
            &dpc.rows_cap,
            .{ .offset = ticket.row_offset, .row = row },
        );
        group.row_presence_flags |= presence;
        page.header.packed_row_counts.num_rows_valid += 1;
    }
};

/// One page slot of a database: the parsed page, or the whole page's
/// bytes kept verbatim because the page failed to parse — an unknown page
/// type with rows, or structural damage. Raw pages are written back
/// byte-for-byte, the bytes the format does not model.
pub const PageSlot = union(enum) {
    /// The parsed page.
    page: Page,
    /// The page's raw bytes, owned by the database's arena.
    raw: []const u8,

    pub fn eql(a: *const PageSlot, b: *const PageSlot) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .page => |*page| page.eql(&b.page),
            .raw => |bytes| std.mem.eql(u8, bytes, b.raw),
        };
    }
};

/// The parsed page at 1-based `page_index`, or null when the index falls
/// outside `slots` or the slot holds raw bytes.
fn parsedPageAt(slots: []PageSlot, page_index: u32) ?*Page {
    if (page_index < 1 or page_index > slots.len) return null;
    return switch (slots[page_index - 1]) {
        .page => |*page| page,
        .raw => null,
    };
}

/// Decoding error of a whole database.
pub const DatabaseDecodeError = bin.ReadError || error{UnexpectedValue};

/// Encoding error of a whole database: the header, page, and content
/// errors (whose `UnexpectedValue` covers content that does not fit its
/// page).
pub const DatabaseEncodeError = bin.WriteError || error{UnexpectedValue};

/// A whole `export.pdb`/`exportExt.pdb` image, parsed into an arena: the
/// file header and every page after page 0. This is the deliberate
/// whole-file-rewrite divergence from rekordcrate's lazy in-place page
/// editor — see `docs/DIVERGENCES.md`; byte-identical roundtrips carry the
/// safety argument and the perf budget the tripwire.
pub const Database = struct {
    /// Arena owning every value parsed into this instance. Rows and their
    /// strings parse directly into it; `serialize` never allocates from
    /// it.
    arena: *std.heap.ArenaAllocator,
    /// The type of database being parsed, which selects the meaning of
    /// the page-type values in tables and page headers.
    db_type: DatabaseType,
    /// The file header (page 0).
    header: Header,
    /// Pages after page 0; `pages[i]` holds page index `i + 1`.
    pages: []PageSlot,
    /// Capacity of the `pages` allocation; the slice's length is the page
    /// count.
    pages_cap: usize = 0,
    /// Bytes after the last whole page, kept verbatim. Known files are
    /// whole multiples of the page size, so this is normally empty.
    tail: []const u8 = &.{},

    /// Parses a whole database image of the given type. All pages are
    /// parsed eagerly; a page that fails to parse — anything but
    /// `error.OutOfMemory` — is kept as raw bytes and written back
    /// verbatim instead of failing the database, mirroring the pages the
    /// format does not model.
    pub fn parse(
        alloc: std.mem.Allocator,
        buf: []const u8,
        db_type: DatabaseType,
    ) DatabaseDecodeError!Database {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var c = bin.Cursor.initAlloc(a, buf);
        const header = try Header.decode(&c, a);
        const page_size: usize = header.page_size;
        if (buf.len < page_size) return error.UnexpectedValue;

        const num_pages = (buf.len - page_size) / page_size;
        const pages = try a.alloc(PageSlot, num_pages);
        for (pages, 0..) |*slot, i| {
            const page_buf = buf[(i + 1) * page_size ..][0..page_size];
            slot.* = parsePage(page_buf, page_size, db_type, a) catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => .{ .raw = try a.dupe(u8, page_buf) },
                };
        }
        const tail_len = buf.len - page_size - num_pages * page_size;
        return .{
            .arena = arena,
            .db_type = db_type,
            .header = header,
            .pages = pages,
            .pages_cap = pages.len,
            .tail = if (tail_len == 0) &.{} else try a.dupe(
                u8,
                buf[buf.len - tail_len ..],
            ),
        };
    }

    /// Frees the instance and every value parsed into it.
    pub fn deinit(db: *Database) void {
        const child = db.arena.child_allocator;
        db.arena.deinit();
        child.destroy(db.arena);
    }

    /// Serializes the whole image — header page, every page slot, tail —
    /// into a freshly allocated buffer the caller owns. The output length
    /// equals the parsed input length: pages never grow or shrink, and
    /// unparseable pages keep their bytes.
    pub fn serialize(db: *const Database, alloc: std.mem.Allocator) DatabaseEncodeError![]u8 {
        var e = bin.Emitter.init(alloc);
        errdefer e.deinit();
        // The image size is known exactly; reserving it up front spares the
        // emitter's doubling reallocations and their full-image copies.
        const total: u64 = @as(u64, db.header.page_size) * (db.pages.len + 1) +
            db.tail.len;
        try e.ensureTotalCapacity(std.math.cast(usize, total) orelse
            return error.OutOfMemory);
        try db.header.encode(&e);
        const page_size: usize = db.header.page_size;
        for (db.pages) |*slot| switch (slot.*) {
            .page => |*page| try page.encode(&e, page_size),
            .raw => |bytes| try e.putBytes(bytes),
        };
        try e.putBytes(db.tail);
        return e.toOwnedSlice();
    }

    pub fn eql(a: *const Database, b: *const Database) bool {
        if (a.db_type != b.db_type) return false;
        // `num_tables` and `magic`/`gap` are derived or validated constants.
        if (a.header.page_size != b.header.page_size or
            a.header.next_unused_page != b.header.next_unused_page or
            a.header.unknown != b.header.unknown or
            a.header.sequence != b.header.sequence) return false;
        if (a.header.tables.len != b.header.tables.len) return false;
        for (a.header.tables, b.header.tables) |*at, *bt| {
            if (!std.meta.eql(at.*, bt.*)) return false;
        }
        if (a.pages.len != b.pages.len) return false;
        for (a.pages, b.pages) |*ap, *bp| {
            if (!ap.eql(bp)) return false;
        }
        return std.mem.eql(u8, a.tail, b.tail);
    }

    /// Iterates the rows of the table holding `page_type`, in page order
    /// (see `RowIterator`).
    pub fn rows(db: *const Database, page_type: PageType) RowIterError!RowIterator {
        const table = db.header.findTable(page_type) orelse return error.NoTable;
        var it = RowIterator{
            .db = db,
            .last_page = table.last_page,
            .current = table.first_page,
            .next_page = page_chain_end,
        };
        try it.loadPage();
        return it;
    }

    /// Appends `row` to the table holding its page type, allocating a new
    /// page when no existing one fits. On success the database owns the
    /// row and its boxed payload — allocate the payload with the
    /// database's arena (`db.arena.allocator()`) and build its strings
    /// with it too, and neither reuse nor free `row` after the call; on
    /// error, ownership is unchanged.
    ///
    /// The insert tries the table's tail page first, then its
    /// `empty_candidate` (when that is a parsed data page of the right
    /// type, unlike the tail), and only then allocates a fresh page,
    /// relinking the chain onto it.
    pub fn addRow(db: *Database, row: *Row) DatabaseModifyError!RowRef {
        switch (row.*) {
            .track => |track| try validateTrackRowSize(track),
            else => {},
        }

        const page_type = row.pageType();
        const row_size = row.heapBytesRequired();

        const table = db.header.findTableMut(page_type) orelse
            return error.TableTypeNotFound;
        const old_last_page = table.last_page;
        // A representable page index, checked before any insert like
        // rekordcrate's `PageIndex` conversion.
        if (table.empty_candidate >= page_chain_end)
            return error.UnexpectedValue;
        const empty_candidate = table.empty_candidate;

        // The chain tail must be a page that exists and parsed, like the
        // oracle's eager load; an index-page tail (an empty created table)
        // simply fails the insert below.
        if (parsedPageAt(db.pages, old_last_page) == null)
            return error.UnexpectedValue;

        if (try db.tryInsertRow(old_last_page, row_size, row)) |row_ref|
            return row_ref;

        if (empty_candidate != old_last_page and
            empty_candidate >= 1 and empty_candidate <= db.pages.len)
        {
            const usable = switch (db.pages[empty_candidate - 1]) {
                .page => |*page| page.header.page_type == page_type and
                    page.content == .data,
                .raw => false,
            };
            if (usable) {
                if (try db.tryInsertRow(empty_candidate, row_size, row)) |row_ref| {
                    try db.relinkChainEnd(old_last_page, empty_candidate);
                    table.last_page = empty_candidate;
                    return row_ref;
                }
            }
        }

        const new_page_index = try db.allocDataPage(page_type);
        try db.relinkChainEnd(old_last_page, new_page_index);
        table.last_page = new_page_index;

        return try db.tryInsertRow(new_page_index, row_size, row) orelse
            error.UnexpectedValue; // a freshly allocated page has no room
    }

    /// Tries to append a row to page `page_index`'s heap. Returns null —
    /// leaving the database unchanged — when the page is absent, unparsed,
    /// an index page, or full; `row` is only moved on success.
    fn tryInsertRow(
        db: *Database,
        page_index: u32,
        row_size: u32,
        row: *Row,
    ) DatabaseModifyError!?RowRef {
        const page = parsedPageAt(db.pages, page_index) orelse return null;
        const ticket = (try page.allocRow(db.arena.allocator(), row_size)) orelse
            return null;
        try page.commitRow(db.arena.allocator(), ticket, row.*);
        return .{ .page_index = page_index, .row_offset = ticket.row_offset };
    }

    /// Points page `previous_page_index`'s `next_page` at
    /// `current_page_index`.
    fn relinkChainEnd(
        db: *Database,
        previous_page_index: u32,
        current_page_index: u32,
    ) error{UnexpectedValue}!void {
        const page = parsedPageAt(db.pages, previous_page_index) orelse
            return error.UnexpectedValue;
        page.header.next_page = current_page_index;
        switch (page.content) {
            .index => |*index| index.header.next_page = current_page_index,
            .data => {},
        }
    }

    /// Allocates a fresh empty data page and returns its index, bumping
    /// `next_unused_page`. Page indexes the file lacked — the counter can
    /// exceed the pages present — become zero-filled gap pages, written as
    /// zeros exactly like rekordcrate's seek over unloaded pages.
    pub fn allocDataPage(db: *Database, page_type: PageType) DatabaseModifyError!u32 {
        // Pages are appended at the end of the image; a trailing partial
        // page would be displaced by the new page's bytes.
        if (db.tail.len != 0) return error.UnexpectedValue;
        const page_index = db.header.next_unused_page;
        if (page_index >= page_chain_end) return error.UnexpectedValue;
        if (db.pages.len >= page_index)
            return error.UnexpectedValue; // counter names an existing page

        const a = db.arena.allocator();
        // Grow to hold every page index up to and including `page_index`,
        // at least doubling the capacity (see `appendElem`).
        if (db.pages_cap < page_index) {
            const new_cap = @max(@max(db.pages_cap *| 2, 4), page_index);
            const grown = try a.alloc(PageSlot, new_cap);
            @memcpy(grown[0..db.pages.len], db.pages);
            // The old allocation is abandoned in the arena.
            db.pages = grown[0..db.pages.len];
            db.pages_cap = new_cap;
        }
        const page_size: usize = db.header.page_size;
        for (db.pages.ptr[db.pages.len .. page_index - 1]) |*slot| {
            const zeros = try a.alloc(u8, page_size);
            @memset(zeros, 0);
            slot.* = .{ .raw = zeros };
        }
        db.pages = db.pages.ptr[0..page_index];
        db.pages[page_index - 1] = .{
            .page = try Page.newData(
                db.header.page_size,
                page_index,
                page_type,
                page_chain_end,
            ),
        };
        db.header.next_unused_page = page_index + 1;
        return page_index;
    }

    /// Creates a new empty database of `db_type` with one table per entry
    /// of `table_page_types` (see `standard_table_page_types` for the
    /// fixed 20-entry order a device export needs), each table initialized
    /// with an index page followed by an empty data page: `first_page` and
    /// `last_page` both point at the index page and `empty_candidate` at
    /// the data page, so the first `addRow` relinks the chain onto the
    /// data page. Everything the database owns lives in its arena.
    pub fn create(
        alloc: std.mem.Allocator,
        db_type: DatabaseType,
        table_page_types: []const PageType,
    ) DatabaseModifyError!Database {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        if (table_page_types.len > std.math.maxInt(u32) or
            headerFixedAndTablesLen(table_page_types.len) > default_page_size)
            return error.UnexpectedValue; // too many tables for page 0

        const pages = try a.alloc(PageSlot, table_page_types.len * 2);
        const tables = try a.alloc(Table, table_page_types.len);

        var next_page: u32 = 1;
        for (table_page_types, 0..) |page_type, i| {
            const index_page_index = next_page;
            const data_page_index = next_page + 1;
            next_page += 2;
            pages[2 * i] = .{
                .page = Page.newIndex(index_page_index, page_type, page_chain_end),
            };
            pages[2 * i + 1] = .{
                .page = try Page.newData(
                    default_page_size,
                    data_page_index,
                    page_type,
                    page_chain_end,
                ),
            };
            tables[i] = .{
                .page_type = page_type,
                .empty_candidate = data_page_index,
                .first_page = index_page_index,
                // Empty table: the logical chain tail is the index page.
                .last_page = index_page_index,
            };
        }

        return .{
            .arena = arena,
            .db_type = db_type,
            .header = .{
                .page_size = default_page_size,
                .num_tables = @intCast(table_page_types.len),
                .next_unused_page = next_page,
                .unknown = 5,
                .sequence = 1,
                .tables = tables,
            },
            .pages = pages,
            .pages_cap = pages.len,
        };
    }

    /// Validates every track row against `min_track_allocated_size` by
    /// walking the tracks table's page chain; ext databases have no
    /// tracks table and pass trivially. rekordcrate runs this on every
    /// flush; the device writer calls it before serializing, the
    /// whole-image model's equivalent moment.
    pub fn validateAllTrackRows(db: *const Database) ValidateAllTrackRowsError!void {
        if (db.db_type != .plain) return;
        const table = db.header.findTable(.tracks) orelse
            return error.TableTypeNotFound;
        var current = table.first_page;
        while (true) {
            const page = parsedPageAt(db.pages, current) orelse
                return error.UnexpectedValue;
            switch (page.content) {
                .data => |*content| for (content.rows) |*at| switch (at.row) {
                    .track => |track| try validateTrackRowSize(track),
                    else => {},
                },
                .index => {},
            }
            if (current == table.last_page) return;
            const next = page.header.next_page;
            if (next <= current) return error.UnexpectedValue;
            current = next;
        }
    }
};

/// Error of `Database.rows` and `RowIterator.next`: `NoTable` is a page
/// type no table in the header holds, `PageNotPresent` a chained page
/// index outside the file, `PageOrderViolation` a chain link that does not
/// advance (rekordcrate's `PageIterator` assumes pages in a table are
/// linked in increasing order by index), and `UnparsedPage` a chained page
/// kept raw because its rows are not wired for the database type.
pub const RowIterError = error{
    NoTable,
    PageNotPresent,
    PageOrderViolation,
    UnparsedPage,
};

/// Iterates the rows of one table's page chain in page order — the order
/// the writer appends them in; index pages carry no rows and are skipped.
/// Every hop validates that the chain advances and stays inside the file,
/// so a corrupted chain errors instead of looping. Rows are borrowed from
/// the database for the iterator's lifetime.
pub const RowIterator = struct {
    db: *const Database,
    /// 1-based index of the page whose rows are being yielded.
    current: u32,
    /// The chain's final page; walking stops after it.
    last_page: u32,
    /// Chain link of the current page, read when it was loaded.
    next_page: u32,
    /// Rows of the current data page and the yield position in it.
    rows: []const RowAtOffset = &.{},
    i: usize = 0,
    done: bool = false,

    /// Loads `current`, adopting its rows (an index page adopts none) and
    /// its chain link.
    fn loadPage(it: *RowIterator) RowIterError!void {
        if (it.current < 1 or it.current > it.db.pages.len)
            return error.PageNotPresent;
        const page = switch (it.db.pages[it.current - 1]) {
            .page => |*page| page,
            .raw => return error.UnparsedPage,
        };
        switch (page.content) {
            .data => |*content| it.rows = content.rows,
            .index => it.rows = &.{},
        }
        it.i = 0;
        it.next_page = page.header.next_page;
    }

    /// The table's next row, or null once the chain is exhausted.
    pub fn next(it: *RowIterator) RowIterError!?*const Row {
        while (!it.done) {
            if (it.i < it.rows.len) {
                const row = &it.rows[it.i].row;
                it.i += 1;
                return row;
            }
            if (it.current == it.last_page) {
                it.done = true;
                return null;
            }
            if (it.next_page <= it.current) return error.PageOrderViolation;
            it.current = it.next_page;
            try it.loadPage();
        }
        return null;
    }
};

/// Parses one page as a `PageSlot`, the eager per-page attempt of
/// `Database.parse`. A page whose rows are not wired for the database
/// type (unknown page types) fails with `error.NotImplemented`.
fn parsePage(
    page_buf: []const u8,
    page_size: usize,
    db_type: DatabaseType,
    alloc: std.mem.Allocator,
) PageDecodeError!PageSlot {
    var c = bin.Cursor.initAlloc(alloc, page_buf);
    return .{ .page = try Page.decode(&c, alloc, page_size, db_type) };
}

// Modification layer, ported from the `allocate_row`, `add_row`, and
// `create` logic of rekordcrate's `src/pdb/mod.rs` and `src/pdb/io.rs`
// plus its `src/pdb/defaults.rs`.

/// Sentinel closing a page chain: the value stored in `next_page` fields
/// of chain-final pages, and the exclusive upper bound of representable
/// page indexes.
pub const page_chain_end: u32 = 0x03FF_FFFF;

/// Error of `Database.validateAllTrackRows`.
pub const ValidateAllTrackRowsError = error{
    TableTypeNotFound,
    TrackRowTooSmall,
    TrackRowTooLarge,
    UnexpectedValue,
};

/// Page size of a created database.
const default_page_size: u32 = 4096;

/// Error of the modification layer: `TableTypeNotFound` is a row whose
/// page type no table in the header holds, `TrackRowTooSmall` a Track row
/// below `min_track_allocated_size`, `TrackRowTooLarge` a Track row whose
/// heap bytes exceed the `u16` page accounting, and `UnexpectedValue` a database
/// whose page chains or allocation counters are inconsistent with the
/// operation, or misuse of the allocate/commit pair.
pub const DatabaseModifyError = error{
    OutOfMemory,
    TableTypeNotFound,
    TrackRowTooSmall,
    TrackRowTooLarge,
    UnexpectedValue,
};

/// Locates an added row: the page holding it and the row's heap offset
/// within that page.
pub const RowRef = struct {
    page_index: u32,
    row_offset: u16,
};

/// Minimum value for the allocated (4-byte-aligned) size of a Track row,
/// in bytes: a CDJ-350 crashes entering its "TRACK" menu when any track
/// row is shorter than this; 221 was the smallest value found to avoid
/// the crash (by trial and error). Device-derived constant — copy
/// exactly; any "cleanup" here is a latent CDJ crash.
pub const min_track_allocated_size: u16 = 221;

/// A row's allocated size: its heap bytes rounded up to `row_alignment`.
pub fn allocatedRowSize(row_size: u32) u32 {
    return @intCast(std.mem.alignForward(u64, row_size, row_alignment));
}

/// Rejects Track rows whose allocated size is below
/// `min_track_allocated_size`; `addRow` enforces it, and the device
/// writer enforces it on whole databases before serializing (see
/// `Database.validateAllTrackRows`).
pub fn validateTrackRowSize(
    track: *const Track,
) error{ TrackRowTooSmall, TrackRowTooLarge }!void {
    const row_size = allocatedRowSize(rowHeapBytesRequired(Track, track));
    if (row_size > std.math.maxInt(u16))
        return error.TrackRowTooLarge;
    if (row_size < min_track_allocated_size)
        return error.TrackRowTooSmall;
}

/// Grows the row's `comment` with trailing spaces — semantically harmless
/// free text — until `validateTrackRowSize` passes, the padding
/// rekordcrate's high-level writer applies (only `comment` is re-encoded
/// per pass, like the oracle). Strings are created with `alloc`, which
/// must be the allocator the row's strings use; each replaced comment is
/// freed, so nothing leaks under a general allocator (an arena reclaims
/// everything at once).
pub fn padTrackCommentToMinimum(
    track: *Track,
    alloc: std.mem.Allocator,
) error{ TooLong, InvalidEncoding, OutOfMemory }!void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(alloc);
    const current = try track.offsets.inner.comment.utf8(alloc);
    defer alloc.free(current);
    try text.appendSlice(alloc, current);

    while (true) {
        const candidate = try DeviceSQLString.fromUtf8(alloc, text.items);
        var replaced = track.offsets.inner.comment;
        track.offsets.inner.comment = candidate;
        replaced.deinit(alloc);
        validateTrackRowSize(track) catch |err| switch (err) {
            // Padding can only grow the row, so a too-large row can never
            // pass; looping would just spin until the comment overflows.
            error.TrackRowTooLarge => return error.TooLong,
            error.TrackRowTooSmall => {
                try text.append(alloc, ' ');
                continue;
            },
        };
        return;
    }
}

/// The fixed 20-entry table order rekordbox writes into new `export.pdb`
/// files, for `Database.create`: table indexes 9, 10, 14, 15, and 18 hold
/// currently-unknown page types that must stay in place or CDJ players
/// crash.
pub const standard_table_page_types = [20]PageType{
    .tracks,          .genres,          .artists,
    .albums,          .labels,          .keys,
    .colors,          .playlist_tree,   .playlist_entries,
    @enumFromInt(9),  @enumFromInt(10), .history_playlists,
    .history_entries, .artwork,         @enumFromInt(14),
    @enumFromInt(15), .columns,         .menu,
    @enumFromInt(18), .history,
};

/// The default color rows rekordbox inserts into a new export: an id, the
/// color it names, and the color's display name.
const default_colors = [_]struct { id: u8, color: util.ColorIndex, name: []const u8 }{
    .{ .id = 1, .color = .pink, .name = "Pink" },
    .{ .id = 2, .color = .red, .name = "Red" },
    .{ .id = 3, .color = .orange, .name = "Orange" },
    .{ .id = 4, .color = .yellow, .name = "Yellow" },
    .{ .id = 5, .color = .green, .name = "Green" },
    .{ .id = 6, .color = .aqua, .name = "Aqua" },
    .{ .id = 7, .color = .blue, .name = "Blue" },
    .{ .id = 8, .color = .purple, .name = "Purple" },
};

/// The default metadata-category rows rekordbox inserts into a new
/// export: an id, an unknown constant, and the annotation-wrapped name.
const default_columns = [_]struct { id: u16, unknown0: u16, name: []const u8 }{
    .{ .id = 1, .unknown0 = 128, .name = "\u{FFFA}GENRE\u{FFFB}" },
    .{ .id = 2, .unknown0 = 129, .name = "\u{FFFA}ARTIST\u{FFFB}" },
    .{ .id = 3, .unknown0 = 130, .name = "\u{FFFA}ALBUM\u{FFFB}" },
    .{ .id = 4, .unknown0 = 131, .name = "\u{FFFA}TRACK\u{FFFB}" },
    .{ .id = 5, .unknown0 = 133, .name = "\u{FFFA}BPM\u{FFFB}" },
    .{ .id = 6, .unknown0 = 134, .name = "\u{FFFA}RATING\u{FFFB}" },
    .{ .id = 7, .unknown0 = 135, .name = "\u{FFFA}YEAR\u{FFFB}" },
    .{ .id = 8, .unknown0 = 136, .name = "\u{FFFA}REMIXER\u{FFFB}" },
    .{ .id = 9, .unknown0 = 137, .name = "\u{FFFA}LABEL\u{FFFB}" },
    .{ .id = 10, .unknown0 = 138, .name = "\u{FFFA}ORIGINAL ARTIST\u{FFFB}" },
    .{ .id = 11, .unknown0 = 139, .name = "\u{FFFA}KEY\u{FFFB}" },
    .{ .id = 12, .unknown0 = 141, .name = "\u{FFFA}CUE\u{FFFB}" },
    .{ .id = 13, .unknown0 = 142, .name = "\u{FFFA}COLOR\u{FFFB}" },
    .{ .id = 14, .unknown0 = 146, .name = "\u{FFFA}TIME\u{FFFB}" },
    .{ .id = 15, .unknown0 = 147, .name = "\u{FFFA}BITRATE\u{FFFB}" },
    .{ .id = 16, .unknown0 = 148, .name = "\u{FFFA}FILE NAME\u{FFFB}" },
    .{ .id = 17, .unknown0 = 132, .name = "\u{FFFA}PLAYLIST\u{FFFB}" },
    .{ .id = 18, .unknown0 = 152, .name = "\u{FFFA}HOT CUE BANK\u{FFFB}" },
    .{ .id = 19, .unknown0 = 149, .name = "\u{FFFA}HISTORY\u{FFFB}" },
    .{ .id = 20, .unknown0 = 145, .name = "\u{FFFA}SEARCH\u{FFFB}" },
    .{ .id = 21, .unknown0 = 150, .name = "\u{FFFA}COMMENTS\u{FFFB}" },
    .{ .id = 22, .unknown0 = 140, .name = "\u{FFFA}DATE ADDED\u{FFFB}" },
    .{ .id = 23, .unknown0 = 151, .name = "\u{FFFA}DJ PLAY COUNT\u{FFFB}" },
    .{ .id = 24, .unknown0 = 144, .name = "\u{FFFA}FOLDER\u{FFFB}" },
    .{ .id = 25, .unknown0 = 161, .name = "\u{FFFA}DEFAULT\u{FFFB}" },
    .{ .id = 26, .unknown0 = 162, .name = "\u{FFFA}ALPHABET\u{FFFB}" },
    .{ .id = 27, .unknown0 = 170, .name = "\u{FFFA}MATCHING\u{FFFB}" },
};

/// The default menu rows rekordbox inserts into a new export, in row
/// order.
const default_menus = [_]struct {
    category_id: u16,
    content_pointer: u16,
    unknown: u8,
    visibility: MenuVisibility,
    sort_order: u16,
}{
    .{ .category_id = 1, .content_pointer = 1, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 5, .content_pointer = 6, .unknown = 5, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 6, .content_pointer = 7, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 7, .content_pointer = 8, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 8, .content_pointer = 9, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 9, .content_pointer = 10, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 10, .content_pointer = 11, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 13, .content_pointer = 15, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 14, .content_pointer = 19, .unknown = 4, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 15, .content_pointer = 20, .unknown = 6, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 16, .content_pointer = 21, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 18, .content_pointer = 23, .unknown = 99, .visibility = .hidden, .sort_order = 0 },
    .{ .category_id = 2, .content_pointer = 2, .unknown = 2, .visibility = .visible, .sort_order = 1 },
    .{ .category_id = 3, .content_pointer = 3, .unknown = 3, .visibility = .visible, .sort_order = 2 },
    .{ .category_id = 4, .content_pointer = 4, .unknown = 1, .visibility = .visible, .sort_order = 3 },
    .{ .category_id = 11, .content_pointer = 12, .unknown = 99, .visibility = .visible, .sort_order = 4 },
    .{ .category_id = 17, .content_pointer = 5, .unknown = 99, .visibility = .visible, .sort_order = 5 },
    .{ .category_id = 19, .content_pointer = 22, .unknown = 99, .visibility = .visible, .sort_order = 6 },
    .{ .category_id = 20, .content_pointer = 18, .unknown = 99, .visibility = .visible, .sort_order = 7 },
    .{ .category_id = 27, .content_pointer = 26, .unknown = 99, .visibility = @enumFromInt(2), .sort_order = 8 },
    .{ .category_id = 24, .content_pointer = 17, .unknown = 99, .visibility = .visible, .sort_order = 9 },
    .{ .category_id = 22, .content_pointer = 27, .unknown = 99, .visibility = .visible, .sort_order = 10 },
};

/// The `Row` variant holding a `*T` payload.
fn rowOf(comptime T: type, payload: *T) Row {
    const tag = comptime blk: {
        for (std.meta.fields(Row)) |field| {
            if (RowPayload(field.type) == T) break :blk field.name;
        }
        @compileError("rowOf: no Row variant holds " ++ @typeName(T));
    };
    return @unionInit(Row, tag, payload);
}

/// Builds one of the default-row strings; the comptime-verified literals
/// can be neither too long nor invalidly encoded, so only allocation can
/// fail.
fn defaultString(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}!DeviceSQLString {
    return DeviceSQLString.fromUtf8(a, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLong, error.InvalidEncoding => unreachable,
    };
}

/// Creates `payload` in the database's arena, boxes it into its `Row`
/// variant, and adds it as a row.
fn addDefaultRow(db: *Database, payload: anytype) DatabaseModifyError!void {
    const owned = try db.arena.allocator().create(@TypeOf(payload));
    owned.* = payload;
    var row = rowOf(@TypeOf(payload), owned);
    _ = try db.addRow(&row);
}

pub fn insertDefaultColors(db: *Database) DatabaseModifyError!void {
    const a = db.arena.allocator();
    for (default_colors) |entry| {
        try addDefaultRow(db, Color{
            .unknown2 = entry.id,
            .color = entry.color,
            .name = try defaultString(a, entry.name),
        });
    }
}

pub fn insertDefaultColumns(db: *Database) DatabaseModifyError!void {
    const a = db.arena.allocator();
    for (default_columns) |entry| {
        try addDefaultRow(db, ColumnEntry{
            .id = entry.id,
            .unknown0 = entry.unknown0,
            .column_name = try defaultString(a, entry.name),
        });
    }
}

pub fn insertDefaultMenus(db: *Database) DatabaseModifyError!void {
    for (default_menus) |entry| {
        try addDefaultRow(db, Menu{
            .category_id = entry.category_id,
            .content_pointer = entry.content_pointer,
            .unknown = entry.unknown,
            .visibility = entry.visibility,
            .sort_order = entry.sort_order,
        });
    }
}
