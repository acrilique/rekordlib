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
//! * a thin SQLite wrapper over the symbol-renamed C API;
//! * the read models (`Library`): every row of the 22 OneLibrary tables,
//!   schema-pinned and arena-owned, with keyed access for the joins the
//!   device reader needs;
//! * the write layer (`Writer`): creates a fresh export's db (the real
//!   schema plus its seeded defaults), inserts rows over the O2 models,
//!   and closes in the on-disk shape of rb's exports.
//!
//! Build modes (`-Ddlp=off|vendored|system`): `off` compiles this module's
//! types away from the binary (every runtime entry point is guarded by a
//! comptime `@compileError`); `vendored` compiles the prefixed amalgamation
//! with zig cc; `system` binds the consumer's own unprefixed SQLCipher.

const std = @import("std");
const opts = @import("options");
const c = @import("c");

pub const mode = opts.dlp;

fn dlpDisabled() noreturn {
    @compileError("rekordlib was built with -Ddlp=off; rebuild with -Ddlp=vendored (or =system) to use the OneLibrary store");
}

/// off/vendored bind `rl_`-renamed symbols (typedefs included; `off`
/// translates the renamed header without compiling any C); system binds
/// the consumer's unprefixed SQLCipher.
const prefix: []const u8 = switch (mode) {
    .system => "",
    .off, .vendored => "rl_",
};

fn cfn(comptime name: []const u8) @TypeOf(@field(c, prefix ++ name)) {
    return @field(c, prefix ++ name);
}

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

/// OS entropy source seed for salt/IV generation. SQLCipher passes the
/// provider ctx to every callback but gives `ctx_init` no input, so
/// `Db.open` parks its Io here and `providerCtxInit` copies it into each
/// provider ctx — an open db pins its own Io instead of racing on
/// whatever `Db.open` ran last. The seed itself is module-global, so
/// `open_gate` serializes the open-to-key stretch that reads it: a
/// concurrent open cannot swap another db's entropy source in.
var io_seed: ?std.Io = null;
var open_gate: std.Io.Mutex = .init;

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
    if (hmac_key == null or out == null) return c.SQLITE_ERROR;
    if (key_sz < 0 or in_sz < 0 or in2_sz < 0) return c.SQLITE_ERROR;
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
    if (pass == null or salt == null or key == null) return c.SQLITE_ERROR;
    if (pass_sz < 0 or salt_sz < 0 or key_sz <= 0 or workfactor <= 0) return c.SQLITE_ERROR;
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

/// Error of `cbc`: the destination must be at least as long as the
/// source, and the source a whole number of 16-byte blocks — checked in
/// every build mode, not only where debug asserts run.
pub const CbcError = error{ BufferTooSmall, NotBlockAligned };

/// AES-256-CBC over a whole number of 16-byte blocks (pages are);
/// std.crypto ships no CBC mode. Public and free of C types — directly
/// testable against published vectors.
pub fn cbc(comptime encrypt: bool, key: [32]u8, iv: [16]u8, dst: []u8, src: []const u8) CbcError!void {
    if (dst.len < src.len) return error.BufferTooSmall;
    if (src.len % 16 != 0) return error.NotBlockAligned;
    const aes = if (encrypt)
        std.crypto.core.aes.Aes256.initEnc(key)
    else
        std.crypto.core.aes.Aes256.initDec(key);
    var chain = iv;
    var i: usize = 0;
    while (i < src.len) : (i += 16) {
        if (encrypt) {
            var block: [16]u8 = undefined;
            for (0..16) |j| block[j] = src[i + j] ^ chain[j];
            aes.encrypt(dst[i..][0..16], &block);
            chain = dst[i..][0..16].*;
        } else {
            var plain: [16]u8 = undefined;
            aes.decrypt(&plain, src[i..][0..16]);
            for (0..16) |j| dst[i + j] = plain[j] ^ chain[j];
            chain = src[i..][0..16].*;
        }
    }
}

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
    if (key == null or iv == null or in == null or out == null) return c.SQLITE_ERROR;
    if (key_sz != 32) return c.SQLITE_ERROR;
    if (in_sz < 0 or @rem(in_sz, 16) != 0) return c.SQLITE_ERROR;
    const n: usize = @intCast(in_sz);
    if (enc == SQLCIPHER_ENCRYPT)
        cbc(true, key.?[0..32].*, iv.?[0..16].*, out.?[0..n], in.?[0..n]) catch return c.SQLITE_ERROR
    else
        cbc(false, key.?[0..32].*, iv.?[0..16].*, out.?[0..n], in.?[0..n]) catch return c.SQLITE_ERROR;
    return c.SQLITE_OK;
}

fn providerAddRandom(ctx: ?*anyopaque, buffer: ?[*]const u8, length: c_int) callconv(.c) c_int {
    _ = ctx;
    _ = buffer;
    _ = length;
    return c.SQLITE_OK;
}

fn providerRandom(ctx: ?*anyopaque, buffer: ?[*]u8, length: c_int) callconv(.c) c_int {
    if (ctx == null or buffer == null or length < 0) return c.SQLITE_ERROR;
    const io: *std.Io = @ptrCast(@alignCast(ctx.?));
    io.random(buffer.?[0..@intCast(length)]);
    return c.SQLITE_OK;
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

/// Snapshots the seed Io into the provider ctx sqlcipher hands to every
/// callback. Before the first open the seed is null (sqlcipher's library
/// init also comes through here) and the ctx stays null; `providerRandom`
/// refuses then.
fn providerCtxInit(ctx: *?*anyopaque) callconv(.c) c_int {
    ctx.* = null;
    if (io_seed) |io| {
        const holder = std.heap.page_allocator.create(std.Io) catch return c.SQLITE_ERROR;
        holder.* = io;
        ctx.* = holder;
    }
    return c.SQLITE_OK;
}

fn providerCtxFree(ctx: *?*anyopaque) callconv(.c) c_int {
    if (ctx.*) |p| std.heap.page_allocator.destroy(@as(*std.Io, @ptrCast(@alignCast(p))));
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
// SQLite wrapper
// ---------------------------------------------------------------------------

/// rbox 0.1.5 `conn.rs` MAGIC with each byte decremented.
pub const passphrase = "r8gddnr4k847830ar6cqzbkk0el6qytmb3trbbx805jm74vez64i5o8fnrqryqls";

comptime {
    // The passphrase is inlined into the key pragma's SQL string; a
    // single quote would break out of the literal.
    if (std.mem.indexOfScalar(u8, passphrase, '\'') != null)
        @compileError("dlp.passphrase must not contain a single quote");
}

pub const SqlError = error{ Sqlite, OutOfMemory };

pub const StepResult = enum { row, done };

/// One prepared statement over an open `Db`.
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

    pub fn resetAndClear(self: Stmt) SqlError!void {
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

/// An open OneLibrary database. `open` reads (recovering WAL state),
/// `openReadWriteCreate` also creates - both apply the DLP passphrase.
pub const Db = struct {
    handle: *c.sqlite3,

    const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
    const SQLITE_OPEN_CREATE: c_int = 0x00000004;

    pub const OpenError = SqlError;

    /// `io` seeds the crypto provider's entropy source (salt/IV generation
    /// on write); read-only sessions never draw from it.
    pub fn open(io: std.Io, path: [:0]const u8) OpenError!Db {
        return openFlags(io, path, SQLITE_OPEN_READWRITE, true);
    }

    pub fn openReadWriteCreate(io: std.Io, path: [:0]const u8) OpenError!Db {
        return openFlags(io, path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, true);
    }

    /// Opens a db without applying the DLP passphrase: plaintext fixtures
    /// (`testdata/dlp/`) and consumer-written plain SQLite files. SQLCipher
    /// reads an unkeyed plaintext file exactly like stock SQLite.
    pub fn openPlaintext(io: std.Io, path: [:0]const u8) OpenError!Db {
        return openFlags(io, path, SQLITE_OPEN_READWRITE, false);
    }

    /// Creates or opens a plaintext db without applying the DLP
    /// passphrase (`Writer.create` with `plaintext` writes such files).
    pub fn openPlaintextReadWriteCreate(io: std.Io, path: [:0]const u8) OpenError!Db {
        return openFlags(io, path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, false);
    }

    fn openFlags(io: std.Io, path: [:0]const u8, flags: c_int, keyed: bool) OpenError!Db {
        if (mode == .off) dlpDisabled();
        // Hold the gate until the key pragma has copied the seed into
        // this db's provider ctx (plaintext opens need no seed, but the
        // library init inside the first open_v2 reads it too).
        open_gate.lockUncancelable(io);
        defer open_gate.unlock(io);
        io_seed = io;
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
// OneLibrary read models
// ---------------------------------------------------------------------------

/// Loading error of `Library.load`: SQLite errors plus `SchemaMismatch`
/// (a table's columns differ from the pinned schema).
pub const LoadError = SqlError || error{SchemaMismatch};

/// An `album` row. `isComplation` [sic] is Pioneer's typo, kept verbatim
/// from the real schema.
pub const Album = struct {
    album_id: i64,
    name: ?[]const u8 = null,
    artist_id: ?i64 = null,
    image_id: ?i64 = null,
    isComplation: ?i64 = null,
    nameForSearch: ?[]const u8 = null,
};

/// An `artist` row; shared by the five content artist roles through the
/// `artist_id_<role>` foreign keys.
pub const Artist = struct {
    artist_id: i64,
    name: ?[]const u8 = null,
    nameForSearch: ?[]const u8 = null,
};

/// A `category` row: links a browse category to its `menuItem` column.
pub const Category = struct {
    category_id: i64,
    menuItem_id: ?i64 = null,
    sequenceNo: ?i64 = null,
    isVisible: ?i64 = null,
};

/// A `color` row: the eight fixed track colors.
pub const Color = struct {
    color_id: i64,
    name: ?[]const u8 = null,
};

/// A `content` row: one track. The central table of the db — every other
/// track-related table references it by `content_id`, and the pdb side
/// joins by `path`. Facts pinned by
/// the with_anlz fixture: `path` is device-root-absolute (`/Contents/...`),
/// `analysisDataFilePath` is root-absolute to the track's ANLZ `.DAT`,
/// `contentLink` = 788 224 = the pdb Track bitmask `0x000C0700`,
/// `analysedBits` = 41 = the pdb Track `unknown5`, and the artist foreign
/// keys are named `artist_id_<role>` (`djPlayCount` and
/// `artist_id_originalArtist` are missing from the rbox 0.1.5 model).
pub const Content = struct {
    content_id: i64,
    title: ?[]const u8 = null,
    titleForSearch: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    bpmx100: ?i64 = null,
    length: ?i64 = null,
    trackNo: ?i64 = null,
    discNo: ?i64 = null,
    artist_id_artist: ?i64 = null,
    artist_id_remixer: ?i64 = null,
    artist_id_originalArtist: ?i64 = null,
    artist_id_composer: ?i64 = null,
    artist_id_lyricist: ?i64 = null,
    album_id: ?i64 = null,
    genre_id: ?i64 = null,
    label_id: ?i64 = null,
    key_id: ?i64 = null,
    color_id: ?i64 = null,
    image_id: ?i64 = null,
    djComment: ?[]const u8 = null,
    rating: ?i64 = null,
    releaseYear: ?i64 = null,
    releaseDate: ?[]const u8 = null,
    dateCreated: ?[]const u8 = null,
    dateAdded: ?[]const u8 = null,
    path: ?[]const u8 = null,
    fileName: ?[]const u8 = null,
    fileSize: ?i64 = null,
    fileType: ?i64 = null,
    bitrate: ?i64 = null,
    bitDepth: ?i64 = null,
    samplingRate: ?i64 = null,
    isrc: ?[]const u8 = null,
    djPlayCount: ?i64 = null,
    isHotCueAutoLoadOn: ?i64 = null,
    isKuvoDeliverStatusOn: ?i64 = null,
    kuvoDeliveryComment: ?[]const u8 = null,
    masterDbId: ?i64 = null,
    masterContentId: ?i64 = null,
    analysisDataFilePath: ?[]const u8 = null,
    analysedBits: ?i64 = null,
    contentLink: ?i64 = null,
    hasModified: ?i64 = null,
    cueUpdateCount: ?i64 = null,
    analysisDataUpdateCount: ?i64 = null,
    informationUpdateCount: ?i64 = null,
};

/// A `cue` row: one point or loop of one track (`content_id`), or of a hot
/// cue bank (through `hotCueBankList_cue`). Every position is stored four
/// ways — microseconds, 150-fps analysis frames, MPEG frames, and sample
/// block offsets (`inFileOffsetInBlock` is lowercase but
/// `OutFileOffsetInBlock` capitalized, both verbatim). Fresh exports carry
/// no cue rows.
pub const Cue = struct {
    cue_id: i64,
    content_id: ?i64 = null,
    kind: ?i64 = null,
    colorTableIndex: ?i64 = null,
    cueComment: ?[]const u8 = null,
    isActiveLoop: ?i64 = null,
    beatLoopNumerator: ?i64 = null,
    beatLoopDenominator: ?i64 = null,
    inUsec: ?i64 = null,
    outUsec: ?i64 = null,
    in150FramePerSec: ?i64 = null,
    out150FramePerSec: ?i64 = null,
    inMpegFrameNumber: ?i64 = null,
    outMpegFrameNumber: ?i64 = null,
    inMpegAbs: ?i64 = null,
    outMpegAbs: ?i64 = null,
    inDecodingStartFramePosition: ?i64 = null,
    outDecodingStartFramePosition: ?i64 = null,
    inFileOffsetInBlock: ?i64 = null,
    OutFileOffsetInBlock: ?i64 = null,
    inNumberOfSampleInBlock: ?i64 = null,
    outNumberOfSampleInBlock: ?i64 = null,
};

/// A `genre` row: the db's copy of the pdb genre table.
pub const Genre = struct {
    genre_id: i64,
    name: ?[]const u8 = null,
};

/// A `history` row: one play-history session (parent 0 = root). Empty in
/// fresh exports; entries live in `history_content`.
pub const History = struct {
    history_id: i64,
    sequenceNo: ?i64 = null,
    name: ?[]const u8 = null,
    attribute: ?i64 = null,
    history_id_parent: ?i64 = null,
};

/// A `history_content` row: one track of one history session.
pub const HistoryContent = struct {
    history_id: ?i64 = null,
    content_id: ?i64 = null,
    sequenceNo: ?i64 = null,
};

/// A `hotCueBankList` row: one hot cue bank (parent 0 = root); its cues
/// link through `hotCueBankList_cue`. Empty in fresh exports.
pub const HotCueBankList = struct {
    hotCueBankList_id: i64,
    sequenceNo: ?i64 = null,
    name: ?[]const u8 = null,
    image_id: ?i64 = null,
    attribute: ?i64 = null,
    hotCueBankList_id_parent: ?i64 = null,
};

/// A `hotCueBankList_cue` row: one cue of one bank.
pub const HotCueBankListCue = struct {
    hotCueBankList_id: ?i64 = null,
    cue_id: ?i64 = null,
    sequenceNo: ?i64 = null,
};

/// An `image` row: artwork referenced by content, playlist, and album
/// rows. `path` is the `b{id}.jpg` variant under the same
/// `{id/20+1:05}` shard as the pdb's `a{id}.jpg` thumbnails.
pub const Image = struct {
    image_id: i64,
    path: ?[]const u8 = null,
};

/// A `key` row: a musical key name; id 0 = no key (the port's FK
/// convention). The fixture's table is empty — its two tracks carry
/// `key_id` 0.
pub const Key = struct {
    key_id: i64,
    name: ?[]const u8 = null,
};

/// A `label` row.
pub const Label = struct {
    label_id: i64,
    name: ?[]const u8 = null,
};

/// A `menuItem` row: a browse column header (27 in the fixture), named
/// with the same `\u{fffa}`/`\u{fffb}` interlinear-annotation wrapping as
/// the pdb Menu rows.
pub const MenuItem = struct {
    menuItem_id: i64,
    kind: ?i64 = null,
    name: ?[]const u8 = null,
};

/// A `myTag` row: the db's copy of the my-tag tree mirrored in
/// `exportExt.pdb`'s Tag rows. `attribute` 1 = column (container), 0 =
/// leaf — the same bit the ext pdb stores as `raw_is_category << 24`;
/// parent 0 = root; ids are random-looking u32s like ext tag ids.
pub const MyTag = struct {
    myTag_id: i64,
    sequenceNo: ?i64 = null,
    name: ?[]const u8 = null,
    attribute: ?i64 = null,
    myTag_id_parent: ?i64 = null,
};

/// A `myTag_content` row: track-to-tag junction; unlike the other
/// junctions it carries no `sequenceNo`.
pub const MyTagContent = struct {
    myTag_id: ?i64 = null,
    content_id: ?i64 = null,
};

/// A `playlist` row: one node of the playlist tree mirrored in the pdb
/// (`playlist_id_parent` 0 = root; the fixture's single leaf carries
/// `attribute` 0).
pub const Playlist = struct {
    playlist_id: i64,
    sequenceNo: ?i64 = null,
    name: ?[]const u8 = null,
    image_id: ?i64 = null,
    attribute: ?i64 = null,
    playlist_id_parent: ?i64 = null,
};

/// A `playlist_content` row: playlist membership; `sequenceNo` is dense
/// and 1-based in the fixture.
pub const PlaylistContent = struct {
    playlist_id: ?i64 = null,
    content_id: ?i64 = null,
    sequenceNo: ?i64 = null,
};

/// The `property` row — a singleton; real exports carry exactly one.
/// `dbVersion` is a varchar holding `'10000'` (rbox models an INTEGER
/// defaulting to 1000); `deviceName` is the empty string in exports;
/// `myTagMasterDBID` derives from the master db and writers may leave 0.
/// and writers may leave 0.
pub const Property = struct {
    deviceName: ?[]const u8 = null,
    dbVersion: ?[]const u8 = null,
    numberOfContents: ?i64 = null,
    createdDate: ?[]const u8 = null,
    backGroundColorType: ?i64 = null,
    myTagMasterDBID: ?i64 = null,
};

/// A `recommendedLike` row: a liked-track relation between two contents.
/// `createdDate` is an INTEGER here (rbox models TEXT).
pub const RecommendedLike = struct {
    content_id_1: ?i64 = null,
    content_id_2: ?i64 = null,
    rating: ?i64 = null,
    createdDate: ?i64 = null,
};

/// A `sort` row: the track-list column layout over `menuItem_id`.
/// `sort_id` is 0-based (fixture rows run 0..16).
pub const Sort = struct {
    sort_id: i64,
    menuItem_id: ?i64 = null,
    sequenceNo: ?i64 = null,
    isVisible: ?i64 = null,
    isSelectedAsSubColumn: ?i64 = null,
};

/// One table's wiring into the rest of the module: the row type, the
/// SQL table name, and the `Library` field its rows load into — plus,
/// where present, the keyed-access map (`map` and `id` are set exactly
/// for the primary-key tables `load` indexes) and the `writable` mark
/// of the families `Writer.insert` accepts.
const Table = struct {
    row: type,
    table: []const u8,
    rows: []const u8,
    map: ?[]const u8 = null,
    id: ?[]const u8 = null,
    writable: bool = false,
};

/// Every table except `property` (a singleton loaded by hand), in
/// schema order — the single registry the load, keyed-access, and write
/// paths all derive from.
const tables = [_]Table{
    .{ .row = Album, .table = "album", .rows = "albums", .map = "album_by_id", .id = "album_id", .writable = true },
    .{ .row = Artist, .table = "artist", .rows = "artists", .map = "artist_by_id", .id = "artist_id", .writable = true },
    .{ .row = Category, .table = "category", .rows = "categories", .map = "category_by_id", .id = "category_id" },
    .{ .row = Color, .table = "color", .rows = "colors", .map = "color_by_id", .id = "color_id" },
    .{ .row = Content, .table = "content", .rows = "contents", .map = "content_by_id", .id = "content_id", .writable = true },
    .{ .row = Cue, .table = "cue", .rows = "cues", .map = "cue_by_id", .id = "cue_id" },
    .{ .row = Genre, .table = "genre", .rows = "genres", .map = "genre_by_id", .id = "genre_id", .writable = true },
    .{ .row = History, .table = "history", .rows = "histories", .map = "history_by_id", .id = "history_id" },
    .{ .row = HistoryContent, .table = "history_content", .rows = "history_contents" },
    .{ .row = HotCueBankList, .table = "hotCueBankList", .rows = "hot_cue_bank_lists", .map = "hot_cue_bank_list_by_id", .id = "hotCueBankList_id" },
    .{ .row = HotCueBankListCue, .table = "hotCueBankList_cue", .rows = "hot_cue_bank_cues" },
    .{ .row = Image, .table = "image", .rows = "images", .map = "image_by_id", .id = "image_id", .writable = true },
    .{ .row = Key, .table = "key", .rows = "keys", .map = "key_by_id", .id = "key_id", .writable = true },
    .{ .row = Label, .table = "label", .rows = "labels", .map = "label_by_id", .id = "label_id", .writable = true },
    .{ .row = MenuItem, .table = "menuItem", .rows = "menu_items", .map = "menu_item_by_id", .id = "menuItem_id" },
    .{ .row = MyTag, .table = "myTag", .rows = "my_tags", .map = "my_tag_by_id", .id = "myTag_id", .writable = true },
    .{ .row = MyTagContent, .table = "myTag_content", .rows = "my_tag_contents", .writable = true },
    .{ .row = Playlist, .table = "playlist", .rows = "playlists", .map = "playlist_by_id", .id = "playlist_id", .writable = true },
    .{ .row = PlaylistContent, .table = "playlist_content", .rows = "playlist_contents", .writable = true },
    .{ .row = RecommendedLike, .table = "recommendedLike", .rows = "recommended_likes" },
    .{ .row = Sort, .table = "sort", .rows = "sorts", .map = "sort_by_id", .id = "sort_id" },
};

/// The primary-key subset of `tables` (`map` set): what `load` indexes
/// and `byId` serves.
const id_tables = blk: {
    var selected: [tables.len]Table = undefined;
    var n: usize = 0;
    for (tables) |t| {
        if (t.map != null) {
            selected[n] = t;
            n += 1;
        }
    }
    break :blk selected[0..n].*;
};

/// A whole `exportLibrary.db`, read into arena-owned models: every row of
/// every table, strings and all. The models mirror the real schema
/// exactly — column names verbatim (typos included), declaration order =
/// schema order, and every non-primary-key column optional, because the
/// real schema carries no NOT NULL anywhere; the fixture writes NULL
/// for unset foreign keys (`artist_id_remixer`) and empty strings
/// elsewhere (`isrc`), and both survive verbatim. Optional fields default
/// to null, so `Writer` input literals only name what they set.
/// Integer columns are read through SQLite's numeric conversion; there
/// are no enums — the reader layer interprets raw values.
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
    /// do not differ); more than one `property` row is a `SchemaMismatch`.
    pub fn load(alloc: std.mem.Allocator, db: Db) LoadError!Library {
        if (mode == .off) dlpDisabled();
        const arena = try alloc.create(std.heap.ArenaAllocator);
        errdefer alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var lib = Library{ .arena = arena };
        inline for (tables) |t|
            try loadTable(t.row, t.table, a, db, &@field(lib, t.rows));

        var props: []const Property = &.{};
        try loadTable(Property, "property", a, db, &props);
        if (props.len > 1) return error.SchemaMismatch;
        lib.property = if (props.len == 1) props[0] else null;

        inline for (id_tables) |t|
            @field(lib, t.map.?) = try indexById(a, @field(lib, t.rows), t.id.?);

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
                const idx = @field(self, t.map.?).get(id) orelse return null;
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

    /// Model equality: same rows, field by field, in load order. Derived
    /// indexes are not compared — they are functions of the rows.
    pub fn eql(self: *const Library, other: *const Library) bool {
        inline for (tables) |t| {
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

    // Grown by doubling: a COUNT(*) pre-pass would read and decrypt
    // every page of the table twice under SQLCipher, while the growth
    // buffers the arena strands along the way cost at most ~2x
    // transient memory.
    var rows: std.ArrayListUnmanaged(T) = .empty;
    while ((try stmt.step()) == .row) try rows.append(a, try decodeRow(T, a, stmt));
    out_rows.* = rows.items;
}

/// Decodes one row into `T` in two passes over the comptime field list:
/// integers through SQLite's numeric conversion, text first borrowed from
/// the statement (valid until the next step) and then copied into one
/// arena allocation holding all of the row's strings contiguously. The
/// per-row pool replaces one allocation per text cell. Nullable columns
/// read NULL as null (non-null text is copied even when empty — the
/// fixture's `isrc` is `''`, not NULL).
fn decodeRow(comptime T: type, a: std.mem.Allocator, stmt: Stmt) LoadError!T {
    const fields = @typeInfo(T).@"struct".fields;
    var row: T = undefined;
    var texts: [fields.len]?[]const u8 = undefined;
    var len: usize = 0;
    inline for (fields, 0..) |f, i| {
        switch (f.type) {
            i64 => @field(row, f.name) = stmt.readInt(i),
            ?i64 => @field(row, f.name) = if (stmt.isNull(i)) null else stmt.readInt(i),
            []const u8, ?[]const u8 => {
                texts[i] = if (f.type == ?[]const u8 and stmt.isNull(i))
                    null
                else
                    stmt.readText(i);
                if (texts[i]) |t| len += t.len;
            },
            else => @compileError("unsupported OneLibrary column type: " ++ @typeName(f.type)),
        }
    }
    const buf = try a.alloc(u8, len);
    var off: usize = 0;
    inline for (fields, 0..) |f, i| {
        switch (f.type) {
            []const u8, ?[]const u8 => {
                if (texts[i]) |t| {
                    @memcpy(buf[off..][0..t.len], t);
                    @field(row, f.name) = buf[off..][0..t.len];
                    off += t.len;
                } else if (f.type == ?[]const u8) {
                    @field(row, f.name) = null;
                }
            },
            else => {},
        }
    }
    return row;
}

/// Field-wise equality of one row pair (`Library.eql`'s inner loop).
fn rowEql(comptime T: type, a: *const T, b: *const T) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (!cellEql(f.type, @field(a, f.name), @field(b, f.name))) return false;
    }
    return true;
}

fn cellEql(comptime F: type, a: F, b: F) bool {
    return switch (F) {
        i64, ?i64 => a == b,
        []const u8 => std.mem.eql(u8, a, b),
        ?[]const u8 => if (a) |x|
            (b != null and std.mem.eql(u8, x, b.?))
        else
            b == null,
        else => @compileError("unsupported OneLibrary column type: " ++ @typeName(F)),
    };
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
fn groupRows(
    a: std.mem.Allocator,
    rows: anytype,
    comptime key_field: []const u8,
    comptime order_field: ?[]const u8,
) LoadError!std.AutoHashMapUnmanaged(i64, []u32) {
    var counts: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    for (rows) |row| {
        const key = @field(row, key_field) orelse continue;
        const gop = try counts.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var grouped: std.AutoHashMapUnmanaged(i64, []u32) = .empty;
    try grouped.ensureTotalCapacity(a, counts.count());
    var it = counts.iterator();
    while (it.next()) |entry| {
        // one exact allocation per key: a grown-and-copied list would
        // strand both its buffers in the arena
        const indices = try a.alloc(u32, entry.value_ptr.*);
        entry.value_ptr.* = 0; // the count becomes the write cursor
        grouped.putAssumeCapacity(entry.key_ptr.*, indices);
    }
    for (rows, 0..) |row, i| {
        const key = @field(row, key_field) orelse continue;
        const cursor = counts.getPtr(key).?;
        grouped.getPtr(key).?.*[cursor.*] = @intCast(i);
        cursor.* += 1;
    }
    if (order_field) |field| {
        var groups = grouped.valueIterator();
        while (groups.next()) |indices| orderIndices(rows, field, indices.*);
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

// ---------------------------------------------------------------------------
// OneLibrary write layer
// ---------------------------------------------------------------------------

/// The corrected schema: every CREATE statement of the real with_anlz
/// `exportLibrary.db`, verbatim and in creation order — no FOREIGN KEY and
/// no NOT NULL anywhere, `content.djPlayCount` present,
/// `recommendedLike.createdDate` INTEGER, the real column spellings
/// (`artist_id_originalArtist`, `OutFileOffsetInBlock`, `isComplation`),
/// and the four indexes real files carry. rbox 0.1.5's migration drifts on
/// every one of these points; the stored `sqlite_master.sql` text of a db
/// this creates is byte-identical to the fixture's.
const schema_sql =
    \\CREATE TABLE content(content_id integer primary key, title varchar, titleForSearch varchar, subtitle varchar, bpmx100 integer, length integer, trackNo integer, discNo integer, artist_id_artist integer, artist_id_remixer integer, artist_id_originalArtist integer, artist_id_composer integer, artist_id_lyricist integer, album_id integer, genre_id integer, label_id integer, key_id integer, color_id integer, image_id integer, djComment varchar, rating integer, releaseYear integer, releaseDate varchar, dateCreated varchar, dateAdded varchar, path varchar, fileName varchar, fileSize integer, fileType integer, bitrate integer, bitDepth integer, samplingRate integer, isrc varchar, djPlayCount integer, isHotCueAutoLoadOn integer, isKuvoDeliverStatusOn integer, kuvoDeliveryComment varchar, masterDbId integer, masterContentId integer, analysisDataFilePath varchar, analysedBits integer, contentLink integer, hasModified integer, cueUpdateCount integer, analysisDataUpdateCount integer, informationUpdateCount integer);
    \\CREATE TABLE genre(genre_id integer primary key, name varchar);
    \\CREATE TABLE artist(artist_id integer primary key, name varchar, nameForSearch varchar);
    \\CREATE TABLE album(album_id integer primary key, name varchar, artist_id integer, image_id integer, isComplation integer, nameForSearch varchar);
    \\CREATE TABLE label(label_id integer primary key, name varchar);
    \\CREATE TABLE key(key_id integer primary key, name varchar);
    \\CREATE TABLE color(color_id integer primary key, name varchar);
    \\CREATE TABLE playlist(playlist_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, playlist_id_parent integer);
    \\CREATE TABLE playlist_content(playlist_id integer, content_id integer, sequenceNo integer);
    \\CREATE TABLE hotCueBankList(hotCueBankList_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, hotCueBankList_id_parent integer);
    \\CREATE TABLE hotCueBankList_cue(hotCueBankList_id integer, cue_id integer, sequenceNo integer);
    \\CREATE TABLE history(history_id integer primary key, sequenceNo integer, name varchar, attribute integer, history_id_parent integer);
    \\CREATE TABLE history_content(history_id integer, content_id integer, sequenceNo integer);
    \\CREATE TABLE image(image_id integer primary key, path varchar);
    \\CREATE TABLE cue(cue_id integer primary key, content_id integer, kind integer, colorTableIndex integer, cueComment varchar, isActiveLoop integer, beatLoopNumerator integer, beatLoopDenominator integer, inUsec integer, outUsec integer, in150FramePerSec integer, out150FramePerSec integer, inMpegFrameNumber integer, outMpegFrameNumber integer, inMpegAbs integer, outMpegAbs integer, inDecodingStartFramePosition integer, outDecodingStartFramePosition integer, inFileOffsetInBlock integer, OutFileOffsetInBlock integer, inNumberOfSampleInBlock integer, outNumberOfSampleInBlock integer);
    \\CREATE TABLE menuItem(menuItem_id integer primary key, kind integer, name varchar);
    \\CREATE TABLE category(category_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer);
    \\CREATE TABLE sort(sort_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer, isSelectedAsSubColumn integer);
    \\CREATE TABLE property(deviceName varchar, dbVersion varchar, numberOfContents integer, createdDate varchar, backGroundColorType integer, myTagMasterDBID integer);
    \\CREATE TABLE recommendedLike(content_id_1 integer, content_id_2 integer, rating integer, createdDate integer);
    \\CREATE TABLE myTag(myTag_id integer primary key, sequenceNo integer, name varchar, attribute integer, myTag_id_parent integer);
    \\CREATE TABLE myTag_content(myTag_id integer, content_id integer);
    \\CREATE INDEX index_playlist_content_playlist_id on playlist_content(playlist_id);
    \\CREATE INDEX index_myTag_content_myTag_id on myTag_content(myTag_id);
    \\CREATE INDEX index_myTag_content_content_id on myTag_content(content_id);
    \\CREATE INDEX index_hotCueBankList_cue_hotCueBankList_id on hotCueBankList_cue(hotCueBankList_id);
;

/// The eight fixed track colors a fresh export carries (rbox's migration
/// inserts the same rows).
const default_colors = [_]Color{
    .{ .color_id = 1, .name = "Pink" },
    .{ .color_id = 2, .name = "Red" },
    .{ .color_id = 3, .name = "Orange" },
    .{ .color_id = 4, .name = "Yellow" },
    .{ .color_id = 5, .name = "Green" },
    .{ .color_id = 6, .name = "Aqua" },
    .{ .color_id = 7, .name = "Blue" },
    .{ .color_id = 8, .name = "Purple" },
};

/// The 27 browse-column headers a fresh export carries, named with the
/// same `\u{fffa}`/`\u{fffb}` interlinear-annotation wrapping as pdb Menu
/// rows.
const default_menu_items = [_]MenuItem{
    .{ .menuItem_id = 1, .kind = 128, .name = "\u{fffa}GENRE\u{fffb}" },
    .{ .menuItem_id = 2, .kind = 129, .name = "\u{fffa}ARTIST\u{fffb}" },
    .{ .menuItem_id = 3, .kind = 130, .name = "\u{fffa}ALBUM\u{fffb}" },
    .{ .menuItem_id = 4, .kind = 131, .name = "\u{fffa}TRACK\u{fffb}" },
    .{ .menuItem_id = 5, .kind = 133, .name = "\u{fffa}BPM\u{fffb}" },
    .{ .menuItem_id = 6, .kind = 134, .name = "\u{fffa}RATING\u{fffb}" },
    .{ .menuItem_id = 7, .kind = 135, .name = "\u{fffa}YEAR\u{fffb}" },
    .{ .menuItem_id = 8, .kind = 136, .name = "\u{fffa}REMIXER\u{fffb}" },
    .{ .menuItem_id = 9, .kind = 137, .name = "\u{fffa}LABEL\u{fffb}" },
    .{ .menuItem_id = 10, .kind = 138, .name = "\u{fffa}ORIGINAL ARTIST\u{fffb}" },
    .{ .menuItem_id = 11, .kind = 139, .name = "\u{fffa}KEY\u{fffb}" },
    .{ .menuItem_id = 12, .kind = 141, .name = "\u{fffa}CUE\u{fffb}" },
    .{ .menuItem_id = 13, .kind = 142, .name = "\u{fffa}COLOR\u{fffb}" },
    .{ .menuItem_id = 14, .kind = 146, .name = "\u{fffa}TIME\u{fffb}" },
    .{ .menuItem_id = 15, .kind = 147, .name = "\u{fffa}BITRATE\u{fffb}" },
    .{ .menuItem_id = 16, .kind = 148, .name = "\u{fffa}FILE NAME\u{fffb}" },
    .{ .menuItem_id = 17, .kind = 132, .name = "\u{fffa}PLAYLIST\u{fffb}" },
    .{ .menuItem_id = 18, .kind = 152, .name = "\u{fffa}HOT CUE BANK\u{fffb}" },
    .{ .menuItem_id = 19, .kind = 149, .name = "\u{fffa}HISTORY\u{fffb}" },
    .{ .menuItem_id = 20, .kind = 145, .name = "\u{fffa}SEARCH\u{fffb}" },
    .{ .menuItem_id = 21, .kind = 150, .name = "\u{fffa}COMMENTS\u{fffb}" },
    .{ .menuItem_id = 22, .kind = 140, .name = "\u{fffa}DATE ADDED\u{fffb}" },
    .{ .menuItem_id = 23, .kind = 151, .name = "\u{fffa}DJ PLAY COUNT\u{fffb}" },
    .{ .menuItem_id = 24, .kind = 144, .name = "\u{fffa}FOLDER\u{fffb}" },
    .{ .menuItem_id = 25, .kind = 161, .name = "\u{fffa}DEFAULT\u{fffb}" },
    .{ .menuItem_id = 26, .kind = 162, .name = "\u{fffa}ALPHABET\u{fffb}" },
    .{ .menuItem_id = 27, .kind = 170, .name = "\u{fffa}MATCHING\u{fffb}" },
};

/// The browse-category layout over `menuItem` a fresh export carries.
/// Row 23 — the `HOT CUE BANK` column — is seeded `(0, 0)` as in the real
/// file; rbox's migration inserts `(11, 1)` there (a drift, like its DDL).
const default_categories = [_]Category{
    .{ .category_id = 1, .menuItem_id = 1, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 2, .menuItem_id = 2, .sequenceNo = 1, .isVisible = 1 },
    .{ .category_id = 3, .menuItem_id = 3, .sequenceNo = 2, .isVisible = 1 },
    .{ .category_id = 4, .menuItem_id = 4, .sequenceNo = 3, .isVisible = 1 },
    .{ .category_id = 5, .menuItem_id = 17, .sequenceNo = 5, .isVisible = 1 },
    .{ .category_id = 6, .menuItem_id = 5, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 7, .menuItem_id = 6, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 8, .menuItem_id = 7, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 9, .menuItem_id = 8, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 10, .menuItem_id = 9, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 11, .menuItem_id = 10, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 12, .menuItem_id = 11, .sequenceNo = 4, .isVisible = 1 },
    .{ .category_id = 15, .menuItem_id = 13, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 17, .menuItem_id = 24, .sequenceNo = 9, .isVisible = 1 },
    .{ .category_id = 18, .menuItem_id = 20, .sequenceNo = 7, .isVisible = 1 },
    .{ .category_id = 19, .menuItem_id = 14, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 20, .menuItem_id = 15, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 21, .menuItem_id = 16, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 22, .menuItem_id = 19, .sequenceNo = 6, .isVisible = 1 },
    .{ .category_id = 23, .menuItem_id = 18, .sequenceNo = 0, .isVisible = 0 },
    .{ .category_id = 26, .menuItem_id = 27, .sequenceNo = 8, .isVisible = 1 },
    .{ .category_id = 27, .menuItem_id = 22, .sequenceNo = 10, .isVisible = 1 },
};

/// The track-list column layout over `menuItem` a fresh export carries
/// (`sort_id` is 0-based; ids 14 and 24/25 are absent in real files too).
const default_sorts = [_]Sort{
    .{ .sort_id = 0, .menuItem_id = 25, .sequenceNo = 1, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 1, .menuItem_id = 26, .sequenceNo = 2, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 2, .menuItem_id = 2, .sequenceNo = 3, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 3, .menuItem_id = 3, .sequenceNo = 4, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 4, .menuItem_id = 5, .sequenceNo = 5, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 5, .menuItem_id = 6, .sequenceNo = 6, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 6, .menuItem_id = 1, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 7, .menuItem_id = 21, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 8, .menuItem_id = 14, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 9, .menuItem_id = 8, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 10, .menuItem_id = 9, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 11, .menuItem_id = 10, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 12, .menuItem_id = 11, .sequenceNo = 7, .isVisible = 1, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 13, .menuItem_id = 15, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 15, .menuItem_id = 13, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 16, .menuItem_id = 23, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
    .{ .sort_id = 17, .menuItem_id = 22, .sequenceNo = 0, .isVisible = 0, .isSelectedAsSubColumn = 0 },
};

/// One explicit transaction: `deinit` rolls back unless `commit` ran, so
/// `var tx = try Tx.begin(db); errdefer tx.deinit();` is the whole
/// failure protocol of a multi-statement mutation.
const Tx = struct {
    db: Db,
    spent: bool = false,

    fn begin(db: Db) SqlError!Tx {
        try db.exec("BEGIN IMMEDIATE;");
        return .{ .db = db };
    }

    fn commit(tx: *Tx) SqlError!void {
        try tx.db.exec("COMMIT;");
        tx.spent = true;
    }

    /// Rolls the transaction back unless it was committed; a rollback
    /// failure is swallowed — there is nothing left to do but leave the
    /// connection to `close`.
    fn deinit(tx: *Tx) void {
        if (!tx.spent) tx.db.exec("ROLLBACK;") catch {};
        tx.spent = true;
    }
};

/// The `writable` subset of `tables`: the entity families a device
/// writer mirrors (dimensions, content through `insertContent`,
/// playlists, my-tags). Cue, history, and hot-cue-bank authoring is
/// absent on purpose — fresh exports carry no rows there and rbox
/// offers no inserts for them either.
const write_tables = blk: {
    var selected: [tables.len]Table = undefined;
    var n: usize = 0;
    for (tables) |t| {
        if (t.writable) {
            selected[n] = t;
            n += 1;
        }
    }
    break :blk selected[0..n].*;
};

/// Options of `Writer.create`.
pub const CreateOptions = struct {
    /// Writes the db without the DLP passphrase — the plaintext side of
    /// `Db.openPlaintext` (fixtures and plain-SQLite consumers).
    plaintext: bool = false,
    /// Written to `property.createdDate` (`'YYYY-MM-DD'` in real
    /// exports). The library reads no clock; the caller supplies the date.
    created_date: []const u8,
    /// Written to `property.myTagMasterDBID` — derived from the master db
    /// in real exports; writers may leave 0 (rbox does).
    my_tag_master_dbid: i64 = 0,
};

/// A OneLibrary db opened for writing: `create` builds a fresh export's
/// db (schema, seeded defaults, the property singleton), `open` attaches
/// to an existing one, and both write through prepared SQL over the O2
/// row models — inserts bind NULL for null fields and copy text before
/// returning, so borrowed input is fine. First-class mutation is
/// append-only, mirroring the device writer's stance; there is no update.
/// The schema carries no foreign keys, so no method validates ids — tree
/// and junction semantics belong to the caller (the O4 device writer).
pub const Writer = struct {
    db: Db,

    /// Error of `create`: `LibraryAlreadyExists` is the exclusive claim
    /// refusing to build over an existing file; the rest is the claim's
    /// file creation and the SQLite calls.
    pub const CreateError = SqlError ||
        std.Io.File.OpenError ||
        error{LibraryAlreadyExists};

    /// Creates a fresh OneLibrary db at `path`: the real schema (see
    /// `schema_sql`), the four seeded tables' default rows, and the
    /// property singleton with `dbVersion` `'10000'`, all in one
    /// transaction — a failed create leaves no file behind, not a
    /// half-built db the claim below would then refuse to overwrite.
    /// The target is claimed with an exclusive create (O_EXCL), so a
    /// concurrent creator loses cleanly and the failure cleanup can only
    /// ever delete a file this call created. The db is keyed with the
    /// DLP passphrase unless `plaintext` is set, and starts in WAL
    /// journal mode like rb's exports.
    pub fn create(io: std.Io, path: [:0]const u8, options: CreateOptions) CreateError!Writer {
        const cwd = std.Io.Dir.cwd();
        // Claim the target exclusively: no window between an access
        // check and the create in which another writer could appear.
        if (cwd.createFile(io, path, .{ .exclusive = true })) |claim| {
            claim.close(io);
        } else |err| switch (err) {
            error.PathAlreadyExists => return error.LibraryAlreadyExists,
            else => return err,
        }

        const db = if (options.plaintext)
            try Db.openPlaintextReadWriteCreate(io, path)
        else
            try Db.openReadWriteCreate(io, path);
        errdefer {
            db.close();
            cwd.deleteFile(io, path) catch {};
        }

        // journal_mode cannot change inside a transaction; everything
        // else lands or leaves as one unit.
        try db.exec("PRAGMA journal_mode = WAL;");
        var tx = try Tx.begin(db);
        errdefer tx.deinit();
        try db.exec(schema_sql);
        try insertRows(db, "color", &default_colors);
        try insertRows(db, "menuItem", &default_menu_items);
        try insertRows(db, "category", &default_categories);
        try insertRows(db, "sort", &default_sorts);

        // rbox's migration seeds dbVersion 1000 as an INTEGER; real
        // exports carry the varchar '10000'.
        var property = try db.prepare(
            "INSERT INTO property (deviceName, dbVersion, numberOfContents, createdDate, backGroundColorType, myTagMasterDBID) " ++
                "VALUES ('', '10000', 0, ?1, 0, ?2);",
        );
        defer property.finalize();
        try property.bindText(1, options.created_date);
        try property.bindInt(2, options.my_tag_master_dbid);
        if ((try property.step()) != .done) return error.Sqlite;
        try tx.commit();

        return .{ .db = db };
    }

    /// Opens an existing OneLibrary db (keyed, read-write).
    pub fn open(io: std.Io, path: [:0]const u8) SqlError!Writer {
        return .{ .db = try Db.open(io, path) };
    }

    /// Folds the WAL back into the main file and truncates it, landing a
    /// complete db without closing the handle (the O4 save hook).
    pub fn checkpoint(self: Writer) SqlError!void {
        try self.db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
    }

    /// Checkpoints and closes. The file keeps its WAL-mode header flag —
    /// exactly the shape of rb's exports — and closing the last
    /// connection removes the sidecar files.
    pub fn close(self: Writer) SqlError!void {
        const folded = self.checkpoint();
        self.db.close();
        try folded;
    }

    /// Inserts one row of any `write_tables` family, primary key
    /// included: ids are the caller's to mint (`nextId`, or an ext tag's
    /// id when mirroring my-tags). A duplicate key fails with
    /// `error.Sqlite` and inserts nothing.
    pub fn insert(self: Writer, row: anytype) SqlError!void {
        const T = @TypeOf(row);
        if (T == Content)
            @compileError("insertContent maintains property.numberOfContents; use it for content rows");
        return insertRow(self.db, comptime tableOf(T), row);
    }

    /// Inserts many rows of one `write_tables` family atomically, through
    /// a single prepared statement stepped per row instead of a
    /// prepare/finalize pair per row — the bulk path for mirroring a
    /// library-sized batch. `rows` is any slice, array, or tuple of
    /// like-typed rows (`&batch`, `&.{ row, row }`). A `Content` batch
    /// maintains `property.numberOfContents` once, like `insertContent`;
    /// ids are the caller's to mint, and any failure — a duplicate key
    /// included — rolls the whole batch back.
    pub fn insertAll(self: Writer, rows: anytype) SqlError!void {
        if (rows.len == 0) return;
        const T = rowOf(@TypeOf(rows));
        var tx = try Tx.begin(self.db);
        errdefer tx.deinit();
        try insertRows(self.db, comptime tableOf(T), rows);
        if (T == Content) try maintainNumberOfContents(tx.db);
        try tx.commit();
    }

    /// Inserts one `content` row and keeps `property.numberOfContents`
    /// equal to the table count — both atomically, so a failure leaves
    /// the count consistent. Dimension and junction rows are separate
    /// `insert` calls (their orphaning risk is documented on the device
    /// writer's `addTrack`; the batch path is `insertAll`).
    pub fn insertContent(self: Writer, row: Content) SqlError!void {
        var tx = try Tx.begin(self.db);
        errdefer tx.deinit();
        try insertRow(self.db, "content", row);
        try maintainNumberOfContents(tx.db);
        try tx.commit();
    }

    /// Deletes the `content` row with `content_id` and maintains
    /// `property.numberOfContents`. Junction rows referencing the track
    /// are left in place — the schema carries no FK, and rbox's delete
    /// leaves them too.
    pub fn deleteContent(self: Writer, content_id: i64) SqlError!void {
        var tx = try Tx.begin(self.db);
        errdefer tx.deinit();
        var stmt = try self.db.prepare("DELETE FROM content WHERE content_id = ?1;");
        defer stmt.finalize();
        try stmt.bindInt(1, content_id);
        if ((try stmt.step()) != .done) return error.Sqlite;
        try maintainNumberOfContents(tx.db);
        try tx.commit();
    }

    /// `max(primary key) + 1` over `T`'s table — 1 when the table is
    /// empty, since id 0 is the null foreign key. Count-based, not
    /// monotonic: it reuses the id of a deleted last row, exactly like
    /// SQLite's own rowid assignment.
    pub fn nextId(self: Writer, comptime T: type) SqlError!i64 {
        const sql = comptime "SELECT COALESCE(MAX(" ++ pkOf(T) ++ "), 0) + 1 FROM " ++ tableOf(T) ++ ";";
        return self.db.scalarInt(sql);
    }

    /// The singleton property row's track count.
    pub fn numberOfContents(self: Writer) SqlError!i64 {
        return self.db.scalarInt("SELECT numberOfContents FROM property LIMIT 1;");
    }

    /// Appends a track to a playlist, assigning the next dense 1-based
    /// `sequenceNo` under that playlist (real exports number entries from
    /// 1) and returning it. One atomic INSERT; the keys are not validated
    /// (no FK in the schema — the caller owns tree semantics).
    pub fn addContentToPlaylist(self: Writer, playlist_id: i64, content_id: i64) SqlError!i64 {
        var stmt = try self.db.prepare(
            "INSERT INTO playlist_content (playlist_id, content_id, sequenceNo) VALUES (?1, ?2, " ++
                "(SELECT COALESCE(MAX(sequenceNo), 0) + 1 FROM playlist_content WHERE playlist_id = ?1)) " ++
                "RETURNING sequenceNo;",
        );
        defer stmt.finalize();
        try stmt.bindInt(1, playlist_id);
        try stmt.bindInt(2, content_id);
        if ((try stmt.step()) != .row) return error.Sqlite;
        const sequence_no = stmt.readInt(0);
        if ((try stmt.step()) != .done) return error.Sqlite;
        return sequence_no;
    }

    /// Appends many tracks to playlists atomically, through a single
    /// prepared statement stepped per pair instead of a
    /// prepare/finalize pair per row — the bulk path behind the device
    /// writer's playlist-pair drain. Each insert sees the ones before it,
    /// so the dense 1-based `sequenceNo`s are exactly
    /// `addContentToPlaylist`'s, continuing past rows already on disk.
    /// `pairs` is a slice, array, or tuple of structs carrying
    /// `playlist_id` and `content_id` fields; any failure rolls the whole
    /// batch back.
    pub fn addAllToPlaylist(self: Writer, pairs: anytype) SqlError!void {
        if (pairs.len == 0) return;
        var tx = try Tx.begin(self.db);
        errdefer tx.deinit();
        var stmt = try self.db.prepare(
            "INSERT INTO playlist_content (playlist_id, content_id, sequenceNo) VALUES (?1, ?2, " ++
                "(SELECT COALESCE(MAX(sequenceNo), 0) + 1 FROM playlist_content WHERE playlist_id = ?1));",
        );
        defer stmt.finalize();
        for (pairs) |pair| {
            try stmt.bindInt(1, pair.playlist_id);
            try stmt.bindInt(2, pair.content_id);
            if ((try stmt.step()) != .done) return error.Sqlite;
            try stmt.resetAndClear();
        }
        try tx.commit();
    }
};

/// Count-derived `numberOfContents` maintenance (inside the caller's
/// transaction): always equal to `SELECT COUNT(*) FROM content`, never a
/// value a caller could pass stale.
fn maintainNumberOfContents(db: Db) SqlError!void {
    try db.exec("UPDATE property SET numberOfContents = (SELECT COUNT(*) FROM content);");
}

/// The SQL table behind a writable row type.
fn tableOf(comptime T: type) []const u8 {
    inline for (write_tables) |t| {
        if (T == t.row) return t.table;
    }
    @compileError("Writer does not write " ++ @typeName(T));
}

/// The primary-key column of a row type — the first field, which every
/// keyed model declares first (schema order). Junction rows fail the
/// check: their first column is nullable.
fn pkOf(comptime T: type) []const u8 {
    const field = @typeInfo(T).@"struct".fields[0];
    if (field.type != i64)
        @compileError(@typeName(T) ++ " has no primary-key first column");
    return field.name;
}

/// One INSERT, built and bound from the row's comptime layout — the
/// write-side mirror of `decodeRow`: null fields bind NULL (one of the
/// fixture's unset conventions), empty strings bind as themselves (the
/// other), and SQLite copies text before the call returns.
fn insertRow(db: Db, comptime table: []const u8, row: anytype) SqlError!void {
    var stmt = try db.prepare(comptime insertSql(table, @TypeOf(row)));
    defer stmt.finalize();
    try bindAndStep(stmt, row);
}

/// Many INSERTs of one table through one prepared statement — the path
/// behind `Writer.insertAll` and `Writer.create`'s seeding: prepare once,
/// then bind, step, and `resetAndClear` per row instead of paying a
/// prepare/finalize pair per row.
fn insertRows(db: Db, comptime table: []const u8, rows: anytype) SqlError!void {
    const T = rowOf(@TypeOf(rows));
    var stmt = try db.prepare(comptime insertSql(table, T));
    defer stmt.finalize();
    if (comptime tupleArg(@TypeOf(rows))) {
        // an anonymous batch literal coerces to the array it denotes,
        // so one plain loop covers every accepted shape
        const arr: [rows.len]T = if (@typeInfo(@TypeOf(rows)) == .pointer) rows.* else rows;
        for (arr) |row| try stepRow(stmt, row);
    } else {
        for (rows) |row| try stepRow(stmt, row);
    }
}

/// Binds one row's fields (primary key included), steps the INSERT, and
/// readies the statement for the next row of a batch.
fn stepRow(stmt: Stmt, row: anytype) SqlError!void {
    try bindAndStep(stmt, row);
    try stmt.resetAndClear();
}

/// The row type of an `insertAll`/`insertRows` batch argument: a slice,
/// an array or tuple, or a pointer to either — the shapes a caller
/// spells naturally (`&batch`, `&.{ row, row }`). `std.meta.Elem` alone
/// rejects tuple pointers, the type of an anonymous literal argument.
fn rowOf(comptime rows: type) type {
    switch (@typeInfo(rows)) {
        .pointer => |p| switch (p.size) {
            .slice => return p.child,
            .one => switch (@typeInfo(p.child)) {
                .@"array" => |a| return a.child,
                .@"struct" => |s| return tupleRow(s, rows),
                else => {},
            },
            else => {},
        },
        .@"array" => |a| return a.child,
        .@"struct" => |s| return tupleRow(s, rows),
        else => {},
    }
    @compileError("expected a slice, array, or tuple of rows, found " ++ @typeName(rows));
}

/// The row type of a (non-empty) tuple argument.
fn tupleRow(comptime s: std.builtin.Type.Struct, comptime rows: type) type {
    if (!s.is_tuple or s.fields.len == 0)
        @compileError("expected a slice, array, or tuple of rows, found " ++ @typeName(rows));
    return s.fields[0].type;
}

/// True for a tuple argument or a pointer to one.
fn tupleArg(comptime rows: type) bool {
    return switch (@typeInfo(rows)) {
        .@"struct" => |s| s.is_tuple,
        .pointer => |p| p.size == .one and
            @typeInfo(p.child) == .@"struct" and @typeInfo(p.child).@"struct".is_tuple,
        else => false,
    };
}

/// Binds one row's fields (primary key included) and steps the INSERT.
fn bindAndStep(stmt: Stmt, row: anytype) SqlError!void {
    inline for (@typeInfo(@TypeOf(row)).@"struct".fields, 1..) |f, i|
        try bindCell(stmt, i, @field(row, f.name));
    if ((try stmt.step()) != .done) return error.Sqlite;
}

fn insertSql(comptime table: []const u8, comptime T: type) [:0]const u8 {
    comptime {
        // content's 47 columns push the concatenation past the default quota
        @setEvalBranchQuota(100_000);
        var sql: []const u8 = "INSERT INTO " ++ table ++ " (";
        for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ f.name;
        }
        sql = sql ++ ") VALUES (";
        for (@typeInfo(T).@"struct".fields, 0..) |_, i| {
            if (i > 0) sql = sql ++ ", ";
            sql = sql ++ std.fmt.comptimePrint("?{d}", .{i + 1});
        }
        return sql ++ ");";
    }
}

fn bindCell(stmt: Stmt, i: usize, cell: anytype) SqlError!void {
    return switch (@TypeOf(cell)) {
        i64 => stmt.bindInt(i, cell),
        ?i64 => if (cell) |v| stmt.bindInt(i, v) else stmt.bindNull(i),
        []const u8 => stmt.bindText(i, cell),
        ?[]const u8 => if (cell) |v| stmt.bindText(i, v) else stmt.bindNull(i),
        else => @compileError("unsupported OneLibrary column type: " ++ @typeName(@TypeOf(cell))),
    };
}
