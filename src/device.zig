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
