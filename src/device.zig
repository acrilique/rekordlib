// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! On-disk layout of a Rekordbox device export: where `export.pdb`,
//! `exportExt.pdb`, the `*SETTING.DAT` files and the `PIONEER`/`USBANLZ`/
//! `Contents` directories live relative to the device root, plus the
//! read-side handle that opens an export's settings and database through
//! that layout.
//!
//! Ported from rekordcrate's `src/device/layout.rs` and
//! `src/device/reader.rs`.

const std = @import("std");
const pdb = @import("pdb");
const setting = @import("setting");

/// Error of the layout functions that hash or format an audio path.
pub const PathError = error{ OutOfMemory, InvalidUtf8 };

/// Which settings payload a `*SETTING.DAT` file carries; identifies the
/// parser for each entry of `dat_files`.
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
    /// Which settings format the file carries.
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

    /// The `PIONEER` directory.
    pub fn pioneerDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER" });
    }

    /// The `PIONEER/rekordbox` directory holding the pdb files.
    pub fn rekordboxDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox" });
    }

    /// Path to `export.pdb`.
    pub fn exportPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "export.pdb" });
    }

    /// Path to `exportExt.pdb`.
    pub fn exportExtPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "exportExt.pdb" });
    }

    /// The `PIONEER/USBANLZ` directory holding per-track analysis files.
    pub fn usbanlzDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "USBANLZ" });
    }

    /// The `Contents` directory holding audio files.
    pub fn contentsDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "Contents" });
    }

    /// Path to a `*SETTING.DAT` file by name, under `PIONEER`.
    pub fn datPath(
        l: Layout,
        alloc: std.mem.Allocator,
        filename: []const u8,
    ) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", filename });
    }

    /// Per-track analysis directory `PIONEER/USBANLZ/P{XXX}/{HHHHHHHH}`,
    /// keyed by the audio file's device-relative path. Pioneer hardware
    /// ignores the pdb `analyze_path` and recomputes this directory from the
    /// on-drive path, so it must match the algorithm in `pathHash`.
    ///
    /// `audio_path` is the path relative to the drive root, starting with a
    /// leading slash (e.g. `/Contents/Artist/Album/01 Title.mp3`).
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

/// Compute the Pioneer `(p_value, hash)` pair for an audio file's
/// device-relative path.
///
/// `audio_path` is the path relative to the drive root, starting with a
/// leading slash (e.g. `/Contents/Artist/Album/01 Title.mp3`). Pioneer
/// CDJ/XDJ hardware ignores the pdb `analyze_path` and recomputes the
/// analysis directory from this hash, so the on-disk layout must match it
/// for waveforms to display. Algorithm reverse-engineered from rekordbox's
/// `CreateAnlzFileFolderPath`: the path is hashed as UTF-16 code units with
/// a custom rolling hash, reduced modulo 200 003 (prime), and a 7-bit P
/// value is then extracted from scattered bits of the result. The same path
/// always yields the same directory, so re-syncs address the same analysis
/// folder.
///
/// Characters outside the BMP contribute only their low 16 bits instead of
/// a proper surrogate pair; non-BMP paths therefore collide with unrelated
/// BMP ones, matching observed rekordbox behavior for the sanitized paths
/// it produces.
pub fn pathHash(audio_path: []const u8) error{InvalidUtf8}!PathHash {
    var hash: u32 = 0;

    var it = (try std.unicode.Utf8View.init(audio_path)).iterator();
    while (it.nextCodepoint()) |c| {
        // Each code point is masked to a single UTF-16 code unit instead of
        // being encoded as a surrogate pair.
        const code_unit: u32 = c & 0xFFFF;
        const temp = hash *% 0x5BC9 +% code_unit;
        hash = temp *% 0x93B5 +% code_unit;
    }

    const hash_result = hash % 0x30D43; // modulo 200 003 (prime)

    // The P value is assembled from non-contiguous bits of the hash, in the
    // exact bit order the rekordbox disassembly extracts them.
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

/// Formats a path hash's two folder names — `P{XXX}` and `{HHHHHHHH}` —
/// the single source of the USBANLZ naming scheme. The buffers exactly fit
/// every value `pathHash` produces (`p_value` is 7 bits, `hash` is below
/// 200 003), so the prints fill them completely and cannot fail; the
/// returned slices point into the buffers.
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
/// substitution on the same stem. The path is keyed by the audio file's
/// device-relative path (with a leading slash), matching what Pioneer
/// hardware recomputes — see `pathHash`.
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

/// Image codec an artwork file must use (decision 5: the library delegates
/// media decoding and conversion to the caller).
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
    /// Codec both files must use.
    codec: ArtworkCodec,
    /// Dimensions of `thumbnail_path`.
    thumbnail_resolution: Resolution,
    /// Dimensions of `medium_path`.
    medium_resolution: Resolution,

    pub fn deinit(spec: *ArtworkSpec, alloc: std.mem.Allocator) void {
        alloc.free(spec.thumbnail_path);
        alloc.free(spec.medium_path);
    }
};

/// Describe the artwork files for `id` (decision 5: the library never
/// decodes or converts media; it only tells the caller what to write).
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

/// The settings payload a `*SETTING.DAT` kind carries (see `dat_files`).
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
///
/// rekordcrate instead flattens every individual setting into `Option`
/// fields of one `Settings` struct; that shape exists for its `Display`
/// impl, which the no-dump decision (roadmap decision 1) does not need —
/// see `docs/DIVERGENCES.md`.
pub const Settings = struct {
    dev_setting: ?setting.DevSetting = null,
    djm_my_setting: ?setting.DJMMySetting = null,
    my_setting: ?setting.MySetting = null,
    my_setting2: ?setting.MySetting2 = null,
};

/// Size cap when reading a `*SETTING.DAT` file; the largest known payload
/// is a few hundred bytes.
const dat_limit = std.Io.Limit.limited(1 << 16);

/// Reads and parses one `*SETTING.DAT` file; a missing, unreadable, or
/// invalid file is reported as a warning and as null.
fn loadSettingFile(
    comptime Payload: type,
    io: std.Io,
    alloc: std.mem.Allocator,
    layout: Layout,
    filename: []const u8,
) ?Payload {
    const path = layout.datPath(alloc, filename) catch return null;
    defer alloc.free(path);
    const buf = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, dat_limit) catch |err| {
        std.log.warn("could not load {s}: {t}", .{ path, err });
        return null;
    };
    defer alloc.free(buf);
    const parsed = setting.Setting(Payload).parse(buf) catch |err| {
        std.log.warn("could not load {s}: {t}", .{ path, err });
        return null;
    };
    return parsed.data;
}

/// Error of `DeviceExportReader.openPdb`.
pub const OpenPdbError = std.Io.Dir.ReadFileAllocError || pdb.DatabaseDecodeError;

/// Size cap when reading an `export.pdb`; the largest fixture is 2.9 MB.
const pdb_limit = std.Io.Limit.limited(1 << 26);

/// A read-side handle to a Rekordbox device export on disk: the setting
/// files and the pdb database, located through `Layout`. Files the export
/// carries but the reader does not model are ignored by design:
/// `djprofile.nxs` (undocumented), and `exportLibrary.db` until Phase O.
pub const DeviceExportReader = struct {
    /// The export's layout.
    layout: Layout,

    /// Points a reader at a device export on disk (a directory containing
    /// `PIONEER`).
    pub fn init(root_path: []const u8) DeviceExportReader {
        return .{ .layout = .{ .root = root_path } };
    }

    /// The device root path.
    pub fn root(r: DeviceExportReader) []const u8 {
        return r.layout.root;
    }

    /// Loads the four `*SETTING.DAT` files in `dat_files` order, each
    /// tolerantly (see `Settings`).
    pub fn loadSettings(r: DeviceExportReader, io: std.Io, alloc: std.mem.Allocator) Settings {
        var settings = Settings{};
        inline for (dat_files) |dat| {
            const payload = loadSettingFile(
                SettingPayload(dat.kind),
                io,
                alloc,
                r.layout,
                dat.name,
            );
            if (payload) |data| {
                @field(settings, @tagName(dat.kind)) = data;
            }
        }
        return settings;
    }

    /// Reads `export.pdb` and parses it into memory; changes to the
    /// returned database are never written back to disk.
    pub fn openPdb(
        r: DeviceExportReader,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) OpenPdbError!pdb.Database {
        const path = r.layout.exportPdb(alloc) catch return error.OutOfMemory;
        defer alloc.free(path);
        const buf = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, pdb_limit);
        defer alloc.free(buf);
        return pdb.Database.parse(alloc, buf, .plain);
    }
};

/// A playlist (leaf of the playlist tree).
pub const Playlist = struct {
    /// ID of this node in the playlist tree.
    id: u32,
    /// Name of the playlist.
    name: []u8,
};

/// A playlist folder, grouping other nodes.
pub const PlaylistFolder = struct {
    /// ID of this node in the playlist tree.
    id: u32,
    /// Name of the playlist folder.
    name: []u8,
    /// Child nodes, in row order.
    children: std.ArrayList(PlaylistNode),
};

/// Either a playlist folder or a playlist.
pub const PlaylistNode = union(enum) {
    /// A folder containing child `PlaylistNode`s.
    folder: PlaylistFolder,
    /// A playlist (leaf).
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

/// Error of `getPlaylists`: the playlist-tree row iteration errors plus
/// the string decode errors.
pub const GetPlaylistsError = pdb.RowIterError || error{ InvalidEncoding, OutOfMemory };

/// Playlist-tree rows grouped by their parent id.
const PlaylistGroups = std.AutoHashMap(u32, std.ArrayList(*const pdb.PlaylistTreeNode));

/// Frees the grouping map built by `getPlaylists`.
fn deinitGroups(alloc: std.mem.Allocator, groups: *PlaylistGroups) void {
    var it = groups.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(alloc);
    groups.deinit();
}

/// Appends the children of `parent` to `out`, in row order, recursing into
/// folders. A folder whose id is already in `visited` is skipped, so
/// parent-id cycles in corrupt data cannot recurse forever.
fn buildChildren(
    alloc: std.mem.Allocator,
    groups: *const PlaylistGroups,
    visited: *std.AutoHashMap(u32, void),
    parent: u32,
    out: *std.ArrayList(PlaylistNode),
) GetPlaylistsError!void {
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

/// Builds the playlist tree from the database's playlist-tree rows: nodes
/// parented to 0 form the top level, folders recurse into their children,
/// and names are decoded to owned UTF-8. Nodes unreachable from the root
/// (parented to a missing id) do not appear, as in rekordcrate; a folder id
/// is expanded at most once, so parent-id cycles in corrupt data cannot
/// recurse forever.
///
/// The caller owns the returned list; free it by deinitializing every
/// element and then the list itself:
///
///     var playlists = try device.getPlaylists(alloc, &db);
///     defer {
///         for (playlists.items) |*node| node.deinit(alloc);
///         playlists.deinit(alloc);
///     }
pub fn getPlaylists(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
) GetPlaylistsError!std.ArrayList(PlaylistNode) {
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
