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
    /// Auto-gain scales of the 3-band waveform sections, in `.2EX` files.
    waveform_3band_scales = fourcc("PWVC"),
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
/// either way.
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

/// A length-prefixed wide (UTF-16BE) string: a big-endian `u32` byte
/// count (NUL terminator included, zero when empty) followed by that many
/// bytes of UTF-16BE text.
///
/// Diverging from rekordcrate, the payload is stored as raw bytes (NUL
/// included) so roundtrips are byte-identical even for unusual data; use
/// `utf8` and `fromUtf8` to convert.
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
/// with `total_size` derived on write from the comment and trailing
/// lengths.
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
        // Entries are at least `fixed_wire_len` bytes each; their comment
        // payload and trailing bytes add more.
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
/// section. Serialized in field order, the three bytes are the analyzer's
/// low, mid, and high band values — whatever the field names suggest.
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
    /// Whether the unknown preamble field must hold its default value;
    /// other values are rejected on parse. Otherwise the field is stored
    /// verbatim.
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

/// The per-track auto-gain scales of the 3-band waveforms, in `.2EX`
/// files: one gain per band (low/mid/high), in hundredths — 100 is
/// neutral. The 3-band columns are stored already scaled by these gains.
pub const Waveform3BandScales = struct {
    /// Unknown field; zero in every known file, and any other value is
    /// rejected on parse.
    unknown: u16 = 0,
    /// The gains, in low/mid/high order.
    scales: [3]u16 = .{ 100, 100, 100 },

    const kind: Kind = .waveform_3band_scales;
    const header_size: u32 = 14;

    fn parse(c: *bin.Cursor, alloc: std.mem.Allocator, header: Header) ParseError!Waveform3BandScales {
        _ = alloc;
        if (header.size != header_size) return error.UnexpectedValue;
        const unknown = try c.takeInt(u16, .big);
        if (unknown != 0) return error.UnexpectedValue;
        return .{ .scales = .{
            try c.takeInt(u16, .big),
            try c.takeInt(u16, .big),
            try c.takeInt(u16, .big),
        } };
    }

    fn contentLen(s: *const Waveform3BandScales) usize {
        _ = s;
        return 6;
    }

    fn writeTo(s: *const Waveform3BandScales, e: *bin.Emitter) WriteError!void {
        try e.putInt(u16, s.unknown, .big);
        for (s.scales) |scale| try e.putInt(u16, scale, .big);
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

/// A song structure entry that represents a phrase in the track (24 bytes
/// on the wire).
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
    waveform_3band_scales: Waveform3BandScales,
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
/// `kind` and canonical `header_size` and provides a `contentLen` method;
/// unknown sections keep their parsed kind and follow the blob lengths.
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

/// The 16-byte preamble following the 12-byte `PMAI` prefix; Rekordbox
/// writes this exact sequence in every known file. Meaning unknown.
pub const file_header_data = [16]u8{
    0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// Writes a whole file: the `PMAI` header, `header_data`, and the sections.
/// The file header's `total_size` is patched in after the sections, since
/// only then is it known.
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

/// Columns of the mono preview (`PWAV`), fixed by the format whatever the
/// track length.
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

/// The extents of the 150 Hz band vector `buildColumnsFromBands` wants for
/// a track: `size = ceil(sample_count / (sample_rate / DETAIL_HZ))` columns
/// of `sample_rate / DETAIL_HZ` samples each. Null when `sample_rate` is 0.
pub fn detailExtents(sample_count: u64, sample_rate: u32) ?WaveformExtents {
    if (sample_rate == 0) return null;
    const samples_per_entry = @as(f64, @floatFromInt(sample_rate)) / DETAIL_HZ;
    const columns = @as(f64, @floatFromInt(sample_count)) / samples_per_entry;
    return .{
        .size = @intFromFloat(@ceil(columns)),
        .samples_per_entry = samples_per_entry,
    };
}

/// The preview companion of `detailExtents`: previews are fixed-width, so
/// the size is `COLOR_PREVIEW_COLUMNS` whatever the track, and each column
/// spans `sample_count / COLOR_PREVIEW_COLUMNS` samples. The color tier is
/// the one reported because libdjinterop's rekordbox adapter maps its own
/// fixed-size 3-band overview onto `PWV6`. Null when `sample_rate` is 0,
/// mirroring `detailExtents`.
pub fn previewExtents(sample_count: u64, sample_rate: u32) ?WaveformExtents {
    if (sample_rate == 0) return null;
    return .{
        .size = COLOR_PREVIEW_COLUMNS,
        .samples_per_entry = @as(f64, @floatFromInt(sample_count)) /
            @as(f64, @floatFromInt(COLOR_PREVIEW_COLUMNS)),
    };
}

/// Rekordbox's quantization of a waveform detail column height from the
/// peak sample magnitude of its 150 Hz window: `min(31, floor(31.5·p²))`,
/// with full scale (≥ 0.992) reaching 31. `detailHeightCode` is the exact
/// integer-domain form Rekordbox itself computes.
pub fn detailHeight(peak: f64) u5 {
    const level = 31.5 * peak * peak;
    if (!(level < 31.0)) return 31; // saturates; also maps NaN to 31
    return @intFromFloat(level);
}

/// Rekordbox's mono downmix for the s16 paths (PWV3/PWAV/PWV2): the
/// arithmetic mean `(L + R) / 2`, not a max-channel pick — anti-phase
/// input cancels. See `waveMonoMix` for the different float-path mix.
pub fn monoMix(left: f64, right: f64) f64 {
    return (left + right) / 2.0;
}

/// Rekordbox's quantizer for the 3-band sections (`PWV7`/`PWV6` band
/// values and the `PWV5` color channels): `min(127, floor(127·env))` for
/// a per-band envelope in 0..1 — linear in amplitude.
pub fn bandValue(envelope: f64) u7 {
    const level = 127.0 * envelope;
    if (!(level < 127.0)) return 127; // saturates; also maps NaN to 127
    if (level > 0.0) return @intFromFloat(level);
    return 0; // maps NaN and negatives to the silence value
}

/// Rekordbox's 3-bit log-pitch "whiteness" code for a pure tone of the
/// given frequency (the top bits of `PWV3`/`PWAV` columns; DC encodes 0,
/// digital silence 7): a monotone step function thresholding at 111.1,
/// 139.7, 168.7, 197.5, 238.6, 297.4 and 420.5 Hz. On program material
/// the code tracks an internal filterbank; `whitenessRatio` is the coded
/// column law.
pub fn whitenessTone(freq_hz: f64) u3 {
    if (freq_hz < 0.0 or freq_hz != freq_hz) return 7;
    const thresholds = [7]f64{ 111.06, 139.69, 168.74, 197.51, 238.59, 297.42, 420.54 };
    var code: u8 = 7;
    for (thresholds, 0..) |t, i| {
        if (freq_hz < t) {
            code = @intCast(i);
            break;
        }
    }
    return @intCast(code);
}

/// Rekordbox's 3-bit quantizer for a `PWV5` color channel: given the
/// channel's amplitude divided by the reference amplitude,
/// `min(7, floor(7·ratio))` — the dominant channel (ratio 1) codes
/// exactly 7. The reference is a maximum over Rekordbox's internal color
/// filterbank, which has more channels than the three visible ones.
/// Scale-free: unlike the 3-band path there is no adaptive gain.
/// `pwv5Colors` is the complete coded law.
pub fn colorShare(ratio: f64) u3 {
    const level = 7.0 * ratio;
    if (!(level < 7.0)) return 7; // saturates; also maps NaN to 7
    if (level > 0.0) return @intFromFloat(level);
    return 0;
}

// ------------------------------------------------------------------------
// Code-verified quantizers, transcribed from Rekordbox 6.8.6's decompiled
// analyzer: pure functions of caller-supplied filtered/enveloped
// statistics. `buildColumnsFromPcm` drives them end to end from raw audio.
// ------------------------------------------------------------------------

/// Rekordbox's "whiteness" code: the 8-level quantization of how much of
/// a column's peak survives a 150 Hz lowpass. `filtered_peak` is the
/// column peak of `|LPF150(mono)|` and `peak` the column peak of the s16
/// mono mix; the code is the smallest `w` in 0..7 with
/// `0.875 − 0.125·w ≤ ratio`, and a silent column (peak 0) encodes 7.
pub fn whitenessRatio(filtered_peak: u16, peak: u16) u3 {
    if (peak == 0) return 7;
    const ratio = @as(f64, @floatFromInt(filtered_peak)) /
        @as(f64, @floatFromInt(peak));
    if (ratio >= 0.875) return 0;
    var k: u8 = 1;
    while (k < 8) : (k += 1) {
        const threshold = 0.875 - 0.125 * @as(f64, @floatFromInt(k));
        if (ratio >= threshold) return @intCast(k);
    }
    return 7;
}

/// The detail-height quantizer exactly as coded: `u = trunc(peak /
/// track_peak · 32767)` then `h = trunc(u² · 2.9327451233027466e-08)` —
/// the constant is 31.488/32767², the integer-domain form of
/// `detailHeight`. `peak` and `track_peak` are s16 column / track peaks
/// of the truncated `(L+R)/2` mix.
pub fn detailHeightCode(peak: u16, track_peak: u16) u5 {
    if (track_peak == 0) return 0;
    const scaled = @as(f64, @floatFromInt(peak)) /
        @as(f64, @floatFromInt(track_peak)) * 32767.0;
    const u: u32 = @intFromFloat(@min(scaled, 32767.0));
    const uf: f64 = @floatFromInt(u);
    const level = uf * uf * 2.9327451233027466e-08;
    if (level < 32.0) return @intFromFloat(level);
    return 31;
}

/// The low/mid quantizer of `PWV7`: with `envelope` the per-ms-record
/// band peak (u16) and `scale_hundredths` the per-track adaptive scale
/// stored as u16·100, the byte is `trunc(env · 2⁻¹⁵ · scale/100 · 128)`
/// — all factors in float32. Quiet tracks pin the scale at the 0.8
/// clamp floor.
pub fn pwv7BandLinear(envelope: u16, scale_hundredths: u16) u8 {
    const env: f32 = @floatFromInt(envelope);
    const scale: f32 = @as(f32, @floatFromInt(scale_hundredths)) * 0.01;
    const v = env * (1.0 / 32768.0) * scale * 128.0;
    const i: u32 = @intFromFloat(v);
    return @truncate(i);
}

/// The high band of `PWV7`: `trunc((64 − cos(π·env·2⁻¹⁵)·64) · scale/100)`
/// — quadratic for small envelopes, saturating. The envelope reduces to
/// float32 before the float64 `cos`.
pub fn pwv7BandQuadratic(envelope: u16, scale_hundredths: u16) u8 {
    const env: f32 = @floatFromInt(envelope);
    const scale: f32 = @as(f32, @floatFromInt(scale_hundredths)) * 0.01;
    const arg: f64 = @as(f64, env * (1.0 / 32768.0)) * std.math.pi;
    const v: f64 = (64.0 - @cos(arg) * 64.0) * @as(f64, scale);
    const i: u32 = @intFromFloat(@max(v, 0.0));
    return @truncate(i);
}

/// The `PWV5` color codes, complete law: the three color-channel values
/// (u16 record peaks of the red/green/blue bands) are scaled by 255/max,
/// then the two suppression corrections and the 1.3 blue boost are
/// applied in float32, and the codes are `byte >> 5` — not
/// `min(7, floor(7·A/A_ref))` (see `colorShare`): the >>5 quantizer lets
/// non-dominant channels pin at 7 already at A/A_ref ≥ 0.878. All-zero
/// input is digital silence and encodes (7,7,7).
pub const ColorCodes = struct { red: u3, green: u3, blue: u3 };

pub fn pwv5Colors(red: u16, green: u16, blue: u16) ColorCodes {
    if (red == 0 and green == 0 and blue == 0)
        return .{ .red = 7, .green = 7, .blue = 7 };
    const aref: f32 = @floatFromInt(@max(red, @max(green, blue)));
    const inv: f32 = 1.0 / aref;
    var b_blue: f32 = inv * @as(f32, @floatFromInt(blue)) * 255.0;
    var b_red: f32 = inv * @as(f32, @floatFromInt(red)) * 255.0;
    var b_green: f32 = inv * @as(f32, @floatFromInt(green)) * 255.0;
    b_blue = @min(@max(b_blue, 0.0), 255.0);
    b_red = @min(@max(b_red, 0.0), 255.0);
    if (b_blue < 64.0) {
        const t = (0.00130718958 - b_blue * 2.04248372e-05) * b_green * b_red;
        b_red -= t;
        b_green -= t;
    }
    const m = @min(@max(b_blue, b_red), 128.0);
    b_green = @min(@max(b_green - m * b_green * 0.00234375, 0.0), 255.0);
    b_blue = @min(@max(b_blue * 1.29999995, 0.0), 255.0);
    b_red = @min(@max(b_red, 0.0), 255.0);
    const r_byte: u8 = @intFromFloat(b_red);
    const g_byte: u8 = @intFromFloat(b_green);
    const b_byte: u8 = @intFromFloat(b_blue);
    var codes = ColorCodes{
        .red = @intCast(r_byte >> 5),
        .green = @intCast(g_byte >> 5),
        .blue = @intCast(b_byte >> 5),
    };
    if (r_byte >> 5 == 0 and g_byte >> 5 == 0 and b_byte >> 5 == 0) {
        const mx = @max(r_byte, @max(g_byte, b_byte));
        if (r_byte == mx) codes.red = 1;
        if (g_byte == mx) codes.green = 1;
        if (b_byte == mx) codes.blue = 1;
    }
    return codes;
}

/// The WaveCreator's mono downmix — the mix behind
/// `PWV4`/`PWV5`/`PWV7`, distinct from `monoMix` (the s16 paths, a plain
/// mean). The branch operands are bit-masked absolutes, so the law is:
/// if `||L|−|R|| ≥ 0.001` take the mean, else take the channel with the
/// larger magnitude — anti-phase content survives here while `monoMix`
/// cancels it.
pub fn waveMonoMix(left: f64, right: f64) f64 {
    const dl = @abs(left);
    const dr = @abs(right);
    if (@abs(dl - dr) >= 0.001) return (left + right) * 0.5;
    return if (dl <= dr) right else left;
}

/// Rekordbox's encoding of digital silence: the mono previews floor at
/// (height 2, whiteness 5) and 1 rather than 0, detail silence is
/// (height 0, whiteness 7), the 3-band sections are all zero, and the
/// color detail encodes colors (7, 7, 7) with height 0 — silence codes
/// as "all bands 7", not 0. These are the values callers should emit for
/// silent spans.
pub const Silence = struct {
    /// `PWAV` byte: height 2, whiteness 5.
    pub const preview_byte: u8 = (5 << 5) | 2;
    /// `PWV2` byte: height 1.
    pub const tiny_byte: u8 = 1;
    /// `PWV3` byte: height 0, whiteness 7.
    pub const detail_byte: u8 = (7 << 5) | 0;
    /// `PWV5` column: colors (7, 7, 7), height 0, unknown bits 0.
    pub const color_detail_column: u16 = (7 << 13) | (7 << 10) | (7 << 7);
};

/// Samples by which Rekordbox's analysis windows lead a gapless-aware
/// MP3 decode: column k of an MP3 import covers source samples
/// `[294·k − 2257, 294·k + 294 − 2257)` instead of `[294·k, …)`.
/// 1105 samples of LAME encoder delay plus one 1152-sample MDCT frame
/// of decoder priming that Rekordbox does not strip. Gapless-tagged
/// encodes decode without priming and align at ~0; WAV imports sit at
/// exactly 0.
pub const mp3_analysis_offset_samples: i32 = -2257;

/// A marker of a sparse beatgrid: a beat number (possibly negative —
/// Rekordbox grids start at -4) at a sample offset.
pub const BeatMarker = struct {
    /// Beat number, anchored so a grid starting at -4 still places bar
    /// downbeats correctly.
    index: i32,
    /// Sample offset within the track.
    sample_offset: f64,
};

/// One 150 Hz waveform detail column: peak band energies. The input of
/// `buildColumnsFromBands` and the shape foreign waveform data maps onto —
/// libdjinterop's `waveform_entry` (low/mid/high values; its per-band
/// opacity fields are render alphas, not levels, and do not qualify)
/// resampled to `DETAIL_HZ`.
pub const Band = struct {
    /// Sound energy of the low frequency band (0-255).
    low: u8 = 0,
    /// Sound energy of the mid frequency band (0-255).
    mid: u8 = 0,
    /// Sound energy of the high frequency band (0-255).
    high: u8 = 0,
    /// The column's overall amplitude (0-255) when the source format
    /// carries one; 0 = not supplied, and the band max stands in — a lower
    /// bound, since band energies spread a peak across bands. Drives the
    /// mono heights and PWAV/PWV2 levels when present.
    peak: u8 = 0,
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

/// Format-agnostic performance data for one track: the metadata half of an
/// ANLZ build — beats, cues, and the rates that place them in time. All
/// positions are sample offsets interpreted at `sample_rate`. The waveform
/// half travels separately in a `WaveformColumns`; `buildAnlzInput` joins the
/// two.
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
    /// 3-band auto-gain scales (`PWVC`), in `.2EX` files.
    band3_scales: ?[3]u16 = null,

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

/// The seven waveform column groups of an ANLZ file: the waveform half of
/// an `AnlzInput` build, with field names matching `AnlzInput` one-to-one.
/// Produced by `buildColumnsFromPcm` (the byte-exact replication of Rekordbox's
/// analysis, from decoded PCM) or `buildColumnsFromBands` (an approximation
/// from foreign 3-band data), and moved into `buildAnlzInput`. All slices
/// are owned by the caller's allocator and freed by `deinit`.
pub const WaveformColumns = struct {
    /// Fixed-width mono preview (`PWAV`, 400 columns).
    preview_mono: []WaveformPreviewColumn = &.{},
    /// Fixed-width tiny mono preview (`PWV2`, 100 columns).
    tiny_preview: []TinyWaveformPreviewColumn = &.{},
    /// Variable-width mono detail (`PWV3`, `ceil(samples/294)` columns).
    detail_mono: []WaveformPreviewColumn = &.{},
    /// Fixed-width color preview (`PWV4`, 1200 columns).
    color_preview: []WaveformColorPreviewColumn = &.{},
    /// Variable-width color detail (`PWV5`, `ceil(samples/294)` columns).
    color_detail: []WaveformColorDetailColumn = &.{},
    /// Fixed-width 3-band preview (`PWV6`, 1200 columns).
    band3_preview: []Waveform3BandColumn = &.{},
    /// Variable-width 3-band detail (`PWV7`, `ceil(samples/294)` columns).
    band3_detail: []Waveform3BandColumn = &.{},
    /// 3-band auto-gain scales (`PWVC`), in hundredths.
    band3_scales: [3]u16 = .{ 100, 100, 100 },

    pub fn deinit(columns: *const WaveformColumns, alloc: std.mem.Allocator) void {
        alloc.free(columns.preview_mono);
        alloc.free(columns.tiny_preview);
        alloc.free(columns.detail_mono);
        alloc.free(columns.color_preview);
        alloc.free(columns.color_detail);
        alloc.free(columns.band3_preview);
        alloc.free(columns.band3_detail);
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

/// Expands a sparse marker beatgrid into one `Beat` per beat; markers need
/// not be sorted (the format requires ascending offsets, so they are
/// sorted first), and markers sharing a sample offset are skipped. Assumes
/// **constant tempo between markers** (linear interpolation of sample
/// offsets). `bpm` seeds the `tempo` field (see `PerformanceData.bpm`);
/// `sample_count` clips the tail — no beats are emitted past the track end
/// or before its start. The final marker only ends the last segment: the
/// tempo beyond it is unknown, so no beat is emitted at or past it.
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

/// The PWV7 envelope replay over the stats grid. The analyzer reseeds at
/// each column's first record minus W and samples at its last record, the
/// recursion being `env = x if x ≥ env else (1−α)·x + α·env` per record;
/// the column-grid form runs the same recursion once per column with the
/// constants converted from the record grid (294 samples per column /
/// 44.1 per record = 20/3 records per column): α per column =
/// α per record ^ 20/3, and the 300/200/100-record windows are exactly
/// 45/30/15 columns.
fn statsEnvelopeAt(vals: []const [3]u16, band: usize, col: usize, win: usize, alpha: f64) f64 {
    const seed: i64 = @as(i64, @intCast(col)) - @as(i64, @intCast(win));
    var env: f64 = if (seed >= 0) @floatFromInt(vals[@intCast(seed)][band]) else 0.0;
    var j = seed + 1;
    while (j <= col) : (j += 1) {
        const x: f64 = if (j >= 0) @floatFromInt(vals[@intCast(j)][band]) else 0.0;
        env = if (x >= env) x else (1.0 - alpha) * x + alpha * env;
    }
    return env;
}

/// Builds the seven waveform column groups from a single 150 Hz 3-band
/// detail vector — the route for callers holding foreign waveform data
/// (e.g. an Engine overview resampled to `DETAIL_HZ`), not decoded audio
/// (`buildColumnsFromPcm` is that route, byte-exact). The input must be sampled at
/// exactly `DETAIL_HZ`: the detail sections track the input columns
/// one-to-one, so a different input rate silently stretches or squashes
/// every output waveform; `detailExtents`/`previewExtents` report the
/// target shape.
///
/// The derivations are the analyzer's own laws (the 6.8.6 transcriptions
/// above) over one domain mapping: band energies and `Band.peak` become
/// the s16 record peaks those laws consume, as `value · 128`. What band
/// data cannot supply is proxied per group, as documented at each group's
/// site in the body: detail heights take the column peak (`Band.peak`
/// when supplied, else the band max, a lower bound), whiteness the low
/// band, the PWV4/PWV5 colors share-weighted band peaks, and the
/// PWAV/PWV2 ladders a per-span level calibrated so the loudest span
/// reaches the analyzer's AGC ceiling. Digital silence encodes as
/// `Silence` documents; empty `bands` produce empty sections.
pub fn buildColumnsFromBands(alloc: std.mem.Allocator, bands: []const Band) BuildError!WaveformColumns {
    if (bands.len == 0) return .{};

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const n = bands.len;

    // The domain mapping: 0-255 energies onto the s16 record peaks
    // (255 → 32640, full scale through the quantizers). `peaks` carries
    // the mono peak proxy — `Band.peak` when supplied, the band max
    // otherwise.
    const vals = try a.alloc([3]u16, n);
    const peaks = try a.alloc(u16, n);
    for (bands, 0..) |band, i| {
        vals[i] = .{ @as(u16, band.low) * 128, @as(u16, band.mid) * 128, @as(u16, band.high) * 128 };
        const p: u8 = if (band.peak != 0) band.peak else @max(@max(band.low, band.mid), band.high);
        peaks[i] = @as(u16, p) * 128;
    }
    var track_peak: u16 = 0;
    for (peaks) |p| track_peak = @max(track_peak, p);

    const scales = try bandScalesAndPreview(a, vals, 150);

    var out: WaveformColumns = .{ .band3_scales = scales.scale_u16 };
    errdefer out.deinit(alloc);
    out.color_preview = try alloc.alloc(WaveformColorPreviewColumn, COLOR_PREVIEW_COLUMNS);
    for (out.color_preview) |*col| col.* = .{}; // empty spans keep zeros
    out.color_detail = try alloc.alloc(WaveformColorDetailColumn, n);
    out.band3_preview = try alloc.alloc(Waveform3BandColumn, COLOR_PREVIEW_COLUMNS);
    out.band3_detail = try alloc.alloc(Waveform3BandColumn, n);
    out.preview_mono = try alloc.alloc(WaveformPreviewColumn, MONO_PREVIEW_COLUMNS);
    out.tiny_preview = try alloc.alloc(TinyWaveformPreviewColumn, TINY_PREVIEW_COLUMNS);
    out.detail_mono = try alloc.alloc(WaveformPreviewColumn, n);

    // The analyzer's PWV7 constants converted to the column grid.
    const rec_per_col: f64 = 20.0 / 3.0;
    const alphas = [3]f64{
        std.math.pow(f64, 0.99, rec_per_col),
        std.math.pow(f64, 0.98, rec_per_col),
        std.math.pow(f64, 0.97, rec_per_col),
    };
    const windows = [3]usize{ 45, 30, 15 };

    for (0..n) |c| {
        // PWV3: the mono height law and the whiteness ratio ladder.
        out.detail_mono[c] = .{
            .height = detailHeightCode(peaks[c], track_peak),
            .whiteness = whitenessRatio(vals[c][0], peaks[c]),
        };
        // PWV5: the share-law colors over the low-widened bands, the same
        // height law underneath.
        var redw: u16 = 0;
        const rlo = if (c >= 2) c - 2 else 0;
        const rhi = @min(c + 2, n - 1);
        var k = rlo;
        while (k <= rhi) : (k += 1) redw = @max(redw, vals[k][0]);
        const codes = pwv5Colors(redw, vals[c][1], vals[c][2]);
        out.color_detail[c] = .{
            .red = codes.red,
            .green = codes.green,
            .blue = codes.blue,
            .height = detailHeightCode(peaks[c], track_peak),
        };
        // PWV7: the envelope replay through the linear (low/mid) and
        // cosine (high) quantizers.
        out.band3_detail[c] = .{
            .energy_mid_third_freq = pwv7QuantLinear(@floatCast(statsEnvelopeAt(vals, 0, c, windows[0], alphas[0])), scales.scale_u16[0]),
            .energy_top_third_freq = pwv7QuantLinear(@floatCast(statsEnvelopeAt(vals, 1, c, windows[1], alphas[1])), scales.scale_u16[1]),
            .energy_bottom_third_freq = pwv7QuantQuadratic(@floatCast(statsEnvelopeAt(vals, 2, c, windows[2], alphas[2])), scales.scale_u16[2]),
        };
    }

    // PWV6 from the shared scale derivation; wire order low/mid/high.
    for (0..COLOR_PREVIEW_COLUMNS) |j| {
        out.band3_preview[j] = .{
            .energy_mid_third_freq = scales.pwv6[j][0],
            .energy_top_third_freq = scales.pwv6[j][1],
            .energy_bottom_third_freq = scales.pwv6[j][2],
        };
    }

    // PWV4: per-span maxima of the mono peak, the low band (the LPF400
    // proxy), and the share-weighted bands, the low share widened ±2
    // columns as the analyzer's ±12-record LOW window.
    {
        const share = try a.alloc([3]u16, n);
        for (bands, 0..) |band, i| {
            const energies = [3]u8{ band.low, band.mid, band.high };
            const sum: u32 = @as(u32, band.low) + band.mid + band.high;
            for (energies, 0..) |e, b| share[i][b] = if (sum == 0) 0 else @intCast(@as(u64, e) * e * 128 / sum);
        }
        for (0..COLOR_PREVIEW_COLUMNS) |j| {
            const rs = spanStartOf(n, j, COLOR_PREVIEW_COLUMNS);
            const re = spanEndOf(n, j, COLOR_PREVIEW_COLUMNS);
            if (re < rs) continue; // empty span: zeros, as the analyzer leaves them
            var mono_max: u16 = 0;
            var low_max: u16 = 0;
            var mid_share: u16 = 0;
            var high_share: u16 = 0;
            for (rs..re + 1) |c| {
                mono_max = @max(mono_max, peaks[c]);
                low_max = @max(low_max, vals[c][0]);
                mid_share = @max(mid_share, share[c][1]);
                high_share = @max(high_share, share[c][2]);
            }
            var low_share: u16 = 0;
            const wlo = if (rs >= 2) rs - 2 else 0;
            const whi = @min(re + 2, n - 1);
            var c2 = wlo;
            while (c2 <= whi) : (c2 += 1) low_share = @max(low_share, share[c2][0]);
            const top: u8 = @intCast(mono_max / 256);
            out.color_preview[j] = .{
                .unknown1 = top,
                .unknown2 = @truncate(@as(u16, 256) -% top),
                .energy_bottom_half_freq = @intCast(low_max / 256),
                .energy_bottom_third_freq = @intCast(low_share / 256),
                .energy_mid_third_freq = @intCast(mid_share / 256),
                .energy_top_third_freq = @intCast(high_share / 256),
            };
        }
    }

    // PWAV: the height ladder over a span-mean level, calibrated so the
    // loudest span reaches the fixtures' AGC ceiling (23); the class bits
    // from the band dB codes.
    {
        // Between pwav_ladder[20] and [21], clear of both boundaries.
        const pwav_target: f32 = 35000;
        var levels = [_]f32{0} ** MONO_PREVIEW_COLUMNS;
        var max_level: f32 = 0;
        for (0..MONO_PREVIEW_COLUMNS) |j| {
            const rs = spanStartOf(n, j, MONO_PREVIEW_COLUMNS);
            const re = spanEndOf(n, j, MONO_PREVIEW_COLUMNS);
            if (re < rs) continue;
            var sum: f64 = 0;
            for (rs..re + 1) |c| sum += @floatFromInt(peaks[c]);
            levels[j] = @floatCast(sum / @as(f64, @floatFromInt(re + 1 - rs)));
            max_level = @max(max_level, levels[j]);
        }
        const cal: f32 = if (max_level > 0) pwav_target / max_level else 0;
        for (0..MONO_PREVIEW_COLUMNS) |j| {
            const rs = spanStartOf(n, j, MONO_PREVIEW_COLUMNS);
            const re = spanEndOf(n, j, MONO_PREVIEW_COLUMNS);
            var band_max = [3]u16{ 0, 0, 0 };
            if (re >= rs) {
                for (rs..re + 1) |c| {
                    for (0..3) |b| band_max[b] = @max(band_max[b], vals[c][b]);
                }
            }
            out.preview_mono[j] = .{
                .height = @intCast(pwavLadder(levels[j] * cal)),
                .whiteness = pwavClass(
                    dbcode(@as(f32, @floatFromInt(band_max[0])) * 0.5),
                    dbcode(@as(f32, @floatFromInt(band_max[1])) * 0.25),
                    dbcode(@as(f32, @floatFromInt(band_max[2]))),
                ),
            };
        }
    }

    // PWV2: its ladder over the span max of the low band, calibrated to 13
    // at the loudest span; a zero accumulator encodes 1 (2 when the mid
    // band is nonzero), the analyzer's band-2 tiebreak.
    {
        const acc = try a.alloc(u16, TINY_PREVIEW_COLUMNS);
        const mid_max = try a.alloc(u16, TINY_PREVIEW_COLUMNS);
        @memset(acc, 0);
        @memset(mid_max, 0);
        var max_acc: u16 = 0;
        for (0..TINY_PREVIEW_COLUMNS) |j| {
            const rs = spanStartOf(n, j, TINY_PREVIEW_COLUMNS);
            const re = spanEndOf(n, j, TINY_PREVIEW_COLUMNS);
            if (re < rs) continue;
            for (rs..re + 1) |c| {
                acc[j] = @max(acc[j], vals[c][0]);
                mid_max[j] = @max(mid_max[j], vals[c][1]);
            }
            max_acc = @max(max_acc, acc[j]);
        }
        const cal: f64 = if (max_acc > 0) 15000.0 / @as(f64, @floatFromInt(max_acc)) else 0;
        for (0..TINY_PREVIEW_COLUMNS) |j| {
            const v: i64 = @intFromFloat(@trunc(@as(f64, @floatFromInt(acc[j])) * cal));
            const code: i64 = if (v == 0) (if (mid_max[j] != 0) 2 else 1) else pwv2LadderVal(v);
            out.tiny_preview[j] = .{ .height = @intCast(code) };
        }
    }

    return out;
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

/// Assembles a complete `AnlzInput` from format-agnostic performance data
/// and a waveform column set: the single composition entry point. The
/// beatgrid is densified by `expandBeatgrid`, `pd.main_cue` is prepended to
/// `pd.cues` as a colorless memory point cue before `buildCues` sees one
/// list, and all seven waveform column groups are **moved** out of
/// `waveforms` (which is left empty, so an unconditional
/// `defer waveforms.deinit(alloc)` stays correct). Produce the columns with
/// `buildColumnsFromPcm` (byte-exact, from decoded audio) or `buildColumnsFromBands`
/// (approximate, from foreign band data); a default `WaveformColumns{}`
/// leaves every waveform section empty, matching a waveform-less analysis.
/// All output is owned by `alloc` and freed by `AnlzInput.deinit`.
pub fn buildAnlzInput(
    alloc: std.mem.Allocator,
    pd: PerformanceData,
    waveforms: *WaveformColumns,
) BuildError!AnlzInput {
    const beats = try expandBeatgrid(alloc, pd.beatgrid, pd.sample_rate, pd.bpm, pd.sample_count);
    errdefer alloc.free(beats);

    const lists = if (pd.main_cue) |main_cue| blk: {
        const head = [1]CueInput{.{ .sample_offset = main_cue }};
        const combined = try std.mem.concat(alloc, CueInput, &.{ &head, pd.cues });
        defer alloc.free(combined);
        break :blk try buildCues(alloc, combined, pd.sample_rate);
    } else try buildCues(alloc, pd.cues, pd.sample_rate);

    const out = AnlzInput{
        .beats = beats,
        .cues = lists.cues,
        .cues_extended = lists.extended,
        .cue_list_type = lists.list_type,
        .preview_mono = waveforms.preview_mono,
        .tiny_preview = waveforms.tiny_preview,
        .detail_mono = waveforms.detail_mono,
        .color_preview = waveforms.color_preview,
        .color_detail = waveforms.color_detail,
        .band3_preview = waveforms.band3_preview,
        .band3_detail = waveforms.band3_detail,
        .band3_scales = waveforms.band3_scales,
    };
    waveforms.* = .{};
    return out;
}

// ---------------------------------------------------------------------------
// PCM analysis route
// ---------------------------------------------------------------------------

pub const AnalyzeError = error{ OutOfMemory, ChannelMismatch };

/// Raw decoded PCM input: planar stereo f32 in [−1, 1) (NaN/inf are a
/// contract violation — the analyzer's saturating casts assume finite
/// samples). Mono sources must be duplicated to both channels, as
/// Rekordbox's decode path always delivers stereo. The two channels must
/// have equal length. The sample rate must be 44100 Hz as that's the only
/// rate Rekordbox's analysis supports (it resamples everything to that
/// before analysis). This library doesn't resample or decode.
pub const PcmInput = struct {
    left: []const f32,
    right: []const f32,
};

// ---------------------------------------------------------------------------
// Numerics
// ---------------------------------------------------------------------------

/// Pairwise summation (128-sample blocks split in half, 8-accumulator
/// unroll). The association order is observable at truncation boundaries
/// downstream, so the exact order matters.
fn npSum(a: []const f64) f64 {
    const n = a.len;
    if (n < 8) {
        var res: f64 = 0.0;
        for (a) |v| res += v;
        return res;
    }
    if (n <= 128) {
        var r = [8]f64{ a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7] };
        var i: usize = 8;
        const lim = n - (n % 8);
        while (i < lim) : (i += 8) {
            r[0] += a[i];
            r[1] += a[i + 1];
            r[2] += a[i + 2];
            r[3] += a[i + 3];
            r[4] += a[i + 4];
            r[5] += a[i + 5];
            r[6] += a[i + 6];
            r[7] += a[i + 7];
        }
        var res: f64 = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
        while (i < n) : (i += 1) res += a[i];
        return res;
    }
    var n2 = n / 2;
    n2 -= n2 % 8;
    return npSum(a[0..n2]) + npSum(a[n2..]);
}

/// Record-write saturation: `trunc(v·32768)`, with v ≥ 1 → 0x7fff and
/// v < −1 → 0x8000.
fn sat16(v: f64) i16 {
    if (v >= 1.0) return 32767;
    if (v < -1.0) return -32768;
    return @intFromFloat(@trunc(v * 32768.0));
}

/// `sat16` for the non-negative |window max| record fields.
fn sat16u(v: f64) u16 {
    return @intCast(sat16(v));
}

/// One direct-form-II-transposed biquad in float64; the exact operation
/// order (`y = b0·x + z0; z0 = (z1 + b1·x) − a1·y; z1 = b2·x − a2·y`)
/// is part of the bit-exact contract.
const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z0: f64 = 0.0,
    z1: f64 = 0.0,

    fn proc(q: *Biquad, x: f64) f64 {
        const y = q.b0 * x + q.z0;
        q.z0 = (q.z1 + q.b1 * x) - q.a1 * y;
        q.z1 = q.b2 * x - q.a2 * y;
        return y;
    }
};

const fs: f64 = 44100.0;
/// Q = 1/√2 — the stored literal, one ulp below `sqrt(2)/2`.
const inv_sqrt2: f64 = 0.70710678118654746;
/// 31.488/32767², the coded height constant.
const height_c: f64 = 2.9327451233027466e-08;

/// RBJ lowpass, Q = 1/√2.
fn cookLpf(fc: f64) Biquad {
    const w0 = 2.0 * std.math.pi * fc / fs;
    const s = @sin(w0);
    const c = @cos(w0);
    const a = s * inv_sqrt2;
    const d = 1.0 / (1.0 + a);
    const b0 = (1.0 - c) * 0.5 * d;
    return .{ .b0 = b0, .b1 = 2.0 * b0, .b2 = b0, .a1 = -2.0 * c * d, .a2 = (1.0 - a) * d };
}

/// RBJ highpass, Q = 1/√2.
fn cookHpf(fc: f64) Biquad {
    const w0 = 2.0 * std.math.pi * fc / fs;
    const s = @sin(w0);
    const c = @cos(w0);
    const a = s * inv_sqrt2;
    const d = 1.0 / (1.0 + a);
    const b0 = (1.0 + c) * 0.5 * d;
    return .{ .b0 = b0, .b1 = -2.0 * b0, .b2 = b0, .a1 = -2.0 * c * d, .a2 = (1.0 - a) * d };
}

/// LPF@150 in bilinear/tan form: fc from tan(π·150/fs), not sin/cos.
fn cookLpf150Tan() Biquad {
    const t = @tan(std.math.pi * 150.0 / fs);
    const d = 1.0 / (t * @sqrt(2.0) + 1.0 + t * t);
    const b0 = t * t * d;
    return .{
        .b0 = b0,
        .b1 = 2.0 * b0,
        .b2 = b0,
        .a1 = (2.0 * t * t - 2.0) * d,
        .a2 = (1.0 - @sqrt(2.0) * t + t * t) * d,
    };
}

/// ceil(a/b) for non-negative integers.
fn ceilDiv(a: usize, b: usize) usize {
    if (b == 0) return 0;
    return (a + b - 1) / b;
}

/// The PWV7 b0/b1 quantizer on the fractional f32 envelope:
/// `trunc(env·2⁻¹⁵·scale/100·128)` — all float32. The public
/// `anlz.pwv7BandLinear` is this same law specialized to integer u16
/// record-bank envelopes; the engine's envelope decays between record
/// values, so it needs the untruncated input.
fn pwv7QuantLinear(env: f32, scale_hundredths: u16) u8 {
    const scale: f32 = @as(f32, @floatFromInt(scale_hundredths)) * 0.01;
    const v = env * (1.0 / 32768.0) * scale * 128.0;
    const i: u32 = @intFromFloat(v);
    return @truncate(i);
}

/// The PWV7 b2 transform on the fractional f32 envelope:
/// `trunc((64 − cos(π·env·2⁻¹⁵)·64)·scale/100)`.
fn pwv7QuantQuadratic(env: f32, scale_hundredths: u16) u8 {
    const scale: f32 = @as(f32, @floatFromInt(scale_hundredths)) * 0.01;
    const arg: f64 = @as(f64, env * (1.0 / 32768.0)) * std.math.pi;
    const v: f64 = (64.0 - @cos(arg) * 64.0) * @as(f64, scale);
    const i: u32 = @intFromFloat(@max(v, 0.0));
    return @truncate(i);
}

// ---------------------------------------------------------------------------
// WaveCreator: PWV4/PWV5/PWV6/PWV7 record bank and finalizers
// ---------------------------------------------------------------------------

/// The per-millisecond record bank. Record r covers samples
/// [starts[r], starts[r+1]) of the track.
const Rec = struct {
    /// PWV7: per-band window |max|, sat16.
    b: [3]u16 = .{ 0, 0, 0 },
    /// Signed window max/min of the mono mix, sat16.
    mmax: i16 = 0,
    mmin: i16 = 0,
    /// PWV5: per-band window |max|, sat16.
    red: u16 = 0,
    green: u16 = 0,
    blue: u16 = 0,
    /// PWV4: LPF400 window |max|, then the share-weighted band peaks
    /// `sat16(cnt_k · peak_k / win)` over the raw pre-sat16 signals.
    w400: u16 = 0,
    s3: i16 = 0,
    s4: i16 = 0,
    s5: i16 = 0,
};

/// Accumulators of the currently open record window.
const RecAcc = struct {
    mmax: f64 = -std.math.inf(f64),
    mmin: f64 = std.math.inf(f64),
    w7b0: f64 = 0,
    w7b1: f64 = 0,
    w7b2: f64 = 0,
    wred: f64 = 0,
    wgreen: f64 = 0,
    wblue: f64 = 0,
    ww400: f64 = 0,
    raw_lo: f64 = 0,
    raw_mi: f64 = 0,
    raw_hi: f64 = 0,
    cnt_l: i64 = 0,
    cnt_m: i64 = 0,
    cnt_h: i64 = 0,
};

/// Record-window grid: starts[r] = min((441·r + 9)/10, n) — 44.1 samples
/// per record.
fn startsGrid(alloc: std.mem.Allocator, d: usize, n: usize) ![]usize {
    const starts = try alloc.alloc(usize, d + 1);
    for (starts, 0..) |*s, r| s.* = @min((441 * r + 9) / 10, n);
    return starts;
}

/// Flush-to-zero of denormals, mirroring the analyzer's SSE FTZ/DAZ mode.
fn ftz(x: f64) f64 {
    return if (@abs(x) < 2.2250738585072014e-308) 0.0 else x;
}

/// The PWV4 share-field store: a window peak at or above 1.0 stores
/// 0x7fff regardless of the count; otherwise
/// `trunc(cnt·peak/win·32768)` with no product clamp (cnt ≤ win and
/// peak < 1 keep the value under 32768).
fn shareSat(cnt: i64, peak: f64, win: f64) i16 {
    if (peak >= 1.0) return 32767;
    return @intFromFloat(@trunc(@as(f64, @floatFromInt(cnt)) * peak / win * 32768.0));
}

/// The float-path WaveCreator: `push` streams one sample through the
/// 18-biquad filterbank and folds it into the open record window;
/// `closeRecord` seals a window at each boundary; the finalizers below
/// consume the closed records.
const WaveCreator = struct {
    n: usize,
    d: usize,
    starts: []usize,
    recs: []Rec,
    acc: RecAcc = .{},
    open: usize = 0,

    // PWV7 bank: b0 = LPF300, b1 = HPF250∘LPF1200, b2 = HPF3000∘LPF9000.
    f_v7b0: Biquad,
    f_v7b1a: Biquad,
    f_v7b1b: Biquad,
    f_v7b2a: Biquad,
    f_v7b2b: Biquad,
    // PWV5 bank: red = LPF100, green = HPF300∘LPF3000, blue = HPF1500.
    f_red: Biquad,
    f_greena: Biquad,
    f_greenb: Biquad,
    f_blue: Biquad,
    // PWV4 bank: wide = LPF400, LOW = LPF200², MID = HPF200²∘LPF2000², HIGH = HPF2000².
    f_w400: Biquad,
    f_lowa: Biquad,
    f_lowb: Biquad,
    f_mida: Biquad,
    f_midb: Biquad,
    f_midc: Biquad,
    f_midd: Biquad,
    f_higha: Biquad,
    f_highb: Biquad,

    fn init(alloc: std.mem.Allocator, n: usize) !WaveCreator {
        const d = ceilDiv(n * 1000, 44100);
        return .{
            .n = n,
            .d = d,
            .starts = try startsGrid(alloc, d, n),
            .recs = try alloc.alloc(Rec, d),
            .f_v7b0 = cookLpf(300),
            .f_v7b1a = cookHpf(250),
            .f_v7b1b = cookLpf(1200),
            .f_v7b2a = cookHpf(3000),
            .f_v7b2b = cookLpf(9000),
            .f_red = cookLpf(100),
            .f_greena = cookHpf(300),
            .f_greenb = cookLpf(3000),
            .f_blue = cookHpf(1500),
            .f_w400 = cookLpf(400),
            .f_lowa = cookLpf(200),
            .f_lowb = cookLpf(200),
            .f_mida = cookHpf(200),
            .f_midb = cookHpf(200),
            .f_midc = cookLpf(2000),
            .f_midd = cookLpf(2000),
            .f_higha = cookHpf(2000),
            .f_highb = cookHpf(2000),
        };
    }

    fn push(w: *WaveCreator, mono: f64) void {
        const a = &w.acc;
        if (mono > a.mmax) a.mmax = mono;
        if (mono < a.mmin) a.mmin = mono;
        const v7b0 = w.f_v7b0.proc(mono);
        const v7b1 = w.f_v7b1b.proc(w.f_v7b1a.proc(mono));
        const v7b2 = w.f_v7b2b.proc(w.f_v7b2a.proc(mono));
        const red = w.f_red.proc(mono);
        const green = w.f_greenb.proc(w.f_greena.proc(mono));
        const blue = w.f_blue.proc(mono);
        const w400 = w.f_w400.proc(mono);
        a.w7b0 = @max(a.w7b0, @abs(v7b0));
        a.w7b1 = @max(a.w7b1, @abs(v7b1));
        a.w7b2 = @max(a.w7b2, @abs(v7b2));
        a.wred = @max(a.wred, @abs(red));
        a.wgreen = @max(a.wgreen, @abs(green));
        a.wblue = @max(a.wblue, @abs(blue));
        a.ww400 = @max(a.ww400, @abs(w400));
        // The analyzer's SSE runs FTZ/DAZ: denormal band samples flush to
        // zero, so decaying RBJ tails in digital silence tie at ±0 and the
        // tie order hands the count to LOW.
        const lo = ftz(w.f_lowb.proc(w.f_lowa.proc(mono)));
        const mi = ftz(w.f_midd.proc(w.f_midc.proc(w.f_midb.proc(w.f_mida.proc(mono)))));
        const hi = ftz(w.f_highb.proc(w.f_higha.proc(mono)));
        a.raw_lo = @max(a.raw_lo, @abs(lo));
        a.raw_mi = @max(a.raw_mi, @abs(mi));
        a.raw_hi = @max(a.raw_hi, @abs(hi));
        // Share counts: argmax over the SIGNED band samples, ties LOW > HIGH > MID.
        const m3 = @max(@max(lo, mi), hi);
        if (lo == m3) {
            a.cnt_l += 1;
        } else if (hi == m3) {
            a.cnt_h += 1;
        } else {
            a.cnt_m += 1;
        }
    }

    /// Seals record `r` from the accumulators and reopens the next window.
    fn closeRecord(w: *WaveCreator, r: usize) void {
        var mmax = w.acc.mmax;
        var mmin = w.acc.mmin;
        if (std.math.isNegativeInf(mmax)) {
            // Empty window: the zero-filled pad slot is its only content.
            mmax = 0.0;
            mmin = 0.0;
        } else if (r == w.d - 1) {
            // The final window extends one pad sample (0.0) past EOF.
            mmax = @max(mmax, 0.0);
            mmin = @min(mmin, 0.0);
        }
        const win: f64 = @floatFromInt(@max(w.starts[r + 1] - w.starts[r], 1));
        const a = &w.acc;
        w.recs[r] = .{
            .b = .{ sat16u(a.w7b0), sat16u(a.w7b1), sat16u(a.w7b2) },
            .mmax = sat16(mmax),
            .mmin = sat16(mmin),
            .red = sat16u(a.wred),
            .green = sat16u(a.wgreen),
            .blue = sat16u(a.wblue),
            .w400 = sat16u(a.ww400),
            .s3 = shareSat(a.cnt_l, a.raw_lo, win),
            .s4 = shareSat(a.cnt_m, a.raw_mi, win),
            .s5 = shareSat(a.cnt_h, a.raw_hi, win),
        };
        w.acc = .{};
        w.open = r + 1;
    }

    // ---- adaptive scales + PWV6 ----

    /// The derivation over the record bank (`per_second = 1000` records);
    /// `bandScalesAndPreview` carries the law.
    fn scalesAndPwv6(w: *const WaveCreator, alloc: std.mem.Allocator) !AdaptiveScales {
        const vals = try alloc.alloc([3]u16, w.d);
        defer alloc.free(vals);
        for (w.recs, 0..) |rec, i| vals[i] = rec.b;
        return bandScalesAndPreview(alloc, vals, 1000);
    }

    // ---- PWV7 ----

    /// Column c's value is the trailing-window attack/decay envelope (α =
    /// 0.99/0.98/0.97 per ms-record, W = 300/200/100) reseeded at the
    /// column's first record minus W and sampled at the column's last
    /// record.
    fn pwv7(w: *const WaveCreator, alloc: std.mem.Allocator, n_columns: usize, scale_u16: [3]u16) ![][3]u8 {
        const d = w.d;
        const out = try alloc.alloc([3]u8, n_columns);
        errdefer alloc.free(out);
        const alphas = [3]f64{ 0.99, 0.98, 0.97 };
        const windows = [3]i64{ 300, 200, 100 };
        const grid = try columnGrid(alloc, d, n_columns);
        defer {
            alloc.free(grid.r_f);
            alloc.free(grid.r_c);
        }
        for (0..3) |b| {
            const win = windows[b];
            const al = alphas[b];
            for (0..n_columns) |c| {
                const seed: i64 = grid.r_f[c] - win;
                var env: f64 = if (seed >= 0 and seed <= grid.r_c[c])
                    @floatFromInt(w.recs[@intCast(seed)].b[b])
                else
                    0.0;
                const width: i64 = grid.r_c[c] - grid.r_f[c] + win + 1;
                var j: i64 = 1;
                while (j < width) : (j += 1) {
                    const p = seed + j;
                    const xj: f64 = if (p >= 0 and p <= grid.r_c[c])
                        @floatFromInt(w.recs[@intCast(p)].b[b])
                    else
                        0.0;
                    env = if (xj >= env) xj else (1.0 - al) * xj + al * env;
                }
                // The envelope decay produces fractional values; the
                // quantizer takes their float32 image, not a value
                // truncated to the record grid.
                const env32: f32 = @floatCast(env);
                out[c][b] = if (b < 2)
                    pwv7QuantLinear(env32, scale_u16[b])
                else
                    pwv7QuantQuadratic(env32, scale_u16[b]);
            }
        }
        return out;
    }

    // ---- PWV5 ----

    /// Returns the big-endian PWV5 words (red<<13 | green<<10 | blue<<7 |
    /// h<<2). Red keeps a ±12-record sliding window over the column, green
    /// ±1, blue and the mono peak run inside [r_f, r_c]; the height
    /// normalizer P is the one-record-lagged column peak maximum.
    fn pwv5(w: *const WaveCreator, alloc: std.mem.Allocator, n_columns: usize) ![]u16 {
        const d = w.d;
        const out = try alloc.alloc(u16, n_columns);
        errdefer alloc.free(out);
        const peaks = try alloc.alloc(u16, n_columns); // min(max(|ch0|,|ch1|), 32767)
        defer alloc.free(peaks);
        const grid = try columnGrid(alloc, d, n_columns);
        defer {
            alloc.free(grid.r_f);
            alloc.free(grid.r_c);
        }

        var p5: u16 = 0;
        for (0..n_columns) |c| {
            var redw: u16 = 0;
            var greenw: u16 = 0;
            var blue: u16 = 0;
            var ch0: i16 = std.math.minInt(i16);
            var ch1: i16 = std.math.maxInt(i16);
            {
                const lo = clampToRecords(grid.r_f[c] - 12, d);
                const hi = clampToRecords(grid.r_c[c] + 12, d);
                var k: i64 = lo;
                while (k <= hi) : (k += 1) redw = @max(redw, w.recs[@intCast(k)].red);
            }
            {
                const lo = clampToRecords(grid.r_f[c] - 1, d);
                const hi = clampToRecords(grid.r_c[c] + 1, d);
                var k: i64 = lo;
                while (k <= hi) : (k += 1) greenw = @max(greenw, w.recs[@intCast(k)].green);
            }
            if (grid.r_c[c] >= grid.r_f[c]) {
                var k: i64 = grid.r_f[c];
                while (k <= grid.r_c[c]) : (k += 1) {
                    const rec = w.recs[@intCast(k)];
                    blue = @max(blue, rec.blue);
                    ch0 = @max(ch0, rec.mmax);
                    ch1 = @min(ch1, rec.mmin);
                }
            } else {
                // Single-degenerate column: the running maxima read as 0.
                ch0 = 0;
                ch1 = 0;
            }
            const codes = pwv5Colors(redw, greenw, blue);
            // The lagged normalizer: peak over [r_f, r_c-1], one record
            // behind the stores.
            var lag: u16 = 0;
            if (grid.r_c[c] > grid.r_f[c]) {
                var mx0: i16 = std.math.minInt(i16);
                var mn1: i16 = std.math.maxInt(i16);
                var k: i64 = grid.r_f[c];
                while (k < grid.r_c[c]) : (k += 1) {
                    mx0 = @max(mx0, w.recs[@intCast(k)].mmax);
                    mn1 = @min(mn1, w.recs[@intCast(k)].mmin);
                }
                lag = @intCast(@min(@max(@abs(mx0), @abs(mn1)), 32767));
            }
            p5 = @max(p5, lag);
            peaks[c] = @intCast(@min(@max(@abs(ch0), @abs(ch1)), 32767));
            out[c] = (@as(u16, codes.red) << 13) | (@as(u16, codes.green) << 10) |
                (@as(u16, codes.blue) << 7); // height bits filled in pass 2
        }
        for (0..n_columns) |c| {
            // h = trunc(u² · 31.488/32767²) with u = trunc(peak/P·32767),
            // deliberately not clamped before the &0x1f: with the lagged
            // P the ratio can exceed 1 and the excess wraps.
            var h: u16 = 0;
            if (p5 > 0) {
                const u = @trunc(@as(f64, @floatFromInt(peaks[c])) / @as(f64, @floatFromInt(p5)) * 32767.0);
                h = @truncate(@as(u64, @intFromFloat(@trunc(u * u * height_c))));
            }
            out[c] |= h << 2;
        }
        return out;
    }

    // ---- PWV4 ----

    /// The six PWV4 bytes per span: {monoMax, monoMin, LPF400peak,
    /// LOW·share, MID·share, HIGH·share}, each `(u8)(v/256)` of the
    /// span-aggregated record fields (LOW widens to [r-12, r+12], MID to
    /// [r-1, r+1] at span end).
    fn pwv4(w: *const WaveCreator, alloc: std.mem.Allocator) ![][6]u8 {
        const d = w.d;
        const out = try alloc.alloc([6]u8, 1200);
        errdefer alloc.free(out);
        @memset(std.mem.sliceAsBytes(out), 0);
        if (d == 0) return out;
        for (0..1200) |j| {
            const rs = spanStart(d, j);
            const re_ = spanEnd(d, j);
            if (re_ < rs) continue;
            var vals = [6]f64{ 0, 0, 0, 0, 0, 0 };
            var v0: i16 = std.math.minInt(i16);
            var v1: i16 = std.math.maxInt(i16);
            var v2: u16 = 0;
            var v5: i16 = std.math.minInt(i16);
            for (rs..re_ + 1) |k| {
                v0 = @max(v0, w.recs[k].mmax);
                v1 = @min(v1, w.recs[k].mmin);
                v2 = @max(v2, w.recs[k].w400);
                v5 = @max(v5, w.recs[k].s5);
            }
            vals[0] = @floatFromInt(v0);
            vals[1] = @floatFromInt(v1);
            vals[2] = @floatFromInt(v2);
            vals[5] = @floatFromInt(v5);
            {
                const lo = clampToRecords(@as(i64, @intCast(rs)) - 12, d);
                const hi = clampToRecords(@as(i64, @intCast(re_)) + 12, d);
                var v3: i16 = std.math.minInt(i16);
                var k: i64 = lo;
                while (k <= hi) : (k += 1) v3 = @max(v3, w.recs[@intCast(k)].s3);
                vals[3] = @floatFromInt(v3);
            }
            {
                const lo = clampToRecords(@as(i64, @intCast(rs)) - 1, d);
                const hi = clampToRecords(@as(i64, @intCast(re_)) + 1, d);
                var v4: i16 = std.math.minInt(i16);
                var k: i64 = lo;
                while (k <= hi) : (k += 1) v4 = @max(v4, w.recs[@intCast(k)].s4);
                vals[4] = @floatFromInt(v4);
            }
            for (0..6) |f| out[j][f] = @intCast(@as(i64, @intFromFloat(@trunc(vals[f] / 256.0))) & 0xFF);
        }
        return out;
    }
};

/// First/last record of detail column c: r_c = min(ceil(D·(c+1)/N) − 1,
/// D−1), r_f = min(ceil(D·c/N), D).
const ColumnGrid = struct { r_f: []i64, r_c: []i64 };

fn columnGrid(alloc: std.mem.Allocator, d: usize, n_columns: usize) !ColumnGrid {
    const r_f = try alloc.alloc(i64, n_columns);
    errdefer alloc.free(r_f);
    const r_c = try alloc.alloc(i64, n_columns);
    for (0..n_columns) |c| {
        r_c[c] = @min(@as(i64, @intCast(ceilDiv(d * (c + 1), n_columns))) - 1, @as(i64, @intCast(d)) - 1);
        r_f[c] = @min(@as(i64, @intCast(ceilDiv(d * c, n_columns))), @as(i64, @intCast(d)));
    }
    return .{ .r_f = r_f, .r_c = r_c };
}

/// First column of preview span `j` of `size` over a `d`-long grid, on the
/// Bresenham partition the analyzer's own span helpers use; spans tile the
/// grid (`spanEndOf` is inclusive).
fn spanStartOf(d: usize, j: usize, size: usize) usize {
    if (j == 0) return 0;
    return spanEndOf(d, j - 1, size) + 1;
}

/// Last column of preview span `j` of `size`:
/// `min(ceil(d·(j+1)/size) − 1, d − 1)`; empty spans (possible once
/// `d < size`) end before their start.
fn spanEndOf(d: usize, j: usize, size: usize) usize {
    if (d == 0) return 0;
    return @min(ceilDiv(d * (j + 1), size) - 1, d - 1);
}

/// The 1200-span PWAV/PWV4/PWV6 grid over the per-millisecond record bank.
fn spanStart(d: usize, j: usize) usize {
    return spanStartOf(d, j, 1200);
}

fn spanEnd(d: usize, j: usize) usize {
    return spanEndOf(d, j, 1200);
}

/// The adaptive per-band scales and the PWV6 preview bytes, computed over
/// a band-peak bank on either grid the library drives: the WaveCreator's
/// per-millisecond records (`per_second = 1000`) or the stats route's
/// 150 Hz columns (`per_second = 150`). Rekordbox's own derivation,
/// transcribed: per-span band averages extended by trailing 1 s / ⅔ s /
/// ⅓ s windows (zero-filled before the start), band-balance weights w_k
/// plus a span-max gain g, per-band peak caps, the [0.8, lim] clamps — and
/// PWV6's bytes `(u8)(clamp(w_k) · avg / 256)`.
const AdaptiveScales = struct {
    /// Per-band scale as u16·100 (the PWV7 quantizer's format).
    scale_u16: [3]u16,
    /// The 1200 PWV6 columns.
    pwv6: [1200][3]u8,
};

fn bandScalesAndPreview(alloc: std.mem.Allocator, vals: []const [3]u16, per_second: usize) std.mem.Allocator.Error!AdaptiveScales {
    const d = vals.len;
    var vmax: u16 = 0;
    for (vals) |v| {
        for (v) |x| vmax = @max(vmax, x);
    }
    if (d == 0 or vmax == 0) {
        // All-silence track: the scales stay at the ctor init (100 → 1.0)
        // and PWV6 is all zero.
        return .{ .scale_u16 = .{ 100, 100, 100 }, .pwv6 = [_][3]u8{.{ 0, 0, 0 }} ** 1200 };
    }
    const s_sec = d / per_second;
    const widths = [3]usize{ s_sec, (s_sec * 2) / 3, s_sec / 3 };

    const avg = try alloc.alloc([3]f64, 1200);
    defer alloc.free(avg);
    const scratch = try alloc.alloc(f64, d);
    defer alloc.free(scratch);

    for (0..1200) |j| {
        const rs = spanStart(d, j);
        const re_ = spanEnd(d, j);
        for (0..3) |b| {
            const wd = widths[b];
            const lo_: usize = if (rs >= wd) rs - wd else 0;
            for (lo_..re_ + 1) |k| scratch[k - lo_] = @floatFromInt(vals[k][b]);
            const sums = npSum(scratch[0 .. re_ + 1 - lo_]);
            const cnts: f64 = if (rs >= wd)
                @floatFromInt(re_ + 1 - lo_)
            else
                // Pre-start zero-filled records count toward the average.
                @floatFromInt(wd - rs + re_ + 1);
            avg[j][b] = sums / cnts;
        }
    }

    // Sum over rows sequentially; the order matters.
    var s = [3]f64{ 0, 0, 0 };
    for (avg) |row| {
        s[0] += row[0];
        s[1] += row[1];
        s[2] += row[2];
    }
    var w_k: [3]f64 = undefined;
    const pos = [3]bool{ s[0] > 0, s[1] > 0, s[2] > 0 };
    if (pos[0] and pos[1] and pos[2]) {
        const mx = @max(s[0], @max(s[1], s[2]));
        for (0..3) |b| w_k[b] = mx / s[b];
    } else {
        var base: f64 = std.math.inf(f64);
        for (0..3) |b| {
            if (pos[b]) base = @min(base, s[b]);
        }
        for (0..3) |b| w_k[b] = if (pos[b]) base / @max(s[b], 1e-300) else 1.0;
    }
    // max over the row terms must propagate NaN (sub-1.2 s tracks have
    // empty Bresenham spans whose 0/0 averages poison bands with w = 0),
    // and `gspan > 0` then selects the g = 1.0 branch — unlike Zig's
    // NaN-ignoring @max.
    var gspan: f64 = -std.math.inf(f64);
    for (avg) |row| {
        const t = (w_k[0] * row[0] + w_k[1] * row[1]) + w_k[2] * row[2];
        if (std.math.isNan(gspan)) break;
        if (std.math.isNan(t)) {
            gspan = std.math.nan(f64);
        } else {
            gspan = @max(gspan, t);
        }
    }
    const g: f64 = if (gspan > 0) 32768.0 / gspan else 1.0;
    for (0..3) |b| w_k[b] *= g;

    var peaks = [3]f64{ 0, 0, 0 };
    for (vals) |v| {
        for (0..3) |b| peaks[b] = @max(peaks[b], @as(f64, @floatFromInt(v[b])));
    }
    const peak2p = 16384.0 * (1.0 - @cos(std.math.pi * peaks[2] * (1.0 / 32768.0)));
    const lim_hi = [3]f64{ 3.0, 3.0, 5.0 };
    const caps = [3]f64{ 32768.0 / peaks[0], 32768.0 / peaks[1], 32768.0 / peak2p };

    var result: AdaptiveScales = .{ .scale_u16 = .{ 100, 100, 100 }, .pwv6 = undefined };
    for (0..3) |b| {
        var v = if (caps[b] > 0) @min(w_k[b], caps[b]) else w_k[b];
        v = @min(@max(v, 0.8), lim_hi[b]);
        result.scale_u16[b] = @intFromFloat(v * 100.0);
        // PWV6 bytes: (char)(clamp(w_k) · avg / 256) — the clamped w_k
        // without the peak caps.
        const wc = @min(@max(w_k[b], 0.8), lim_hi[b]);
        for (0..1200) |j| {
            const t = @trunc(wc * avg[j][b] / 256.0);
            // NaN averages (empty spans) encode as 0.
            result.pwv6[j][b] = if (std.math.isNan(t)) 0 else @intCast(@as(i64, @intFromFloat(t)) & 0xFF);
        }
    }
    return result;
}

/// clip(x, 0, D−1) over the record index space.
fn clampToRecords(x: i64, d: usize) i64 {
    return @min(@max(x, 0), @as(i64, @intCast(d)) - 1);
}

// ---------------------------------------------------------------------------
// PWV3 + whiteness engine
// ---------------------------------------------------------------------------

/// The s16 path: per 294-sample column, the peak of the truncated
/// `(L+R)/2` mix and the peak of its 150 Hz tan-form lowpass, quantized by
/// `anlz.detailHeightCode` and `anlz.whitenessRatio`.
const Pwv3Engine = struct {
    n: usize,
    n_columns: usize,
    peak: []u16,
    fpeak: []u16,
    lpf: Biquad,
    pk: u16 = 0, // open-column |mono16| peak
    fp: u16 = 0, // open-column filtered peak
    open: usize = 0,

    fn init(alloc: std.mem.Allocator, n: usize) !Pwv3Engine {
        const n_columns = ceilDiv(n, 294);
        return .{
            .n = n,
            .n_columns = n_columns,
            .peak = try alloc.alloc(u16, n_columns),
            .fpeak = try alloc.alloc(u16, n_columns),
            .lpf = cookLpf150Tan(),
        };
    }

    /// `mono16` is the truncated s16 mono sample as an integer.
    fn push(e: *Pwv3Engine, mono16: i32) void {
        const m: f64 = @floatFromInt(mono16);
        const ab: i32 = if (mono16 < 0) -mono16 else mono16;
        e.pk = @max(e.pk, @as(u16, @intCast(@min(ab, 32767))));
        const f = e.lpf.proc(m);
        const fpv: i64 = @intFromFloat(@min(@abs(@trunc(f)), 32767.0));
        e.fp = @max(e.fp, @as(u16, @intCast(fpv)));
    }

    fn closeColumn(e: *Pwv3Engine, c: usize) void {
        e.peak[c] = e.pk;
        e.fpeak[c] = e.fp;
        e.pk = 0;
        e.fp = 0;
        e.open = c + 1;
    }

    /// The PWV3 bytes: whiteness in the top three bits, height below.
    fn bytes(e: *const Pwv3Engine, alloc: std.mem.Allocator) ![]u8 {
        const out = try alloc.alloc(u8, e.n_columns);
        errdefer alloc.free(out);
        var p: u16 = 0;
        for (e.peak) |pk| p = @max(p, pk);
        for (0..e.n_columns) |c| {
            const w = whitenessRatio(e.fpeak[c], e.peak[c]);
            const h = detailHeightCode(e.peak[c], p);
            out[c] = (@as(u8, w) << 5) | h;
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// PWAV/PWV2 writer engine
// ---------------------------------------------------------------------------

const chunk_samples = 588;
/// Detector record capacity.
const det_cap = 36000;
const det_rec_len = det_cap + 4;

/// The full-rate hysteresis peak tracker. The idle check is equality
/// against the 0.01f marker itself; the run counter is stored as float
/// and truncated on read; the ride path does not reset the 512-sample
/// idle counter; the level decays ×0.993830323 after ≥ fs·1.714 samples
/// idle. The idle counter resets at every 588-sample call entry and
/// never persists across chunks.
const DetA = struct {
    tag: i32, // 0 band1, 1 band2, 2 band3
    total: usize,
    pos: usize = 0,
    count: i32 = 0,
    shadow: i32 = 0,
    runf: f32 = 0.0,
    idle: i32 = 0,
    level: f32 = mark1,
    rec: []f32,
    counts: []i32,
    raised: []i32, // only written for tag 0 (the group-cut flag)

    const mark1: f32 = 0.009999999776482582; // exact f32 of 0.01
    const thr1: f64 = 0.01;
    const droop: f32 = 0.75;
    const droop3: f32 = 0.660000026; // band 3
    const decay: f32 = 0.993830323;
    const idle_run: f64 = 44100.0 * 1.714;
    const close_run: f64 = 44100.0 * 0.32;
    const idle_lim: i32 = 512;

    fn init(alloc: std.mem.Allocator, tag: i32, total: usize, n_slots: usize) !DetA {
        const rec = try alloc.alloc(f32, det_rec_len);
        @memset(rec, 0);
        rec[0] = mark1;
        const counts = try alloc.alloc(i32, n_slots);
        @memset(counts, 0);
        const raised = try alloc.alloc(i32, n_slots);
        @memset(raised, 0);
        return .{ .tag = tag, .total = total, .rec = rec, .counts = counts, .raised = raised };
    }

    /// Processes one chunk; `c` is the 1-based chunk index.
    fn chunk(st: *DetA, s: []const f32, c: usize) void {
        const drp: f32 = if (st.tag == 2) droop3 else droop;
        var shadow = st.shadow;
        st.idle = 0; // register local: reset at every call entry
        for (s) |x| {
            st.runf = @floatFromInt(@as(i32, @intFromFloat(st.runf)) + 1);
            const run: i32 = @intFromFloat(st.runf);
            if (st.rec[0] == mark1) { // idle
                if (@as(f64, x) > thr1) {
                    st.rec[0] = x;
                    st.count = 1;
                    shadow = 1;
                    st.runf = 0.0;
                    st.level = x;
                    if (st.tag == 0) st.raised[c - 1] = 1;
                }
            } else {
                const ride = if (@as(f64, st.level) <= thr1)
                    @as(f64, x) >= thr1
                else
                    !(x < st.level * drp);
                if (ride) {
                    if (@as(f64, @floatFromInt(run)) < close_run) {
                        if (st.level < x) st.level = x;
                    } else {
                        // Close.
                        if (st.tag == 0) st.raised[c - 1] = 1;
                        st.runf = 0.0;
                        if (st.count >= 1 and shadow >= 1 and shadow - 1 < det_rec_len)
                            st.rec[@intCast(shadow - 1)] = st.level;
                        st.count += 1;
                        shadow += 1;
                        st.idle = 0;
                        st.level = x;
                    }
                } else {
                    // Droop / below-threshold path.
                    if (@as(f64, @floatFromInt(run)) > idle_run) {
                        st.idle += 1;
                        if (!(st.idle < idle_lim)) {
                            st.level = st.level * decay;
                            if (@as(f64, st.level) <= thr1) st.level = mark1;
                            st.idle = 0;
                        }
                    } else {
                        st.idle = 0;
                    }
                }
            }
            st.pos += 1;
            // End-of-track flush.
            if (st.pos == st.total) {
                if (shadow < det_rec_len) st.rec[@intCast(shadow)] = st.level;
                st.count += 1;
                shadow += 1;
            }
        }
        st.shadow = shadow;
        if (st.count < det_cap) st.rec[@intCast(st.count)] = st.level; // end-of-call working flush
        st.counts[c - 1] = st.count;
    }
};

/// The every-4th-sample variant driving PWV2. The phase counter doubles
/// as the run and re-anchors the eval grid after each close; the window
/// max is zeroed at every call entry (partial windows at chunk boundaries
/// are dropped); the decay floor is the 327.679993 threshold itself, not
/// the 0.01 marker.
const DetB = struct {
    total: usize,
    pos: usize = 0,
    count: i32 = 0,
    shadow: i32 = 0,
    phase: i32 = 0,
    idle: i32 = 0,
    wmax: f32 = 0.0,
    level: f32 = DetA.mark1,
    rec: []f32,
    counts: []i32,

    const thr2: f32 = 327.679993; // exact f32 of 327.68
    const idle_lim: i32 = 512;

    fn init(alloc: std.mem.Allocator, total: usize, n_slots: usize) !DetB {
        const rec = try alloc.alloc(f32, det_rec_len);
        @memset(rec, 0);
        rec[0] = DetA.mark1;
        const counts = try alloc.alloc(i32, n_slots);
        @memset(counts, 0);
        return .{ .total = total, .rec = rec, .counts = counts };
    }

    fn chunk(st: *DetB, s: []const f32, c: usize) void {
        var shadow = st.shadow;
        st.wmax = 0.0;
        st.idle = 0; // register local: reset at every call entry
        for (s, 0..) |x, i| {
            st.phase += 1;
            if (st.wmax < x) st.wmax = x;
            var ev = @mod(st.phase, 4) == 0;
            if (!ev and s.len < chunk_samples) {
                // Last sample of the track?
                if ((c - 1) * chunk_samples + i == st.total - 1) ev = true;
            }
            if (ev) {
                const w = st.wmax;
                if (st.rec[0] == DetA.mark1) { // idle
                    if (thr2 < w) {
                        st.rec[0] = w;
                        st.count = 1;
                        shadow = 1;
                        st.phase = 0;
                        st.level = w;
                    }
                } else {
                    const ride = if (st.level <= thr2)
                        thr2 <= w
                    else
                        !(w < st.level * DetA.droop);
                    if (ride) {
                        if (@as(f64, @floatFromInt(st.phase)) < DetA.close_run) {
                            if (st.level <= w) st.level = w;
                        } else {
                            st.phase = 0;
                            if (shadow < det_cap) st.rec[@intCast(shadow)] = st.level;
                            st.count += 1;
                            shadow += 1;
                            st.idle = 0;
                            st.level = w;
                        }
                    } else {
                        if (@as(f64, @floatFromInt(st.phase)) > DetA.idle_run) {
                            st.idle += 4;
                            if (!(st.idle < idle_lim)) {
                                st.level *= DetA.decay;
                                if (st.level < thr2) st.level = thr2;
                                st.idle = 0;
                            }
                        } else {
                            st.idle = 0;
                        }
                    }
                }
                // End-of-track flush.
                if (st.pos == st.total - 1) {
                    if (shadow < det_cap) st.rec[@intCast(shadow)] = st.level;
                    st.count += 1;
                    shadow += 1;
                }
                st.wmax = 0.0;
            }
            st.pos += 1;
        }
        st.shadow = shadow;
        if (st.count < det_cap) st.rec[@intCast(st.count)] = st.level;
        st.counts[c - 1] = st.count;
    }
};

/// One direct-form-1 biquad in float64.
const Bq1 = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64 = 0.0,
    x2: f64 = 0.0,
    y1: f64 = 0.0,
    y2: f64 = 0.0,

    fn proc(q: *Bq1, x: f64) f64 {
        const y = (((x * q.b0 + q.b1 * q.x1) + q.b2 * q.x2) - q.a1 * q.y1) - q.a2 * q.y2;
        q.x2 = q.x1;
        q.x1 = x;
        q.y2 = q.y1;
        q.y1 = y;
        return y;
    }

    /// BP@150.
    fn cookBp150() Bq1 {
        const w = 942.477796076937 / fs;
        const s = @sin(w);
        const c = @cos(w);
        const al = s * 0.5555555702727522;
        const den = al + 1.0;
        return .{
            .b0 = al / den,
            .b1 = 0.0,
            .b2 = (-1.0 / den) * al,
            .a1 = c * (-2.0 / den),
            .a2 = (1.0 - al) / den,
        };
    }

    /// HP cook: Q = 0.707106769 (stored, ≈1/√2); the 2π literal is the
    /// stored constant, not `std.math.tau`.
    fn cookHp(fc: f64) Bq1 {
        const q = 0.707106769;
        const w = (fc * 6.28318530717958) / fs;
        const s = @sin(w);
        const c = @cos(w);
        const al = s * (0.5 / q);
        const den = al + 1.0;
        return .{
            .b0 = ((c + 1.0) * 0.5) / den,
            .b1 = (-1.0 - c) / den,
            .b2 = ((c + 1.0) * 0.5) / den,
            .a1 = c * (-2.0 / den),
            .a2 = (1.0 - al) / den,
        };
    }

    /// LP cook, same constants as `cookHp`.
    fn cookLp(fc: f64) Bq1 {
        const q = 0.707106769;
        const w = (fc * 6.28318530717958) / fs;
        const s = @sin(w);
        const c = @cos(w);
        const al = s * (0.5 / q);
        const den = al + 1.0;
        return .{
            .b0 = (0.5 / den) * (1.0 - c),
            .b1 = (1.0 - c) / den,
            .b2 = (0.5 / den) * (1.0 - c),
            .a1 = c * (-2.0 / den),
            .a2 = (1.0 - al) / den,
        };
    }
};

/// PWAV height thresholds: height = 2 + #{T ≤ max(0, level)}.
const pwav_ladder = [23]f64{
    2195.4560546875, 3112.9599609375,  4096.0,          5079.0400390625,
    6062.080078125,  7045.1201171875,  8028.16015625,   9011.2001953125,
    9994.240234375,  10977.2802734375, 11960.3203125,   12943.3603515625,
    13926.400390625, 14909.4404296875, 15892.48046875,  17367.0390625,
    19333.119140625, 21299.19921875,   23265.279296875, 25886.720703125,
    30801.919921875, 39321.6015625,    50790.3984375,
};

/// PWV2 height thresholds.
const pwv2_ladder = [13]i64{ 1304, 1642, 2067, 2602, 3276, 4125, 5193, 6538, 8230, 10362, 13045, 16422, 20675 };

fn pwavLadder(v_: f32) i64 {
    const v = v_;
    if (v <= 0) return 2;
    var n: i64 = 0;
    const vf: f64 = v;
    for (pwav_ladder) |t| {
        if (t <= vf) n += 1;
    }
    return 2 + n;
}

fn pwv2LadderVal(v: i64) i64 {
    var n: i64 = 0;
    for (pwv2_ladder) |t| {
        if (t <= v) n += 1;
    }
    return 2 + n;
}

/// The band dB code (PWAV record fields F2/F3/F4):
/// `(int)clamp((float)(log10(v·2⁻¹⁵)·20) + 30.5f, 0, 30)` — float32 steps
/// around a float64 log10.
fn dbcode(v32: f32) i64 {
    const x = v32;
    if (x > 0) {
        const xv: f64 = @as(f64, x * @as(f32, 3.05175781e-05));
        var d: f32 = @as(f32, @floatCast(std.math.log10(xv) * 20.0)) + @as(f32, 30.5);
        if (d < 0) d = 0.0;
        if (@as(f32, 30.0) <= d) d = 30.0;
        return @intFromFloat(d);
    }
    return 0;
}

/// The PWAV top-3-bits class: with a = F2 and d = F3−F4,
/// `a<14 → (d ≤ 3 ? 5 : 4)`; `d<0 → 2 + ((a−F4) ≤ 0)`; else `(a−F3) ≤ 0`.
fn pwavClass(f2: i64, f3: i64, f4: i64) u3 {
    const a = f2;
    const d = f3 - f4;
    if (a < 14) {
        return if (d <= 3) 5 else 4;
    }
    if (d < 0) {
        return @intCast(2 + @as(u3, @intFromBool(a - f4 <= 0)));
    }
    return @intFromBool(a - f3 <= 0);
}

/// Three band signals through exact DF1-double biquads, the two crossing
/// detectors, and the span/level choreography that emits the PWAV/PWV2
/// records: a 9-chunk group cadence beats against the 400-span time grid
/// (band-1 record closes cut groups short and arm a one-group divert),
/// the PWAV float is scaled by a band-1 activity gate, and the band spans
/// live on a stride-2 pair grid.
const PwavPwv2Engine = struct {
    n: usize,
    nceil: usize,
    nchunks: usize,
    /// 1-based index of the last processed chunk (real pieces, plus the
    /// rare f32 phantom past them); `islast` fires here.
    last_chunk: usize,
    cps: usize,
    f38: f32,
    span_credit: f32,
    lvl_rescale: f32,
    band_rescale: f32,

    det_a: [3]DetA,
    det_b: [2]DetB,

    // Band filters: band1 = BP150², band2 = HP283→LP6000→HP283→LP6000,
    // band3 = HP6000².
    q1: [2]Bq1,
    q2: [4]Bq1,
    q3: [2]Bq1,

    band: [3][chunk_samples]f32 = undefined,
    mono_abs: [chunk_samples]f64 = undefined,
    buf_len: usize = 0,

    // Writer choreography state.
    arr1b8: [400]f32 = [_]f32{0} ** 400,
    grp_cnt: i64 = 0,
    grp_sum: f32 = 0.0,
    lvl_span: i64 = 0,
    lvl_carry: f32 = 0.0,
    armed: u8 = 0,
    pending: u8 = 0,
    last_add_span: i64 = 0,
    b_acc: [3][400]f32 = [_][400]f32{[_]f32{0} ** 400} ** 3,
    b_span: [3]i64 = .{ 0, 0, 0 },
    b_credit: [3]f32 = .{ 0, 0, 0 },
    b_cursor: [3]i64 = .{ 0, 0, 0 },
    b_prev: [3]i64 = .{ 0, 0, 0 },
    p_acc: [2][100]i64 = [_][100]i64{[_]i64{0} ** 100} ** 2,
    p_span: [2]i64 = .{ 0, 0 },
    p_prev: [2]i64 = .{ 0, 0 },
    pwav_f: [400][5]i64 = [_][5]i64{[_]i64{0} ** 5} ** 400,
    pwav_cursor: i64 = 0,
    pwv2_code: [100]i64 = [_]i64{0} ** 100,
    pwv2_cursor: i64 = 0,

    fn init(alloc: std.mem.Allocator, n: usize) !PwavPwv2Engine {
        // The analyzer's engine total is the last sample index n-1, not
        // the sample count, and the PWV2 chunks-per-span is
        // ((n-1)/588)/100 — one less than n/588/100 whenever n is an
        // exact multiple of 58800. nceil (the float32 ceil of the same
        // field) is unchanged for every n % 588 != 1.
        const tot = if (n > 0) n - 1 else 0;
        // nceil comes from a float32 ceil of the chunk division; on
        // rounding it can exceed the integer nchunks by one.
        const nceil: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(tot)) / @as(f32, chunk_samples)));
        const nchunks = ceilDiv(n, chunk_samples);
        const n_slots = @max(nceil, nchunks) + 2;
        return .{
            .n = n,
            .nceil = nceil,
            .nchunks = nchunks,
            .last_chunk = @max(nceil, nchunks),
            .cps = @max(1, tot / chunk_samples / 100),
            .f38 = divF32(400.0, nceil),
            .span_credit = @as(f32, @floatFromInt(nceil)) * @as(f32, 0.005),
            .lvl_rescale = divF32(15000.0, nceil),
            .band_rescale = @as(f32, 0.5) / (@as(f32, @floatFromInt(nceil)) * @as(f32, 0.005)),
            .det_a = .{
                try DetA.init(alloc, 0, n, n_slots),
                try DetA.init(alloc, 1, n, n_slots),
                try DetA.init(alloc, 2, n, n_slots),
            },
            .det_b = .{
                try DetB.init(alloc, n, n_slots),
                try DetB.init(alloc, n, n_slots),
            },
            .q1 = .{ Bq1.cookBp150(), Bq1.cookBp150() },
            .q2 = .{ Bq1.cookHp(283.0), Bq1.cookLp(6000.0), Bq1.cookHp(283.0), Bq1.cookLp(6000.0) },
            .q3 = .{ Bq1.cookHp(6000.0), Bq1.cookHp(6000.0) },
        };
    }

    fn divF32(a: f32, b: usize) f32 {
        if (b == 0) return std.math.inf(f32);
        return a / @as(f32, @floatFromInt(b));
    }

    /// Streams one sample: `mono32` is the f32 (L+R)·2⁻¹⁶ mix,
    /// `mono20` its ×32768 f32 image.
    fn push(e: *PwavPwv2Engine, mono32: f32, mono20: f32) void {
        const x: f64 = mono32;
        const y1 = e.q1[1].proc(e.q1[0].proc(x));
        var t = e.q2[0].proc(x);
        t = e.q2[1].proc(t);
        t = e.q2[2].proc(t);
        t = e.q2[3].proc(t);
        const y3 = e.q3[1].proc(e.q3[0].proc(x));
        e.band[0][e.buf_len] = absF32(y1) * 32768.0;
        e.band[1][e.buf_len] = absF32(t) * 32768.0;
        e.band[2][e.buf_len] = absF32(y3) * 32768.0;
        e.mono_abs[e.buf_len] = @abs(@as(f64, mono20));
        e.buf_len += 1;
    }

    fn absF32(y: f64) f32 {
        const f: f32 = @floatCast(y);
        return if (f < 0) -f else f;
    }

    fn bufferFull(e: *const PwavPwv2Engine) bool {
        return e.buf_len == chunk_samples;
    }

    /// Runs the detectors and the writer choreography over the buffered
    /// chunk; `c` is the 1-based chunk index.
    fn endChunk(e: *PwavPwv2Engine, c: usize) void {
        const s0 = e.band[0][0..e.buf_len];
        e.det_a[0].chunk(s0, c);
        e.det_a[1].chunk(e.band[1][0..e.buf_len], c);
        e.det_a[2].chunk(e.band[2][0..e.buf_len], c);
        e.det_b[0].chunk(s0, c);
        e.det_b[1].chunk(e.band[1][0..e.buf_len], c);
        e.runChunk(c);
        e.buf_len = 0;
    }

    /// The writer body for chunk `c`. Also called with an empty buffer for
    /// float32-rounding phantom chunks past the last real one.
    fn runChunk(e: *PwavPwv2Engine, c: usize) void {
        const islast = c == e.last_chunk;
        const flag1ec = e.det_a[0].raised[c - 1] != 0;
        const nch = e.nceil;

        // 9-chunk group of |mono|·32768, cut short by band-1 record closes.
        // The sum is a sequential f32 accumulation in sample order (carry
        // = ((a0+carry)+a1)+a2+…), not a wider or pairwise sum — the f32
        // rounding is part of the format's behavior.
        e.grp_cnt += 1;
        for (e.mono_abs[0..e.buf_len]) |x| e.grp_sum += @as(f32, @floatCast(x));
        var completed = false;
        var bufd8: f32 = 0.0;
        if (e.grp_cnt > 8 or flag1ec) {
            bufd8 = e.grp_sum / @as(f32, @floatFromInt(chunk_samples * @as(usize, @intCast(e.grp_cnt))));
            if (e.armed == 1) {
                e.pending = 1;
                e.armed = 0;
            }
            if (flag1ec) e.armed = 1;
            e.grp_cnt = 0;
            e.grp_sum = 0.0;
            completed = true;
        }

        // Level accumulator arr1b8 on the time-driven 400-span grid.
        var target: i64 = @intFromFloat(@as(f32, @floatFromInt(c)) * e.f38);
        if (target > 399) target = 399;
        if (islast) target = 400;
        if (e.lvl_span + 1 <= target) {
            e.arr1b8[@intCast(e.lvl_span)] = (e.lvl_carry * @as(f32, 75.0)) * divF32(200.0, nch);
            var j = e.lvl_span + 1;
            var sp = e.lvl_span;
            while (j <= target) : (j += 1) {
                sp += 1;
                if (sp < 400) e.arr1b8[@intCast(j)] = 0.0;
            }
            e.lvl_span = sp;
        } else if (e.lvl_span < 400) {
            e.arr1b8[@intCast(e.lvl_span)] = e.lvl_carry;
        }
        if (completed and e.lvl_span < 400) {
            if (e.pending == 1) {
                const old = e.last_add_span;
                var v = bufd8;
                if (e.lvl_span != old) v = v * e.lvl_rescale;
                e.arr1b8[@intCast(old)] = e.arr1b8[@intCast(old)] + v;
            } else {
                e.arr1b8[@intCast(e.lvl_span)] = e.arr1b8[@intCast(e.lvl_span)] + bufd8;
                e.last_add_span = e.lvl_span;
            }
            e.pending = 0;
        }
        if (e.lvl_span < 400) e.lvl_carry = e.arr1b8[@intCast(e.lvl_span)];

        // PWAV band accumulators (stride-2 pair grid).
        for (0..3) |bix| {
            if (e.b_span[bix] >= 400) continue;
            const count: i64 = e.det_a[bix].counts[c - 1];
            const tgt: i64 = if (islast) count else count - 1;
            if (!(islast or e.b_prev[bix] < count - 1)) continue;
            const acc = &e.b_acc[bix];
            var span = e.b_span[bix];
            var credit = @as(f32, @floatFromInt(@as(i64, @intCast(c)) - e.b_cursor[bix])) + e.b_credit[bix];
            const lv = e.det_a[bix].rec;
            var ri = e.b_prev[bix];
            while (ri < @max(e.b_prev[bix], tgt)) : (ri += 1) {
                if (credit >= e.span_credit) {
                    if (span > 399) break;
                    credit -= e.span_credit;
                    const v = (acc[@intCast(span)] * @as(f32, 75.0)) * e.band_rescale;
                    acc[@intCast(span)] = v;
                    if (span + 1 < 400) acc[@intCast(span + 1)] = v;
                    var ns = span + 2;
                    while (credit >= e.span_credit) {
                        if (ns > 399) break;
                        credit -= e.span_credit;
                        acc[@intCast(ns)] = 0.0;
                        if (ns + 1 < 400) acc[@intCast(ns + 1)] = 0.0;
                        ns += 2;
                    }
                    span = ns;
                    if (span < 400) acc[@intCast(span)] = 0.0;
                }
                if (!(ri == tgt - 1 and islast)) {
                    if (span < 400 and ri < det_cap) {
                        acc[@intCast(span)] = acc[@intCast(span)] + @as(f32, @floatFromInt(@as(i64, @intFromFloat(@trunc(lv[@intCast(ri)])))));
                    }
                }
            }
            e.b_prev[bix] = @max(e.b_prev[bix], tgt);
            e.b_cursor[bix] = @intCast(c);
            e.b_credit[bix] = credit;
            e.b_span[bix] = @min(span, 400);
        }

        // PWV2 accumulators.
        for (0..2) |bix| {
            if (e.p_span[bix] >= 100) continue;
            const count: i64 = e.det_b[bix].counts[c - 1];
            var target2: i64 = @as(i64, @intCast(c / e.cps));
            if (target2 > 99) target2 = 99;
            if (islast) target2 = 100;
            const acc = &e.p_acc[bix];
            var span = e.p_span[bix];
            if (span + 1 <= target2) {
                acc[@intCast(span)] = @divFloor(acc[@intCast(span)] * 75, @as(i64, @intCast(e.cps * 2)));
                var j = span + 1;
                var sp = span;
                while (j <= target2) : (j += 1) {
                    sp += 1;
                    if (sp < 100) acc[@intCast(j)] = 0;
                }
                span = sp;
            }
            if (e.p_prev[bix] < count) {
                if (span < 100 and c > 50 and e.p_prev[bix] < det_cap) {
                    acc[@intCast(span)] += @intFromFloat(@trunc(e.det_b[bix].rec[@intCast(e.p_prev[bix])]));
                }
            }
            e.p_prev[bix] = count;
            e.p_span[bix] = span;
        }

        // PWAV span-record loop.
        const n19c: i64 = if (islast) 400 else @min(@min(e.lvl_span, e.b_span[0]), @min(e.b_span[1], e.b_span[2]));
        if (e.pwav_cursor < n19c) {
            var i = e.pwav_cursor;
            while (i < n19c) : (i += 1) {
                const iu: usize = @intCast(i);
                const f4f = e.arr1b8[iu];
                const f2 = dbcode(e.b_acc[0][iu] * @as(f32, 0.5));
                const f3 = dbcode(e.b_acc[1][iu] * @as(f32, 0.25));
                const f4 = dbcode(e.b_acc[2][iu]);
                var gate = (e.b_acc[0][iu] / @as(f32, 32768.0)) * @as(f32, 0.75) + @as(f32, 0.25);
                if (@as(f32, 1.0) < gate) gate = 1.0;
                const v = gate * f4f;
                e.pwav_f[iu] = .{ pwavLadder(v), pwavLadder(f4f), f2, f3, f4 };
            }
            e.pwav_cursor = n19c;
        }

        // PWV2 record loop.
        const n1ac: i64 = if (islast) 100 else @min(e.p_span[0], e.p_span[1]);
        if (e.pwv2_cursor < n1ac) {
            var i = e.pwv2_cursor;
            while (i < n1ac) : (i += 1) {
                const iu: usize = @intCast(i);
                const v = e.p_acc[0][iu];
                if (v == 0) {
                    // A zero band-1 accumulator encodes 1, or 2 when the
                    // band-2 accumulator is nonzero.
                    e.pwv2_code[iu] = if (e.p_acc[1][iu] == 0) 1 else 2;
                } else {
                    e.pwv2_code[iu] = pwv2LadderVal(v);
                }
            }
            e.pwv2_cursor = n1ac;
        }
    }

    const Bytes = struct { pwav: [400]u8, pwv2: [100]u8 };

    /// Final byte assembly: the class rule over the F2/F3/F4 band codes.
    fn bytes(e: *const PwavPwv2Engine) Bytes {
        var b: Bytes = .{ .pwav = undefined, .pwv2 = undefined };
        for (0..400) |i| {
            const f = e.pwav_f[i];
            const cls = pwavClass(f[2], f[3], f[4]);
            b.pwav[i] = (@as(u8, cls) << 5) | @as(u8, @intCast(f[0]));
        }
        for (0..100) |i| b.pwv2[i] = @intCast(e.pwv2_code[i]);
        return b;
    }
};

/// Analyzes decoded PCM and produces the `WaveformColumns` of an ANLZ file,
/// replicating Rekordbox's analysis. Requires 44 100 Hz stereo f32 input in
/// [−1, 1) (see `PcmInput`); Hand the result to `buildAnlzInput` with the
/// track's performance data.
///
/// Known divergences from Rekordbox on real program material: everything
/// matches byte-for-byte and is pinned by the fixtures under
/// `testdata/analysis`, except the PWAV 3-bit class code on noise-like
/// high-band content (the height bits stay byte-exact).
pub fn buildColumnsFromPcm(alloc: std.mem.Allocator, pcm: PcmInput) AnalyzeError!WaveformColumns {
    if (pcm.left.len != pcm.right.len) return error.ChannelMismatch;
    const n = pcm.left.len;
    const left = pcm.left;
    const right = pcm.right;

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    var wc = try WaveCreator.init(a, n);
    var p3 = try Pwv3Engine.init(a, n);
    var pp = try PwavPwv2Engine.init(a, n);

    // One streaming pass: every engine consumes each sample exactly once,
    // with record/column/chunk boundaries sealed as they pass.
    var chunk: usize = 1; // 1-based PWAV/PWV2 chunk index
    for (0..n) |i| {
        const x: f64 = left[i];
        const y: f64 = right[i];

        // WaveCreator float path: the channels arrive s16-quantized
        // (×32768, truncated toward zero, clamped to [-32768, 32767],
        // widened back to f64) and the WaveCreator rescales by 1/32767,
        // not 2⁻¹⁵. The half-code truncation shifts the PWV4 band signals
        // enough to flip razor-thin share comparisons, so it must be
        // kept exact.
        const wl: f64 = @as(f64, @floatFromInt(std.math.clamp(@as(i32, @intFromFloat(@trunc(x * 32768.0))), -32768, 32767))) * (1.0 / 32767.0);
        const wr: f64 = @as(f64, @floatFromInt(std.math.clamp(@as(i32, @intFromFloat(@trunc(y * 32768.0))), -32768, 32767))) * (1.0 / 32767.0);
        wc.push(waveMonoMix(wl, wr));
        while (wc.open < wc.d and wc.starts[wc.open + 1] <= i + 1) {
            wc.closeRecord(wc.open);
        }

        // PWV3 s16 path.
        const l16: i32 = @intFromFloat(@trunc(x * 32768.0));
        const r16: i32 = @intFromFloat(@trunc(y * 32768.0));
        p3.push(@divTrunc(l16 + r16, 2));
        if (i + 1 == n or @mod(i + 1, 294) == 0) {
            if (p3.open < p3.n_columns) p3.closeColumn(p3.open);
        }

        // PWAV/PWV2 s16 path.
        const mono32: f32 = @floatCast((@trunc(x * 32768.0) + @trunc(y * 32768.0)) * 0.0000152587890625);
        const mono20: f32 = mono32 * 32768.0;
        pp.push(mono32, mono20);
        if (pp.bufferFull() or i + 1 == n) {
            pp.endChunk(chunk);
            chunk += 1;
        }
    }
    // float32-rounding phantom chunks past the last real one (rare, long
    // tracks): empty groups, zero counts.
    while (chunk <= pp.last_chunk) : (chunk += 1) {
        pp.runChunk(chunk);
    }

    const n_columns = p3.n_columns;
    const pwv3_bytes = try p3.bytes(a);
    const scales = try wc.scalesAndPwv6(a);
    const pwv7_bytes = try wc.pwv7(a, n_columns, scales.scale_u16);
    const pwv5_words = try wc.pwv5(a, n_columns);
    const pwv4_bytes = try wc.pwv4(a);
    const preview_bytes = pp.bytes();

    var out: WaveformColumns = .{ .band3_scales = scales.scale_u16 };
    errdefer out.deinit(alloc);
    out.preview_mono = try alloc.alloc(WaveformPreviewColumn, 400);
    for (out.preview_mono, 0..) |*col, i| col.* = @bitCast(preview_bytes.pwav[i]);
    out.tiny_preview = try alloc.alloc(TinyWaveformPreviewColumn, 100);
    for (out.tiny_preview, 0..) |*col, i| col.* = @bitCast(preview_bytes.pwv2[i]);
    out.detail_mono = try alloc.alloc(WaveformPreviewColumn, n_columns);
    for (out.detail_mono, 0..) |*col, i| col.* = @bitCast(pwv3_bytes[i]);
    out.color_preview = try alloc.alloc(WaveformColorPreviewColumn, 1200);
    for (0..1200) |i| {
        // Wire order {monoMax, monoMin, LPF400, LOW, MID, HIGH}.
        out.color_preview[i] = .{
            .unknown1 = pwv4_bytes[i][0],
            .unknown2 = pwv4_bytes[i][1],
            .energy_bottom_half_freq = pwv4_bytes[i][2],
            .energy_bottom_third_freq = pwv4_bytes[i][3],
            .energy_mid_third_freq = pwv4_bytes[i][4],
            .energy_top_third_freq = pwv4_bytes[i][5],
        };
    }
    out.color_detail = try alloc.alloc(WaveformColorDetailColumn, n_columns);
    for (out.color_detail, 0..) |*col, i| col.* = @bitCast(pwv5_words[i]);
    out.band3_preview = try alloc.alloc(Waveform3BandColumn, 1200);
    for (0..1200) |i| {
        // Wire order (LPF300, BP250–1200, BP3000–9000).
        out.band3_preview[i] = .{
            .energy_mid_third_freq = scales.pwv6[i][0],
            .energy_top_third_freq = scales.pwv6[i][1],
            .energy_bottom_third_freq = scales.pwv6[i][2],
        };
    }
    out.band3_detail = try alloc.alloc(Waveform3BandColumn, n_columns);
    for (0..n_columns) |i| {
        out.band3_detail[i] = .{
            .energy_mid_third_freq = pwv7_bytes[i][0],
            .energy_top_third_freq = pwv7_bytes[i][1],
            .energy_bottom_third_freq = pwv7_bytes[i][2],
        };
    }

    arena.deinit();
    return out;
}
