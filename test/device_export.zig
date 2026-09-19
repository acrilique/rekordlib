// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const anlz = @import("rekordlib").anlz;
const device_export = @import("rekordlib").device_export;
const onelibrary = @import("rekordlib").onelibrary;
const pdb = @import("rekordlib").pdb;
const setting = @import("rekordlib").setting;
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
    const h = try device_export.pathHash(audio_path);
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
        const h = try device_export.pathHash(track.audio_path);
        const dir = try std.fmt.allocPrint(testing.allocator, "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}", .{ h.p_value, h.hash });
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings(track.anlz_dir, dir);
    }
}

test "anlz device path matches the stored analyze_path" {
    for (with_anlz_tracks) |track| {
        const path = try device_export.anlzDevicePath(testing.allocator, track.audio_path);
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(track.analyze_path, path);
    }
}

test "layout paths match the with_anlz export" {
    const alloc = testing.allocator;
    const io = testing.io;
    const dir = std.Io.Dir.cwd();
    const layout = device_export.Layout{ .root = "testdata/complete_export/with_anlz" };

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

    for (device_export.dat_files) |dat| {
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
        device_export.DatFile,
        &.{
            .{ .name = "DEVSETTING.DAT", .kind = .dev_setting },
            .{ .name = "DJMMYSETTING.DAT", .kind = .djm_my_setting },
            .{ .name = "MYSETTING.DAT", .kind = .my_setting },
            .{ .name = "MYSETTING2.DAT", .kind = .my_setting2 },
        },
        &device_export.dat_files,
    );
}

test "artwork spec pins shard folders, file names, and resolutions" {
    const alloc = testing.allocator;

    // The with_anlz export stores id 1 and 2 under shard folder 00001; the
    // Artwork rows carry the thumbnail paths.
    var spec = try device_export.artworkSpec(alloc, 1);
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
        const folder = try device_export.artworkFolder(alloc, case.id);
        defer alloc.free(folder);
        try testing.expectEqualStrings(case.folder, folder);
    }

    var spec2 = try device_export.artworkSpec(alloc, 20);
    defer spec2.deinit(alloc);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/a20.jpg", spec2.thumbnail_path);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/a20_m.jpg", spec2.medium_path);

    try testing.expectEqual(device_export.ArtworkCodec.jpeg, spec.codec);
    try testing.expectEqual(@as(u16, 80), spec.thumbnail_resolution.width);
    try testing.expectEqual(@as(u16, 80), spec.thumbnail_resolution.height);
    try testing.expectEqual(@as(u16, 240), spec.medium_resolution.width);
    try testing.expectEqual(@as(u16, 240), spec.medium_resolution.height);
}

test "artwork spec carries the OneLibrary b-variant" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Rekordbox writes both the a* and b* sets; the with_anlz export
    // carries all four files for artwork ids 1 and 2 under shard 00001.
    var spec = try device_export.artworkSpec(alloc, 1);
    defer spec.deinit(alloc);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/b1.jpg", spec.ol_thumbnail_path);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/b1_m.jpg", spec.ol_medium_path);

    const files = [_][]const u8{
        spec.thumbnail_path,
        spec.medium_path,
        spec.ol_thumbnail_path,
        spec.ol_medium_path,
    };
    for (files) |file| {
        const host = try std.fmt.allocPrint(
            alloc,
            "testdata/complete_export/with_anlz{s}",
            .{file},
        );
        defer alloc.free(host);
        _ = try std.Io.Dir.cwd().statFile(io, host, .{});
    }

    var spec2 = try device_export.artworkSpec(alloc, 20);
    defer spec2.deinit(alloc);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/b20.jpg", spec2.ol_thumbnail_path);
    try testing.expectEqualStrings("/PIONEER/Artwork/00002/b20_m.jpg", spec2.ol_medium_path);
}

test "layout derives the exportLibrary.db path" {
    const alloc = testing.allocator;
    const io = testing.io;

    const layout = device_export.Layout{ .root = "testdata/complete_export/with_anlz" };
    const path = try layout.exportLibraryDb(alloc);
    defer alloc.free(path);
    try testing.expectEqualStrings(
        "testdata/complete_export/with_anlz/PIONEER/rekordbox/exportLibrary.db",
        path,
    );
    // Newer exports carry the OneLibrary db; the two older fixtures don't.
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});
    for ([_][]const u8{ "empty", "demo_tracks" }) |name| {
        const other = try std.fmt.allocPrint(
            alloc,
            "testdata/complete_export/{s}/PIONEER/rekordbox/exportLibrary.db",
            .{name},
        );
        defer alloc.free(other);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, other, .{}));
    }
}

// --- device reader -----------------------------------------------------------------

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
        .playlists = &.{.{ .id = @enumFromInt(1), .name = "aaaaa" }},
    },
};

/// One expected top-level playlist leaf.
const PlaylistExpectation = struct {
    id: device_export.PlaylistNodeId,
    name: []const u8,
};

test "reader loads all four settings of every fixture" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);
        var ex = try device_export.DeviceExport.open(path, io, alloc);
        defer ex.deinit();
        const settings = try ex.loadSettings();
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

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    const settings = try ex.loadSettings();
    try testing.expect(settings.my_setting != null);
    try testing.expect(settings.djm_my_setting == null);
    try testing.expect(settings.dev_setting == null);
    try testing.expect(settings.my_setting2 == null);

    // A root without any export content at all fails classification.
    try testing.expectError(
        error.NotAnExport,
        device_export.DeviceExport.open(".zig-cache/definitely-not-here", io, alloc),
    );
}

test "loadSettings propagates a file that is not absence-shaped" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // A DEVSETTING.DAT over the read cap is present but unexaminable;
    // it must surface, not silently read as a null field.
    try tmp.dir.createDirPath(io, "PIONEER");
    const big = try alloc.alloc(u8, (1 << 16) + 1);
    defer alloc.free(big);
    @memset(big, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER/DEVSETTING.DAT", .data = big });

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    try testing.expectError(error.StreamTooLong, ex.loadSettings());
}

test "writeSettings lands exactly the patched files at save" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    // A settings-only root: PIONEER, one intact settings file, no
    // database at all — save must still land the patch.
    const good = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/MYSETTING.DAT",
        .limited(1 << 16),
    );
    defer alloc.free(good);
    try tmp.dir.createDirPath(io, "PIONEER");
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER/MYSETTING.DAT", .data = good });

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    var my_setting = (try ex.loadSettings()).my_setting.?;
    my_setting.quantize = .off;
    try ex.writeSettings(.{ .my_setting = device_export.wholeSetting(my_setting) });
    try ex.save();

    // The patched file changed; the unpatched absences stayed absent.
    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    const reread = try reopened.loadSettings();
    try testing.expect(reread.my_setting.?.quantize == .off);
    try testing.expect(reread.dev_setting == null);
    try testing.expect(reread.djm_my_setting == null);
    try testing.expect(reread.my_setting2 == null);
}

test "writeSettings patches fields without resetting the file" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    // Same settings-only root shape: one intact MYSETTING.DAT, nothing
    // else. The field patch must overlay onto what the file carries, not
    // replace it with defaults.
    const good = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/MYSETTING.DAT",
        .limited(1 << 16),
    );
    defer alloc.free(good);
    try tmp.dir.createDirPath(io, "PIONEER");
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER/MYSETTING.DAT", .data = good });

    // What the disk carries, read through an independent handle.
    var probe = try device_export.DeviceExport.open(root, io, alloc);
    defer probe.deinit();
    const orig = (try probe.loadSettings()).my_setting.?;

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    try ex.writeSettings(.{ .my_setting = .{ .quantize = .off } });
    try ex.save();

    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    const reread = try reopened.loadSettings();
    try testing.expect(reread.my_setting.?.quantize == .off);
    // Everything the patch left null kept the file's value, not the
    // payload default.
    try testing.expect(reread.my_setting.?.jog_mode == orig.jog_mode);
    try testing.expect(reread.my_setting.?.language == orig.language);
    try testing.expectEqualSlices(u8, &orig.unknown1, &reread.my_setting.?.unknown1);
}

test "successive writeSettings patches to one file overlay" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    var ex = try device_export.DeviceExport.create(root, io, alloc);
    defer ex.deinit();
    try ex.writeSettings(.{ .my_setting = .{ .quantize = .off } });
    try ex.writeSettings(.{ .my_setting = .{ .jog_mode = .cdj } });
    try ex.save();

    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    const settings = try reopened.loadSettings();
    // The second patch applied on top of the first, not over it.
    try testing.expect(settings.my_setting.?.quantize == .off);
    try testing.expect(settings.my_setting.?.jog_mode == .cdj);
}

test "writeSettings patches a missing file onto its default" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try tmp.dir.createDirPath(io, "PIONEER");

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    // No loadSettings round-trip needed on a file the export does not
    // carry — the patch seeds from the default.
    try ex.writeSettings(.{ .my_setting = .{ .quantize = .off } });
    try ex.save();

    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    const settings = try reopened.loadSettings();
    try testing.expect(settings.my_setting.?.quantize == .off);
    try testing.expect(settings.my_setting.?.jog_mode == .vinyl);
    try testing.expect(settings.dev_setting == null);
}

test "writeSettings overrides a created export's default" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    var ex = try device_export.DeviceExport.create(root, io, alloc);
    defer ex.deinit();
    try ex.writeSettings(.{ .my_setting = .{ .quantize = .off } });
    try ex.save();

    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    const settings = try reopened.loadSettings();
    // All four defaults landed; the patch won where it named a file.
    try testing.expect(settings.dev_setting != null);
    try testing.expect(settings.djm_my_setting != null);
    try testing.expect(settings.my_setting.?.quantize == .off);
    try testing.expect(settings.my_setting2 != null);
}

test "reader opens each fixture pdb and counts its tracks" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);

        var db = try parseExportPdb(alloc, io, path);
        defer db.deinit();

        var tracks: usize = 0;
        var it = try db.rowsOf(pdb.Track);
        while (try it.next()) |_| tracks += 1;
        try testing.expectEqual(fixture.tracks, tracks);
    }
}

test "playlist trees match the fixtures" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (fixtures) |fixture| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{fixture.name});
        defer alloc.free(path);
        var ex = try device_export.DeviceExport.open(path, io, alloc);
        defer ex.deinit();

        var playlists = try ex.getPlaylists();
        defer playlists.deinit();
        try testing.expectEqual(fixture.playlists.len, playlists.roots.len);
        for (fixture.playlists, playlists.roots) |want, *node| switch (node.*) {
            .playlist => |playlist| {
                try testing.expectEqual(want.id, playlist.id);
                try testing.expectEqualStrings(want.name, playlist.name);
            },
            .folder => try testing.expect(false),
        };
    }
}

// --- OneLibrary reader hook -------------------------------------------------------

test "OL reader hook loads with_anlz and joins tracks by path" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();

    const lib = (try ex.openOneLibrary()).?;
    // The join: each pdb track's file_path names its OL content row,
    // carrying the fields the pdb lacks.
    const bako = lib.contentByPath(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    ).?;
    try testing.expectEqual(@as(i64, 2), bako.content_id);
    try testing.expectEqualStrings("Bako (Original Mix)", bako.title.?);
    try testing.expectEqual(@as(i64, 16), bako.bitDepth.?);
    try testing.expectEqual(@as(i64, 44100), bako.samplingRate.?);
    try testing.expectEqual(@as(i64, 0), bako.djPlayCount.?);
    try testing.expect(lib.hot_cue_bank_lists.len == 0);

    // Cached: the second call returns the same models without re-reading.
    try testing.expectEqual(lib, (try ex.openOneLibrary()).?);
}

test "OL reader hook is null without an exportLibrary.db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/demo_tracks", io, alloc);
    defer ex.deinit();
    try testing.expect((try ex.openOneLibrary()) == null);
    // The absent verdict is cached too.
    try testing.expect((try ex.openOneLibrary()) == null);
}

// --- OneLibrary writer mirror --------------------------------------------------------

/// Copies one file of a fixture export into the same place under a
/// temp-dir export root.
fn copyFixtureFile(
    tmp: *testing.TmpDir,
    io: std.Io,
    alloc: std.mem.Allocator,
    fixture: []const u8,
    sub_path: []const u8,
) !void {
    const src = try std.fmt.allocPrint(
        alloc,
        "complete_export/{s}/{s}",
        .{ fixture, sub_path },
    );
    defer alloc.free(src);
    const image = try testutil.readFixture(alloc, src, .limited(1 << 22));
    defer alloc.free(image);
    try tmp.dir.createDirPath(io, std.fs.path.dirname(sub_path) orelse ".");
    try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = image });
}

/// Copies a fixture's `exportLibrary.db` into a temp-dir export root.
fn copyFixtureOlDb(
    tmp: *testing.TmpDir,
    io: std.Io,
    alloc: std.mem.Allocator,
) !void {
    try copyFixtureFile(
        tmp,
        io,
        alloc,
        "with_anlz",
        "PIONEER/rekordbox/exportLibrary.db",
    );
}

/// The absolute, NUL-terminated path of the temp dir's OL db.
fn tmpOlDbPath(tmp: *testing.TmpDir, alloc: std.mem.Allocator) ![:0]u8 {
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    return std.fmt.allocPrintSentinel(
        alloc,
        "{s}/PIONEER/rekordbox/exportLibrary.db",
        .{tmp_path},
        0,
    );
}

test "create saves an OL db with defaults and zero contents" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    try ex.save();

    // The db is keyed (salt, not the SQLite magic) and leaves no sidecars.
    const raw = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/exportLibrary.db",
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(raw);
    try testing.expect(!std.mem.eql(u8, raw[0..16], "SQLite format 3\x00"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "PIONEER/rekordbox/exportLibrary.db-wal", .{}));

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    // The same seeded shape as a fresh rb export, and nothing else.
    try testing.expectEqual(@as(usize, 8), lib.colors.len);
    try testing.expectEqual(@as(usize, 27), lib.menu_items.len);
    try testing.expectEqual(@as(usize, 22), lib.categories.len);
    try testing.expectEqual(@as(usize, 17), lib.sorts.len);
    try testing.expectEqual(@as(usize, 0), lib.contents.len);
    try testing.expectEqual(@as(usize, 0), lib.artists.len);
    try testing.expectEqual(@as(usize, 0), lib.my_tags.len);
    try testing.expectEqualStrings("10000", lib.property.?.dbVersion.?);
    try testing.expectEqual(@as(i64, 0), lib.property.?.numberOfContents.?);
    // The library reads no clock and create takes no date.
    try testing.expectEqualStrings("", lib.property.?.createdDate.?);

    var check = try db.prepare("PRAGMA integrity_check;");
    defer check.finalize();
    try testing.expectEqual(.row, try check.step());
    try testing.expectEqualStrings("ok", check.readText(0));

    // A second save with nothing pending does not rewrite the db.
    try ex.save();
    const again = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/exportLibrary.db",
        alloc,
        .limited(1 << 20),
    );
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, raw, again);
}

test "off builds write no exportLibrary.db" {
    if (onelibrary.mode != .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{ .title = "song", .file_path = "/Contents/song.mp3" });
    try ex.save();

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "PIONEER/rekordbox/exportLibrary.db", .{}),
    );
}

test "addTrack mirrors a content row and its dimensions" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const first = try ex.addTrack(.{
        .title = "Bako",
        .artist = "Reboot",
        .album = " www.electronicfresh.com",
        .genre = "Tech House",
        .key = "Am",
        .label = "Cecille",
        .comment = "nice one",
        .release_date = "2022-03-04",
        .date_added = "2026-08-24",
        .file_path = "/Contents/Reboot/01. Bako.mp3",
        .filename = "01. Bako.mp3",
        .artwork_device_path = "/PIONEER/Artwork/00001/a1.jpg",
        .tempo = 129.0,
        .bitrate = 320,
        .sample_rate = 44_100,
        .sample_depth = 16,
        .duration_secs = 398,
        .file_size = 16_009_841,
        .track_number = 1,
        .year = 2022,
        .rating = 4,
        .play_count = 2,
        .color = .aqua,
        .file_type = .mp3,
        .autoload_hotcues = true,
    });
    // A second track sharing the artist, genre, label, key, and artwork:
    // the mirrored dimensions dedup, exactly like the pdb side.
    _ = try ex.addTrack(.{
        .title = "Assign",
        .artist = "Reboot",
        .genre = "Tech House",
        .key = "A Minor",
        .label = "Cecille",
        .remixer = "Reboot",
        .file_path = "/Contents/Reboot/02. Assign.mp3",
        .filename = "02. Assign.mp3",
        .artwork_device_path = "/PIONEER/Artwork/00001/a1.jpg",
    });
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    try testing.expectEqual(@as(usize, 2), lib.contents.len);
    try testing.expectEqual(@as(i64, 2), lib.property.?.numberOfContents.?);

    // The content row: bridged id, mirrored facts, the fixture's NULL
    // versus empty-string conventions, and the cross-format constants.
    const content = lib.byId(onelibrary.Content, first.id.int()).?;
    try testing.expectEqualStrings("Bako", content.title.?);
    try testing.expectEqual(@as(i64, 12_900), content.bpmx100.?);
    try testing.expectEqual(@as(i64, 398), content.length.?);
    try testing.expectEqual(@as(i64, 1), content.trackNo.?);
    try testing.expectEqual(@as(i64, 1), content.artist_id_artist.?);
    try testing.expectEqual(@as(i64, 1), content.album_id.?);
    try testing.expectEqual(@as(i64, 1), content.genre_id.?);
    try testing.expectEqual(@as(i64, 1), content.label_id.?);
    try testing.expectEqual(@as(i64, 1), content.key_id.?);
    try testing.expectEqual(@as(i64, 6), content.color_id.?);
    try testing.expectEqual(@as(i64, 1), content.image_id.?);
    try testing.expectEqualStrings("nice one", content.djComment.?);
    try testing.expectEqual(@as(i64, 4), content.rating.?);
    try testing.expectEqual(@as(i64, 2022), content.releaseYear.?);
    try testing.expectEqualStrings("2022-03-04", content.releaseDate.?);
    try testing.expectEqualStrings("2026-08-24", content.dateCreated.?);
    try testing.expectEqualStrings("2026-08-24", content.dateAdded.?);
    try testing.expectEqualStrings("/Contents/Reboot/01. Bako.mp3", content.path.?);
    try testing.expectEqual(@as(i64, 320), content.bitrate.?);
    try testing.expectEqual(@as(i64, 16), content.bitDepth.?);
    try testing.expectEqual(@as(i64, 44_100), content.samplingRate.?);
    try testing.expectEqual(@as(i64, 1), content.fileType.?);
    try testing.expectEqual(@as(i64, 41), content.analysedBits.?);
    try testing.expectEqual(@as(i64, 788_224), content.contentLink.?);
    try testing.expectEqual(@as(i64, 1), content.isHotCueAutoLoadOn.?);
    try testing.expect(content.titleForSearch == null);
    try testing.expect(content.subtitle != null and content.subtitle.?.len == 0);
    try testing.expect(content.isrc != null and content.isrc.?.len == 0);
    try testing.expect(content.artist_id_remixer == null);
    try testing.expect(content.masterDbId == null);
    try testing.expect(content.analysisDataFilePath == null);
    try testing.expect(content.cueUpdateCount == null);

    // The second track: dimensions reused (both point at id 1), the
    // remixer resolved as its own artist role, and no new rows.
    const second = lib.contentByPath("/Contents/Reboot/02. Assign.mp3").?;
    try testing.expectEqual(@as(i64, 1), second.artist_id_artist.?);
    try testing.expectEqual(@as(i64, 1), second.artist_id_remixer.?);
    try testing.expectEqual(@as(i64, 1), second.genre_id.?);
    try testing.expectEqual(@as(i64, 1), second.label_id.?);
    try testing.expectEqual(@as(i64, 1), second.key_id.?);
    try testing.expectEqual(@as(i64, 0), second.album_id.?);
    try testing.expectEqual(@as(i64, 0), second.color_id.?);

    try testing.expectEqual(@as(usize, 1), lib.artists.len);
    try testing.expectEqual(@as(usize, 1), lib.genres.len);
    try testing.expectEqual(@as(usize, 1), lib.labels.len);
    try testing.expectEqual(@as(usize, 1), lib.keys.len);
    try testing.expectEqual(@as(usize, 1), lib.albums.len);
    try testing.expectEqual(@as(usize, 1), lib.images.len);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/b1.jpg", lib.images[0].path.?);
    // "Am" and "A Minor" folded to one canonical key row.
    try testing.expectEqualStrings("Amin", lib.keys[0].name.?);
}

test "addTrack authors OL-only columns and mints a lyricist artist" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "Cirrus",
        .artist = "Ninja",
        .lyricist = "Kuro",
        .date_added = "2026-01-02",
        .date_created = "2025-12-31",
        .subtitle = "Original Mix",
        .title_for_search = "cirrus",
        .kuvo_delivery_on = false,
        .kuvo_delivery_comment = "hold",
        .cue_update_count = 1,
        .analysis_data_update_count = 2,
        .information_update_count = 3,
        .file_path = "/Contents/Ninja/01. Cirrus.mp3",
        .filename = "01. Cirrus.mp3",
    });
    // The dedup path ignores OL extras: the same file_path returns the
    // existing track (append-only, no update), so none of this lands.
    const dup = try ex.addTrack(.{
        .title = "Cirrus",
        .file_path = "/Contents/Ninja/01. Cirrus.mp3",
        .subtitle = "ignored",
    });
    try testing.expect(!dup.is_new);
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    try testing.expectEqual(@as(usize, 1), lib.contents.len);
    const content = lib.contents[0];
    try testing.expectEqualStrings("Original Mix", content.subtitle.?);
    try testing.expectEqualStrings("cirrus", content.titleForSearch.?);
    try testing.expectEqual(@as(i64, 0), content.isKuvoDeliverStatusOn.?);
    try testing.expectEqualStrings("hold", content.kuvoDeliveryComment.?);
    try testing.expectEqualStrings("2025-12-31", content.dateCreated.?);
    try testing.expectEqualStrings("2026-01-02", content.dateAdded.?);
    try testing.expectEqual(@as(i64, 1), content.cueUpdateCount.?);
    try testing.expectEqual(@as(i64, 2), content.analysisDataUpdateCount.?);
    try testing.expectEqual(@as(i64, 3), content.informationUpdateCount.?);

    // Two artist rows: the bridged performer and the minted lyricist —
    // the only mirrored row without a pdb id, so its id starts above
    // every possible bridged u32.
    try testing.expectEqual(@as(usize, 2), lib.artists.len);
    try testing.expectEqualStrings("Ninja", lib.artists[0].name.?);
    try testing.expectEqual(@as(i64, 1), lib.artists[0].artist_id);
    const lyricist = lib.byId(onelibrary.Artist, content.artist_id_lyricist.?).?;
    try testing.expectEqualStrings("Kuro", lyricist.name.?);
    try testing.expect(lyricist.artist_id >= 0x1_0000_0000);
}

test "a lyricist sharing the track artist resolves, never mints" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "Kite",
        .artist = "Yuki",
        .lyricist = "Yuki",
        .file_path = "/Contents/Yuki/01. Kite.flac",
        .filename = "01. Kite.flac",
    });
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    try testing.expectEqual(@as(usize, 1), lib.artists.len);
    const content = lib.contents[0];
    try testing.expectEqual(content.artist_id_artist, content.artist_id_lyricist);
}

test "a failed OL batch rolls back whole and stays pending" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{ .title = "a", .artist = "Ar", .file_path = "/Contents/a.mp3" });
    try ex.save();

    // Break the lockstep id bridge by hand: an artist row under the id
    // the next mirror will bridge (1 "Ar", then 2, 3...), named NULL so
    // no dedup key collides with it either.
    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    {
        var w = try onelibrary.Writer.open(io, db_path);
        try w.insert(onelibrary.Artist{ .artist_id = 3 });
        try w.close();
    }

    _ = try ex.addTrack(.{ .title = "b", .artist = "Br", .file_path = "/Contents/b.mp3" });
    _ = try ex.addTrack(.{ .title = "c", .artist = "Cr", .file_path = "/Contents/c.mp3" });

    // The artists batch dies on the poisoned id and rolls back whole —
    // "Br", the row before the poison, stays out of the db too (the
    // table keeps just "Ar" and the poison itself) — and the pending
    // rows survive the failure, failing a retry the same way without
    // ever duplicating a landed row.
    try testing.expectError(error.Sqlite, ex.save());
    {
        var db = try onelibrary.Db.open(io, db_path);
        defer db.close();
        var lib = try onelibrary.Library.load(alloc, db);
        defer lib.deinit();
        try testing.expectEqual(@as(usize, 2), lib.artists.len);
        try testing.expectEqual(@as(usize, 1), lib.contents.len);
        try testing.expect(lib.byId(onelibrary.Artist, 2) == null);
    }
    try testing.expectError(error.Sqlite, ex.save());
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 2), lib.artists.len);
    try testing.expectEqual(@as(usize, 1), lib.contents.len);
    try testing.expect(lib.byId(onelibrary.Artist, 2) == null);
}

test "a save blocked at the first OL batch recovers whole on retry" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const first = try ex.addTrack(.{
        .title = "first",
        .artist = "Ar",
        .file_path = "/Contents/first.mp3",
    });
    const pl = try ex.createPlaylist("pl", .root);
    try ex.addTrackToPlaylist(pl, first.id);
    const cat = try ex.createTagCategory("Cats");
    try ex.addTagsToTrack(first.id, cat, &.{"fav"});
    try ex.save();

    const second = try ex.addTrack(.{
        .title = "second",
        .artist = "Br",
        .file_path = "/Contents/second.mp3",
    });
    try ex.addTrackToPlaylist(pl, second.id);
    try ex.addTagsToTrack(second.id, cat, &.{"go"});

    // A second connection holding the write lock fails the first drain's
    // BEGIN IMMEDIATE — nothing lands.
    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var blocker = try onelibrary.Db.open(io, db_path);
    try blocker.exec("BEGIN IMMEDIATE;");
    try testing.expectError(error.Sqlite, ex.save());
    try blocker.exec("ROLLBACK;");
    blocker.close();

    // The still-pending rows land whole on the retry, exactly once, with
    // the playlist ordinals continuing past the rows already on disk.
    try ex.save();
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 2), lib.artists.len);
    try testing.expectEqual(@as(usize, 2), lib.contents.len);
    try testing.expectEqual(@as(i64, 2), lib.property.?.numberOfContents.?);
    try testing.expectEqual(@as(usize, 2), lib.playlist_contents.len);
    const entries = lib.playlist_contents_by_playlist.get(pl.int()).?;
    try testing.expectEqual(@as(i64, 1), lib.playlist_contents[entries[0]].sequenceNo.?);
    try testing.expectEqual(@as(i64, 2), lib.playlist_contents[entries[1]].sequenceNo.?);
    try testing.expectEqual(@as(usize, 2), lib.my_tag_contents.len);
}

test "addTrack mirrors the analysis path when analysis pends" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var beats = [1]anlz.Beat{.{ .beat_number = 1, .tempo = 12_800, .time = 0 }};
    const input = anlz.Analysis{ .beats = &beats };

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "analyzed",
        .file_path = "/Contents/analyzed.mp3",
        .analysis = &input,
    });
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    const content = lib.contents[0];
    const want = try device_export.anlzDevicePath(alloc, "/Contents/analyzed.mp3");
    defer alloc.free(want);
    try testing.expectEqualStrings(want, content.analysisDataFilePath.?);
}

test "mirroring dedups against an existing OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    try copyFixturePdb(&tmp, io, alloc, "with_anlz");
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    // The fixture's own artist and genre, a new path: the mirror must
    // reuse the db's rows (artist 1 "Reboot", genre 2 "Tech House")
    // instead of inserting bridged duplicates.
    const outcome = try ex.addTrack(.{
        .title = "new song",
        .artist = "Reboot",
        .genre = "Tech House",
        .file_path = "/Contents/Reboot/03. new song.mp3",
        .filename = "03. new song.mp3",
    });
    try testing.expect(outcome.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(3)), outcome.id);
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    try testing.expectEqual(@as(usize, 3), lib.contents.len);
    try testing.expectEqual(@as(i64, 3), lib.property.?.numberOfContents.?);
    try testing.expectEqual(@as(usize, 1), lib.artists.len);
    try testing.expectEqual(@as(usize, 2), lib.genres.len);
    const content = lib.contentByPath("/Contents/Reboot/03. new song.mp3").?;
    try testing.expectEqual(@as(i64, 3), content.content_id);
    try testing.expectEqual(@as(i64, 1), content.artist_id_artist.?);
    try testing.expectEqual(@as(i64, 2), content.genre_id.?);

    // Across the save/reopen boundary the pdb-side path dedup still
    // gates the mirror: re-adding inserts nothing anywhere.
    var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer reopened.deinit();
    const again = try reopened.addTrack(.{
        .title = "new song",
        .artist = "Reboot",
        .genre = "Tech House",
        .file_path = "/Contents/Reboot/03. new song.mp3",
        .filename = "03. new song.mp3",
    });
    try testing.expect(!again.is_new);
    try reopened.save();

    var db2 = try onelibrary.Db.open(io, db_path);
    defer db2.close();
    var lib2 = try onelibrary.Library.load(alloc, db2);
    defer lib2.deinit();
    try testing.expectEqual(@as(usize, 3), lib2.contents.len);
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

    var playlists = try device_export.getPlaylistsDb(alloc, &db);
    defer playlists.deinit();

    try testing.expectEqual(@as(usize, 2), playlists.roots.len);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(1)), playlists.roots[0].playlist.id);
    try testing.expectEqualStrings("aaaaa", playlists.roots[0].playlist.name);
    const folder = playlists.roots[1].folder;
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(100)), folder.id);
    try testing.expectEqualStrings("Folder", folder.name);
    try testing.expectEqual(@as(usize, 2), folder.children.items.len);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(101)), folder.children.items[0].playlist.id);
    try testing.expectEqualStrings("Leaf B", folder.children.items[0].playlist.name);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(102)), folder.children.items[1].playlist.id);
    try testing.expectEqualStrings("Leaf A", folder.children.items[1].playlist.name);
}

test "playlist tree cuts parent-id cycles" {
    const alloc = testing.allocator;

    const input = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/rekordbox/export.pdb",
        .limited(1 << 22),
    );
    defer alloc.free(input);
    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();

    // The two cycle shapes reachable from the root: a folder carrying the
    // root's own id 0 parented to 0, and a duplicated folder id parented to
    // itself. Before the visited guard, both recursed until the stack
    // overflowed.
    const a = db.arena.allocator();
    const nodes = [_]pdb.PlaylistTreeNode{
        .{ .id = 0, .parent_id = 0, .node_is_folder = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Root cycle") },
        .{ .id = 5, .parent_id = 0, .node_is_folder = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Outer") },
        .{ .id = 5, .parent_id = 5, .node_is_folder = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Inner") },
    };
    for (nodes) |node| {
        const boxed = try a.create(pdb.PlaylistTreeNode);
        boxed.* = node;
        var row = pdb.Row{ .playlist_tree_node = boxed };
        _ = try db.addRow(&row);
    }

    var playlists = try device_export.getPlaylistsDb(alloc, &db);
    defer playlists.deinit();

    // The top level holds the real playlist and the id-0 folder; the
    // duplicated id 5 is expanded once (inside the id-0 folder) and skipped
    // at the top level.
    try testing.expectEqual(@as(usize, 2), playlists.roots.len);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(1)), playlists.roots[0].playlist.id);
    const root_cycle = playlists.roots[1].folder;
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(0)), root_cycle.id);
    try testing.expectEqual(@as(usize, 2), root_cycle.children.items.len);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(1)), root_cycle.children.items[0].playlist.id);
    const inner = root_cycle.children.items[1].folder;
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(5)), inner.id);
    try testing.expectEqual(@as(usize, 0), inner.children.items.len);
}

test "playlist tree handles nesting far beyond any call stack" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
    defer db.deinit();
    const a = db.arena.allocator();

    // The crash shape of the recursive walk: distinct folder ids parented
    // linearly, so the cycle guard never fires and only the depth grows.
    const depth = 100_000;
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        const node = try a.create(pdb.PlaylistTreeNode);
        node.* = .{
            .parent_id = i, // node i+1 parented to node i
            .id = i + 1,
            .node_is_folder = 1,
            .name = try pdb.DeviceSQLString.fromUtf8(a, "F"),
        };
        var row = pdb.Row{ .playlist_tree_node = node };
        _ = try db.addRow(&row);
    }

    var tree = try device_export.getPlaylistsDb(alloc, &db);
    defer tree.deinit();

    // One root nesting `depth` deep; verify by walking iteratively, the
    // way any consumer of an unbounded tree must.
    try testing.expectEqual(@as(usize, 1), tree.roots.len);
    var nodes: std.ArrayList(*const device_export.PlaylistNode) = .empty;
    defer nodes.deinit(alloc);
    var depths: std.ArrayList(usize) = .empty;
    defer depths.deinit(alloc);
    try nodes.append(alloc, &tree.roots[0]);
    try depths.append(alloc, 1);
    var max_depth: usize = 0;
    var folder_count: usize = 0;
    while (nodes.pop()) |node| {
        const d = depths.pop().?;
        max_depth = @max(max_depth, d);
        switch (node.*) {
            .folder => |folder| {
                folder_count += 1;
                for (folder.children.items) |*child| {
                    try nodes.append(alloc, child);
                    try depths.append(alloc, d + 1);
                }
            },
            .playlist => {},
        }
    }
    try testing.expectEqual(depth, max_depth);
    try testing.expectEqual(depth, folder_count);
}

/// Counts the rows of one table through its page chain.
fn countTableRows(db: *const pdb.Database, page_type: pdb.PageType) !usize {
    var it = try db.rows(page_type);
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    return count;
}

/// Parses `root`'s `export.pdb` off disk — the manual path's read half,
/// verifying the landed bytes rather than any in-handle state.
fn parseExportPdb(alloc: std.mem.Allocator, io: std.Io, root_path: []const u8) !pdb.Database {
    const layout = device_export.Layout{ .root = root_path };
    const path = try layout.exportPdb(alloc);
    defer alloc.free(path);
    const dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer dir.close(io);
    const image = try dir.readFileAlloc(io, path, alloc, .limited(1 << 26));
    defer alloc.free(image);
    return pdb.Database.parse(alloc, image, .plain);
}

/// Copies the `empty` fixture's setting files and `export.pdb` into a
/// temp-dir export root.
fn copyEmptyFixture(tmp: *testing.TmpDir, io: std.Io, alloc: std.mem.Allocator) !void {
    try tmp.dir.createDirPath(io, "PIONEER/rekordbox");
    const pdb_image = try testutil.readFixture(
        alloc,
        "complete_export/empty/PIONEER/rekordbox/export.pdb",
        .limited(1 << 22),
    );
    defer alloc.free(pdb_image);
    try tmp.dir.writeFile(io, .{
        .sub_path = "PIONEER/rekordbox/export.pdb",
        .data = pdb_image,
    });
    for (device_export.dat_files) |dat| {
        const src = try std.fmt.allocPrint(
            alloc,
            "complete_export/empty/PIONEER/{s}",
            .{dat.name},
        );
        defer alloc.free(src);
        const image = try testutil.readFixture(alloc, src, .limited(1 << 16));
        defer alloc.free(image);
        const dst = try std.fmt.allocPrint(alloc, "PIONEER/{s}", .{dat.name});
        defer alloc.free(dst);
        try tmp.dir.writeFile(io, .{ .sub_path = dst, .data = image });
    }
}

test "create saves an export shaped like the empty fixture" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    try ex.save();

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();

    const empty_image = try testutil.readFixture(
        alloc,
        "complete_export/empty/PIONEER/rekordbox/export.pdb",
        .limited(1 << 22),
    );
    defer alloc.free(empty_image);
    var empty = try pdb.Database.parse(alloc, empty_image, .plain);
    defer empty.deinit();

    // The fixed 20-table structure, in order.
    try testing.expectEqual(empty.header.tables.len, db.header.tables.len);
    for (empty.header.tables, db.header.tables) |want, got| {
        try testing.expectEqual(want.page_type, got.page_type);
    }

    // Same rows as the real export in every content and defaults table.
    // The one difference: rb writes a History row (the sync record) when
    // it creates an export; rekordcrate's `create` — and ours — starts
    // that table empty, so it is asserted as zero instead.
    const table_types = [_]pdb.PageType{
        .tracks,           .genres,            .artists,         .albums,
        .labels,           .keys,              .colors,          .playlist_tree,
        .playlist_entries, .history_playlists, .history_entries, .artwork,
        .columns,          .menu,
    };
    inline for (table_types) |page_type| {
        try testing.expectEqual(
            try countTableRows(&empty, page_type),
            try countTableRows(&db, page_type),
        );
    }
    try testing.expectEqual(@as(usize, 1), try countTableRows(&empty, .history));
    try testing.expectEqual(@as(usize, 0), try countTableRows(&db, .history));
    try testing.expectEqual(@as(usize, 8), try countTableRows(&db, .colors));
    try testing.expectEqual(@as(usize, 27), try countTableRows(&db, .columns));
    try testing.expectEqual(@as(usize, 22), try countTableRows(&db, .menu));

    // All four settings landed, parse back, and re-serialize byte-equal —
    // the default constructors and checksums agree with a real export.
    const settings = try ex.loadSettings();
    try testing.expect(settings.dev_setting != null);
    try testing.expect(settings.djm_my_setting != null);
    try testing.expect(settings.my_setting != null);
    try testing.expect(settings.my_setting2 != null);
    const dat = try tmp.dir.readFileAlloc(io, "PIONEER/DEVSETTING.DAT", alloc, .limited(1 << 16));
    defer alloc.free(dat);
    const reserialized = try (try setting.Setting(setting.DevSetting).parse(dat)).serialize(alloc);
    defer alloc.free(reserialized);
    try testing.expectEqualSlices(u8, dat, reserialized);

    // The scaffolding of a created export.
    try tmp.dir.access(io, "PIONEER/USBANLZ", .{});
    try tmp.dir.access(io, "Contents", .{});
}

test "create without save leaves nothing on disk" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    ex.deinit();

    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "PIONEER", .{}));
}

test "a save that fails validation writes nothing" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // A valid export on disk.
    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{ .title = "Music", .file_path = "/Contents/music.mp3" });
    try ex.save();

    // Manual-path surgery: the landed row shrunk below the CDJ minimum.
    // `addRow` would reject it up front, so the box edit comes after.
    {
        var db = try parseExportPdb(alloc, io, tmp_path);
        defer db.deinit();
        var it = try db.rowsOf(pdb.Track);
        while (try it.next()) |track| {
            track.offsets.inner.comment = pdb.DeviceSQLString.empty();
        }
        const image = try db.serialize(alloc);
        defer alloc.free(image);
        try device_export.writeFileAtomic(io, tmp.dir, "PIONEER/rekordbox/export.pdb", image);
    }

    // A handle over it refuses to save, leaving the file untouched.
    const before = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/export.pdb",
        alloc,
        .limited(1 << 26),
    );
    defer alloc.free(before);
    var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer reopened.deinit();
    try testing.expectError(error.TrackRowTooSmall, reopened.save());
    const after = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/export.pdb",
        alloc,
        .limited(1 << 26),
    );
    defer alloc.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "create refuses a root that already has an export" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    try copyEmptyFixture(&tmp, io, alloc);

    try testing.expectError(
        error.ExportAlreadyExists,
        device_export.DeviceExport.create(tmp_path, io, alloc),
    );
}

test "save is byte-stable" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    try ex.save();

    const first = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/export.pdb",
        alloc,
        .limited(1 << 26),
    );
    defer alloc.free(first);

    // The second save rewrites the pdb only; the fresh-write model makes
    // it byte-identical.
    try ex.save();
    const second = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/export.pdb",
        alloc,
        .limited(1 << 26),
    );
    defer alloc.free(second);
    try testing.expectEqualSlices(u8, first, second);

    // And the settings were not rewritten: still exactly four DATs.
    const settings = try ex.loadSettings();
    try testing.expect(settings.my_setting != null);
}

test "opened export edits persist through save" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    try copyEmptyFixture(&tmp, io, alloc);

    // Manual-path surgery before the handle exists: a genre row through
    // the modification layer.
    {
        var db = try parseExportPdb(alloc, io, tmp_path);
        defer db.deinit();
        const a = db.arena.allocator();
        const genre = try a.create(pdb.Genre);
        genre.* = .{ .id = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Techno") };
        var row = pdb.Row{ .genre = genre };
        _ = try db.addRow(&row);
        const image = try db.serialize(alloc);
        defer alloc.free(image);
        try device_export.writeFileAtomic(io, tmp.dir, "PIONEER/rekordbox/export.pdb", image);
    }

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();

    // An opened export never rewrites its setting files.
    const dat_before = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/MYSETTING.DAT",
        alloc,
        .limited(1 << 16),
    );
    defer alloc.free(dat_before);
    try ex.save();
    const dat_after = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/MYSETTING.DAT",
        alloc,
        .limited(1 << 16),
    );
    defer alloc.free(dat_after);
    try testing.expectEqualSlices(u8, dat_before, dat_after);

    var db2 = try parseExportPdb(alloc, io, tmp_path);
    defer db2.deinit();
    try testing.expectEqual(@as(usize, 1), try countTableRows(&db2, .genres));
}

// --- writer: lazy scan -----------------------------------------------------------

/// Asserts `canonicalKeyName(in) == want`, freeing the owned result.
fn expectCanonical(in: []const u8, want: []const u8) !void {
    const alloc = testing.allocator;
    const got = try device_export.canonicalKeyName(alloc, in);
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
}

test "canonical key name folds major forms" {
    try expectCanonical("C Major", "Cmaj");
    try expectCanonical("Cmaj", "Cmaj");
    try expectCanonical("C MAJOR", "Cmaj");
    try expectCanonical("Cmajor", "Cmaj");
    // The note letter's case is preserved as given.
    try expectCanonical("c MAJOR", "cmaj");
}

test "canonical key name folds minor forms" {
    try expectCanonical("A Minor", "Amin");
    try expectCanonical("Amin", "Amin");
    try expectCanonical("A MINOR", "Amin");
    // Bare 'm' suffix is minor.
    try expectCanonical("Am", "Amin");
}

test "canonical key name folds accidentals" {
    // Unicode ♭/♯ and the words flat/sharp all collapse to ascii.
    try expectCanonical("B\u{266d}m", "Bbmin");
    try expectCanonical("B flat minor", "Bbmin");
    try expectCanonical("F\u{266f}m", "F#min");
    try expectCanonical("F sharp Minor", "F#min");
}

test "canonical key name dedups equivalent spellings" {
    // The whole point: these must all collide so they share one pdb Key row.
    try expectCanonical("D Major", "Dmaj");
    try expectCanonical("", "");
}

/// Hand-checked writer-state expectations for the complete exports,
/// probed from the fixtures once (2026-08-23): counters are max id + 1
/// per table, map keys exactly as the rows carry them.
const scan_expectations = [_]struct {
    name: []const u8,
    next_track_id: u32 = 1,
    next_artist_id: u32 = 1,
    next_album_id: u32 = 1,
    next_genre_id: u32 = 1,
    next_key_id: u32 = 1,
    next_label_id: u32 = 1,
    next_artwork_id: u32 = 1,
    next_playlist_node_id: u32 = 1,
    track_ids: usize = 0,
    tracks_by_path: []const []const u8 = &.{},
    artists: []const NameId = &.{},
    genres: []const NameId = &.{},
    keys_canonical: []const NameId = &.{},
    labels: []const NameId = &.{},
    artwork: []const NameId = &.{},
    playlists: usize = 0,
}{
    .{
        .name = "with_anlz",
        .next_track_id = 3,
        .next_artist_id = 2,
        .next_album_id = 2,
        .next_genre_id = 3,
        .next_label_id = 2,
        .next_artwork_id = 3,
        .next_playlist_node_id = 2,
        .track_ids = 2,
        .tracks_by_path = &.{
            "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
            "/Contents/Reboot/www.electronicfresh.com/03. Reboot - Assign The Source (Remaster).mp3",
        },
        .artists = &.{.{ .name = "Reboot", .id = 1 }},
        .genres = &.{ .{ .name = "Minimal / Deep Tech", .id = 1 }, .{ .name = "Tech House", .id = 2 } },
        .labels = &.{.{ .name = "Cecille", .id = 1 }},
        .artwork = &.{
            .{ .name = "/PIONEER/Artwork/00001/a1.jpg", .id = 1 },
            .{ .name = "/PIONEER/Artwork/00001/a2.jpg", .id = 2 },
        },
        .playlists = 1,
    },
    .{
        .name = "demo_tracks",
        .next_track_id = 3,
        .next_artist_id = 2,
        .next_key_id = 6,
        .next_label_id = 2,
        .track_ids = 2,
        .tracks_by_path = &.{
            "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3",
            "/Contents/Loopmasters/UnknownAlbum/Demo Track 2.mp3",
        },
        .artists = &.{.{ .name = "Loopmasters", .id = 1 }},
        .keys_canonical = &.{
            .{ .name = "Dmin", .id = 1 },
            .{ .name = "Amin", .id = 2 },
            .{ .name = "E", .id = 3 },
            .{ .name = "D", .id = 4 },
            .{ .name = "Fmin", .id = 5 },
        },
        .labels = &.{.{ .name = "Loopmasters", .id = 1 }},
    },
    .{ .name = "empty" },
};

/// One expected `(name, id)` entry of a string-keyed dedup map.
const NameId = struct {
    name: []const u8,
    id: u32,
};

/// Asserts `entries` is exactly the map's contents.
fn expectStringMapEntries(
    map: *const std.StringHashMapUnmanaged(u32),
    entries: []const NameId,
) !void {
    try testing.expectEqual(entries.len, map.count());
    for (entries) |entry| {
        try testing.expectEqual(entry.id, map.get(entry.name) orelse {
            std.debug.print("missing key: {s}\n", .{entry.name});
            return error.TestUnexpectedResult;
        });
    }
}

test "writer state scans each fixture" {
    const alloc = testing.allocator;
    const io = testing.io;
    for (scan_expectations) |want| {
        const path = try std.fmt.allocPrint(alloc, "testdata/complete_export/{s}", .{want.name});
        defer alloc.free(path);
        var ex = try device_export.DeviceExport.open(path, io, alloc);
        defer ex.deinit();
        const ws = try ex.writerState();

        try testing.expectEqual(want.next_track_id, ws.next_track_id.next);
        try testing.expectEqual(want.next_artist_id, ws.next_artist_id.next);
        try testing.expectEqual(want.next_album_id, ws.next_album_id.next);
        try testing.expectEqual(want.next_genre_id, ws.next_genre_id.next);
        try testing.expectEqual(want.next_key_id, ws.next_key_id.next);
        try testing.expectEqual(want.next_label_id, ws.next_label_id.next);
        try testing.expectEqual(want.next_artwork_id, ws.next_artwork_id.next);
        try testing.expectEqual(want.next_playlist_node_id, ws.next_playlist_node_id.next);

        try testing.expectEqual(want.track_ids, ws.track_ids.count());
        try testing.expectEqual(want.tracks_by_path.len, ws.tracks_by_path.count());
        for (want.tracks_by_path) |p| try testing.expect(ws.tracks_by_path.contains(p));
        try expectStringMapEntries(&ws.artists_by_name, want.artists);
        try expectStringMapEntries(&ws.genres_by_name, want.genres);
        try expectStringMapEntries(&ws.keys_by_canonical, want.keys_canonical);
        try expectStringMapEntries(&ws.labels_by_name, want.labels);
        try expectStringMapEntries(&ws.artwork_by_path, want.artwork);
        try testing.expectEqual(want.playlists, ws.playlist_nodes.count());
        try testing.expectEqual(want.playlists, ws.playlist_entry_counts.count());
    }
}

test "writer state pins with_anlz relationships" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();
    const ws = try ex.writerState();

    // Track ids resolved through their paths (row ids 2 and 1).
    try testing.expectEqual(@as(u32, 2), ws.tracks_by_path.get(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    ).?);
    try testing.expectEqual(@as(u32, 1), ws.tracks_by_path.get(
        "/Contents/Reboot/www.electronicfresh.com/03. Reboot - Assign The Source (Remaster).mp3",
    ).?);

    // The album row carries artist_id 0 (the null FK) even though artist
    // 1 exists — and its name genuinely starts with a space in the
    // fixture (short-ASCII body " www.electronicfresh.com", 24 bytes):
    // keyed exactly as the row says.
    try testing.expectEqual(@as(u32, 1), ws.albums_by_artist_and_name.get(.{
        .artist_id = 0,
        .name = " www.electronicfresh.com",
    }).?);
    try testing.expectEqual(@as(u32, 1), ws.albums_by_artist_and_name.count());

    // One top-level leaf playlist holding entries up to index 2
    // (max entry_index + 1 = 3, not the row count).
    try testing.expectEqual(false, ws.playlist_nodes.get(1).?);
    try testing.expectEqual(@as(u32, 3), ws.playlist_entry_counts.get(1).?.next);
}

test "writer state ignores dead-row remnants" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ex = try device_export.DeviceExport.open("testdata/complete_export/demo_tracks", io, alloc);
    defer ex.deinit();
    const ws = try ex.writerState();

    // The demo_tracks page heaps carry four deleted-track paths
    // (`/Contents/UnknownArtist/UnknownAlbum/*.wav`) in dead space —
    // the scan walks present rows only, so they must not resolve.
    try testing.expect(ws.tracks_by_path.get(
        "/Contents/UnknownArtist/UnknownAlbum/NOISE.wav",
    ) == null);
    try testing.expectEqual(@as(usize, 2), ws.tracks_by_path.count());
}

test "writer state is lazy, cached, and pre-built by create" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();
    try testing.expect(ex.writer_state == null);
    const ws = try ex.writerState();
    try testing.expect(ws == try ex.writerState());
    try testing.expect(ex.pdb_state == .loaded);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    var created = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer created.deinit();
    const fresh = try created.writerState();
    // Fresh counters — id 0 is the null FK — and empty maps; the default
    // color/column/menu rows live in tables the writer doesn't track.
    try testing.expectEqual(@as(u32, 1), fresh.next_track_id.next);
    try testing.expectEqual(@as(u32, 1), fresh.next_artist_id.next);
    try testing.expectEqual(@as(u32, 1), fresh.next_tag_id.next);
    try testing.expectEqual(@as(u32, 0), fresh.next_category_position.next);
    try testing.expectEqual(@as(u32, 0), fresh.next_tag_row_index.next);
    try testing.expectEqual(@as(usize, 0), fresh.track_ids.count());
    try testing.expectEqual(@as(usize, 0), fresh.tracks_by_path.count());
}

test "writer state scans num_rows at scale" {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(alloc, "pdb/num_rows/export.pdb", .limited(1 << 22));
    defer alloc.free(input);
    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();

    var state = try device_export.scanWriterState(alloc, &db);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 3886), state.track_ids.count());
    try testing.expect(state.next_track_id.next > 3886);
}

test "IdMint rejects an exhausted id space" {
    var m = device_export.IdMint(u32){ .next = 5 };
    try testing.expectEqual(@as(u32, 5), try m.mint());
    try testing.expectEqual(@as(u32, 6), try m.mint());

    // The boundary id is never minted...
    m = .{ .next = std.math.maxInt(u32) };
    try testing.expectError(error.IdSpaceExhausted, m.mint());
    // ...nor accepted from an untrusted database.
    try testing.expectError(error.IdSpaceExhausted, m.raisePast(std.math.maxInt(u32)));
    // One below it leaves the space exhausted without overflowing.
    m = .{ .next = 0 };
    try m.raisePast(std.math.maxInt(u32) - 1);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), m.next);
    try testing.expectError(error.IdSpaceExhausted, m.mint());
}

test "writer state scan rejects a max track id" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
    defer db.deinit();
    try pdb.insertDefaultColors(&db);
    try pdb.insertDefaultColumns(&db);
    try pdb.insertDefaultMenus(&db);
    const a = db.arena.allocator();
    const track = try a.create(pdb.Track);
    track.* = .{
        .id = std.math.maxInt(u32),
        .offsets = .{ .inner = .{
            .file_path = try pdb.DeviceSQLString.fromUtf8(a, "/x.mp3"),
        } },
    };
    try pdb.padTrackCommentToMinimum(track, a);
    var row = pdb.Row{ .track = track };
    _ = try db.addRow(&row);

    // Saturation would leave the counter at maxInt and collide every
    // later mint with the hostile row (or panic on the bump).
    try testing.expectError(
        error.IdSpaceExhausted,
        device_export.scanWriterState(alloc, &db),
    );
}

test "writer state scan rejects a max playlist entry index" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
    defer db.deinit();
    const a = db.arena.allocator();
    const entry = try a.create(pdb.PlaylistEntry);
    entry.* = .{
        .entry_index = std.math.maxInt(u32),
        .track_id = 1,
        .playlist_id = 1,
    };
    var row = pdb.Row{ .playlist_entry = entry };
    _ = try db.addRow(&row);

    try testing.expectError(
        error.IdSpaceExhausted,
        device_export.scanWriterState(alloc, &db),
    );
}

/// Builds a boxed TagOrCategory row on `a`, for the ext-scan tests.
fn testTagRow(
    a: std.mem.Allocator,
    parent_id: u32,
    position: u32,
    id: u32,
    is_category: bool,
    row_index: u32,
    name: []const u8,
) !pdb.Row {
    const tag = try a.create(pdb.TagOrCategory);
    tag.* = .{
        .parent_id = parent_id,
        .position = position,
        .id = id,
        .raw_is_category = if (is_category) 1 << 24 else 0,
        .index_shift = @intCast(row_index * 0x20),
        .offsets = .{ .inner = .{ .name = try pdb.DeviceSQLString.fromUtf8(a, name) } },
    };
    return pdb.Row{ .tag = tag };
}

test "ext tag scan recovers a built ext database" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .ext, &[_]pdb.PageType{
        @enumFromInt(@intFromEnum(pdb.ExtPageType.tag)),
        @enumFromInt(@intFromEnum(pdb.ExtPageType.track_tag)),
    });
    defer db.deinit();

    const a = db.arena.allocator();
    var category = try testTagRow(a, 0, 0, 7, true, 0, "My Tags");
    _ = try db.addRow(&category);
    var techno = try testTagRow(a, 7, 0, 9, false, 1, "Techno");
    _ = try db.addRow(&techno);
    var dub = try testTagRow(a, 7, 1, 12, false, 2, "Dub");
    _ = try db.addRow(&dub);
    // A duplicate label under the same category: the scan keeps the
    // first row's id (rekordcrate's `or_insert`).
    var techno_dup = try testTagRow(a, 7, 2, 20, false, 3, "Techno");
    _ = try db.addRow(&techno_dup);

    var state = device_export.WriterState{ .arena = std.heap.ArenaAllocator.init(alloc) };
    defer state.deinit();
    try device_export.scanExtTags(state.arena.allocator(), &db, &state);

    try testing.expectEqual(@as(u32, 21), state.next_tag_id.next);
    try testing.expectEqual(@as(u32, 4), state.next_tag_row_index.next);
    try testing.expect(state.tag_categories.contains(7));
    try testing.expectEqual(@as(u32, 1), state.next_category_position.next);
    try testing.expectEqual(@as(u32, 2), state.tags_by_key.count());
    try testing.expectEqual(@as(u32, 9), state.tags_by_key.get(.{
        .category_id = 7,
        .label = "Techno",
    }).?);
    try testing.expectEqual(@as(u32, 12), state.tags_by_key.get(.{
        .category_id = 7,
        .label = "Dub",
    }).?);
    try testing.expectEqual(@as(u32, 3), state.tag_leaf_counts.get(7).?.next);
}

test "ext tag scan rejects a max tag id" {
    const alloc = testing.allocator;
    var db = try pdb.Database.create(alloc, .ext, &[_]pdb.PageType{
        @enumFromInt(@intFromEnum(pdb.ExtPageType.tag)),
        @enumFromInt(@intFromEnum(pdb.ExtPageType.track_tag)),
    });
    defer db.deinit();
    const a = db.arena.allocator();
    var hostile = try testTagRow(a, 0, 0, std.math.maxInt(u32), true, 0, "X");
    _ = try db.addRow(&hostile);

    var state = device_export.WriterState{ .arena = std.heap.ArenaAllocator.init(alloc) };
    defer state.deinit();
    try testing.expectError(
        error.IdSpaceExhausted,
        device_export.scanExtTags(state.arena.allocator(), &db, &state),
    );
}

test "ext tag scan recovers the with_anlz fixture" {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/rekordbox/exportExt.pdb",
        .limited(1 << 20),
    );
    defer alloc.free(input);
    var db = try pdb.Database.parse(alloc, input, .ext);
    defer db.deinit();

    var state = device_export.WriterState{ .arena = std.heap.ArenaAllocator.init(alloc) };
    defer state.deinit();
    try device_export.scanExtTags(state.arena.allocator(), &db, &state);

    // Hand-checked against the fixture (2026-08-23): 4 categories —
    // Genre, Components, Situation, Untitled Column (ids 1-4, positions
    // 0-3) — holding 7/8/8/1 leaves; 28 Tag rows stepping index_shift by
    // 0x20; leaf ids are random-looking u32s (the max is Acid House's
    // 4275955888), mirroring the OL db's 28 myTag rows.
    try testing.expectEqual(@as(u32, 4275955889), state.next_tag_id.next);
    try testing.expectEqual(@as(u32, 28), state.next_tag_row_index.next);
    try testing.expectEqual(@as(u32, 4), state.next_category_position.next);
    try testing.expectEqual(@as(usize, 4), state.tag_categories.count());
    try testing.expectEqual(@as(usize, 28), state.tag_ids.count());
    for ([_]u32{ 1, 2, 3, 4 }) |id| try testing.expect(state.tag_categories.contains(id));
    try testing.expectEqual(@as(u32, 4275955888), state.tags_by_key.get(.{
        .category_id = 1,
        .label = "Acid House",
    }).?);
    try testing.expectEqual(@as(u32, 3139558292), state.tags_by_key.get(.{
        .category_id = 1,
        .label = "Techno",
    }).?);
    try testing.expectEqual(@as(u32, 3662875339), state.tags_by_key.get(.{
        .category_id = 4,
        .label = "My Comment",
    }).?);
    try testing.expectEqual(@as(usize, 24), state.tags_by_key.count());
    try testing.expectEqual(@as(u32, 7), state.tag_leaf_counts.get(1).?.next);
    try testing.expectEqual(@as(u32, 8), state.tag_leaf_counts.get(2).?.next);
    try testing.expectEqual(@as(u32, 8), state.tag_leaf_counts.get(3).?.next);
    try testing.expectEqual(@as(u32, 1), state.tag_leaf_counts.get(4).?.next);
}

// --- writer: add_track ------------------------------------------------------------

/// Copies a fixture's `export.pdb` into a temp-dir export root — enough
/// of the export for `open` + `addTrack` + `save` sessions.
fn copyFixturePdb(
    tmp: *testing.TmpDir,
    io: std.Io,
    alloc: std.mem.Allocator,
    fixture: []const u8,
) !void {
    try tmp.dir.createDirPath(io, "PIONEER/rekordbox");
    const src = try std.fmt.allocPrint(
        alloc,
        "complete_export/{s}/PIONEER/rekordbox/export.pdb",
        .{fixture},
    );
    defer alloc.free(src);
    const image = try testutil.readFixture(alloc, src, .limited(1 << 22));
    defer alloc.free(image);
    try tmp.dir.writeFile(io, .{
        .sub_path = "PIONEER/rekordbox/export.pdb",
        .data = image,
    });
}

/// Counts Artist rows whose name decodes to exactly `name`.
fn countArtistsNamed(db: *const pdb.Database, name: []const u8) !usize {
    var count: usize = 0;
    var it = try db.rowsOf(pdb.Artist);
    while (try it.next()) |artist| {
        const got = try artist.offsets.inner.name.utf8(testing.allocator);
        defer testing.allocator.free(got);
        if (std.mem.eql(u8, got, name)) count += 1;
    }
    return count;
}

test "add track dedups on file path" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const song = device_export.TrackInput{
        .title = "song",
        .filename = "song.mp3",
        .file_path = "/Contents/song.mp3",
    };

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const first = try ex.addTrack(song);
    const second = try ex.addTrack(song);
    try testing.expectEqual(first.id, second.id);
    try testing.expect(first.is_new);
    try testing.expect(!second.is_new);
    try ex.save();

    // Across save/open: the scan reads the path back, so re-adding still
    // dedups instead of inserting a second row.
    var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer reopened.deinit();
    const third = try reopened.addTrack(song);
    try testing.expectEqual(first.id, third.id);
    try testing.expect(!third.is_new);
    try reopened.save();

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    try testing.expectEqual(@as(usize, 1), try countTableRows(&db, .tracks));
}

test "add track auto-pads under the minimum row size" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const outcome = try ex.addTrack(.{
        .title = "tiny",
        .file_path = "/Contents/tiny.mp3",
    });
    try testing.expect(outcome.is_new);
    try ex.save();

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    var it = try db.rowsOf(pdb.Track);
    const track = (try it.next()).?;
    const comment = try track.offsets.inner.comment.utf8(alloc);
    defer alloc.free(comment);
    try testing.expect(comment.len > 0);
    for (comment) |c| try testing.expect(c == ' ');
}

test "a string that fails to encode leaves the export untouched" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();

    // One byte over the long-form body cap: encoding fails before any id
    // is taken or row inserted.
    const long_title = try alloc.alloc(u8, 32_768);
    defer alloc.free(long_title);
    @memset(long_title, 'a');
    try testing.expectError(
        error.TooLong,
        ex.addTrack(.{ .title = long_title, .artist = "X", .file_path = "/Contents/x.mp3" }),
    );
    try testing.expectEqual(@as(u32, 1), (try ex.writerState()).next_track_id.next);

    // The export still accepts the next, valid track — with id 1 — and a
    // save then proves the failed one left no rows behind.
    const outcome = try ex.addTrack(.{ .title = "ok", .file_path = "/Contents/ok.mp3" });
    try testing.expect(outcome.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(1)), outcome.id);
    try ex.save();

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    try testing.expectEqual(@as(usize, 1), try countTableRows(&db, .tracks));
    try testing.expectEqual(@as(usize, 0), try countTableRows(&db, .artists));
}

test "add track stores the caller artwork path verbatim" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    const caller_path = "/PIONEER/Artwork/00007/a137.jpg";
    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "song",
        .filename = "song.mp3",
        .file_path = "/Contents/song.mp3",
        .artwork_device_path = caller_path,
    });
    // A second track sharing the artwork dedups onto the same row.
    _ = try ex.addTrack(.{
        .title = "song2",
        .filename = "song2.mp3",
        .file_path = "/Contents/song2.mp3",
        .artwork_device_path = caller_path,
    });
    try ex.save();

    // No image files are written — the caller owns them.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "PIONEER/Artwork", .{}));

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    try testing.expectEqual(@as(usize, 1), try countTableRows(&db, .artwork));
    var it = try db.rowsOf(pdb.Artwork);
    const artwork = (try it.next()).?;
    const path = try artwork.path.utf8(alloc);
    defer alloc.free(path);
    try testing.expectEqualStrings(caller_path, path);

    var tracks = try db.rowsOf(pdb.Track);
    var artwork_ids: [2]u32 = undefined;
    var i: usize = 0;
    while (try tracks.next()) |track| : (i += 1) artwork_ids[i] = track.artwork_id;
    try testing.expect(artwork_ids[0] != 0);
    try testing.expectEqual(artwork_ids[0], artwork_ids[1]);
    try testing.expectEqual(artwork.id, artwork_ids[0]);
}

test "open then add does not duplicate a named row" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Created export: create → add → save, reopen → add again — the
    // artist must be deduped through the save/reopen round trip.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        defer alloc.free(tmp_path);

        const song = device_export.TrackInput{
            .title = "song",
            .artist = "Dup Artist",
            .album = "Dup Album",
            .genre = "Dup Genre",
            .filename = "song.mp3",
            .file_path = "/Contents/song.mp3",
        };
        var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
        defer ex.deinit();
        _ = try ex.addTrack(song);
        try ex.save();

        var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
        defer reopened.deinit();
        _ = try reopened.addTrack(song);
        try reopened.save();

        var db = try parseExportPdb(alloc, io, tmp_path);
        defer db.deinit();
        try testing.expectEqual(
            @as(usize, 1),
            try countArtistsNamed(&db, "Dup Artist"),
        );
    }

    // Opened real exports: an artist the fixture already carries is
    // reused, never duplicated.
    const named = [_]struct { name: []const u8, artist: []const u8, tracks: usize }{
        .{ .name = "demo_tracks", .artist = "Loopmasters", .tracks = 2 },
        .{ .name = "with_anlz", .artist = "Reboot", .tracks = 2 },
    };
    for (named) |fixture| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        defer alloc.free(tmp_path);
        try copyFixturePdb(&tmp, io, alloc, fixture.name);

        var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
        defer ex.deinit();
        const outcome = try ex.addTrack(.{
            .title = "new song",
            .artist = fixture.artist,
            .filename = "new song.mp3",
            .file_path = "/Contents/new song.mp3",
        });
        try testing.expect(outcome.is_new);
        try ex.save();

        var db = try parseExportPdb(alloc, io, tmp_path);
        defer db.deinit();
        try testing.expectEqual(@as(usize, 1), try countArtistsNamed(&db, fixture.artist));
        try testing.expectEqual(fixture.tracks + 1, try countTableRows(&db, .tracks));

        // The new track points at the pre-existing artist row.
        var it = try db.rowsOf(pdb.Track);
        while (try it.next()) |track| {
            if (track.id == outcome.id.int()) {
                try testing.expectEqual(@as(u32, 1), track.artist_id);
            }
        }
    }
}

test "add track with analysis writes anlz files" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // Minimal analysis vector: one beat, one mono preview column, a
    // one-column color preview — enough for `.DAT` + `.EXT`, not `.2EX`.
    // The `Analysis` slices are mutable, so the columns live in vars.
    var beats = [1]anlz.Beat{.{ .beat_number = 1, .tempo = 12_800, .time = 0 }};
    var preview_mono = [1]anlz.WaveformPreviewColumn{.{ .height = 1, .whiteness = 0 }};
    var color_preview = [1]anlz.WaveformColorPreviewColumn{.{
        .energy_low_wide = 10,
        .energy_low = 20,
        .energy_mid = 30,
        .energy_high = 40,
    }};
    const input = anlz.Analysis{
        .beats = &beats,
        .cue_list_type = .memory_cues,
        .preview_mono = &preview_mono,
        .color_preview = &color_preview,
    };

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const outcome = try ex.addTrack(.{
        .title = "test",
        .file_path = "/Contents/test.mp3",
        .analysis = &input,
    });
    try testing.expect(outcome.is_new);
    try ex.save();

    // The analysis directory is keyed by the audio path exactly the way
    // players recompute it (`pathHash`).
    const audio_path = "/Contents/test.mp3";
    const h = try device_export.pathHash(audio_path);
    const dat_sub = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.DAT",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(dat_sub);
    const dat = try tmp.dir.readFileAlloc(io, dat_sub, alloc, .limited(1 << 24));
    defer alloc.free(dat);
    var dat_parsed = try anlz.Anlz.parse(alloc, dat);
    defer dat_parsed.deinit();
    try testing.expect(dat_parsed.findSection(.path) != null);
    try testing.expect(dat_parsed.findSection(.beat_grid) != null);
    try testing.expect(dat_parsed.findSection(.waveform_preview) != null);
    try testing.expect(dat_parsed.findSection(.cue_list) == null);

    const ext_sub = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.EXT",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(ext_sub);
    const ext = try tmp.dir.readFileAlloc(io, ext_sub, alloc, .limited(1 << 24));
    defer alloc.free(ext);
    var ext_parsed = try anlz.Anlz.parse(alloc, ext);
    defer ext_parsed.deinit();
    try testing.expect(ext_parsed.findSection(.path) != null);
    try testing.expect(ext_parsed.findSection(.waveform_color_preview) != null);

    // No 3-band data, no `.2EX`.
    const two_ex_sub = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.2EX",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(two_ex_sub);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, two_ex_sub, .{}));

    // The row stores the device path of its `.DAT`, derived from the
    // audio path.
    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    var it = try db.rowsOf(pdb.Track);
    const track = (try it.next()).?;
    const analyze_path = try track.offsets.inner.analyze_path.utf8(alloc);
    defer alloc.free(analyze_path);
    const want = try device_export.anlzDevicePath(alloc, audio_path);
    defer alloc.free(want);
    try testing.expectEqualStrings(want, analyze_path);
}

test "2EX sections follow the writer's order and carry the scales" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // 3-band analysis vector: one preview and one detail column plus the
    // auto-gain scales — enough for a `.2EX` (the click probes' clamped
    // scales).
    var preview_mono = [1]anlz.WaveformPreviewColumn{.{ .height = 1, .whiteness = 0 }};
    var band3_preview = [1]anlz.Waveform3BandColumn{.{ .energy_low = 1 }};
    var band3_detail = [1]anlz.Waveform3BandColumn{.{ .energy_high = 2 }};
    const input = anlz.Analysis{
        .cue_list_type = .memory_cues,
        .preview_mono = &preview_mono,
        .band3_preview = &band3_preview,
        .band3_detail = &band3_detail,
        .band3_scales = .{ 300, 300, 470 },
    };

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "test",
        .file_path = "/Contents/test.mp3",
        .analysis = &input,
    });
    try ex.save();

    const h = try device_export.pathHash("/Contents/test.mp3");
    const two_ex_sub = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.2EX",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(two_ex_sub);
    const two_ex = try tmp.dir.readFileAlloc(io, two_ex_sub, alloc, .limited(1 << 24));
    defer alloc.free(two_ex);
    var parsed = try anlz.Anlz.parse(alloc, two_ex);
    defer parsed.deinit();

    // The 6.8.6 writer's order: path, detail (PWV7), preview (PWV6),
    // scales (PWVC) last.
    const kinds = [_]anlz.Kind{ .path, .waveform_3band_detail, .waveform_3band_preview, .waveform_3band_scales };
    try testing.expectEqual(@as(usize, 4), parsed.sections.len);
    for (parsed.sections, kinds) |*section, want| {
        const content_kind = anlz.sectionKind(section);
        try testing.expectEqual(want, content_kind);
    }
    try testing.expectEqual(
        [3]u16{ 300, 300, 470 },
        parsed.findSection(.waveform_3band_scales).?.scales,
    );
}

// --- writer: playlists + tags --------------------------------------------------------

test "playlist methods reject unknown foreign keys" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();

    // The root (0) is always a valid parent; a folder groups a playlist.
    // Fresh counters start at 1: id 0 is the null foreign key.
    const folder = try ex.createPlaylistFolder("Folder", .root);
    const playlist = try ex.createPlaylist("Playlist", folder);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(1)), folder);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(2)), playlist);

    // Unknown parent: 999 was never created.
    try testing.expectError(error.UnknownForeignKey, ex.createPlaylist("Orphan", @enumFromInt(999)));

    // A valid track so the membership check has something to find.
    const track = (try ex.addTrack(.{
        .title = "song",
        .filename = "song.mp3",
        .file_path = "/Contents/song.mp3",
    })).id;

    // Unknown playlist id, unknown track id.
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(@enumFromInt(999), track));
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(playlist, @enumFromInt(999)));

    // The happy path still works.
    try ex.addTrackToPlaylist(playlist, track);
}

test "playlist tree enforces folder vs playlist roles" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const folder = try ex.createPlaylistFolder("Folder", .root);
    const playlist = try ex.createPlaylist("Playlist", folder);

    // The playlist exists, but it's a leaf, not a folder.
    try testing.expectError(error.UnknownForeignKey, ex.createPlaylist("Child", playlist));

    // The folder exists, but tracks go into playlists only.
    const track = (try ex.addTrack(.{
        .title = "song",
        .filename = "song.mp3",
        .file_path = "/Contents/song.mp3",
    })).id;
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(folder, track));

    // End to end: the saved export reads back as a folder nesting the
    // playlist, so `node_is_folder` was written the way the reader (and
    // players) interpret it.
    try ex.save();
    var check = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer check.deinit();
    var playlists = try check.getPlaylists();
    defer playlists.deinit();
    try testing.expectEqual(@as(usize, 1), playlists.roots.len);
    const saved_folder = &playlists.roots[0].folder;
    try testing.expectEqual(folder, saved_folder.id);
    try testing.expectEqualStrings("Folder", saved_folder.name);
    try testing.expectEqual(@as(usize, 1), saved_folder.children.items.len);
    const saved_playlist = &saved_folder.children.items[0].playlist;
    try testing.expectEqual(playlist, saved_playlist.id);
    try testing.expectEqualStrings("Playlist", saved_playlist.name);
}

test "add track to playlist auto-indexes" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const playlist = try ex.createPlaylist("P", .root);
    const t0 = (try ex.addTrack(.{
        .title = "song0",
        .filename = "song0.mp3",
        .file_path = "/Contents/song0.mp3",
    })).id;
    const t1 = (try ex.addTrack(.{
        .title = "song1",
        .filename = "song1.mp3",
        .file_path = "/Contents/song1.mp3",
    })).id;
    const t2 = (try ex.addTrack(.{
        .title = "song2",
        .filename = "song2.mp3",
        .file_path = "/Contents/song2.mp3",
    })).id;
    try ex.addTrackToPlaylist(playlist, t0);
    try ex.addTrackToPlaylist(playlist, t1);
    try ex.addTrackToPlaylist(playlist, t2);
    try ex.save();

    // After a save/open the entry counter is rebuilt from the rows, so
    // one more append lands at index 3.
    var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer reopened.deinit();
    const t3 = (try reopened.addTrack(.{
        .title = "song3",
        .filename = "song3.mp3",
        .file_path = "/Contents/song3.mp3",
    })).id;
    try reopened.addTrackToPlaylist(playlist, t3);
    try reopened.save();

    var db = try parseExportPdb(alloc, io, tmp_path);
    defer db.deinit();
    var indices: [4]u32 = undefined;
    var count: usize = 0;
    var it = try db.rowsOf(pdb.PlaylistEntry);
    while (try it.next()) |entry| {
        indices[count] = entry.entry_index;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 4), count);
    std.mem.sort(u32, &indices, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, &indices);
}

/// Reads and parses the `exportExt.pdb` a save wrote under `tmp`.
fn openSavedExtDb(
    tmp: *testing.TmpDir,
    io: std.Io,
    alloc: std.mem.Allocator,
) !pdb.Database {
    const image = try tmp.dir.readFileAlloc(
        io,
        "PIONEER/rekordbox/exportExt.pdb",
        alloc,
        .limited(1 << 26),
    );
    defer alloc.free(image);
    return pdb.Database.parse(alloc, image, .ext);
}

/// The Tag and TrackTag rows of a parsed ext database; the row pointers
/// stay owned by the database's arena.
const ExtRows = struct {
    tags: std.ArrayList(*pdb.TagOrCategory),
    track_tags: std.ArrayList(*pdb.TrackTag),

    fn deinit(rows: *ExtRows, alloc: std.mem.Allocator) void {
        rows.tags.deinit(alloc);
        rows.track_tags.deinit(alloc);
    }
};

fn collectExtRows(alloc: std.mem.Allocator, db: *const pdb.Database) !ExtRows {
    var rows = ExtRows{ .tags = .empty, .track_tags = .empty };
    errdefer rows.deinit(alloc);
    var tags = try db.rowsOf(pdb.TagOrCategory);
    while (try tags.next()) |tag| try rows.tags.append(alloc, tag);
    var track_tags = try db.rowsOf(pdb.TrackTag);
    while (try track_tags.next()) |tt| try rows.track_tags.append(alloc, tt);
    return rows;
}

test "tags are not written when unused" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "song",
        .filename = "song.mp3",
        .file_path = "/Contents/song.mp3",
    });
    try ex.save();

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "PIONEER/rekordbox/exportExt.pdb", .{}),
    );
}

test "add tags creates category leaves and junctions" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const id1 = (try ex.addTrack(.{
        .title = "a",
        .filename = "a.mp3",
        .file_path = "/Contents/a.mp3",
    })).id;
    const id2 = (try ex.addTrack(.{
        .title = "b",
        .filename = "b.mp3",
        .file_path = "/Contents/b.mp3",
    })).id;

    const cat = try ex.createTagCategory("My Tags");
    // The duplicate "Techno" within id1's call must collapse.
    try ex.addTagsToTrack(id1, cat, &.{ "Techno", "Dub", "Techno" });
    // The shared "Dub" must reuse one leaf row.
    try ex.addTagsToTrack(id2, cat, &.{ "Dub", "House" });
    try ex.save();

    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var rows = try collectExtRows(alloc, &ext);
    defer rows.deinit(alloc);

    var categories = std.ArrayList(*pdb.TagOrCategory).empty;
    defer categories.deinit(alloc);
    var leaves = std.ArrayList(*pdb.TagOrCategory).empty;
    defer leaves.deinit(alloc);
    for (rows.tags.items) |tag| {
        if (tag.raw_is_category != 0) {
            try categories.append(alloc, tag);
        } else {
            try leaves.append(alloc, tag);
        }
    }

    // One category. The encodings here fold rekordcrate's focused
    // `tag_row_encodings` self-check: categories are `0x01000000`, not 1,
    // and `index_shift` is `row_index * 0x20` (0 for the first row, 0x60
    // for the leaf at row 3).
    try testing.expectEqual(@as(usize, 1), categories.items.len);
    const category = categories.items[0];
    try testing.expectEqual(@as(u32, 1 << 24), category.raw_is_category);
    try testing.expectEqual(@as(u16, 0), category.index_shift);
    try testing.expectEqual(cat.int(), category.id);
    try testing.expectEqual(@as(u32, 0), category.parent_id);
    const cat_name = try category.offsets.inner.name.utf8(alloc);
    defer alloc.free(cat_name);
    try testing.expectEqualStrings("My Tags", cat_name);

    try testing.expectEqual(@as(usize, 3), leaves.items.len);
    for (leaves.items) |leaf| {
        try testing.expectEqual(@as(u32, 0), leaf.raw_is_category);
        try testing.expectEqual(cat.int(), leaf.parent_id);
    }
    for ([_][]const u8{ "Techno", "Dub", "House" }) |want| {
        var found = false;
        for (leaves.items) |leaf| {
            const name = try leaf.offsets.inner.name.utf8(alloc);
            defer alloc.free(name);
            if (std.mem.eql(u8, name, want)) found = true;
        }
        try testing.expect(found);
    }
    // The category is written first (row 0); the leaves follow, one 0x20
    // step per row in write order.
    std.mem.sort(*pdb.TagOrCategory, leaves.items, {}, struct {
        fn byIndexShift(_: void, a: *pdb.TagOrCategory, b: *pdb.TagOrCategory) bool {
            return a.index_shift < b.index_shift;
        }
    }.byIndexShift);
    var shifts: [3]u16 = undefined;
    for (leaves.items, 0..) |leaf, i| shifts[i] = leaf.index_shift;
    try testing.expectEqualSlices(u16, &.{ 0x20, 0x40, 0x60 }, &shifts);

    // id1: 2 tags, id2: 2 tags — four junctions, each with the constant.
    try testing.expectEqual(@as(usize, 4), rows.track_tags.items.len);
    for (rows.track_tags.items) |tt| try testing.expectEqual(@as(u32, 3), tt.unknown_const);
}

test "add tags rejects unknown track" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const cat = try ex.createTagCategory("My Tags");
    try testing.expectError(error.UnknownForeignKey, ex.addTagsToTrack(@enumFromInt(999), cat, &.{"x"}));
}

test "add tags rejects unknown category" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const id = (try ex.addTrack(.{
        .title = "a",
        .filename = "a.mp3",
        .file_path = "/Contents/a.mp3",
    })).id;

    try testing.expectError(error.UnknownForeignKey, ex.addTagsToTrack(id, @enumFromInt(999), &.{"x"}));
    // The track key is validated first (both keys bad reports the track
    // one; our errors carry no kind, so this pins only that it errors).
    try testing.expectError(error.UnknownForeignKey, ex.addTagsToTrack(@enumFromInt(888), @enumFromInt(999), &.{"x"}));
}

test "add tags ignores empty labels" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const id = (try ex.addTrack(.{
        .title = "a",
        .filename = "a.mp3",
        .file_path = "/Contents/a.mp3",
    })).id;

    const cat = try ex.createTagCategory("My Tags");
    try ex.addTagsToTrack(id, cat, &.{ "", "" });
    try ex.save();

    // The category write already created the tag database; the all-empty
    // call added no leaf and no junction to it.
    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var rows = try collectExtRows(alloc, &ext);
    defer rows.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), rows.tags.items.len);
    try testing.expectEqual(@as(usize, 0), rows.track_tags.items.len);
}

test "open preserves existing tags" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    {
        var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
        defer ex.deinit();
        const id = (try ex.addTrack(.{
            .title = "a",
            .filename = "a.mp3",
            .file_path = "/Contents/a.mp3",
        })).id;
        const cat = try ex.createTagCategory("My Tags");
        try ex.addTagsToTrack(id, cat, &.{ "Techno", "Dub" });
        try ex.save();
    }

    // Reopen and append a new leaf under the existing category (id 1,
    // remembered from the first session — the foreign-key check passing
    // at all is the assertion that the tag state was recovered) plus a
    // brand-new category. The leaf call runs first, so the opened tag
    // database must load before the category key is even checked.
    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    const id = (try ex.addTrack(.{
        .title = "a",
        .filename = "a.mp3",
        .file_path = "/Contents/a.mp3",
    })).id;
    try ex.addTagsToTrack(id, @enumFromInt(1), &.{"House"});
    const cat2 = try ex.createTagCategory("Mood");
    try ex.addTagsToTrack(id, cat2, &.{"Dark"});
    try ex.save();

    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var rows = try collectExtRows(alloc, &ext);
    defer rows.deinit(alloc);

    // Two categories, no duplicates.
    var categories = std.ArrayList(*pdb.TagOrCategory).empty;
    defer categories.deinit(alloc);
    var leaves = std.ArrayList(*pdb.TagOrCategory).empty;
    defer leaves.deinit(alloc);
    for (rows.tags.items) |tag| {
        if (tag.raw_is_category != 0) {
            try categories.append(alloc, tag);
        } else {
            try leaves.append(alloc, tag);
        }
    }
    try testing.expectEqual(@as(usize, 2), categories.items.len);
    for ([_][]const u8{ "My Tags", "Mood" }) |want| {
        var found = false;
        for (categories.items) |category| {
            const name = try category.offsets.inner.name.utf8(alloc);
            defer alloc.free(name);
            if (std.mem.eql(u8, name, want)) found = true;
        }
        try testing.expect(found);
    }

    // The original leaves survive unduplicated; the new ones landed.
    try testing.expectEqual(@as(usize, 4), leaves.items.len);
    for ([_][]const u8{ "Techno", "Dub", "House", "Dark" }) |want| {
        var count: usize = 0;
        for (leaves.items) |leaf| {
            const name = try leaf.offsets.inner.name.utf8(alloc);
            defer alloc.free(name);
            if (std.mem.eql(u8, name, want)) count += 1;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // 2 junctions from the first session + House + Dark.
    try testing.expectEqual(@as(usize, 4), rows.track_tags.items.len);

    // No two Tag rows share an id or an index_shift (a collision would
    // mean a counter wasn't recovered).
    var ids: [6]u32 = undefined;
    var shifts: [6]u16 = undefined;
    for (rows.tags.items, 0..) |tag, i| {
        ids[i] = tag.id;
        shifts[i] = tag.index_shift;
    }
    std.mem.sort(u32, &ids, {}, std.sort.asc(u32));
    for (ids[1..], 0..) |value, i| try testing.expect(value != ids[i]);
    std.mem.sort(u16, &shifts, {}, std.sort.asc(u16));
    for (shifts[1..], 0..) |value, i| try testing.expect(value != shifts[i]);
}

test "tag calls bridge a myTag tree with no exportExt.pdb" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // The with_anlz export without its exportExt.pdb: the same databases
    // and tracks, the 28-row tag tree only on the OL side.
    for ([_][]const u8{ "export.pdb", "exportLibrary.db" }) |file| {
        const sub = try std.fmt.allocPrint(alloc, "PIONEER/rekordbox/{s}", .{file});
        defer alloc.free(sub);
        try copyFixtureFile(&tmp, io, alloc, "with_anlz", sub);
    }

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();

    var rec = (try ex.trackByPath(with_anlz_tracks[0].audio_path)).?;
    defer rec.deinit();
    const track = rec.view.id;

    // Category 1 ("Genre") exists only in the OL tree; the FK check and
    // the "Acid House" leaf's dedup both resolve through the bridge —
    // no duplicate leaf, the junction carries the OL row's own id.
    try ex.addTagsToTrack(track, @enumFromInt(1), &.{"Acid House"});
    // A label the tree lacks mints past every OL id (the fixture's max
    // is Acid House's 4275955888) and mirrors back into the OL side.
    try ex.addTagsToTrack(track, @enumFromInt(1), &.{"Fresh"});
    try ex.save();

    // The tag database materialized the whole OL tree plus the new leaf.
    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var rows = try collectExtRows(alloc, &ext);
    defer rows.deinit(alloc);
    try testing.expectEqual(@as(usize, 29), rows.tags.items.len);
    try testing.expectEqual(@as(usize, 2), rows.track_tags.items.len);

    var acid_house_id: ?u32 = null;
    var fresh_id: ?u32 = null;
    for (rows.tags.items) |tag| {
        if (tag.raw_is_category != 0) continue;
        const name = try tag.offsets.inner.name.utf8(alloc);
        defer alloc.free(name);
        if (std.mem.eql(u8, name, "Acid House")) acid_house_id = tag.id;
        if (std.mem.eql(u8, name, "Fresh")) fresh_id = tag.id;
    }
    try testing.expectEqual(@as(u32, 4275955888), acid_house_id.?);
    try testing.expectEqual(@as(u32, 4275955889), fresh_id.?);
    for (rows.track_tags.items) |tt| {
        try testing.expectEqual(track.int(), tt.track_id);
        try testing.expect(tt.tag_id == acid_house_id.? or tt.tag_id == fresh_id.?);
    }

    // The OL side gained only the new leaf and the two junctions — the
    // 28 bridged rows are the ones already on disk.
    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 29), lib.my_tags.len);
    try testing.expectEqual(@as(usize, 2), lib.my_tag_contents.len);
    try testing.expectEqual(@as(?i64, 1), lib.byId(onelibrary.MyTag, 4275955889).?.myTag_id_parent);
}

test "a lockstep myTag tree bridges without duplicating" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    // The full with_anlz export: the ext pdb and the OL db carry the
    // same 28 tags under the same ids (the lockstep the bridge assumes).
    for ([_][]const u8{ "export.pdb", "exportLibrary.db", "exportExt.pdb" }) |file| {
        const sub = try std.fmt.allocPrint(alloc, "PIONEER/rekordbox/{s}", .{file});
        defer alloc.free(sub);
        try copyFixtureFile(&tmp, io, alloc, "with_anlz", sub);
    }

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();

    var rec = (try ex.trackByPath(with_anlz_tracks[0].audio_path)).?;
    defer rec.deinit();
    const track = rec.view.id;

    // "Techno" already lives under category 1 on both sides; the
    // junction must reuse its id (3139558292), not mint a leaf.
    try ex.addTagsToTrack(track, @enumFromInt(1), &.{"Techno"});
    try ex.save();

    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var rows = try collectExtRows(alloc, &ext);
    defer rows.deinit(alloc);
    try testing.expectEqual(@as(usize, 28), rows.tags.items.len);
    try testing.expectEqual(@as(usize, 1), rows.track_tags.items.len);
    try testing.expectEqual(track.int(), rows.track_tags.items[0].track_id);
    try testing.expectEqual(@as(u32, 3139558292), rows.track_tags.items[0].tag_id);

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 28), lib.my_tags.len);
    try testing.expectEqual(@as(usize, 1), lib.my_tag_contents.len);
    try testing.expectEqual(@as(i64, 3139558292), lib.my_tag_contents[0].myTag_id.?);
    try testing.expectEqual(@as(i64, track.int()), lib.my_tag_contents[0].content_id.?);
}

test "a relative root stays pinned to the working directory of first use" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const alloc = testing.allocator;
    const io = testing.io;

    // The test moves the process cwd; restore it afterwards — the suite's
    // other relative roots need it.
    var orig_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_len = std.os.linux.getcwd(&orig_buf, orig_buf.len);
    if (std.os.linux.errno(orig_len) != .SUCCESS) return error.Unexpected;
    // The raw syscall counts the trailing NUL it wrote.
    const orig_cwd = orig_buf[0 .. orig_len - 1];
    defer std.Io.Threaded.chdir(orig_cwd) catch {};

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    // Absolute: the test chdirs more than once, so relative targets would
    // resolve against whichever cwd is current.
    const a = try std.fmt.allocPrint(alloc, "{s}/.zig-cache/tmp/{s}/a", .{ orig_cwd, &tmp.sub_path });
    defer alloc.free(a);
    const b = try std.fmt.allocPrint(alloc, "{s}/.zig-cache/tmp/{s}/b", .{ orig_cwd, &tmp.sub_path });
    defer alloc.free(b);

    // `create` runs with cwd "a" and pins it; `save` runs after the cwd
    // moved and must still land the export under "a" — an unpinned
    // AT_FDCWD would resolve "root" under "b".
    try std.Io.Threaded.chdir(a);
    var ex = try device_export.DeviceExport.create("root", io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{ .title = "Pinned" });

    try std.Io.Threaded.chdir(b);
    try ex.save();

    try tmp.dir.access(io, "a/root/PIONEER/rekordbox/export.pdb", .{});
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "b/root/PIONEER/rekordbox/export.pdb", .{}),
    );

    // SQLite resolves paths against the process cwd (now b), not the
    // pinned directory — the OL db must still land under a.
    if (onelibrary.mode != .off) {
        try tmp.dir.access(io, "a/root/PIONEER/rekordbox/exportLibrary.db", .{});
        try testing.expectError(
            error.FileNotFound,
            tmp.dir.access(io, "b/root/PIONEER/rekordbox/exportLibrary.db", .{}),
        );
    }
}

test "playlist operations mirror into the OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const folder = try ex.createPlaylistFolder("Folder", .root);
    const inside = try ex.createPlaylist("Inside", folder);
    const outside = try ex.createPlaylist("Outside", .root);
    const t1 = (try ex.addTrack(.{
        .title = "one",
        .file_path = "/Contents/one.mp3",
    })).id;
    const t2 = (try ex.addTrack(.{
        .title = "two",
        .file_path = "/Contents/two.mp3",
    })).id;
    try ex.addTrackToPlaylist(inside, t1);
    try ex.addTrackToPlaylist(inside, t2);
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    // Three nodes, ids bridged from the pdb side, folder marked
    // attribute 1, per-parent dense sequenceNo from 0.
    try testing.expectEqual(@as(usize, 3), lib.playlists.len);
    const ol_folder = lib.byId(onelibrary.Playlist, folder.int()).?;
    try testing.expectEqualStrings("Folder", ol_folder.name.?);
    try testing.expectEqual(@as(i64, 1), ol_folder.attribute.?);
    try testing.expectEqual(@as(i64, 0), ol_folder.playlist_id_parent.?);
    try testing.expectEqual(@as(i64, 0), ol_folder.sequenceNo.?);
    const ol_inside = lib.byId(onelibrary.Playlist, inside.int()).?;
    try testing.expectEqual(@as(i64, 0), ol_inside.attribute.?);
    try testing.expectEqual(@as(i64, folder.int()), ol_inside.playlist_id_parent.?);
    try testing.expectEqual(@as(i64, 0), ol_inside.sequenceNo.?);
    const ol_outside = lib.byId(onelibrary.Playlist, outside.int()).?;
    try testing.expectEqual(@as(i64, 0), ol_outside.playlist_id_parent.?);
    try testing.expectEqual(@as(i64, 1), ol_outside.sequenceNo.?);

    // Memberships: the OL side's own dense 1-based sequenceNo, content
    // ids bridged.
    try testing.expectEqual(@as(usize, 2), lib.playlist_contents.len);
    const entries = lib.playlist_contents_by_playlist.get(inside.int()).?;
    try testing.expectEqual(@as(i64, t1.int()), lib.playlist_contents[entries[0]].content_id.?);
    try testing.expectEqual(@as(i64, 1), lib.playlist_contents[entries[0]].sequenceNo.?);
    try testing.expectEqual(@as(i64, t2.int()), lib.playlist_contents[entries[1]].content_id.?);
    try testing.expectEqual(@as(i64, 2), lib.playlist_contents[entries[1]].sequenceNo.?);
}

test "tag operations mirror into the OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const track = (try ex.addTrack(.{
        .title = "a",
        .file_path = "/Contents/a.mp3",
    })).id;
    const cat = try ex.createTagCategory("My Tags");
    try ex.addTagsToTrack(track, cat, &.{ "Techno", "Dub" });
    // The second call dedups Techno and adds one leaf.
    try ex.addTagsToTrack(track, cat, &.{ "Techno", "House" });
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    // Four myTag rows whose ids are exactly the ext tag ids (the id
    // bridge), the category attribute 1 with leaves 0 under it, and
    // sequenceNo reusing the ext positions.
    try testing.expectEqual(@as(usize, 4), lib.my_tags.len);
    const ol_cat = lib.byId(onelibrary.MyTag, cat.int()).?;
    try testing.expectEqualStrings("My Tags", ol_cat.name.?);
    try testing.expectEqual(@as(i64, 1), ol_cat.attribute.?);
    try testing.expectEqual(@as(i64, 0), ol_cat.myTag_id_parent.?);
    try testing.expectEqual(@as(i64, 0), ol_cat.sequenceNo.?);

    var ext = try openSavedExtDb(&tmp, io, alloc);
    defer ext.deinit();
    var ext_rows = try collectExtRows(alloc, &ext);
    defer ext_rows.deinit(alloc);
    try testing.expectEqual(lib.my_tags.len, ext_rows.tags.items.len);
    for (ext_rows.tags.items) |tag| {
        const mirrored = lib.byId(onelibrary.MyTag, tag.id) orelse {
            std.debug.print("ext tag {d} has no mirrored myTag row\n", .{tag.id});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(i64, tag.position), mirrored.sequenceNo.?);
        try testing.expectEqual(
            @as(i64, if (tag.raw_is_category != 0) 1 else 0),
            mirrored.attribute.?,
        );
        try testing.expectEqual(@as(i64, tag.parent_id), mirrored.myTag_id_parent.?);
    }

    // Junctions are not deduplicated across calls: the second call's
    // "Techno" stacks a second junction for the same leaf — 4 total.
    try testing.expectEqual(@as(usize, 4), lib.my_tag_contents.len);
    for (lib.my_tag_contents) |junction| {
        try testing.expectEqual(@as(i64, track.int()), junction.content_id.?);
        try testing.expect(lib.byId(onelibrary.MyTag, junction.myTag_id.?) != null);
    }
}

test "playlist and tag mirroring continues an existing OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    try copyFixtureFile(&tmp, io, alloc, "with_anlz", "PIONEER/rekordbox/export.pdb");
    try copyFixtureFile(&tmp, io, alloc, "with_anlz", "PIONEER/rekordbox/exportExt.pdb");
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    const track = (try ex.addTrack(.{
        .title = "new song",
        .artist = "Reboot",
        .file_path = "/Contents/Reboot/03. new song.mp3",
        .filename = "03. new song.mp3",
    })).id;
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(3)), track);
    // The fixture's playlist 1 ("aaaaa") gains the track; its OL
    // sequenceNo continues past the existing 1 and 2.
    try ex.addTrackToPlaylist(@enumFromInt(1), track);
    // "Techno" already exists under category 1 both sides: the junction
    // mirrors, no myTag row is added.
    try ex.addTagsToTrack(track, @enumFromInt(1), &.{"Techno"});
    try ex.save();

    const db_path = try tmpOlDbPath(&tmp, alloc);
    defer alloc.free(db_path);
    var db = try onelibrary.Db.open(io, db_path);
    defer db.close();
    var lib = try onelibrary.Library.load(alloc, db);
    defer lib.deinit();

    // The existing label resolves on both sides: 28 myTag rows stay 28.
    try testing.expectEqual(@as(usize, 28), lib.my_tags.len);
    const entries = lib.playlist_contents_by_playlist.get(1).?;
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(@as(i64, 3), lib.playlist_contents[entries[2]].content_id.?);
    try testing.expectEqual(@as(i64, 3), lib.playlist_contents[entries[2]].sequenceNo.?);

    try testing.expectEqual(@as(usize, 1), lib.my_tag_contents.len);
    const junction = lib.my_tag_contents[0];
    try testing.expectEqual(@as(i64, 3), junction.content_id.?);
    try testing.expectEqual(@as(i64, 3139558292), junction.myTag_id.?);
}

// --- unified track model ----------------------------------------------------------

/// Copies the whole `with_anlz` fixture export — databases, settings,
/// artwork, analysis tree — into a temp-dir export root, so tests can
/// mutate and save.
fn copyWithAnlzFixture(
    tmp: *testing.TmpDir,
    io: std.Io,
    alloc: std.mem.Allocator,
) !void {
    var src = try std.Io.Dir.cwd().openDir(
        io,
        "testdata/complete_export/with_anlz",
        .{ .iterate = true },
    );
    defer src.close(io);
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const image = try src.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 26));
        defer alloc.free(image);
        try tmp.dir.createDirPath(io, std.fs.path.dirname(entry.path) orelse ".");
        try tmp.dir.writeFile(io, .{ .sub_path = entry.path, .data = image });
    }
}

/// A temp-dir export root, as a device-root path the writer resolves
/// against the working directory.
fn tmpExportPath(tmp: *testing.TmpDir, alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "track views join both databases by path" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();

    var it = try ex.tracks();
    defer it.deinit();
    var count: usize = 0;
    var saw_bako = false;
    while (try it.next()) |track| {
        count += 1;
        try testing.expect(track.source == .pdb_and_ol);
        if (std.mem.endsWith(u8, track.file_path, "01. Reboot - Bako (Original Mix).mp3")) {
            saw_bako = true;
            try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), track.id);
            try testing.expectEqualStrings("Bako (Original Mix)", track.title);
            // Foreign keys resolved to names, not ids.
            try testing.expectEqualStrings("Reboot", track.artist);
            try testing.expectEqualStrings(" www.electronicfresh.com", track.album);
            try testing.expectEqualStrings("Tech House", track.genre);
            try testing.expectEqualStrings("Cecille", track.label);
            try testing.expectEqual(@as(usize, 0), track.key.len);
            // Centi-BPM decoded; the fixture row carries 12_900.
            try testing.expectEqual(@as(f32, 129.0), track.tempo);
            try testing.expectEqual(@as(u8, 4), track.rating);
            try testing.expect(track.has_analysis);
            // The OL half: fields the pdb lacks.
            try testing.expectEqualStrings("2026-07-16", track.date_created.?);
            try testing.expect(track.kuvo_delivery_on);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(saw_bako);
}

test "track views are pdb_only without an OL db" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/demo_tracks", io, alloc);
    defer ex.deinit();

    var it = try ex.tracks();
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |track| {
        count += 1;
        try testing.expect(track.source == .pdb_only);
        try testing.expect(track.date_created == null);
        try testing.expectEqualStrings("", track.subtitle);
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "trackByPath resolves and misses" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();

    var record = (try ex.trackByPath(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    )).?;
    defer record.deinit();
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), record.view.id);
    try testing.expectEqualStrings("Bako (Original Mix)", record.view.title);

    const missing = try ex.trackByPath("/Contents/nothing.mp3");
    try testing.expect(missing == null);
}

test "trackByTitle resolves and misses" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();

    var record = (try ex.trackByTitle("Bako (Original Mix)")).?;
    defer record.deinit();
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), record.view.id);
    try testing.expectEqualStrings("Bako (Original Mix)", record.view.title);

    const missing = try ex.trackByTitle("nothing by this name");
    try testing.expect(missing == null);
}

test "addTrack derives filename from the file path basename" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device_export.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{
        .title = "test",
        .file_path = "/Contents/Some artist/01 Some track.mp3",
    });
    try ex.save();

    var reopened = try device_export.DeviceExport.open(tmp_path, io, alloc);
    defer reopened.deinit();
    var record = (try reopened.trackByPath("/Contents/Some artist/01 Some track.mp3")).?;
    defer record.deinit();
    try testing.expectEqualStrings("01 Some track.mp3", record.view.filename);
}

// --- open-semantics classification -------------------------------------------------

test "open classifies a root with no PIONEER as NotAnExport" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    try testing.expectError(error.NotAnExport, device_export.DeviceExport.open(root, io, alloc));
}

test "a PIONEER regular file is NotAnExport" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "PIONEER", .data = "not a directory" });

    try testing.expectError(error.NotAnExport, device_export.DeviceExport.open(root, io, alloc));
}

test "a PIONEER-only root carries no database" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try tmp.dir.createDirPath(io, "PIONEER");

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    if (onelibrary.mode == .off) {
        // The OL fallback is compiled out; the pdb's absence is the
        // verdict.
        try testing.expectError(error.FileNotFound, ex.tracks());
        try testing.expectError(error.FileNotFound, ex.getPlaylists());
        try testing.expectError(error.FileNotFound, ex.createPlaylist("p", .root));
        // Nothing database-side can be pending, so a no-op save lands
        // exactly what it has: nothing.
        try ex.save();
    } else {
        try testing.expectError(error.DatabaseNotFound, ex.tracks());
        try testing.expectError(error.DatabaseNotFound, ex.getPlaylists());
        try testing.expectError(
            error.DatabaseNotFound,
            ex.getPlaylistTrackIds(alloc, @enumFromInt(1)),
        );
        try testing.expectError(error.DatabaseNotFound, ex.addTrack(.{ .title = "t" }));
        try testing.expectError(error.DatabaseNotFound, ex.updateTrack(@enumFromInt(1), .{ .title = "t" }));
        try testing.expectError(error.DatabaseNotFound, ex.removeTrack(@enumFromInt(1), .{}));
        try testing.expectError(error.DatabaseNotFound, ex.createPlaylist("p", .root));
        try testing.expectError(error.DatabaseNotFound, ex.addTrackToPlaylist(@enumFromInt(1), @enumFromInt(1)));
        // Same as above: a no-op save on a database-less root succeeds.
        try ex.save();
    }
}

test "OL-only roots read tracks through the OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    // PIONEER/rekordbox/exportLibrary.db and nothing else — no pdb.
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();

    const bako_path = with_anlz_tracks[0].audio_path;
    // The view derives its artwork path from the row's image id — the
    // `artworkSpec` a-variant — or carries none with no image.
    const bako_row = (try ex.openOneLibrary()).?.contentByPath(bako_path).?;
    var spec: ?device_export.ArtworkSpec = null;
    defer if (spec) |*s| s.deinit(alloc);
    if (bako_row.image_id) |id| spec = try device_export.artworkSpec(alloc, @intCast(id));

    var it = try ex.tracks();
    defer it.deinit();
    var count: usize = 0;
    var saw_bako = false;
    while (try it.next()) |track| {
        count += 1;
        // Built from the OL row outright, so the OL-only columns count.
        try testing.expect(track.source == .pdb_and_ol);
        if (std.mem.eql(u8, track.file_path, bako_path)) {
            saw_bako = true;
            // The content id doubles as the track id (lockstep).
            try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), track.id);
            try testing.expectEqualStrings("Bako (Original Mix)", track.title);
            // Foreign keys resolved to names through the library's rows.
            try testing.expectEqualStrings("Reboot", track.artist);
            try testing.expectEqualStrings(" www.electronicfresh.com", track.album);
            try testing.expectEqualStrings("Tech House", track.genre);
            try testing.expectEqualStrings("Cecille", track.label);
            try testing.expectEqual(@as(usize, 0), track.key.len);
            try testing.expectEqual(@as(f32, 129.0), track.tempo);
            try testing.expectEqual(@as(u16, 16), track.sample_depth);
            try testing.expectEqual(@as(u32, 44100), track.sample_rate);
            try testing.expectEqual(@as(u16, 0), track.play_count);
            try testing.expect(track.has_analysis);
            // The OL-only vocabulary reads back.
            try testing.expectEqualStrings("2026-07-16", track.date_created.?);
            try testing.expect(track.kuvo_delivery_on);
            // pdb-only vocabulary stays empty — the ignore-vice-versa
            // convention.
            try testing.expectEqual(@as(usize, 0), track.message.len);
            try testing.expectEqual(@as(usize, 0), track.mix_name.len);
            try testing.expectEqual(@as(usize, 0), track.analyze_date.len);
            try testing.expect(!track.publish_track_information);
            if (spec) |s| {
                try testing.expectEqualStrings(s.thumbnail_path, track.artwork_device_path);
            } else {
                try testing.expectEqual(@as(usize, 0), track.artwork_device_path.len);
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(saw_bako);

    var record = (try ex.trackByPath(bako_path)).?;
    defer record.deinit();
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), record.view.id);
    try testing.expectEqualStrings("Bako (Original Mix)", record.view.title);

    const missing = try ex.trackByPath("/Contents/nothing.mp3");
    try testing.expect(missing == null);
}

test "off builds read OL-only roots as FileNotFound" {
    if (onelibrary.mode != .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    // The fallback is not compiled in; the pdb's absence propagates.
    try testing.expectError(error.FileNotFound, ex.tracks());
    try testing.expectError(error.FileNotFound, ex.trackByPath("/Contents/a.mp3"));
    try testing.expectError(error.FileNotFound, ex.getPlaylists());
    try testing.expectError(error.FileNotFound, ex.createPlaylist("p", .root));
    // Nothing database-side can be pending in an off build on this
    // root; a no-op save succeeds.
    try ex.save();
    try testing.expectError(error.FileNotFound, ex.addTrack(.{ .title = "t" }));
    try testing.expectError(error.FileNotFound, ex.updateTrack(@enumFromInt(1), .{ .title = "t" }));
    try testing.expectError(error.FileNotFound, ex.removeTrack(@enumFromInt(1), .{}));
}

test "OL-only roots add tracks through the OL db" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();

    // The db's own high-water ids, for the mint assertions.
    const lib = (try ex.openOneLibrary()).?;
    var max_content: i64 = 0;
    for (lib.contents) |c| max_content = @max(max_content, c.content_id);
    var max_genre: i64 = 0;
    for (lib.genres) |g| max_genre = @max(max_genre, g.genre_id);
    var reboot_id: ?i64 = null;
    for (lib.artists) |a| {
        if (a.name != null and std.mem.eql(u8, a.name.?, "Reboot")) reboot_id = a.artist_id;
    }

    // Dedup: a path the db carries returns its own id, unchanged.
    const dup = try ex.addTrack(.{
        .title = "Again",
        .file_path = with_anlz_tracks[0].audio_path,
    });
    try testing.expect(!dup.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), dup.id);

    // A new track: the existing artist resolves to the db's own row, a
    // new genre mints past the db's own ids.
    const genre = "Brand New Genre";
    const added = try ex.addTrack(.{
        .title = "New Track",
        .artist = "Reboot",
        .genre = genre,
        .tempo = 120.5,
        .file_path = "/Contents/new.mp3",
        .filename = "new.mp3",
        .sample_rate = 48_000,
    });
    try testing.expect(added.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(@as(u32, @intCast(max_content + 1)))), added.id);

    try ex.save();

    // Reopen: the row landed with stable ids.
    var ex2 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex2.deinit();
    const lib2 = (try ex2.openOneLibrary()).?;
    const c = lib2.contentByPath("/Contents/new.mp3").?;
    try testing.expectEqual(max_content + 1, c.content_id);
    try testing.expectEqualStrings("New Track", c.title.?);
    try testing.expectEqual(@as(i64, 12_050), c.bpmx100.?);
    try testing.expectEqual(@as(i64, 48_000), c.samplingRate.?);
    // The fresh-row constants the mirror copies.
    try testing.expectEqual(@as(i64, 788_224), c.contentLink.?);
    try testing.expectEqual(@as(i64, 41), c.analysedBits.?);
    // The artist deduped to the db's own row, the genre minted.
    try testing.expectEqual(reboot_id.?, c.artist_id_artist.?);
    var minted_genre = false;
    for (lib2.genres) |g| {
        if (g.name != null and std.mem.eql(u8, g.name.?, genre)) {
            minted_genre = true;
            try testing.expectEqual(max_genre + 1, g.genre_id);
            try testing.expectEqual(g.genre_id, c.genre_id.?);
        }
    }
    try testing.expect(minted_genre);
    // No analysis input, no analysis path.
    try testing.expect(c.analysisDataFilePath == null);

    // A view on the OL-only export reads the new row back.
    var record = (try ex2.trackByPath("/Contents/new.mp3")).?;
    defer record.deinit();
    try testing.expectEqual(added.id, record.view.id);
    try testing.expectEqualStrings("New Track", record.view.title);
    try testing.expectEqualStrings("Reboot", record.view.artist);
    try testing.expectEqualStrings(genre, record.view.genre);
}

test "OL-only add then remove before save lands nothing" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    const added = try ex.addTrack(.{
        .title = "Gone",
        .file_path = "/Contents/gone.mp3",
    });
    try testing.expect(added.is_new);
    try ex.removeTrack(added.id, .{});
    try ex.save();

    var ex2 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex2.deinit();
    try testing.expect((try ex2.openOneLibrary()).?.contentByPath("/Contents/gone.mp3") == null);
}

test "OL-only roots update, rename, and remove tracks" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyFixtureOlDb(&tmp, io, alloc);
    // The analysis files the rename relocates.
    try copyFixtureFile(&tmp, io, alloc, "with_anlz", "PIONEER/USBANLZ/P01F/00004BC5/ANLZ0000.DAT");
    try copyFixtureFile(&tmp, io, alloc, "with_anlz", "PIONEER/USBANLZ/P01F/00004BC5/ANLZ0000.EXT");

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();

    try testing.expectError(error.UnknownTrack, ex.updateTrack(@enumFromInt(99), .{ .title = "x" }));

    // Patch: pdb-mirrored and OL-only columns move.
    try ex.updateTrack(@enumFromInt(2), .{ .title = "Renamed", .tempo = 140.0, .subtitle = "sub" });
    // Rename: the analysis follows at save.
    const new_path = "/Contents/Reboot/renamed.mp3";
    try ex.updateTrack(@enumFromInt(2), .{ .file_path = new_path });
    // Another track's path is taken.
    try testing.expectError(
        error.DuplicatePath,
        ex.updateTrack(@enumFromInt(2), .{ .file_path = with_anlz_tracks[1].audio_path }),
    );

    try ex.save();

    // The relocation landed: the old directory is gone, the new one
    // carries the siblings with PPTH naming the new path.
    const old_dir = "PIONEER/USBANLZ/P01F/00004BC5";
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, old_dir, .{}));
    const h = try device_export.pathHash(new_path);
    const new_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(new_dir);
    const dat_sub = try std.fmt.allocPrint(alloc, "{s}/ANLZ0000.DAT", .{new_dir});
    defer alloc.free(dat_sub);
    const dat = try tmp.dir.readFileAlloc(io, dat_sub, alloc, .limited(1 << 24));
    defer alloc.free(dat);
    var parsed = try anlz.Anlz.parse(alloc, dat);
    defer parsed.deinit();
    var ppth: ?[]u8 = null;
    defer if (ppth) |p| alloc.free(p);
    for (parsed.sections) |section| switch (section) {
        .path => |p| ppth = try p.path.utf8(alloc),
        else => {},
    };
    try testing.expectEqualStrings(new_path, ppth.?);

    // The row landed with the stable id and the patched values.
    var ex2 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex2.deinit();
    const lib2 = (try ex2.openOneLibrary()).?;
    const c = lib2.contentByPath(new_path).?;
    try testing.expectEqual(@as(i64, 2), c.content_id);
    try testing.expectEqualStrings("Renamed", c.title.?);
    try testing.expectEqual(@as(i64, 14_000), c.bpmx100.?);
    try testing.expectEqualStrings("sub", c.subtitle.?);
    try testing.expectEqualStrings("renamed.mp3", c.fileName.?);
    const want_anlz = try device_export.anlzDevicePath(alloc, new_path);
    defer alloc.free(want_anlz);
    try testing.expectEqualStrings(want_anlz, c.analysisDataFilePath.?);
    try testing.expect(lib2.contentByPath(with_anlz_tracks[0].audio_path) == null);

    // Removal: the disk row cascade-deletes at save. Before it lands,
    // the session already counts the row gone — the read side and a
    // second removal both see the tombstone, not the stale disk.
    try ex2.removeTrack(@enumFromInt(2), .{});
    try testing.expect((try ex2.trackByPath(new_path)) == null);
    try testing.expectError(error.UnknownTrack, ex2.removeTrack(@enumFromInt(2), .{}));
    try ex2.save();
    var ex3 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex3.deinit();
    try testing.expect((try ex3.openOneLibrary()).?.contentByPath(new_path) == null);
}

test "OL-only roots round-trip playlists" {
    if (onelibrary.mode == .off) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyFixtureOlDb(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();

    // The db's own node reads back: one root-level leaf playlist.
    {
        var tree = try ex.getPlaylists();
        defer tree.deinit();
        try testing.expectEqual(@as(usize, 1), tree.roots.len);
        const saved = &tree.roots[0].playlist;
        try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(1)), saved.id);
        try testing.expectEqualStrings("aaaaa", saved.name);
    }
    const fixture_entries = try ex.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(fixture_entries);
    try testing.expectEqualSlices(device_export.TrackId, &.{ @enumFromInt(1), @enumFromInt(2) }, fixture_entries);
    const none = try ex.getPlaylistTrackIds(alloc, @enumFromInt(999));
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Roles and unknown keys validate against the OL rows; the ids mint
    // past the db's own (its high water is 1).
    try testing.expectError(error.UnknownForeignKey, ex.createPlaylist("Orphan", @enumFromInt(999)));
    const folder = try ex.createPlaylistFolder("Folder", .root);
    const playlist = try ex.createPlaylist("Playlist", folder);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(2)), folder);
    try testing.expectEqual(@as(device_export.PlaylistNodeId, @enumFromInt(3)), playlist);
    try testing.expectError(error.UnknownForeignKey, ex.createPlaylist("Child", playlist));
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(folder, @enumFromInt(1)));
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(@enumFromInt(999), @enumFromInt(1)));
    try testing.expectError(error.UnknownForeignKey, ex.addTrackToPlaylist(playlist, @enumFromInt(999)));

    // Membership: a disk content id and a minted one.
    const added = try ex.addTrack(.{
        .title = "New",
        .file_path = "/Contents/new.mp3",
    });
    try ex.addTrackToPlaylist(playlist, @enumFromInt(1));
    try ex.addTrackToPlaylist(playlist, added.id);
    try ex.save();

    // Reopen: the tree and the entries landed with stable ids, and the
    // fixture's own playlist is untouched.
    var ex2 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex2.deinit();
    {
        var tree = try ex2.getPlaylists();
        defer tree.deinit();
        try testing.expectEqual(@as(usize, 2), tree.roots.len);
        const saved_folder = &tree.roots[1].folder;
        try testing.expectEqual(folder, saved_folder.id);
        try testing.expectEqualStrings("Folder", saved_folder.name);
        try testing.expectEqual(@as(usize, 1), saved_folder.children.items.len);
        const saved_playlist = &saved_folder.children.items[0].playlist;
        try testing.expectEqual(playlist, saved_playlist.id);
        try testing.expectEqualStrings("Playlist", saved_playlist.name);
    }
    const entries = try ex2.getPlaylistTrackIds(alloc, playlist);
    defer alloc.free(entries);
    try testing.expectEqualSlices(device_export.TrackId, &.{ @enumFromInt(1), added.id }, entries);
    const fixture_entries2 = try ex2.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(fixture_entries2);
    try testing.expectEqualSlices(device_export.TrackId, &.{ @enumFromInt(1), @enumFromInt(2) }, fixture_entries2);

    // A removal tombstones its entries before the save lands the
    // cascade, and the cascade carries them away.
    try ex2.removeTrack(@enumFromInt(1), .{});
    const tombstoned = try ex2.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(tombstoned);
    try testing.expectEqualSlices(device_export.TrackId, &.{@enumFromInt(2)}, tombstoned);
    try ex2.save();
    var ex3 = try device_export.DeviceExport.open(root, io, alloc);
    defer ex3.deinit();
    const cascaded = try ex3.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(cascaded);
    try testing.expectEqualSlices(device_export.TrackId, &.{@enumFromInt(2)}, cascaded);
}

test "getPlaylistTrackIds returns entries in order" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = try device_export.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();

    const entries = try ex.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(entries);
    try testing.expectEqualSlices(device_export.TrackId, &.{ @enumFromInt(1), @enumFromInt(2) }, entries);

    const none = try ex.getPlaylistTrackIds(alloc, @enumFromInt(999));
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "updateTrack patches both databases and preserves untouched fields" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyWithAnlzFixture(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    try ex.updateTrack(@enumFromInt(2), .{
        .title = "Bako (Remaster)",
        .artist = "Someone Else",
        .tempo = 130.0,
        .rating = 5,
        .comment = "still nice",
        .subtitle = "the b side",
        .publish_track_information = false,
        .analyze_date = "2026-08-31",
    });
    try ex.save();

    // A fresh handle sees the landed state.
    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    var record = (try reopened.trackByPath(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    )).?;
    defer record.deinit();
    const v = &record.view;
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), v.id);
    try testing.expectEqualStrings("Bako (Remaster)", v.title);
    try testing.expectEqualStrings("Someone Else", v.artist);
    try testing.expectEqual(@as(f32, 130.0), v.tempo);
    try testing.expectEqual(@as(u8, 5), v.rating);
    try testing.expect(!v.publish_track_information);
    try testing.expectEqualStrings("2026-08-31", v.analyze_date);

    // The row's device constants survive a patch, unlike a fresh row's.
    var raw_db = try parseExportPdb(alloc, io, root);
    defer raw_db.deinit();
    var track_it = try raw_db.rowsOf(pdb.Track);
    while (try track_it.next()) |track| {
        if (track.id != 2) continue;
        try testing.expectEqual(@as(u32, 788_224), track.bitmask);
        try testing.expectEqual(@as(u16, 41), track.unknown5);
    }

    if (onelibrary.mode != .off) {
        const lib = (try reopened.openOneLibrary()).?;
        const content = lib.contentByPath(
            "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
        ).?;
        try testing.expectEqualStrings("Bako (Remaster)", content.title.?);
        try testing.expectEqualStrings("the b side", content.subtitle.?);
        try testing.expectEqualStrings("still nice", content.djComment.?);
        try testing.expectEqual(@as(i64, 13_000), content.bpmx100.?);
        try testing.expectEqual(@as(i64, 5), content.rating.?);
        // Untouched OL columns keep their values.
        try testing.expectEqualStrings("2026-07-16", content.dateCreated.?);
        try testing.expectEqualStrings(
            "Someone Else",
            lib.byId(onelibrary.Artist, content.artist_id_artist.?).?.name.?,
        );
    }
}

test "updateTrack rejects an unknown track and a bad string" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyWithAnlzFixture(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    try testing.expectError(error.UnknownTrack, ex.updateTrack(@enumFromInt(999), .{ .rating = 5 }));

    const long_title = try alloc.alloc(u8, 32_768);
    defer alloc.free(long_title);
    @memset(long_title, 'a');
    try testing.expectError(error.TooLong, ex.updateTrack(@enumFromInt(2), .{ .title = long_title }));

    // The failed patch changed nothing.
    var record = (try ex.trackByPath(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    )).?;
    defer record.deinit();
    try testing.expectEqualStrings("Bako (Original Mix)", record.view.title);
}

test "a file_path patch renames: the row, the mirror, and the analysis files move" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyWithAnlzFixture(&tmp, io, alloc);

    const old_path = "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3";
    const new_path = "/Contents/Renamed/Bako.mp3";

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    // The rename rides along a field patch, in one call.
    try ex.updateTrack(@enumFromInt(2), .{ .file_path = new_path, .title = "Bako" });
    // The dedup key already follows the new path, before any save.
    const dup = try ex.addTrack(.{ .title = "Bako (Original Mix)", .file_path = new_path });
    try testing.expect(!dup.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), dup.id);
    try ex.save();

    // A fresh handle sees the landed rename.
    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    try testing.expect((try reopened.trackByPath(old_path)) == null);
    var record = (try reopened.trackByPath(new_path)).?;
    defer record.deinit();
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), record.view.id);
    try testing.expectEqualStrings("Bako", record.view.title);
    try testing.expectEqualStrings("Bako.mp3", record.view.filename);
    try testing.expect(record.view.has_analysis);

    // The pdb's analyze_path matches what players recompute from the
    // new path.
    const want_anlz = try device_export.anlzDevicePath(alloc, new_path);
    defer alloc.free(want_anlz);
    var raw_db = try parseExportPdb(alloc, io, root);
    defer raw_db.deinit();
    var track_it = try raw_db.rowsOf(pdb.Track);
    while (try track_it.next()) |track| {
        if (track.id != 2) continue;
        const got = try track.offsets.inner.analyze_path.utf8(alloc);
        defer alloc.free(got);
        try testing.expectEqualStrings(want_anlz, got);
    }

    // The analysis files live where the new path hashes to, the PPTH
    // inside names the new path, and the old directory is gone.
    const old_h = try device_export.pathHash(old_path);
    const new_h = try device_export.pathHash(new_path);
    const old_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ old_h.p_value, old_h.hash },
    );
    defer alloc.free(old_dir);
    const new_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ new_h.p_value, new_h.hash },
    );
    defer alloc.free(new_dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, old_dir, .{}));

    const dat_sub = try std.fmt.allocPrint(alloc, "{s}/ANLZ0000.DAT", .{new_dir});
    defer alloc.free(dat_sub);
    const dat = try tmp.dir.readFileAlloc(io, dat_sub, alloc, .limited(1 << 24));
    defer alloc.free(dat);
    var parsed = try anlz.Anlz.parse(alloc, dat);
    defer parsed.deinit();
    var ppth: ?[]u8 = null;
    defer if (ppth) |p| alloc.free(p);
    for (parsed.sections) |section| switch (section) {
        .path => |p| ppth = try p.path.utf8(alloc),
        else => {},
    };
    try testing.expectEqualStrings(new_path, ppth.?);

    if (onelibrary.mode != .off) {
        const lib = (try reopened.openOneLibrary()).?;
        try testing.expect(lib.contentByPath(old_path) == null);
        const content = lib.contentByPath(new_path).?;
        try testing.expectEqual(@as(i64, 2), content.content_id);
        try testing.expectEqualStrings("Bako", content.title.?);
        try testing.expectEqualStrings("Bako.mp3", content.fileName.?);
        const want_ol_anlz = try device_export.anlzDevicePath(alloc, new_path);
        defer alloc.free(want_ol_anlz);
        try testing.expectEqualStrings(want_ol_anlz, content.analysisDataFilePath.?);
    }
}

test "a file_path patch rejects duplicate paths, malformed paths, and occupied targets" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyWithAnlzFixture(&tmp, io, alloc);

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();

    // The other track's path is taken.
    try testing.expectError(
        error.DuplicatePath,
        ex.updateTrack(
            @enumFromInt(2),
            .{ .file_path = "/Contents/Reboot/www.electronicfresh.com/03. Reboot - Assign The Source (Remaster).mp3" },
        ),
    );
    // The path coordinate is device-absolute.
    try testing.expectError(error.InvalidPath, ex.updateTrack(@enumFromInt(2), .{ .file_path = "Contents/Bako.mp3" }));
    try testing.expectError(error.InvalidPath, ex.updateTrack(@enumFromInt(2), .{ .file_path = "" }));

    // A target directory another analysis already occupies is refused,
    // without a way through: clobbering would destroy that analysis.
    const old_path = "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3";
    const new_path = "/Contents/Renamed/Bako.mp3";
    const h = try device_export.pathHash(new_path);
    const anlz_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ h.p_value, h.hash },
    );
    defer alloc.free(anlz_dir);
    try tmp.dir.createDirPath(io, anlz_dir);
    const target_dat = try std.fmt.allocPrint(alloc, "{s}/ANLZ0000.DAT", .{anlz_dir});
    defer alloc.free(target_dat);
    try tmp.dir.writeFile(io, .{ .sub_path = target_dat, .data = "occupied" });
    try testing.expectError(error.AnalysisPathCollision, ex.updateTrack(@enumFromInt(2), .{ .file_path = new_path }));
    // The refusal is final: the track keeps its old path.
    try testing.expect((try ex.trackByPath(new_path)) == null);
    var record = (try ex.trackByPath(old_path)).?;
    defer record.deinit();
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), record.view.id);
}

test "a pending rename retargets queued analysis before the first save" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);

    var beats = [1]anlz.Beat{.{ .beat_number = 1, .tempo = 12_800, .time = 0 }};
    const input = anlz.Analysis{ .beats = &beats, .cue_list_type = .memory_cues };

    const first_path = "/Contents/test.mp3";
    const renamed_path = "/Contents/renamed.mp3";

    var ex = try device_export.DeviceExport.create(root, io, alloc);
    defer ex.deinit();
    _ = try ex.addTrack(.{ .title = "test", .file_path = first_path, .analysis = &input });
    try ex.updateTrack(@enumFromInt(1), .{ .file_path = renamed_path });
    try ex.save();

    // Nothing under the original hash; the DAT under the new hash names
    // the new path.
    const old_h = try device_export.pathHash(first_path);
    const new_h = try device_export.pathHash(renamed_path);
    const old_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ old_h.p_value, old_h.hash },
    );
    defer alloc.free(old_dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, old_dir, .{}));

    const dat_sub = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.DAT",
        .{ new_h.p_value, new_h.hash },
    );
    defer alloc.free(dat_sub);
    const dat = try tmp.dir.readFileAlloc(io, dat_sub, alloc, .limited(1 << 24));
    defer alloc.free(dat);
    var parsed = try anlz.Anlz.parse(alloc, dat);
    defer parsed.deinit();
    for (parsed.sections) |section| switch (section) {
        .path => |p| {
            const got = try p.path.utf8(alloc);
            defer alloc.free(got);
            try testing.expectEqualStrings(renamed_path, got);
        },
        else => {},
    };
}

test "removeTrack cascades across both databases and deletes analysis on request" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpExportPath(&tmp, alloc);
    defer alloc.free(root);
    try copyWithAnlzFixture(&tmp, io, alloc);

    const bako_path = "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3";

    var ex = try device_export.DeviceExport.open(root, io, alloc);
    defer ex.deinit();
    try ex.removeTrack(@enumFromInt(2), .{ .delete_analysis_files = true });
    try testing.expectError(error.UnknownTrack, ex.removeTrack(@enumFromInt(2), .{}));
    try ex.save();

    var reopened = try device_export.DeviceExport.open(root, io, alloc);
    defer reopened.deinit();
    try testing.expect((try reopened.trackByPath(bako_path)) == null);
    var it = try reopened.tracks();
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |track| {
        count += 1;
        try testing.expect(track.id != @as(device_export.TrackId, @enumFromInt(2)));
    }
    try testing.expectEqual(@as(usize, 1), count);

    // The playlist entry went with the track.
    const entries = try reopened.getPlaylistTrackIds(alloc, @enumFromInt(1));
    defer alloc.free(entries);
    try testing.expectEqualSlices(device_export.TrackId, &.{@enumFromInt(1)}, entries);

    // The analysis directory is gone; the survivor's stays.
    const bako_h = try device_export.pathHash(bako_path);
    const bako_dir = try std.fmt.allocPrint(
        alloc,
        "PIONEER/USBANLZ/P{X:0>3}/{X:0>8}",
        .{ bako_h.p_value, bako_h.hash },
    );
    defer alloc.free(bako_dir);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, bako_dir, .{}));

    // A fresh track mints from the scan's max id + 1: with track 2 (the
    // max) gone, its id is reused — the same count-based behavior the
    // format's own writers have, not a collision (every reference to the
    // old row went with the cascade).
    const readded = try reopened.addTrack(.{ .title = "New", .file_path = "/Contents/new.mp3" });
    try testing.expect(readded.is_new);
    try testing.expectEqual(@as(device_export.TrackId, @enumFromInt(2)), readded.id);

    if (onelibrary.mode != .off) {
        const lib = (try reopened.openOneLibrary()).?;
        try testing.expect(lib.contentByPath(bako_path) == null);
        try testing.expectEqual(@as(usize, 1), lib.contents.len);
        try testing.expectEqual(@as(i64, 1), lib.property.?.numberOfContents.?);
        // The playlist junction went with the content row.
        var junctions: usize = 0;
        for (lib.playlist_contents) |row| {
            if (row.content_id.? == 2) junctions += 1;
        }
        try testing.expectEqual(@as(usize, 0), junctions);
    }
}
