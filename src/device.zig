// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! On-disk layout of a Rekordbox device export: where `export.pdb`,
//! `exportExt.pdb`, the `*SETTING.DAT` files and the `PIONEER`/`USBANLZ`/
//! `Contents` directories live relative to the device root, plus the
//! handle that opens an export's settings and database through that
//! layout, and builds fresh ones.
//!
//! Ported from rekordcrate's `src/device/layout.rs` and
//! `src/device/reader.rs`/`writer.rs`.

const std = @import("std");
const bin = @import("bin");
const pdb = @import("pdb");
const setting = @import("setting");

/// Error of the layout functions that hash or format an audio path.
pub const PathError = error{ OutOfMemory, InvalidUtf8 };

/// Which settings payload a `*SETTING.DAT` file carries.
pub const SettingKind = enum {
    dev_setting,
    djm_my_setting,
    my_setting,
    my_setting2,
};

/// One of the `*SETTING.DAT` files in a device export.
pub const DatFile = struct {
    /// File name under `PIONEER`.
    name: []const u8,
    kind: SettingKind,
};

/// The `*SETTING.DAT` files in a device export, in the order Rekordbox
/// writes them.
pub const dat_files = [_]DatFile{
    .{ .name = "DEVSETTING.DAT", .kind = .dev_setting },
    .{ .name = "DJMMYSETTING.DAT", .kind = .djm_my_setting },
    .{ .name = "MYSETTING.DAT", .kind = .my_setting },
    .{ .name = "MYSETTING2.DAT", .kind = .my_setting2 },
};

/// On-disk layout of a device export rooted at `root`. Derives all paths
/// from it on demand; every method returns a slice the caller owns.
///
/// Exposed so expert callers can locate `exportPdb`/`exportExtPdb` and the
/// surrounding `PIONEER`/`Contents` directories directly, for manual
/// inspection or modification outside the high-level reader/writer.
pub const Layout = struct {
    /// The device root directory, as a host path.
    root: []const u8,

    pub fn pioneerDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER" });
    }

    /// Directory holding the pdb files.
    pub fn rekordboxDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox" });
    }

    pub fn exportPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "export.pdb" });
    }

    pub fn exportExtPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "exportExt.pdb" });
    }

    /// Directory holding per-track analysis files.
    pub fn usbanlzDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "USBANLZ" });
    }

    /// Directory holding audio files.
    pub fn contentsDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "Contents" });
    }

    /// Path to `filename` under `PIONEER`.
    pub fn datPath(
        l: Layout,
        alloc: std.mem.Allocator,
        filename: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", filename });
    }

    /// Per-track analysis directory `PIONEER/USBANLZ/P{XXX}/{HHHHHHHH}`,
    /// computed from `audio_path`; see `pathHash` for the format
    /// `audio_path` must have.
    pub fn anlzDir(l: Layout, alloc: std.mem.Allocator, audio_path: []const u8) PathError![]u8 {
        var p_folder: [4]u8 = undefined;
        var leaf_folder: [8]u8 = undefined;
        const names = anlzFolderNames(try pathHash(audio_path), &p_folder, &leaf_folder);
        return std.fs.path.join(
            alloc,
            &.{ l.root, "PIONEER", "USBANLZ", names.p_folder, names.leaf_folder },
        );
    }

    /// Host path to a track's `ANLZ0000.DAT` (base sections: beatgrid,
    /// cues, mono waveforms).
    pub fn anlzDatFile(l: Layout, alloc: std.mem.Allocator, audio_path: []const u8) PathError![]u8 {
        return l.anlzFile(alloc, audio_path, "ANLZ0000.DAT");
    }

    /// Host path to a track's `ANLZ0000.EXT` (Nexus-era colored waveforms +
    /// song structure).
    pub fn anlzExtFile(
        l: Layout,
        alloc: std.mem.Allocator,
        audio_path: []const u8,
    ) PathError![]u8 {
        return l.anlzFile(alloc, audio_path, "ANLZ0000.EXT");
    }

    /// Host path to a track's `ANLZ0000.2EX` (newest 3-band waveforms +
    /// per-band calibration).
    pub fn anlz2exFile(
        l: Layout,
        alloc: std.mem.Allocator,
        audio_path: []const u8,
    ) PathError![]u8 {
        return l.anlzFile(alloc, audio_path, "ANLZ0000.2EX");
    }

    fn anlzFile(
        l: Layout,
        alloc: std.mem.Allocator,
        audio_path: []const u8,
        filename: []const u8,
    ) PathError![]u8 {
        const dir = try l.anlzDir(alloc, audio_path);
        defer alloc.free(dir);
        return std.fs.path.join(alloc, &.{ dir, filename });
    }
};

/// Result of `pathHash`: the two values that name a track's analysis
/// directory under `PIONEER/USBANLZ`.
pub const PathHash = struct {
    /// 7-bit value assembled from scattered bits of `hash`; names the
    /// `P` folder in hexadecimal, three digits.
    p_value: u16,
    /// Rolling-hash result reduced modulo 200 003; names the leaf folder in
    /// hexadecimal, eight digits.
    hash: u32,
};

/// Compute the Pioneer `(p_value, hash)` pair for `audio_path`: the path
/// relative to the drive root, starting with a leading slash (e.g.
/// `/Contents/Artist/Album/01 Title.mp3`).
///
/// Pioneer CDJ/XDJ hardware ignores the pdb `analyze_path` and recomputes
/// the analysis directory from this hash, so the on-disk layout must match
/// it for waveforms to display. Algorithm reverse-engineered from
/// rekordbox's `CreateAnlzFileFolderPath`: the path is hashed as UTF-16
/// code units with a custom rolling hash, reduced modulo 200 003 (prime),
/// and a 7-bit P value is then extracted from scattered bits of the result.
///
/// Characters outside the BMP contribute only their low 16 bits instead of
/// a proper surrogate pair; non-BMP paths therefore collide with unrelated
/// BMP ones, matching observed rekordbox behavior for the sanitized paths
/// it produces.
pub fn pathHash(audio_path: []const u8) error{InvalidUtf8}!PathHash {
    var hash: u32 = 0;

    var it = (try std.unicode.Utf8View.init(audio_path)).iterator();
    while (it.nextCodepoint()) |c| {
        const code_unit: u32 = c & 0xFFFF;
        const temp = hash *% 0x5BC9 +% code_unit;
        hash = temp *% 0x93B5 +% code_unit;
    }

    const hash_result = hash % 0x30D43; // modulo 200 003 (prime)

    var p_value: u16 = 0;
    p_value |= @intCast(hash_result & 1); // bit 0  -> bit 0
    p_value |= @intCast((hash_result >> 1) & 2); // bit 2  -> bit 1
    p_value |= @intCast((hash_result >> 4) & 4); // bit 6  -> bit 2
    p_value |= @intCast((hash_result >> 4) & 8); // bit 7  -> bit 3
    p_value |= @intCast((hash_result >> 5) & 0x10); // bit 9  -> bit 4
    p_value |= @intCast((hash_result >> 8) & 0x20); // bit 13 -> bit 5
    p_value |= @intCast((hash_result >> 10) & 0x40); // bit 16 -> bit 6

    return .{ .p_value = p_value, .hash = hash_result };
}

/// Formats a path hash's two folder names — `P{XXX}` and `{HHHHHHHH}`.
/// The buffers exactly fit every value `pathHash` produces, so the prints
/// cannot fail; the returned slices point into the buffers.
fn anlzFolderNames(
    h: PathHash,
    p_folder: *[4]u8,
    leaf_folder: *[8]u8,
) struct { p_folder: []const u8, leaf_folder: []const u8 } {
    return .{
        .p_folder = std.fmt.bufPrint(p_folder, "P{X:0>3}", .{h.p_value}) catch unreachable,
        .leaf_folder = std.fmt.bufPrint(leaf_folder, "{X:0>8}", .{h.hash}) catch unreachable,
    };
}

/// Device-relative path stored in the pdb `analyze_path` column: the `.DAT`
/// the player loads first; sibling `.EXT`/`.2EX` are found by extension
/// substitution on the same stem. Computed from `audio_path` via
/// `pathHash`.
pub fn anlzDevicePath(alloc: std.mem.Allocator, audio_path: []const u8) PathError![]u8 {
    var p_folder: [4]u8 = undefined;
    var leaf_folder: [8]u8 = undefined;
    const names = anlzFolderNames(try pathHash(audio_path), &p_folder, &leaf_folder);
    return std.fmt.allocPrint(
        alloc,
        "/PIONEER/USBANLZ/{s}/{s}/ANLZ0000.DAT",
        .{ names.p_folder, names.leaf_folder },
    );
}

/// Image codec an artwork file must use.
pub const ArtworkCodec = enum {
    jpeg,
};

/// Pixel dimensions of an artwork file.
pub const Resolution = struct {
    width: u16,
    height: u16,
};

/// What a caller must create on the device for an artwork row with `id`:
/// two JPEG files under the `PIONEER/Artwork` shard folder. The caller
/// writes the files and stores `thumbnail_path` in the pdb Artwork row, as
/// Rekordbox does.
pub const ArtworkSpec = struct {
    /// Device-root-absolute path of the 80x80 thumbnail `a{id}.jpg` — the
    /// path stored in the pdb Artwork row.
    thumbnail_path: []u8,
    /// Device-root-absolute path of the 240x240 image `a{id}_m.jpg`.
    medium_path: []u8,
    codec: ArtworkCodec,
    thumbnail_resolution: Resolution,
    medium_resolution: Resolution,

    pub fn deinit(spec: *ArtworkSpec, alloc: std.mem.Allocator) void {
        alloc.free(spec.thumbnail_path);
        alloc.free(spec.medium_path);
    }
};

/// Builds the `ArtworkSpec` for artwork row `id`.
pub fn artworkSpec(alloc: std.mem.Allocator, id: u32) std.mem.Allocator.Error!ArtworkSpec {
    const folder = try artworkFolder(alloc, id);
    defer alloc.free(folder);
    const thumbnail_path = try std.fmt.allocPrint(
        alloc,
        "/PIONEER/Artwork/{s}/a{d}.jpg",
        .{ folder, id },
    );
    errdefer alloc.free(thumbnail_path);
    const medium_path = try std.fmt.allocPrint(
        alloc,
        "/PIONEER/Artwork/{s}/a{d}_m.jpg",
        .{ folder, id },
    );
    return .{
        .thumbnail_path = thumbnail_path,
        .medium_path = medium_path,
        .codec = .jpeg,
        .thumbnail_resolution = .{ .width = 80, .height = 80 },
        .medium_resolution = .{ .width = 240, .height = 240 },
    };
}

/// Five-digit shard folder name for artwork `id`: `id/20 + 1`, zero-padded.
pub fn artworkFolder(alloc: std.mem.Allocator, id: u32) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{d:0>5}", .{id / 20 + 1});
}

pub fn SettingPayload(comptime kind: SettingKind) type {
    return switch (kind) {
        .dev_setting => setting.DevSetting,
        .djm_my_setting => setting.DJMMySetting,
        .my_setting => setting.MySetting,
        .my_setting2 => setting.MySetting2,
    };
}

/// The parsed payloads of the four `*SETTING.DAT` files. A file that is
/// missing, unreadable, or invalid leaves its field null.
pub const Settings = struct {
    dev_setting: ?setting.DevSetting = null,
    djm_my_setting: ?setting.DJMMySetting = null,
    my_setting: ?setting.MySetting = null,
    my_setting2: ?setting.MySetting2 = null,
};

/// Size cap when reading a `*SETTING.DAT` file; the largest known payload
/// is a few hundred bytes.
const dat_limit = std.Io.Limit.limited(1 << 16);

/// Reads and parses one `*SETTING.DAT` file, returning null on any failure.
fn loadSettingFile(
    comptime Payload: type,
    io: std.Io,
    alloc: std.mem.Allocator,
    layout: Layout,
    filename: []const u8,
) ?Payload {
    const path = layout.datPath(alloc, filename) catch return null;
    defer alloc.free(path);
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, dat_limit) catch return null;
    defer alloc.free(buf);
    const parsed = setting.Setting(Payload).parse(buf) catch return null;
    return parsed.data;
}

/// Error of `DeviceExport.openPdb`: reading `export.pdb` off disk or
/// parsing it.
pub const OpenPdbError = std.Io.Dir.ReadFileAllocError || pdb.DatabaseDecodeError;

/// Size cap when reading an `export.pdb`; the largest fixture is 2.9 MB.
const pdb_limit = std.Io.Limit.limited(1 << 26);

/// Error of `DeviceExport.create`: `ExportAlreadyExists` is the
/// exists-guard refusing a root that already carries a
/// `PIONEER/rekordbox/export.pdb`; the rest is building the in-memory
/// database and setting images.
pub const CreateError =
    std.Io.Dir.AccessError ||
    pdb.DatabaseModifyError ||
    bin.WriteError ||
    error{ExportAlreadyExists};

/// Error of the temp-file-then-rename write `save` performs per file.
pub const AtomicWriteError =
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.Dir.RenameError;

/// Error of `DeviceExport.save`.
pub const SaveError =
    OpenPdbError ||
    pdb.DatabaseEncodeError ||
    pdb.ValidateAllTrackRowsError ||
    std.Io.Dir.CreateDirPathError ||
    AtomicWriteError;

/// Error of `DeviceExport.writerState`: reading or parsing
/// `export.pdb`, or scanning it.
pub const WriterStateError = OpenPdbError || ScanError;

/// A handle to a Rekordbox device export on disk: the setting files and
/// the pdb database, located through `Layout`. `open` points the handle
/// at an existing export (reading; the `openPdb` escape hatch edits),
/// `create` builds a fresh one in memory. `save` is the only call that
/// writes; `deinit` discards whatever was never saved. Files the export
/// carries but the handle does not model are ignored by design:
/// `djprofile.nxs` (undocumented) and `exportLibrary.db`.
pub const DeviceExport = struct {
    layout: Layout,
    io: std.Io,
    alloc: std.mem.Allocator,
    /// The export's pdb, loaded on the first pdb-touching call — `open`
    /// stays cheap for settings-only sessions.
    pdb_state: PdbState = .unloaded,
    /// Serialized default `*SETTING.DAT` images waiting for the first
    /// `save` of a created export; always null for opened ones.
    pending_settings: ?[dat_files.len][]u8 = null,
    /// The writer's cached scan of the export — id counters and dedup
    /// maps — null until `writerState` builds it on first use.
    writer_state: ?WriterState = null,

    const PdbState = union(enum) {
        /// An export opened at `root`; the pdb parses on first touch.
        unloaded,
        /// In memory — parsed from disk or built by `create`.
        loaded: pdb.Database,
    };

    /// Points the handle at a device export on disk (a directory
    /// containing `PIONEER`). Cheap and infallible: nothing is read until
    /// a pdb-touching call. The root path is borrowed; keep it alive
    /// until `deinit`.
    pub fn open(root_path: []const u8, io: std.Io, alloc: std.mem.Allocator) DeviceExport {
        return .{ .layout = .{ .root = root_path }, .io = io, .alloc = alloc };
    }

    /// Builds a fresh export in memory: a created pdb carrying the fixed
    /// 20-table layout (the `Unknown` slots must stay in place or CDJ
    /// players crash) with the default color, column, and menu rows, plus
    /// the four default setting files. Nothing touches the disk until
    /// `save`, so a `deinit` without one leaves nothing behind.
    pub fn create(
        root_path: []const u8,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) CreateError!DeviceExport {
        const layout = Layout{ .root = root_path };

        // Exists-guard the oracle lacks: its `create_dir_all` silently
        // orphans an existing export instead of refusing.
        const pdb_path = try layout.exportPdb(alloc);
        defer alloc.free(pdb_path);
        if (std.Io.Dir.cwd().access(io, pdb_path, .{})) |_| {
            return error.ExportAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
        errdefer db.deinit();
        try pdb.insertDefaultColors(&db);
        try pdb.insertDefaultColumns(&db);
        try pdb.insertDefaultMenus(&db);

        var pending: [dat_files.len][]u8 = undefined;
        var pending_filled: usize = 0;
        errdefer for (pending[0..pending_filled]) |bytes| alloc.free(bytes);
        inline for (dat_files) |dat| {
            pending[pending_filled] = try setting.Setting(SettingPayload(dat.kind)).default().serialize(alloc);
            pending_filled += 1;
        }

        return .{
            .layout = layout,
            .io = io,
            .alloc = alloc,
            .pdb_state = .{ .loaded = db },
            .pending_settings = pending,
            // Fresh counters — id 0 is the null FK — and empty maps: the
            // default color/column/menu rows live in tables the writer
            // doesn't track.
            .writer_state = .{},
        };
    }

    /// Frees everything the handle holds. Unsaved state is discarded —
    /// there is no implicit flush; a created export that never called
    /// `save` leaves nothing on disk.
    pub fn deinit(e: *DeviceExport) void {
        switch (e.pdb_state) {
            .loaded => |*db| db.deinit(),
            .unloaded => {},
        }
        if (e.pending_settings) |pending| {
            for (pending) |bytes| e.alloc.free(bytes);
        }
        if (e.writer_state) |*state| state.deinit(e.alloc);
    }

    pub fn root(e: *const DeviceExport) []const u8 {
        return e.layout.root;
    }

    /// Loads the four `*SETTING.DAT` files in `dat_files` order. A file
    /// that is missing, unreadable, or invalid leaves its field null —
    /// settings loading is the tolerant side of the handle; pdb errors
    /// are fatal.
    pub fn loadSettings(e: *const DeviceExport) Settings {
        var settings = Settings{};
        inline for (dat_files) |dat| {
            const payload = loadSettingFile(
                SettingPayload(dat.kind),
                e.io,
                e.alloc,
                e.layout,
                dat.name,
            );
            if (payload) |data| {
                @field(settings, @tagName(dat.kind)) = data;
            }
        }
        return settings;
    }

    /// The export's database, parsing it off disk on first call. Also the
    /// escape hatch for row surgery: edits made here bypass the writer's
    /// id counters and dedup maps (which scan once, at the first
    /// first-class mutating call) and reach the disk at the next `save`.
    pub fn openPdb(e: *DeviceExport) OpenPdbError!*pdb.Database {
        switch (e.pdb_state) {
            .loaded => |*db| return db,
            .unloaded => {
                const path = try e.layout.exportPdb(e.alloc);
                defer e.alloc.free(path);
                const buf = try std.Io.Dir.cwd().readFileAlloc(e.io, path, e.alloc, pdb_limit);
                defer e.alloc.free(buf);
                e.pdb_state = .{ .loaded = try pdb.Database.parse(e.alloc, buf, .plain) };
                return &e.pdb_state.loaded;
            },
        }
    }

    /// The export's playlist tree (see `getPlaylistsDb` for the shape and
    /// ownership rules).
    pub fn getPlaylists(
        e: *DeviceExport,
    ) (OpenPdbError || PlaylistTreeError)!std.ArrayList(PlaylistNode) {
        return getPlaylistsDb(e.alloc, try e.openPdb());
    }

    /// The writer's cached scan of the export: id counters and dedup
    /// maps, rebuilt from the database on the first call (loading the
    /// pdb first if needed). The mutating methods call this before they
    /// touch the database, so read-only sessions never pay for it;
    /// calling it directly only warms the cache early. Rows added
    /// through the `openPdb` escape hatch after the state was built are
    /// invisible to it.
    pub fn writerState(e: *DeviceExport) WriterStateError!*WriterState {
        if (e.writer_state == null) {
            const db = try e.openPdb();
            e.writer_state = try scanWriterState(e.alloc, db);
        }
        return &e.writer_state.?;
    }

    /// Writes the buffered export to disk — the handle's only
    /// disk-writing call. Crash-safe order: the default directory tree
    /// and the four setting files (a created export's first `save` only;
    /// DATs are never rewritten later, and opened exports never write
    /// them), then the other files the writer owns, and `export.pdb` —
    /// the index everything else is reached through — last, so a crash
    /// leaves orphan files players ignore, not rows naming missing data.
    /// Every file lands through a same-directory temp file and an atomic
    /// rename: readers see the old or the new file, never a torn one, and
    /// a second `save` is byte-stable.
    pub fn save(e: *DeviceExport) SaveError!void {
        if (e.pending_settings) |pending| {
            const cwd = std.Io.Dir.cwd();
            const dirs = [_][]const u8{
                try e.layout.rekordboxDir(e.alloc),
                try e.layout.usbanlzDir(e.alloc),
                try e.layout.contentsDir(e.alloc),
            };
            defer {
                for (dirs) |dir| e.alloc.free(dir);
            }
            for (dirs) |dir| try cwd.createDirPath(e.io, dir);

            // A failed write leaves every image owned by
            // `pending_settings`, so `deinit` reclaims them; they are
            // freed only once all four have landed.
            inline for (dat_files, 0..) |dat, i| {
                const path = try e.layout.datPath(e.alloc, dat.name);
                defer e.alloc.free(path);
                try e.writeFileAtomic(path, pending[i]);
            }
            for (pending) |bytes| e.alloc.free(bytes);
            e.pending_settings = null;
        }

        const db = try e.openPdb();
        try db.validateAllTrackRows();
        const image = try db.serialize(e.alloc);
        defer e.alloc.free(image);
        const pdb_path = try e.layout.exportPdb(e.alloc);
        defer e.alloc.free(pdb_path);
        try e.writeFileAtomic(pdb_path, image);
    }

    /// Writes `bytes` to `path` through a same-directory temp file and an
    /// atomic rename.
    fn writeFileAtomic(e: *DeviceExport, path: []const u8, bytes: []const u8) AtomicWriteError!void {
        var af = try std.Io.Dir.cwd().createFileAtomic(e.io, path, .{ .replace = true });
        defer af.deinit(e.io);
        try af.file.writeStreamingAll(e.io, bytes);
        try af.replace(e.io);
    }
};

/// A playlist (leaf of the playlist tree).
pub const Playlist = struct {
    /// ID of this node in the playlist tree.
    id: u32,
    name: []u8,
};

/// A playlist folder, grouping other nodes.
pub const PlaylistFolder = struct {
    /// ID of this node in the playlist tree.
    id: u32,
    name: []u8,
    /// Child nodes, in row order.
    children: std.ArrayList(PlaylistNode),
};

/// Either a playlist folder or a playlist.
pub const PlaylistNode = union(enum) {
    folder: PlaylistFolder,
    playlist: Playlist,

    /// Frees the node's name and, for a folder, its children recursively.
    pub fn deinit(node: *PlaylistNode, alloc: std.mem.Allocator) void {
        switch (node.*) {
            .folder => |*folder| {
                for (folder.children.items) |*child| child.deinit(alloc);
                folder.children.deinit(alloc);
                alloc.free(folder.name);
            },
            .playlist => |*playlist| alloc.free(playlist.name),
        }
    }
};

/// Error of the playlist-tree walk.
pub const PlaylistTreeError = pdb.RowIterError || error{ InvalidEncoding, OutOfMemory };

/// Playlist-tree rows grouped by their parent id.
const PlaylistGroups = std.AutoHashMap(u32, std.ArrayList(*const pdb.PlaylistTreeNode));

/// Frees the grouping map built by `getPlaylists`.
fn deinitGroups(alloc: std.mem.Allocator, groups: *PlaylistGroups) void {
    var it = groups.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(alloc);
    groups.deinit();
}

/// Appends the children of `parent` to `out`, in row order, recursing into
/// folders.
fn buildChildren(
    alloc: std.mem.Allocator,
    groups: *const PlaylistGroups,
    visited: *std.AutoHashMap(u32, void),
    parent: u32,
    out: *std.ArrayList(PlaylistNode),
) PlaylistTreeError!void {
    const nodes = groups.get(parent) orelse return;
    for (nodes.items) |node| {
        if (node.isFolder() and (try visited.getOrPut(node.id)).found_existing) continue;
        const name = try node.name.utf8(alloc);
        errdefer alloc.free(name);
        if (node.isFolder()) {
            var children = std.ArrayList(PlaylistNode).empty;
            errdefer {
                for (children.items) |*child| child.deinit(alloc);
                children.deinit(alloc);
            }
            try buildChildren(alloc, groups, visited, node.id, &children);
            try out.append(alloc, .{ .folder = .{
                .id = node.id,
                .name = name,
                .children = children,
            } });
        } else {
            try out.append(alloc, .{ .playlist = .{ .id = node.id, .name = name } });
        }
    }
}

/// Builds the playlist tree from a database's playlist-tree rows: nodes
/// parented to 0 form the top level, folders recurse into their children,
/// and names are decoded to owned UTF-8. Nodes unreachable from the root
/// (parented to a missing id) do not appear, as in rekordcrate; a folder id
/// is expanded at most once, so parent-id cycles in corrupt data cannot
/// recurse forever.
///
/// The caller owns the returned list; free it by deinitializing every
/// element and then the list itself:
///
///     var playlists = try device.getPlaylistsDb(alloc, &db);
///     defer {
///         for (playlists.items) |*node| node.deinit(alloc);
///         playlists.deinit(alloc);
///     }
pub fn getPlaylistsDb(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
) PlaylistTreeError!std.ArrayList(PlaylistNode) {
    var groups = PlaylistGroups.init(alloc);
    defer deinitGroups(alloc, &groups);

    var it = try db.rows(.playlist_tree);
    while (try it.next()) |row| switch (row.*) {
        .playlist_tree_node => |node| {
            const gop = try groups.getOrPut(node.parent_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, node);
        },
        else => {},
    };

    var visited = std.AutoHashMap(u32, void).init(alloc);
    defer visited.deinit();

    var roots = std.ArrayList(PlaylistNode).empty;
    errdefer {
        for (roots.items) |*node| node.deinit(alloc);
        roots.deinit(alloc);
    }
    try buildChildren(alloc, &groups, &visited, 0, &roots);
    return roots;
}

// --- writer state (D5) ---------------------------------------------------------

/// Folds a musical key name to a canonical form for deduplication
/// (`C Major`/`Cmaj`/`C MAJOR`/`Cmajor` → `Cmaj`), so different spellings
/// of one key share a single pdb Key row. The note letter keeps its case.
///
/// String-equality only: enharmonic equivalents (`B♭m` ≠ `A#m`), Camelot,
/// and Open Key notation are not resolved — different pitch spellings
/// still create distinct rows.
///
/// The walk matches tokens on the original text with ASCII case folding;
/// the oracle lowercases a copy first and indexes back into the original
/// per character, which misaligns whenever lowercasing changes byte
/// length (e.g. `İ`). Output is identical on every input where the
/// oracle's indexing holds, and total here.
pub fn canonicalKeyName(alloc: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < trimmed.len) {
        // Order matters: longest tokens first, so `major` folds as one
        // token instead of matching `maj` and leaking the rest.
        const folded = [_]struct { token: []const u8, emit: []const u8 }{
            .{ .token = "major", .emit = "maj" },
            .{ .token = "minor", .emit = "min" },
            .{ .token = "flat", .emit = "b" },
            .{ .token = "sharp", .emit = "#" },
            .{ .token = "maj", .emit = "maj" },
            .{ .token = "min", .emit = "min" },
        };
        var matched = false;
        for (folded) |f| {
            if (asciiStartsWithIgnoreCase(trimmed[i..], f.token)) {
                try out.appendSlice(alloc, f.emit);
                i += f.token.len;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        // Not a recognized token: copy one codepoint through, folding the
        // unicode accidentals and dropping spaces on the way. The oracle
        // folds both in a second pass; folding while copying is
        // equivalent because tokens are pure ASCII and can never span a
        // folded character.
        const cp_len = std.unicode.utf8ByteSequenceLength(trimmed[i]) catch 1;
        const end = @min(i + cp_len, trimmed.len);
        const codepoint = trimmed[i..end];
        if (std.mem.eql(u8, codepoint, "♭")) {
            try out.append(alloc, 'b');
        } else if (std.mem.eql(u8, codepoint, "♯")) {
            try out.append(alloc, '#');
        } else if (codepoint.len != 1 or codepoint[0] != ' ') {
            try out.appendSlice(alloc, codepoint);
        }
        i = end;
    }

    // Bare trailing 'm' is minor ("Cm" → "Cmin"). 'm', "min" and "maj"
    // are ASCII, so the suffix checks cannot land inside a multi-byte
    // codepoint.
    if (out.items.len > 0 and out.items[out.items.len - 1] == 'm' and
        !std.mem.endsWith(u8, out.items, "min") and !std.mem.endsWith(u8, out.items, "maj"))
    {
        try out.appendSlice(alloc, "in");
    }

    return out.toOwnedSlice(alloc);
}

/// Whether `s` starts with the (lowercase) `token`, ignoring ASCII case.
fn asciiStartsWithIgnoreCase(s: []const u8, token: []const u8) bool {
    if (s.len < token.len) return false;
    for (s[0..token.len], token) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

/// Dedup key of an Album row: albums are per-artist.
pub const AlbumKey = struct {
    artist_id: u32,
    name: []const u8,
};

/// Content hash over `AlbumKey` — never the slice pointer.
const AlbumKeyContext = struct {
    pub fn hash(_: AlbumKeyContext, key: AlbumKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.artist_id));
        h.update(key.name);
        return h.final();
    }

    pub fn eql(_: AlbumKeyContext, a: AlbumKey, b: AlbumKey) bool {
        return a.artist_id == b.artist_id and std.mem.eql(u8, a.name, b.name);
    }
};

/// Albums keyed by `(owning artist, name)`.
pub const AlbumsByArtistAndName = std.HashMapUnmanaged(
    AlbumKey,
    u32,
    AlbumKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Dedup key of a leaf tag: the category it lives under plus its label.
pub const TagKey = struct {
    category_id: u32,
    label: []const u8,
};

const TagKeyContext = struct {
    pub fn hash(_: TagKeyContext, key: TagKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.category_id));
        h.update(key.label);
        return h.final();
    }

    pub fn eql(_: TagKeyContext, a: TagKey, b: TagKey) bool {
        return a.category_id == b.category_id and std.mem.eql(u8, a.label, b.label);
    }
};

/// Leaf tags keyed by `(category, label)`.
pub const TagsByKey = std.HashMapUnmanaged(
    TagKey,
    u32,
    TagKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// The writer's cached view of an export: one `next_*` id counter per
/// table it appends to, plus the dedup maps that let later inserts reuse
/// an existing row instead of duplicating it. Rebuilt from a plain
/// database by `scanWriterState` and extended over an ext database's tag
/// rows by `scanExtTags`; every string key is owned by the state and
/// freed by `deinit`.
pub const WriterState = struct {
    /// Next free id per table. Id 0 is the null foreign key, so the
    /// counters start at 1 and a scan leaves each one past the highest
    /// id that table carries.
    next_track_id: u32 = 1,
    next_artist_id: u32 = 1,
    next_album_id: u32 = 1,
    next_genre_id: u32 = 1,
    next_key_id: u32 = 1,
    next_label_id: u32 = 1,
    next_artwork_id: u32 = 1,
    next_playlist_node_id: u32 = 1,
    /// Shared id space for tag categories and leaf tags (0 = null FK).
    next_tag_id: u32 = 1,
    /// Next `position` for a top-level category (0-based, as on real
    /// exports).
    next_category_position: u32 = 0,
    /// Per-row monotonic counter driving tag `index_shift` (`0x20` per
    /// row, as observed on real exports).
    next_tag_row_index: u32 = 0,

    /// Known track ids, for playlist-membership FK checks.
    track_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// `id -> is_folder`. Root (id 0) is implicit — always a valid
    /// parent, always a folder.
    playlist_nodes: std.AutoHashMapUnmanaged(u32, bool) = .empty,
    /// Next `entry_index` per playlist: `max(entry_index) + 1`, not the
    /// row count, so a reopened export with sparse indices doesn't
    /// collide.
    playlist_entry_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Track ids by device file path (non-empty paths only; `add_track`
    /// dedups on this key).
    tracks_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    artists_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    albums_by_artist_and_name: AlbumsByArtistAndName = .empty,
    genres_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    /// Key names indexed under their canonical form (`canonicalKeyName`)
    /// so later lookups collide across spellings.
    keys_by_canonical: std.StringHashMapUnmanaged(u32) = .empty,
    labels_by_name: std.StringHashMapUnmanaged(u32) = .empty,
    artwork_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    /// Tag category ids, for leaf FK validation.
    tag_categories: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// `(category, label) -> tag id` leaf dedup.
    tags_by_key: TagsByKey = .empty,
    /// `category -> next leaf position` (dense from 0 within a
    /// category).
    tag_leaf_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn deinit(state: *WriterState, alloc: std.mem.Allocator) void {
        const string_maps = .{
            &state.tracks_by_path,
            &state.artists_by_name,
            &state.genres_by_name,
            &state.keys_by_canonical,
            &state.labels_by_name,
            &state.artwork_by_path,
        };
        inline for (string_maps) |map| {
            var it = map.iterator();
            while (it.next()) |entry| alloc.free(entry.key_ptr.*);
            map.deinit(alloc);
        }
        {
            var it = state.albums_by_artist_and_name.iterator();
            while (it.next()) |entry| alloc.free(entry.key_ptr.name);
            state.albums_by_artist_and_name.deinit(alloc);
        }
        {
            var it = state.tags_by_key.iterator();
            while (it.next()) |entry| alloc.free(entry.key_ptr.label);
            state.tags_by_key.deinit(alloc);
        }
        const id_maps = .{
            &state.track_ids,
            &state.playlist_nodes,
            &state.playlist_entry_counts,
            &state.tag_categories,
            &state.tag_leaf_counts,
        };
        inline for (id_maps) |map| map.deinit(alloc);
    }
};

/// Error of the writer-state scans: walking a table's page chain hit
/// structural corruption, or an allocation failed. A table the database
/// doesn't carry is not an error — `rowsOrEmpty` resolves tables up
/// front and scans them as empty; `NoTable` is only in the set because
/// `RowIterator` shares one.
pub const ScanError = error{
    OutOfMemory,
    NoTable,
    PageNotPresent,
    PageOrderViolation,
    UnparsedPage,
};

/// `Database.rows`, treating a table the database doesn't carry as empty
/// (standard exports carry all 20 tables; this keeps the scan total over
/// hand-built databases).
fn rowsOrEmpty(db: *const pdb.Database, page_type: pdb.PageType) ScanError!?pdb.RowIterator {
    return db.rows(page_type) catch |err| switch (err) {
        error.NoTable => null,
        else => |e| return e,
    };
}

/// Decodes a row string, treating invalid encoding as null — the row
/// still counts toward the id counters, only its map entry is skipped
/// (the oracle's `if let Ok(..)`).
fn decodeOrSkip(
    s: pdb.DeviceSQLString,
    alloc: std.mem.Allocator,
) ScanError!?[]u8 {
    return s.utf8(alloc) catch |err| switch (err) {
        error.InvalidEncoding => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Inserts `key -> value` unless `key` is already present — first row
/// wins, the oracle's `or_insert`. The caller-owned `key` is freed
/// immediately when it duplicates an existing entry, and owned by the
/// map afterwards.
fn putStringIfAbsent(
    map: *std.StringHashMapUnmanaged(u32),
    alloc: std.mem.Allocator,
    key: []u8,
    value: u32,
) std.mem.Allocator.Error!void {
    const gop = map.getOrPut(alloc, key) catch |err| {
        alloc.free(key);
        return err;
    };
    if (gop.found_existing) {
        alloc.free(key);
    } else {
        gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }
}

/// `putStringIfAbsent` for the album map, which owns only the key's
/// `name` slice.
fn putAlbumIfAbsent(
    map: *AlbumsByArtistAndName,
    alloc: std.mem.Allocator,
    key: AlbumKey,
    value: u32,
) std.mem.Allocator.Error!void {
    const gop = map.getOrPut(alloc, key) catch |err| {
        alloc.free(key.name);
        return err;
    };
    if (gop.found_existing) {
        alloc.free(key.name);
    } else {
        gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }
}

/// Scans a plain database into a fresh `WriterState`: one pass per
/// table, rebuilding the id counters (max id + 1) and the dedup maps the
/// writer consults before inserting. First row wins on duplicate map
/// keys, except `playlist_nodes`, where the last row wins (the oracle's
/// `or_insert` vs `insert`). Rows are walked through the page chain, so
/// deleted-row remnants in page heaps are invisible, exactly as to
/// readers.
pub fn scanWriterState(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
) ScanError!WriterState {
    var state = WriterState{};
    errdefer state.deinit(alloc);

    var it = try rowsOrEmpty(db, .tracks);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const track = row.track;
            try state.track_ids.put(alloc, track.id, {});
            state.next_track_id = @max(state.next_track_id, track.id +| 1);
            if (try decodeOrSkip(track.offsets.inner.file_path, alloc)) |path| {
                if (path.len > 0) {
                    try putStringIfAbsent(&state.tracks_by_path, alloc, path, track.id);
                } else {
                    alloc.free(path);
                }
            }
        }
    }

    it = try rowsOrEmpty(db, .artists);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const artist = row.artist;
            state.next_artist_id = @max(state.next_artist_id, artist.id +| 1);
            if (try decodeOrSkip(artist.offsets.inner.name, alloc)) |name| {
                try putStringIfAbsent(&state.artists_by_name, alloc, name, artist.id);
            }
        }
    }

    it = try rowsOrEmpty(db, .albums);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const album = row.album;
            state.next_album_id = @max(state.next_album_id, album.id +| 1);
            if (try decodeOrSkip(album.offsets.inner.name, alloc)) |name| {
                try putAlbumIfAbsent(
                    &state.albums_by_artist_and_name,
                    alloc,
                    .{ .artist_id = album.artist_id, .name = name },
                    album.id,
                );
            }
        }
    }

    it = try rowsOrEmpty(db, .genres);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const genre = row.genre;
            state.next_genre_id = @max(state.next_genre_id, genre.id +| 1);
            if (try decodeOrSkip(genre.name, alloc)) |name| {
                try putStringIfAbsent(&state.genres_by_name, alloc, name, genre.id);
            }
        }
    }

    it = try rowsOrEmpty(db, .keys);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const key = row.key;
            state.next_key_id = @max(state.next_key_id, key.id +| 1);
            if (try decodeOrSkip(key.name, alloc)) |name| {
                const canonical = try canonicalKeyName(alloc, name);
                alloc.free(name);
                try putStringIfAbsent(&state.keys_by_canonical, alloc, canonical, key.id);
            }
        }
    }

    it = try rowsOrEmpty(db, .labels);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const label = row.label;
            state.next_label_id = @max(state.next_label_id, label.id +| 1);
            if (try decodeOrSkip(label.name, alloc)) |name| {
                try putStringIfAbsent(&state.labels_by_name, alloc, name, label.id);
            }
        }
    }

    it = try rowsOrEmpty(db, .artwork);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const artwork = row.artwork;
            state.next_artwork_id = @max(state.next_artwork_id, artwork.id +| 1);
            if (try decodeOrSkip(artwork.path, alloc)) |path| {
                try putStringIfAbsent(&state.artwork_by_path, alloc, path, artwork.id);
            }
        }
    }

    it = try rowsOrEmpty(db, .playlist_tree);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const node = row.playlist_tree_node;
            state.next_playlist_node_id = @max(state.next_playlist_node_id, node.id +| 1);
            try state.playlist_nodes.put(alloc, node.id, node.isFolder());
        }
    }

    it = try rowsOrEmpty(db, .playlist_entries);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const entry = row.playlist_entry;
            const gop = try state.playlist_entry_counts.getOrPut(alloc, entry.playlist_id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* = @max(gop.value_ptr.*, entry.entry_index +| 1);
        }
    }

    return state;
}

/// `putStringIfAbsent` for the leaf-tag map, which owns only the key's
/// `label` slice.
fn putTagKeyIfAbsent(
    map: *TagsByKey,
    alloc: std.mem.Allocator,
    key: TagKey,
    value: u32,
) std.mem.Allocator.Error!void {
    const gop = map.getOrPut(alloc, key) catch |err| {
        alloc.free(key.label);
        return err;
    };
    if (gop.found_existing) {
        alloc.free(key.label);
    } else {
        gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }
}

/// Extends a `WriterState` with the tag state recovered from an ext
/// database, so later tag calls append instead of colliding or
/// truncating: counters past every Tag row's id and `index_shift`, the
/// category set, and the leaf dedup map. TrackTag junction rows carry no
/// state the writer tracks — their ids reference tag rows already
/// counted here — so they are not scanned. On error the state keeps
/// whatever was merged so far; callers treat a failed scan as fatal for
/// the session.
pub fn scanExtTags(
    alloc: std.mem.Allocator,
    ext_db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    // PageType 3 means albums in a plain database and Tag pages in an
    // ext one; tables are looked up by raw value, so the ext table is
    // found by passing the colliding value.
    var it = try rowsOrEmpty(ext_db, @enumFromInt(@intFromEnum(pdb.ExtPageType.tag)));
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const tag = row.tag;
            state.next_tag_id = @max(state.next_tag_id, tag.id +| 1);
            state.next_tag_row_index = @max(
                state.next_tag_row_index,
                @as(u32, tag.index_shift) / 0x20 +| 1,
            );
            if (tag.raw_is_category != 0) {
                try state.tag_categories.put(alloc, tag.id, {});
                state.next_category_position = @max(state.next_category_position, tag.position +| 1);
            } else {
                if (try decodeOrSkip(tag.offsets.inner.name, alloc)) |label| {
                    try putTagKeyIfAbsent(
                        &state.tags_by_key,
                        alloc,
                        .{ .category_id = tag.parent_id, .label = label },
                        tag.id,
                    );
                }
                const gop = try state.tag_leaf_counts.getOrPut(alloc, tag.parent_id);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = @max(gop.value_ptr.*, tag.position +| 1);
            }
        }
    }
}
