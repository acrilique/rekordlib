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
const bin = @import("bin.zig");
const util = @import("util.zig");
const xor = @import("xor.zig");

pub const ParseError = error{ UnexpectedEof, OutOfMemory, InvalidFormat, UnexpectedValue };

pub const WriteError = bin.WriteError || error{Overflow};

/// Narrows `n` to `T`, failing with `Overflow` instead of truncating.
fn narrow(comptime T: type, n: usize) WriteError!T {
    return std.math.cast(T, n) orelse error.Overflow;
}

/// Packs a four character code into a big-endian u32 tag.
pub fn fourcc(comptime tag: *const [4]u8) u32 {
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
pub const Header = struct {
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
    /// Unknown field, zero in all known files (stored verbatim).
    unknown1: u32 = 0,
    /// Unknown field, `0x00080000` in all known files (stored verbatim).
    unknown2: u32 = 0x0008_0000,
    /// Beats of this beatgrid. The `len_beats` count is recomputed from this
    /// slice on write.
    beats: []Beat = &.{},

    const kind: Kind = .beat_grid;
    const header_size: u32 = 24;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!BeatGrid {
        if (header.size != header_size) return error.UnexpectedValue;
        const unknown1 = try c.takeInt(u32, .big);
        const unknown2 = try c.takeInt(u32, .big);
        const len_beats = try c.takeInt(u32, .big);
        if (@as(u64, len_beats) * bin.serializedLen(Beat) != header.content_size()) return error.InvalidFormat;
        const beats = try bin.takeStructSlice(alloc, c, Beat, .big, len_beats);
        return .{ .unknown1 = unknown1, .unknown2 = unknown2, .beats = beats };
    }

    fn contentLen(bg: *const BeatGrid) usize {
        return bin.serializedLen(Beat) * bg.beats.len;
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
    /// Unknown field, `0x00010000` in all known files (stored verbatim).
    unknown1: u32 = 0x0001_0000,
    /// Somehow used for sorting cues (`0xFFFF` for the first cue).
    order_first: u16 = 0xFFFF,
    /// Somehow used for sorting cues (`0xFFFF` for the last cue).
    order_last: u16 = 0xFFFF,
    /// Type of this cue (`loop` if this cue is a loop).
    cue_type: CueType = .point,
    /// Unknown field, zero in all known files (stored verbatim).
    unknown2: u8 = 0,
    /// Unknown field, `0x03E8` (= decimal 1000) in all known files (stored
    /// verbatim).
    unknown3: u16 = 0x03E8,
    /// Time in milliseconds after which this cue would occur (at normal
    /// playback speed).
    time: u32 = 0,
    /// Time in milliseconds at which the loop jumps back to `time` (at
    /// normal playback speed).
    loop_time: u32 = 0xFFFF_FFFF,
    unknown4: u32 = 0,
    unknown5: u32 = 0,
    unknown6: u32 = 0,
    unknown7: u32 = 0,

    /// Length of a serialized entry, its nested header included.
    pub const wire_len = 12 + bin.serializedLen(Cue);

    /// Parses one entry. `header_size` learns the nested header's `size`
    /// style from the first entry; later entries must share it.
    pub fn parse(c: *bin.Cursor, header_size: *?u32) ParseError!Cue {
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

/// Entry count that a `CueList.memory_count` field must hold: the number of
/// cues in a non-empty memory cue list, the `0xFFFFFFFF` sentinel in hot cue
/// lists and empty lists.
fn derivedMemoryCount(list_type: CueListType, len_cues: usize) usize {
    return if (list_type == .memory_cues and len_cues > 0) len_cues else 0xFFFF_FFFF;
}

/// List of cue points or loops (either hot cues or memory cues).
pub const CueList = struct {
    /// The types of cues (memory or hot) that this list contains.
    list_type: CueListType = .memory_cues,
    /// Unknown field, zero in all known files (stored verbatim).
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

    const kind: Kind = .cue_list;
    const header_size: u32 = 24;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!CueList {
        if (header.size != header_size) return error.UnexpectedValue;
        const list_type: CueListType = @enumFromInt(try c.takeInt(u32, .big));
        const unknown = try c.takeInt(u16, .big);
        const len_cues = try c.takeInt(u16, .big);
        const memory_count = try c.takeInt(u32, .big);
        if (memory_count != derivedMemoryCount(list_type, len_cues)) return error.UnexpectedValue;
        // Each entry occupies exactly `Cue.wire_len` bytes; a count whose
        // entries cannot fit the section is rejected before anything is
        // allocated (the `takeStructSlice` discipline).
        if (@as(u64, len_cues) * Cue.wire_len > c.remaining()) return error.UnexpectedEof;
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

    fn contentLen(cl: *const CueList) usize {
        return Cue.wire_len * cl.cues.len;
    }

    fn writeTo(cl: *const CueList, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, @intFromEnum(cl.list_type), .big);
        try e.putInt(u16, cl.unknown, .big);
        try e.putInt(u16, try narrow(u16, cl.cues.len), .big);
        try e.putInt(u32, try narrow(u32, derivedMemoryCount(cl.list_type, cl.cues.len)), .big);
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
    /// Unknown field, zero in all known files (stored verbatim).
    unknown1: u8 = 0,
    /// Unknown field, `0x03E8` (= decimal 1000) in all known files (stored
    /// verbatim).
    unknown2: u16 = 0x03E8,
    /// Time in milliseconds after which this cue would occur (at normal
    /// playback speed).
    time: u32 = 0,
    /// Time in milliseconds at which the loop jumps back to `time` (at
    /// normal playback speed).
    loop_time: u32 = 0xFFFF_FFFF,
    /// Color assigned to this cue. Only used by memory cues; hot cues use a
    /// different value (see `hot_cue_color_index`).
    color: util.ColorIndex = .none,
    /// Unknown field, `1` in all known files (stored verbatim).
    unknown3: u8 = 1,
    unknown4: u16 = 0,
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
    unknown6: u32 = 0,
    /// Unknown field, `0x00C17000` in all known files (stored verbatim).
    unknown7: u32 = 0x00C1_7000,
    unknown8: u32 = 0,
    unknown9: u32 = 0,
    unknown10: u32 = 0,
    /// Trailing unknown bytes after `unknown10` to the end of the entry:
    /// `total_size - 68 - comment byte_len` bytes.
    trailing: []const u8 = &.{},

    /// Fixed size of a serialized entry: the 12-byte nested `PCP2` header
    /// plus 56 bytes of fields, the comment's 4-byte length prefix included
    /// (its payload and the trailing bytes are variable).
    const fixed_wire_len = 68;

    /// Length of a serialized entry, its nested header, comment payload,
    /// and trailing bytes included.
    fn wireLen(cue: *const ExtendedCue) usize {
        return fixed_wire_len + cue.comment.raw.len + cue.trailing.len;
    }

    pub fn parse(c: *bin.Cursor, alloc: std.mem.Allocator) ParseError!ExtendedCue {
        const header = try bin.takeStruct(c, Header, .big);
        if (header.kind != .extended_cue or header.size != 16) return error.UnexpectedValue;
        var cue = try bin.takeStruct(c, ExtendedCue, .big);
        const fixed_len: usize = fixed_wire_len + cue.comment.raw.len;
        if (header.total_size < fixed_len) return error.InvalidFormat;
        cue.trailing = try alloc.dupe(u8, try c.takeBytes(@as(usize, header.total_size) - fixed_len));
        return cue;
    }

    pub fn writeTo(cue: *const ExtendedCue, e: *bin.Emitter) WriteError!void {
        try bin.putStruct(e, Header{
            .kind = .extended_cue,
            .size = 16,
            .total_size = try narrow(u32, cue.wireLen()),
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

    const kind: Kind = .extended_cue_list;
    const header_size: u32 = 20;

    /// Fields that must hold their default value in all known files;
    /// other values are rejected on parse (see `bin.validateConstantFields`).
    pub const constant_fields = .{.unknown};

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!ExtendedCueList {
        if (header.size != header_size) return error.UnexpectedValue;
        const list_type: CueListType = @enumFromInt(try c.takeInt(u32, .big));
        const len_cues = try c.takeInt(u16, .big);
        const unknown = try c.takeInt(u16, .big);
        try bin.validateConstantFields(ExtendedCueList, .{ .list_type = list_type, .unknown = unknown });
        // Entries are at least `fixed_wire_len` bytes each, their comment
        // payload and trailing bytes add more; a count whose entries cannot
        // fit the section is rejected before anything is allocated.
        if (@as(u64, len_cues) * ExtendedCue.fixed_wire_len > c.remaining()) return error.UnexpectedEof;
        const cues = try alloc.alloc(ExtendedCue, len_cues);
        for (cues) |*cue| cue.* = try ExtendedCue.parse(c, alloc);
        return .{ .list_type = list_type, .unknown = unknown, .cues = cues };
    }

    fn contentLen(cl: *const ExtendedCueList) usize {
        var len: usize = 0;
        for (cl.cues) |*cue| len += cue.wireLen();
        return len;
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

    const kind: Kind = .path;
    const header_size: u32 = 16;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Path {
        _ = alloc;
        if (header.size != header_size) return error.UnexpectedValue;
        const p = try bin.takeStruct(c, Path, .big);
        if (p.path.raw.len != header.content_size()) return error.InvalidFormat;
        return p;
    }

    fn contentLen(p: *const Path) usize {
        return p.path.byte_len();
    }

    fn writeTo(p: *const Path, e: *bin.Emitter) WriteError!void {
        try bin.putStruct(e, p, .big);
    }
};

/// Seek information for variable bitrate files.
pub const Vbr = struct {
    unknown1: u32 = 0,
    /// Unknown data blob, the raw section content.
    data: []const u8 = &.{},

    const kind: Kind = .vbr;
    const header_size: u32 = 16;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Vbr {
        if (header.size != header_size) return error.UnexpectedValue;
        const unknown1 = try c.takeInt(u32, .big);
        const data = try alloc.dupe(u8, try c.takeBytes(header.content_size()));
        return .{ .unknown1 = unknown1, .data = data };
    }

    fn contentLen(v: *const Vbr) usize {
        return v.data.len;
    }

    fn writeTo(v: *const Vbr, e: *bin.Emitter) WriteError!void {
        try e.putInt(u32, v.unknown1, .big);
        try e.putBytes(v.data);
    }
};

/// Single column of a `waveform_preview`/`waveform_detail` section.
///
/// The wire byte packs the height into the five least significant bits and
/// the whiteness into the three most significant bits; because Zig packs
/// struct fields starting at the least significant bit, the fields are
/// declared in wire bit order.
pub const WaveformPreviewColumn = packed struct(u8) {
    /// Height of the column in pixels.
    height: u5 = 0,
    /// Shade of white.
    whiteness: u3 = 0,
};

/// Single column of a `tiny_waveform_preview` section. The wire byte packs
/// the height into the four least significant bits (see
/// `WaveformPreviewColumn` for the field order); the upper four bits are
/// unused.
pub const TinyWaveformPreviewColumn = packed struct(u8) {
    /// Height of the column in pixels.
    height: u4 = 0,
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

/// Single column of a `waveform_3band_preview` or `waveform_3band_detail`
/// section.
pub const Waveform3BandColumn = struct {
    /// Sound energy in the mid of the frequency range.
    energy_mid_third_freq: u8 = 0,
    /// Sound energy in the top of the frequency range.
    energy_top_third_freq: u8 = 0,
    /// Sound energy in the bottom third of the frequency range.
    energy_bottom_third_freq: u8 = 0,
};

/// Comptime shape of a waveform section, as consumed by `WaveformSection`.
const WaveformSpec = struct {
    /// Kind of the generated section.
    kind: Kind,
    /// Type of a single waveform column.
    column: type,
    /// Value of the `len_entry_bytes` preamble field, the wire size of one
    /// column. `null` for the two oldest preview sections, whose preamble
    /// carries only the column count (their columns are one byte each).
    entry_bytes: ?u32 = null,
    /// Default value of the trailing unknown preamble field. `null` if the
    /// section has no such field.
    unknown: ?u32 = null,
    /// Whether the unknown preamble field must hold its default value in all
    /// known files; other values are rejected on parse (rekordcrate asserts
    /// on read). Otherwise the field is stored verbatim.
    constant_unknown: bool = false,
};

/// Generates one of the waveform section types: the preamble described by
/// `spec`, followed by a run of `spec.column` entries. The waveform kinds
/// differ only in their column type and preamble shape; all parse and write
/// logic is shared here.
fn WaveformSection(comptime spec: WaveformSpec) type {
    const Column = spec.column;
    if (spec.entry_bytes) |entry_bytes| {
        if (entry_bytes != bin.serializedLen(Column))
            @compileError("WaveformSection: entry_bytes must match the serialized length of column");
    } else if (bin.serializedLen(Column) != 1) {
        @compileError("WaveformSection: sections without entry_bytes need one-byte columns");
    }
    return struct {
        const Self = @This();

        const kind: Kind = spec.kind;
        const header_size: u32 = 12 + 4 + (if (spec.entry_bytes != null) 4 else 0) + (if (spec.unknown != null) 4 else 0);

        /// Unknown preamble field, stored verbatim (see the section alias
        /// for the value found in known files). Virtual when the spec has no
        /// such field: it stays at its default and is never serialized.
        unknown: u32 = spec.unknown orelse 0,
        /// Waveform column data; the entry count is recomputed from this
        /// slice on write.
        data: []Column = &.{},

        fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Self {
            if (header.size != header_size) return error.UnexpectedValue;
            if (spec.entry_bytes) |entry_bytes| {
                const len_entry_bytes = try c.takeInt(u32, .big);
                if (len_entry_bytes != entry_bytes) return error.UnexpectedValue;
            }
            const len_entries = try c.takeInt(u32, .big);
            const column_bytes: u64 = spec.entry_bytes orelse 1;
            if (column_bytes * len_entries != header.content_size()) return error.InvalidFormat;
            const unknown: u32 = if (spec.unknown != null) try c.takeInt(u32, .big) else 0;
            if (spec.unknown) |default| {
                if (spec.constant_unknown and unknown != default) return error.UnexpectedValue;
            }
            return .{
                .unknown = unknown,
                .data = try bin.takeStructSlice(alloc, c, Column, .big, len_entries),
            };
        }

        fn contentLen(w: *const Self) usize {
            return bin.serializedLen(Column) * w.data.len;
        }

        fn writeTo(w: *const Self, e: *bin.Emitter) WriteError!void {
            if (spec.entry_bytes) |entry_bytes| try e.putInt(u32, entry_bytes, .big);
            try e.putInt(u32, try narrow(u32, w.data.len), .big);
            if (spec.unknown != null) try e.putInt(u32, w.unknown, .big);
            for (w.data) |*column| try bin.putStruct(e, column, .big);
        }
    };
}

/// Fixed-width monochrome preview of the track waveform.
pub const WaveformPreview = WaveformSection(.{
    .kind = .waveform_preview,
    .column = WaveformPreviewColumn,
    .unknown = 0x0001_0000,
});

/// Smaller version of the fixed-width monochrome preview of the track
/// waveform (for the CDJ-900).
pub const TinyWaveformPreview = WaveformSection(.{
    .kind = .tiny_waveform_preview,
    .column = TinyWaveformPreviewColumn,
    .unknown = 0x0001_0000,
});

/// Variable-width large monochrome version of the track waveform, in `.EXT`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const WaveformDetail = WaveformSection(.{
    .kind = .waveform_detail,
    .column = WaveformPreviewColumn,
    .entry_bytes = 1,
    .unknown = 0x0096_0000,
    .constant_unknown = true,
});

/// Fixed-width colored preview of the track waveform, in `.EXT` files.
pub const WaveformColorPreview = WaveformSection(.{
    .kind = .waveform_color_preview,
    .column = WaveformColorPreviewColumn,
    .entry_bytes = 6,
    .unknown = 0,
});

/// Variable-width large colored version of the track waveform, in `.EXT`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const WaveformColorDetail = WaveformSection(.{
    .kind = .waveform_color_detail,
    .column = WaveformColorDetailColumn,
    .entry_bytes = 2,
    .unknown = 0x0096_0305,
});

/// Fixed-width 3-band preview of the track waveform, in `.2EX` files.
pub const Waveform3BandPreview = WaveformSection(.{
    .kind = .waveform_3band_preview,
    .column = Waveform3BandColumn,
    .entry_bytes = 3,
});

/// Variable-width large 3-band version of the track waveform, in `.2EX`
/// files. Each entry represents one half-frame of audio data, so there are
/// 150 entries per second of track audio.
pub const Waveform3BandDetail = WaveformSection(.{
    .kind = .waveform_3band_detail,
    .column = Waveform3BandColumn,
    .entry_bytes = 3,
    .unknown = 0x0096_0000,
    .constant_unknown = true,
});

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
    unknown1: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k1: u8 = 0,
    unknown2: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k2: u8 = 0,
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
    unknown4: u8 = 0,
    /// Flag byte used for numbered variations (in case of the `high` mood).
    ///
    /// See <https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html#high-phrase-variants>
    k3: u8 = 0,
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
    unknown1: u32 = 0,
    unknown2: u16 = 0,
    /// Number of the beat at which the last recognized phrase ends.
    end_beat: u16 = 0,
    unknown3: u16 = 0,
    /// Stylistic bank assigned in Lighting Mode.
    bank: Bank = .default,
    unknown4: u8 = 0,
    /// Phrase entries. The `len_entries` count is recomputed from this
    /// slice on write (and feeds the XOR key).
    phrases: []Phrase = &.{},

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, len_entries: u16) ParseError!SongStructureData {
        var out = try bin.takeStruct(c, SongStructureData, .big);
        out.phrases = try bin.takeStructSlice(alloc, c, Phrase, .big, len_entries);
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
pub fn getKey(len_entries: u16) [19]u8 {
    var key: [19]u8 = undefined;
    for (KEY_DATA, 0..) |byte, i| key[i] = @truncate(@as(u16, byte) +% len_entries);
    return key;
}

/// A song structure is considered encrypted when the first two key bytes
/// XOR-decode the raw `mood` field to a valid mood.
pub fn checkIfEncrypted(span: []const u8, len_entries: u16) bool {
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

    const kind: Kind = .song_structure;
    const header_size: u32 = 32;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!SongStructure {
        if (header.size != header_size) return error.UnexpectedValue;
        const len_entry_bytes = try c.takeInt(u32, .big);
        if (len_entry_bytes != bin.serializedLen(Phrase)) return error.UnexpectedValue;
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

    fn contentLen(ss: *const SongStructure) usize {
        return bin.serializedLen(Phrase) * ss.data.phrases.len;
    }

    fn writeTo(ss: *const SongStructure, e: *bin.Emitter) WriteError!void {
        const len_entries: u16 = try narrow(u16, ss.data.phrases.len);
        try e.putInt(u32, @intCast(bin.serializedLen(Phrase)), .big);
        try e.putInt(u16, len_entries, .big);
        var data_out = bin.Emitter.init(e.alloc);
        defer data_out.deinit();
        try ss.data.writeTo(&data_out);
        const bytes = try data_out.toOwnedSlice();
        defer e.alloc.free(bytes);
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

// Content types must declare pairwise distinct `kind`s: `parseContent`
// dispatches on first match, so a duplicate would silently parse one
// type's bytes as another while `sectionHeader` still writes the kind and
// sizes of the type that declared it.
comptime {
    const fields = std.meta.fields(Content);
    for (fields, 0..) |a, i| {
        if (a.type == Unknown) continue;
        for (fields[i + 1 ..]) |b| {
            if (b.type == Unknown) continue;
            if (a.type.kind == b.type.kind)
                @compileError(
                    "content types " ++ @typeName(a.type) ++ " and " ++
                        @typeName(b.type) ++ " declare the same section kind",
                );
        }
    }
}

/// Parses the content of one section from `c` (positioned right after the
/// section's 12-byte header). The section's bytes are bounded to its
/// declared `total_size` and must be consumed exactly; a mismatch is
/// reported as `InvalidFormat`. Each content type parses the `kind` it
/// declares; the entry kinds (`file`, `cue`, `extended_cue`) only appear
/// nested inside cue lists, so a stray one matches no type and is kept
/// verbatim, like any unknown tag.
fn parseContent(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Content {
    if (header.size < 12 or header.total_size < header.size) return error.InvalidFormat;
    const region = try c.takeBytes(header.total_size - 12);
    var sub = bin.Cursor.initAlloc(alloc, region);
    const content: Content = inline for (std.meta.fields(Content)) |field| {
        const T = field.type;
        if (T == Unknown) continue;
        if (T.kind == header.kind) break @unionInit(Content, field.name, try T.parse(&sub, alloc, header));
    } else .{ .unknown = try Unknown.parse(&sub, alloc, header) };
    if (!sub.atEnd()) return error.InvalidFormat;
    return content;
}

/// The kind a section's content serializes as: every content type declares
/// its `kind` (unknown content keeps the kind it was parsed with).
fn sectionKind(content: *const Content) Kind {
    return switch (content.*) {
        .unknown => |u| u.kind,
        inline else => |x| @TypeOf(x).kind,
    };
}

/// Derives the wire header of `content`: every section type declares its
/// `kind` and canonical `header_size` and provides a `contentLen` method,
/// so the header follows from the content; unknown sections keep their
/// parsed kind and follow the blob lengths. Deriving headers from the data
/// rather than storing parsed values keeps files consistent when parsed
/// content is modified.
pub fn sectionHeader(content: Content) WriteError!Header {
    return switch (content) {
        .unknown => |x| .{
            .kind = x.kind,
            .size = try narrow(u32, 12 + x.header_data.len),
            .total_size = try narrow(u32, 12 + x.header_data.len + x.content_data.len),
        },
        inline else => |x| blk: {
            const T = @TypeOf(x);
            break :blk .{
                .kind = T.kind,
                .size = T.header_size,
                .total_size = try narrow(u32, T.header_size + x.contentLen()),
            };
        },
    };
}

/// Writes one section: its derived header followed by the content.
fn writeSection(content: Content, e: *bin.Emitter) WriteError!void {
    try bin.putStruct(e, try sectionHeader(content), .big);
    switch (content) {
        inline else => |x| try x.writeTo(e),
    }
}

/// The 16-byte preamble following the 12-byte `PMAI` prefix, observed on
/// every known file. Meaning unknown; Rekordbox writes this exact
/// sequence, and the device writer emits it for the files it builds.
pub const file_header_data = [16]u8{
    0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// Writes a whole file: the `PMAI` header, `header_data`, and the sections,
/// with every size derived from the content. The file header's `total_size`
/// is patched in after the sections, since only then is it known.
fn writeFile(e: *bin.Emitter, header_data: []const u8, sections: []const Content) WriteError!void {
    const file_start = e.pos();
    try bin.putStruct(e, Header{
        .kind = .file,
        .size = try narrow(u32, 12 + header_data.len),
        .total_size = 0,
    }, .big);
    try e.putBytes(header_data);
    for (sections) |content| try writeSection(content, e);
    // `total_size` sits eight bytes into the header, behind `kind` and `size`.
    e.patchIntAt(file_start + 8, u32, try narrow(u32, e.pos() - file_start), .big);
}

/// Serializes a whole file into an owned ANLZ image; the caller owns the
/// returned bytes.
pub fn serializeFile(alloc: std.mem.Allocator, header_data: []const u8, sections: []const Content) WriteError![]u8 {
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try writeFile(&e, header_data, sections);
    return e.toOwnedSlice();
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
        return serializeFile(alloc, m.header_data, m.sections);
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

// ---------------------------------------------------------------------------
// Building ANLZ files from scratch
// ---------------------------------------------------------------------------

pub const BuildError = error{ OutOfMemory, InvalidUtf8 };

/// Detail section columns per second (PWV3/PWV5/PWV7). Pinned by the
/// format: 75 frames/sec × 2.
pub const DETAIL_HZ: f64 = 150.0;

/// Columns of the mono preview (`PWAV`). Fixed by the format: every ANLZ
/// fixture carries exactly this many, whatever the track length.
pub const MONO_PREVIEW_COLUMNS: usize = 400;

/// Columns of the tiny mono preview (`PWV2`). Fixed by the format, like
/// `MONO_PREVIEW_COLUMNS`.
pub const TINY_PREVIEW_COLUMNS: usize = 100;

/// Columns of the color (`PWV4`) and 3-band (`PWV6`) previews, which share
/// one width. Fixed by the format, like `MONO_PREVIEW_COLUMNS`.
pub const COLOR_PREVIEW_COLUMNS: usize = 1200;

/// The size of a waveform in libdjinterop's terms: how many columns it has,
/// and how many audio samples each column spans.
pub const WaveformExtents = struct {
    /// Number of columns.
    size: u64,
    /// Audio samples represented by one column.
    samples_per_entry: f64,
};

/// The extents of the 150 Hz detail input `PerformanceData` wants for a
/// track: `size = round(sample_count / (sample_rate / DETAIL_HZ))` columns
/// of `sample_rate / DETAIL_HZ` samples each. Pinned by every ANLZ fixture
/// (demo_tracks 25866/19208, with_anlz 77181/59771 columns). Null when
/// `sample_rate` is 0.
pub fn detailExtents(sample_count: u64, sample_rate: u32) ?WaveformExtents {
    if (sample_rate == 0) return null;
    const samples_per_entry = @as(f64, @floatFromInt(sample_rate)) / DETAIL_HZ;
    const columns = @as(f64, @floatFromInt(sample_count)) / samples_per_entry;
    return .{
        .size = @intFromFloat(@round(columns)),
        .samples_per_entry = samples_per_entry,
    };
}

/// A marker of a sparse beatgrid: a beat number (possibly negative —
/// Rekordbox grids start at -4) at a sample offset.
pub const BeatMarker = struct {
    /// Beat number, anchored so a grid starting at -4 still places bar
    /// downbeats correctly.
    index: i32,
    /// Sample offset within the track.
    sample_offset: f64,
};

/// One 150 Hz waveform detail column: peak band energies.
pub const Band = struct {
    /// Sound energy of the low frequency band (0-255).
    low: u8 = 0,
    /// Sound energy of the mid frequency band (0-255).
    mid: u8 = 0,
    /// Sound energy of the high frequency band (0-255).
    high: u8 = 0,
};

/// A cue (point or loop) in sample units, before ANLZ encoding.
pub const CueInput = struct {
    /// Hot-cue slot, 1-based (1=A … 8=H). 0 = memory cue.
    hot_cue: u32 = 0,
    /// Point position in samples.
    sample_offset: f64 = 0,
    /// Loop end in samples; ignored when `is_loop` is false.
    loop_end: ?f64 = null,
    /// Whether this cue is a loop (uses `loop_end`) or a point cue.
    is_loop: bool = false,
    /// Label (only stored on the extended cue).
    label: []const u8 = "",
    /// Cue color components; alpha is dropped (ANLZ stores RGB plus a
    /// palette index).
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

/// Format-agnostic performance data for one track, the single input of
/// `buildAnlzInput`. All positions are sample offsets interpreted at
/// `sample_rate`.
///
/// `waveform_bands` and `waveform_heights` must be sampled at exactly
/// `DETAIL_HZ`: the detail sections copy the input columns verbatim, so a
/// different input rate silently stretches or squashes every output
/// waveform. Callers holding columns at another rate must resample to
/// 150 Hz first. The preview sections are derived from these same columns
/// at fixed widths (see `buildPreviewColumns`/`buildBandColumns`).
pub const PerformanceData = struct {
    /// Audio sample rate in Hz, used for sample→ms conversion. Zero makes
    /// beat and cue times come out as zero.
    sample_rate: u32,
    /// Total number of samples in the track; clips beats past the end.
    sample_count: u64,
    /// Track tempo in BPM. When set, it is applied uniformly to every beat,
    /// even for a variable-tempo grid (a Rekordbox-era simplification kept
    /// from rekordcrate); `null` derives the tempo per grid segment.
    bpm: ?f64 = null,
    /// Sparse beatgrid markers, in any order.
    beatgrid: []const BeatMarker = &.{},
    /// Sample offset of the main (memory) cue; null = none. Prepended as a
    /// colorless memory point cue.
    main_cue: ?f64 = null,
    /// Cues (memory or hot, point or loop).
    cues: []const CueInput = &.{},
    /// 3-band detail columns at `DETAIL_HZ`.
    waveform_bands: []const Band = &.{},
    /// Per-column peak height (0-31) at `DETAIL_HZ`, driving PWAV/PWV2/PWV3
    /// and the PWV5 height. May be shorter than `waveform_bands`.
    waveform_heights: []const u8 = &.{},
};

/// Caller-provided ANLZ content for a track, the output of
/// `buildAnlzInput` and the input of the device writer: beats/cues go to
/// `.DAT` (extended cues mirror to `.EXT`); the optional column groups
/// select which sibling files are written — null skips that file, empty
/// means the file is written without that section. All slices come from one
/// allocator and are freed by `deinit`.
pub const AnlzInput = struct {
    /// Beat grid (caller-provided).
    beats: []Beat = &.{},
    /// Plain cues for the `.DAT` cue list.
    cues: []Cue = &.{},
    /// Extended cues for the `.EXT` cue list.
    cues_extended: []ExtendedCue = &.{},
    /// Cue list type shared by `cues` and `cues_extended`.
    cue_list_type: CueListType = .memory_cues,
    /// Fixed-width mono preview (`PWAV`).
    preview_mono: []WaveformPreviewColumn = &.{},
    /// Fixed-width tiny mono preview (`PWV2`).
    tiny_preview: []TinyWaveformPreviewColumn = &.{},
    /// Variable-width mono detail (`PWV3`, 150 Hz), in `.EXT`.
    detail_mono: ?[]WaveformPreviewColumn = null,
    /// Fixed-width color preview (`PWV4`), in `.EXT`.
    color_preview: ?[]WaveformColorPreviewColumn = null,
    /// Variable-width color detail (`PWV5`, 150 Hz), in `.EXT`.
    color_detail: ?[]WaveformColorDetailColumn = null,
    /// Fixed-width 3-band preview (`PWV6`), in `.2EX`.
    band3_preview: ?[]Waveform3BandColumn = null,
    /// Variable-width 3-band detail (`PWV7`, 150 Hz), in `.2EX`.
    band3_detail: ?[]Waveform3BandColumn = null,

    /// Frees every slice reachable from this instance.
    pub fn deinit(input: *const AnlzInput, alloc: std.mem.Allocator) void {
        freeExtendedCues(alloc, input.cues_extended);
        alloc.free(input.beats);
        alloc.free(input.cues);
        alloc.free(input.cues_extended);
        alloc.free(input.preview_mono);
        alloc.free(input.tiny_preview);
        if (input.detail_mono) |data| alloc.free(data);
        if (input.color_preview) |data| alloc.free(data);
        if (input.color_detail) |data| alloc.free(data);
        if (input.band3_preview) |data| alloc.free(data);
        if (input.band3_detail) |data| alloc.free(data);
    }
};

/// The four band-derived column groups of `buildBandColumns`.
pub const BandColumns = struct {
    color_preview: []WaveformColorPreviewColumn = &.{},
    color_detail: []WaveformColorDetailColumn = &.{},
    band3_preview: []Waveform3BandColumn = &.{},
    band3_detail: []Waveform3BandColumn = &.{},

    pub fn deinit(columns: *const BandColumns, alloc: std.mem.Allocator) void {
        alloc.free(columns.color_preview);
        alloc.free(columns.color_detail);
        alloc.free(columns.band3_preview);
        alloc.free(columns.band3_detail);
    }
};

/// The two preview column groups of `buildPreviewColumns`.
pub const PreviewColumns = struct {
    preview: []WaveformPreviewColumn = &.{},
    tiny: []TinyWaveformPreviewColumn = &.{},

    pub fn deinit(columns: *const PreviewColumns, alloc: std.mem.Allocator) void {
        alloc.free(columns.preview);
        alloc.free(columns.tiny);
    }
};

/// Frees the comment payloads of the extended cues built by `buildCues`.
fn freeExtendedCues(alloc: std.mem.Allocator, cues: []const ExtendedCue) void {
    for (cues) |cue| alloc.free(cue.comment.raw);
}

/// The two cue lists of `buildCues`.
pub const CueLists = struct {
    cues: []Cue = &.{},
    extended: []ExtendedCue = &.{},
    list_type: CueListType = .memory_cues,

    pub fn deinit(lists: *const CueLists, alloc: std.mem.Allocator) void {
        freeExtendedCues(alloc, lists.extended);
        alloc.free(lists.cues);
        alloc.free(lists.extended);
    }
};

/// Converts a sample offset to milliseconds at `sample_rate`, rounded;
/// zero when `sample_rate` is zero.
pub fn samplesToMs(samples: f64, sample_rate: u32) u32 {
    if (sample_rate == 0) return 0;
    const rate: f64 = @floatFromInt(sample_rate);
    return std.math.lossyCast(u32, @round(samples / rate * 1000.0));
}

/// Rounds `bpm` to centi-BPM, saturating at the `u16` format ceiling of
/// 655.35 BPM; non-finite or non-positive values become zero.
fn centiBpm(bpm: f64) u16 {
    if (std.math.isFinite(bpm) and bpm > 0.0) {
        const centis = std.math.lossyCast(u64, @round(bpm * 100.0));
        return @intCast(@min(centis, std.math.maxInt(u16)));
    }
    return 0;
}

/// Maps a (possibly negative) global beat index to its 1-4 position in the
/// bar: `@mod` is the Euclidean remainder, so a grid starting at beat -4
/// still places the first bar downbeat at position 1.
fn barPosition(global_beat: i64) u16 {
    return @intCast(@mod(global_beat - 1, 4) + 1);
}

/// Expands a sparse 2-marker beatgrid into one `Beat` per beat. The markers
/// need not be sorted; the format requires ascending sample offsets, so they
/// are sorted first. Assumes **constant tempo between markers** (linear
/// interpolation of sample offsets): no rubato, no tempo curves, no
/// time-signature changes. `bpm` seeds the `tempo` field (see
/// `PerformanceData.bpm`); `sample_count` clips the tail — no beats are
/// emitted past the track end or before its start. Markers sharing a
/// sample offset are skipped. The final marker only ends the last
/// segment: the tempo beyond it is unknown, so no beat is emitted at or
/// past it — a grid's last beat is the one before the final marker.
pub fn expandBeatgrid(
    alloc: std.mem.Allocator,
    markers: []const BeatMarker,
    sample_rate: u32,
    bpm: ?f64,
    sample_count: u64,
) BuildError![]Beat {
    if (markers.len == 0 or sample_rate == 0) return &.{};

    const sorted = try alloc.dupe(BeatMarker, markers);
    defer alloc.free(sorted);
    std.mem.sort(BeatMarker, sorted, {}, struct {
        fn lessThan(_: void, a: BeatMarker, b: BeatMarker) bool {
            return a.sample_offset < b.sample_offset;
        }
    }.lessThan);

    const rate: f64 = @floatFromInt(sample_rate);
    const limit: f64 = @floatFromInt(sample_count);
    var beats: std.ArrayList(Beat) = .empty;
    errdefer beats.deinit(alloc);

    for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
        const index_a: i64 = a.index;
        const beat_span: i64 = @max(@as(i64, b.index) - index_a, 1);
        const span: f64 = @floatFromInt(beat_span);
        const samples_per_beat = (b.sample_offset - a.sample_offset) / span;
        if (samples_per_beat <= 0.0) continue;

        const local_bpm = 60.0 * rate / samples_per_beat;
        const tempo = centiBpm(bpm orelse local_bpm);
        const ms_per_beat = samples_per_beat / rate * 1000.0;
        const start_ms = a.sample_offset / rate * 1000.0;
        for (0..@intCast(beat_span)) |k| {
            const offset = a.sample_offset + @as(f64, @floatFromInt(k)) * samples_per_beat;
            if (offset < 0.0) continue;
            if (offset > limit) break;
            try beats.append(alloc, .{
                .beat_number = barPosition(index_a + @as(i64, @intCast(k))),
                .tempo = tempo,
                .time = std.math.lossyCast(u32, @round(start_ms + @as(f64, @floatFromInt(k)) * ms_per_beat)),
            });
        }
    }
    return beats.toOwnedSlice(alloc);
}

/// Index of the detail column that preview column `i` of `size` samples:
/// the midpoint of its span, `len * (2i + 1) / (2 * size)` in floor
/// arithmetic over the actual input length `len`. Rekordbox's own
/// derivation is unobservable (see `docs/DIVERGENCES.md`); this matches
/// libdjinterop's Engine overview resampler, the documented precedent for
/// the same two-tier design.
fn midpointIndex(len: usize, size: usize, i: usize) usize {
    return @intCast(@as(u64, len) * (2 * @as(u64, i) + 1) / (2 * @as(u64, size)));
}

/// Builds the four band-derived column groups (PWV4 color preview, PWV5
/// color detail, PWV6/PWV7 3-band) from a single 150 Hz 3-band detail
/// vector. The previews are fixed-width (`COLOR_PREVIEW_COLUMNS`) and
/// midpoint-sample the detail bands; the detail groups copy the band
/// energies directly (field order mid, top, bottom). `heights` drives the
/// PWV5 height (see `colorDetailColumn` for the missing-entry fallback).
/// Empty `bands` produce empty sections: nothing pins Rekordbox's behavior
/// for a track with no waveform.
///
/// Whiteness and the PWV4 bottom-half band are guesses: Rekordbox's exact
/// derivation is proprietary and undocumented — whiteness stays zero
/// throughout this module and the bottom-half energy mirrors the
/// bottom-third energy.
pub fn buildBandColumns(
    alloc: std.mem.Allocator,
    bands: []const Band,
    heights: []const u8,
) BuildError!BandColumns {
    const n_previews: usize = if (bands.len == 0) 0 else COLOR_PREVIEW_COLUMNS;

    const color_preview = try alloc.alloc(WaveformColorPreviewColumn, n_previews);
    errdefer alloc.free(color_preview);
    const color_detail = try alloc.alloc(WaveformColorDetailColumn, bands.len);
    errdefer alloc.free(color_detail);
    const band3_preview = try alloc.alloc(Waveform3BandColumn, n_previews);
    errdefer alloc.free(band3_preview);
    const band3_detail = try alloc.alloc(Waveform3BandColumn, bands.len);
    errdefer alloc.free(band3_detail);

    for (0..n_previews) |w| {
        const band = bands[midpointIndex(bands.len, COLOR_PREVIEW_COLUMNS, w)];
        color_preview[w] = .{
            .energy_bottom_half_freq = band.low,
            .energy_bottom_third_freq = band.low,
            .energy_mid_third_freq = band.mid,
            .energy_top_third_freq = band.high,
        };
        band3_preview[w] = .{
            .energy_mid_third_freq = band.mid,
            .energy_top_third_freq = band.high,
            .energy_bottom_third_freq = band.low,
        };
    }
    for (bands, 0..) |band, i| {
        color_detail[i] = colorDetailColumn(
            band.low,
            band.mid,
            band.high,
            if (i < heights.len) heights[i] else null,
        );
        band3_detail[i] = .{
            .energy_mid_third_freq = band.mid,
            .energy_top_third_freq = band.high,
            .energy_bottom_third_freq = band.low,
        };
    }
    return .{
        .color_preview = color_preview,
        .color_detail = color_detail,
        .band3_preview = band3_preview,
        .band3_detail = band3_detail,
    };
}

/// Quantizes one color-detail column. The RGB values pick the dominant band
/// (high→blue, mid→green, low→red; ties break high, so silence renders
/// blue); a caller-supplied height is clamped to 0-31, a missing one falls
/// back to the scaled band maximum.
fn colorDetailColumn(low: u8, mid: u8, high: u8, height: ?u8) WaveformColorDetailColumn {
    const h: u8 = height orelse blk: {
        const band_max: f32 = @floatFromInt(@max(@max(low, mid), high));
        break :blk std.math.lossyCast(u8, @round(band_max / 255.0 * 31.0));
    };
    var red: u3 = 0;
    var green: u3 = 0;
    var blue: u3 = 0;
    if (high >= mid and high >= low) {
        blue = 7;
    } else if (mid >= low) {
        green = 7;
    } else {
        red = 7;
    }
    return .{ .height = @intCast(@min(h, 31)), .red = red, .green = green, .blue = blue };
}

/// Builds the fixed-width mono previews (PWAV at `MONO_PREVIEW_COLUMNS`,
/// PWV2 at `TINY_PREVIEW_COLUMNS`) from a per-column peak height vector by
/// midpoint-sampling the detail heights, the resampling `buildBandColumns`
/// documents. The PWV2 height is the PWAV-scale height halved into its
/// 4-bit field — the fixtures cannot pin the 5→4-bit rescale, so halves
/// are chosen for symmetry. Empty `heights` produce empty sections:
/// nothing pins Rekordbox's behavior for a track with no waveform.
pub fn buildPreviewColumns(
    alloc: std.mem.Allocator,
    heights: []const u8,
) BuildError!PreviewColumns {
    const n_previews: usize = if (heights.len == 0) 0 else MONO_PREVIEW_COLUMNS;

    const preview = try alloc.alloc(WaveformPreviewColumn, n_previews);
    errdefer alloc.free(preview);
    const tiny = try alloc.alloc(TinyWaveformPreviewColumn, if (heights.len == 0) 0 else TINY_PREVIEW_COLUMNS);
    errdefer alloc.free(tiny);

    for (0..n_previews) |w| {
        const peak = @min(heights[midpointIndex(heights.len, MONO_PREVIEW_COLUMNS, w)], 31);
        // PWV2 carries a 4-bit height (0-15); PWAV carries 5 bits (0-31).
        preview[w] = .{ .height = @intCast(peak), .whiteness = 0 };
    }
    for (0..tiny.len) |w| {
        const peak = @min(heights[midpointIndex(heights.len, TINY_PREVIEW_COLUMNS, w)], 31);
        tiny[w] = .{ .height = @intCast(peak / 2) };
    }
    return .{ .preview = preview, .tiny = tiny };
}

/// Converts a caller-supplied per-column peak height vector (0-31) into the
/// mono detail columns (PWV3, 150 Hz) used by `.EXT`.
pub fn buildDetailMono(alloc: std.mem.Allocator, heights: []const u8) BuildError![]WaveformPreviewColumn {
    const detail = try alloc.alloc(WaveformPreviewColumn, heights.len);
    errdefer alloc.free(detail);
    for (heights, 0..) |h, i| {
        detail[i] = .{ .height = @intCast(@min(h, 31)), .whiteness = 0 };
    }
    return detail;
}

/// Builds the `.DAT` plain-cue list and the `.EXT` extended-cue list from
/// one set of cues. Both lists share `list_type`: memory cues
/// (`hot_cue == 0`) are emitted as memory lists, hot cues as hot lists —
/// since the writer applies a single shared type to both lists, hot cues
/// win whenever any is present. Memory-cue colors default to
/// `ColorIndex.none` and hot-cue palette indices to zero (the RGBA→palette
/// mapping is a known gap). A loop without `loop_end` keeps the
/// `0xFFFF_FFFF` sentinel.
pub fn buildCues(alloc: std.mem.Allocator, cues: []const CueInput, sample_rate: u32) BuildError!CueLists {
    const has_hot_cue = for (cues) |cue| {
        if (cue.hot_cue != 0) break true;
    } else false;

    const plain = try alloc.alloc(Cue, cues.len);
    errdefer alloc.free(plain);
    const extended = try alloc.alloc(ExtendedCue, cues.len);
    var built: usize = 0;
    errdefer {
        freeExtendedCues(alloc, extended[0..built]);
        alloc.free(extended);
    }

    for (cues, 0..) |*in, i| {
        const cue_type: CueType = if (in.is_loop) .loop else .point;
        const time = samplesToMs(in.sample_offset, sample_rate);
        const loop_time = if (in.is_loop and in.loop_end != null)
            samplesToMs(in.loop_end.?, sample_rate)
        else
            0xFFFF_FFFF;
        plain[i] = .{
            .hot_cue = in.hot_cue,
            .cue_type = cue_type,
            .time = time,
            .loop_time = loop_time,
        };
        extended[i] = .{
            .hot_cue = in.hot_cue,
            .cue_type = cue_type,
            .time = time,
            .loop_time = loop_time,
            .comment = try LenPrefixedWideString.fromUtf8(alloc, in.label),
            .hot_cue_color_rgb = .{ in.r, in.g, in.b },
        };
        built = i + 1;
    }
    return .{ .cues = plain, .extended = extended, .list_type = if (has_hot_cue) .hot_cues else .memory_cues };
}

/// Assembles a complete `AnlzInput` from format-agnostic performance data:
/// the single entry point for callers. Waveform columns for all seven
/// sections are derived from `pd.waveform_bands`/`pd.waveform_heights` (see
/// `PerformanceData` for the 150 Hz contract), the beatgrid is densified by
/// `expandBeatgrid`, and `pd.main_cue` is prepended to `pd.cues` as a
/// colorless memory point cue before `buildCues` sees one list. All output
/// is owned by `alloc` and freed by `AnlzInput.deinit`.
pub fn buildAnlzInput(alloc: std.mem.Allocator, pd: PerformanceData) BuildError!AnlzInput {
    const bands = try buildBandColumns(alloc, pd.waveform_bands, pd.waveform_heights);
    errdefer bands.deinit(alloc);
    const previews = try buildPreviewColumns(alloc, pd.waveform_heights);
    errdefer previews.deinit(alloc);
    const detail_mono = try buildDetailMono(alloc, pd.waveform_heights);
    errdefer alloc.free(detail_mono);
    const beats = try expandBeatgrid(alloc, pd.beatgrid, pd.sample_rate, pd.bpm, pd.sample_count);
    errdefer alloc.free(beats);

    const lists = if (pd.main_cue) |main_cue| blk: {
        const head = [1]CueInput{.{ .sample_offset = main_cue }};
        const combined = try std.mem.concat(alloc, CueInput, &.{ &head, pd.cues });
        defer alloc.free(combined);
        break :blk try buildCues(alloc, combined, pd.sample_rate);
    } else try buildCues(alloc, pd.cues, pd.sample_rate);

    return .{
        .beats = beats,
        .cues = lists.cues,
        .cues_extended = lists.extended,
        .cue_list_type = lists.list_type,
        .preview_mono = previews.preview,
        .tiny_preview = previews.tiny,
        .detail_mono = detail_mono,
        .color_preview = bands.color_preview,
        .color_detail = bands.color_detail,
        .band3_preview = bands.band3_preview,
        .band3_detail = bands.band3_detail,
    };
}
