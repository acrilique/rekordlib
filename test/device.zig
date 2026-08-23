// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const device = @import("device");
const pdb = @import("pdb");
const setting = @import("setting");
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
        const ex = device.DeviceExport.open(path, io, alloc);
        const settings = ex.loadSettings();
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

    const ex = device.DeviceExport.open(tmp_path, io, alloc);
    const settings = ex.loadSettings();
    try testing.expect(settings.my_setting != null);
    try testing.expect(settings.djm_my_setting == null);
    try testing.expect(settings.dev_setting == null);
    try testing.expect(settings.my_setting2 == null);

    // A root without any export content at all stays quiet and empty.
    const empty_ex = device.DeviceExport.open(".zig-cache/definitely-not-here", io, alloc);
    const empty_settings = empty_ex.loadSettings();
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
        var ex = device.DeviceExport.open(path, io, alloc);
        defer ex.deinit();

        const db = try ex.openPdb();

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
        var ex = device.DeviceExport.open(path, io, alloc);
        defer ex.deinit();

        var playlists = try ex.getPlaylists();
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

    var playlists = try device.getPlaylistsDb(alloc, &db);
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

    var playlists = try device.getPlaylistsDb(alloc, &db);
    defer {
        for (playlists.items) |*node| node.deinit(alloc);
        playlists.deinit(alloc);
    }

    // The top level holds the real playlist and the id-0 folder; the
    // duplicated id 5 is expanded once (inside the id-0 folder) and skipped
    // at the top level.
    try testing.expectEqual(@as(usize, 2), playlists.items.len);
    try testing.expectEqual(@as(u32, 1), playlists.items[0].playlist.id);
    const root_cycle = playlists.items[1].folder;
    try testing.expectEqual(@as(u32, 0), root_cycle.id);
    try testing.expectEqual(@as(usize, 2), root_cycle.children.items.len);
    try testing.expectEqual(@as(u32, 1), root_cycle.children.items[0].playlist.id);
    const inner = root_cycle.children.items[1].folder;
    try testing.expectEqual(@as(u32, 5), inner.id);
    try testing.expectEqual(@as(usize, 0), inner.children.items.len);
}

/// Counts the rows of one table through its page chain.
fn countTableRows(db: *const pdb.Database, page_type: pdb.PageType) !usize {
    var it = try db.rows(page_type);
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    return count;
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
    for (device.dat_files) |dat| {
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

    var ex = try device.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    try ex.save();

    var reread = device.DeviceExport.open(tmp_path, io, alloc);
    defer reread.deinit();
    const db = try reread.openPdb();

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
    // it creates an export; the oracle's `create` — and ours — starts
    // that table empty, so it is asserted as zero instead.
    const table_types = [_]pdb.PageType{
        .tracks,   .genres,           .artists,  .albums,
        .labels,   .keys,             .colors,   .playlist_tree,
        .playlist_entries, .history_playlists, .history_entries,
        .artwork,  .columns,          .menu,
    };
    inline for (table_types) |page_type| {
        try testing.expectEqual(
            try countTableRows(&empty, page_type),
            try countTableRows(db, page_type),
        );
    }
    try testing.expectEqual(@as(usize, 1), try countTableRows(&empty, .history));
    try testing.expectEqual(@as(usize, 0), try countTableRows(db, .history));
    try testing.expectEqual(@as(usize, 8), try countTableRows(db, .colors));
    try testing.expectEqual(@as(usize, 27), try countTableRows(db, .columns));
    try testing.expectEqual(@as(usize, 22), try countTableRows(db, .menu));

    // All four settings landed, parse back, and re-serialize byte-equal —
    // the default constructors and checksums agree with a real export.
    const settings = reread.loadSettings();
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

    var ex = try device.DeviceExport.create(tmp_path, io, alloc);
    ex.deinit();

    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "PIONEER", .{}));
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
        device.DeviceExport.create(tmp_path, io, alloc),
    );
}

test "save is byte-stable" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device.DeviceExport.create(tmp_path, io, alloc);
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
    const settings = ex.loadSettings();
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

    var ex = device.DeviceExport.open(tmp_path, io, alloc);
    defer ex.deinit();
    const db = try ex.openPdb();

    // Escape-hatch surgery: a genre row through the modification layer.
    const a = db.arena.allocator();
    const genre = try a.create(pdb.Genre);
    genre.* = .{ .id = 1, .name = try pdb.DeviceSQLString.fromUtf8(a, "Techno") };
    var row = pdb.Row{ .genre = genre };
    _ = try db.addRow(&row);

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

    var check = device.DeviceExport.open(tmp_path, io, alloc);
    defer check.deinit();
    const db2 = try check.openPdb();
    try testing.expectEqual(@as(usize, 1), try countTableRows(db2, .genres));
}
