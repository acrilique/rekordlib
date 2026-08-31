const std = @import("std");
const anlz = @import("rekordlib").anlz;
const bin = @import("rekordlib").bin;
const util = @import("rekordlib").util;
const testutil = @import("util.zig");

const testing = std.testing;

/// File header preamble shared by the hand-built test files (16 bytes, as in
/// all known files).
const test_file_header_data = [16]u8{ 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };

/// Serializes raw section bytes (already including their headers) into a
/// full ANLZ image.
fn buildRawFile(alloc: std.mem.Allocator, header_data: []const u8, body: []const u8) bin.WriteError![]u8 {
    const header_data_len: u32 = @intCast(header_data.len);
    const body_len: u32 = @intCast(body.len);
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, anlz.Header{
        .kind = .file,
        .size = 12 + header_data_len,
        .total_size = 12 + header_data_len + body_len,
    }, .big);
    try e.putBytes(header_data);
    try e.putBytes(body);
    return e.toOwnedSlice();
}

/// Emits a raw section (header plus `preamble` and `content` bytes).
fn buildRawSection(alloc: std.mem.Allocator, kind: anlz.Kind, preamble: []const u8, content: []const u8) bin.WriteError![]u8 {
    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try bin.putStruct(&e, anlz.Header{
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
    const output = try roundtripAnlz(alloc, input);
    defer alloc.free(output);
    try testing.expectEqualSlices(u8, input, output);
}

/// Parses `input` and re-serializes it, for `testutil.expectFixturesRoundtrip`.
fn roundtripAnlz(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();
    return parsed.serialize(alloc);
}

test "ANLZ fixtures roundtrip byte-identical" {
    // Four tracks times the three extensions, across two complete device
    // exports.
    try testutil.expectFixturesRoundtrip(roundtripAnlz, "ANLZ0000.", 12);
}

/// Reads a fixture from `testdata`.
fn readFixture(alloc: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return testutil.readFixture(alloc, sub_path, .limited(1 << 20));
}

/// Path of the P053 `.DAT` fixture, relative to `testdata`.
const p053_dat = "complete_export/demo_tracks/PIONEER/USBANLZ/P053/0001D21F/ANLZ0000.DAT";

/// Path of the P053 `.EXT` fixture, relative to `testdata`.
const p053_ext = "complete_export/demo_tracks/PIONEER/USBANLZ/P053/0001D21F/ANLZ0000.EXT";

test "empty file roundtrips" {
    // Port of rekordcrate's anlz_new_empty_roundtrips: a file built from no
    // sections serializes, re-parses, and stays empty.
    const alloc = testing.allocator;
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &.{});
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 28), out.len);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.sections.len);

    const again = try parsed.serialize(alloc);
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, out, again);
    // The `PMAI` file header is derived on write.
    try testing.expectEqual(@as(u32, @intFromEnum(anlz.Kind.file)), std.mem.readInt(u32, again[0..4], .big));
}

test "derived headers roundtrip through content size" {
    // Port of rekordcrate's header_for_section_roundtrips_through_content_size:
    // the derived header of a section without preamble is `size` 12 and
    // `total_size` 12 + content, which the size accessors invert.
    const content = [_]u8{0} ** 100;
    const plain = try anlz.sectionHeader(.{ .unknown = .{
        .kind = @enumFromInt(anlz.fourcc("PQT2")),
        .content_data = &content,
    } });
    try testing.expectEqual(@as(u32, 12), plain.size);
    try testing.expectEqual(@as(u32, 112), plain.total_size);
    try testing.expectEqual(@as(u32, 100), plain.content_size());
    try testing.expectEqual(@as(u32, 0), plain.remaining_size());

    // A section with a 4-byte preamble keeps it in `remaining_size`.
    const vbr = try anlz.sectionHeader(.{ .vbr = .{ .data = &content } });
    try testing.expectEqual(@as(u32, 16), vbr.size);
    try testing.expectEqual(@as(u32, 116), vbr.total_size);
    try testing.expectEqual(@as(u32, 100), vbr.content_size());
    try testing.expectEqual(@as(u32, 4), vbr.remaining_size());
}

test "unknown section kinds roundtrip verbatim" {
    const alloc = testing.allocator;
    const path_raw = [6]u8{ 0x00, '/', 0x00, 'a', 0x00, 0x00 };
    var unknown_content = [6]u8{ 1, 2, 3, 4, 5, 6 };
    const sections = [_]anlz.Content{
        .{ .unknown = .{ .kind = @enumFromInt(anlz.fourcc("PQT2")), .header_data = &.{ 0xAA, 0xBB }, .content_data = &unknown_content } },
        .{ .path = .{ .path = .{ .raw = &path_raw } } },
    };

    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 28 + 20 + 22), out.len);
    try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
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
    const out3 = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out3);
    try expectRoundtripBytes(alloc, out3);
    try testing.expect(!std.mem.eql(u8, out, out3));
}

test "parse rejects malformed files" {
    const alloc = testing.allocator;
    const sections = [_]anlz.Content{
        .{ .vbr = .{ .unknown1 = 7, .data = &.{ 0x11, 0x22 } } },
    };
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    // Wrong file magic.
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u32, bad[0..4], anlz.fourcc("XMAI"), .big);
    try testing.expectError(error.InvalidFormat, anlz.Anlz.parse(alloc, bad));

    // Truncated file: the PMAI header promises more bytes than remain.
    try testing.expectError(error.UnexpectedEof, anlz.Anlz.parse(alloc, out[0 .. out.len - 1]));

    // Trailing bytes beyond the PMAI total size.
    const long = try alloc.alloc(u8, out.len + 1);
    defer alloc.free(long);
    @memcpy(long[0..out.len], out);
    long[out.len] = 0;
    try testing.expectError(error.InvalidFormat, anlz.Anlz.parse(alloc, long));

    // Section sizes that would underflow the header accessors.
    std.mem.writeInt(u32, bad[0..4], anlz.fourcc("PMAI"), .big);
    std.mem.writeInt(u32, bad[4..8], 4, .big);
    try testing.expectError(error.InvalidFormat, anlz.Anlz.parse(alloc, bad));
}

test "parse rejects sections with inconsistent sizes" {
    const alloc = testing.allocator;

    // Path whose stored length does not match the section content size:
    // prefix says 6 bytes, the section reserves 14.
    var path_preamble = [_]u8{0} ** 4;
    std.mem.writeInt(u32, path_preamble[0..4], 6, .big);
    const path_section = try buildRawSection(alloc, .path, &path_preamble, &([_]u8{0} ** 14));
    defer alloc.free(path_section);
    const path_file = try buildRawFile(alloc, &test_file_header_data, path_section);
    defer alloc.free(path_file);
    try testing.expectError(error.InvalidFormat, anlz.Anlz.parse(alloc, path_file));

    // Extended cue list with a nonzero unknown field.
    var ext_preamble = [_]u8{0} ** 8;
    std.mem.writeInt(u32, ext_preamble[0..4], 1, .big);
    std.mem.writeInt(u16, ext_preamble[6..8], 1, .big);
    const ext_body = try buildRawSection(alloc, .extended_cue_list, &ext_preamble, &.{});
    defer alloc.free(ext_body);
    const ext_file = try buildRawFile(alloc, &test_file_header_data, ext_body);
    defer alloc.free(ext_file);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, ext_file));

    // Song structure with an entry size other than 24.
    var pssi_preamble = [_]u8{0} ** 20;
    std.mem.writeInt(u32, pssi_preamble[0..4], 23, .big);
    std.mem.writeInt(u16, pssi_preamble[4..6], 1, .big);
    std.mem.writeInt(u16, pssi_preamble[6..8], 1, .big); // unencrypted mood
    const pssi_body = try buildRawSection(alloc, .song_structure, &pssi_preamble, &([_]u8{0} ** 24));
    defer alloc.free(pssi_body);
    const pssi_file = try buildRawFile(alloc, &test_file_header_data, pssi_body);
    defer alloc.free(pssi_file);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, pssi_file));

    // Waveform detail with an entry size other than 1.
    var pwv3_preamble = [_]u8{0} ** 12;
    std.mem.writeInt(u32, pwv3_preamble[0..4], 2, .big);
    const pwv3_body = try buildRawSection(alloc, .waveform_detail, &pwv3_preamble, &.{});
    defer alloc.free(pwv3_body);
    const pwv3_file = try buildRawFile(alloc, &test_file_header_data, pwv3_body);
    defer alloc.free(pwv3_file);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, pwv3_file));

    // Waveform detail whose unknown preamble field is not the constant found
    // in all known files.
    var pwv3_preamble2 = [_]u8{0} ** 12;
    std.mem.writeInt(u32, pwv3_preamble2[0..4], 1, .big);
    std.mem.writeInt(u32, pwv3_preamble2[8..12], 1, .big);
    const pwv3_body2 = try buildRawSection(alloc, .waveform_detail, &pwv3_preamble2, &.{});
    defer alloc.free(pwv3_body2);
    const pwv3_file2 = try buildRawFile(alloc, &test_file_header_data, pwv3_body2);
    defer alloc.free(pwv3_file2);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, pwv3_file2));

    // Song structure whose phrase count does not match the content size.
    var pssi_preamble2 = [_]u8{0} ** 20;
    std.mem.writeInt(u32, pssi_preamble2[0..4], 24, .big);
    std.mem.writeInt(u16, pssi_preamble2[4..6], 2, .big);
    std.mem.writeInt(u16, pssi_preamble2[6..8], 1, .big);
    const pssi_body2 = try buildRawSection(alloc, .song_structure, &pssi_preamble2, &([_]u8{0} ** 24));
    defer alloc.free(pssi_body2);
    const pssi_file2 = try buildRawFile(alloc, &test_file_header_data, pssi_body2);
    defer alloc.free(pssi_file2);
    try testing.expectError(error.InvalidFormat, anlz.Anlz.parse(alloc, pssi_file2));
}

test "parse rejects non-canonical header sizes" {
    const alloc = testing.allocator;

    // Beat grid whose header size is 20 instead of the canonical 24; the
    // total size is consistent, so only the size check catches it.
    const beat_grid = try buildRawSection(alloc, .beat_grid, &([_]u8{0} ** 12), &.{});
    defer alloc.free(beat_grid);
    std.mem.writeInt(u32, beat_grid[4..8], 20, .big);
    const grid_file = try buildRawFile(alloc, &test_file_header_data, beat_grid);
    defer alloc.free(grid_file);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, grid_file));

    // Cue list whose single entry announces a total length other than 56.
    var preamble = [_]u8{0} ** 12;
    std.mem.writeInt(u16, preamble[6..8], 1, .big); // one cue
    var entry = [_]u8{0} ** 57;
    std.mem.writeInt(u32, entry[0..4], anlz.fourcc("PCPT"), .big);
    std.mem.writeInt(u32, entry[4..8], 16, .big);
    std.mem.writeInt(u32, entry[8..12], 57, .big);
    const cue_list = try buildRawSection(alloc, .cue_list, &preamble, &entry);
    defer alloc.free(cue_list);
    const list_file = try buildRawFile(alloc, &test_file_header_data, cue_list);
    defer alloc.free(list_file);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, list_file));
}

test "song structure key bytes" {
    // Known answer from the P053 fixture: 11 phrase entries.
    const key = anlz.getKey(11);
    try testing.expectEqual(@as(u8, 0xD6), key[0]);
    try testing.expectEqual(@as(u8, 0xEC), key[1]);
}

test "song structure encryption detection" {
    // P053 fixture: raw mood d6ee with 11 entries decodes to `mid`.
    try testing.expect(anlz.checkIfEncrypted(&.{ 0xD6, 0xEE }, 11));
    // P016 fixture: raw mood def6 with 19 entries decodes to `mid`.
    try testing.expect(anlz.checkIfEncrypted(&.{ 0xDE, 0xF6 }, 19));
    // Unencrypted moods (valid as-is) are not detected as encrypted.
    try testing.expect(!anlz.checkIfEncrypted(&.{ 0x00, 0x01 }, 11));
    try testing.expect(!anlz.checkIfEncrypted(&.{ 0x00, 0x02 }, 19));
    try testing.expect(!anlz.checkIfEncrypted(&.{ 0x00, 0x03 }, 0));
    // Random garbage does not decode to a valid mood.
    try testing.expect(!anlz.checkIfEncrypted(&.{ 0xAB, 0xCD }, 11));
}

test "song structure roundtrips encrypted and plain" {
    const alloc = testing.allocator;
    var phrases = [_]anlz.Phrase{
        .{ .index = 1, .beat = 1, .kind = 1, .beat2 = 16, .fill = 1, .beat_fill = 14 },
        .{ .index = 2, .beat = 17, .kind = 2, .beat2 = 32 },
    };
    const data = anlz.SongStructureData{
        .mood = .mid,
        .unknown1 = 0x0102_0304,
        .end_beat = 32,
        .bank = .cool,
        .phrases = &phrases,
    };

    for ([_]bool{ true, false }) |is_encrypted| {
        const sections = [_]anlz.Content{.{
            .song_structure = .{ .is_encrypted = is_encrypted, .data = data },
        }};
        const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
        defer alloc.free(out);

        var parsed = try anlz.Anlz.parse(alloc, out);
        defer parsed.deinit();
        try testing.expectEqual(is_encrypted, parsed.sections[0].song_structure.is_encrypted);
        const ss = parsed.sections[0].song_structure;
        try testing.expectEqual(anlz.Mood.mid, ss.data.mood);
        try testing.expectEqual(anlz.Bank.cool, ss.data.bank);
        try testing.expectEqual(@as(u16, 32), ss.data.end_beat);
        try testing.expectEqual(@as(usize, 2), ss.data.phrases.len);
        try testing.expectEqualSlices(anlz.Phrase, &phrases, ss.data.phrases);

        const out2 = try parsed.serialize(alloc);
        defer alloc.free(out2);
        try testing.expectEqualSlices(u8, out, out2);
    }
}

test "beat grid and cue list with entries roundtrip" {
    try testing.expectEqual(@as(usize, 44), bin.serializedLen(anlz.Cue));
    try testing.expectEqual(@as(u32, 56), anlz.Cue.wire_len);
    try testing.expectEqual(@as(usize, 24), bin.serializedLen(anlz.Phrase));
    const alloc = testing.allocator;
    var beats = [_]anlz.Beat{
        .{ .beat_number = 1, .tempo = 12800, .time = 0 },
        .{ .beat_number = 2, .tempo = 12800, .time = 468 },
        .{ .beat_number = 3, .tempo = 12804, .time = 937 },
    };
    var cues = [_]anlz.Cue{
        .{},
        .{ .hot_cue = 1, .cue_type = .loop, .time = 1000, .loop_time = 2000, .order_first = 0xFFFF, .order_last = 0x0001 },
    };
    const sections = [_]anlz.Content{
        .{ .beat_grid = .{ .beats = &beats } },
        .{ .cue_list = .{ .list_type = .hot_cues, .memory_count = 0xFFFF_FFFF, .cues = &cues } },
    };

    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    try testing.expectEqualSlices(anlz.Beat, &beats, parsed.sections[0].beat_grid.beats);
    const list = parsed.sections[1].cue_list;
    try testing.expectEqual(anlz.CueListType.hot_cues, list.list_type);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), list.memory_count);
    try testing.expectEqual(@as(usize, 2), list.cues.len);
    try testing.expectEqual(anlz.CueType.loop, list.cues[1].cue_type);
    try testing.expectEqual(@as(u32, 2000), list.cues[1].loop_time);
    try testing.expectEqual(@as(u32, 0x0001_0000), list.cues[1].unknown1);
}

test "writing more cues than the u16 len_cues field holds fails" {
    const alloc = testing.allocator;
    const cues = try alloc.alloc(anlz.Cue, 65536);
    defer alloc.free(cues);
    for (cues) |*cue| cue.* = .{};

    var sections = [_]anlz.Content{
        .{ .cue_list = .{ .list_type = .hot_cues, .memory_count = 0xFFFF_FFFF, .cues = cues[0..65535] } },
    };
    // The largest count that fits `len_cues` (u16) still roundtrips.
    const max = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(max);
    try expectRoundtripBytes(alloc, max);

    // One cue more must fail instead of truncating the count against the
    // derived `total_size`.
    sections[0].cue_list.cues = cues;
    try testing.expectError(error.Overflow, anlz.serializeFile(alloc, &test_file_header_data, &sections));
}

test "cue list counts that cannot fit the section fail before allocating" {
    const alloc = testing.allocator;

    // A hot list's memory_count is the sentinel whatever the count, so a
    // patched len_cues reaches the fits-in-section check. The field sits
    // at file offset 12 (`PMAI`) + 16 (header_data) + 12 (section header)
    // + 6 (list_type, unknown).
    var cues = [_]anlz.Cue{.{}};
    const sections = [_]anlz.Content{
        .{ .cue_list = .{ .list_type = .hot_cues, .memory_count = 0xFFFF_FFFF, .cues = &cues } },
    };
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u16, bad[46..48], 0xFFFF, .big);
    try testing.expectError(error.UnexpectedEof, anlz.Anlz.parse(alloc, bad));

    // Same for an extended list, whose len_cues sits at +4 (list_type):
    // the minimum entry size alone already exceeds the section.
    var extended = [_]anlz.ExtendedCue{.{}};
    const ext_sections = [_]anlz.Content{
        .{ .extended_cue_list = .{ .cues = &extended } },
    };
    const ext_out = try anlz.serializeFile(alloc, &test_file_header_data, &ext_sections);
    defer alloc.free(ext_out);
    const ext_bad = try alloc.dupe(u8, ext_out);
    defer alloc.free(ext_bad);
    std.mem.writeInt(u16, ext_bad[44..46], 0xFFFF, .big);
    try testing.expectError(error.UnexpectedEof, anlz.Anlz.parse(alloc, ext_bad));
}

test "cue list memory_count is derived and validated" {
    const alloc = testing.allocator;
    var cues = [_]anlz.Cue{.{ .time = 1000 }};
    const sections = [_]anlz.Content{
        .{ .cue_list = .{ .list_type = .memory_cues, .cues = &cues } },
    };
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
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
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, bad));
}

test "cue entries with newer 28-byte entry headers roundtrip" {
    const alloc = testing.allocator;
    var cues = [_]anlz.Cue{
        .{ .hot_cue = 1, .time = 0x0003_CA3B },
        .{ .hot_cue = 2, .time = 0x0000_011E },
    };
    const sections = [_]anlz.Content{
        .{ .cue_list = .{ .list_type = .hot_cues, .cues = &cues, .entry_header_size = 28 } },
    };
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    const list = parsed.sections[0].cue_list;
    try testing.expectEqual(@as(u32, 28), list.entry_header_size);
    try testing.expectEqualSlices(anlz.Cue, &cues, list.cues);

    // Entries must share the style: patch the second entry's header size
    // (at 12 + 16 + 12 for the file and section headers, + 12 preamble, +
    // one 56-byte entry, + 4 for the entry tag) from 28 back to 16.
    const bad = try alloc.dupe(u8, out);
    defer alloc.free(bad);
    std.mem.writeInt(u32, bad[112..116], 16, .big);
    try testing.expectError(error.UnexpectedValue, anlz.Anlz.parse(alloc, bad));
}

test "waveform sections roundtrip with checks" {
    const alloc = testing.allocator;
    var preview = [_]anlz.WaveformPreviewColumn{
        .{ .height = 0b10101, .whiteness = 0b110 },
        .{ .height = 31, .whiteness = 7 },
    };
    var tiny = [_]anlz.TinyWaveformPreviewColumn{.{ .height = 9, .unused = 3 }};
    var color_preview = [_]anlz.WaveformColorPreviewColumn{
        .{ .unknown1 = 1, .unknown2 = 2, .energy_bottom_half_freq = 3, .energy_bottom_third_freq = 4, .energy_mid_third_freq = 5, .energy_top_third_freq = 6 },
    };
    var color_detail = [_]anlz.WaveformColorDetailColumn{.{ .red = 5, .green = 3, .blue = 7, .height = 31, .unknown = 1 }};
    var band_preview = [_]anlz.Waveform3BandColumn{.{ .energy_mid_third_freq = 1, .energy_top_third_freq = 2, .energy_bottom_third_freq = 3 }};
    var band_detail = [_]anlz.Waveform3BandColumn{.{ .energy_mid_third_freq = 4, .energy_top_third_freq = 5, .energy_bottom_third_freq = 6 }};
    const sections = [_]anlz.Content{
        .{ .waveform_preview = .{ .data = &preview } },
        .{ .tiny_waveform_preview = .{ .data = &tiny } },
        .{ .waveform_color_preview = .{ .data = &color_preview } },
        .{ .waveform_color_detail = .{ .data = &color_detail } },
        .{ .waveform_3band_preview = .{ .data = &band_preview } },
        .{ .waveform_3band_detail = .{ .data = &band_detail } },
    };

    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    // The packed bitfields land in the expected wire bits: height in the
    // five least significant bits, whiteness above.
    try testing.expectEqualSlices(u8, &.{ 0b110_10101, 0b11111_111 }, std.mem.sliceAsBytes(parsed.sections[0].waveform_preview.data));
    try testing.expectEqualSlices(u8, &.{0b0011_1001}, std.mem.sliceAsBytes(parsed.sections[1].tiny_waveform_preview.data));
    const cd = parsed.sections[3].waveform_color_detail.data[0];
    try testing.expectEqual(@as(u3, 5), cd.red);
    try testing.expectEqual(@as(u3, 3), cd.green);
    try testing.expectEqual(@as(u3, 7), cd.blue);
    try testing.expectEqual(@as(u5, 31), cd.height);
    try testing.expectEqual(@as(u2, 1), cd.unknown);
    try testing.expectEqualSlices(anlz.WaveformColorPreviewColumn, &color_preview, parsed.sections[2].waveform_color_preview.data);
    try testing.expectEqualSlices(anlz.Waveform3BandColumn, &band_preview, parsed.sections[4].waveform_3band_preview.data);
    try testing.expectEqualSlices(anlz.Waveform3BandColumn, &band_detail, parsed.sections[5].waveform_3band_detail.data);
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
    const cue = try anlz.ExtendedCue.parse(&c, alloc);
    defer alloc.free(cue.trailing);
    try testing.expect(c.atEnd());
    try testing.expectEqual(@as(u32, 4), cue.hot_cue);
    try testing.expectEqual(anlz.CueType.point, cue.cue_type);
    try testing.expectEqual(@as(u32, 0x0004_62F7), cue.time);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), cue.loop_time);
    try testing.expectEqual(util.ColorIndex.none, cue.color);
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
    const comment = try anlz.LenPrefixedWideString.fromUtf8(alloc, "Break");
    defer alloc.free(comment.raw);
    var cues = [_]anlz.ExtendedCue{
        .{ .hot_cue = 3, .time = 0x0004_62F7, .comment = comment, .hot_cue_color_rgb = .{ 0x4D, 0x00, 0xFF } },
    };
    const sections = [_]anlz.Content{.{
        .extended_cue_list = .{ .list_type = .hot_cues, .cues = &cues },
    }};

    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);
    _ = try expectRoundtripBytes(alloc, out);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    const list = parsed.sections[0].extended_cue_list;
    try testing.expectEqual(@as(usize, 1), list.cues.len);
    const text = try list.cues[0].comment.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Break", text);
}

test "mutating parsed data re-serializes consistently" {
    const alloc = testing.allocator;
    var beats = [_]anlz.Beat{
        .{ .beat_number = 1, .tempo = 12800, .time = 0 },
        .{ .beat_number = 2, .tempo = 12800, .time = 468 },
    };
    const comment = try anlz.LenPrefixedWideString.fromUtf8(alloc, "Break");
    defer alloc.free(comment.raw);
    var cues = [_]anlz.ExtendedCue{
        .{ .hot_cue = 3, .time = 1000, .comment = comment },
    };
    const sections = [_]anlz.Content{
        .{ .beat_grid = .{ .beats = &beats } },
        .{ .extended_cue_list = .{ .list_type = .hot_cues, .cues = &cues } },
    };
    const out = try anlz.serializeFile(alloc, &test_file_header_data, &sections);
    defer alloc.free(out);

    var parsed = try anlz.Anlz.parse(alloc, out);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    // Grow the beat grid by one beat and lengthen the cue comment; since
    // headers are derived from the data, both mutations re-serialize to a
    // consistent file.
    const grid = &parsed.sections[0].beat_grid;
    const grown = try arena.alloc(anlz.Beat, grid.beats.len + 1);
    @memcpy(grown[0..grid.beats.len], grid.beats);
    grown[grown.len - 1] = .{ .beat_number = 3, .tempo = 12804, .time = 937 };
    grid.beats = grown;

    const longer = try anlz.LenPrefixedWideString.fromUtf8(arena, "Breakdown");
    parsed.sections[1].extended_cue_list.cues[0].comment = longer;

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expect(modified.len > out.len);
    try expectRoundtripBytes(alloc, modified);

    var reparsed = try anlz.Anlz.parse(alloc, modified);
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
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();

    const grid = &parsed.findSection(.beat_grid).?.beat_grid;
    try testing.expectEqual(@as(usize, 257), grid.beats.len);
    for (grid.beats) |*beat| beat.tempo += 1;

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    // Same beat count, same file size, different bytes.
    try testing.expectEqual(input.len, modified.len);
    try testing.expect(!std.mem.eql(u8, input, modified));

    var reparsed = try anlz.Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const beats = reparsed.findSection(.beat_grid).?.beat_grid.beats;
    try testing.expectEqualSlices(anlz.Beat, grid.beats, beats);
    try testing.expectEqual(@as(u16, 12001), beats[0].tempo);
}

test "mutating fixture cue list entries re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_dat);
    defer alloc.free(input);
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    // The fixture's hot cue list is empty; `len_cues` is derived on write,
    // and `memory_count` keeps the hot-cue sentinel.
    const list = &parsed.findSection(.cue_list).?.cue_list;
    try testing.expectEqual(anlz.CueListType.hot_cues, list.list_type);
    try testing.expectEqual(@as(usize, 0), list.cues.len);

    // Add two cues: the file grows by one wire entry each.
    const cues = try arena.alloc(anlz.Cue, 2);
    cues[0] = .{ .hot_cue = 1, .time = 0x0004_62F7 };
    cues[1] = .{ .hot_cue = 2, .cue_type = .loop, .time = 1000, .loop_time = 2000 };
    list.cues = cues;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    try testing.expectEqual(input.len + 2 * anlz.Cue.wire_len, grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed = try anlz.Anlz.parse(alloc, grown);
    defer reparsed.deinit();
    const grown_list = reparsed.findSection(.cue_list).?.cue_list;
    try testing.expectEqualSlices(anlz.Cue, cues, grown_list.cues);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), grown_list.memory_count);

    // Modify the first cue: the file size stays, the entry changes.
    cues[0].time += 500;
    const tweaked = try parsed.serialize(alloc);
    defer alloc.free(tweaked);
    try testing.expectEqual(grown.len, tweaked.len);

    var reparsed2 = try anlz.Anlz.parse(alloc, tweaked);
    defer reparsed2.deinit();
    const tweaked_cues = reparsed2.findSection(.cue_list).?.cue_list.cues;
    try testing.expectEqualSlices(anlz.Cue, cues, tweaked_cues);
    try testing.expectEqual(@as(u32, 0x0004_62F7 + 500), tweaked_cues[0].time);

    // Remove one cue, then the other: the derived count shrinks the file
    // back to the original bytes.
    list.cues = cues[0..1];
    const shrunk = try parsed.serialize(alloc);
    defer alloc.free(shrunk);
    try testing.expectEqual(input.len + anlz.Cue.wire_len, shrunk.len);

    var reparsed3 = try anlz.Anlz.parse(alloc, shrunk);
    defer reparsed3.deinit();
    try testing.expectEqualSlices(anlz.Cue, cues[0..1], reparsed3.findSection(.cue_list).?.cue_list.cues);

    list.cues = &.{};
    const restored = try parsed.serialize(alloc);
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, input, restored);
}

test "mutating fixture extended cue comment re-parses" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_ext);
    defer alloc.free(input);
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    const list = &parsed.findSection(.extended_cue_list).?.extended_cue_list;
    try testing.expectEqual(@as(usize, 0), list.cues.len);

    // Add a cue whose comment grows the entry beyond its 68 fixed bytes.
    const cues = try arena.alloc(anlz.ExtendedCue, 1);
    cues[0] = .{
        .hot_cue = 1,
        .time = 0x0004_62F7,
        .comment = try anlz.LenPrefixedWideString.fromUtf8(arena, "Break"),
    };
    list.cues = cues;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    // 68 fixed bytes plus the 12 comment bytes ("Break" + NUL, UTF-16BE).
    try testing.expectEqual(input.len + 68 + 12, grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed = try anlz.Anlz.parse(alloc, grown);
    defer reparsed.deinit();
    const grown_list = reparsed.findSection(.extended_cue_list).?.extended_cue_list;
    try testing.expectEqual(@as(usize, 1), grown_list.cues.len);
    const text = try grown_list.cues[0].comment.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Break", text);

    // Growing the comment text grows the entry byte for byte.
    cues[0].comment = try anlz.LenPrefixedWideString.fromUtf8(arena, "Breakdown!");
    const longer = try parsed.serialize(alloc);
    defer alloc.free(longer);
    try testing.expectEqual(grown.len + 10, longer.len);

    // Clearing the comment shrinks the cue back to its fixed size.
    cues[0].comment = .{};
    const cleared = try parsed.serialize(alloc);
    defer alloc.free(cleared);
    try testing.expectEqual(input.len + 68, cleared.len);
    try expectRoundtripBytes(alloc, cleared);

    var reparsed2 = try anlz.Anlz.parse(alloc, cleared);
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
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();

    const section = parsed.findSection(.path).?;
    const original = try section.path.path.utf8(alloc);
    defer alloc.free(original);
    try testing.expectEqualStrings("/Contents/Loopmasters/UnknownAlbum/Demo Track 2.mp3", original);
    const old_len = section.path.path.byte_len();

    section.path.path = try anlz.LenPrefixedWideString.fromUtf8(parsed.arena.allocator(), "/Contents/mutated.mp3");
    const new_len = section.path.path.byte_len();
    try testing.expect(new_len < old_len);

    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expectEqual(input.len - old_len + new_len, modified.len);
    try expectRoundtripBytes(alloc, modified);

    var reparsed = try anlz.Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const text = try reparsed.findSection(.path).?.path.path.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("/Contents/mutated.mp3", text);
}

test "mutating fixture song structure re-encrypts" {
    const alloc = testing.allocator;
    const input = try readFixture(alloc, p053_ext);
    defer alloc.free(input);
    var parsed = try anlz.Anlz.parse(alloc, input);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();

    const ss = &parsed.findSection(.song_structure).?.song_structure;
    try testing.expect(ss.is_encrypted);
    try testing.expectEqual(anlz.Mood.mid, ss.data.mood);
    try testing.expectEqual(@as(usize, 11), ss.data.phrases.len);

    // Same-length mutations: the output must be re-obfuscated with the key
    // so that it decodes again on re-parse.
    ss.data.mood = .low;
    ss.data.phrases[0].beat += 1;
    const modified = try parsed.serialize(alloc);
    defer alloc.free(modified);
    try testing.expectEqual(input.len, modified.len);
    try testing.expect(!std.mem.eql(u8, input, modified));

    var reparsed = try anlz.Anlz.parse(alloc, modified);
    defer reparsed.deinit();
    const ss2 = &reparsed.findSection(.song_structure).?.song_structure;
    try testing.expect(ss2.is_encrypted);
    try testing.expectEqual(anlz.Mood.low, ss2.data.mood);
    try testing.expectEqualSlices(anlz.Phrase, ss.data.phrases, ss2.data.phrases);

    // Growing the phrase list changes the entry count, and with it the XOR
    // key; the re-obfuscated section must decode with the new key.
    const phrases = try arena.alloc(anlz.Phrase, ss.data.phrases.len + 1);
    @memcpy(phrases[0 .. phrases.len - 1], ss.data.phrases);
    phrases[phrases.len - 1] = .{ .index = 12, .beat = ss.data.phrases[ss.data.phrases.len - 1].beat + 16 };
    ss.data.phrases = phrases;

    const grown = try parsed.serialize(alloc);
    defer alloc.free(grown);
    try testing.expectEqual(modified.len + bin.serializedLen(anlz.Phrase), grown.len);
    try expectRoundtripBytes(alloc, grown);

    var reparsed2 = try anlz.Anlz.parse(alloc, grown);
    defer reparsed2.deinit();
    const ss3 = &reparsed2.findSection(.song_structure).?.song_structure;
    try testing.expect(ss3.is_encrypted);
    try testing.expectEqual(anlz.Mood.low, ss3.data.mood);
    try testing.expectEqualSlices(anlz.Phrase, phrases, ss3.data.phrases);
}

test "length-prefixed wide strings roundtrip" {
    const alloc = testing.allocator;

    var e = bin.Emitter.init(alloc);
    defer e.deinit();
    try (anlz.LenPrefixedWideString{}).encode(&e);
    var ws = try anlz.LenPrefixedWideString.fromUtf8(alloc, "Ära");
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
    const empty = try anlz.LenPrefixedWideString.decode(&c);
    try testing.expectEqual(@as(usize, 0), empty.raw.len);
    const again = try anlz.LenPrefixedWideString.decode(&c);
    defer alloc.free(again.raw);
    try testing.expectEqualSlices(u8, ws.raw, again.raw);
    try testing.expect(c.atEnd());

    const text = try again.utf8(alloc);
    defer alloc.free(text);
    try testing.expectEqualStrings("Ära", text);
}

test "length-prefixed wide string rejects odd payload lengths" {
    const odd = anlz.LenPrefixedWideString{ .raw = &.{ 0, 'A', 0 } };
    try testing.expectError(error.UnexpectedValue, odd.utf8(testing.allocator));
}

test "length-prefixed wide string through the struct walker" {
    const alloc = testing.allocator;
    const Sample = struct {
        prefix: u8 = 0,
        text: anlz.LenPrefixedWideString = .{},
        suffix: u8 = 0,
    };

    const ws = try anlz.LenPrefixedWideString.fromUtf8(alloc, "Hi");
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

// ---------------------------------------------------------------------------
// Performance-data construction (anlz_build port)
// ---------------------------------------------------------------------------

test "beatgrid expansion is constant tempo" {
    // Port of rekordcrate's beatgrid_expansion_is_constant_tempo: a
    // 2-marker grid at 120 BPM densifies to ~2 beats with cycling bar
    // positions and ms offsets within ~1 sample.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    // 120 BPM -> 22050 samples per beat; two beats span 44100 samples (1 s).
    const samples_per_beat = 60.0 / 120.0 * @as(f64, @floatFromInt(sr));
    const markers = [_]anlz.BeatMarker{
        .{ .index = 1, .sample_offset = 0.0 },
        .{ .index = 3, .sample_offset = 2.0 * samples_per_beat },
    };
    const beats = try anlz.expandBeatgrid(alloc, &markers, sr, 120.0, std.math.maxInt(u64));
    defer alloc.free(beats);
    try testing.expectEqual(@as(usize, 2), beats.len);
    try testing.expectEqualSlices(u16, &.{ 1, 2 }, &.{ beats[0].beat_number, beats[1].beat_number });
    try testing.expectEqual(@as(u16, 12_000), beats[0].tempo);
    try testing.expectEqual(@as(u32, 0), beats[0].time);
    try testing.expect(@abs(@as(i64, beats[1].time) - 500) <= 1);

    // Total count from duration: at 120 BPM, 1 s holds 2 beats.
    const from_duration = try anlz.expandBeatgrid(alloc, &markers, sr, 120.0, sr);
    defer alloc.free(from_duration);
    try testing.expectEqual(@as(usize, 2), from_duration.len);
}

test "beatgrid negative index aligns bar" {
    // Port of rekordcrate's beatgrid_negative_index_aligns_bar: bar
    // positions cycle 1-4 with downbeats at global index 1 (mod 4), so a
    // grid spanning beats -4..-1 yields [4, 1, 2, 3] — not [1, 2, 3, 4].
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const spb = 60.0 / 120.0 * @as(f64, @floatFromInt(sr));
    const markers = [_]anlz.BeatMarker{
        .{ .index = -4, .sample_offset = 0.0 },
        .{ .index = 0, .sample_offset = 4.0 * spb },
    };
    const beats = try anlz.expandBeatgrid(alloc, &markers, sr, 120.0, std.math.maxInt(u64));
    defer alloc.free(beats);
    var positions: [4]u16 = undefined;
    for (beats, 0..) |beat, i| positions[i] = beat.beat_number;
    try testing.expectEqualSlices(u16, &.{ 4, 1, 2, 3 }, &positions);
}

test "beatgrid tempo derives from the grid and saturates" {
    // Ours (no rekordcrate counterpart): with `bpm` null the tempo comes from
    // the grid segment, a set `bpm` overrides it uniformly, centi-BPM
    // saturates at the format ceiling, and unsorted markers are sorted by
    // sample offset before expansion.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const spb = 60.0 / 120.0 * @as(f64, @floatFromInt(sr));
    const markers = [_]anlz.BeatMarker{
        .{ .index = 0, .sample_offset = 0.0 },
        .{ .index = 2, .sample_offset = 2.0 * spb },
    };
    const derived = try anlz.expandBeatgrid(alloc, &markers, sr, null, std.math.maxInt(u64));
    defer alloc.free(derived);
    try testing.expectEqual(@as(u16, 12_000), derived[0].tempo);

    const overridden = try anlz.expandBeatgrid(alloc, &markers, sr, 128.0, std.math.maxInt(u64));
    defer alloc.free(overridden);
    try testing.expectEqual(@as(u16, 12_800), overridden[0].tempo);

    const saturated = try anlz.expandBeatgrid(alloc, &markers, sr, 700.0, std.math.maxInt(u64));
    defer alloc.free(saturated);
    try testing.expectEqual(@as(u16, 655_35), saturated[0].tempo);

    const unsorted = [_]anlz.BeatMarker{ markers[1], markers[0] };
    const sorted = try anlz.expandBeatgrid(alloc, &unsorted, sr, null, std.math.maxInt(u64));
    defer alloc.free(sorted);
    try testing.expectEqualSlices(anlz.Beat, derived, sorted);
}

test "column stats build drives the analyzer laws" {
    // One 150 Hz 3-band vector in, all seven groups out, every derivation
    // the transcribed analyzer law through the band→s16 domain mapping
    // (×128): the quadratic track-normalized height law, the whiteness
    // ratio ladder, the PWV5 share law, the PWV7 envelope quantizers, the
    // span-max PWV4, and the two calibrated preview ladders.
    const alloc = testing.allocator;
    const bands = [_]anlz.Band{.{ .low = 10, .mid = 20, .high = 30 }} ** 150;

    const columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc);
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, columns.color_preview.len);
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, columns.band3_preview.len);
    try testing.expectEqual(@as(usize, 150), columns.color_detail.len);
    try testing.expectEqual(@as(usize, 150), columns.band3_detail.len);
    try testing.expectEqual(anlz.MONO_PREVIEW_COLUMNS, columns.preview_mono.len);
    try testing.expectEqual(anlz.TINY_PREVIEW_COLUMNS, columns.tiny_preview.len);
    try testing.expectEqual(@as(usize, 150), columns.detail_mono.len);

    // PWV3: constant bands make every column the track peak — height 31
    // via the normalizer, whatever the absolute level — and whiteness
    // whitenessRatio(10/30 ≈ 0.33) = 5.
    try testing.expectEqual(anlz.WaveformPreviewColumn{ .height = 31, .whiteness = 5 }, columns.detail_mono[0]);

    // PWV5: pwv5Colors(10·128, 20·128, 30·128) = (2, 3, 7) — the green
    // suppression and blue boost of the share law — over the same 31.
    try testing.expectEqual(
        anlz.WaveformColorDetailColumn{ .red = 2, .green = 3, .blue = 7, .height = 31 },
        columns.color_detail[0],
    );

    // PWV7: constant input is its own envelope, so every column is equal;
    // values land in the quantizers' 0-128 domain (the input domain is
    // 0-255, a straight copy would overshoot 2×).
    try testing.expect(std.meta.eql(columns.band3_detail[0], columns.band3_detail[7]));
    try testing.expect(columns.band3_detail[0].energy_mid_third_freq <= 128);
    try testing.expect(columns.band3_detail[0].energy_top_third_freq <= 128);
    try testing.expect(columns.band3_detail[0].energy_bottom_third_freq <= 128);

    // PWV4: span maxima — mono 30 → 15 with the two's-complement min
    // mirror, the low band 10 → 5, and the shares 10²/60·128 → 0,
    // 20²/60·128 → 3, 30²/60·128 → 7.
    try testing.expectEqual(anlz.WaveformColorPreviewColumn{
        .unknown1 = 15,
        .unknown2 = 241,
        .energy_bottom_half_freq = 5,
        .energy_bottom_third_freq = 0,
        .energy_mid_third_freq = 3,
        .energy_top_third_freq = 7,
    }, columns.color_preview[0]);

    // PWAV: a constant track calibrates every span to the AGC ceiling 23;
    // the class is pwavClass(dbcode(640), dbcode(640), dbcode(3840)) =
    // pwavClass(0, 0, 11) = 5. PWV2 calibrates to 13.
    try testing.expectEqual(anlz.WaveformPreviewColumn{ .height = 23, .whiteness = 5 }, columns.preview_mono[0]);
    try testing.expectEqual(anlz.TinyWaveformPreviewColumn{ .height = 13 }, columns.tiny_preview[0]);
}

test "column stats previews aggregate their spans" {
    // rb's previews are span-resolution quantizations, not detail samples:
    // a loud column away from any span midpoint still drives its span in
    // every preview tier (the old midpoint resampler missed it), and the
    // PWAV/PWV2 calibration maps the loudest span to 23/13.
    const alloc = testing.allocator;
    var bands = [_]anlz.Band{.{ .low = 10, .mid = 10, .high = 10 }} ** 12000;
    bands[3] = .{ .low = 200, .mid = 200, .high = 200 }; // span 0, not its midpoint (column 5)
    const columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc);

    // 12000 columns → 10 per PWV4 span.
    try testing.expectEqual(@as(u8, 100), columns.color_preview[0].unknown1); // 200·128/256
    try testing.expectEqual(@as(u8, 5), columns.color_preview[1].unknown1); // 10·128/256

    // PWAV spans hold 30 columns: span 0's mean level is
    // (29·1280 + 25600)/30 ≈ 2091 against 1280 elsewhere — the loudest
    // span calibrates to 23 and the quiet spans land at
    // pwavLadder(1280·35000/2091 ≈ 21427) = 20.
    try testing.expectEqual(@as(u5, 23), columns.preview_mono[0].height);
    try testing.expectEqual(@as(u5, 20), columns.preview_mono[3].height);

    // PWV2 spans hold 120 columns: span 0 carries the loud column's low
    // band (25600 → calibrated 13); the quiet spans fall to the ladder
    // floor's neighborhood.
    try testing.expectEqual(@as(u4, 13), columns.tiny_preview[0].height);
    try testing.expectEqual(@as(u4, 2), columns.tiny_preview[1].height);
}

test "column stats heights are track-normalized and quadratic" {
    const alloc = testing.allocator;
    // The same shape at 2× scale renders identically: the track peak is
    // the normalizer. And the law is quadratic — a half-peak column codes
    // 7 where a linear law would give 15.
    const loud = [_]anlz.Band{ .{ .low = 255 }, .{ .low = 128 }, .{ .high = 64 } };
    const quiet = [_]anlz.Band{ .{ .low = 128 }, .{ .low = 64 }, .{ .high = 32 } };
    const cols_loud = try anlz.buildColumnsFromStats(alloc, &loud);
    defer cols_loud.deinit(alloc);
    const cols_quiet = try anlz.buildColumnsFromStats(alloc, &quiet);
    defer cols_quiet.deinit(alloc);
    for (cols_loud.detail_mono, cols_quiet.detail_mono) |l, q| {
        try testing.expectEqual(l, q);
    }
    // 31 at the peak; u = trunc(128·128/32640·32767) = 16447 →
    // 16447²·31.488/32767² ≈ 7.9 → 7; third column
    // u = 8223 → ≈ 1.99 → 1.
    try testing.expectEqual(@as(u5, 31), cols_loud.detail_mono[0].height);
    try testing.expectEqual(@as(u5, 7), cols_loud.detail_mono[1].height);
    try testing.expectEqual(@as(u5, 1), cols_loud.detail_mono[2].height);
    // Whiteness: low-only columns ratio 1 → 0; a treble-only column has
    // no low-band energy → 7.
    try testing.expectEqual(@as(u3, 0), cols_loud.detail_mono[0].whiteness);
    try testing.expectEqual(@as(u3, 7), cols_loud.detail_mono[2].whiteness);
}

test "column stats Band.peak drives the mono heights" {
    const alloc = testing.allocator;
    // Band energies cannot express a column's true peak; `peak` can: with
    // peaks supplied, the band-max fallback's uniform rendering gives way
    // to the real amplitude ratio (quadratic law: band max 100 against a
    // 255 peak codes 4).
    var bands = [_]anlz.Band{.{ .low = 100, .mid = 100, .high = 100 }} ** 40;
    const cols_fb = try anlz.buildColumnsFromStats(alloc, &bands);
    defer cols_fb.deinit(alloc);
    bands[20] = .{ .low = 100, .mid = 100, .high = 100, .peak = 255 };
    const cols_pk = try anlz.buildColumnsFromStats(alloc, &bands);
    defer cols_pk.deinit(alloc);
    // Fallback: every column is its own track peak → 31 everywhere.
    try testing.expectEqual(@as(u5, 31), cols_fb.detail_mono[0].height);
    try testing.expectEqual(@as(u5, 31), cols_fb.detail_mono[20].height);
    // With the peak: column 20 becomes the normalizer → 31; the others
    // code trunc(100·128/32640·32767)²·31.488/32767² ≈ 4.84 → 4.
    try testing.expectEqual(@as(u5, 31), cols_pk.detail_mono[20].height);
    try testing.expectEqual(@as(u5, 4), cols_pk.detail_mono[0].height);
}

test "column stats PWV7 envelope decays like the analyzer" {
    const alloc = testing.allocator;
    var bands = [_]anlz.Band{.{}} ** 600;
    bands[0] = .{ .high = 255 };
    const columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc);
    // Instant attack, exponential decay: strictly decreasing after the
    // impulse and silent by the tail. The high band rides the
    // bottom-third field (wire order); the other bands stay silent.
    try testing.expect(columns.band3_detail[0].energy_bottom_third_freq > columns.band3_detail[1].energy_bottom_third_freq);
    try testing.expect(columns.band3_detail[1].energy_bottom_third_freq > columns.band3_detail[2].energy_bottom_third_freq);
    try testing.expectEqual(@as(u8, 0), columns.band3_detail[500].energy_bottom_third_freq);
    try testing.expectEqual(@as(u8, 0), columns.band3_detail[0].energy_mid_third_freq);
    try testing.expectEqual(@as(u8, 0), columns.band3_detail[0].energy_top_third_freq);
}

test "empty waveform input produces empty sections" {
    // Nothing pins rb's behavior for a track without waveform data; the
    // builder's documented choice is empty sections over padded ones.
    const alloc = testing.allocator;
    const columns = try anlz.buildColumnsFromStats(alloc, &.{});
    defer columns.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), columns.preview_mono.len);
    try testing.expectEqual(@as(usize, 0), columns.tiny_preview.len);
    try testing.expectEqual(@as(usize, 0), columns.detail_mono.len);
    try testing.expectEqual(@as(usize, 0), columns.color_preview.len);
    try testing.expectEqual(@as(usize, 0), columns.color_detail.len);
    try testing.expectEqual(@as(usize, 0), columns.band3_preview.len);
    try testing.expectEqual(@as(usize, 0), columns.band3_detail.len);
}

test "column stats silence encodes the analyzer floors" {
    // Digital silence is not zero everywhere: the mono tiers floor at
    // PWAV (2, 5) / PWV2 1, PWV3 is (0, 7), PWV5 colors (7, 7, 7) with
    // height 0, and only PWV4/PWV6/PWV7 are all zero — `anlz.Silence`.
    const alloc = testing.allocator;
    const bands = [_]anlz.Band{.{}} ** 64;
    const columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc);
    try testing.expectEqual(anlz.WaveformPreviewColumn{ .height = 0, .whiteness = 7 }, columns.detail_mono[7]);
    try testing.expectEqual(
        anlz.WaveformColorDetailColumn{ .red = 7, .green = 7, .blue = 7 },
        columns.color_detail[7],
    );
    try testing.expectEqual(anlz.Waveform3BandColumn{}, columns.band3_detail[7]);
    try testing.expectEqual(anlz.WaveformPreviewColumn{ .height = 2, .whiteness = 5 }, columns.preview_mono[0]);
    try testing.expectEqual(anlz.TinyWaveformPreviewColumn{ .height = 1 }, columns.tiny_preview[0]);
    try testing.expectEqual(anlz.WaveformColorPreviewColumn{}, columns.color_preview[0]);
    try testing.expectEqual(anlz.Waveform3BandColumn{}, columns.band3_preview[0]);
}

test "cue building point and loop" {
    // Port of rekordcrate's cue_building_point_and_loop: cues encode point
    // vs loop, convert sample offsets to milliseconds, and pick the hot-cue
    // list type when a hot cue is present.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const cues = [_]anlz.CueInput{
        .{ .hot_cue = 1, .sample_offset = 44_100.0, .label = "Intro", .r = 255 },
        .{ .hot_cue = 2, .sample_offset = 88_200.0, .loop_end = 132_300.0, .is_loop = true, .label = "Loop", .g = 255 },
    };
    const lists = try anlz.buildCues(alloc, &cues, sr);
    defer lists.deinit(alloc);
    try testing.expectEqual(anlz.CueListType.hot_cues, lists.list_type);
    try testing.expectEqual(@as(usize, 2), lists.cues.len);
    try testing.expectEqual(@as(u32, 1000), lists.cues[0].time);
    try testing.expectEqual(anlz.CueType.point, lists.cues[0].cue_type);
    try testing.expectEqual(anlz.CueType.loop, lists.cues[1].cue_type);
    try testing.expectEqual(@as(u32, 3000), lists.cues[1].loop_time);
    // A point cue ignores its `loop_end`... (none set here; the sentinel
    // holds).
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), lists.cues[0].loop_time);
    try testing.expectEqual(@as(usize, 2), lists.extended.len);
    try testing.expectEqual([3]u8{ 255, 0, 0 }, lists.extended[0].hot_cue_color_rgb);
    const label = try lists.extended[0].comment.utf8(alloc);
    defer alloc.free(label);
    try testing.expectEqualStrings("Intro", label);

    // Memory-only cue lists keep the memory type.
    const memory = try anlz.buildCues(alloc, &.{.{ .sample_offset = 44_100.0 }}, sr);
    defer memory.deinit(alloc);
    try testing.expectEqual(anlz.CueListType.memory_cues, memory.list_type);
}

test "built anlz input assembles consistently" {
    // Port of rekordcrate's build_anlz_input_assembles_consistently: a
    // populated performance data plus a column set yields a non-empty
    // AnlzInput whose waveform sections are internally consistent (detail
    // == band count, preview ~1/22) and whose main cue was prepended to the
    // cue list.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const bands = [_]anlz.Band{.{ .low = 50, .mid = 100, .high = 150 }} ** 150;
    const markers = [_]anlz.BeatMarker{
        .{ .index = 1, .sample_offset = 0.0 },
        .{ .index = 5, .sample_offset = 60.0 / 120.0 * @as(f64, @floatFromInt(sr)) * 4.0 },
    };
    var columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc); // moved-from: no-op once buildAnlzInput runs
    const input = try anlz.buildAnlzInput(alloc, .{
        .sample_rate = sr,
        .sample_count = sr,
        .bpm = 120.0,
        .beatgrid = &markers,
        .main_cue = 0.0,
        .cues = &.{.{ .hot_cue = 1, .sample_offset = @floatFromInt(sr), .label = "x" }},
    }, &columns);
    defer input.deinit(alloc);
    try testing.expect(input.beats.len > 0);
    try testing.expectEqual(@as(usize, 2), input.cues.len);
    try testing.expectEqual(@as(usize, 2), input.cues_extended.len);
    try testing.expectEqual(anlz.CueListType.hot_cues, input.cue_list_type);
    try testing.expectEqual(@as(usize, 150), input.detail_mono.?.len);
    try testing.expectEqual(@as(usize, 150), input.color_detail.?.len);
    try testing.expectEqual(@as(usize, 150), input.band3_detail.?.len);
    try testing.expectEqual(anlz.MONO_PREVIEW_COLUMNS, input.preview_mono.len);
    try testing.expectEqual(anlz.TINY_PREVIEW_COLUMNS, input.tiny_preview.len);
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, input.color_preview.?.len);
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, input.band3_preview.?.len);
}

test "built anlz input serializes and re-parses" {
    // Ours (no rekordcrate counterpart): a built AnlzInput, assembled into the
    // section sets the device writer will emit (.DAT/.EXT/.2EX, each led
    // by a PPTH path section), serializes, re-parses with equal data, and
    // roundtrips byte-identical — constructed output is valid ANLZ end to
    // end.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const bands = [_]anlz.Band{.{ .low = 50, .mid = 100, .high = 150 }} ** 150;
    const markers = [_]anlz.BeatMarker{
        .{ .index = 1, .sample_offset = 0.0 },
        .{ .index = 5, .sample_offset = 60.0 / 120.0 * @as(f64, @floatFromInt(sr)) * 4.0 },
    };
    var columns = try anlz.buildColumnsFromStats(alloc, &bands);
    defer columns.deinit(alloc); // moved-from: no-op once buildAnlzInput runs
    const input = try anlz.buildAnlzInput(alloc, .{
        .sample_rate = sr,
        .sample_count = sr,
        .bpm = 120.0,
        .beatgrid = &markers,
        .main_cue = 0.0,
        .cues = &.{.{ .hot_cue = 1, .sample_offset = @floatFromInt(sr), .label = "Brëak", .r = 0x4D, .b = 0xFF }},
    }, &columns);
    defer input.deinit(alloc);

    const track_path = try anlz.LenPrefixedWideString.fromUtf8(alloc, "/Contents/track.mp3");
    defer alloc.free(track_path.raw);
    const path_section = anlz.Content{ .path = .{ .path = track_path } };

    // .DAT: beats, plain cues, mono previews.
    const dat_sections = [_]anlz.Content{
        path_section,
        .{ .beat_grid = .{ .beats = input.beats } },
        .{ .cue_list = .{ .list_type = input.cue_list_type, .cues = input.cues } },
        .{ .waveform_preview = .{ .data = input.preview_mono } },
        .{ .tiny_waveform_preview = .{ .data = input.tiny_preview } },
    };
    const dat = try anlz.serializeFile(alloc, &test_file_header_data, &dat_sections);
    defer alloc.free(dat);
    try expectRoundtripBytes(alloc, dat);

    var dat_parsed = try anlz.Anlz.parse(alloc, dat);
    defer dat_parsed.deinit();
    try testing.expectEqual(@as(usize, 5), dat_parsed.sections.len);
    try testing.expectEqualSlices(u8, track_path.raw, dat_parsed.findSection(.path).?.path.path.raw);
    try testing.expectEqualSlices(anlz.Beat, input.beats, dat_parsed.findSection(.beat_grid).?.beat_grid.beats);
    const dat_list = &dat_parsed.findSection(.cue_list).?.cue_list;
    try testing.expectEqual(anlz.CueListType.hot_cues, dat_list.list_type);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), dat_list.memory_count);
    try testing.expectEqualSlices(anlz.Cue, input.cues, dat_list.cues);
    const preview = &dat_parsed.findSection(.waveform_preview).?.waveform_preview;
    try testing.expectEqual(anlz.MONO_PREVIEW_COLUMNS, preview.data.len);
    // Constant bands: every span calibrates to the AGC ceiling 23, class
    // pwavClass(dbcode(3200), dbcode(3200), dbcode(19200)) = 5.
    try testing.expectEqual(@as(u5, 23), preview.data[0].height);
    try testing.expectEqual(@as(u3, 5), preview.data[0].whiteness);
    try testing.expectEqual(anlz.TINY_PREVIEW_COLUMNS, dat_parsed.findSection(.tiny_waveform_preview).?.tiny_waveform_preview.data.len);

    // .EXT: extended cues, mono detail, color preview/detail.
    const ext_sections = [_]anlz.Content{
        path_section,
        .{ .extended_cue_list = .{ .list_type = input.cue_list_type, .cues = input.cues_extended } },
        .{ .waveform_detail = .{ .data = input.detail_mono.? } },
        .{ .waveform_color_preview = .{ .data = input.color_preview.? } },
        .{ .waveform_color_detail = .{ .data = input.color_detail.? } },
    };
    const ext = try anlz.serializeFile(alloc, &test_file_header_data, &ext_sections);
    defer alloc.free(ext);
    try expectRoundtripBytes(alloc, ext);

    var ext_parsed = try anlz.Anlz.parse(alloc, ext);
    defer ext_parsed.deinit();
    try testing.expectEqual(@as(usize, 5), ext_parsed.sections.len);
    const ext_list = &ext_parsed.findSection(.extended_cue_list).?.extended_cue_list;
    try testing.expectEqual(anlz.CueListType.hot_cues, ext_list.list_type);
    try testing.expectEqual(@as(usize, 2), ext_list.cues.len);
    try testing.expectEqual(@as(u32, 0), ext_list.cues[0].hot_cue);
    const label = try ext_list.cues[1].comment.utf8(alloc);
    defer alloc.free(label);
    try testing.expectEqualStrings("Brëak", label);
    try testing.expectEqual([3]u8{ 0x4D, 0, 0xFF }, ext_list.cues[1].hot_cue_color_rgb);
    const detail = &ext_parsed.findSection(.waveform_detail).?.waveform_detail;
    try testing.expectEqual(@as(usize, 150), detail.data.len);
    // Constant bands: every column is the track peak → 31.
    try testing.expectEqual(@as(u5, 31), detail.data[0].height);
    const color_preview = &ext_parsed.findSection(.waveform_color_preview).?.waveform_color_preview;
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, color_preview.data.len);
    // Span maxima: mono 150·128/256 = 75 (mirror 181), low 50·128/256 = 25,
    // shares 50²/300·128/256 = 4, 100²/300·128/256 = 16, 150²/300·128/256
    // = 37.
    try testing.expectEqual(anlz.WaveformColorPreviewColumn{
        .unknown1 = 75,
        .unknown2 = 181,
        .energy_bottom_half_freq = 25,
        .energy_bottom_third_freq = 4,
        .energy_mid_third_freq = 16,
        .energy_top_third_freq = 37,
    }, color_preview.data[0]);
    const color_detail = &ext_parsed.findSection(.waveform_color_detail).?.waveform_color_detail;
    try testing.expectEqual(@as(usize, 150), color_detail.data.len);
    try testing.expectEqual(@as(u3, 7), color_detail.data[0].blue);
    try testing.expectEqual(@as(u5, 31), color_detail.data[0].height);

    // .2EX: 3-band preview/detail.
    const ex2_sections = [_]anlz.Content{
        path_section,
        .{ .waveform_3band_preview = .{ .data = input.band3_preview.? } },
        .{ .waveform_3band_detail = .{ .data = input.band3_detail.? } },
    };
    const ex2 = try anlz.serializeFile(alloc, &test_file_header_data, &ex2_sections);
    defer alloc.free(ex2);
    try expectRoundtripBytes(alloc, ex2);

    var ex2_parsed = try anlz.Anlz.parse(alloc, ex2);
    defer ex2_parsed.deinit();
    try testing.expectEqual(@as(usize, 3), ex2_parsed.sections.len);
    const band3_preview = &ex2_parsed.findSection(.waveform_3band_preview).?.waveform_3band_preview;
    try testing.expectEqual(anlz.COLOR_PREVIEW_COLUMNS, band3_preview.data.len);
    const band3_detail = &ex2_parsed.findSection(.waveform_3band_detail).?.waveform_3band_detail;
    try testing.expectEqual(@as(usize, 150), band3_detail.data.len);
    // Constant input through the scale derivation (unit scales): PWV6's
    // span-0 averages of 6400/2, 12800, 19200 over 256 = (12, 50, 75)
    // (only the low band's 1-second window zero-fills before the start);
    // PWV7's envelope is the value itself — 128/32768·(6400, 12800) =
    // (25, 50) linear, (64 − cos(π·19200/32768)·64) = 81 quadratic.
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 12,
        .energy_top_third_freq = 50,
        .energy_bottom_third_freq = 75,
    }, band3_preview.data[0]);
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 25,
        .energy_top_third_freq = 50,
        .energy_bottom_third_freq = 81,
    }, band3_detail.data[0]);
}

test "detailExtents reconstructs every fixture's detail column count" {
    // sample_count = columns * 294 reconstructs the exact counts measured
    // in the four ANLZ fixture sets (44.1 kHz, whole-second durations).
    const e = anlz.detailExtents(77181 * 294, 44100).?;
    try testing.expectEqual(@as(u64, 77181), e.size);
    try testing.expectEqual(@as(f64, 294.0), e.samples_per_entry);
    try testing.expectEqual(@as(u64, 59771), anlz.detailExtents(59771 * 294, 44100).?.size);
    try testing.expectEqual(@as(u64, 25866), anlz.detailExtents(25866 * 294, 44100).?.size);
    try testing.expectEqual(@as(u64, 19208), anlz.detailExtents(19208 * 294, 44100).?.size);
    // 48 kHz divides evenly as well.
    const e48 = anlz.detailExtents(320_000, 48000).?;
    try testing.expectEqual(@as(u64, 1000), e48.size);
    try testing.expectEqual(@as(f64, 320.0), e48.samples_per_entry);
}

test "detailExtents ceils partial columns and rejects rate 0" {
    // 294147 samples at 44.1 kHz = exactly 1000.5 columns.
    try testing.expectEqual(@as(u64, 1001), anlz.detailExtents(294_147, 44100).?.size);
    // Partial columns ceil: 15 752 931 samples = 53 581.04 columns.
    try testing.expectEqual(@as(u64, 45069), anlz.detailExtents(13_250_199, 44100).?.size);
    try testing.expectEqual(@as(u64, 53582), anlz.detailExtents(15_752_931, 44100).?.size);
    try testing.expectEqual(@as(u64, 50565), anlz.detailExtents(14_866_077, 44100).?.size);
    try testing.expect(anlz.detailExtents(1_000_000, 0) == null);
}

test "previewExtents reports the fixed color tier" {
    // Fixed size whatever the track; each column spans sample_count/1200
    // samples; rate 0 is rejected like detailExtents.
    const e = anlz.previewExtents(1_200_000, 44100).?;
    try testing.expectEqual(@as(u64, 1200), e.size);
    try testing.expectEqual(@as(f64, 1000.0), e.samples_per_entry);
    const e2 = anlz.previewExtents(2_400_000, 48_000).?;
    try testing.expectEqual(@as(u64, 1200), e2.size);
    try testing.expectEqual(@as(f64, 2000.0), e2.samples_per_entry);
    try testing.expect(anlz.previewExtents(1_000_000, 0) == null);
}

/// The four ANLZ fixture tracks (two per rb generation), relative to
/// `testdata`.
const fixture_tracks = [_][]const u8{
    "complete_export/demo_tracks/PIONEER/USBANLZ/P016/0000875E",
    "complete_export/demo_tracks/PIONEER/USBANLZ/P053/0001D21F",
    "complete_export/with_anlz/PIONEER/USBANLZ/P002/0000D534",
    "complete_export/with_anlz/PIONEER/USBANLZ/P01F/00004BC5",
};

test "builders pin preview widths and analyzer-law ranges against fixtures" {
    // rb's preview bytes are underivable from the detail sections, so
    // what the fixtures pin is the widths — 400 PWAV, 100 PWV2, 1200
    // PWV4/PWV6 across all four tracks — and what this test pins on top
    // is the derived output's law-shaped ranges: PWAV/PWV2 heights inside
    // the ladders (floors 2/1), the track-peak normalizer reaching 31
    // somewhere in the detail, and the PWV7 quantizer domain ≤ 128.
    const alloc = testing.allocator;
    for (fixture_tracks) |dir| {
        var path_buf: [128]u8 = undefined;
        const dat = try readFixture(alloc, try std.fmt.bufPrint(&path_buf, "{s}/ANLZ0000.DAT", .{dir}));
        defer alloc.free(dat);
        const ext = try readFixture(alloc, try std.fmt.bufPrint(&path_buf, "{s}/ANLZ0000.EXT", .{dir}));
        defer alloc.free(ext);
        const ex2 = try readFixture(alloc, try std.fmt.bufPrint(&path_buf, "{s}/ANLZ0000.2EX", .{dir}));
        defer alloc.free(ex2);

        var dat_parsed = try anlz.Anlz.parse(alloc, dat);
        defer dat_parsed.deinit();
        var ext_parsed = try anlz.Anlz.parse(alloc, ext);
        defer ext_parsed.deinit();
        var ex2_parsed = try anlz.Anlz.parse(alloc, ex2);
        defer ex2_parsed.deinit();

        const pwav = &dat_parsed.findSection(.waveform_preview).?.waveform_preview;
        const pwv2 = &dat_parsed.findSection(.tiny_waveform_preview).?.tiny_waveform_preview;
        const pwv3 = &ext_parsed.findSection(.waveform_detail).?.waveform_detail;
        const pwv4 = &ext_parsed.findSection(.waveform_color_preview).?.waveform_color_preview;
        const pwv6 = &ex2_parsed.findSection(.waveform_3band_preview).?.waveform_3band_preview;
        const pwv7 = &ex2_parsed.findSection(.waveform_3band_detail).?.waveform_3band_detail;

        const bands = try alloc.alloc(anlz.Band, pwv7.data.len);
        defer alloc.free(bands);
        // The wire order puts the low band in the mid-third field (see
        // analyzePcm's assembly note).
        for (pwv7.data, 0..) |column, i| bands[i] = .{
            .low = column.energy_mid_third_freq,
            .mid = column.energy_top_third_freq,
            .high = column.energy_bottom_third_freq,
        };
        const columns = try anlz.buildColumnsFromStats(alloc, bands);
        defer columns.deinit(alloc);
        // The widths are the fixtures' own preview widths.
        try testing.expectEqual(pwav.data.len, columns.preview_mono.len);
        try testing.expectEqual(pwv2.data.len, columns.tiny_preview.len);
        try testing.expectEqual(pwv4.data.len, columns.color_preview.len);
        try testing.expectEqual(pwv6.data.len, columns.band3_preview.len);
        try testing.expectEqual(pwv3.data.len, columns.detail_mono.len);
        for (columns.preview_mono) |column| {
            try testing.expect(column.height >= 2 and column.height <= 25);
        }
        for (columns.tiny_preview) |column| {
            try testing.expect(column.height >= 1 and column.height <= 15);
        }
        var max_h: u5 = 0;
        for (columns.detail_mono) |column| max_h = @max(max_h, column.height);
        try testing.expectEqual(@as(u5, 31), max_h);
        for (columns.band3_detail) |column| {
            try testing.expect(column.energy_mid_third_freq <= 128);
            try testing.expect(column.energy_top_third_freq <= 128);
            try testing.expect(column.energy_bottom_third_freq <= 128);
        }
    }
}

test "detailHeight is Rekordbox's quadratic quantizer" {
    // Bin edges at sqrt((h+1)/31.5): 0.1782²·31.5 = 1.0004 → 1.
    try testing.expectEqual(@as(u5, 0), anlz.detailHeight(0.0));
    try testing.expectEqual(@as(u5, 0), anlz.detailHeight(0.1781));
    try testing.expectEqual(@as(u5, 1), anlz.detailHeight(0.1782));
    try testing.expectEqual(@as(u5, 1), anlz.detailHeight(0.2519));
    try testing.expectEqual(@as(u5, 2), anlz.detailHeight(0.2520));
    try testing.expectEqual(@as(u5, 2), anlz.detailHeight(0.3086));
    try testing.expectEqual(@as(u5, 3), anlz.detailHeight(0.3087));
    try testing.expectEqual(@as(u5, 30), anlz.detailHeight(0.9920));
    try testing.expectEqual(@as(u5, 31), anlz.detailHeight(0.9921));
    try testing.expectEqual(@as(u5, 31), anlz.detailHeight(1.0));
}

test "monoMix is the arithmetic mean, not a channel max" {
    try testing.expectEqual(@as(f64, 0.25), anlz.monoMix(0.5, 0.0));
    try testing.expectEqual(@as(f64, 0.25), anlz.monoMix(0.0, 0.5));
    try testing.expectEqual(@as(f64, 0.0), anlz.monoMix(0.5, -0.5));
    try testing.expectEqual(@as(f64, 0.5), anlz.monoMix(0.5, 0.5));
}

test "bandValue is Rekordbox's 7-bit envelope quantizer" {
    try testing.expectEqual(@as(u7, 0), anlz.bandValue(0.0));
    try testing.expectEqual(@as(u7, 0), anlz.bandValue(1.0 / 127.0 - 1e-9));
    try testing.expectEqual(@as(u7, 1), anlz.bandValue(1.0 / 127.0));
    try testing.expectEqual(@as(u7, 63), anlz.bandValue(0.5));
    try testing.expectEqual(@as(u7, 96), anlz.bandValue(96.0 / 127.0));
    try testing.expectEqual(@as(u7, 126), anlz.bandValue(0.999));
    try testing.expectEqual(@as(u7, 127), anlz.bandValue(1.0));
    try testing.expectEqual(@as(u7, 127), anlz.bandValue(2.0));
}

test "whitenessTone reproduces every probe tone's code" {
    try testing.expectEqual(@as(u3, 0), anlz.whitenessTone(0.0)); // DC
    try testing.expectEqual(@as(u3, 0), anlz.whitenessTone(100.0));
    try testing.expectEqual(@as(u3, 1), anlz.whitenessTone(120.0));
    try testing.expectEqual(@as(u3, 2), anlz.whitenessTone(160.0));
    try testing.expectEqual(@as(u3, 3), anlz.whitenessTone(190.0));
    try testing.expectEqual(@as(u3, 4), anlz.whitenessTone(220.0));
    try testing.expectEqual(@as(u3, 5), anlz.whitenessTone(250.0));
    try testing.expectEqual(@as(u3, 6), anlz.whitenessTone(350.0));
    try testing.expectEqual(@as(u3, 7), anlz.whitenessTone(500.0));
    try testing.expectEqual(@as(u3, 7), anlz.whitenessTone(20000.0));
}

test "silence floors match the analyzer's own encoding" {
    // Each section emits exactly one value throughout.
    try testing.expectEqual(@as(u8, 162), anlz.Silence.preview_byte);
    try testing.expectEqual(@as(u8, 1), anlz.Silence.tiny_byte);
    try testing.expectEqual(@as(u8, 224), anlz.Silence.detail_byte);
    try testing.expectEqual(@as(u16, 65408), anlz.Silence.color_detail_column);
}

test "mp3 analysis offset is LAME delay plus one decoder frame" {
    try testing.expectEqual(@as(i32, -2257), anlz.mp3_analysis_offset_samples);
    try testing.expectEqual(@as(i32, -(1105 + 1152)), anlz.mp3_analysis_offset_samples);
}

test "colorShare is Rekordbox's 3-bit share quantizer" {
    try testing.expectEqual(@as(u3, 0), anlz.colorShare(0.0));
    try testing.expectEqual(@as(u3, 0), anlz.colorShare(1.0 / 7.0 - 1e-9));
    try testing.expectEqual(@as(u3, 1), anlz.colorShare(1.0 / 7.0));
    try testing.expectEqual(@as(u3, 3), anlz.colorShare(0.5));
    try testing.expectEqual(@as(u3, 6), anlz.colorShare(6.0 / 7.0));
    try testing.expectEqual(@as(u3, 7), anlz.colorShare(1.0));
    try testing.expectEqual(@as(u3, 7), anlz.colorShare(1.5));
    // Just under the saturation edge.
    try testing.expectEqual(@as(u3, 6), anlz.colorShare(6.0 / 7.0 + 1e-9));
}

test "whitenessRatio is the LPF150 peak-ratio ladder" {
    // Real analyzer columns (tones, filtered noise, silence).
    const cases = [_]struct { fp: u16, pk: u16, want: u3 }{
        .{ .fp = 14971, .pk = 16383, .want = 0 }, // 100 Hz tone
        .{ .fp = 13285, .pk = 16383, .want = 1 }, // 127 Hz
        .{ .fp = 10634, .pk = 16383, .want = 2 }, // 162 Hz
        .{ .fp = 7621, .pk = 16383, .want = 4 }, // 207 Hz
        .{ .fp = 5044, .pk = 16383, .want = 5 }, // 264 Hz
        .{ .fp = 3201, .pk = 16383, .want = 6 }, // 336 Hz
        .{ .fp = 1995, .pk = 16383, .want = 7 }, // 428 Hz
        .{ .fp = 3740, .pk = 19613, .want = 6 }, // LP1k noise column
        .{ .fp = 1554, .pk = 22701, .want = 7 }, // LP10k noise column
        .{ .fp = 0, .pk = 0, .want = 7 }, // digital silence
    };
    for (cases) |c| try testing.expectEqual(c.want, anlz.whitenessRatio(c.fp, c.pk));
}

test "detailHeightCode is the coded two-stage truncation" {
    // Real analyzer columns (track peak 32767).
    const cases = [_]struct { p: u16, t: u16, want: u5 }{
        .{ .p = 16383, .t = 32767, .want = 7 },
        .{ .p = 0, .t = 32767, .want = 0 },
        .{ .p = 19613, .t = 32767, .want = 11 },
        .{ .p = 22701, .t = 32767, .want = 15 },
    };
    for (cases) |c| try testing.expectEqual(c.want, anlz.detailHeightCode(c.p, c.t));
    try testing.expectEqual(@as(u5, 31), anlz.detailHeightCode(32767, 32767));
    try testing.expectEqual(@as(u5, 0), anlz.detailHeightCode(5, 0)); // silent track
}

test "pwv7BandLinear reproduces the coded b0/b1 quantizer" {
    // Real (envelope, scale) pairs, scale at the 0.8 clamp floor.
    const cases = [_]struct { env: u16, sc: u16, want: u8 }{
        .{ .env = 318, .sc = 80, .want = 0 },
        .{ .env = 6741, .sc = 80, .want = 21 },
        .{ .env = 14439, .sc = 80, .want = 45 },
        .{ .env = 624, .sc = 80, .want = 1 },
        .{ .env = 15091, .sc = 80, .want = 47 },
        .{ .env = 30609, .sc = 80, .want = 95 },
    };
    for (cases) |c| try testing.expectEqual(c.want, anlz.pwv7BandLinear(c.env, c.sc));
}

test "pwv7BandQuadratic reproduces the coded b2 transform" {
    // Real pairs, adaptive scale 1.04: 64·(1−cos(π·x)) — quadratic at
    // small x, saturating at 128·scale.
    const cases = [_]struct { env: u16, sc: u16, want: u8 }{
        .{ .env = 16, .sc = 500, .want = 0 },
        .{ .env = 8867, .sc = 104, .want = 22 },
        .{ .env = 10452, .sc = 104, .want = 30 },
        .{ .env = 13246, .sc = 104, .want = 46 },
        .{ .env = 14778, .sc = 104, .want = 56 },
        .{ .env = 17972, .sc = 104, .want = 76 },
        .{ .env = 17757, .sc = 104, .want = 75 },
    };
    for (cases) |c| try testing.expectEqual(c.want, anlz.pwv7BandQuadratic(c.env, c.sc));
}

test "pwv5Colors is the coded byte>>5 law with corrections" {
    // Real channel triplets (tones, combos, silence).
    const cases = [_]struct { r: u16, g: u16, b: u16, want: anlz.ColorCodes }{
        .{ .r = 9536, .g = 726, .b = 149, .want = .{ .red = 7, .green = 0, .blue = 0 } },
        .{ .r = 8283, .g = 3425, .b = 3602, .want = .{ .red = 7, .green = 2, .blue = 4 } },
        .{ .r = 0, .g = 0, .b = 0, .want = .{ .red = 7, .green = 7, .blue = 7 } },
        .{ .r = 455, .g = 9065, .b = 9220, .want = .{ .red = 0, .green = 5, .blue = 7 } },
        .{ .r = 535, .g = 9719, .b = 3541, .want = .{ .red = 0, .green = 6, .blue = 3 } },
    };
    for (cases) |c| {
        const got = anlz.pwv5Colors(c.r, c.g, c.b);
        try testing.expectEqual(c.want.red, got.red);
        try testing.expectEqual(c.want.green, got.green);
        try testing.expectEqual(c.want.blue, got.blue);
    }
}

test "waveMonoMix is the magnitude-branch WaveCreator mix" {
    // Anti-phase keeps full magnitude (the larger-magnitude pick) where
    // `monoMix` would cancel; near-identical channels pick the larger one.
    try testing.expectEqual(@as(f64, 0.5), anlz.waveMonoMix(0.5, 0.5));
    try testing.expectEqual(@as(f64, -0.5), anlz.waveMonoMix(0.5, -0.5));
    try testing.expectEqual(@as(f64, 0.25), anlz.waveMonoMix(0.5, 0.0));
    try testing.expectEqual(@as(f64, 0.25), anlz.waveMonoMix(0.0, 0.5));
    try testing.expectEqual(@as(f64, 0.3005), anlz.waveMonoMix(0.3, 0.3005));
    try testing.expectEqual(@as(f64, -0.2), anlz.waveMonoMix(-0.1995, -0.2));
}

// ------------------------------------------------------------------------
// PCM analysis route (analysis.zig)
// ------------------------------------------------------------------------

/// Reads a PCM-analysis fixture pair: `sub_path` names the `.pcm` file,
/// whose `.exp` sibling carries the expected section bytes.
const AnalysisFixture = struct {
    n: usize,
    left: []f32,
    right: []f32,
    pwav: []u8,
    pwv2: []u8,
    pwv3: []u8,
    pwv4: []u8, // 1200 columns x 6 bytes
    pwv5: []u16, // big-endian words on disk, native here
    pwv6: []u8, // 1200 x 3
    pwv7: []u8, // N x 3

    fn read(alloc: std.mem.Allocator, sub_path: []const u8) !AnalysisFixture {
        const pcm = try readFixture(alloc, sub_path);
        defer alloc.free(pcm);
        var f: AnalysisFixture = undefined;
        if (pcm.len < 4) return error.InvalidFormat;
        f.n = std.mem.readInt(u32, pcm[0..4], .little);
        const channels_bytes = f.n * 2 * 4;
        if (pcm.len != 4 + channels_bytes) return error.InvalidFormat;
        const lbytes = pcm[4 .. 4 + f.n * 4];
        const rbytes = pcm[4 + f.n * 4 ..];
        const left = try alloc.alloc(f32, f.n);
        errdefer alloc.free(left);
        const right = try alloc.alloc(f32, f.n);
        errdefer alloc.free(right);
        for (left, 0..) |*s, i| s.* = @bitCast(std.mem.readInt(u32, lbytes[i * 4 ..][0..4], .little));
        for (right, 0..) |*s, i| s.* = @bitCast(std.mem.readInt(u32, rbytes[i * 4 ..][0..4], .little));
        f.left = left;
        f.right = right;

        const stem = try std.fmt.allocPrint(alloc, "{s}.exp", .{sub_path[0 .. sub_path.len - 4]});
        defer alloc.free(stem);
        const exp = try readFixture(alloc, stem);
        defer alloc.free(exp);
        const n_columns = (f.n + 293) / 294;
        const want_len = 4 + 400 + 100 + n_columns + 7200 + 2 * n_columns + 3600 + 3 * n_columns;
        if (exp.len != want_len) return error.InvalidFormat;
        if (std.mem.readInt(u32, exp[0..4], .little) != f.n) return error.InvalidFormat;
        var off: usize = 4;
        f.pwav = try alloc.dupe(u8, exp[off .. off + 400]);
        errdefer alloc.free(f.pwav);
        off += 400;
        f.pwv2 = try alloc.dupe(u8, exp[off .. off + 100]);
        errdefer alloc.free(f.pwv2);
        off += 100;
        f.pwv3 = try alloc.dupe(u8, exp[off .. off + n_columns]);
        errdefer alloc.free(f.pwv3);
        off += n_columns;
        f.pwv4 = try alloc.dupe(u8, exp[off .. off + 7200]);
        errdefer alloc.free(f.pwv4);
        off += 7200;
        const words = try alloc.alloc(u16, n_columns);
        errdefer alloc.free(words);
        for (words, 0..) |*wd, i| wd.* = std.mem.readInt(u16, exp[off + i * 2 ..][0..2], .big);
        f.pwv5 = words;
        off += 2 * n_columns;
        f.pwv6 = try alloc.dupe(u8, exp[off .. off + 3600]);
        errdefer alloc.free(f.pwv6);
        off += 3600;
        f.pwv7 = try alloc.dupe(u8, exp[off .. off + 3 * n_columns]);
        errdefer alloc.free(f.pwv7);
        return f;
    }

    fn deinit(f: *const AnalysisFixture, alloc: std.mem.Allocator) void {
        alloc.free(f.left);
        alloc.free(f.right);
        alloc.free(f.pwav);
        alloc.free(f.pwv2);
        alloc.free(f.pwv3);
        alloc.free(f.pwv4);
        alloc.free(f.pwv5);
        alloc.free(f.pwv6);
        alloc.free(f.pwv7);
    }
};

/// Compares one analysis against a fixture, printing the first differing
/// section and column on failure.
fn expectAnalysisMatches(analysis: *const anlz.WaveformColumns, f: *const AnalysisFixture) !void {
    var failed: ?[]const u8 = null;
    var bad_index: usize = 0;

    for (analysis.preview_mono, 0..) |col, i| {
        if ((@as(u8, col.whiteness) << 5) | col.height != f.pwav[i]) {
            failed = "PWAV";
            bad_index = i;
            break;
        }
    }
    if (failed == null) for (analysis.tiny_preview, 0..) |col, i| {
        if (col.height != f.pwv2[i] or col.unused != 0) {
            failed = "PWV2";
            bad_index = i;
            break;
        }
    };
    if (failed == null) for (analysis.detail_mono, 0..) |col, i| {
        if ((@as(u8, col.whiteness) << 5) | col.height != f.pwv3[i]) {
            failed = "PWV3";
            bad_index = i;
            break;
        }
    };
    if (failed == null) for (0..1200) |i| {
        const col = analysis.color_preview[i];
        const b = f.pwv4[i * 6 ..][0..6];
        if (col.unknown1 != b[0] or col.unknown2 != b[1] or
            col.energy_bottom_half_freq != b[2] or col.energy_bottom_third_freq != b[3] or
            col.energy_mid_third_freq != b[4] or col.energy_top_third_freq != b[5])
        {
            failed = "PWV4";
            bad_index = i;
            break;
        }
    };
    if (failed == null) for (analysis.color_detail, 0..) |col, i| {
        if (@as(u16, @bitCast(col)) != f.pwv5[i]) {
            failed = "PWV5";
            bad_index = i;
            break;
        }
    };
    if (failed == null) for (0..1200) |i| {
        const col = analysis.band3_preview[i];
        const b = f.pwv6[i * 3 ..][0..3];
        if (col.energy_mid_third_freq != b[0] or col.energy_top_third_freq != b[1] or
            col.energy_bottom_third_freq != b[2])
        {
            failed = "PWV6";
            bad_index = i;
            break;
        }
    };
    if (failed == null) for (0..analysis.band3_detail.len) |i| {
        const col = analysis.band3_detail[i];
        const b = f.pwv7[i * 3 ..][0..3];
        if (col.energy_mid_third_freq != b[0] or col.energy_top_third_freq != b[1] or
            col.energy_bottom_third_freq != b[2])
        {
            failed = "PWV7";
            bad_index = i;
            break;
        }
    };
    if (failed) |section| {
        std.debug.print("analysis mismatch: {s} column {d}\n", .{ section, bad_index });
        return error.TestExpectedEqual;
    }
}

test "analyzePcm reproduces the fixtures byte-for-byte" {
    // Every fixture under testdata/analysis: small synthesized stereo
    // signals (silence, DC, sines, boundary tones, an anti-phase track, a
    // click train, amplitude steps); the .exp files hold the expected
    // section bytes.
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata/analysis", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".pcm")) continue;

        const fixture_path = try std.fmt.allocPrint(alloc, "analysis/{s}", .{entry.path});
        defer alloc.free(fixture_path);
        var fixture = try AnalysisFixture.read(alloc, fixture_path);
        defer fixture.deinit(alloc);
        var analysis = try anlz.analyzePcm(alloc, .{
            .left = fixture.left,
            .right = fixture.right,
        });
        defer analysis.deinit(alloc);
        errdefer std.debug.print("failing fixture: {s}\n", .{entry.path});
        try expectAnalysisMatches(&analysis, &fixture);
        count += 1;
    }
    // One per synthesized signal; keeps a stripped testdata honest.
    try testing.expectEqual(@as(usize, 11), count);
}

test "analyzePcm encodes digital silence exactly like the analyzer" {
    // A short all-zero track reproduces every section's silence encoding.
    const alloc = testing.allocator;
    const zeros = [_]f32{0} ** 11025; // 0.25 s
    var analysis = try anlz.analyzePcm(alloc, .{
        .left = &zeros,
        .right = &zeros,
    });
    defer analysis.deinit(alloc);

    try testing.expectEqual(@as(usize, 400), analysis.preview_mono.len);
    for (analysis.preview_mono) |col| {
        try testing.expectEqual(anlz.Silence.preview_byte, @as(u8, @bitCast(col)));
    }
    for (analysis.tiny_preview) |col| {
        try testing.expectEqual(@as(u8, 1), col.height);
        try testing.expectEqual(@as(u8, 0), col.unused);
    }
    try testing.expectEqual(@as(usize, 38), analysis.detail_mono.len); // ceil(11025/294)
    for (analysis.detail_mono) |col| {
        try testing.expectEqual(anlz.Silence.detail_byte, @as(u8, @bitCast(col)));
    }
    for (analysis.color_detail) |col| {
        try testing.expectEqual(anlz.Silence.color_detail_column, @as(u16, @bitCast(col)));
    }
    for (analysis.color_preview) |col| {
        try testing.expectEqual(@as(u8, 0), col.unknown1);
        try testing.expectEqual(@as(u8, 0), col.unknown2);
        try testing.expectEqual(@as(u8, 0), col.energy_bottom_half_freq);
        try testing.expectEqual(@as(u8, 0), col.energy_mid_third_freq);
    }
    for (analysis.band3_preview) |col| {
        try testing.expectEqual(@as(u8, 0), col.energy_mid_third_freq);
        try testing.expectEqual(@as(u8, 0), col.energy_top_third_freq);
        try testing.expectEqual(@as(u8, 0), col.energy_bottom_third_freq);
    }
    for (analysis.band3_detail) |col| {
        try testing.expectEqual(@as(u8, 0), col.energy_mid_third_freq);
    }
}

test "analyzePcm requires stereo" {
    const alloc = testing.allocator;
    const zeros = [_]f32{0} ** 128;
    try testing.expectError(error.ChannelMismatch, anlz.analyzePcm(alloc, .{
        .left = &zeros,
        .right = zeros[0..64],
    }));
}

test "PWV2 zero-code rule: 1 when both accumulators are zero, 2 when only band 2 is live" {
    // A zero band-1 accumulator encodes 1, or 2 when band 2 fired. On
    // click content band 1 stays under its threshold, so exactly the
    // spans where band 2 fired read 2 — the clicks fixture has one
    // (span 53), everything else reads 1.
    const alloc = testing.allocator;
    var fixture = try AnalysisFixture.read(alloc, "analysis/clicks.pcm");
    defer fixture.deinit(alloc);
    var analysis = try anlz.analyzePcm(alloc, .{
        .left = fixture.left,
        .right = fixture.right,
    });
    defer analysis.deinit(alloc);
    try expectAnalysisMatches(&analysis, &fixture);

    var twos: usize = 0;
    for (analysis.tiny_preview, 0..) |col, i| {
        if (i == 53) {
            try testing.expectEqual(@as(u4, 2), col.height);
            twos += 1;
        } else {
            try testing.expectEqual(@as(u4, 1), col.height);
        }
    }
    try testing.expectEqual(@as(usize, 1), twos);
}

test "buildAnlzInput moves the analysis columns into an input" {
    const alloc = testing.allocator;
    var fixture = try AnalysisFixture.read(alloc, "analysis/sine440_a05.pcm");
    defer fixture.deinit(alloc);
    var columns = try anlz.analyzePcm(alloc, .{
        .left = fixture.left,
        .right = fixture.right,
    });
    defer columns.deinit(alloc); // moved-from: no-op once buildAnlzInput runs
    const detail_len = columns.detail_mono.len;
    const preview_ptr = columns.preview_mono.ptr;

    var input = try anlz.buildAnlzInput(alloc, .{ .sample_rate = 44_100, .sample_count = fixture.n }, &columns);
    defer input.deinit(alloc);

    // The slices moved, not copied: the columns are empty and the input
    // owns the same memory.
    try testing.expectEqual(@as(usize, 0), columns.preview_mono.len);
    try testing.expectEqual(@as(usize, 0), columns.detail_mono.len);
    try testing.expectEqual(detail_len, input.detail_mono.?.len);
    try testing.expectEqual(preview_ptr, input.preview_mono.ptr);
    try testing.expectEqual(@as(usize, 400), input.preview_mono.len);
    try testing.expectEqual(@as(usize, 100), input.tiny_preview.len);
    try testing.expectEqual(@as(usize, 1200), input.color_preview.?.len);
    try testing.expectEqual(@as(usize, 1200), input.band3_preview.?.len);

    // The input serializes into a well-formed ANLZ set.
    const dat = try anlz.serializeFile(alloc, &test_file_header_data, &.{
        .{ .beat_grid = .{} },
        .{ .cue_list = .{} },
    });
    defer alloc.free(dat);
    try testing.expect(dat.len > 0);
}
