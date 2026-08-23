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
    const image = try testutil.readFixture(
        alloc,
        "complete_export/with_anlz/PIONEER/rekordbox/exportLibrary.db",
        .limited(1 << 20),
    );
    defer alloc.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "exportLibrary.db", .data = image });
    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(tmp_path);
    const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/exportLibrary.db", .{tmp_path}, 0);
    defer alloc.free(db_path);
    return dlp.Db.open(io, db_path);
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
