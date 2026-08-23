const std = @import("std");
const testing = std.testing;

const dlp = @import("dlp");
const testutil = @import("util.zig");

test {
    if (dlp.mode != .vendored) return; // fixture tests need the vendored build
}

/// Copies the with_anlz `exportLibrary.db` into a temp dir (the WAL-persisted
/// fixture needs write access for recovery) and opens it keyed.
fn openFixtureDb(io: std.Io, tmp: *testing.TmpDir, alloc: std.mem.Allocator) !dlp.Db {
    return openFixtureCopy(io, tmp, alloc, true);
}

/// Copies the decrypted `testdata/dlp/with_anlz_plain.db` into a temp dir
/// and opens it without the DLP key — the fast O2 fixture path.
fn openPlaintextFixtureDb(io: std.Io, tmp: *testing.TmpDir, alloc: std.mem.Allocator) !dlp.Db {
    return openFixtureCopy(io, tmp, alloc, false);
}

fn openFixtureCopy(
    io: std.Io,
    tmp: *testing.TmpDir,
    alloc: std.mem.Allocator,
    keyed: bool,
) !dlp.Db {
    const rel = if (keyed)
        "complete_export/with_anlz/PIONEER/rekordbox/exportLibrary.db"
    else
        "dlp/with_anlz_plain.db";
    const image = try testutil.readFixture(alloc, rel, .limited(1 << 20));
    defer alloc.free(image);
    const name = if (keyed) "exportLibrary.db" else "plain.db";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = image });
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ tmp_path, name }, 0);
    defer alloc.free(db_path);
    return if (keyed) dlp.Db.open(io, db_path) else dlp.Db.openPlaintext(io, db_path);
}

test "with_anlz fixture: integrity, provider wiring, table counts" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openFixtureDb(io, &tmp, alloc);
    defer db.close();

    var stmt = try db.prepare("PRAGMA integrity_check;");
    defer stmt.finalize();
    try testing.expectEqual(.row, try stmt.step());
    try testing.expectEqualStrings("ok", stmt.readText(0));
    try testing.expectEqual(.done, try stmt.step());

    // the Zig std.crypto provider must be the one SQLCipher used
    var prov = try db.prepare("PRAGMA cipher_provider;");
    defer prov.finalize();
    try testing.expectEqual(.row, try prov.step());
    try testing.expectEqualStrings("zig-std-crypto", prov.readText(0));

    // hand-pinned counts (Phase O findings; O2 turns these into models)
    try testing.expectEqual(@as(i64, 2), try db.scalarInt("SELECT COUNT(*) FROM content;"));
    try testing.expectEqual(@as(i64, 1), try db.scalarInt("SELECT COUNT(*) FROM artist;"));
    try testing.expectEqual(@as(i64, 1), try db.scalarInt("SELECT COUNT(*) FROM album;"));
    try testing.expectEqual(@as(i64, 28), try db.scalarInt("SELECT COUNT(*) FROM myTag;"));
    try testing.expectEqual(@as(i64, 1), try db.scalarInt("SELECT COUNT(*) FROM playlist;"));
    try testing.expectEqual(@as(i64, 2), try db.scalarInt("SELECT COUNT(*) FROM playlist_content;"));
    try testing.expectEqual(@as(i64, 2), try db.scalarInt("SELECT COUNT(*) FROM image;"));
    try testing.expectEqual(@as(i64, 1), try db.scalarInt("SELECT COUNT(*) FROM property;"));
}

test "create, write, read back through the provider" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/ol.db", .{tmp_path}, 0);
    defer alloc.free(db_path);

    {
        var db = try dlp.Db.openReadWriteCreate(io, db_path);
        defer db.close();
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, data BLOB);");
        var stmt = try db.prepare("INSERT INTO t (name, score, data) VALUES (?1, ?2, ?3);");
        defer stmt.finalize();
        try stmt.bindText(1, "bloß");
        try stmt.bindFloat(2, 1.5);
        try stmt.bindBlob(3, &[_]u8{ 1, 2, 3, 255 });
        try testing.expectEqual(.done, try stmt.step());
        try testing.expectEqual(@as(i64, 1), db.changes());
        try testing.expectEqual(@as(i64, 1), db.lastInsertRowid());
    }

    // reopen: the file on disk must be encrypted and decrypt correctly
    const raw = try tmp.dir.readFileAlloc(io, "ol.db", alloc, .limited(1 << 20));
    defer alloc.free(raw);
    try testing.expect(raw.len >= 4096);
    try testing.expect(!std.mem.eql(u8, raw[0..16], "SQLite format 3\x00")); // salt, not magic
    var db = try dlp.Db.open(io, db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT id, name, score, data FROM t;");
    defer stmt.finalize();
    try testing.expectEqual(.row, try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.readInt(0));
    try testing.expectEqualStrings("bloß", stmt.readText(1));
    try testing.expectEqual(@as(f64, 1.5), stmt.readFloat(2));
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 255 }, stmt.readBlob(3));
    try testing.expectEqual(.done, try stmt.step());
    var check = try db.prepare("PRAGMA integrity_check;");
    defer check.finalize();
    try testing.expectEqual(.row, try check.step());
    try testing.expectEqualStrings("ok", check.readText(0));
}

test "sqliteVersion is reachable" {
    if (dlp.mode == .off) return;
    try testing.expect(std.mem.startsWith(u8, dlp.sqliteVersion(), "3."));
}

test "O2 load: every table with the fixture's row counts" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openPlaintextFixtureDb(io, &tmp, alloc);
    defer db.close();

    var lib = try dlp.Library.load(alloc, db);
    defer lib.deinit();

    try testing.expectEqual(@as(usize, 1), lib.albums.len);
    try testing.expectEqual(@as(usize, 1), lib.artists.len);
    try testing.expectEqual(@as(usize, 22), lib.categories.len);
    try testing.expectEqual(@as(usize, 8), lib.colors.len);
    try testing.expectEqual(@as(usize, 2), lib.contents.len);
    try testing.expectEqual(@as(usize, 0), lib.cues.len);
    try testing.expectEqual(@as(usize, 2), lib.genres.len);
    try testing.expectEqual(@as(usize, 0), lib.histories.len);
    try testing.expectEqual(@as(usize, 0), lib.history_contents.len);
    try testing.expectEqual(@as(usize, 0), lib.hot_cue_bank_lists.len);
    try testing.expectEqual(@as(usize, 0), lib.hot_cue_bank_cues.len);
    try testing.expectEqual(@as(usize, 2), lib.images.len);
    try testing.expectEqual(@as(usize, 0), lib.keys.len);
    try testing.expectEqual(@as(usize, 1), lib.labels.len);
    try testing.expectEqual(@as(usize, 27), lib.menu_items.len);
    try testing.expectEqual(@as(usize, 28), lib.my_tags.len);
    try testing.expectEqual(@as(usize, 0), lib.my_tag_contents.len);
    try testing.expectEqual(@as(usize, 1), lib.playlists.len);
    try testing.expectEqual(@as(usize, 2), lib.playlist_contents.len);
    try testing.expectEqual(@as(usize, 0), lib.recommended_likes.len);
    try testing.expectEqual(@as(usize, 17), lib.sorts.len);
    try testing.expect(lib.property != null);
}

test "O2 load: fixture values, NULL versus empty string" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openPlaintextFixtureDb(io, &tmp, alloc);
    defer db.close();

    var lib = try dlp.Library.load(alloc, db);
    defer lib.deinit();

    const bako = lib.contents[1];
    try testing.expectEqualStrings("Bako (Original Mix)", bako.title.?);
    try testing.expectEqual(@as(i64, 12900), bako.bpmx100.?);
    try testing.expectEqual(@as(i64, 16), bako.bitDepth.?);
    try testing.expectEqual(@as(i64, 44100), bako.samplingRate.?);
    try testing.expectEqual(@as(i64, 0), bako.djPlayCount.?);
    try testing.expectEqual(@as(i64, 41), bako.analysedBits.?);
    try testing.expectEqual(@as(i64, 788224), bako.contentLink.?);
    try testing.expectEqualStrings(
        "/PIONEER/USBANLZ/P01F/00004BC5/ANLZ0000.DAT",
        bako.analysisDataFilePath.?,
    );
    // the fixture writes NULL for unset foreign keys but '' elsewhere
    try testing.expect(bako.artist_id_remixer == null);
    try testing.expect(bako.titleForSearch == null);
    try testing.expect(bako.cueUpdateCount == null);
    try testing.expect(bako.isrc != null and bako.isrc.?.len == 0);
    try testing.expect(bako.subtitle != null and bako.subtitle.?.len == 0);

    try testing.expectEqualStrings("Reboot", lib.artists[0].name.?);
    // the album name's leading space is genuine (D5 finding)
    try testing.expectEqualStrings(" www.electronicfresh.com", lib.albums[0].name.?);
    try testing.expectEqual(@as(i64, 0), lib.albums[0].isComplation.?);
    try testing.expectEqualStrings("Pink", lib.colors[0].name.?);
    try testing.expectEqualStrings("/PIONEER/Artwork/00001/b1.jpg", lib.images[0].path.?);
    try testing.expectEqualStrings("aaaaa", lib.playlists[0].name.?);
    try testing.expect(lib.playlists[0].image_id == null);
    // myTag: four root columns (attribute 1, parent 0), 24 leaves
    var roots: usize = 0;
    var leaves: usize = 0;
    for (lib.my_tags) |tag| {
        if (tag.attribute == 1 and tag.myTag_id_parent == 0) roots += 1 else leaves += 1;
    }
    try testing.expectEqual(@as(usize, 4), roots);
    try testing.expectEqual(@as(usize, 24), leaves);
    try testing.expectEqualStrings("10000", lib.property.?.dbVersion.?);
    try testing.expectEqual(@as(i64, 2), lib.property.?.numberOfContents.?);
}

test "O2 load: schema drift is rejected" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // extra column: count mismatch
    {
        var db = try openPlaintextFixtureDb(io, &tmp, alloc);
        defer db.close();
        try db.exec("ALTER TABLE artist ADD COLUMN extra varchar;");
        try testing.expectError(error.SchemaMismatch, dlp.Library.load(alloc, db));
    }
    // renamed column: name mismatch
    {
        var db = try openPlaintextFixtureDb(io, &tmp, alloc);
        defer db.close();
        try db.exec("ALTER TABLE menuItem RENAME COLUMN name TO nom;");
        try testing.expectError(error.SchemaMismatch, dlp.Library.load(alloc, db));
    }
    // duplicated property row: the singleton rule
    {
        var db = try openPlaintextFixtureDb(io, &tmp, alloc);
        defer db.close();
        try db.exec("INSERT INTO property SELECT * FROM property;");
        try testing.expectError(error.SchemaMismatch, dlp.Library.load(alloc, db));
    }
}

test "O2 load: plaintext and encrypted paths yield identical models" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var plain_tmp = testing.tmpDir(.{});
    defer plain_tmp.cleanup();
    var plain = try openPlaintextFixtureDb(io, &plain_tmp, alloc);
    defer plain.close();
    var plain_lib = try dlp.Library.load(alloc, plain);
    defer plain_lib.deinit();

    var enc_tmp = testing.tmpDir(.{});
    defer enc_tmp.cleanup();
    var enc = try openFixtureDb(io, &enc_tmp, alloc);
    defer enc.close();
    var enc_lib = try dlp.Library.load(alloc, enc);
    defer enc_lib.deinit();

    try testing.expect(plain_lib.eql(&enc_lib));
}
