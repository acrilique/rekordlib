// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const device = @import("device");

const testing = std.testing;

// The two tracks of the `with_anlz` export: the audio `file_path` values
// stored in `export.pdb`, each with the analysis directory Rekordbox
// actually created under `PIONEER/USBANLZ`.
const with_anlz_tracks = [_]struct {
    audio_path: []const u8,
    anlz_dir: []const u8,
    analyze_path: []const u8,
}{
    .{
        .audio_path = "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
        .anlz_dir = "PIONEER/USBANLZ/P01F/00004BC5",
        .analyze_path = "/PIONEER/USBANLZ/P01F/00004BC5/ANLZ0000.DAT",
    },
    .{
        .audio_path = "/Contents/Reboot/www.electronicfresh.com/03. Reboot - Assign The Source (Remaster).mp3",
        .anlz_dir = "PIONEER/USBANLZ/P002/0000D534",
        .analyze_path = "/PIONEER/USBANLZ/P002/0000D534/ANLZ0000.DAT",
    },
};

// Checks `pathHash` against an expected `P{XXX}` folder and `{HHHHHHHH}`
// leaf, formatted the way the on-disk directory names are.
fn expectPathHash(audio_path: []const u8, want_folder: []const u8, want_leaf: []const u8) !void {
    const h = try device.pathHash(audio_path);
    const folder = try std.fmt.allocPrint(testing.allocator, "P{X:0>3}", .{h.p_value});
    defer testing.allocator.free(folder);
    const leaf = try std.fmt.allocPrint(testing.allocator, "{X:0>8}", .{h.hash});
    defer testing.allocator.free(leaf);
    try testing.expectEqualStrings(want_folder, folder);
    try testing.expectEqualStrings(want_leaf, leaf);
}

// Real rekordbox exports store both the audio `file_path` and the resulting
// `analyze_path`. Pioneer hardware recomputes the latter from the former,
// so `pathHash` must reproduce it exactly. Each case is
// `(file_path, P-folder, hash-leaf)`.
test "path hash matches real rekordbox exports" {
    const cases = [_]struct { audio_path: []const u8, folder: []const u8, leaf: []const u8 }{
        .{
            .audio_path = "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3",
            .folder = "P016",
            .leaf = "0000875E",
        },
        .{
            .audio_path = "/Contents/UnknownArtist/UnknownAlbum/NOISE.wav",
            .folder = "P019",
            .leaf = "00020AA9",
        },
        .{
            .audio_path = "/Contents/UnknownArtist/UnknownAlbum/SINEWAVE.wav",
            .folder = "P043",
            .leaf = "00011517",
        },
        .{
            .audio_path = "/Contents/UnknownArtist/UnknownAlbum/SIREN.wav",
            .folder = "P017",
            .leaf = "00009B77",
        },
        .{
            .audio_path = "/Contents/UnknownArtist/UnknownAlbum/HORN.wav",
            .folder = "P021",
            .leaf = "00006D2B",
        },
    };
    for (cases) |case| try expectPathHash(case.audio_path, case.folder, case.leaf);
}

test "path hash matches the with_anlz analysis directories" {
    for (with_anlz_tracks) |track| {
        const h = try device.pathHash(track.audio_path);
        const dir = try std.fmt.allocPrint(testing.allocator, "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}", .{ h.p_value, h.hash });
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings(track.anlz_dir, dir);
    }
}

test "anlz device path matches the stored analyze_path" {
    for (with_anlz_tracks) |track| {
        const path = try device.anlzDevicePath(testing.allocator, track.audio_path);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(track.analyze_path, path);
    }
}

test "layout paths match the with_anlz export" {
    const alloc = testing.allocator;
    const io = testing.io;
    const dir = std.Io.Dir.cwd();
    const layout = device.Layout{ .root = "testdata/complete_export/with_anlz" };

    // Every derived host path must exist in the fixture, exactly where the
    // fixture has it.
    const path = try layout.exportPdb(alloc);
    defer alloc.free(path);
    try testing.expectEqualStrings("testdata/complete_export/with_anlz/PIONEER/rekordbox/export.pdb", path);
    _ = try dir.statFile(io, path, .{});

    const ext_path = try layout.exportExtPdb(alloc);
    defer alloc.free(ext_path);
    try testing.expectEqualStrings("testdata/complete_export/with_anlz/PIONEER/rekordbox/exportExt.pdb", ext_path);
    _ = try dir.statFile(io, ext_path, .{});

    for (device.dat_files) |dat| {
        const dat_path = try layout.datPath(alloc, dat.name);
        defer alloc.free(dat_path);
        _ = try dir.statFile(io, dat_path, .{});
    }

    // The fixture carries all three ANLZ files for both tracks.
    for (with_anlz_tracks) |track| {
        const dat = try layout.anlzDatFile(alloc, track.audio_path);
        defer alloc.free(dat);
        const want_dat = try std.fmt.allocPrint(alloc, "testdata/complete_export/with_anlz/{s}/ANLZ0000.DAT", .{track.anlz_dir});
        defer alloc.free(want_dat);
        try testing.expectEqualStrings(want_dat, dat);
        _ = try dir.statFile(io, dat, .{});

        const ext = try layout.anlzExtFile(alloc, track.audio_path);
        defer alloc.free(ext);
        _ = try dir.statFile(io, ext, .{});

        const two_ex = try layout.anlz2exFile(alloc, track.audio_path);
        defer alloc.free(two_ex);
        _ = try dir.statFile(io, two_ex, .{});
    }

    // `Contents` is absent from the fixture (no audio files), so only the
    // derivation is pinned here.
    const contents = try layout.contentsDir(alloc);
    defer alloc.free(contents);
    try testing.expectEqualStrings("testdata/complete_export/with_anlz/Contents", contents);
}

test "dat files are in the order rekordbox writes them" {
    try testing.expectEqualSlices(
        device.DatFile,
        &.{
            .{ .name = "DEVSETTING.DAT", .kind = .dev_setting },
            .{ .name = "DJMMYSETTING.DAT", .kind = .djm_my_setting },
            .{ .name = "MYSETTING.DAT", .kind = .my_setting },
            .{ .name = "MYSETTING2.DAT", .kind = .my_setting2 },
        },
        &device.dat_files,
    );
}
