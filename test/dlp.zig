const std = @import("std");
const testing = std.testing;

const dlp = @import("rekordlib").dlp;
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

test "cbc matches NIST SP 800-38A F.2.5 (AES-256-CBC)" {
    // pure std.crypto - runs in every build mode, no sqlcipher needed
    const key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    const pt = hex(
        "6bc1bee22e409f96e93d7e117393172a" ++
            "ae2d8a571e03ac9c9eb76fac45af8e51" ++
            "30c81c46a35ce411e5fbc1191a0a52ef" ++
            "f69f2445df4f9b17ad2b417be66c3710",
    );
    const ct = hex(
        "f58c4c04d6e5f1ba779eabfb5f7bfbd6" ++
            "9cfc4e967edb808d679f777bc6702c7d" ++
            "39f23369a9d9bacfa530e26304231461" ++
            "b2eb05e2c39be9fcda6c19078c6a9d1b",
    );

    var buf: [64]u8 = undefined;
    try dlp.cbc(true, key, iv, &buf, &pt);
    try testing.expectEqualSlices(u8, &ct, buf[0..pt.len]);
    try dlp.cbc(false, key, iv, &buf, &ct);
    try testing.expectEqualSlices(u8, &pt, buf[0..ct.len]);

    // the preconditions are real errors, not debug asserts
    try testing.expectError(error.BufferTooSmall, dlp.cbc(true, key, iv, buf[0..8], &pt));
    try testing.expectError(error.NotBlockAligned, dlp.cbc(true, key, iv, &buf, pt[0..20]));
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
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

test "O2 keyed: by-id maps and the path join" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openPlaintextFixtureDb(io, &tmp, alloc);
    defer db.close();
    var lib = try dlp.Library.load(alloc, db);
    defer lib.deinit();

    // the pdb-side join
    const bako = lib.contentByPath(
        "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
    ).?;
    try testing.expectEqual(@as(i64, 2), bako.content_id);
    try testing.expect(lib.contentByPath("/Contents/nope") == null);

    try testing.expectEqualStrings("Reboot", lib.byId(dlp.Artist, 1).?.name.?);
    try testing.expectEqualStrings("Tech House", lib.byId(dlp.Genre, 2).?.name.?);
    try testing.expectEqualStrings("Cecille", lib.byId(dlp.Label, 1).?.name.?);
    try testing.expectEqualStrings("Genre", lib.byId(dlp.MyTag, 1).?.name.?);
    try testing.expectEqualStrings(
        "/PIONEER/Artwork/00001/b2.jpg",
        lib.byId(dlp.Image, 2).?.path.?,
    );
    try testing.expectEqual(@as(i64, 12900), lib.byId(dlp.Content, 2).?.bpmx100.?);
    // empty tables and the 0 = "no foreign key" convention
    try testing.expect(lib.byId(dlp.Key, 1) == null);
    try testing.expect(lib.byId(dlp.Content, 0) == null);
}

test "O2 keyed: junction groupings order, skip, and first-win" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openPlaintextFixtureDb(io, &tmp, alloc);
    defer db.close();

    // fixture order: sequenceNo 1, 2 -> contents 1, 2
    {
        var lib = try dlp.Library.load(alloc, db);
        defer lib.deinit();
        const entries = lib.playlist_contents_by_playlist.get(1).?;
        try testing.expectEqual(@as(usize, 2), entries.len);
        try testing.expectEqual(@as(i64, 1), lib.playlist_contents[entries[0]].content_id.?);
        try testing.expectEqual(@as(i64, 2), lib.playlist_contents[entries[1]].content_id.?);
        try testing.expect(lib.playlist_contents_by_playlist.get(2) == null);
        try testing.expectEqual(@as(u32, 0), lib.my_tag_contents_by_my_tag.count());
        try testing.expect(lib.hot_cue_bank_cues_by_list.count() == 0);
        try testing.expectEqual(@as(u32, 2), lib.content_by_path.count());
    }

    // shuffle the storage order: groups must order by sequenceNo (NULLs
    // last), NULL keys drop out, and duplicate paths first-win
    try db.exec(
        \\INSERT INTO playlist_content (playlist_id, content_id, sequenceNo)
        \\VALUES (1, 2, 0), (1, 1, NULL), (NULL, 1, 5);
        \\INSERT INTO content (content_id, path)
        \\VALUES (99, '/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3');
        \\
    );
    var lib = try dlp.Library.load(alloc, db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 5), lib.playlist_contents.len);
    const entries = lib.playlist_contents_by_playlist.get(1).?;
    try testing.expectEqual(@as(usize, 4), entries.len); // the NULL playlist_id row drops
    const got = [_]i64{
        lib.playlist_contents[entries[0]].content_id.?,
        lib.playlist_contents[entries[1]].content_id.?,
        lib.playlist_contents[entries[2]].content_id.?,
        lib.playlist_contents[entries[3]].content_id.?,
    };
    // sequenceNo 0, 1, 2, then the NULL sequenceNo last
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 1, 2, 1 }, &got);
    try testing.expectEqual(@as(u32, 2), lib.content_by_path.count()); // duplicate path skipped
    try testing.expectEqual(
        @as(i64, 2),
        lib.contentByPath(
            "/Contents/Reboot/www.electronicfresh.com/01. Reboot - Bako (Original Mix).mp3",
        ).?.content_id,
    );
}

// ---------------------------------------------------------------------------
// O3 write layer
// ---------------------------------------------------------------------------

/// The cwd-relative, NUL-terminated path of a file inside `tmp`.
fn tmpDbPath(tmp: *testing.TmpDir, alloc: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ tmp_path, name }, 0);
}

/// Compares two schemas as name-ordered (type, name, sql) triples — the
/// O3 acceptance's "schema diff empty modulo data".
fn expectSchemaEql(a: dlp.Db, b: dlp.Db) !void {
    const sql = "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name;";
    var sa = try a.prepare(sql);
    defer sa.finalize();
    var sb = try b.prepare(sql);
    defer sb.finalize();
    while (true) {
        const ra = try sa.step();
        const rb = try sb.step();
        try testing.expectEqual(ra, rb);
        if (ra == .done) break;
        for (0..3) |i| try testing.expectEqualStrings(sa.readText(i), sb.readText(i));
    }
}

/// Row-for-row, field-for-field equality of two loaded tables.
fn expectTableEql(comptime T: type, expected: []const T, actual: []const T) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |*e, *a| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const ev = @field(e, f.name);
            const av = @field(a, f.name);
            switch (f.type) {
                i64, ?i64 => try testing.expectEqual(ev, av),
                ?[]const u8 => if (ev) |s| {
                    try testing.expect(av != null);
                    try testing.expectEqualStrings(s, av.?);
                } else try testing.expect(av == null),
                else => @compileError("unexpected column type"),
            }
        }
    }
}

test "O3 create: schema diff vs the real fixture is empty" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    defer w.db.close();

    var fix_tmp = testing.tmpDir(.{});
    defer fix_tmp.cleanup();
    var fixture = try openPlaintextFixtureDb(io, &fix_tmp, alloc);
    defer fixture.close();

    try expectSchemaEql(w.db, fixture);
}

test "O3 create: seeded defaults and the property row" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{
        .plaintext = true,
        .created_date = "2026-07-16",
        .my_tag_master_dbid = 3168300669,
    });
    defer w.db.close();

    var lib = try dlp.Library.load(alloc, w.db);
    defer lib.deinit();

    var fix_tmp = testing.tmpDir(.{});
    defer fix_tmp.cleanup();
    var fixture = try openPlaintextFixtureDb(io, &fix_tmp, alloc);
    defer fixture.close();
    var fix_lib = try dlp.Library.load(alloc, fixture);
    defer fix_lib.deinit();

    try expectTableEql(dlp.Color, fix_lib.colors, lib.colors);
    try expectTableEql(dlp.MenuItem, fix_lib.menu_items, lib.menu_items);
    try expectTableEql(dlp.Category, fix_lib.categories, lib.categories);
    try expectTableEql(dlp.Sort, fix_lib.sorts, lib.sorts);

    // everything a fresh export leaves empty is empty
    try testing.expectEqual(@as(usize, 0), lib.contents.len);
    try testing.expectEqual(@as(usize, 0), lib.genres.len);
    try testing.expectEqual(@as(usize, 0), lib.artists.len);
    try testing.expectEqual(@as(usize, 0), lib.albums.len);
    try testing.expectEqual(@as(usize, 0), lib.playlists.len);
    try testing.expectEqual(@as(usize, 0), lib.my_tags.len);

    // the property singleton, fixture values in
    try testing.expectEqual(@as(i64, 0), try w.numberOfContents());
    const p = lib.property.?;
    try testing.expectEqualStrings("", p.deviceName.?);
    try testing.expectEqualStrings("10000", p.dbVersion.?);
    try testing.expectEqual(@as(i64, 0), p.numberOfContents.?);
    try testing.expectEqualStrings("2026-07-16", p.createdDate.?);
    try testing.expectEqual(@as(i64, 0), p.backGroundColorType.?);
    try testing.expectEqual(@as(i64, 3168300669), p.myTagMasterDBID.?);
}

test "O3 create: refuses to build over an existing db" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    try w.close();

    try testing.expectError(
        error.LibraryAlreadyExists,
        dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" }),
    );
}

test "O3 close: WAL header flag like rb exports, no sidecars left" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    // one written row, so the checkpoint has WAL frames to fold
    try w.db.exec("INSERT INTO content (content_id, path) VALUES (1, '/Contents/a.mp3');");
    try w.close();

    // the persisted WAL flag (header bytes 18/19: 2 = WAL, 1 = rollback)
    const raw = try tmp.dir.readFileAlloc(io, "ol.db", alloc, .limited(1 << 20));
    defer alloc.free(raw);
    try testing.expect(raw.len >= 100);
    try testing.expectEqual(@as(u8, 2), raw[18]);
    try testing.expectEqual(@as(u8, 2), raw[19]);

    // rb's exports carry no sidecars
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "ol.db-wal", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "ol.db-shm", .{}));

    // and the db reopens without a recovery dance
    var db = try dlp.Db.openPlaintext(io, db_path);
    defer db.close();
    try testing.expectEqual(@as(i64, 1), try db.scalarInt("SELECT COUNT(*) FROM content;"));
    try testing.expectEqualStrings("ok", try integrityCheck(db));
}

fn integrityCheck(db: dlp.Db) ![]const u8 {
    var stmt = try db.prepare("PRAGMA integrity_check;");
    defer stmt.finalize();
    try testing.expectEqual(.row, try stmt.step());
    return stmt.readText(0);
}

test "O3 round-trip: fixture models re-written into a fresh db are eql" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var fix_tmp = testing.tmpDir(.{});
    defer fix_tmp.cleanup();
    var fixture = try openPlaintextFixtureDb(io, &fix_tmp, alloc);
    defer fixture.close();
    var src = try dlp.Library.load(alloc, fixture);
    defer src.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{
        .plaintext = true,
        .created_date = "2026-07-16",
        .my_tag_master_dbid = 3168300669,
    });
    for (src.genres) |row| try w.insert(row);
    for (src.artists) |row| try w.insert(row);
    for (src.albums) |row| try w.insert(row);
    for (src.labels) |row| try w.insert(row);
    for (src.images) |row| try w.insert(row);
    for (src.playlists) |row| try w.insert(row);
    for (src.my_tags) |row| try w.insert(row);
    for (src.playlist_contents) |row| try w.insert(row);
    for (src.my_tag_contents) |row| try w.insert(row);
    for (src.contents) |row| try w.insertContent(row);
    try w.close();

    var db = try dlp.Db.openPlaintext(io, db_path);
    defer db.close();
    try testing.expectEqualStrings("ok", try integrityCheck(db));
    var dst = try dlp.Library.load(alloc, db);
    defer dst.deinit();
    try testing.expect(src.eql(&dst));
}

test "O3 mutate: numberOfContents maintenance on insert and delete" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    defer w.db.close();

    try testing.expectEqual(@as(i64, 0), try w.numberOfContents());
    try testing.expectEqual(@as(i64, 1), try w.nextId(dlp.Content));

    try w.insertContent(.{ .content_id = 1, .path = "/Contents/a.mp3" });
    try w.insertContent(.{ .content_id = 2, .path = "/Contents/b.mp3", .rating = 3 });
    try testing.expectEqual(@as(i64, 2), try w.numberOfContents());
    try testing.expectEqual(@as(i64, 3), try w.nextId(dlp.Content));

    try w.deleteContent(1);
    try testing.expectEqual(@as(i64, 1), try w.numberOfContents());
    try testing.expectEqual(@as(i64, 1), try w.db.scalarInt("SELECT COUNT(*) FROM content;"));
    // count-derived: matches the table, and the property stays a singleton
    try testing.expectEqual(@as(i64, 1), try w.db.scalarInt("SELECT COUNT(*) FROM property;"));
    // MAX+1 reuses a deleted last id, like SQLite's own rowid assignment
    try testing.expectEqual(@as(i64, 3), try w.nextId(dlp.Content));
}

test "O3 mutate: playlist append is dense and 1-based" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    defer w.db.close();

    try w.insertContent(.{ .content_id = 1, .path = "/Contents/a.mp3" });
    try w.insertContent(.{ .content_id = 2, .path = "/Contents/b.mp3" });

    try w.insert(dlp.Playlist{
        .playlist_id = try w.nextId(dlp.Playlist),
        .sequenceNo = 0,
        .name = "pl",
        .attribute = 0,
        .playlist_id_parent = 0,
    });
    try w.insert(dlp.Playlist{
        .playlist_id = try w.nextId(dlp.Playlist),
        .sequenceNo = 1,
        .name = "other",
        .attribute = 0,
        .playlist_id_parent = 0,
    });

    // real exports number playlist entries from 1, dense per playlist
    try testing.expectEqual(@as(i64, 1), try w.addContentToPlaylist(1, 1));
    try testing.expectEqual(@as(i64, 2), try w.addContentToPlaylist(1, 2));
    try testing.expectEqual(@as(i64, 1), try w.addContentToPlaylist(2, 1));

    var lib = try dlp.Library.load(alloc, w.db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 3), lib.playlist_contents.len);
    const entries = lib.playlist_contents_by_playlist.get(1).?;
    try testing.expectEqual(@as(i64, 1), lib.playlist_contents[entries[0]].sequenceNo.?);
    try testing.expectEqual(@as(i64, 2), lib.playlist_contents[entries[1]].sequenceNo.?);
}

test "O3 mutate: insertAll batches rows atomically through one statement" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    defer w.db.close();

    try w.insertAll(&.{
        dlp.Artist{ .artist_id = 1, .name = "A" },
        dlp.Artist{ .artist_id = 2, .name = "B" },
        dlp.Artist{ .artist_id = 3, .name = "C" },
    });
    // a Content batch maintains numberOfContents once, like insertContent
    try w.insertAll(&.{
        dlp.Content{ .content_id = 1, .path = "/Contents/a.mp3" },
        dlp.Content{ .content_id = 2, .path = "/Contents/b.mp3" },
    });
    try testing.expectEqual(@as(i64, 2), try w.numberOfContents());
    try testing.expectEqual(@as(i64, 4), try w.nextId(dlp.Artist));

    var lib = try dlp.Library.load(alloc, w.db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 3), lib.artists.len);
    try testing.expectEqualStrings("B", lib.byId(dlp.Artist, 2).?.name.?);

    // a duplicate key rolls the whole batch back
    try testing.expectError(error.Sqlite, w.insertAll(&.{
        dlp.Artist{ .artist_id = 4, .name = "D" },
        dlp.Artist{ .artist_id = 4, .name = "D again" },
    }));
    try testing.expectEqual(@as(i64, 3), w.db.scalarInt("SELECT COUNT(*) FROM artist;"));
    try testing.expectEqual(@as(i64, 4), try w.nextId(dlp.Artist));
}

test "O3 mutate: addAllToPlaylist batches dense appends through one statement" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    var w = try dlp.Writer.create(io, db_path, .{ .plaintext = true, .created_date = "2026-08-23" });
    defer w.db.close();

    try w.insertAll(&.{
        dlp.Content{ .content_id = 1, .path = "/Contents/a.mp3" },
        dlp.Content{ .content_id = 2, .path = "/Contents/b.mp3" },
        dlp.Content{ .content_id = 3, .path = "/Contents/c.mp3" },
    });
    try w.insertAll(&.{
        dlp.Playlist{ .playlist_id = 1, .sequenceNo = 0, .name = "pl", .attribute = 0, .playlist_id_parent = 0 },
        dlp.Playlist{ .playlist_id = 2, .sequenceNo = 1, .name = "other", .attribute = 0, .playlist_id_parent = 0 },
    });

    // The batch continues past a row already on disk, then stays dense
    // per playlist — the ordinals addContentToPlaylist would assign.
    _ = try w.addContentToPlaylist(1, 1);
    const Pair = struct { playlist_id: i64, content_id: i64 };
    try w.addAllToPlaylist(&[_]Pair{
        .{ .playlist_id = 1, .content_id = 2 },
        .{ .playlist_id = 1, .content_id = 3 },
        .{ .playlist_id = 2, .content_id = 1 },
    });

    var lib = try dlp.Library.load(alloc, w.db);
    defer lib.deinit();
    try testing.expectEqual(@as(usize, 4), lib.playlist_contents.len);
    const pl1 = lib.playlist_contents_by_playlist.get(1).?;
    try testing.expectEqual(@as(i64, 1), lib.playlist_contents[pl1[0]].sequenceNo.?);
    try testing.expectEqual(@as(i64, 2), lib.playlist_contents[pl1[1]].sequenceNo.?);
    try testing.expectEqual(@as(i64, 3), lib.playlist_contents[pl1[2]].sequenceNo.?);
    const pl2 = lib.playlist_contents_by_playlist.get(2).?;
    try testing.expectEqual(@as(i64, 1), lib.playlist_contents[pl2[0]].sequenceNo.?);
}

test "O3 create: keyed db is encrypted and reopens through the provider" {
    if (dlp.mode != .vendored) return;
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try tmpDbPath(&tmp, alloc, "ol.db");
    defer alloc.free(db_path);
    {
        var w = try dlp.Writer.create(io, db_path, .{ .created_date = "2026-08-23" });
        try w.insertContent(.{ .content_id = 1, .path = "/Contents/a.mp3" });
        try w.close();
    }

    // page 1 starts with the plaintext salt, never the SQLite magic
    const raw = try tmp.dir.readFileAlloc(io, "ol.db", alloc, .limited(1 << 20));
    defer alloc.free(raw);
    try testing.expect(raw.len >= 4096);
    try testing.expect(!std.mem.eql(u8, raw[0..16], "SQLite format 3\x00"));

    var w = try dlp.Writer.open(io, db_path);
    defer w.db.close();
    try testing.expectEqual(@as(i64, 1), try w.numberOfContents());
    try testing.expectEqualStrings("ok", try integrityCheck(w.db));
}
