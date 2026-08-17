// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Parser and writer for the Rekordbox settings files.
//!
//! The files are found in the `PIONEER` directory of a USB device export.
//!
//! Ported from rekordcrate's `src/setting.rs`
//!
//!
//! Unknown fields and unknown enum values are stored on parse and written back
//! verbatim, so a parsed file always re-serializes byte-identically.

const std = @import("std");
const bin = @import("bin");

/// Size of the three NUL-padded string fields at the start of the file.
const string_field_len = 32;

/// Offset of the `data` section; the checksum starts at `data_offset + len_data`.
const data_offset = 4 + 3 * string_field_len + 4;

pub const ParseError = error{ UnexpectedEof, InvalidFormat };

/// Represents a `DEVSETTING.DAT` file.
pub const Setting = struct {
    /// Name of the brand, NUL-padded ("PIONEER DJ" for device exports).
    brand: [string_field_len]u8,
    /// Name of the software ("rekordbox"), NUL-padded.
    software: [string_field_len]u8,
    /// Some kind of version number ("6.6.1"), NUL-padded.
    version: [string_field_len]u8,
    /// The actual settings data.
    data: DevSetting,
    /// Trailing unknown field (apparently always zero), kept verbatim.
    unknown: u16,

    /// Parse a `DEVSETTING.DAT` image. The checksum is not verified; it is
    /// recalculated on write.
    pub fn parse(buf: []const u8) ParseError!Setting {
        var c = bin.Cursor.init(buf);
        const len_stringdata = try c.takeInt(u32);
        if (len_stringdata != 0x60) return error.InvalidFormat;
        const brand = (try c.takeArray(string_field_len)).*;
        const software = (try c.takeArray(string_field_len)).*;
        const version = (try c.takeArray(string_field_len)).*;
        const len_data = try c.takeInt(u32);
        if (len_data != DevSetting.serialized_len) return error.InvalidFormat;
        const data = try DevSetting.parse(&c);
        _ = try c.takeInt(u16);
        const unknown = try c.takeInt(u16);
        if (!c.atEnd()) return error.InvalidFormat;
        return .{
            .brand = brand,
            .software = software,
            .version = version,
            .data = data,
            .unknown = unknown,
        };
    }

    pub fn writeTo(s: *const Setting, e: *bin.Emitter) bin.WriteError!void {
        try e.putInt(u32, 0x60);
        try e.putBytes(&s.brand);
        try e.putBytes(&s.software);
        try e.putBytes(&s.version);
        try e.putInt(u32, DevSetting.serialized_len);
        try s.data.writeTo(e);
        const checksum_at = e.pos();
        try e.putInt(u16, 0);
        try e.putInt(u16, s.unknown);
        // The checksum covers just the data section.
        const crc = crc16Xmodem(e.written()[data_offset..checksum_at]);
        e.patchIntAt(checksum_at, u16, crc);
    }

    pub fn serialize(s: *const Setting, alloc: std.mem.Allocator) bin.WriteError![]u8 {
        var e = bin.Emitter.init(alloc);
        defer e.deinit();
        try s.writeTo(&e);
        return e.toOwnedSlice();
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() Setting {
        return .{
            .brand = stringField("PIONEER DJ"),
            .software = stringField("rekordbox"),
            .version = stringField("6.6.1"),
            .data = DevSetting.default(),
            .unknown = 0,
        };
    }

    /// The brand string, without NUL padding (e.g. "PIONEER DJ").
    pub fn brandString(s: *const Setting) []const u8 {
        return fieldString(&s.brand);
    }

    /// The software string, without NUL padding (e.g. "rekordbox").
    pub fn softwareString(s: *const Setting) []const u8 {
        return fieldString(&s.software);
    }

    /// The version string, without NUL padding (e.g. "6.6.1").
    pub fn versionString(s: *const Setting) []const u8 {
        return fieldString(&s.version);
    }
};

/// Payload of a `DEVSETTING.DAT` file.
pub const DevSetting = struct {
    /// Unknown field (fixtures carry `78 56 34 12 01 00 00 00 01`), kept
    /// verbatim.
    unknown1: [9]u8,
    /// "Type of the overview Waveform" setting.
    overview_waveform_type: OverviewWaveformType,
    /// "Waveform color" setting.
    waveform_color: WaveformColor,
    /// Unknown field (apparently always `0x01`), kept verbatim.
    unknown2: u8,
    /// "Key display format" setting.
    key_display_format: KeyDisplayFormat,
    /// "Waveform Current Position" setting.
    waveform_current_position: WaveformCurrentPosition,
    /// Unknown field (apparently always zero), kept verbatim.
    unknown3: [18]u8,

    pub const serialized_len = 32;

    pub fn parse(c: *bin.Cursor) bin.ReadError!DevSetting {
        return .{
            .unknown1 = (try c.takeArray(9)).*,
            .overview_waveform_type = @enumFromInt(try c.takeInt(u8)),
            .waveform_color = @enumFromInt(try c.takeInt(u8)),
            .unknown2 = try c.takeInt(u8),
            .key_display_format = @enumFromInt(try c.takeInt(u8)),
            .waveform_current_position = @enumFromInt(try c.takeInt(u8)),
            .unknown3 = (try c.takeArray(18)).*,
        };
    }

    pub fn writeTo(d: *const DevSetting, e: *bin.Emitter) bin.WriteError!void {
        try e.putBytes(&d.unknown1);
        try e.putInt(u8, @intFromEnum(d.overview_waveform_type));
        try e.putInt(u8, @intFromEnum(d.waveform_color));
        try e.putInt(u8, d.unknown2);
        try e.putInt(u8, @intFromEnum(d.key_display_format));
        try e.putInt(u8, @intFromEnum(d.waveform_current_position));
        try e.putBytes(&d.unknown3);
    }

    /// Default values as found in Rekordbox 6.6.1.
    pub fn default() DevSetting {
        return .{
            .unknown1 = .{ 0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x01 },
            .overview_waveform_type = .half_waveform,
            .waveform_color = .blue,
            .unknown2 = 0x01,
            .key_display_format = .classic,
            .waveform_current_position = .center,
            .unknown3 = @splat(0),
        };
    }
};

/// "Type of the overview Waveform" setting. Found on the "General" page in the
/// Rekordbox preferences.
pub const OverviewWaveformType = enum(u8) {
    /// "Half Waveform"
    half_waveform = 0x01,
    /// "Full Waveform"
    full_waveform = 0x02,
    _,
};

/// "Waveform color" setting. Found on the "General" page in the Rekordbox
/// preferences.
pub const WaveformColor = enum(u8) {
    /// "BLUE"
    blue = 0x01,
    /// "RGB"
    rgb = 0x03,
    /// "3Band"
    tri_band = 0x04,
    _,
};

/// "Key display format" setting. Found on the "General" page in the Rekordbox
/// preferences.
pub const KeyDisplayFormat = enum(u8) {
    /// "Classic"
    classic = 0x01,
    /// "Alphanumeric"
    alphanumeric = 0x02,
    _,
};

/// "Waveform Current Position" setting. Found on the "General" page in the
/// Rekordbox preferences.
pub const WaveformCurrentPosition = enum(u8) {
    /// "CENTER"
    center = 0x01,
    /// "LEFT"
    left = 0x02,
    _,
};

fn stringField(comptime s: []const u8) [string_field_len]u8 {
    comptime std.debug.assert(s.len < string_field_len);
    var field = [_]u8{0} ** string_field_len;
    @memcpy(field[0..s.len], s);
    return field;
}

fn fieldString(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

/// CRC-16/XMODEM (poly 0x1021, init 0x0000, no reflection, no final xor).
/// <https://reveng.sourceforge.io/crc-catalogue/all.htm#crc.cat.crc-16-xmodem>
fn crc16Xmodem(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
        }
    }
    return crc;
}

const testing = std.testing;

test "crc16-xmodem known answer" {
    try testing.expectEqual(@as(u16, 0x31C3), crc16Xmodem("123456789"));
}

test "default roundtrip" {
    const s = Setting.default();
    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 140), out.len);

    const parsed = try Setting.parse(out);
    try testing.expectEqual(s, parsed);
    try testing.expectEqualStrings("PIONEER DJ", parsed.brandString());
    try testing.expectEqualStrings("rekordbox", parsed.softwareString());
    try testing.expectEqualStrings("6.6.1", parsed.versionString());
}

test "unknown fields and enum values roundtrip verbatim" {
    var s = Setting.default();
    s.data.unknown1 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    s.data.unknown2 = 0xAA;
    s.data.unknown3 = [_]u8{0x5A} ** 18;
    s.data.key_display_format = @enumFromInt(0x7F);
    s.unknown = 0xBEEF;

    const out = try s.serialize(testing.allocator);
    defer testing.allocator.free(out);
    const parsed = try Setting.parse(out);
    try testing.expectEqual(s, parsed);

    const out2 = try parsed.serialize(testing.allocator);
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, out, out2);
}

test "parse rejects invalid structure" {
    var e = bin.Emitter.init(testing.allocator);
    defer e.deinit();
    try Setting.default().writeTo(&e);
    try testing.expectEqual(@as(usize, 140), e.written().len);

    var bad = try testing.allocator.dupe(u8, e.written());
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0x20, .little);
    try testing.expectError(error.InvalidFormat, Setting.parse(bad));

    std.mem.writeInt(u32, bad[0..4], 0x60, .little);
    std.mem.writeInt(u32, bad[100..104], 40, .little);
    try testing.expectError(error.InvalidFormat, Setting.parse(bad));

    const long = try testing.allocator.alloc(u8, 141);
    defer testing.allocator.free(long);
    @memcpy(long[0..140], e.written());
    long[140] = 0;
    try testing.expectError(error.InvalidFormat, Setting.parse(long));

    try testing.expectError(error.UnexpectedEof, Setting.parse(e.written()[0..139]));
}

test "DEVSETTING.DAT fixtures roundtrip byte-identical" {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "DEVSETTING.DAT")) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const parsed = try Setting.parse(input);
        const output = try parsed.serialize(alloc);
        defer alloc.free(output);
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }

    // Five devsetting fixtures plus two complete device exports.
    try testing.expect(count >= 7);
}
