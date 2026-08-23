const std = @import("std");
const anlz = @import("anlz");
const bin = @import("bin");
const util = @import("util");
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

test "preview downsample counts" {
    // Port of rekordcrate's preview_downsample_count: 150 detail entries
    // collapse to ~7 preview columns at 6.667 Hz (22 detail columns per
    // preview column), plus spot checks pinning the band-to-column mapping.
    const alloc = testing.allocator;
    const bands = [_]anlz.Band{.{ .low = 10, .mid = 20, .high = 30 }} ** 150;
    const heights = [_]u8{16} ** 150;

    const columns = try anlz.buildBandColumns(alloc, &bands, &heights);
    defer columns.deinit(alloc);
    try testing.expectEqual(@as(usize, 7), columns.color_preview.len);
    try testing.expectEqual(@as(usize, 7), columns.band3_preview.len);
    try testing.expectEqual(@as(usize, 150), columns.color_detail.len);
    try testing.expectEqual(@as(usize, 150), columns.band3_detail.len);
    // Constant bands mean to themselves; the PWV4 bottom half mirrors the
    // bottom third (documented guess) and whiteness stays zero.
    try testing.expectEqual(anlz.WaveformColorPreviewColumn{
        .energy_bottom_half_freq = 10,
        .energy_bottom_third_freq = 10,
        .energy_mid_third_freq = 20,
        .energy_top_third_freq = 30,
    }, columns.color_preview[0]);
    // 3-band preview reuses the PWV4 window means.
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 20,
        .energy_top_third_freq = 30,
        .energy_bottom_third_freq = 10,
    }, columns.band3_preview[0]);
    // 3-band detail reuses the band energies directly, field order mid,
    // top, bottom.
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 20,
        .energy_top_third_freq = 30,
        .energy_bottom_third_freq = 10,
    }, columns.band3_detail[0]);
    // The dominant band (high) colors PWV5 blue with the supplied height.
    try testing.expectEqual(anlz.WaveformColorDetailColumn{
        .height = 16,
        .blue = 7,
    }, columns.color_detail[0]);

    const previews = try anlz.buildPreviewColumns(alloc, &heights);
    defer previews.deinit(alloc);
    try testing.expectEqual(@as(usize, 7), previews.preview.len);
    try testing.expectEqual(@as(usize, 7), previews.tiny.len);
    for (previews.preview) |column| try testing.expect(column.height <= 31);
    for (previews.tiny) |column| try testing.expect(column.height <= 15);
    try testing.expectEqual(@as(u5, 16), previews.preview[0].height);
    try testing.expectEqual(@as(u4, 8), previews.tiny[0].height);

    const detail = try anlz.buildDetailMono(alloc, &heights);
    defer alloc.free(detail);
    try testing.expectEqual(@as(usize, 150), detail.len);
    try testing.expectEqual(@as(u5, 16), detail[0].height);
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
    // populated performance data yields a non-empty AnlzInput whose
    // waveform sections are internally consistent (detail == height count,
    // preview ~1/22) and whose main cue was prepended to the cue list.
    const alloc = testing.allocator;
    const sr: u32 = 44_100;
    const bands = [_]anlz.Band{.{ .low = 50, .mid = 100, .high = 150 }} ** 150;
    const heights = [_]u8{20} ** 150;
    const markers = [_]anlz.BeatMarker{
        .{ .index = 1, .sample_offset = 0.0 },
        .{ .index = 5, .sample_offset = 60.0 / 120.0 * @as(f64, @floatFromInt(sr)) * 4.0 },
    };
    const input = try anlz.buildAnlzInput(alloc, .{
        .sample_rate = sr,
        .sample_count = sr,
        .bpm = 120.0,
        .beatgrid = &markers,
        .main_cue = 0.0,
        .cues = &.{.{ .hot_cue = 1, .sample_offset = @floatFromInt(sr), .label = "x" }},
        .waveform_bands = &bands,
        .waveform_heights = &heights,
    });
    defer input.deinit(alloc);
    try testing.expect(input.beats.len > 0);
    try testing.expectEqual(@as(usize, 2), input.cues.len);
    try testing.expectEqual(@as(usize, 2), input.cues_extended.len);
    try testing.expectEqual(anlz.CueListType.hot_cues, input.cue_list_type);
    try testing.expectEqual(@as(usize, 150), input.detail_mono.?.len);
    try testing.expectEqual(@as(usize, 150), input.color_detail.?.len);
    try testing.expectEqual(@as(usize, 150), input.band3_detail.?.len);
    try testing.expectEqual(@as(usize, 7), input.preview_mono.len);
    try testing.expectEqual(@as(usize, 7), input.tiny_preview.len);
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
    const heights = [_]u8{20} ** 150;
    const markers = [_]anlz.BeatMarker{
        .{ .index = 1, .sample_offset = 0.0 },
        .{ .index = 5, .sample_offset = 60.0 / 120.0 * @as(f64, @floatFromInt(sr)) * 4.0 },
    };
    const input = try anlz.buildAnlzInput(alloc, .{
        .sample_rate = sr,
        .sample_count = sr,
        .bpm = 120.0,
        .beatgrid = &markers,
        .main_cue = 0.0,
        .cues = &.{.{ .hot_cue = 1, .sample_offset = @floatFromInt(sr), .label = "Brëak", .r = 0x4D, .b = 0xFF }},
        .waveform_bands = &bands,
        .waveform_heights = &heights,
    });
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
    try testing.expectEqual(@as(usize, 7), preview.data.len);
    try testing.expectEqual(@as(u5, 20), preview.data[0].height);
    try testing.expectEqual(@as(u3, 0), preview.data[0].whiteness);
    try testing.expectEqual(@as(usize, 7), dat_parsed.findSection(.tiny_waveform_preview).?.tiny_waveform_preview.data.len);

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
    try testing.expectEqual(@as(u5, 20), detail.data[0].height);
    const color_preview = &ext_parsed.findSection(.waveform_color_preview).?.waveform_color_preview;
    try testing.expectEqual(@as(usize, 7), color_preview.data.len);
    try testing.expectEqual(anlz.WaveformColorPreviewColumn{
        .energy_bottom_half_freq = 50,
        .energy_bottom_third_freq = 50,
        .energy_mid_third_freq = 100,
        .energy_top_third_freq = 150,
    }, color_preview.data[0]);
    const color_detail = &ext_parsed.findSection(.waveform_color_detail).?.waveform_color_detail;
    try testing.expectEqual(@as(usize, 150), color_detail.data.len);
    try testing.expectEqual(@as(u3, 7), color_detail.data[0].blue);
    try testing.expectEqual(@as(u5, 20), color_detail.data[0].height);

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
    try testing.expectEqual(@as(usize, 7), band3_preview.data.len);
    const band3_detail = &ex2_parsed.findSection(.waveform_3band_detail).?.waveform_3band_detail;
    try testing.expectEqual(@as(usize, 150), band3_detail.data.len);
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 100,
        .energy_top_third_freq = 150,
        .energy_bottom_third_freq = 50,
    }, band3_preview.data[0]);
    try testing.expectEqual(anlz.Waveform3BandColumn{
        .energy_mid_third_freq = 100,
        .energy_top_third_freq = 150,
        .energy_bottom_third_freq = 50,
    }, band3_detail.data[0]);
}
