// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! OneLibrary / DeviceLibraryPlus storage (`exportLibrary.db`).
//!
//! The db is SQLCipher v4 defaults in passphrase mode; the SQLCipher
//! amalgamation (vendored under `vendor/sqlcipher/`, see its README) provides
//! the b-tree engine and this module provides everything else:
//!
//! * the crypto provider — implemented over `std.crypto` and registered
//!   through SQLCipher's documented `SQLCIPHER_CRYPTO_CUSTOM` hook, so no
//!   third-party crypto C is vendored;
//! * a thin SQLite wrapper (the "A candidate" of the O1 spike) over the
//!   symbol-renamed C API;
//! * the read models (`Library`): every row of the 22 OneLibrary tables,
//!   schema-pinned and arena-owned, with keyed access for the joins the
//!   device reader needs.
//!
//! Build modes (`-Ddlp=off|vendored|system`): `off` compiles this module's
//! types away from the binary (every runtime entry point is guarded by a
//! comptime `@compileError`); `vendored` compiles the prefixed amalgamation
//! with zig cc; `system` binds the consumer's own unprefixed SQLCipher.

const std = @import("std");
const opts = @import("options");
const c = @import("c");

/// The build mode (`-Ddlp`), comptime-known; compare with `.off`/`.vendored`/
/// `.system` literals.
pub const mode = opts.dlp;

fn dlpDisabled() noreturn {
    @compileError("rekordlib was built with -Ddlp=off; rebuild with -Ddlp=vendored (or =system) to use the OneLibrary store");
}

/// The symbols differ per mode: the vendored build renames every
/// `sqlite3_*`/`sqlcipher_*` export to `rl_sqlite3_*` (decision 10) —
/// including the `sqlite3_stmt` typedef — the system build binds the
/// consumer's own unprefixed SQLCipher, and `off` translates the renamed
/// header without compiling any C. One comptime prefix resolves every
/// binding through both headers; the dead branch of the mode switch is
/// not analyzed, so only the referenced set is emitted.
const prefix: []const u8 = switch (mode) {
    .system => "",
    .off, .vendored => "rl_",
};

/// Declaration lookup under the mode's prefix: `cfn("sqlite3_open_v2")`
/// resolves `rl_sqlite3_open_v2` in off/vendored builds and
/// `sqlite3_open_v2` in system builds.
fn cfn(comptime name: []const u8) @TypeOf(@field(c, prefix ++ name)) {
    return @field(c, prefix ++ name);
}

/// The statement handle type, renamed in the vendored header.
const cStmt = @field(c, prefix ++ "sqlite3_stmt");

const api = switch (mode) {
    .off => {},
    else => struct {
        const open_v2 = cfn("sqlite3_open_v2");
        const close_v2 = cfn("sqlite3_close_v2");
        const errmsg = cfn("sqlite3_errmsg");
        const exec = cfn("sqlite3_exec");
        const prepare_v2 = cfn("sqlite3_prepare_v2");
        const finalize = cfn("sqlite3_finalize");
        const step = cfn("sqlite3_step");
        const reset = cfn("sqlite3_reset");
        const clear_bindings = cfn("sqlite3_clear_bindings");
        const column_count = cfn("sqlite3_column_count");
        const column_name = cfn("sqlite3_column_name");
        const column_type = cfn("sqlite3_column_type");
        const column_int64 = cfn("sqlite3_column_int64");
        const column_double = cfn("sqlite3_column_double");
        const column_text = cfn("sqlite3_column_text");
        const column_blob = cfn("sqlite3_column_blob");
        const column_bytes = cfn("sqlite3_column_bytes");
        const bind_null = cfn("sqlite3_bind_null");
        const bind_int64 = cfn("sqlite3_bind_int64");
        const bind_double = cfn("sqlite3_bind_double");
        const bind_text = cfn("sqlite3_bind_text");
        const bind_blob = cfn("sqlite3_bind_blob");
        const last_insert_rowid = cfn("sqlite3_last_insert_rowid");
        const changes = cfn("sqlite3_changes");
        const libversion = cfn("sqlite3_libversion");
    },
};

// ---------------------------------------------------------------------------
// Crypto provider (SQLCIPHER_CRYPTO_CUSTOM over std.crypto)
// ---------------------------------------------------------------------------

const SQLCIPHER_DECRYPT: c_int = 0;
const SQLCIPHER_ENCRYPT: c_int = 1;

const SQLCIPHER_HMAC_SHA1: c_int = 0;
const SQLCIPHER_HMAC_SHA256: c_int = 1;
const SQLCIPHER_HMAC_SHA512: c_int = 2;

/// Mirrors `struct sqlcipher_provider` from sqlcipher.h.
pub const Provider = extern struct {
    init: ?*const fn () callconv(.c) c_int = null,
    shutdown: ?*const fn () callconv(.c) void = null,
    get_provider_name: *const fn (?*anyopaque) callconv(.c) [*:0]const u8,
    add_random: *const fn (?*anyopaque, ?[*]const u8, c_int) callconv(.c) c_int,
    random: *const fn (?*anyopaque, ?[*]u8, c_int) callconv(.c) c_int,
    hmac: *const fn (?*anyopaque, c_int, ?[*]const u8, c_int, ?[*]const u8, c_int, ?[*]const u8, c_int, ?[*]u8) callconv(.c) c_int,
    kdf: *const fn (?*anyopaque, c_int, ?[*]const u8, c_int, ?[*]const u8, c_int, c_int, c_int, ?[*]u8) callconv(.c) c_int,
    cipher: *const fn (?*anyopaque, c_int, ?[*]const u8, c_int, ?[*]const u8, ?[*]const u8, c_int, ?[*]u8) callconv(.c) c_int,
    get_cipher: *const fn (?*anyopaque) callconv(.c) [*:0]const u8,
    get_key_sz: *const fn (?*anyopaque) callconv(.c) c_int,
    get_iv_sz: *const fn (?*anyopaque) callconv(.c) c_int,
    get_block_sz: *const fn (?*anyopaque) callconv(.c) c_int,
    get_hmac_sz: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    ctx_init: *const fn (*?*anyopaque) callconv(.c) c_int,
    ctx_free: *const fn (*?*anyopaque) callconv(.c) c_int,
    fips_status: *const fn (?*anyopaque) callconv(.c) c_int,
    get_provider_version: *const fn (?*anyopaque) callconv(.c) [*:0]const u8,
    next: ?*Provider = null,
};

/// OS entropy source for salt/IV generation. The C provider callback carries
/// no context pointer we control, so the wrapper installs its `std.Io` here
/// (`Db.open` does it); the bundled SQLCipher providers solve this the same
/// way with global state behind SQLCIPHER_MUTEX_PROVIDER_RAND.
var io_source: ?std.Io = null;

fn providerHmac(
    ctx: ?*anyopaque,
    algorithm: c_int,
    hmac_key: ?[*]const u8,
    key_sz: c_int,
    in: ?[*]const u8,
    in_sz: c_int,
    in2: ?[*]const u8,
    in2_sz: c_int,
    out: ?[*]u8,
) callconv(.c) c_int {
    _ = ctx;
    const key = hmac_key.?[0..@intCast(key_sz)];
    const buf1 = if (in) |p| p[0..@intCast(in_sz)] else &[_]u8{};
    const buf2 = if (in2) |p| p[0..@intCast(in2_sz)] else &[_]u8{};

    switch (algorithm) {
        // page hmacs: HMAC-SHA512(hmac_key, ciphertext+IV || LE page number)
        SQLCIPHER_HMAC_SHA512 => mac(std.crypto.auth.hmac.sha2.HmacSha512, key, buf1, buf2, out.?),
        SQLCIPHER_HMAC_SHA256 => mac(std.crypto.auth.hmac.sha2.HmacSha256, key, buf1, buf2, out.?),
        SQLCIPHER_HMAC_SHA1 => mac(std.crypto.auth.hmac.HmacSha1, key, buf1, buf2, out.?),
        else => return c.SQLITE_ERROR,
    }
    return c.SQLITE_OK;
}

fn mac(comptime Hmac: type, key: []const u8, buf1: []const u8, buf2: []const u8, out: [*]u8) void {
    var h = Hmac.init(key);
    h.update(buf1);
    if (buf2.len > 0) h.update(buf2);
    var digest: [Hmac.mac_length]u8 = undefined;
    h.final(&digest);
    @memcpy(out[0..digest.len], &digest);
}

fn kdfPbkdf2(comptime Hash: type, password: []const u8, salt: []const u8, rounds: u32, out: []u8) c_int {
    std.crypto.pwhash.pbkdf2(out, password, salt, rounds, std.crypto.auth.hmac.Hmac(Hash)) catch return c.SQLITE_ERROR;
    return c.SQLITE_OK;
}

fn providerKdf(
    ctx: ?*anyopaque,
    algorithm: c_int,
    pass: ?[*]const u8,
    pass_sz: c_int,
    salt: ?[*]const u8,
    salt_sz: c_int,
    workfactor: c_int,
    key_sz: c_int,
    key: ?[*]u8,
) callconv(.c) c_int {
    _ = ctx;
    const p = pass.?[0..@intCast(pass_sz)];
    const s = salt.?[0..@intCast(salt_sz)];
    const k = key.?[0..@intCast(key_sz)];
    const rounds: u32 = @intCast(workfactor);
    return switch (algorithm) {
        // v4 default: key = PBKDF2-HMAC-SHA512(passphrase, salt, 256000)
        2 => kdfPbkdf2(std.crypto.hash.sha2.Sha512, p, s, rounds, k),
        1 => kdfPbkdf2(std.crypto.hash.sha2.Sha256, p, s, rounds, k),
        0 => kdfPbkdf2(std.crypto.hash.Sha1, p, s, rounds, k),
        else => c.SQLITE_ERROR,
    };
}

/// AES-256-CBC over a whole number of 16-byte blocks (pages are).
fn providerCipher(
    ctx: ?*anyopaque,
    enc: c_int,
    key: ?[*]const u8,
    key_sz: c_int,
    iv: ?[*]const u8,
    in: ?[*]const u8,
    in_sz: c_int,
    out: ?[*]u8,
) callconv(.c) c_int {
    _ = ctx;
    if (key_sz != 32) return c.SQLITE_ERROR;
    if (@rem(in_sz, 16) != 0) return c.SQLITE_ERROR;
    const k: [32]u8 = key.?[0..32].*;
    const init_vec: [16]u8 = iv.?[0..16].*;
    const src = in.?[0..@intCast(in_sz)];
    const dst = out.?[0..@intCast(in_sz)];

    if (enc == SQLCIPHER_ENCRYPT) {
        const aes = std.crypto.core.aes.Aes256.initEnc(k);
        var chain = init_vec;
        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            var block: [16]u8 = undefined;
            for (0..16) |j| block[j] = src[i + j] ^ chain[j];
            aes.encrypt(dst[i..][0..16], &block);
            chain = dst[i..][0..16].*;
        }
    } else {
        const aes = std.crypto.core.aes.Aes256.initDec(k);
        var chain = init_vec;
        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            var plain: [16]u8 = undefined;
            aes.decrypt(&plain, src[i..][0..16]);
            for (0..16) |j| dst[i + j] = plain[j] ^ chain[j];
            chain = src[i..][0..16].*;
        }
    }
    return c.SQLITE_OK;
}

fn providerAddRandom(ctx: ?*anyopaque, buffer: ?[*]const u8, length: c_int) callconv(.c) c_int {
    _ = ctx;
    _ = buffer;
    _ = length;
    return c.SQLITE_OK;
}

fn providerRandom(ctx: ?*anyopaque, buffer: ?[*]u8, length: c_int) callconv(.c) c_int {
    _ = ctx;
    if (length < 0) return c.SQLITE_ERROR;
    const buf = buffer.?[0..@intCast(length)];
    if (io_source) |io| {
        io.random(buf);
        return c.SQLITE_OK;
    }
    return c.SQLITE_ERROR;
}

fn providerGetName(ctx: ?*anyopaque) callconv(.c) [*:0]const u8 {
    _ = ctx;
    return "zig-std-crypto";
}

fn providerGetCipher(ctx: ?*anyopaque) callconv(.c) [*:0]const u8 {
    _ = ctx;
    return "aes-256-cbc";
}

fn providerGetKeySz(ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    return 32;
}

fn providerGetIvSz(ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    return 16;
}

fn providerGetBlockSz(ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    return 16;
}

fn providerGetHmacSz(ctx: ?*anyopaque, algorithm: c_int) callconv(.c) c_int {
    _ = ctx;
    return switch (algorithm) {
        SQLCIPHER_HMAC_SHA1 => 20,
        SQLCIPHER_HMAC_SHA256 => 32,
        SQLCIPHER_HMAC_SHA512 => 64,
        else => 0,
    };
}

fn providerCtxInit(ctx: *?*anyopaque) callconv(.c) c_int {
    ctx.* = null;
    return c.SQLITE_OK;
}

fn providerCtxFree(ctx: *?*anyopaque) callconv(.c) c_int {
    ctx.* = null;
    return c.SQLITE_OK;
}

fn providerFipsStatus(ctx: ?*anyopaque) callconv(.c) c_int {
    _ = ctx;
    return 0;
}

fn providerGetVersion(ctx: ?*anyopaque) callconv(.c) [*:0]const u8 {
    _ = ctx;
    return "std.crypto";
}

/// Called by the amalgamation at library init (SQLITE_EXTRA_INIT ->
/// sqlcipher_extra_init -> SQLCIPHER_PROVIDER_SETUP) because the vendored
/// build defines SQLCIPHER_CRYPTO_CUSTOM=rl_sqlcipher_zig_provider_setup.
/// In `system` mode the consumer's own provider is used instead and this
/// export is unreferenced.
pub export fn rl_sqlcipher_zig_provider_setup(p: *Provider) c_int {
    p.* = .{
        .init = null,
        .shutdown = null,
        .get_provider_name = providerGetName,
        .add_random = providerAddRandom,
        .random = providerRandom,
        .hmac = providerHmac,
        .kdf = providerKdf,
        .cipher = providerCipher,
        .get_cipher = providerGetCipher,
        .get_key_sz = providerGetKeySz,
        .get_iv_sz = providerGetIvSz,
        .get_block_sz = providerGetBlockSz,
        .get_hmac_sz = providerGetHmacSz,
        .ctx_init = providerCtxInit,
        .ctx_free = providerCtxFree,
        .fips_status = providerFipsStatus,
        .get_provider_version = providerGetVersion,
        .next = null,
    };
    return c.SQLITE_OK;
}

// ---------------------------------------------------------------------------
// SQLite wrapper (O1 candidate A)
// ---------------------------------------------------------------------------

/// rbox 0.1.5 `conn.rs` MAGIC with each byte decremented (plan Phase O).
pub const passphrase = "r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls";

pub const SqlError = error{ Sqlite, OutOfMemory };

pub const StepResult = enum { row, done };

/// One prepared statement over an open `Db`. Borrowed: finalizing returns
/// it to the caller's discipline (the `deinit`-style call is `finalize`).
pub const Stmt = struct {
    handle: *cStmt,

    pub fn step(self: Stmt) SqlError!StepResult {
        return switch (api.step(self.handle)) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => error.Sqlite,
        };
    }

    pub fn finalize(self: Stmt) void {
        _ = api.finalize(self.handle);
    }

    pub fn reset(self: Stmt) SqlError!void {
        if (api.reset(self.handle) != c.SQLITE_OK) return error.Sqlite;
        _ = api.clear_bindings(self.handle);
    }

    pub fn columnCount(self: Stmt) usize {
        return @intCast(api.column_count(self.handle));
    }

    /// Borrowed for the lifetime of the statement.
    pub fn columnName(self: Stmt, i: usize) [:0]const u8 {
        const name = api.column_name(self.handle, @intCast(i));
        return std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    }

    pub fn isNull(self: Stmt, i: usize) bool {
        return api.column_type(self.handle, @intCast(i)) == c.SQLITE_NULL;
    }

    pub fn readInt(self: Stmt, i: usize) i64 {
        return api.column_int64(self.handle, @intCast(i));
    }

    pub fn readFloat(self: Stmt, i: usize) f64 {
        return api.column_double(self.handle, @intCast(i));
    }

    /// UTF-8 text, borrowed for the lifetime of the statement.
    pub fn readText(self: Stmt, i: usize) []const u8 {
        const ptr = api.column_text(self.handle, @intCast(i)) orelse return &[_]u8{};
        const len: usize = @intCast(api.column_bytes(self.handle, @intCast(i)));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    /// Blob bytes, borrowed for the lifetime of the statement.
    pub fn readBlob(self: Stmt, i: usize) []const u8 {
        const ptr = api.column_blob(self.handle, @intCast(i)) orelse return &[_]u8{};
        const len: usize = @intCast(api.column_bytes(self.handle, @intCast(i)));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn bindNull(self: Stmt, i: usize) SqlError!void {
        if (api.bind_null(self.handle, @intCast(i)) != c.SQLITE_OK) return error.Sqlite;
    }

    pub fn bindInt(self: Stmt, i: usize, v: i64) SqlError!void {
        if (api.bind_int64(self.handle, @intCast(i), v) != c.SQLITE_OK) return error.Sqlite;
    }

    pub fn bindFloat(self: Stmt, i: usize, v: f64) SqlError!void {
        if (api.bind_double(self.handle, @intCast(i), v) != c.SQLITE_OK) return error.Sqlite;
    }

    /// `text` is copied by SQLite before the call returns (SQLITE_TRANSIENT).
    pub fn bindText(self: Stmt, i: usize, text: []const u8) SqlError!void {
        const rc = api.bind_text(self.handle, @intCast(i), text.ptr, @intCast(text.len), sqlite_transient());
        if (rc != c.SQLITE_OK) return error.Sqlite;
    }

    /// `blob` is copied by SQLite before the call returns (SQLITE_TRANSIENT).
    pub fn bindBlob(self: Stmt, i: usize, blob: []const u8) SqlError!void {
        const rc = api.bind_blob(self.handle, @intCast(i), blob.ptr, @intCast(blob.len), sqlite_transient());
        if (rc != c.SQLITE_OK) return error.Sqlite;
    }
};

/// The value SQLite's headers call SQLITE_TRANSIENT (-1 cast to the
/// destructor type): tell SQLite to copy the bound memory.
fn sqlite_transient() ?*const fn (?*anyopaque) callconv(.c) void {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
}

/// An open, keyed OneLibrary database. `open` reads (recovering WAL state),
/// `openReadWriteCreate` also creates - both apply the DLP passphrase.
pub const Db = struct {
    handle: *c.sqlite3,

    const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    const SQLITE_OPEN_CREATE: c_int = 0x00000004;

    pub const OpenError = SqlError;

    /// `io` seeds the crypto provider's entropy source (salt/IV generation
    /// on write); read-only sessions never draw from it.
    pub fn open(io: std.Io, path: [:0]const u8) OpenError!Db {
        if (mode == .off) dlpDisabled();
        return openFlags(io, path, SQLITE_OPEN_READWRITE, true);
    }

    pub fn openReadWriteCreate(io: std.Io, path: [:0]const u8) OpenError!Db {
        if (mode == .off) dlpDisabled();
        return openFlags(io, path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, true);
    }

    /// Opens a db without applying the DLP passphrase: plaintext fixtures
    /// (`testdata/dlp/`) and consumer-written plain SQLite files. SQLCipher
    /// reads an unkeyed plaintext file exactly like stock SQLite.
    pub fn openPlaintext(io: std.Io, path: [:0]const u8) OpenError!Db {
        if (mode == .off) dlpDisabled();
        return openFlags(io, path, SQLITE_OPEN_READWRITE, false);
    }

    fn openFlags(io: std.Io, path: [:0]const u8, flags: c_int, keyed: bool) OpenError!Db {
        if (mode == .off) dlpDisabled();
        io_source = io;
        var handle: ?*c.sqlite3 = null;
        const rc = api.open_v2(path.ptr, &handle, flags, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = api.close_v2(h);
            return error.Sqlite;
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        if (!keyed) return db;
        // key before any page read; the WAL-persisted fixture needs the
        // read-write open above to recover without sidecar files present
        const key_sql = "PRAGMA key = '" ++ passphrase ++ "';";
        try db.exec(key_sql);
        return db;
    }

    pub fn close(self: Db) void {
        _ = api.close_v2(self.handle);
    }

    /// Last error message, borrowed from the handle.
    pub fn lastError(self: Db) [:0]const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(api.errmsg(self.handle))));
    }

    pub fn exec(self: Db, sql: [:0]const u8) SqlError!void {
        if (api.exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) return error.Sqlite;
    }

    pub fn prepare(self: Db, sql: [:0]const u8) SqlError!Stmt {
        var stmt: ?*cStmt = null;
        const rc = api.prepare_v2(self.handle, sql.ptr, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.Sqlite;
        return .{ .handle = stmt.? };
    }

    /// Convenience one-shot scalar (COUNT(*) etc.).
    pub fn scalarInt(self: Db, sql: [:0]const u8) SqlError!i64 {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step() != .row) return error.Sqlite;
        return stmt.readInt(0);
    }

    pub fn lastInsertRowid(self: Db) i64 {
        return api.last_insert_rowid(self.handle);
    }

    pub fn changes(self: Db) i64 {
        return api.changes(self.handle);
    }
};

pub fn sqliteVersion() [:0]const u8 {
    if (mode == .off) dlpDisabled();
    return std.mem.span(@as([*:0]const u8, @ptrCast(api.libversion())));
}

// ---------------------------------------------------------------------------
// OneLibrary read models (O2)
// ---------------------------------------------------------------------------

/// Loading error of `Library.load`: the SQLite wrapper's errors plus the
/// schema-shape validation (`SchemaMismatch`: a table's column count or
/// column names differ from the pinned schema — the OneLibrary analog of
/// the pdb `constant_fields` asserts).
pub const LoadError = SqlError || error{SchemaMismatch};

/// An `album` row. `isComplation` [sic] is Pioneer's typo, kept verbatim
/// from the real schema.
pub const Album = struct {
    album_id: i64,
    name: ?[]const u8,
    artist_id: ?i64,
    image_id: ?i64,
    isComplation: ?i64,
    nameForSearch: ?[]const u8,
};

/// An `artist` row; shared by the five content artist roles through the
/// `artist_id_<role>` foreign keys.
pub const Artist = struct {
    artist_id: i64,
    name: ?[]const u8,
    nameForSearch: ?[]const u8,
};

/// A `category` row: links a browse category to its `menuItem` column.
pub const Category = struct {
    category_id: i64,
    menuItem_id: ?i64,
    sequenceNo: ?i64,
    isVisible: ?i64,
};

/// A `color` row: the eight fixed track colors.
pub const Color = struct {
    color_id: i64,
    name: ?[]const u8,
};

/// A `content` row: one track. The central table of the db — every other
/// track-related table references it by `content_id`, and the pdb side
/// joins by `path` (the two id spaces are independent). Facts pinned by
/// the with_anlz fixture: `path` is device-root-absolute (`/Contents/...`),
/// `analysisDataFilePath` is root-absolute to the track's ANLZ `.DAT`,
/// `contentLink` = 788 224 = the pdb Track bitmask `0x000C0700`,
/// `analysedBits` = 41 = the pdb Track `unknown5`, and the artist foreign
/// keys are named `artist_id_<role>` (`djPlayCount` and
/// `artist_id_originalArtist` are missing from the rbox 0.1.5 model — see
/// the upstream-report checklist in PLAN.md).
pub const Content = struct {
    content_id: i64,
    title: ?[]const u8,
    titleForSearch: ?[]const u8,
    subtitle: ?[]const u8,
    bpmx100: ?i64,
    length: ?i64,
    trackNo: ?i64,
    discNo: ?i64,
    artist_id_artist: ?i64,
    artist_id_remixer: ?i64,
    artist_id_originalArtist: ?i64,
    artist_id_composer: ?i64,
    artist_id_lyricist: ?i64,
    album_id: ?i64,
    genre_id: ?i64,
    label_id: ?i64,
    key_id: ?i64,
    color_id: ?i64,
    image_id: ?i64,
    djComment: ?[]const u8,
    rating: ?i64,
    releaseYear: ?i64,
    releaseDate: ?[]const u8,
    dateCreated: ?[]const u8,
    dateAdded: ?[]const u8,
    path: ?[]const u8,
    fileName: ?[]const u8,
    fileSize: ?i64,
    fileType: ?i64,
    bitrate: ?i64,
    bitDepth: ?i64,
    samplingRate: ?i64,
    isrc: ?[]const u8,
    djPlayCount: ?i64,
    isHotCueAutoLoadOn: ?i64,
    isKuvoDeliverStatusOn: ?i64,
    kuvoDeliveryComment: ?[]const u8,
    masterDbId: ?i64,
    masterContentId: ?i64,
    analysisDataFilePath: ?[]const u8,
    analysedBits: ?i64,
    contentLink: ?i64,
    hasModified: ?i64,
    cueUpdateCount: ?i64,
    analysisDataUpdateCount: ?i64,
    informationUpdateCount: ?i64,
};

/// A `cue` row: one point or loop of one track (`content_id`), or of a hot
/// cue bank (through `hotCueBankList_cue`). Every position is stored four
/// ways — microseconds, 150-fps analysis frames, MPEG frames, and sample
/// block offsets (`inFileOffsetInBlock` is lowercase but
/// `OutFileOffsetInBlock` capitalized, both verbatim). Fresh exports carry
/// no cue rows.
pub const Cue = struct {
    cue_id: i64,
    content_id: ?i64,
    kind: ?i64,
    colorTableIndex: ?i64,
    cueComment: ?[]const u8,
    isActiveLoop: ?i64,
    beatLoopNumerator: ?i64,
    beatLoopDenominator: ?i64,
    inUsec: ?i64,
    outUsec: ?i64,
    in150FramePerSec: ?i64,
    out150FramePerSec: ?i64,
    inMpegFrameNumber: ?i64,
    outMpegFrameNumber: ?i64,
    inMpegAbs: ?i64,
    outMpegAbs: ?i64,
    inDecodingStartFramePosition: ?i64,
    outDecodingStartFramePosition: ?i64,
    inFileOffsetInBlock: ?i64,
    OutFileOffsetInBlock: ?i64,
    inNumberOfSampleInBlock: ?i64,
    outNumberOfSampleInBlock: ?i64,
};

/// A `genre` row: the db's copy of the pdb genre table.
pub const Genre = struct {
    genre_id: i64,
    name: ?[]const u8,
};

/// A `history` row: one play-history session (parent 0 = root). Empty in
/// fresh exports; entries live in `history_content`.
pub const History = struct {
    history_id: i64,
    sequenceNo: ?i64,
    name: ?[]const u8,
    attribute: ?i64,
    history_id_parent: ?i64,
};

/// A `history_content` row: one track of one history session.
pub const HistoryContent = struct {
    history_id: ?i64,
    content_id: ?i64,
    sequenceNo: ?i64,
};

/// A `hotCueBankList` row: one hot cue bank (parent 0 = root); its cues
/// link through `hotCueBankList_cue`. Empty in fresh exports.
pub const HotCueBankList = struct {
    hotCueBankList_id: i64,
    sequenceNo: ?i64,
    name: ?[]const u8,
    image_id: ?i64,
    attribute: ?i64,
    hotCueBankList_id_parent: ?i64,
};

/// A `hotCueBankList_cue` row: one cue of one bank.
pub const HotCueBankListCue = struct {
    hotCueBankList_id: ?i64,
    cue_id: ?i64,
    sequenceNo: ?i64,
};

/// An `image` row: artwork referenced by content, playlist, and album
/// rows. `path` is the `b{id}.jpg` variant under the same
/// `{id/20+1:05}` shard as the pdb's `a{id}.jpg` thumbnails.
pub const Image = struct {
    image_id: i64,
    path: ?[]const u8,
};

/// A `key` row: a musical key name; id 0 = no key (the port's FK
/// convention). The fixture's table is empty — its two tracks carry
/// `key_id` 0.
pub const Key = struct {
    key_id: i64,
    name: ?[]const u8,
};

/// A `label` row.
pub const Label = struct {
    label_id: i64,
    name: ?[]const u8,
};

/// A `menuItem` row: a browse column header (27 in the fixture), named
/// with the same `\u{fffa}`/`\u{fffb}` interlinear-annotation wrapping as
/// the pdb Menu rows.
pub const MenuItem = struct {
    menuItem_id: i64,
    kind: ?i64,
    name: ?[]const u8,
};

/// A `myTag` row: the db's copy of the my-tag tree mirrored in
/// `exportExt.pdb`'s Tag rows. `attribute` 1 = column (container), 0 =
/// leaf — the same bit the ext pdb stores as `raw_is_category << 24`;
/// parent 0 = root; ids are random-looking u32s like ext tag ids.
pub const MyTag = struct {
    myTag_id: i64,
    sequenceNo: ?i64,
    name: ?[]const u8,
    attribute: ?i64,
    myTag_id_parent: ?i64,
};

/// A `myTag_content` row: track-to-tag junction; unlike the other
/// junctions it carries no `sequenceNo`.
pub const MyTagContent = struct {
    myTag_id: ?i64,
    content_id: ?i64,
};

/// A `playlist` row: one node of the playlist tree mirrored in the pdb
/// (`playlist_id_parent` 0 = root; the fixture's single leaf carries
/// `attribute` 0).
pub const Playlist = struct {
    playlist_id: i64,
    sequenceNo: ?i64,
    name: ?[]const u8,
    image_id: ?i64,
    attribute: ?i64,
    playlist_id_parent: ?i64,
};

/// A `playlist_content` row: playlist membership; `sequenceNo` is dense
/// and 1-based in the fixture.
pub const PlaylistContent = struct {
    playlist_id: ?i64,
    content_id: ?i64,
    sequenceNo: ?i64,
};

/// The `property` row — a singleton; real exports carry exactly one.
/// `dbVersion` is a varchar holding `'10000'` (rbox models an INTEGER
/// defaulting to 1000 — drift, see the checklist); `deviceName` is the
/// empty string in exports; `myTagMasterDBID` derives from the master db
/// and writers may leave 0.
pub const Property = struct {
    deviceName: ?[]const u8,
    dbVersion: ?[]const u8,
    numberOfContents: ?i64,
    createdDate: ?[]const u8,
    backGroundColorType: ?i64,
    myTagMasterDBID: ?i64,
};

/// A `recommendedLike` row: a liked-track relation between two contents.
/// `createdDate` is an INTEGER here (rbox models TEXT — drift, see the
/// checklist).
pub const RecommendedLike = struct {
    content_id_1: ?i64,
    content_id_2: ?i64,
    rating: ?i64,
    createdDate: ?i64,
};

/// A `sort` row: the track-list column layout over `menuItem_id`.
/// `sort_id` is 0-based (fixture rows run 0..16).
pub const Sort = struct {
    sort_id: i64,
    menuItem_id: ?i64,
    sequenceNo: ?i64,
    isVisible: ?i64,
    isSelectedAsSubColumn: ?i64,
};

/// Every loaded table except `property` (a singleton loaded by hand):
/// row type, SQL table name, and the `Library` field the rows land in.
/// Field order is schema order — `loadTable` validates every column name
/// against it.
const row_tables = .{
    .{ .row = Album, .table = "album", .rows = "albums" },
    .{ .row = Artist, .table = "artist", .rows = "artists" },
    .{ .row = Category, .table = "category", .rows = "categories" },
    .{ .row = Color, .table = "color", .rows = "colors" },
    .{ .row = Content, .table = "content", .rows = "contents" },
    .{ .row = Cue, .table = "cue", .rows = "cues" },
    .{ .row = Genre, .table = "genre", .rows = "genres" },
    .{ .row = History, .table = "history", .rows = "histories" },
    .{ .row = HistoryContent, .table = "history_content", .rows = "history_contents" },
    .{ .row = HotCueBankList, .table = "hotCueBankList", .rows = "hot_cue_bank_lists" },
    .{ .row = HotCueBankListCue, .table = "hotCueBankList_cue", .rows = "hot_cue_bank_cues" },
    .{ .row = Image, .table = "image", .rows = "images" },
    .{ .row = Key, .table = "key", .rows = "keys" },
    .{ .row = Label, .table = "label", .rows = "labels" },
    .{ .row = MenuItem, .table = "menuItem", .rows = "menu_items" },
    .{ .row = MyTag, .table = "myTag", .rows = "my_tags" },
    .{ .row = MyTagContent, .table = "myTag_content", .rows = "my_tag_contents" },
    .{ .row = Playlist, .table = "playlist", .rows = "playlists" },
    .{ .row = PlaylistContent, .table = "playlist_content", .rows = "playlist_contents" },
    .{ .row = RecommendedLike, .table = "recommendedLike", .rows = "recommended_likes" },
    .{ .row = Sort, .table = "sort", .rows = "sorts" },
};

/// The keyed-access wiring for every table with a primary key: row type,
/// `Library` rows field, map field, and the id column. SQLite enforces
/// the PK constraint, so each id maps to exactly one row index.
const id_tables = .{
    .{ .row = Album, .rows = "albums", .map = "album_by_id", .id = "album_id" },
    .{ .row = Artist, .rows = "artists", .map = "artist_by_id", .id = "artist_id" },
    .{ .row = Category, .rows = "categories", .map = "category_by_id", .id = "category_id" },
    .{ .row = Color, .rows = "colors", .map = "color_by_id", .id = "color_id" },
    .{ .row = Content, .rows = "contents", .map = "content_by_id", .id = "content_id" },
    .{ .row = Cue, .rows = "cues", .map = "cue_by_id", .id = "cue_id" },
    .{ .row = Genre, .rows = "genres", .map = "genre_by_id", .id = "genre_id" },
    .{ .row = History, .rows = "histories", .map = "history_by_id", .id = "history_id" },
    .{ .row = HotCueBankList, .rows = "hot_cue_bank_lists", .map = "hot_cue_bank_list_by_id", .id = "hotCueBankList_id" },
    .{ .row = Image, .rows = "images", .map = "image_by_id", .id = "image_id" },
    .{ .row = Key, .rows = "keys", .map = "key_by_id", .id = "key_id" },
    .{ .row = Label, .rows = "labels", .map = "label_by_id", .id = "label_id" },
    .{ .row = MenuItem, .rows = "menu_items", .map = "menu_item_by_id", .id = "menuItem_id" },
    .{ .row = MyTag, .rows = "my_tags", .map = "my_tag_by_id", .id = "myTag_id" },
    .{ .row = Playlist, .rows = "playlists", .map = "playlist_by_id", .id = "playlist_id" },
    .{ .row = Sort, .rows = "sorts", .map = "sort_by_id", .id = "sort_id" },
};

/// A whole `exportLibrary.db`, read into arena-owned models: every row of
/// every table, strings and all. The models mirror the real schema
/// exactly — column names verbatim (typos included), declaration order =
/// schema order, and every non-primary-key column optional, because the
/// real schema carries no NOT NULL anywhere (upstream-report checklist);
/// the fixture writes NULL for unset foreign keys (`artist_id_remixer`)
/// and empty strings elsewhere (`isrc`), and both survive verbatim.
/// Integer columns are read through SQLite's numeric conversion; there
/// are no enums — the O4 reader layer interprets raw values.
pub const Library = struct {
    /// Arena owning every row, string, and index parsed into this
    /// instance.
    arena: *std.heap.ArenaAllocator,
    albums: []const Album = &.{},
    artists: []const Artist = &.{},
    categories: []const Category = &.{},
    colors: []const Color = &.{},
    contents: []const Content = &.{},
    cues: []const Cue = &.{},
    genres: []const Genre = &.{},
    histories: []const History = &.{},
    history_contents: []const HistoryContent = &.{},
    hot_cue_bank_lists: []const HotCueBankList = &.{},
    hot_cue_bank_cues: []const HotCueBankListCue = &.{},
    images: []const Image = &.{},
    keys: []const Key = &.{},
    labels: []const Label = &.{},
    menu_items: []const MenuItem = &.{},
    my_tags: []const MyTag = &.{},
    my_tag_contents: []const MyTagContent = &.{},
    playlists: []const Playlist = &.{},
    playlist_contents: []const PlaylistContent = &.{},
    recommended_likes: []const RecommendedLike = &.{},
    sorts: []const Sort = &.{},
    /// The singleton `property` row, or null when the table is empty.
    property: ?Property = null,

    /// Keyed access built by `load`: one id → row-index map per
    /// primary-key table (`byId`), the pdb-side join by `content.path`
    /// (`contentByPath`), and the junction groupings mirroring the
    /// schema's own four indexes — the only indexes real files carry.
    album_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    artist_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    category_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    color_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    content_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    cue_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    genre_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    history_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    hot_cue_bank_list_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    image_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    key_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    label_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    menu_item_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    my_tag_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    playlist_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    sort_by_id: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    /// First row wins on duplicate paths — the schema enforces no
    /// uniqueness there. Rows with a NULL path are skipped (unkeyable,
    /// like NULL foreign keys).
    content_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    playlist_contents_by_playlist: std.AutoHashMapUnmanaged(i64, []u32) = .empty,
    my_tag_contents_by_my_tag: std.AutoHashMapUnmanaged(i64, []u32) = .empty,
    my_tag_contents_by_content: std.AutoHashMapUnmanaged(i64, []u32) = .empty,
    hot_cue_bank_cues_by_list: std.AutoHashMapUnmanaged(i64, []u32) = .empty,

    /// Reads every table of an open db (keyed or plaintext — the models
    /// do not differ). Each table's column layout is validated against
    /// the pinned schema before any row is read; more than one
    /// `property` row is a `SchemaMismatch`.
    pub fn load(alloc: std.mem.Allocator, db: Db) LoadError!Library {
        if (mode == .off) dlpDisabled();
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var lib = Library{ .arena = arena };
        inline for (row_tables) |t|
            try loadTable(t.row, t.table, a, db, &@field(lib, t.rows));

        var props: []const Property = &.{};
        try loadTable(Property, "property", a, db, &props);
        if (props.len > 1) return error.SchemaMismatch;
        lib.property = if (props.len == 1) props[0] else null;

        inline for (id_tables) |t|
            @field(lib, t.map) = try indexById(a, @field(lib, t.rows), t.id);

        try lib.content_by_path.ensureTotalCapacity(a, @intCast(lib.contents.len));
        for (lib.contents, 0..) |*row, i| {
            const path = row.path orelse continue;
            const gop = lib.content_by_path.getOrPutAssumeCapacity(path);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }

        lib.playlist_contents_by_playlist =
            try groupRows(a, lib.playlist_contents, "playlist_id", "sequenceNo");
        lib.my_tag_contents_by_my_tag =
            try groupRows(a, lib.my_tag_contents, "myTag_id", null);
        lib.my_tag_contents_by_content =
            try groupRows(a, lib.my_tag_contents, "content_id", null);
        lib.hot_cue_bank_cues_by_list =
            try groupRows(a, lib.hot_cue_bank_cues, "hotCueBankList_id", "sequenceNo");

        return lib;
    }

    /// Row lookup for any primary-key table — `lib.byId(dlp.Artist, 3)`.
    /// Ids absent from the table, including the 0 = "no foreign key"
    /// convention, return null.
    pub fn byId(self: *const Library, comptime T: type, id: i64) ?*const T {
        inline for (id_tables) |t| {
            if (T == t.row) {
                const idx = @field(self, t.map).get(id) orelse return null;
                return &@field(self, t.rows)[idx];
            }
        }
        @compileError("Library has no by-id map for " ++ @typeName(T));
    }

    /// The join to the pdb side: `content.path` values are
    /// device-root-absolute (`/Contents/...`), the value shape of the pdb
    /// Track `file_path` — the two id spaces are otherwise independent.
    pub fn contentByPath(self: *const Library, path: []const u8) ?*const Content {
        const idx = self.content_by_path.get(path) orelse return null;
        return &self.contents[idx];
    }

    /// Frees the instance and every value parsed into it.
    pub fn deinit(lib: *Library) void {
        const child = lib.arena.child_allocator;
        lib.arena.deinit();
        child.destroy(lib.arena);
    }

    /// Model equality (decision 11's acceptance primitive): same rows,
    /// field by field, in load order. Derived indexes are not compared —
    /// they are functions of the rows.
    pub fn eql(self: *const Library, other: *const Library) bool {
        inline for (row_tables) |t| {
            const mine = @field(self, t.rows);
            const theirs = @field(other, t.rows);
            if (mine.len != theirs.len) return false;
            for (mine, theirs) |*a, *b| {
                if (!rowEql(t.row, a, b)) return false;
            }
        }
        if (self.property == null or other.property == null)
            return self.property == null and other.property == null;
        return rowEql(Property, &self.property.?, &other.property.?);
    }
};

/// Loads one table's rows, validating the column layout (count then every
/// name, in order) against the row type's declaration before reading —
/// the schema-pinned analog of the pdb `constant_fields` asserts.
fn loadTable(
    comptime T: type,
    comptime table: []const u8,
    a: std.mem.Allocator,
    db: Db,
    out_rows: *[]const T,
) LoadError!void {
    const sql = "SELECT * FROM " ++ table ++ ";";
    var stmt = try db.prepare(sql);
    defer stmt.finalize();

    const fields = @typeInfo(T).@"struct".fields;
    if (stmt.columnCount() != fields.len) return error.SchemaMismatch;
    inline for (fields, 0..) |f, i| {
        if (!std.mem.eql(u8, stmt.columnName(i), f.name)) return error.SchemaMismatch;
    }

    var rows: std.ArrayListUnmanaged(T) = .empty;
    while ((try stmt.step()) == .row) {
        var row: T = undefined;
        inline for (fields, 0..) |f, i| {
            @field(row, f.name) = try decodeCell(f.type, a, stmt, i);
        }
        try rows.append(a, row);
    }
    out_rows.* = try rows.toOwnedSlice(a);
}

/// Reads one column of one row into its model field: integers through
/// SQLite's numeric conversion, text copied into the library's arena.
/// Nullable columns read NULL as null (non-null text is copied even when
/// empty — the fixture's `isrc` is `''`, not NULL).
fn decodeCell(comptime F: type, a: std.mem.Allocator, stmt: Stmt, i: usize) LoadError!F {
    if (F == i64) return stmt.readInt(i);
    if (F == ?i64) return if (stmt.isNull(i)) null else stmt.readInt(i);
    if (F == []const u8) return try a.dupe(u8, stmt.readText(i));
    if (F == ?[]const u8) return if (stmt.isNull(i)) null else try a.dupe(u8, stmt.readText(i));
    @compileError("unsupported OneLibrary column type: " ++ @typeName(F));
}

/// Field-wise equality of one row pair (`Library.eql`'s inner loop).
fn rowEql(comptime T: type, a: *const T, b: *const T) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (!cellEql(f.type, @field(a, f.name), @field(b, f.name))) return false;
    }
    return true;
}

fn cellEql(comptime F: type, a: F, b: F) bool {
    if (F == i64) return a == b;
    if (F == []const u8) return std.mem.eql(u8, a, b);
    if (F == ?i64) return (a == null and b == null) or (a != null and b != null and a.? == b.?);
    if (F == ?[]const u8) {
        return (a == null and b == null) or
            (a != null and b != null and std.mem.eql(u8, a.?, b.?));
    }
    @compileError("unsupported OneLibrary column type: " ++ @typeName(F));
}

/// Builds one id → row-index map (see `id_tables`); SQLite's PK
/// constraint guarantees unique keys.
fn indexById(
    a: std.mem.Allocator,
    rows: anytype,
    comptime id_field: []const u8,
) LoadError!std.AutoHashMapUnmanaged(i64, u32) {
    var map: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    try map.ensureTotalCapacity(a, @intCast(rows.len));
    for (rows, 0..) |row, i| map.putAssumeCapacity(@field(row, id_field), @intCast(i));
    return map;
}

/// Builds one junction grouping: key value → row indices, in row order;
/// `order_field`, when given, re-orders each group by that column
/// (`sequenceNo`) with NULLs last. Rows whose key is NULL are skipped.
/// The four groupings mirror the schema's own four indexes.
fn groupRows(
    a: std.mem.Allocator,
    rows: anytype,
    comptime key_field: []const u8,
    comptime order_field: ?[]const u8,
) LoadError!std.AutoHashMapUnmanaged(i64, []u32) {
    var lists: std.AutoHashMapUnmanaged(i64, std.ArrayListUnmanaged(u32)) = .empty;
    for (rows, 0..) |row, i| {
        const key = @field(row, key_field) orelse continue;
        const gop = try lists.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, @intCast(i));
    }
    var grouped: std.AutoHashMapUnmanaged(i64, []u32) = .empty;
    try grouped.ensureTotalCapacity(a, lists.count());
    var it = lists.iterator();
    while (it.next()) |entry| {
        var list = entry.value_ptr.*;
        if (order_field) |field| orderIndices(rows, field, list.items);
        grouped.putAssumeCapacity(entry.key_ptr.*, try list.toOwnedSlice(a));
    }
    return grouped;
}

fn orderIndices(rows: anytype, comptime field: []const u8, indices: []u32) void {
    const Order = SeqOrder(@TypeOf(rows), field);
    std.sort.pdq(u32, indices, Order{ .rows = rows }, Order.lessThan);
}

/// Sort context ordering row indices by one nullable-i64 column, NULLs
/// last, ties by row order.
fn SeqOrder(comptime Rows: type, comptime field: []const u8) type {
    return struct {
        rows: Rows,

        fn lessThan(self: @This(), a: u32, b: u32) bool {
            const sa = @field(self.rows[a], field) orelse std.math.maxInt(i64);
            const sb = @field(self.rows[b], field) orelse std.math.maxInt(i64);
            return if (sa == sb) a < b else sa < sb;
        }
    };
}
