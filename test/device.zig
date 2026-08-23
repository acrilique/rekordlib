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

    const ex = device.DeviceExport.open(tmp_path, io, alloc);
    const settings = try ex.loadSettings();
    try testing.expect(settings.my_setting != null);
    try testing.expect(settings.djm_my_setting == null);
    try testing.expect(settings.dev_setting == null);
    try testing.expect(settings.my_setting2 == null);

    // A root without any export content at all stays quiet and empty.
    const empty_ex = device.DeviceExport.open(".zig-cache/definitely-not-here", io, alloc);
    const empty_settings = try empty_ex.loadSettings();
    try testing.expect(empty_settings.dev_setting == null);
    try testing.expect(empty_settings.djm_my_setting == null);
    try testing.expect(empty_settings.my_setting == null);
    try testing.expect(empty_settings.my_setting2 == null);
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

    const ex = device.DeviceExport.open(tmp_path, io, alloc);
    try testing.expectError(error.StreamTooLong, ex.loadSettings());
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
    const settings = try reread.loadSettings();
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

test "a save that fails validation leaves nothing on disk" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);

    var ex = try device.DeviceExport.create(tmp_path, io, alloc);
    defer ex.deinit();
    const db = try ex.openPdb();

    // Escape-hatch surgery: a track row padded to the CDJ minimum,
    // then shrunk below it, so `save` must fail validation — before it
    // has written anything.
    const a = db.arena.allocator();
    const boxed = try a.create(pdb.Track);
    boxed.* = .{ .id = 1, .offsets = .{ .inner = .{
        .title = try pdb.DeviceSQLString.fromUtf8(a, "Music"),
    } } };
    try pdb.padTrackCommentToMinimum(boxed, a);
    var row = pdb.Row{ .track = boxed };
    _ = try db.addRow(&row);
    // `addRow` stored the box itself, so this edits the database's row.
    boxed.offsets.inner.comment = pdb.DeviceSQLString.empty();

    try testing.expectError(error.TrackRowTooSmall, ex.save());
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

// --- writer: lazy scan (D5) ----------------------------------------------------

/// Asserts `canonicalKeyName(in) == want`, freeing the owned result.
fn expectCanonical(in: []const u8, want: []const u8) !void {
    const alloc = testing.allocator;
    const got = try device.canonicalKeyName(alloc, in);
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
        var ex = device.DeviceExport.open(path, io, alloc);
        defer ex.deinit();
        const ws = try ex.writerState();

        try testing.expectEqual(want.next_track_id, ws.next_track_id);
        try testing.expectEqual(want.next_artist_id, ws.next_artist_id);
        try testing.expectEqual(want.next_album_id, ws.next_album_id);
        try testing.expectEqual(want.next_genre_id, ws.next_genre_id);
        try testing.expectEqual(want.next_key_id, ws.next_key_id);
        try testing.expectEqual(want.next_label_id, ws.next_label_id);
        try testing.expectEqual(want.next_artwork_id, ws.next_artwork_id);
        try testing.expectEqual(want.next_playlist_node_id, ws.next_playlist_node_id);

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
    var ex = device.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
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
    try testing.expectEqual(@as(u32, 3), ws.playlist_entry_counts.get(1).?);
}

test "writer state ignores dead-row remnants" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ex = device.DeviceExport.open("testdata/complete_export/demo_tracks", io, alloc);
    defer ex.deinit();
    const ws = try ex.writerState();

    // The demo_tracks page heaps carry four deleted-track paths
    // (`/Contents/UnknownArtist/UnknownAlbum/*.wav`, P7's dead-space
    // finding) — the scan walks present rows only, so they must not
    // resolve.
    try testing.expect(ws.tracks_by_path.get(
        "/Contents/UnknownArtist/UnknownAlbum/NOISE.wav",
    ) == null);
    try testing.expectEqual(@as(usize, 2), ws.tracks_by_path.count());
}

test "writer state is lazy, cached, and pre-built by create" {
    const alloc = testing.allocator;
    const io = testing.io;

    var ex = device.DeviceExport.open("testdata/complete_export/with_anlz", io, alloc);
    defer ex.deinit();
    try testing.expect(ex.writer_state == null);
    const ws = try ex.writerState();
    try testing.expect(ws == try ex.writerState());
    try testing.expect(ex.pdb_state == .loaded);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    var created = try device.DeviceExport.create(tmp_path, io, alloc);
    defer created.deinit();
    const fresh = try created.writerState();
    // Fresh counters — id 0 is the null FK — and empty maps; the default
    // color/column/menu rows live in tables the writer doesn't track.
    try testing.expectEqual(@as(u32, 1), fresh.next_track_id);
    try testing.expectEqual(@as(u32, 1), fresh.next_artist_id);
    try testing.expectEqual(@as(u32, 1), fresh.next_tag_id);
    try testing.expectEqual(@as(u32, 0), fresh.next_category_position);
    try testing.expectEqual(@as(u32, 0), fresh.next_tag_row_index);
    try testing.expectEqual(@as(usize, 0), fresh.track_ids.count());
    try testing.expectEqual(@as(usize, 0), fresh.tracks_by_path.count());
}

test "writer state scans num_rows at scale" {
    const alloc = testing.allocator;
    const input = try testutil.readFixture(alloc, "pdb/num_rows/export.pdb", .limited(1 << 22));
    defer alloc.free(input);
    var db = try pdb.Database.parse(alloc, input, .plain);
    defer db.deinit();

    var state = try device.scanWriterState(alloc, &db);
    defer state.deinit(alloc);

    try testing.expectEqual(@as(usize, 3886), state.track_ids.count());
    try testing.expect(state.next_track_id > 3886);
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

    var state = device.WriterState{};
    defer state.deinit(alloc);
    try device.scanExtTags(alloc, &db, &state);

    try testing.expectEqual(@as(u32, 21), state.next_tag_id);
    try testing.expectEqual(@as(u32, 4), state.next_tag_row_index);
    try testing.expect(state.tag_categories.contains(7));
    try testing.expectEqual(@as(u32, 1), state.next_category_position);
    try testing.expectEqual(@as(u32, 2), state.tags_by_key.count());
    try testing.expectEqual(@as(u32, 9), state.tags_by_key.get(.{
        .category_id = 7,
        .label = "Techno",
    }).?);
    try testing.expectEqual(@as(u32, 12), state.tags_by_key.get(.{
        .category_id = 7,
        .label = "Dub",
    }).?);
    try testing.expectEqual(@as(u32, 3), state.tag_leaf_counts.get(7).?);
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

    var state = device.WriterState{};
    defer state.deinit(alloc);
    try device.scanExtTags(alloc, &db, &state);

    // Hand-checked against the fixture (2026-08-23): 4 categories —
    // Genre, Components, Situation, Untitled Column (ids 1-4, positions
    // 0-3) — holding 7/8/8/1 leaves; 28 Tag rows stepping index_shift by
    // 0x20; leaf ids are random-looking u32s (the max is Acid House's
    // 4275955888), mirroring the OL db's 28 myTag rows.
    try testing.expectEqual(@as(u32, 4275955889), state.next_tag_id);
    try testing.expectEqual(@as(u32, 28), state.next_tag_row_index);
    try testing.expectEqual(@as(u32, 4), state.next_category_position);
    try testing.expectEqual(@as(usize, 4), state.tag_categories.count());
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
    try testing.expectEqual(@as(u32, 7), state.tag_leaf_counts.get(1).?);
    try testing.expectEqual(@as(u32, 8), state.tag_leaf_counts.get(2).?);
    try testing.expectEqual(@as(u32, 8), state.tag_leaf_counts.get(3).?);
    try testing.expectEqual(@as(u32, 1), state.tag_leaf_counts.get(4).?);
}
