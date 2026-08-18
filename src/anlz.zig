// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for Rekordbox analysis files, which are found inside
//! nested subdirectories of the `PIONEER/USBANLZ` directory of a device
//! export and can have the extensions `.DAT`, `.EXT`, or `.2EX`. They are
//! also used for local Rekordbox databases. The files contain track data
//! that is not part of the PDB file, such as beatgrids, cue points,
//! waveforms, and song structure information.
//!
//! The file starts with a `PMAI` header followed by a sequence of sections,
//! each prefixed with a fourcc tag and size fields. With each hardware
//! generation new section types were added; to avoid issues with older
//! players, the newer sections are only written to copies of the file with
//! a different extension (`.EXT`, then `.2EX`).
//!
//! Initially ported from rekordcrate's `src/anlz.rs`
//!
//! - <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html>

const std = @import("std");
const bin = @import("bin");
const xor = @import("xor");

pub const ParseError = error{ UnexpectedEof, OutOfMemory, InvalidFormat, UnexpectedValue };

pub const WriteError = bin.WriteError || error{Overflow};

/// Narrows `n` to `T`, failing with `Overflow` instead of truncating.
fn narrow(comptime T: type, n: usize) WriteError!T {
    return std.math.cast(T, n) orelse error.Overflow;
}

/// Packs a four character code into a big-endian u32 tag.
fn fourcc(comptime tag: *const [4]u8) u32 {
    return (@as(u32, tag[0]) << 24) | (@as(u32, tag[1]) << 16) | (@as(u32, tag[2]) << 8) | tag[3];
}

/// The kind of a section, identified by its fourcc tag. Unknown tags are
/// kept and roundtrip verbatim through the `Unknown` content.
pub const Kind = enum(u32) {
    /// File header that contains all other sections.
    file = fourcc("PMAI"),
    /// All beats found in the track.
    beat_grid = fourcc("PQTZ"),
    /// Memory points/loops or hot cues/loops of the track. Since the Nexus 2
    /// series there also is the `extended_cue_list` section, which can carry
    /// additional information.
    cue_list = fourcc("PCOB"),
    /// Extended version of the cue list (since the Nexus 2 series).
    extended_cue_list = fourcc("PCO2"),
    /// Single cue entry inside an extended cue list.
    extended_cue = fourcc("PCP2"),
    /// Single cue entry inside a cue list.
    cue = fourcc("PCPT"),
    /// File path of the audio file.
    path = fourcc("PPTH"),
    /// Seek information for variable bitrate files.
    vbr = fourcc("PVBR"),
    /// Fixed-width monochrome preview of the track waveform.
    waveform_preview = fourcc("PWAV"),
    /// Smaller version of the waveform preview (for the CDJ-900).
    tiny_waveform_preview = fourcc("PWV2"),
    /// Variable-width large monochrome version of the track waveform, in
    /// `.EXT` files.
    waveform_detail = fourcc("PWV3"),
    /// Fixed-width colored preview of the track waveform, in `.EXT` files.
    waveform_color_preview = fourcc("PWV4"),
    /// Variable-width large colored version of the track waveform, in `.EXT`
    /// files.
    waveform_color_detail = fourcc("PWV5"),
    /// Fixed-width 3-band preview of the track waveform, in `.2EX` files.
    waveform_3band_preview = fourcc("PWV6"),
    /// Variable-width large 3-band version of the track waveform, in `.2EX`
    /// files.
    waveform_3band_detail = fourcc("PWV7"),
    /// Describes the structure of a song (Intro, Chorus, Verse, ...), in
    /// `.EXT` files.
    song_structure = fourcc("PSSI"),
    _,
};

/// Header of a section: type and size information. On parse the stored
/// values are validated (the canonical `size` per kind, `total_size` pinned
/// by exact consumption); on write they are derived from the content, so a
/// modified file re-serializes with consistent headers. The size accessors
/// may only be used after the header has been validated (`size >= 12`,
/// `total_size >= size`).
const Header = struct {
    /// Kind of content in this section.
    kind: Kind = .file,
    /// Length of the header, including `kind`, `size`, and `total_size`.
    size: u32 = 0,
    /// Length of the whole section, including the header.
    total_size: u32 = 0,

    /// Bytes between the fixed 12-byte header prefix and the start of the
    /// content: the length of the per-section header preamble.
    pub fn remaining_size(h: Header) u32 {
        return h.size - 12;
    }

    /// Bytes of payload that follow the header.
    pub fn content_size(h: Header) u32 {
        return h.total_size - h.size;
    }
};

/// A single beat inside the beat grid.
pub const Beat = struct {
    /// Beat number inside the bar (1-4).
    beat_number: u16 = 0,
    /// Current tempo in centi-BPM (= 1/100 BPM).
    tempo: u16 = 0,
    /// Time in milliseconds after which this beat would occur (at normal
    /// playback speed).
    time: u32 = 0,
};

/// All beats in the track.
pub const BeatGrid = struct {
    /// Unknown field, zero in all known files.
    unknown1: u32 = 0,
    /// Unknown field, `0x00800000` in all known files.
    unknown2: u32 = 0x0080_0000,
    /// Beats of this beatgrid. The `len_beats` count is recomputed from this
    /// slice on write.
    beats: []Beat = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!BeatGrid {
        if (header.size != 24) return error.UnexpectedValue;
        const unknown1 = try c.takeInt(u32, .big);
        const unknown2 = try c.takeInt(u32, .big);
        const len_beats = try c.takeInt(u32, .big);
        if (@as(u64, len_beats) * bin.serializedLen(Beat) != header.content_size()) return error.InvalidFormat;
        const beats = try alloc.alloc(Beat, len_beats);
        for (beats) |*beat| beat.* = try bin.takeStruct(c, Beat, .big);
        return .{ .unknown1 = unknown1, .unknown2 = unknown2, .beats = beats };
    }

    fn writeTo(bg: *const BeatGrid, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, bg.unknown1, .big);
        try e.putInt(u32, bg.unknown2, .big);
        try e.putInt(u32, try narrow(u32, bg.beats.len), .big);
        for (bg.beats) |*beat| try bin.putStruct(e, beat, .big);
    }
};

/// The types of entries found in a cue list section.
pub const CueListType = enum(u32) {
    /// Memory cues or loops.
    memory_cues = 0,
    /// Hot cues or loops.
    hot_cues = 1,
    _,
};

/// Indicates if a cue is a point or a loop.
pub const CueType = enum(u8) {
    /// Cue is a single point.
    point = 1,
    /// Cue is a loop.
    loop = 2,
    _,
};

/// Color assigned to a memory cue (see `ExtendedCue.color`).
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

/// A memory or hot cue (or loop), a single entry of a cue list. Preceded on
/// the wire by a nested 12-byte entry header (tag `PCPT`, total entry
/// length `wire_len`); its `size` field is `16` in older files and `28` in
/// files written by newer Rekordbox versions, with an identical entry body
/// either way (the containing `CueList` carries the style, since a virtual
/// field here would be serialized by `bin.putStruct`). The remaining
/// fields are serialized in one pass through `bin.takeStruct`/`bin.putStruct`.
pub const Cue = struct {
    /// Hot cue number (0 = not a hot cue, 1 = A, 2 = B, ...).
    hot_cue: u32 = 0,
    /// Loop status: `4` if this cue is an active loop, `0` otherwise.
    status: u32 = 0,
    /// Unknown field, `0x00100000` in all known files.
    unknown1: u32 = 0x0010_0000,
    /// Somehow used for sorting cues (`0xFFFF` for the first cue).
    order_first: u16 = 0xFFFF,
    /// Somehow used for sorting cues (`0xFFFF` for the last cue).
    order_last: u16 = 0xFFFF,
    /// Type of this cue (`loop` if this cue is a loop).
    cue_type: CueType = .point,
    /// Unknown field, zero in all known files.
    unknown2: u8 = 0,
    /// Unknown field, `0x03E8` (= decimal 1000) in all known files.
    unknown3: u16 = 0x03E8,
    /// Time in milliseconds after which this cue would occur (at normal
    /// playback speed).
    time: u32 = 0,
    /// Time in milliseconds at which the loop jumps back to `time` (at
    /// normal playback speed).
    loop_time: u32 = 0xFFFF_FFFF,
    /// Unknown field.
    unknown4: u32 = 0,
    /// Unknown field.
    unknown5: u32 = 0,
    /// Unknown field.
    unknown6: u32 = 0,
    /// Unknown field.
    unknown7: u32 = 0,

    /// Length of a serialized entry, its nested header included.
    const wire_len = 12 + bin.serializedLen(Cue);

    /// Parses one entry. `header_size` learns the nested header's `size`
    /// style from the first entry; later entries must share it.
    fn parse(c: *bin.Cursor, header_size: *?u32) ParseError!Cue {
        const header = try bin.takeStruct(c, Header, .big);
        if (header.kind != .cue or header.total_size != wire_len) return error.UnexpectedValue;
        if (header.size != 16 and header.size != 28) return error.UnexpectedValue;
        if (header_size.*) |size| {
            if (size != header.size) return error.UnexpectedValue;
        } else {
            header_size.* = header.size;
        }
        return bin.takeStruct(c, Cue, .big);
    }

    fn writeTo(cue: *const Cue, e: *bin.Emitter, header_size: u32) WriteError!void {
        try bin.putStruct(e, Header{ .kind = .cue, .size = header_size, .total_size = wire_len }, .big);
        try bin.putStruct(e, cue, .big);
    }
};

/// List of cue points or loops (either hot cues or memory cues).
pub const CueList = struct {
    /// The types of cues (memory or hot) that this list contains.
    list_type: CueListType = .memory_cues,
    /// Unknown field, zero in all known files.
    unknown: u16 = 0,
    /// Entry count of a non-empty memory cue list; the `0xFFFFFFFF`
    /// sentinel in hot cue lists and empty lists. Validated on parse and
    /// derived on write, so the count stays consistent when `cues` is
    /// edited.
    memory_count: u32 = 0xFFFF_FFFF,
    /// Cues of this list. The `len_cues` count is recomputed from this slice
    /// on write.
    cues: []Cue = &.{},
    /// The `size` recorded in the nested `PCPT` entry headers: `16` in older
    /// files, `28` in files written by newer Rekordbox versions (the entry
    /// body is identical either way). A virtual field, not present in the
    /// file outside the entries; stored verbatim so files roundtrip
    /// byte-identical.
    entry_header_size: u32 = 16,

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!CueList {
        if (header.size != 24) return error.UnexpectedValue;
        const list_type: CueListType = @enumFromInt(try c.takeInt(u32, .big));
        const unknown = try c.takeInt(u16, .big);
        const len_cues = try c.takeInt(u16, .big);
        const memory_count = try c.takeInt(u32, .big);
        const expected_count: u64 = if (list_type == .memory_cues and len_cues > 0) len_cues else 0xFFFF_FFFF;
        if (memory_count != expected_count) return error.UnexpectedValue;
        const cues = try alloc.alloc(Cue, len_cues);
        var entry_header_size: ?u32 = null;
        for (cues) |*cue| cue.* = try Cue.parse(c, &entry_header_size);
        return .{
            .list_type = list_type,
            .unknown = unknown,
            .memory_count = memory_count,
            .cues = cues,
            .entry_header_size = entry_header_size orelse 16,
        };
    }

    fn writeTo(cl: *const CueList, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, @intFromEnum(cl.list_type), .big);
        try e.putInt(u16, cl.unknown, .big);
        try e.putInt(u16, try narrow(u16, cl.cues.len), .big);
        const memory_count: u32 = if (cl.list_type == .memory_cues and cl.cues.len > 0)
            try narrow(u32, cl.cues.len)
        else
            0xFFFF_FFFF;
        try e.putInt(u32, memory_count, .big);
        for (cl.cues) |*cue| try cue.writeTo(e, cl.entry_header_size);
    }
};

/// A length-prefixed wide (UTF-16BE) string.
///
/// The wire format is a big-endian `u32` length in bytes (including the
/// trailing NUL terminator, zero when empty) followed by that many bytes of
/// UTF-16BE encoded text:
///
/// ```text
/// | <length> (u32) | UTF-16BE encoded text | 0x0000 |
///                   <------------------------------>
///                            <length> bytes
/// ```
///
/// Diverging from rekordcrate, the payload is stored as raw bytes (NUL
/// included) so that roundtrips are byte-identical even for unusual data;
/// use `utf8` and `fromUtf8` to convert. Used for the `comment` field of
/// `ExtendedCue` and the `path` field of `Path` (rekordcrate uses an
/// equivalent `NullWideString` there).
pub const LenPrefixedWideString = struct {
    /// Raw payload bytes, exactly as found on disk.
    raw: []const u8 = &.{},

    /// Number of payload bytes this string occupies beyond its length
    /// prefix (zero when empty).
    pub fn byte_len(s: *const LenPrefixedWideString) u32 {
        return @intCast(s.raw.len);
    }

    /// Decodes the payload (minus trailing NULs) into UTF-8.
    pub fn utf8(s: *const LenPrefixedWideString, alloc: std.mem.Allocator) ![]u8 {
        if (s.raw.len % 2 != 0) return error.UnexpectedValue;
        const units = try alloc.alloc(u16, s.raw.len / 2);
        defer alloc.free(units);
        for (units, 0..) |*unit, i| {
            unit.* = (@as(u16, s.raw[2 * i]) << 8) | s.raw[2 * i + 1];
        }
        var end = units.len;
        while (end > 0 and units[end - 1] == 0) end -= 1;
        return std.unicode.utf16LeToUtf8Alloc(alloc, units[0..end]);
    }

    /// Encodes `text` as UTF-16BE with a trailing NUL, the inverse of
    /// `utf8`.
    pub fn fromUtf8(alloc: std.mem.Allocator, text: []const u8) !LenPrefixedWideString {
        const units = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
        defer alloc.free(units);
        const raw = try alloc.alloc(u8, (units.len + 1) * 2);
        for (units, 0..) |unit, i| {
            raw[2 * i] = @intCast(unit >> 8);
            raw[2 * i + 1] = @intCast(unit & 0xFF);
        }
        raw[raw.len - 2] = 0;
        raw[raw.len - 1] = 0;
        return .{ .raw = raw };
    }

    /// Custom codec hook for `bin.takeStruct`/`bin.putStruct`.
    pub fn decode(c: *bin.Cursor) bin.ReadError!LenPrefixedWideString {
        const len = try c.takeInt(u32, .big);
        if (len == 0) return .{};
        const alloc = c.alloc orelse return bin.ReadError.OutOfMemory;
        return .{ .raw = try alloc.dupe(u8, try c.takeBytes(len)) };
    }

    /// Custom codec hook for `bin.takeStruct`/`bin.putStruct`.
    pub fn encode(s: LenPrefixedWideString, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, s.byte_len(), .big);
        try e.putBytes(s.raw);
    }
};

/// A memory or hot cue (or loop), a single entry of an extended cue list.
/// Preceded on the wire by a nested 16-byte entry header (tag `PCP2`),
/// derived on write from the comment and trailing lengths; the remaining
/// fixed part (56 bytes including the comment's empty length prefix) is
/// serialized in one pass through `bin.takeStruct`/`bin.putStruct`, the
/// `comment` codec included.
pub const ExtendedCue = struct {
    /// Hot cue number (0 = not a hot cue, 1 = A, 2 = B, ...).
    hot_cue: u32 = 0,
    /// Type of this cue (`loop` if this cue is a loop).
    cue_type: CueType = .point,
    /// Unknown field, zero in all known files.
    unknown1: u8 = 0,
    /// Unknown field, `0x03E8` (= decimal 1000) in all known files.
    unknown2: u16 = 0x03E8,
    /// Time in milliseconds after which this cue would occur (at normal
    /// playback speed).
    time: u32 = 0,
    /// Time in milliseconds at which the loop jumps back to `time` (at
    /// normal playback speed).
    loop_time: u32 = 0xFFFF_FFFF,
    /// Color assigned to this cue. Only used by memory cues; hot cues use a
    /// different value (see `hot_cue_color_index`).
    color: ColorIndex = .none,
    /// Unknown field, `1` in all known files.
    unknown3: u8 = 1,
    /// Unknown field.
    unknown4: u16 = 0,
    /// Unknown field.
    unknown5: u32 = 0,
    /// Loop size numerator (if this is a quantized loop).
    loop_numerator: u16 = 0,
    /// Loop size denominator (if this is a quantized loop).
    loop_denominator: u16 = 0,
    /// Comment assigned to this cue.
    comment: LenPrefixedWideString = .{},
    /// Rekordbox hotcue color index:
    ///
    /// | Value  | Color                       |
    /// | ------ | --------------------------- |
    /// | `0x00` | None (Green on older CDJs). |
    /// | `0x01` | `#305aff`                   |
    /// | `0x02` | `#5073ff`                   |
    /// | `0x03` | `#508cff`                   |
    /// | `0x04` | `#50a0ff`                   |
    /// | `0x05` | `#50b4ff`                   |
    /// | `0x06` | `#50b0f2`                   |
    /// | `0x07` | `#50aee8`                   |
    /// | `0x08` | `#45acdb`                   |
    /// | `0x09` | `#00e0ff`                   |
    /// | `0x0a` | `#19daf0`                   |
    /// | `0x0b` | `#32d2e6`                   |
    /// | `0x0c` | `#21b4b9`                   |
    /// | `0x0d` | `#20aaa0`                   |
    /// | `0x0e` | `#1fa392`                   |
    /// | `0x0f` | `#19a08c`                   |
    /// | `0x10` | `#14a584`                   |
    /// | `0x11` | `#14aa7d`                   |
    /// | `0x12` | `#10b176`                   |
    /// | `0x13` | `#30d26e`                   |
    /// | `0x14` | `#37de5a`                   |
    /// | `0x15` | `#3ceb50`                   |
    /// | `0x16` | `#28e214`                   |
    /// | `0x17` | `#7dc13d`                   |
    /// | `0x18` | `#8cc832`                   |
    /// | `0x19` | `#9bd723`                   |
    /// | `0x1a` | `#a5e116`                   |
    /// | `0x1b` | `#a5dc0a`                   |
    /// | `0x1c` | `#aad208`                   |
    /// | `0x1d` | `#b4c805`                   |
    /// | `0x1e` | `#b4be04`                   |
    /// | `0x1f` | `#bab404`                   |
    /// | `0x20` | `#c3af04`                   |
    /// | `0x21` | `#e1aa00`                   |
    /// | `0x22` | `#ffa000`                   |
    /// | `0x23` | `#ff9600`                   |
    /// | `0x24` | `#ff8c00`                   |
    /// | `0x25` | `#ff7500`                   |
    /// | `0x26` | `#e0641b`                   |
    /// | `0x27` | `#e0461e`                   |
    /// | `0x28` | `#e0301e`                   |
    /// | `0x29` | `#e02823`                   |
    /// | `0x2a` | `#e62828`                   |
    /// | `0x2b` | `#ff376f`                   |
    /// | `0x2c` | `#ff2d6f`                   |
    /// | `0x2d` | `#ff127b`                   |
    /// | `0x2e` | `#f51e8c`                   |
    /// | `0x2f` | `#eb2da0`                   |
    /// | `0x30` | `#e637b4`                   |
    /// | `0x31` | `#de44cf`                   |
    /// | `0x32` | `#de448d`                   |
    /// | `0x33` | `#e630b4`                   |
    /// | `0x34` | `#e619dc`                   |
    /// | `0x35` | `#e600ff`                   |
    /// | `0x36` | `#dc00ff`                   |
    /// | `0x37` | `#cc00ff`                   |
    /// | `0x38` | `#b432ff`                   |
    /// | `0x39` | `#b93cff`                   |
    /// | `0x3a` | `#c542ff`                   |
    /// | `0x3b` | `#aa5aff`                   |
    /// | `0x3c` | `#aa72ff`                   |
    /// | `0x3d` | `#8272ff`                   |
    /// | `0x3e` | `#6473ff`                   |
    hot_cue_color_index: u8 = 0,
    /// Rekordbox hotcue color RGB value. Similar but not identical to the
    /// color Rekordbox displays, possibly used to illuminate the RGB LEDs
    /// of a player that has loaded the cue. `(0, 0, 0)` if no color is
    /// associated with this hot cue.
    hot_cue_color_rgb: [3]u8 = .{ 0, 0, 0 },
    /// Unknown field.
    unknown6: u32 = 0,
    /// Unknown field, `0x00C17000` in all known files.
    unknown7: u32 = 0x00C1_7000,
    /// Unknown field.
    unknown8: u32 = 0,
    /// Unknown field.
    unknown9: u32 = 0,
    /// Unknown field.
    unknown10: u32 = 0,
    /// Trailing unknown bytes after `unknown10` to the end of the entry:
    /// `total_size - 68 - comment byte_len` bytes.
    trailing: []const u8 = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator) ParseError!ExtendedCue {
        const header = try bin.takeStruct(c, Header, .big);
        if (header.kind != .extended_cue or header.size != 16) return error.UnexpectedValue;
        var cue = try bin.takeStruct(c, ExtendedCue, .big);
        const fixed_len: usize = 68 + cue.comment.raw.len;
        if (header.total_size < fixed_len) return error.InvalidFormat;
        cue.trailing = try alloc.dupe(u8, try c.takeBytes(@as(usize, header.total_size) - fixed_len));
        return cue;
    }

    fn writeTo(cue: *const ExtendedCue, e: *bin.Emitter) WriteError!void {
        try bin.putStruct(e, Header{
            .kind = .extended_cue,
            .size = 16,
            .total_size = try narrow(u32, 68 + cue.comment.raw.len + cue.trailing.len),
        }, .big);
        try bin.putStruct(e, cue, .big);
        try e.putBytes(cue.trailing);
    }
};

/// List of cue points or loops (either hot cues or memory cues, extended
/// version). Variation of the cue list that adds support for more metadata
/// such as comments and colors; introduced with the Nexus 2 series players.
pub const ExtendedCueList = struct {
    /// The types of cues (memory or hot) that this list contains.
    list_type: CueListType = .memory_cues,
    /// Unknown field, zero in all known files.
    unknown: u16 = 0,
    /// Cues of this list. The `len_cues` count is recomputed from this slice
    /// on write.
    cues: []ExtendedCue = &.{},

    /// Unknown fields that must hold their default value in all known files;
    /// other values are rejected on parse (rekordcrate asserts `unknown` is
    /// zero on read).
    pub const constant_fields = .{.unknown};

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!ExtendedCueList {
        if (header.size != 20) return error.UnexpectedValue;
        const list_type: CueListType = @enumFromInt(try c.takeInt(u32, .big));
        const len_cues = try c.takeInt(u16, .big);
        const unknown = try c.takeInt(u16, .big);
        try bin.validateConstantFields(ExtendedCueList, .{ .list_type = list_type, .unknown = unknown });
        const cues = try alloc.alloc(ExtendedCue, len_cues);
        for (cues) |*cue| cue.* = try ExtendedCue.parse(c, alloc);
        return .{ .list_type = list_type, .unknown = unknown, .cues = cues };
    }

    fn writeTo(cl: *const ExtendedCueList, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, @intFromEnum(cl.list_type), .big);
        try e.putInt(u16, try narrow(u16, cl.cues.len), .big);
        try e.putInt(u16, cl.unknown, .big);
        for (cl.cues) |*cue| try cue.writeTo(e);
    }
};

/// Path of the audio file that this analysis belongs to.
pub const Path = struct {
    /// Path of the audio file. The length prefix in the section preamble
    /// must equal the section's `content_size`.
    path: LenPrefixedWideString = .{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Path {
        _ = alloc;
        if (header.size != 16) return error.UnexpectedValue;
        const p = try bin.takeStruct(c, Path, .big);
        if (p.path.raw.len != header.content_size()) return error.InvalidFormat;
        return p;
    }

    fn writeTo(p: *const Path, e: *bin.Emitter) WriteError!void {
        try bin.putStruct(e, p, .big);
    }
};

/// Seek information for variable bitrate files.
pub const Vbr = struct {
    /// Unknown field.
    unknown1: u32 = 0,
    /// Unknown data blob, the raw section content.
    data: []const u8 = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Vbr {
        if (header.size != 16) return error.UnexpectedValue;
        const unknown1 = try c.takeInt(u32, .big);
        const data = try alloc.dupe(u8, try c.takeBytes(header.content_size()));
        return .{ .unknown1 = unknown1, .data = data };
    }

    fn writeTo(v: *const Vbr, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, v.unknown1, .big);
        try e.putBytes(v.data);
    }
};

/// Single column of a `waveform_preview`/`waveform_detail` section.
///
/// The wire byte packs the height into the five most significant bits and
/// the whiteness into the three least significant bits; because Zig packs
/// struct fields starting at the least significant bit, the fields are
/// declared in reverse bit order.
pub const WaveformPreviewColumn = packed struct(u8) {
    /// Shade of white.
    whiteness: u3 = 0,
    /// Height of the column in pixels.
    height: u5 = 0,
};

/// Single column of a `tiny_waveform_preview` section. The wire byte packs
/// the height into the four most significant bits (see
/// `WaveformPreviewColumn` for the field order).
pub const TinyWaveformPreviewColumn = packed struct(u8) {
    /// Height of the column in pixels.
    height: u4 = 0,
    /// Unknown field.
    unused: u4 = 0,
};

/// Single column of a `waveform_color_preview` section.
pub const WaveformColorPreviewColumn = struct {
    /// Unknown field (somehow encodes the "whiteness").
    unknown1: u8 = 0,
    /// Unknown field (somehow encodes the "whiteness").
    unknown2: u8 = 0,
    /// Sound energy in the bottom half of the frequency range (<10 KHz).
    energy_bottom_half_freq: u8 = 0,
    /// Sound energy in the bottom third of the frequency range.
    energy_bottom_third_freq: u8 = 0,
    /// Sound energy in the mid of the frequency range.
    energy_mid_third_freq: u8 = 0,
    /// Sound energy in the top of the frequency range.
    energy_top_third_freq: u8 = 0,
};

/// Single column of a `waveform_color_detail` section. The wire bytes pack
/// the fields big-endian, starting with `red` in the three most significant
/// bits (see `WaveformPreviewColumn` for the field order).
pub const WaveformColorDetailColumn = packed struct(u16) {
    /// Unknown field.
    unknown: u2 = 0,
    /// Height of the column.
    height: u5 = 0,
    /// Blue color component.
    blue: u3 = 0,
    /// Green color component.
    green: u3 = 0,
    /// Red color component.
    red: u3 = 0,
};

/// Single column of a `waveform_3band_preview` section.
pub const Waveform3BandPreviewColumn = struct {
    /// Sound energy in the mid of the frequency range.
    energy_mid_third_freq: u8 = 0,
    /// Sound energy in the top of the frequency range.
    energy_top_third_freq: u8 = 0,
    /// Sound energy in the bottom third of the frequency range.
    energy_bottom_third_freq: u8 = 0,
};

/// Single column of a `waveform_3band_detail` section.
pub const Waveform3BandDetailColumn = struct {
    /// Sound energy in the mid of the frequency range.
    energy_mid_third_freq: u8 = 0,
    /// Sound energy in the top of the frequency range.
    energy_top_third_freq: u8 = 0,
    /// Sound energy in the bottom third of the frequency range.
    energy_bottom_third_freq: u8 = 0,
};

/// Fixed-width monochrome preview of the track waveform.
pub const WaveformPreview = struct {
    /// Unknown field, `0x00010000` in all known files.
    unknown: u32 = 0x0001_0000,
    /// Waveform preview column data; `len_preview` is recomputed from this
    /// slice on write.
    data: []WaveformPreviewColumn = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!WaveformPreview {
        if (header.size != 20) return error.UnexpectedValue;
        const len_preview = try c.takeInt(u32, .big);
        const unknown = try c.takeInt(u32, .big);
        if (len_preview != header.content_size()) return error.InvalidFormat;
        const data = try alloc.alloc(WaveformPreviewColumn, len_preview);
        for (data) |*column| column.* = try bin.takeStruct(c, WaveformPreviewColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const WaveformPreview, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Smaller version of the fixed-width monochrome preview of the track
/// waveform (for the CDJ-900).
pub const TinyWaveformPreview = struct {
    /// Unknown field, `0x00010000` in all known files.
    unknown: u32 = 0x0001_0000,
    /// Waveform preview column data; `len_preview` is recomputed from this
    /// slice on write.
    data: []TinyWaveformPreviewColumn = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!TinyWaveformPreview {
        if (header.size != 20) return error.UnexpectedValue;
        const len_preview = try c.takeInt(u32, .big);
        const unknown = try c.takeInt(u32, .big);
        if (len_preview != header.content_size()) return error.InvalidFormat;
        const data = try alloc.alloc(TinyWaveformPreviewColumn, len_preview);
        for (data) |*column| column.* = try bin.takeStruct(c, TinyWaveformPreviewColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const TinyWaveformPreview, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Variable-width large monochrome version of the track waveform, in `.EXT`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const WaveformDetail = struct {
    /// Unknown field, `0x00960000` in all known files.
    unknown: u32 = 0x0096_0000,
    /// Waveform detail column data; `len_entries` is recomputed from this
    /// slice on write.
    data: []WaveformPreviewColumn = &.{},

    /// Unknown fields that must hold their default value in all known files;
    /// other values are rejected on parse (rekordcrate asserts on read).
    pub const constant_fields = .{.unknown};

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!WaveformDetail {
        if (header.size != 24) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 1) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u32, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        const unknown = try c.takeInt(u32, .big);
        try bin.validateConstantFields(WaveformDetail, .{ .unknown = unknown });
        const data = try alloc.alloc(WaveformPreviewColumn, len_entries);
        for (data) |*column| column.* = try bin.takeStruct(c, WaveformPreviewColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const WaveformDetail, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, 1, .big);
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Fixed-width colored preview of the track waveform, in `.EXT` files.
pub const WaveformColorPreview = struct {
    /// Unknown field, zero in all known files (stored verbatim).
    unknown: u32 = 0,
    /// Waveform preview column data; `len_entries` is recomputed from this
    /// slice on write.
    data: []WaveformColorPreviewColumn = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!WaveformColorPreview {
        if (header.size != 24) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 6) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u32, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        const unknown = try c.takeInt(u32, .big);
        const data = try alloc.alloc(WaveformColorPreviewColumn, len_entries);
        for (data) |*column| column.* = try bin.takeStruct(c, WaveformColorPreviewColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const WaveformColorPreview, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, 6, .big);
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Variable-width large colored version of the track waveform, in `.EXT`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const WaveformColorDetail = struct {
    /// Unknown field, `0x00960305` in all known files (stored verbatim).
    unknown: u32 = 0x0096_0305,
    /// Waveform detail column data; `len_entries` is recomputed from this
    /// slice on write.
    data: []WaveformColorDetailColumn = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!WaveformColorDetail {
        if (header.size != 24) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 2) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u32, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        const unknown = try c.takeInt(u32, .big);
        const data = try alloc.alloc(WaveformColorDetailColumn, len_entries);
        for (data) |*column| column.* = try bin.takeStruct(c, WaveformColorDetailColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const WaveformColorDetail, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, 2, .big);
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Fixed-width 3-band preview of the track waveform, in `.2EX` files.
pub const Waveform3BandPreview = struct {
    /// Waveform preview column data; `len_entries` is recomputed from this
    /// slice on write.
    data: []Waveform3BandPreviewColumn = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Waveform3BandPreview {
        if (header.size != 20) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 3) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u32, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        const data = try alloc.alloc(Waveform3BandPreviewColumn, len_entries);
        for (data) |*column| column.* = try bin.takeStruct(c, Waveform3BandPreviewColumn, .big);
        return .{ .data = data };
    }

    fn writeTo(w: *const Waveform3BandPreview, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, 3, .big);
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Variable-width large 3-band version of the track waveform, in `.2EX`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const Waveform3BandDetail = struct {
    /// Unknown field, `0x00960000` in all known files.
    unknown: u32 = 0x0096_0000,
    /// Waveform detail column data; `len_entries` is recomputed from this
    /// slice on write.
    data: []Waveform3BandDetailColumn = &.{},

    /// Unknown fields that must hold their default value in all known files;
    /// other values are rejected on parse (rekordcrate asserts on read).
    pub const constant_fields = .{.unknown};

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Waveform3BandDetail {
        if (header.size != 24) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 3) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u32, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        const unknown = try c.takeInt(u32, .big);
        try bin.validateConstantFields(Waveform3BandDetail, .{ .unknown = unknown });
        const data = try alloc.alloc(Waveform3BandDetailColumn, len_entries);
        for (data) |*column| column.* = try bin.takeStruct(c, Waveform3BandDetailColumn, .big);
        return .{ .unknown = unknown, .data = data };
    }

    fn writeTo(w: *const Waveform3BandDetail, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, 3, .big);
        try e.putInt(u32, try narrow(u32, w.data.len), .big);
        try e.putInt(u32, w.unknown, .big);
        for (w.data) |*column| try bin.putStruct(e, column, .big);
    }
};

/// Music classification used for Lighting mode, based on rhythm, tempo,
/// kick drum, and sound density.
pub const Mood = enum(u16) {
    /// Phrase types consist of "Intro", "Up", "Down", "Chorus", and "Outro".
    /// Other values in each phrase entry cause the intro, chorus, and outro
    /// phrases to have their labels subdivided into styles "1" or "2" (for
    /// example, "Intro 1"), and "up" is subdivided into "Up 1", "Up 2", or
    /// "Up 3".
    high = 1,
    /// Phrase types are labeled "Intro", "Verse 1" through "Verse 6",
    /// "Chorus", "Bridge", and "Outro".
    mid = 2,
    /// Phrase types are labeled "Intro", "Verse 1", "Verse 2", "Chorus",
    /// "Bridge", and "Outro". There are three different phrase type values
    /// for each of "Verse 1" and "Verse 2", but Rekordbox makes no
    /// distinction between them.
    low = 3,
    _,
};

/// Stylistic track bank for Lighting mode.
pub const Bank = enum(u8) {
    /// Default bank variant, treated as `cool`.
    default = 0,
    /// "Cool" bank variant.
    cool = 1,
    /// "Natural" bank variant.
    natural = 2,
    /// "Hot" bank variant.
    hot = 3,
    /// "Subtle" bank variant.
    subtle = 4,
    /// "Warm" bank variant.
    warm = 5,
    /// "Vivid" bank variant.
    vivid = 6,
    /// "Club 1" bank variant.
    club1 = 7,
    /// "Club 2" bank variant.
    club2 = 8,
    _,
};

/// A song structure entry that represents a phrase in the track. Serialized
/// in one pass through `bin.takeStruct`/`bin.putStruct` (24 bytes).
pub const Phrase = struct {
    /// Phrase number (starting at 1).
    index: u16 = 0,
    /// Beat number where this phrase begins.
    beat: u16 = 0,
    /// Kind of phrase that Rekordbox has identified (?).
    kind: u16 = 0,
    /// Unknown field.
    unknown1: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k1: u8 = 0,
    /// Unknown field.
    unknown2: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k2: u8 = 0,
    /// Unknown field.
    unknown3: u8 = 0,
    /// Flag that determines if only `beat2` is used (0), or if `beat2`,
    /// `beat3` and `beat4` are used (1).
    b: u8 = 0,
    /// Beat number.
    beat2: u16 = 0,
    /// Beat number.
    beat3: u16 = 0,
    /// Beat number.
    beat4: u16 = 0,
    /// Unknown field.
    unknown4: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k3: u8 = 0,
    /// Unknown field.
    unknown5: u8 = 0,
    /// Indicates if there are fill (non-phrase) beats at the end of the
    /// phrase.
    fill: u8 = 0,
    /// Beat number where the fill begins (if `fill` is non-zero).
    beat_fill: u16 = 0,
};

/// The data part of a `song_structure` section, which may be encrypted
/// (Rekordbox 6 and newer).
pub const SongStructureData = struct {
    /// Overall type of phrase structure.
    mood: Mood = .high,
    /// Unknown field.
    unknown1: u32 = 0,
    /// Unknown field.
    unknown2: u16 = 0,
    /// Number of the beat at which the last recognized phrase ends.
    end_beat: u16 = 0,
    /// Unknown field.
    unknown3: u16 = 0,
    /// Stylistic bank assigned in Lighting Mode.
    bank: Bank = .default,
    /// Unknown field.
    unknown4: u8 = 0,
    /// Phrase entries. The `len_entries` count is recomputed from this
    /// slice on write (and feeds the XOR key).
    phrases: []Phrase = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, len_entries: u16) ParseError!SongStructureData {
        var out = try bin.takeStruct(c, SongStructureData, .big);
        out.phrases = try alloc.alloc(Phrase, len_entries);
        for (out.phrases) |*phrase| phrase.* = try bin.takeStruct(c, Phrase, .big);
        return out;
    }

    fn writeTo(d: *const SongStructureData, e: *bin.Emitter) WriteError!void {
        try bin.putStruct(e, d, .big);
        for (d.phrases) |*phrase| try bin.putStruct(e, phrase, .big);
    }
};

/// Key table for the song-structure obfuscation (Rekordbox 6 and newer).
const KEY_DATA = [19]u8{
    0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2,
    0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1,
};

/// Repeating XOR key derived from the number of phrase entries: each key
/// byte is the table entry offset by `len_entries`, modulo 256.
fn getKey(len_entries: u16) [19]u8 {
    var key: [19]u8 = undefined;
    for (KEY_DATA, 0..) |byte, i| key[i] = @truncate(@as(u16, byte) + len_entries);
    return key;
}

/// A song structure is considered encrypted when the first two key bytes
/// XOR-decode the raw `mood` field to a valid mood.
fn checkIfEncrypted(span: []const u8, len_entries: u16) bool {
    if (span.len < 2) return false;
    const key = getKey(len_entries);
    const raw_mood = (@as(u16, span[0]) << 8) | span[1];
    const decoded_mood = raw_mood ^ (@as(u16, key[0]) << 8 | key[1]);
    return switch (decoded_mood) {
        1...3 => true,
        else => false,
    };
}

/// Describes the structure of a song (Intro, Chorus, Verse, ...), in `.EXT`
/// files.
///
/// The section preamble (`len_entry_bytes`, `len_entries`, and everything
/// up to `mood` included) is stored in the clear; the data span starting at
/// `mood` may be XOR-obfuscated. Encryption is detected on parse by
/// decoding the `mood` field, and applied again on write when
/// `is_encrypted` is set, so encrypted files roundtrip byte-identical.
pub const SongStructure = struct {
    /// Indicates if the data part is encrypted (a virtual field, not
    /// present in the file).
    is_encrypted: bool = false,
    /// Song structure data.
    data: SongStructureData = .{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!SongStructure {
        if (header.size != 32) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != 24) return error.UnexpectedValue;
        const len_entries = try c.takeInt(u16, .big);
        if (@as(u64, len_entry_bytes) * len_entries != header.content_size()) return error.InvalidFormat;
        // The data span starts at `mood`, inside the section preamble, and
        // extends to the end of the section.
        const span: []u8 = try alloc.dupe(u8, try c.takeBytes(c.remaining()));
        const is_encrypted = checkIfEncrypted(span, len_entries);
        if (is_encrypted) xor.apply(span, &getKey(len_entries));
        var data_cursor = bin.Cursor.init(span);
        const data = try SongStructureData.parse(&data_cursor, alloc, len_entries);
        if (!data_cursor.atEnd()) return error.InvalidFormat;
        return .{ .is_encrypted = is_encrypted, .data = data };
    }

    fn writeTo(ss: *const SongStructure, e: *bin.Emitter, alloc: std.mem.Allocator) WriteError!void {
        const len_entries: u16 = try narrow(u16, ss.data.phrases.len);
        try e.putInt(u32, 24, .big);
        try e.putInt(u16, len_entries, .big);
        var data_out = bin.Emitter.init(alloc);
        defer data_out.deinit();
        try ss.data.writeTo(&data_out);
        const bytes = try data_out.toOwnedSlice();
        defer alloc.free(bytes);
        if (ss.is_encrypted) xor.apply(bytes, &getKey(len_entries));
        try e.putBytes(bytes);
    }
};

/// Unknown content: a section whose tag this library does not recognize
/// (or a `file`/`cue`/`extended_cue` header, which only appear nested or
/// by mistake). The tag and the section's raw bytes are stored verbatim
/// and re-emitted as-is, with header sizes derived from the blob lengths.
/// This is how files keep roundtripping when they contain section types
/// this library does not know about.
pub const Unknown = struct {
    /// Kind of the unknown section.
    kind: Kind,
    /// Unknown header preamble bytes (between the 12-byte header prefix and
    /// the content).
    header_data: []const u8 = &.{},
    /// Unknown content bytes.
    content_data: []const u8 = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Unknown {
        const header_data = try alloc.dupe(u8, try c.takeBytes(header.remaining_size()));
        const content_data = try alloc.dupe(u8, try c.takeBytes(header.content_size()));
        return .{ .kind = header.kind, .header_data = header_data, .content_data = content_data };
    }

    fn writeTo(u: *const Unknown, e: *bin.Emitter) WriteError!void {
        try e.putBytes(u.header_data);
        try e.putBytes(u.content_data);
    }
};

/// Section content, one variant per known section type.
pub const Content = union(enum) {
    /// All beats in the track.
    beat_grid: BeatGrid,
    /// List of cue points or loops (either hot cues or memory cues).
    cue_list: CueList,
    /// List of cue points or loops, extended version.
    extended_cue_list: ExtendedCueList,
    /// Path of the audio file that this analysis belongs to.
    path: Path,
    /// Seek information for variable bitrate files.
    vbr: Vbr,
    /// Fixed-width monochrome preview of the track waveform.
    waveform_preview: WaveformPreview,
    /// Smaller version of the monochrome waveform preview.
    tiny_waveform_preview: TinyWaveformPreview,
    /// Variable-width large monochrome version of the track waveform.
    waveform_detail: WaveformDetail,
    /// Fixed-width colored preview of the track waveform.
    waveform_color_preview: WaveformColorPreview,
    /// Variable-width large colored version of the track waveform.
    waveform_color_detail: WaveformColorDetail,
    /// Fixed-width 3-band preview of the track waveform.
    waveform_3band_preview: Waveform3BandPreview,
    /// Variable-width large 3-band version of the track waveform.
    waveform_3band_detail: Waveform3BandDetail,
    /// Describes the structure of a song (Intro, Chorus, Verse, ...).
    song_structure: SongStructure,
    /// Unknown content, kept verbatim.
    unknown: Unknown,
};

/// Parses the content of one section from `c` (positioned right after the
/// section's 12-byte header). The section's bytes are bounded to its
/// declared `total_size` and must be consumed exactly; a mismatch is
/// reported as `InvalidFormat`.
fn parseContent(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Content {
    if (header.size < 12 or header.total_size < header.size) return error.InvalidFormat;
    const region = try c.takeBytes(header.total_size - 12);
    var sub = bin.Cursor.initAlloc(alloc, region);
    const content: Content = switch (header.kind) {
        .beat_grid => .{ .beat_grid = try BeatGrid.parse(&sub, alloc, header) },
        .cue_list => .{ .cue_list = try CueList.parse(&sub, alloc, header) },
        .extended_cue_list => .{ .extended_cue_list = try ExtendedCueList.parse(&sub, alloc, header) },
        .path => .{ .path = try Path.parse(&sub, alloc, header) },
        .vbr => .{ .vbr = try Vbr.parse(&sub, alloc, header) },
        .waveform_preview => .{ .waveform_preview = try WaveformPreview.parse(&sub, alloc, header) },
        .tiny_waveform_preview => .{ .tiny_waveform_preview = try TinyWaveformPreview.parse(&sub, alloc, header) },
        .waveform_detail => .{ .waveform_detail = try WaveformDetail.parse(&sub, alloc, header) },
        .waveform_color_preview => .{ .waveform_color_preview = try WaveformColorPreview.parse(&sub, alloc, header) },
        .waveform_color_detail => .{ .waveform_color_detail = try WaveformColorDetail.parse(&sub, alloc, header) },
        .waveform_3band_preview => .{ .waveform_3band_preview = try Waveform3BandPreview.parse(&sub, alloc, header) },
        .waveform_3band_detail => .{ .waveform_3band_detail = try Waveform3BandDetail.parse(&sub, alloc, header) },
        .song_structure => .{ .song_structure = try SongStructure.parse(&sub, alloc, header) },
        // Entry kinds only appear nested inside cue lists; a stray `file`
        // header or cue section at the top level is kept verbatim, like any
        // unknown tag.
        .file, .cue, .extended_cue, _ => .{ .unknown = try Unknown.parse(&sub, alloc, header) },
    };
    if (!sub.atEnd()) return error.InvalidFormat;
    return content;
}

/// The kind a section's content serializes as: every known content maps to
/// its kind, unknown content keeps the kind it was parsed with.
fn sectionKind(content: *const Content) Kind {
    return switch (content.*) {
        .beat_grid => .beat_grid,
        .cue_list => .cue_list,
        .extended_cue_list => .extended_cue_list,
        .path => .path,
        .vbr => .vbr,
        .waveform_preview => .waveform_preview,
        .tiny_waveform_preview => .tiny_waveform_preview,
        .waveform_detail => .waveform_detail,
        .waveform_color_preview => .waveform_color_preview,
        .waveform_color_detail => .waveform_color_detail,
        .waveform_3band_preview => .waveform_3band_preview,
        .waveform_3band_detail => .waveform_3band_detail,
        .song_structure => .song_structure,
        .unknown => |u| u.kind,
    };
}

/// Derives the wire header of `content`: the kind and the canonical header
/// `size` are fixed per section type (and follow the blob lengths, for
/// unknown sections), while `total_size` follows from the content lengths.
/// Deriving headers from the data rather than storing parsed values keeps
/// files consistent when parsed content is modified.
fn sectionHeader(content: Content) WriteError!Header {
    return switch (content) {
        .beat_grid => |x| .{
            .kind = .beat_grid,
            .size = 24,
            .total_size = try narrow(u32, 24 + bin.serializedLen(Beat) * x.beats.len),
        },
        .cue_list => |x| .{
            .kind = .cue_list,
            .size = 24,
            .total_size = try narrow(u32, 24 + Cue.wire_len * x.cues.len),
        },
        .extended_cue_list => |x| .{
            .kind = .extended_cue_list,
            .size = 20,
            .total_size = blk: {
                var len: usize = 20;
                for (x.cues) |*cue| len += 68 + cue.comment.raw.len + cue.trailing.len;
                break :blk try narrow(u32, len);
            },
        },
        .path => |x| .{ .kind = .path, .size = 16, .total_size = 16 + x.path.byte_len() },
        .vbr => |x| .{ .kind = .vbr, .size = 16, .total_size = try narrow(u32, 16 + x.data.len) },
        .waveform_preview => |x| .{
            .kind = .waveform_preview,
            .size = 20,
            .total_size = try narrow(u32, 20 + bin.serializedLen(WaveformPreviewColumn) * x.data.len),
        },
        .tiny_waveform_preview => |x| .{
            .kind = .tiny_waveform_preview,
            .size = 20,
            .total_size = try narrow(u32, 20 + bin.serializedLen(TinyWaveformPreviewColumn) * x.data.len),
        },
        .waveform_detail => |x| .{
            .kind = .waveform_detail,
            .size = 24,
            .total_size = try narrow(u32, 24 + bin.serializedLen(WaveformPreviewColumn) * x.data.len),
        },
        .waveform_color_preview => |x| .{
            .kind = .waveform_color_preview,
            .size = 24,
            .total_size = try narrow(u32, 24 + bin.serializedLen(WaveformColorPreviewColumn) * x.data.len),
        },
        .waveform_color_detail => |x| .{
            .kind = .waveform_color_detail,
            .size = 24,
            .total_size = try narrow(u32, 24 + bin.serializedLen(WaveformColorDetailColumn) * x.data.len),
        },
        .waveform_3band_preview => |x| .{
            .kind = .waveform_3band_preview,
            .size = 20,
            .total_size = try narrow(u32, 20 + bin.serializedLen(Waveform3BandPreviewColumn) * x.data.len),
        },
        .waveform_3band_detail => |x| .{
            .kind = .waveform_3band_detail,
            .size = 24,
            .total_size = try narrow(u32, 24 + bin.serializedLen(Waveform3BandDetailColumn) * x.data.len),
        },
        .song_structure => |x| .{
            .kind = .song_structure,
            .size = 32,
            .total_size = try narrow(u32, 32 + bin.serializedLen(Phrase) * x.data.phrases.len),
        },
        .unknown => |x| .{
            .kind = x.kind,
            .size = try narrow(u32, 12 + x.header_data.len),
            .total_size = try narrow(u32, 12 + x.header_data.len + x.content_data.len),
        },
    };
}

/// Writes one section: its derived header followed by the content.
fn writeSection(content: Content, e: *bin.Emitter, alloc: std.mem.Allocator) WriteError!void {
    try bin.putStruct(e, try sectionHeader(content), .big);
    try writeContent(content, e, alloc);
}

fn writeContent(content: Content, e: *bin.Emitter, alloc: std.mem.Allocator) WriteError!void {
    switch (content) {
        .beat_grid => |x| try x.writeTo(e),
        .cue_list => |x| try x.writeTo(e),
        .extended_cue_list => |x| try x.writeTo(e),
        .path => |x| try x.writeTo(e),
        .vbr => |x| try x.writeTo(e),
        .waveform_preview => |x| try x.writeTo(e),
        .tiny_waveform_preview => |x| try x.writeTo(e),
        .waveform_detail => |x| try x.writeTo(e),
        .waveform_color_preview => |x| try x.writeTo(e),
        .waveform_color_detail => |x| try x.writeTo(e),
        .waveform_3band_preview => |x| try x.writeTo(e),
        .waveform_3band_detail => |x| try x.writeTo(e),
        .song_structure => |x| try x.writeTo(e, alloc),
        .unknown => |x| try x.writeTo(e),
    }
}

/// Writes a whole file: the `PMAI` header with sizes derived from the
/// content, `header_data`, and the sections.
fn writeFile(e: *bin.Emitter, alloc: std.mem.Allocator, header_data: []const u8, sections: []const Content) WriteError!void {
    var total: usize = 12 + header_data.len;
    for (sections) |content| total += (try sectionHeader(content)).total_size;
    try bin.putStruct(e, Header{
        .kind = .file,
        .size = try narrow(u32, 12 + header_data.len),
        .total_size = try narrow(u32, total),
    }, .big);
    try e.putBytes(header_data);
    for (sections) |content| try writeSection(content, e, alloc);
}

/// Represents a whole `ANLZ0000.{DAT,EXT,2EX}` file.
pub const Anlz = struct {
    /// Arena that owns every variable-size value reachable from this
    /// instance; freed by `deinit`.
    arena: *std.heap.ArenaAllocator,
    /// Unknown preamble bytes following the file header (16 bytes in all
    /// known files). The `PMAI` header itself is fully derived on write.
    header_data: []const u8,
    /// The content sections; section headers are derived on write.
    sections: []Content,

    /// Parses an ANLZ image. All data is copied into an arena owned by the
    /// returned instance, so `buf` may be freed afterwards. Headers are
    /// validated against the values derived on write, so any file that
    /// parses re-serializes byte-identical. Call `deinit` when done.
    pub fn parse(alloc: std.mem.Allocator, buf: []const u8) ParseError!Anlz {
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var c = bin.Cursor.initAlloc(a, buf);
        const header = try bin.takeStruct(&c, Header, .big);
        if (header.kind != .file) return error.InvalidFormat;
        if (header.size < 12 or header.total_size < header.size) return error.InvalidFormat;
        const header_data = try a.dupe(u8, try c.takeBytes(header.remaining_size()));
        const sections_region = try c.takeBytes(header.content_size());
        if (!c.atEnd()) return error.InvalidFormat;

        var sections = std.ArrayList(Content).empty;
        var sc = bin.Cursor.initAlloc(a, sections_region);
        while (!sc.atEnd()) {
            const section_header = try bin.takeStruct(&sc, Header, .big);
            try sections.append(a, try parseContent(&sc, a, section_header));
        }
        return .{
            .arena = arena,
            .header_data = header_data,
            .sections = sections.items,
        };
    }

    /// Frees the instance and every value parsed into it.
    pub fn deinit(m: *Anlz) void {
        const child = m.arena.child_allocator;
        m.arena.deinit();
        child.destroy(m.arena);
    }

    /// Serializes the file; the caller owns the returned bytes. All header
    /// sizes and count fields are derived from the data, so parsed files
    /// serialize byte-identical and modified files stay well-formed. A count
    /// or size that does not fit its wire field fails with `error.Overflow`.
    pub fn serialize(m: *const Anlz, alloc: std.mem.Allocator) WriteError![]u8 {
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try writeFile(&e, alloc, m.header_data, m.sections);
        return e.toOwnedSlice();
    }

    /// Returns the first section of the given kind, or null if the file
    /// contains none. The pointer reaches into this instance, so mutations
    /// through it are picked up by `serialize`.
    pub fn findSection(m: *const Anlz, kind: Kind) ?*Content {
        for (m.sections) |*section| {
            if (sectionKind(section) == kind) return section;
        }
        return null;
    }
};

const testing = std.testing;

/// Serializes `sections` into a full ANLZ image.
fn buildFile(alloc: std.mem.Allocator, header_data: []const u8, sections: []const Content) WriteError![]u8 {
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try writeFile(&e, alloc, header_data, sections);
    return e.toOwnedSlice();
}

/// Serializes raw section bytes (already including their headers) into a
/// full ANLZ image.
fn buildRawFile(alloc: std.mem.Allocator, header_data: []const u8, body: []const u8) bin.WriteError![]u8 {
    const header_data_len: u32 = @intCast(header_data.len);
    const body_len: u32 = @intCast(body.len);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, Header{
        .kind = .file,
        .size = 12 + header_data_len,
        .total_size = 12 + header_data_len + body_len,
    }, .big);
    try e.putBytes(header_data);
    try e.putBytes(body);
    return e.toOwnedSlice();
}

/// Emits a raw section (header plus `preamble` and `content` bytes).
fn buildRawSection(alloc: std.mem.Allocator, kind: Kind, preamble: []const u8, content: []const u8) bin.WriteError![]u8 {
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, Header{
        .kind = kind,
        .size = @intCast(12 + preamble.len),
        .total_size = @intCast(12 + preamble.len + content.len),
    }, .big);
    try e.putBytes(preamble);
    try e.putBytes(content);
    return e.toOwnedSlice();
}

/// Parses `input` and checks that it re-serializes byte-identical.
fn expectRoundtripBytes(alloc: std.mem.Allocator, input: []const u8) !void {
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();
    const output = try parsed.serialize(alloc);
    defer alloc.free(output);
    try testing.expectEqualSlices(u8, input, output);
}

/// Parses every `testdata` fixture whose basename starts with `ANLZ0000.`
/// and checks that it re-serializes byte-identical.
fn expectFixturesRoundtrip() !void {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "ANLZ0000.")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        var parsed = Anlz.parse(alloc, input) catch |err| {
            std.debug.print("failing fixture: {s} ({t})\n", .{ entry.path, err });
            return err;
        };
        defer parsed.deinit();
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        if (!std.mem.eql(u8, input, output)) std.debug.print("mismatching fixture: {s}\n", .{entry.path});
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }
    try testing.expect(count >= 6);
}

test "ANLZ fixtures roundtrip byte-identical" {
    try expectFixturesRoundtrip();
}

/// Reads a fixture from `testdata`.
fn readFixture(alloc: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, sub_path, alloc, std.Io.Limit.limited(1 << 20));
}

/// Path of the P053 `.DAT` fixture, relative to `testdata`.
const p053_dat = "complete_export/demo_tracks/PIONEER/USBANLZ/P053/0001D21F/ANLZ0000.DAT";

/// Path of the P053 `.EXT` fixture, relative to `testdata`.
const p053_ext = "complete_export/demo_tracks/PIONEER/USBANLZ/P053/0001D21F/ANLZ0000.EXT";

test "empty file roundtrips" {
    // Port of rekordcrate's anlz_new_empty_roundtrips: a file built from no
    // sections serializes, re-parses, and stays empty.
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const out = try buildFile(alloc, &file_header_data, &.{});
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 28), out.len);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.sections.len);

    const again = try parsed.serialize(alloc);
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, out, again);
    // The `PMAI` file header is derived on write.
    try testing.expectEqual(@as(u32, @intFromEnum(Kind.file)), std.mem.readInt(u32, again[0..4], .big));
}

test "derived headers roundtrip through content size" {
    // Port of rekordcrate's header_for_section_roundtrips_through_content_size:
    // the derived header of a section without preamble is `size` 12 and
    // `total_size` 12 + content, which the size accessors invert.
    const content = [_]u8{0} ** 100;
    const plain = try sectionHeader(.{ .unknown = .{
        .kind = @enumFromInt(fourcc("PQT2")),
        .content_data = &content,
    } });
    try testing.expectEqual(@as(u32, 12), plain.size);
    try testing.expectEqual(@as(u32, 112), plain.total_size);
    try testing.expectEqual(@as(u32, 100), plain.content_size());
    try testing.expectEqual(@as(u32, 0), plain.remaining_size());

    // A section with a 4-byte preamble keeps it in `remaining_size`.
    const vbr = try sectionHeader(.{ .vbr = .{ .data = &content } });
    try testing.expectEqual(@as(u32, 16), vbr.size);
    try testing.expectEqual(@as(u32, 116), vbr.total_size);
    try testing.expectEqual(@as(u32, 100), vbr.content_size());
    try testing.expectEqual(@as(u32, 4), vbr.remaining_size());
}

test "unknown section kinds roundtrip verbatim" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const path_raw = [6]u8{ 0x00, '/', 0x00, 'a', 0x00, 0x00 };
    var unknown_content = [6]u8{ 1, 2, 3, 4, 5, 6 };
    const sections = [_]Content{
        .{ .unknown = .{ .kind = @enumFromInt(fourcc("PQT2")), .header_data = &.{ 0xAA, 0xBB }, .content_data = &unknown_content } },
        .{ .path = .{ .path = .{ .raw = &path_raw } } },
    };

    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 28 + 20 + 22), out.len);
    try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.sections.len);
    try testing.expectEqual(@as(u32, 0x50515432), @intFromEnum(parsed.sections[0].unknown.kind));
    const unknown = parsed.sections[0].unknown;
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, unknown.header_data);
    try testing.expectEqualSlices(u8, &unknown_content, unknown.content_data);
    try testing.expectEqualSlices(u8, &path_raw, parsed.sections[1].path.path.raw);

    // Mutating the unknown section's raw bytes changes the output with the
    // input while still roundtripping.
    unknown_content[3] ^= 0xFF;
    const out3 = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out3);
    try expectRoundtripBytes(alloc, out3);
    try testing.expect(!std.mem.eql(u8, out, out3));
}

test "parse rejects malformed files" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const sections = [_]Content{
        .{ .vbr = .{ .unknown1 = 7, .data = &.{ 0x11, 0x22 } } },
    };
    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    // Wrong file magic.
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u32, bad[0..4], fourcc("XMAI"), .big);
    try testing.expectError(error.InvalidFormat, Anlz.parse(alloc, bad));

    // Truncated file: the PMAI header promises more bytes than remain.
    try testing.expectError(error.UnexpectedEof, Anlz.parse(alloc, out[0 .. out.len - 1]));

    // Trailing bytes beyond the PMAI total size.
    const long = try alloc.alloc(u8, out.len + 1);
    defer alloc.free(long);
    @memcpy(long[0..out.len], out);
    long[out.len] = 0;
    try testing.expectError(error.InvalidFormat, Anlz.parse(alloc, long));

    // Section sizes that would underflow the header accessors.
    std.mem.writeInt(u32, bad[0..4], fourcc("PMAI"), .big);
    std.mem.writeInt(u32, bad[4..8], 4, .big);
    try testing.expectError(error.InvalidFormat, Anlz.parse(alloc, bad));
}

test "parse rejects sections with inconsistent sizes" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };

    // Path whose stored length does not match the section content size:
    // prefix says 6 bytes, the section reserves 14.
    var path_preamble = [_]u8{0} ** 4;
    std.mem.writeInt(u32, path_preamble[0..4], 6, .big);
    const path_section = try buildRawSection(alloc, .path, &path_preamble, &([_]u8{0} ** 14));
    defer alloc.free(path_section);
    const path_file = try buildRawFile(alloc, &file_header_data, path_section);
    defer alloc.free(path_file);
    try testing.expectError(error.InvalidFormat, Anlz.parse(alloc, path_file));

    // Extended cue list with a nonzero unknown field.
    var ext_preamble = [_]u8{0} ** 8;
    std.mem.writeInt(u32, ext_preamble[0..4], 1, .big);
    std.mem.writeInt(u16, ext_preamble[6..8], 1, .big);
    const ext_body = try buildRawSection(alloc, .extended_cue_list, &ext_preamble, &.{});
    defer alloc.free(ext_body);
    const ext_file = try buildRawFile(alloc, &file_header_data, ext_body);
    defer alloc.free(ext_file);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, ext_file));

    // Song structure with an entry size other than 24.
    var pssi_preamble = [_]u8{0} ** 20;
    std.mem.writeInt(u32, pssi_preamble[0..4], 23, .big);
    std.mem.writeInt(u16, pssi_preamble[4..6], 1, .big);
    std.mem.writeInt(u16, pssi_preamble[6..8], 1, .big); // unencrypted mood
    const pssi_body = try buildRawSection(alloc, .song_structure, &pssi_preamble, &([_]u8{0} ** 24));
    defer alloc.free(pssi_body);
    const pssi_file = try buildRawFile(alloc, &file_header_data, pssi_body);
    defer alloc.free(pssi_file);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, pssi_file));

    // Waveform detail with an entry size other than 1.
    var pwv3_preamble = [_]u8{0} ** 12;
    std.mem.writeInt(u32, pwv3_preamble[0..4], 2, .big);
    const pwv3_body = try buildRawSection(alloc, .waveform_detail, &pwv3_preamble, &.{});
    defer alloc.free(pwv3_body);
    const pwv3_file = try buildRawFile(alloc, &file_header_data, pwv3_body);
    defer alloc.free(pwv3_file);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, pwv3_file));

    // Song structure whose phrase count does not match the content size.
    var pssi_preamble2 = [_]u8{0} ** 20;
    std.mem.writeInt(u32, pssi_preamble2[0..4], 24, .big);
    std.mem.writeInt(u16, pssi_preamble2[4..6], 2, .big);
    std.mem.writeInt(u16, pssi_preamble2[6..8], 1, .big);
    const pssi_body2 = try buildRawSection(alloc, .song_structure, &pssi_preamble2, &([_]u8{0} ** 24));
    defer alloc.free(pssi_body2);
    const pssi_file2 = try buildRawFile(alloc, &file_header_data, pssi_body2);
    defer alloc.free(pssi_file2);
    try testing.expectError(error.InvalidFormat, Anlz.parse(alloc, pssi_file2));
}

test "parse rejects non-canonical header sizes" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };

    // Beat grid whose header size is 20 instead of the canonical 24; the
    // total size is consistent, so only the size check catches it.
    const beat_grid = try buildRawSection(alloc, .beat_grid, &([_]u8{0} ** 12), &.{});
    defer alloc.free(beat_grid);
    std.mem.writeInt(u32, beat_grid[4..8], 20, .big);
    const grid_file = try buildRawFile(alloc, &file_header_data, beat_grid);
    defer alloc.free(grid_file);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, grid_file));

    // Cue list whose single entry announces a total length other than 56.
    var preamble = [_]u8{0} ** 12;
    std.mem.writeInt(u16, preamble[6..8], 1, .big); // one cue
    var entry = [_]u8{0} ** 57;
    std.mem.writeInt(u32, entry[0..4], fourcc("PCPT"), .big);
    std.mem.writeInt(u32, entry[4..8], 16, .big);
    std.mem.writeInt(u32, entry[8..12], 57, .big);
    const cue_list = try buildRawSection(alloc, .cue_list, &preamble, &entry);
    defer alloc.free(cue_list);
    const list_file = try buildRawFile(alloc, &file_header_data, cue_list);
    defer alloc.free(list_file);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, list_file));
}

test "song structure key bytes" {
    // Known answer from the P053 fixture: 11 phrase entries.
    const key = getKey(11);
    try testing.expectEqual(@as(u8, 0xD6), key[0]);
    try testing.expectEqual(@as(u8, 0xEC), key[1]);
}

test "song structure encryption detection" {
    // P053 fixture: raw mood d6ee with 11 entries decodes to `mid`.
    try testing.expect(checkIfEncrypted(&.{ 0xD6, 0xEE }, 11));
    // P016 fixture: raw mood def6 with 19 entries decodes to `mid`.
    try testing.expect(checkIfEncrypted(&.{ 0xDE, 0xF6 }, 19));
    // Unencrypted moods (valid as-is) are not detected as encrypted.
    try testing.expect(!checkIfEncrypted(&.{ 0x00, 0x01 }, 11));
    try testing.expect(!checkIfEncrypted(&.{ 0x00, 0x02 }, 19));
    try testing.expect(!checkIfEncrypted(&.{ 0x00, 0x03 }, 0));
    // Random garbage does not decode to a valid mood.
    try testing.expect(!checkIfEncrypted(&.{ 0xAB, 0xCD }, 11));
}

test "song structure roundtrips encrypted and plain" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var phrases = [_]Phrase{
        .{ .index = 1, .beat = 1, .kind = 1, .beat2 = 16, .fill = 1, .beat_fill = 14 },
        .{ .index = 2, .beat = 17, .kind = 2, .beat2 = 32 },
    };
    const data = SongStructureData{
        .mood = .mid,
        .unknown1 = 0x0102_0304,
        .end_beat = 32,
        .bank = .cool,
        .phrases = &phrases,
    };

    for ([_]bool{ true, false }) |is_encrypted| {
        const sections = [_]Content{.{
            .song_structure = .{ .is_encrypted = is_encrypted, .data = data },
        }};
        const out = try buildFile(alloc, &file_header_data, &sections);
        defer alloc.free(out);

        var parsed = try Anlz.parse(alloc, out);
        defer parsed.deinit();
        try testing.expectEqual(is_encrypted, parsed.sections[0].song_structure.is_encrypted);
        const ss = parsed.sections[0].song_structure;
        try testing.expectEqual(Mood.mid, ss.data.mood);
        try testing.expectEqual(Bank.cool, ss.data.bank);
        try testing.expectEqual(@as(u16, 32), ss.data.end_beat);
        try testing.expectEqual(@as(usize, 2), ss.data.phrases.len);
        try testing.expectEqualSlices(Phrase, &phrases, ss.data.phrases);

        const out2 = try parsed.serialize(alloc);
        defer alloc.free(out2);
        try testing.expectEqualSlices(u8, out, out2);
    }
}

test "beat grid and cue list with entries roundtrip" {
    try testing.expectEqual(@as(usize, 44), bin.serializedLen(Cue));
    try testing.expectEqual(@as(u32, 56), Cue.wire_len);
    try testing.expectEqual(@as(usize, 24), bin.serializedLen(Phrase));
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var beats = [_]Beat{
        .{ .beat_number = 1, .tempo = 12800, .time = 0 },
        .{ .beat_number = 2, .tempo = 12800, .time = 468 },
        .{ .beat_number = 3, .tempo = 12804, .time = 937 },
    };
    var cues = [_]Cue{
        .{},
        .{ .hot_cue = 1, .cue_type = .loop, .time = 1000, .loop_time = 2000, .order_first = 0xFFFF, .order_last = 0x0001 },
    };
    const sections = [_]Content{
        .{ .beat_grid = .{ .beats = &beats } },
        .{ .cue_list = .{ .list_type = .hot_cues, .memory_count = 0xFFFF_FFFF, .cues = &cues } },
    };

    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualSlices(Beat, &beats, parsed.sections[0].beat_grid.beats);
    const list = parsed.sections[1].cue_list;
    try testing.expectEqual(CueListType.hot_cues, list.list_type);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), list.memory_count);
    try testing.expectEqual(@as(usize, 2), list.cues.len);
    try testing.expectEqual(CueType.loop, list.cues[1].cue_type);
    try testing.expectEqual(@as(u32, 2000), list.cues[1].loop_time);
    try testing.expectEqual(@as(u32, 0x0010_0000), list.cues[1].unknown1);
}

test "writing more cues than the u16 len_cues field holds fails" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const cues = try alloc.alloc(Cue, 65536);
    defer alloc.free(cues);
    for (cues) |*cue| cue.* = .{};

    var sections = [_]Content{
        .{ .cue_list = .{ .list_type = .hot_cues, .memory_count = 0xFFFF_FFFF, .cues = cues[0..65535] } },
    };
    // The largest count that fits `len_cues` (u16) still roundtrips.
    const max = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(max);
    try expectRoundtripBytes(alloc, max);

    // One cue more must fail instead of truncating the count against the
    // derived `total_size`.
    sections[0].cue_list.cues = cues;
    try testing.expectError(error.Overflow, buildFile(alloc, &file_header_data, &sections));
}

test "cue list memory_count is derived and validated" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var cues = [_]Cue{.{ .time = 1000 }};
    const sections = [_]Content{
        .{ .cue_list = .{ .list_type = .memory_cues, .cues = &cues } },
    };
    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    // A non-empty memory list derives the entry count; a hot list derives
    // (and parses) the `0xFFFFFFFF` sentinel instead, whatever value the
    // struct field happens to hold.
    try testing.expectEqual(@as(u32, 1), parsed.sections[0].cue_list.memory_count);

    // A stored count that disagrees with the list type and length is
    // rejected on parse: the field sits at file offset 12 (`PMAI`) + 16
    // (header_data) + 12 (section header) + 8 (list_type, unknown,
    // len_cues).
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u32, bad[48..52], 5, .big);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, bad));
}

test "cue entries with newer 28-byte entry headers roundtrip" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var cues = [_]Cue{
        .{ .hot_cue = 1, .time = 0x0003_CA3B },
        .{ .hot_cue = 2, .time = 0x0000_011E },
    };
    const sections = [_]Content{
        .{ .cue_list = .{ .list_type = .hot_cues, .cues = &cues, .entry_header_size = 28 } },
    };
    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    const list = parsed.sections[0].cue_list;
    try testing.expectEqual(@as(u32, 28), list.entry_header_size);
    try testing.expectEqualSlices(Cue, &cues, list.cues);

    // Entries must share the style: patch the second entry's header size
    // (at 12 + 16 + 12 for the file and section headers, + 12 preamble, +
    // one 56-byte entry, + 4 for the entry tag) from 28 back to 16.
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u32, bad[112..116], 16, .big);
    try testing.expectError(error.UnexpectedValue, Anlz.parse(alloc, bad));
}

test "waveform sections roundtrip with checks" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var preview = [_]WaveformPreviewColumn{
        .{ .height = 0b10101, .whiteness = 0b110 },
        .{ .height = 31, .whiteness = 7 },
    };
    var tiny = [_]TinyWaveformPreviewColumn{.{ .height = 9, .unused = 3 }};
    var color_preview = [_]WaveformColorPreviewColumn{
        .{ .unknown1 = 1, .unknown2 = 2, .energy_bottom_half_freq = 3, .energy_bottom_third_freq = 4, .energy_mid_third_freq = 5, .energy_top_third_freq = 6 },
    };
    var color_detail = [_]WaveformColorDetailColumn{.{ .red = 5, .green = 3, .blue = 7, .height = 31, .unknown = 1 }};
    var band_preview = [_]Waveform3BandPreviewColumn{.{ .energy_mid_third_freq = 1, .energy_top_third_freq = 2, .energy_bottom_third_freq = 3 }};
    var band_detail = [_]Waveform3BandDetailColumn{.{ .energy_mid_third_freq = 4, .energy_top_third_freq = 5, .energy_bottom_third_freq = 6 }};
    const sections = [_]Content{
        .{ .waveform_preview = .{ .data = &preview } },
        .{ .tiny_waveform_preview = .{ .data = &tiny } },
        .{ .waveform_color_preview = .{ .data = &color_preview } },
        .{ .waveform_color_detail = .{ .data = &color_detail } },
        .{ .waveform_3band_preview = .{ .data = &band_preview } },
        .{ .waveform_3band_detail = .{ .data = &band_detail } },
    };

    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    // The packed bitfields land in the expected wire bits: height in the
    // five most significant bits, whiteness below.
    try testing.expectEqualSlices(u8, &.{ 0b10101_110, 0b11111_111 }, std.mem.sliceAsBytes(parsed.sections[0].waveform_preview.data));
    try testing.expectEqualSlices(u8, &.{0b0011_1001}, std.mem.sliceAsBytes(parsed.sections[1].tiny_waveform_preview.data));
    const cd = parsed.sections[3].waveform_color_detail.data[0];
    try testing.expectEqual(@as(u3, 5), cd.red);
    try testing.expectEqual(@as(u3, 3), cd.green);
    try testing.expectEqual(@as(u3, 7), cd.blue);
    try testing.expectEqual(@as(u5, 31), cd.height);
    try testing.expectEqual(@as(u2, 1), cd.unknown);
    try testing.expectEqualSlices(WaveformColorPreviewColumn, &color_preview, parsed.sections[2].waveform_color_preview.data);
    try testing.expectEqualSlices(Waveform3BandPreviewColumn, &band_preview, parsed.sections[4].waveform_3band_preview.data);
    try testing.expectEqualSlices(Waveform3BandDetailColumn, &band_detail, parsed.sections[5].waveform_3band_detail.data);
}

test "extended cue with empty comment roundtrips" {
    // Real ExtendedCue with an empty comment, extracted from a file
    // provided by @FizzyApple12 (ported from rekordcrate's test suite).
    const raw = [_]u8{
        0x50, 0x43, 0x50, 0x32, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x58, 0x00, 0x00,
        0x00, 0x04, 0x01, 0x00, 0x03, 0xe8, 0x00, 0x04, 0x62, 0xf7, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x4d, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc1, 0x70, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x30,
        0x77, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const alloc = testing.allocator;
    var c = bin.Cursor.initAlloc(alloc, &raw);
    const cue = try ExtendedCue.parse(&c, alloc);
    defer alloc.free(cue.trailing);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u32, 4), cue.hot_cue);
    try testing.expectEqual(CueType.point, cue.cue_type);
    try testing.expectEqual(@as(u32, 0x0004_62F7), cue.time);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), cue.loop_time);
    try testing.expectEqual(ColorIndex.none, cue.color);
    try testing.expectEqual(@as(u8, 1), cue.unknown3);
    try testing.expectEqual(@as(usize, 0), cue.comment.raw.len);
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x00, 0xFF }, &cue.hot_cue_color_rgb);
    try testing.expectEqual(@as(u32, 0x00C1_7000), cue.unknown7);
    try testing.expectEqual(@as(usize, 20), cue.trailing.len);

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try cue.writeTo(&e);
    try testing.expectEqualSlices(u8, &raw, e.written());
}

test "extended cue list with commented cue roundtrips" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const comment = try LenPrefixedWideString.fromUtf8(alloc, "Break");
    defer alloc.free(comment.raw);
    var cues = [_]ExtendedCue{
        .{ .hot_cue = 3, .time = 0x0004_62F7, .comment = comment, .hot_cue_color_rgb = .{ 0x4D, 0x00, 0xFF } },
    };
    const sections = [_]Content{.{
        .extended_cue_list = .{ .list_type = .hot_cues, .cues = &cues },
    }};

    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    const list = parsed.sections[0].extended_cue_list;
    try testing.expectEqual(@as(usize, 1), list.cues.len);
    const text = try list.cues[0].comment.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Break", text);
}

test "mutating parsed data re-serializes consistently" {
    const alloc = testing.allocator;
    const file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    var beats = [_]Beat{
        .{ .beat_number = 1, .tempo = 12800, .time = 0 },
        .{ .beat_number = 2, .tempo = 12800, .time = 468 },
    };
    const comment = try LenPrefixedWideString.fromUtf8(alloc, "Break");
    defer alloc.free(comment.raw);
    var cues = [_]ExtendedCue{
        .{ .hot_cue = 3, .time = 1000, .comment = comment },
    };
    const sections = [_]Content{
        .{ .beat_grid = .{ .beats = &beats } },
        .{ .extended_cue_list = .{ .list_type = .hot_cues, .cues = &cues } },
    };
    const out = try buildFile(alloc, &file_header_data, &sections);
    defer alloc.free(out);

    var parsed = try Anlz.parse(alloc, out);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    // Grow the beat grid by one beat and lengthen the cue comment; since
    // headers are derived from the data, both mutations re-serialize to a
    // consistent file.
    const grid = &parsed.sections[0].beat_grid;
    const grown = try arena.alloc(Beat, grid.beats.len + 1);
    @memcpy(grown[0..grid.beats.len], grid.beats);
    grown[grown.len - 1] = .{ .beat_number = 3, .tempo = 12804, .time = 937 };
    grid.beats = grown;

    const longer = try LenPrefixedWideString.fromUtf8(arena, "Breakdown");
    parsed.sections[1].extended_cue_list.cues[0].comment = longer;

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expect(modified.len > out.len);
    try expectRoundtripBytes(alloc, modified);

    var reparsed = try Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    try testing.expectEqual(@as(usize, 3), reparsed.sections[0].beat_grid.beats.len);
    const text = try reparsed.sections[1].extended_cue_list.cues[0].comment.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Breakdown", text);
}

test "mutating fixture beat grid tempo re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_dat);
    defer alloc.free(input);
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();

    const grid = &parsed.findSection(.beat_grid).?.beat_grid;
    try testing.expectEqual(@as(usize, 257), grid.beats.len);
    for (grid.beats) |*beat| beat.tempo += 1;

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    // Same beat count, same file size, different bytes.
    try testing.expectEqual(input.len, modified.len);
    try testing.expect(!std.mem.eql(u8, input, modified));

    var reparsed = try Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const beats = reparsed.findSection(.beat_grid).?.beat_grid.beats;
    try testing.expectEqualSlices(Beat, grid.beats, beats);
    try testing.expectEqual(@as(u16, 12001), beats[0].tempo);
}

test "mutating fixture cue list entries re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_dat);
    defer alloc.free(input);
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    // The fixture's hot cue list is empty; `len_cues` is derived on write,
    // and `memory_count` keeps the hot-cue sentinel.
    const list = &parsed.findSection(.cue_list).?.cue_list;
    try testing.expectEqual(CueListType.hot_cues, list.list_type);
    try testing.expectEqual(@as(usize, 0), list.cues.len);

    // Add two cues: the file grows by one wire entry each.
    const cues = try arena.alloc(Cue, 2);
    cues[0] = .{ .hot_cue = 1, .time = 0x0004_62F7 };
    cues[1] = .{ .hot_cue = 2, .cue_type = .loop, .time = 1000, .loop_time = 2000 };
    list.cues = cues;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    try testing.expectEqual(input.len + 2 * Cue.wire_len, grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed = try Anlz.parse(alloc, grown);
    defer reparsed.deinit();
    const grown_list = reparsed.findSection(.cue_list).?.cue_list;
    try testing.expectEqualSlices(Cue, cues, grown_list.cues);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), grown_list.memory_count);

    // Modify the first cue: the file size stays, the entry changes.
    cues[0].time += 500;
    const tweaked = try parsed.serialize(alloc);
    defer alloc.free(tweaked);
    try testing.expectEqual(grown.len, tweaked.len);

    var reparsed2 = try Anlz.parse(alloc, tweaked);
    defer reparsed2.deinit();
    const tweaked_cues = reparsed2.findSection(.cue_list).?.cue_list.cues;
    try testing.expectEqualSlices(Cue, cues, tweaked_cues);
    try testing.expectEqual(@as(u32, 0x0004_62F7 + 500), tweaked_cues[0].time);

    // Remove one cue, then the other: the derived count shrinks the file
    // back to the original bytes.
    list.cues = cues[0..1];
    const shrunk = try parsed.serialize(alloc);
    defer alloc.free(shrunk);
    try testing.expectEqual(input.len + Cue.wire_len, shrunk.len);

    var reparsed3 = try Anlz.parse(alloc, shrunk);
    defer reparsed3.deinit();
    try testing.expectEqualSlices(Cue, cues[0..1], reparsed3.findSection(.cue_list).?.cue_list.cues);

    list.cues = &.{};
    const restored = try parsed.serialize(alloc);
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, input, restored);
}

test "mutating fixture extended cue comment re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_ext);
    defer alloc.free(input);
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    const list = &parsed.findSection(.extended_cue_list).?.extended_cue_list;
    try testing.expectEqual(@as(usize, 0), list.cues.len);

    // Add a cue whose comment grows the entry beyond its 68 fixed bytes.
    const cues = try arena.alloc(ExtendedCue, 1);
    cues[0] = .{
        .hot_cue = 1,
        .time = 0x0004_62F7,
        .comment = try LenPrefixedWideString.fromUtf8(arena, "Break"),
    };
    list.cues = cues;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    // 68 fixed bytes plus the 12 comment bytes ("Break" + NUL, UTF-16BE).
    try testing.expectEqual(input.len + 68 + 12, grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed = try Anlz.parse(alloc, grown);
    defer reparsed.deinit();
    const grown_list = reparsed.findSection(.extended_cue_list).?.extended_cue_list;
    try testing.expectEqual(@as(usize, 1), grown_list.cues.len);
    const text = try grown_list.cues[0].comment.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Break", text);

    // Growing the comment text grows the entry byte for byte.
    cues[0].comment = try LenPrefixedWideString.fromUtf8(arena, "Breakdown!");
    const longer = try parsed.serialize(alloc);
    defer alloc.free(longer);
    try testing.expectEqual(grown.len + 10, longer.len);

    // Clearing the comment shrinks the cue back to its fixed size.
    cues[0].comment = .{};
    const cleared = try parsed.serialize(alloc);
    defer alloc.free(cleared);
    try testing.expectEqual(input.len + 68, cleared.len);
    try expectRoundtripBytes(alloc, cleared);

    var reparsed2 = try Anlz.parse(alloc, cleared);
    defer reparsed2.deinit();
    const cleared_cue = &reparsed2.findSection(.extended_cue_list).?.extended_cue_list.cues[0];
    try testing.expectEqual(@as(usize, 0), cleared_cue.comment.raw.len);
    const empty_text = try cleared_cue.comment.utf8(alloc);
    defer alloc.free(empty_text);
    try testing.expectEqualStrings("", empty_text);
}

test "mutating fixture path re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_dat);
    defer alloc.free(input);
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();

    const section = parsed.findSection(.path).?;
    const original = try section.path.path.utf8(alloc);
    defer alloc.free(original);
    try testing.expectEqualStrings("/Contents/Loopmasters/UnknownAlbum/Demo Track 2.mp3", original);
    const old_len = section.path.path.byte_len();

    section.path.path = try LenPrefixedWideString.fromUtf8(parsed.arena.allocator(), "/Contents/mutated.mp3");
    const new_len = section.path.path.byte_len();
    try testing.expect(new_len < old_len);

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expectEqual(input.len - old_len + new_len, modified.len);
    try expectRoundtripBytes(alloc, modified);

    var reparsed = try Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const text = try reparsed.findSection(.path).?.path.path.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("/Contents/mutated.mp3", text);
}

test "mutating fixture song structure re-encrypts" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_ext);
    defer alloc.free(input);
    var parsed = try Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    const ss = &parsed.findSection(.song_structure).?.song_structure;
    try testing.expect(ss.is_encrypted);
    try testing.expectEqual(Mood.mid, ss.data.mood);
    try testing.expectEqual(@as(usize, 11), ss.data.phrases.len);

    // Same-length mutations: the output must be re-obfuscated with the key
    // so that it decodes again on re-parse.
    ss.data.mood = .low;
    ss.data.phrases[0].beat += 1;
    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expectEqual(input.len, modified.len);
    try testing.expect(!std.mem.eql(u8, input, modified));

    var reparsed = try Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const ss2 = &reparsed.findSection(.song_structure).?.song_structure;
    try testing.expect(ss2.is_encrypted);
    try testing.expectEqual(Mood.low, ss2.data.mood);
    try testing.expectEqualSlices(Phrase, ss.data.phrases, ss2.data.phrases);

    // Growing the phrase list changes the entry count, and with it the XOR
    // key; the re-obfuscated section must decode with the new key.
    const phrases = try arena.alloc(Phrase, ss.data.phrases.len + 1);
    @memcpy(phrases[0 .. phrases.len - 1], ss.data.phrases);
    phrases[phrases.len - 1] = .{ .index = 12, .beat = ss.data.phrases[ss.data.phrases.len - 1].beat + 16 };
    ss.data.phrases = phrases;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    try testing.expectEqual(modified.len + bin.serializedLen(Phrase), grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed2 = try Anlz.parse(alloc, grown);
    defer reparsed2.deinit();
    const ss3 = &reparsed2.findSection(.song_structure).?.song_structure;
    try testing.expect(ss3.is_encrypted);
    try testing.expectEqual(Mood.low, ss3.data.mood);
    try testing.expectEqualSlices(Phrase, phrases, ss3.data.phrases);
}

test "length-prefixed wide strings roundtrip" {
    const alloc = testing.allocator;

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try (LenPrefixedWideString{}).encode(&e);
    var ws = try LenPrefixedWideString.fromUtf8(alloc, "Ära");
    defer alloc.free(ws.raw);
    try ws.encode(&e);
    try testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, // empty: length 0, no payload
        0,    0,    0,    8, // "(3 + 1) * 2" bytes follow
        0x00, 0xC4, 0x00, 'r',
        0x00, 'a',  0x00, 0x00,
    }, e.written());
    try testing.expectEqual(@as(u32, 8), ws.byte_len());

    var c = bin.Cursor.initAlloc(alloc, e.written());
    const empty = try LenPrefixedWideString.decode(&c);
    try testing.expectEqual(@as(usize, 0), empty.raw.len);
    const again = try LenPrefixedWideString.decode(&c);
    defer alloc.free(again.raw);
    try testing.expectEqualSlices(u8, ws.raw, again.raw);
    try testing.expect(c.atEnd());

    const text = try again.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Ära", text);
}

test "length-prefixed wide string rejects odd payload lengths" {
    const odd = LenPrefixedWideString{ .raw = &.{ 0, 'A', 0 } };
    try testing.expectError(error.UnexpectedValue, odd.utf8(testing.allocator));
}

test "length-prefixed wide string through the struct walker" {
    const alloc = testing.allocator;
    const Sample = struct {
        prefix: u8 = 0,
        text: LenPrefixedWideString = .{},
        suffix: u8 = 0,
    };

    const ws = try LenPrefixedWideString.fromUtf8(alloc, "Hi");
    defer alloc.free(ws.raw);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, Sample{ .prefix = 1, .text = ws, .suffix = 2 }, .big);
    try testing.expectEqualSlices(u8, &.{
        1, 0, 0, 0, 6, 0, 'H', 0, 'i', 0, 0, 2,
    }, e.written());

    var c = bin.Cursor.initAlloc(alloc, e.written());
    const s = try bin.takeStruct(&c, Sample, .big);
    defer alloc.free(s.text.raw);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u8, 1), s.prefix);
    try testing.expectEqualSlices(u8, ws.raw, s.text.raw);
    try testing.expectEqual(@as(u8, 2), s.suffix);
}
