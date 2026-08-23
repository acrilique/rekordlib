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
//!   symbol-renamed C API.
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

/// The symbols differ per mode: the vendored build renames every export to
/// `rl_sqlite3_*`/`rl_sqlcipher_*` (decision 10), the system build links the
/// consumer's own unprefixed SQLCipher. The dead branch of this comptime
/// switch is not analyzed, so only the referenced set is emitted.
const api = switch (mode) {
    .off => {},
    .system => struct {
        const open_v2 = c.sqlite3_open_v2;
        const close_v2 = c.sqlite3_close_v2;
        const errmsg = c.sqlite3_errmsg;
        const exec = c.sqlite3_exec;
        const prepare_v2 = c.sqlite3_prepare_v2;
        const finalize = c.sqlite3_finalize;
        const step = c.sqlite3_step;
        const reset = c.sqlite3_reset;
        const clear_bindings = c.sqlite3_clear_bindings;
        const column_count = c.sqlite3_column_count;
        const column_name = c.sqlite3_column_name;
        const column_type = c.sqlite3_column_type;
        const column_int64 = c.sqlite3_column_int64;
        const column_double = c.sqlite3_column_double;
        const column_text = c.sqlite3_column_text;
        const column_blob = c.sqlite3_column_blob;
        const column_bytes = c.sqlite3_column_bytes;
        const bind_null = c.sqlite3_bind_null;
        const bind_int64 = c.sqlite3_bind_int64;
        const bind_double = c.sqlite3_bind_double;
        const bind_text = c.sqlite3_bind_text;
        const bind_blob = c.sqlite3_bind_blob;
        const last_insert_rowid = c.sqlite3_last_insert_rowid;
        const changes = c.sqlite3_changes;
        const libversion = c.sqlite3_libversion;
    },
    .vendored => struct {
        const open_v2 = c.rl_sqlite3_open_v2;
        const close_v2 = c.rl_sqlite3_close_v2;
        const errmsg = c.rl_sqlite3_errmsg;
        const exec = c.rl_sqlite3_exec;
        const prepare_v2 = c.rl_sqlite3_prepare_v2;
        const finalize = c.rl_sqlite3_finalize;
        const step = c.rl_sqlite3_step;
        const reset = c.rl_sqlite3_reset;
        const clear_bindings = c.rl_sqlite3_clear_bindings;
        const column_count = c.rl_sqlite3_column_count;
        const column_name = c.rl_sqlite3_column_name;
        const column_type = c.rl_sqlite3_column_type;
        const column_int64 = c.rl_sqlite3_column_int64;
        const column_double = c.rl_sqlite3_column_double;
        const column_text = c.rl_sqlite3_column_text;
        const column_blob = c.rl_sqlite3_column_blob;
        const column_bytes = c.rl_sqlite3_column_bytes;
        const bind_null = c.rl_sqlite3_bind_null;
        const bind_int64 = c.rl_sqlite3_bind_int64;
        const bind_double = c.rl_sqlite3_bind_double;
        const bind_text = c.rl_sqlite3_bind_text;
        const bind_blob = c.rl_sqlite3_bind_blob;
        const last_insert_rowid = c.rl_sqlite3_last_insert_rowid;
        const changes = c.rl_sqlite3_changes;
        const libversion = c.rl_sqlite3_libversion;
    },
};

// ---------------------------------------------------------------------------
// Crypto provider (SQLCIPHER_CRYPTO_CUSTOM over std.crypto)
// ---------------------------------------------------------------------------

const SQLITE_OK: c_int = 0;
const SQLITE_ERROR: c_int = 1;

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
        else => return SQLITE_ERROR,
    }
    return SQLITE_OK;
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
    std.crypto.pwhash.pbkdf2(out, password, salt, rounds, std.crypto.auth.hmac.Hmac(Hash)) catch return SQLITE_ERROR;
    return SQLITE_OK;
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
        else => SQLITE_ERROR,
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
    if (key_sz != 32) return SQLITE_ERROR;
    if (@rem(in_sz, 16) != 0) return SQLITE_ERROR;
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
    return SQLITE_OK;
}

fn providerAddRandom(ctx: ?*anyopaque, buffer: ?[*]const u8, length: c_int) callconv(.c) c_int {
    _ = ctx;
    _ = buffer;
    _ = length;
    return SQLITE_OK;
}

fn providerRandom(ctx: ?*anyopaque, buffer: ?[*]u8, length: c_int) callconv(.c) c_int {
    _ = ctx;
    if (length < 0) return SQLITE_ERROR;
    const buf = buffer.?[0..@intCast(length)];
    if (io_source) |io| {
        io.random(buf);
        return SQLITE_OK;
    }
    return SQLITE_ERROR;
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
    return SQLITE_OK;
}

fn providerCtxFree(ctx: *?*anyopaque) callconv(.c) c_int {
    ctx.* = null;
    return SQLITE_OK;
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
    return SQLITE_OK;
}

// ---------------------------------------------------------------------------
// SQLite wrapper (O1 candidate A)
// ---------------------------------------------------------------------------

/// rbox 0.1.5 `conn.rs` MAGIC with each byte decremented (plan Phase O).
pub const passphrase = "r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls";

pub const SqlError = error{ Sqlite, OutOfMemory };

const SQLITE_OK_RC: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;

pub const StepResult = enum { row, done };

/// One prepared statement over an open `Db`. Borrowed: finalizing returns
/// it to the caller's discipline (the `deinit`-style call is `finalize`).
pub const Stmt = struct {
    handle: *c.rl_sqlite3_stmt,

    pub fn step(self: Stmt) SqlError!StepResult {
        return switch (api.step(self.handle)) {
            SQLITE_ROW => .row,
            SQLITE_DONE => .done,
            else => error.Sqlite,
        };
    }

    pub fn finalize(self: Stmt) void {
        _ = api.finalize(self.handle);
    }

    pub fn reset(self: Stmt) SqlError!void {
        if (api.reset(self.handle) != SQLITE_OK_RC) return error.Sqlite;
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
        // SQLITE_NULL == 5
        return api.column_type(self.handle, @intCast(i)) == 5;
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
        if (api.bind_null(self.handle, @intCast(i)) != SQLITE_OK_RC) return error.Sqlite;
    }

    pub fn bindInt(self: Stmt, i: usize, v: i64) SqlError!void {
        if (api.bind_int64(self.handle, @intCast(i), v) != SQLITE_OK_RC) return error.Sqlite;
    }

    pub fn bindFloat(self: Stmt, i: usize, v: f64) SqlError!void {
        if (api.bind_double(self.handle, @intCast(i), v) != SQLITE_OK_RC) return error.Sqlite;
    }

    /// `text` is copied by SQLite before the call returns (SQLITE_TRANSIENT).
    pub fn bindText(self: Stmt, i: usize, text: []const u8) SqlError!void {
        const rc = api.bind_text(self.handle, @intCast(i), text.ptr, @intCast(text.len), sqlite_transient());
        if (rc != SQLITE_OK_RC) return error.Sqlite;
    }

    /// `blob` is copied by SQLite before the call returns (SQLITE_TRANSIENT).
    pub fn bindBlob(self: Stmt, i: usize, blob: []const u8) SqlError!void {
        const rc = api.bind_blob(self.handle, @intCast(i), blob.ptr, @intCast(blob.len), sqlite_transient());
        if (rc != SQLITE_OK_RC) return error.Sqlite;
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
        return openFlags(io, path, SQLITE_OPEN_READWRITE);
    }

    pub fn openReadWriteCreate(io: std.Io, path: [:0]const u8) OpenError!Db {
        if (mode == .off) dlpDisabled();
        return openFlags(io, path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    }

    fn openFlags(io: std.Io, path: [:0]const u8, flags: c_int) OpenError!Db {
        if (mode == .off) dlpDisabled();
        io_source = io;
        var handle: ?*c.sqlite3 = null;
        const rc = api.open_v2(path.ptr, &handle, flags, null);
        if (rc != SQLITE_OK_RC) {
            if (handle) |h| _ = api.close_v2(h);
            return error.Sqlite;
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        // key before any page read; the WAL-persisted fixture needs the
        // read-write open above to recover without sidecar files present
        var buf: [256]u8 = undefined;
        const key_sql = std.fmt.bufPrintZ(&buf, "PRAGMA key = '{s}';", .{passphrase}) catch return error.OutOfMemory;
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
        if (api.exec(self.handle, sql.ptr, null, null, null) != SQLITE_OK_RC) return error.Sqlite;
    }

    pub fn prepare(self: Db, sql: [:0]const u8) SqlError!Stmt {
        var stmt: ?*c.rl_sqlite3_stmt = null;
        const rc = api.prepare_v2(self.handle, sql.ptr, -1, &stmt, null);
        if (rc != SQLITE_OK_RC) return error.Sqlite;
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
