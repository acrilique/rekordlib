const std = @import("std");
const setting = @import("rekordlib").setting;
const bin = @import("rekordlib").bin;
const testutil = @import("util.zig");

const testing = std.testing;

/// Checks that the default `Setting(Data)` value roundtrips: the expected
/// file length derived from the format constants, struct equality after
/// parse, and the expected brand/software/version strings.
fn expectDefaultRoundtrip(comptime Data: type) !void {
    const s = setting.Setting(Data).default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(setting.data_offset + bin.serializedLen(Data) + 4, out.len);

    const parsed = try setting.Setting(Data).parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings(Data.default_brand, parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings(Data.default_version, parsed.versionString());
}

/// Checks that `s` parses back equal and serializes to the same bytes, so
/// unknown field and enum values survive verbatim.
fn expectRoundtripVerbatim(s: anytype) !void {
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try setting.Setting(@TypeOf(s.data)).parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

/// Checks the `testdata` fixtures named `basename` with `Setting(Data)`,
/// through the shared `testutil.expectFixturesRoundtrip`.
fn expectSettingFixturesRoundtrip(comptime Data: type, comptime basename: []const u8, min_count: usize) !void {
    const Roundtrip = struct {
        fn run(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
            const parsed = try setting.Setting(Data).parse(input);
            return parsed.serialize(alloc);
        }
    };
    try testutil.expectFixturesRoundtrip(Roundtrip.run, basename, min_count);
}

/// Serializes a setting and checks that parsing it back fails with
/// `error.UnexpectedValue`.
fn expectUnexpectedValue(s: anytype) !void {
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectError(error.UnexpectedValue, setting.Setting(@TypeOf(s.data)).parse(out));
}

test "devsetting default roundtrip" {
    try expectDefaultRoundtrip(setting.DevSetting);
}

test "mysetting default roundtrip" {
    try expectDefaultRoundtrip(setting.MySetting);
}

test "devsetting unknown enum values roundtrip verbatim" {
    var s = setting.Setting(setting.DevSetting).default();
    s.data.key_display_format = @enumFromInt(0x7F);
    try expectRoundtripVerbatim(s);
}

test "mysetting unknown fields and enum values roundtrip verbatim" {
    var s = setting.Setting(setting.MySetting).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    s.data.unknown2 = 0xAA;
    s.data.unknown3 = .{ 0x5A, 0xA5, 0x5A };
    s.data.language = @enumFromInt(0x7F);
    s.data.tempo_range = @enumFromInt(0x00);
    try expectRoundtripVerbatim(s);
}

test "mysetting2 default roundtrip" {
    try expectDefaultRoundtrip(setting.MySetting2);
}

test "djmmysetting default roundtrip" {
    try expectDefaultRoundtrip(setting.DJMMySetting);
}

test "mysetting2 unknown fields and enum values roundtrip verbatim" {
    var s = setting.Setting(setting.MySetting2).default();
    s.data.unknown2 = 0xAA;
    s.data.waveform = @enumFromInt(0x7F);
    try expectRoundtripVerbatim(s);
}

test "djmmysetting unknown fields and enum values roundtrip verbatim" {
    var s = setting.Setting(setting.DJMMySetting).default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    s.data.midi_channel = @enumFromInt(0x7F);
    // The five setting-like bytes newer exports carry in `unknown2`.
    s.data.unknown2[0..5].* = .{ 0x80, 0x82, 0x84, 0x81, 0x81 };
    try expectRoundtripVerbatim(s);
}

test "parse rejects invalid structure" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try setting.Setting(setting.DevSetting).default().writeTo(&e);
    try testing.expectEqual(@as(usize, 140), e.written().len);

    var bad = try testing.allocator.dupe(u8, e.written());
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0x20, .little);
    try testing.expectError(error.InvalidFormat, setting.Setting(setting.DevSetting).parse(bad));

    std.mem.writeInt(u32, bad[0..4], 0x60, .little);
    std.mem.writeInt(u32, bad[100..104], 40, .little);
    try testing.expectError(error.InvalidFormat, setting.Setting(setting.DevSetting).parse(bad));

    const long = try testing.allocator.alloc(u8, 141);
    defer testing.allocator.free(long);
    @memcpy(long[0..140], e.written());
    long[140] = 0;
    try testing.expectError(error.InvalidFormat, setting.Setting(setting.DevSetting).parse(long));

    try testing.expectError(error.UnexpectedEof, setting.Setting(setting.DevSetting).parse(e.written()[0..139]));
}

test "setting type mismatch is rejected" {
    const out = try setting.Setting(setting.MySetting).default().serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectError(error.InvalidFormat, setting.Setting(setting.DevSetting).parse(out));
}

test "writeTo appends correctly after foreign bytes" {
    // DJMMySetting exercises the whole-file checksum range, which must be
    // relative to where the setting starts, not to the emitter start.
    const prefix = [_]u8{ 0xAA, 0xBB, 0xCC };
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try e.putBytes(&prefix);
    try setting.Setting(setting.DJMMySetting).default().writeTo(&e);

    const plain = try setting.Setting(setting.DJMMySetting).default().serialize(testing.allocator);
    defer testing.allocator.free(plain);
    try testing.expectEqualSlices(u8, plain, e.written()[prefix.len..]);
}

test "parse verifies the checksum" {
    const out = try setting.Setting(setting.DevSetting).default().serialize(testing.allocator);
    defer testing.allocator.free(out);

    // A corrupted checksum field is rejected. It sits right before the
    // trailing `unknown` field, at data_offset + data_len.
    const bad_checksum = try testing.allocator.dupe(u8, out);
    defer testing.allocator.free(bad_checksum);
    bad_checksum[136] ^= 0xFF;
    try testing.expectError(error.ChecksumMismatch, setting.Setting(setting.DevSetting).parse(bad_checksum));

    // Corruption inside the covered data section is caught even though the
    // structure still parses: enum fields accept any value, and this byte is
    // `overview_waveform_type` (data_offset + 9).
    const bad_data = try testing.allocator.dupe(u8, out);
    defer testing.allocator.free(bad_data);
    bad_data[113] = 0x55;
    try testing.expectError(error.ChecksumMismatch, setting.Setting(setting.DevSetting).parse(bad_data));

    // The same flip in the brand string (offset 5) is outside DEVSETTING's
    // data-only coverage, so the file still parses.
    const bad_brand = try testing.allocator.dupe(u8, out);
    defer testing.allocator.free(bad_brand);
    bad_brand[5] ^= 0xFF;
    _ = try setting.Setting(setting.DevSetting).parse(bad_brand);

    // DJMMYSETTING's checksum covers the whole file, so the brand flip is
    // caught there.
    const djm = try setting.Setting(setting.DJMMySetting).default().serialize(testing.allocator);
    defer testing.allocator.free(djm);
    const bad_djm = try testing.allocator.dupe(u8, djm);
    defer testing.allocator.free(bad_djm);
    bad_djm[5] ^= 0xFF;
    try testing.expectError(error.ChecksumMismatch, setting.Setting(setting.DJMMySetting).parse(bad_djm));
}

test "unexpected values in constant unknown fields are rejected" {
    // The trailing `unknown` field is asserted for every file type.
    var dev = setting.Setting(setting.DevSetting).default();
    dev.unknown = 1;
    try expectUnexpectedValue(dev);

    // DevSetting: unknown1, unknown2, unknown3.
    dev = setting.Setting(setting.DevSetting).default();
    dev.data.unknown1[0] = 0x00;
    try expectUnexpectedValue(dev);

    dev = setting.Setting(setting.DevSetting).default();
    dev.data.unknown2 = 0x02;
    try expectUnexpectedValue(dev);

    dev = setting.Setting(setting.DevSetting).default();
    dev.data.unknown3[17] = 0x01;
    try expectUnexpectedValue(dev);

    // MySetting: unknown4, unknown5, unknown6.
    var my = setting.Setting(setting.MySetting).default();
    my.data.unknown4 = 0x0001;
    try expectUnexpectedValue(my);

    my = setting.Setting(setting.MySetting).default();
    my.data.unknown5 = 0x8000;
    try expectUnexpectedValue(my);

    my = setting.Setting(setting.MySetting).default();
    my.data.unknown6 = 0xFFFF;
    try expectUnexpectedValue(my);

    // MySetting2: unknown1, unknown3.
    var my2 = setting.Setting(setting.MySetting2).default();
    my2.data.unknown1[0] = 0x01;
    try expectUnexpectedValue(my2);

    my2 = setting.Setting(setting.MySetting2).default();
    my2.data.unknown3[26] = 0xFF;
    try expectUnexpectedValue(my2);
}

test "DEVSETTING.DAT fixtures roundtrip byte-identical" {
    // Five devsetting fixtures plus three complete device exports.
    try expectSettingFixturesRoundtrip(setting.DevSetting, "DEVSETTING.DAT", 8);
}

test "MYSETTING.DAT fixtures roundtrip byte-identical" {
    // Thirty-two mysetting fixtures plus three complete device exports.
    try expectSettingFixturesRoundtrip(setting.MySetting, "MYSETTING.DAT", 35);
}

test "MYSETTING2.DAT fixtures roundtrip byte-identical" {
    // Fourteen mysetting2 fixtures plus three complete device exports.
    try expectSettingFixturesRoundtrip(setting.MySetting2, "MYSETTING2.DAT", 17);
}

test "DJMMYSETTING.DAT fixtures roundtrip byte-identical" {
    // Twenty-three djmmysetting fixtures plus three complete device exports.
    try expectSettingFixturesRoundtrip(setting.DJMMySetting, "DJMMYSETTING.DAT", 26);
}
