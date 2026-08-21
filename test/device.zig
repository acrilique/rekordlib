// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const device = @import("device");
const pdb = @import("pdb");
const testutil = @import("util.zig");

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

test "artwork spec pins shard folders, file names, and resolutions" {
    const alloc = testing.allocator;

    // The with_anlz export stores id 1 and 2 under shard folder 00001; the
    // Artwork rows carry the thumbnail paths.
    var spec = try device.artworkSpec(alloc, 1);
    defer spec.deinit(alloc);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/a1.jpg", spec.thumbnail_path);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/a1_m.jpg", spec.medium_path);

    // Shard folders: id/20 + 1, five digits.
    const shard_bounds = [_]struct { id: u32, folder: []const u8 }{
        .{ .id = 0, .folder = "00001" },
        .{ .id = 19, .folder = "00001" },
        .{ .id = 20, .folder = "00002" },
        .{ .id = 39, .folder = "00002" },
    };
    for (shard_bounds) |case| {
        const folder = try device.artworkFolder(alloc, case.id);
        defer alloc.free(folder);
        try testing.expectEqualStrings(case.folder, folder);
    }

    var spec2 = try device.artworkSpec(alloc, 20);
    defer spec2.deinit(alloc);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/a20.jpg", spec2.thumbnail_path);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/a20_m.jpg", spec2.medium_path);

    try testing.expectEqual(device.ArtworkCodec.jpeg, spec.codec);
    try testing.expectEqual(@as(u16, 80), spec.thumbnail_resolution.width);
    try testing.expectEqual(@as(u16, 80), spec.thumbnail_resolution.height);
    try testing.expectEqual(@as(u16, 240), spec.medium_resolution.width);
    try testing.expectEqual(@as(u16, 240), spec.medium_resolution.height);
}

// --- device reader (D2) -------------------------------------------------------

/// Fixture roots under `testdata`, with hand-checked track counts (the
/// pdb's own rows) and playlist trees.
const fixtures = [_]struct {
    name: []const u8,
    tracks: usize,
    playlists: []const PlaylistExpectation,
}{
    .{ .name = "empty", .tracks = 0, .playlists = &.{} },
    .{ .name = "demo_tracks", .tracks = 2, .playlists = &.{} },
    .{
        .name = "with_anlz",
        .tracks = 2,
        .playlists = &.{.{ .id = 1, .name = "aaaaa" }},
    },
};

/// One expected top-level playlist leaf.
const PlaylistExpectation = struct {
    id: u32,
    name: []const u8,
};

test "reader loads all four settings of every fixture" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);
        const reader = device.DeviceExportReader.init(path);
        const settings = reader.loadSettings(io, alloc);
        try testing.expect(settings.dev_setting != null);
        try testing.expect(settings.djm_my_setting != null);
        try testing.expect(settings.my_setting != null);
        try testing.expect(settings.my_setting2 != null);
    }
}

test "settings loading tolerates missing and invalid files" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // One intact settings file, one corrupted, two absent.
    const good = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/MYSETTING.DAT",
        .limited(1 << 16),
    );
    defer alloc.free(good);
    try tmp.dir.createDirPath(io, "PIONEER");
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER/MYSETTING.DAT", .data = good });
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER/DJMMYSETTING.DAT", .data = "garbage" });

    const reader = device.DeviceExportReader.init(tmp_path);
    const settings = reader.loadSettings(io, alloc);
    try testing.expect(settings.my_setting != null);
    try testing.expect(settings.djm_my_setting == null);
    try testing.expect(settings.dev_setting == null);
    try testing.expect(settings.my_setting2 == null);

    // A root without any export content at all stays quiet and empty.
    const empty_reader = device.DeviceExportReader.init(".zig-cache/definitely-not-here");
    const empty_settings = empty_reader.loadSettings(io, alloc);
    try testing.expect(empty_settings.dev_setting == null);
    try testing.expect(empty_settings.djm_my_setting == null);
    try testing.expect(empty_settings.my_setting == null);
    try testing.expect(empty_settings.my_setting2 == null);
}

test "reader opens each fixture pdb and counts its tracks" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);
        const reader = device.DeviceExportReader.init(path);

        var db = try reader.openPdb(io, alloc);
        defer db.deinit();

        var tracks: usize = 0;
        var it = try db.rows(.tracks);
        while (try it.next()) |row| switch (row.*) {
            .track => tracks += 1,
            else => {},
        };
        try testing.expectEqual(fixture.tracks, tracks);
    }
}

test "playlist trees match the fixtures" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);
        const reader = device.DeviceExportReader.init(path);

        var db = try reader.openPdb(io, alloc);
        defer db.deinit();

        var playlists = try device.getPlaylists(alloc, &db);
        defer {
            for (playlists.items) |*node| node.deinit(alloc);
            playlists.deinit(alloc);
        }
        try testing.expectEqual(fixture.playlists.len, playlists.items.len);
        for (fixture.playlists, playlists.items) |want, *node| switch (node.*) {
            .playlist => |playlist| {
                try testing.expectEqual(want.id, playlist.id);
                try testing.expectEqualStrings(want.name, playlist.name);
            },
            .folder => try testing.expect(false),
        };
    }
}

test "playlist tree nests folders in row order" {
    const alloc = testing.allocator;

    const input = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/rekordbox/export.pdb",
        .limited(1 << 22),
    );
    defer alloc.free(input);
    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();

    // The fixture has no folders, so grow a tree through the modification
    // layer: one folder under the root, two leaves under it — appended in
    // an order that is not id order, pinning row order.
    const a = db.arena.allocator();
    const nodes = [_]pdb.PlaylistTreeNode{
        .{ .id = 100, .node_is_folder = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Folder") },
        .{ .id = 101, .parent_id = 100, .name = try pdb.DeviceSQLString.fromUtf8(a, "Leaf B") },
        .{ .id = 102, .parent_id = 100, .name = try pdb.DeviceSQLString.fromUtf8(a, "Leaf A") },
    };
    for (nodes) |node| {
        const boxed = try a.create(pdb.PlaylistTreeNode);
        boxed.* = node;
        var row = pdb.Row{ .playlist_tree_node = boxed };
        _ = try db.addRow(&row);
    }

    var playlists = try device.getPlaylists(alloc, &db);
    defer {
        for (playlists.items) |*node| node.deinit(alloc);
        playlists.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), playlists.items.len);
    try testing.expectEqual(@as(u32, 1), playlists.items[0].playlist.id);
    try testing.expectEqualStrings("aaaaa", playlists.items[0].playlist.name);
    const folder = playlists.items[1].folder;
    try testing.expectEqual(@as(u32, 100), folder.id);
    try testing.expectEqualStrings("Folder", folder.name);
    try testing.expectEqual(@as(usize, 2), folder.children.items.len);
    try testing.expectEqual(@as(u32, 101), folder.children.items[0].playlist.id);
    try testing.expectEqualStrings("Leaf B", folder.children.items[0].playlist.name);
    try testing.expectEqual(@as(u32, 102), folder.children.items[1].playlist.id);
    try testing.expectEqualStrings("Leaf A", folder.children.items[1].playlist.name);
}
