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
const anlz = @import("anlz");
const pdb = @import("pdb");
const setting = @import("setting");
const util = @import("util");

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
        const names = anlzFolderNames(try pathHash(audio_path));
        return std.fs.path.join(
            alloc,
            &.{ l.root, "PIONEER", "USBANLZ", &names.p_folder, &names.leaf_folder },
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
        const names = anlzFolderNames(try pathHash(audio_path));
        return std.fs.path.join(
            alloc,
            &.{ l.root, "PIONEER", "USBANLZ", &names.p_folder, &names.leaf_folder, filename },
        );
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

    const hash_result = hash % 0x30D43;

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

/// The two `USBANLZ` folder names a path hash maps to.
const AnlzFolderNames = struct {
    /// `P{XXX}` — three hexadecimal digits.
    p_folder: [4]u8,
    /// `{HHHHHHHH}` — eight hexadecimal digits.
    leaf_folder: [8]u8,
};

/// Formats a path hash's two folder names. The arrays exactly fit every
/// value `pathHash` produces, so the prints cannot fail.
fn anlzFolderNames(h: PathHash) AnlzFolderNames {
    var names: AnlzFolderNames = undefined;
    _ = std.fmt.bufPrint(&names.p_folder, "P{X:0>3}", .{h.p_value}) catch unreachable;
    _ = std.fmt.bufPrint(&names.leaf_folder, "{X:0>8}", .{h.hash}) catch unreachable;
    return names;
}

/// Device-relative path stored in the pdb `analyze_path` column: the `.DAT`
/// the player loads first; sibling `.EXT`/`.2EX` are found by extension
/// substitution on the same stem. Computed from `audio_path` via
/// `pathHash`.
pub fn anlzDevicePath(alloc: std.mem.Allocator, audio_path: []const u8) PathError![]u8 {
    const names = anlzFolderNames(try pathHash(audio_path));
    return std.fmt.allocPrint(
        alloc,
        "/PIONEER/USBANLZ/{s}/{s}/ANLZ0000.DAT",
        .{ &names.p_folder, &names.leaf_folder },
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

/// The parsed payloads of the four `*SETTING.DAT` files.
pub const Settings = struct {
    dev_setting: ?setting.DevSetting = null,
    djm_my_setting: ?setting.DJMMySetting = null,
    my_setting: ?setting.MySetting = null,
    my_setting2: ?setting.MySetting2 = null,
};

/// Size cap when reading a `*SETTING.DAT` file; the largest known payload
/// is a few hundred bytes.
const dat_limit = std.Io.Limit.limited(1 << 16);

/// Error of `DeviceExport.loadSettings`: a setting file exists but could
/// not be examined — unreadable, over the read cap, or memory ran out.
pub const LoadSettingsError = std.Io.Dir.ReadFileAllocError;

/// Reads and parses one `*SETTING.DAT` file. A missing file or one that
/// fails to parse yields null — old exports genuinely lack files — while
/// errors that say the file could not be examined (permissions, memory,
/// a length over the read cap) propagate instead of masquerading as
/// absence.
fn loadSettingFile(
    comptime Payload: type,
    io: std.Io,
    dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    layout: Layout,
    filename: []const u8,
) std.Io.Dir.ReadFileAllocError!?Payload {
    const path = try layout.datPath(alloc, filename);
    defer alloc.free(path);
    const buf = dir.readFileAlloc(io, path, alloc, dat_limit) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(buf);
    const parsed = setting.Setting(Payload).parse(buf) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
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

/// Reverse-engineered `bitmask` constant observed on fresh Rekordbox
/// Track rows (`0x000c0700`). The OneLibrary db mirrors it as
/// `contentLink`. Device-derived — copy exactly.
const track_bitmask: u32 = 788_224;

/// Reverse-engineered `unknown5` constant observed on fresh Rekordbox
/// Track rows. The OneLibrary db mirrors it as `analysedBits`.
/// Device-derived — copy exactly.
const track_unknown5: u16 = 41;

/// A track as a user thinks of it: plain UTF-8 string slices and scalars,
/// no foreign-key ids. Input to `DeviceExport.addTrack`, which resolves
/// artists/albums/genres/keys/labels/artwork into deduplicated rows and
/// handles format quirks (the 221-byte minimum row size, centi-BPM
/// tempo). Every slice is borrowed for the call only. Experts needing
/// fields not exposed here should build a `pdb.Track` row directly
/// through `openPdb`.
pub const TrackInput = struct {
    /// Track title.
    title: []const u8 = "",
    /// Performing artist name.
    artist: []const u8 = "",
    /// Album name.
    album: []const u8 = "",
    /// Genre name.
    genre: []const u8 = "",
    /// Musical key name (e.g. "Cmaj", "D♭min"); folded to a canonical
    /// form for dedup.
    key: []const u8 = "",
    /// Record label name.
    label: []const u8 = "",
    /// Composer name.
    composer: []const u8 = "",
    /// Remixer name.
    remixer: []const u8 = "",
    /// Original performer, distinct from `artist` (covers/reworks).
    orig_artist: []const u8 = "",
    /// Free-text comment; also the auto-pad target when the row falls
    /// under the 221-byte minimum.
    comment: []const u8 = "",
    /// ISRC, in rekordbox's mangled format.
    isrc: []const u8 = "",
    /// Lyricist name.
    lyricist: []const u8 = "",
    /// Remix/mix name.
    mix_name: []const u8 = "",
    /// Free text; Rekordbox writes strict `YYYY-MM-DD` or empty, this
    /// field passes through verbatim so callers can probe hardware
    /// behavior with anything.
    release_date: []const u8 = "",
    /// Free text, commonly `YYYY-MM-DD` (see `release_date`).
    date_added: []const u8 = "",
    /// Device-relative file path (e.g. `/Contents/Artist - Title.mp3`).
    /// Dedup key when non-empty; tracks with an empty path are always
    /// inserted.
    file_path: []const u8 = "",
    /// File name without path.
    filename: []const u8 = "",
    /// Device path stored verbatim in the Artwork row; empty = none. The
    /// caller owns placing the image files it names (see `artworkSpec`
    /// for the required format).
    artwork_device_path: []const u8 = "",
    /// Track "message" field shown in Rekordbox.
    message: []const u8 = "",
    /// Tempo in BPM; encoded to centi-BPM (× 100) in the pdb.
    tempo: f32 = 0,
    /// Bitrate in kbps.
    bitrate: u32 = 0,
    /// Sample rate in Hz.
    sample_rate: u32 = 0,
    /// Bits per sample of the audio file.
    sample_depth: u16 = 0,
    /// Playback duration in seconds. The pdb field is `u16` (ceiling
    /// ~18.2 h).
    duration_secs: u16 = 0,
    /// File size in bytes.
    file_size: u32 = 0,
    /// Track number within the album.
    track_number: u32 = 0,
    /// Disc number.
    disc_number: u16 = 0,
    /// Release year.
    year: u16 = 0,
    /// Number of times the track was played.
    play_count: u16 = 0,
    /// Star rating, 0-5; stored raw — the pdb byte, not the XML's
    /// `0/51/102/153/204/255` scale.
    rating: u8 = 0,
    /// Color label.
    color: util.ColorIndex = .none,
    /// Audio file format.
    file_type: pdb.FileType = .unknown,
    /// Whether stored hotcues auto-load on a CDJ; maps to the pdb string
    /// `"ON"` / empty.
    autoload_hotcues: bool = false,
    /// Pre-computed ANLZ content. When set, the writer queues the
    /// `ANLZ0000` files for `save` (each sibling only when its section
    /// set carries data) and stores the device `.DAT` path in
    /// `analyze_path`. Beats and cues are always caller-provided — the
    /// library does not do beat detection; see `anlz.buildAnlzInput` for
    /// assembling one from performance data.
    analysis: ?*const anlz.AnlzInput = null,
};

/// The outcome of `DeviceExport.addTrack`: a freshly inserted track, or
/// an existing one returned because its `file_path` was already present.
pub const AddTrackOutcome = struct {
    /// The track id in the export.
    id: u32,
    /// True if a new row was inserted; false if an existing track was
    /// returned unchanged.
    is_new: bool,
};

/// Error of `DeviceExport.addTrack`: building the writer state, encoding
/// the track's strings (too long, or invalid UTF-8 where a format string
/// requires it), deriving its ANLZ paths, or inserting the rows.
pub const AddTrackError =
    WriterStateError ||
    PathError ||
    error{ TooLong, InvalidEncoding, InvalidUtf8 } ||
    pdb.DatabaseModifyError ||
    anlz.WriteError;

/// Error of the playlist and tag methods: building the writer state,
/// loading or creating `exportExt.pdb`, encoding a name or label (too
/// long, or invalid UTF-8 where a format string requires it), a foreign
/// key that names no existing row, or inserting the rows.
pub const PlaylistError =
    WriterStateError ||
    OpenPdbError ||
    error{ UnknownForeignKey, TooLong, InvalidEncoding } ||
    pdb.DatabaseModifyError;

/// The tag methods fail for the same reasons as the playlist ones.
pub const TagError = PlaylistError;

/// One serialized ANLZ file waiting for the next `save`: the host path it
/// lands at, plus its image. `addTrack` serializes eagerly so the
/// caller's `AnlzInput` can go away and `save` only moves bytes.
const PendingAnlz = struct {
    path: []u8,
    image: []u8,

    fn deinit(file: *PendingAnlz, alloc: std.mem.Allocator) void {
        alloc.free(file.path);
        alloc.free(file.image);
    }
};

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
    /// Directory every path is resolved against — the process working
    /// directory, captured once here so a mid-session cwd change cannot
    /// reinterpret a relative root between calls.
    dir: std.Io.Dir,
    /// The export's pdb, loaded on the first pdb-touching call — `open`
    /// stays cheap for settings-only sessions.
    pdb_state: PdbState = .unloaded,
    /// Serialized default `*SETTING.DAT` images waiting for the first
    /// `save` of a created export; always null for opened ones.
    pending_settings: ?[dat_files.len][]u8 = null,
    /// The writer's cached scan of the export — id counters and dedup
    /// maps — null until `writerState` builds it on first use.
    writer_state: ?WriterState = null,
    /// The tag database (`exportExt.pdb`), touched only by the tag
    /// methods and `save`.
    ext_pdb_state: ExtPdbState = .unloaded,
    /// Serialized ANLZ images queued by `addTrack`, written by the next
    /// `save` — before `export.pdb`, so a crash leaves orphan analysis
    /// files players ignore, not rows naming missing ones.
    pending_anlz: std.ArrayList(PendingAnlz) = .empty,

    const PdbState = union(enum) {
        /// An export opened at `root`; the pdb parses on first touch.
        unloaded,
        /// In memory — parsed from disk or built by `create`.
        loaded: pdb.Database,
    };

    /// Lifecycle of the tag database. A created export starts `absent`
    /// (the oracle's `create` never reads a leftover `exportExt.pdb`
    /// either — its first tag write starts fresh); an opened one starts
    /// `unloaded` and examines the disk at the first tag call.
    const ExtPdbState = union(enum) {
        /// Not examined yet; the first tag call checks the disk.
        unloaded,
        /// No `exportExt.pdb` under the root; the first tag write builds
        /// a fresh database in memory.
        absent,
        /// In memory — parsed from disk (prior tags preserved) or built
        /// fresh.
        loaded: pdb.Database,
    };

    /// Points the handle at a device export on disk (a directory
    /// containing `PIONEER`). Cheap and infallible: nothing is read until
    /// a pdb-touching call. The root path is borrowed; keep it alive
    /// until `deinit`.
    pub fn open(root_path: []const u8, io: std.Io, alloc: std.mem.Allocator) DeviceExport {
        return .{
            .layout = .{ .root = root_path },
            .io = io,
            .alloc = alloc,
            .dir = std.Io.Dir.cwd(),
        };
    }

    /// Builds a fresh export in memory: a created pdb carrying the fixed
    /// 20-table layout (the `Unknown` slots must stay in place or CDJ
    /// players crash) with the default color, column, and menu rows, plus
    /// the four default setting files. Nothing touches the disk until
    /// `save`.
    pub fn create(
        root_path: []const u8,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) CreateError!DeviceExport {
        const layout = Layout{ .root = root_path };
        const dir = std.Io.Dir.cwd();

        // Refuse to build over an existing export rather than orphan it.
        const pdb_path = try layout.exportPdb(alloc);
        defer alloc.free(pdb_path);
        if (dir.access(io, pdb_path, .{})) |_| {
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
            .dir = dir,
            .pdb_state = .{ .loaded = db },
            .pending_settings = pending,
            // Fresh counters and empty maps: the default color/column/menu
            // rows live in tables the writer doesn't track.
            .writer_state = .{},
            // Tags start empty — even over a root carrying a leftover
            // `exportExt.pdb`, which `save` then overwrites.
            .ext_pdb_state = .absent,
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
        switch (e.ext_pdb_state) {
            .loaded => |*db| db.deinit(),
            .unloaded, .absent => {},
        }
        if (e.pending_settings) |pending| {
            for (pending) |bytes| e.alloc.free(bytes);
        }
        if (e.writer_state) |*state| state.deinit(e.alloc);
        for (e.pending_anlz.items) |*file| file.deinit(e.alloc);
        e.pending_anlz.deinit(e.alloc);
    }

    pub fn root(e: *const DeviceExport) []const u8 {
        return e.layout.root;
    }

    /// Loads the four `*SETTING.DAT` files in `dat_files` order. A
    /// missing or invalid file leaves its field null; a file that
    /// cannot be examined is an error.
    pub fn loadSettings(e: *const DeviceExport) LoadSettingsError!Settings {
        var settings = Settings{};
        inline for (dat_files) |dat| {
            const payload = try loadSettingFile(
                SettingPayload(dat.kind),
                e.io,
                e.dir,
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
    /// id counters and dedup maps and reach the disk at the next `save`.
    pub fn openPdb(e: *DeviceExport) OpenPdbError!*pdb.Database {
        switch (e.pdb_state) {
            .loaded => |*db| return db,
            .unloaded => {
                const path = try e.layout.exportPdb(e.alloc);
                defer e.alloc.free(path);
                const buf = try e.dir.readFileAlloc(e.io, path, e.alloc, pdb_limit);
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

    /// The writer's cached scan of the export, built on first use
    /// (loading the pdb first if needed). The mutating methods call
    /// this before they touch the database, so read-only sessions
    /// never pay for it. Rows added through the `openPdb` escape
    /// hatch after the state was built are invisible to it.
    pub fn writerState(e: *DeviceExport) WriterStateError!*WriterState {
        if (e.writer_state == null) {
            const db = try e.openPdb();
            e.writer_state = try scanWriterState(e.alloc, db);
        }
        return &e.writer_state.?;
    }

    /// Adds a track to the export. Resolves — creating where needed —
    /// the Artist, Album, Genre, Key, Label, and Artwork rows, then
    /// inserts a Track row pointing at them by id.
    ///
    /// Idempotent on a non-empty `file_path`: if a track with that path
    /// was already added (this session, or read back by the writer-state
    /// scan of an opened export), the existing id is returned and nothing
    /// is inserted; `AddTrackOutcome.is_new` tells the cases apart.
    ///
    /// Everything that can fail on the caller's data — string encoding,
    /// ANLZ serialization — happens before any id is taken or row
    /// inserted, so a bad string leaves the export untouched. A failure
    /// between the dimension-row inserts and the Track row (allocation
    /// failure, or a database counters inconsistency) can still leave
    /// orphaned dimension rows — unreachable from any track, ignored by
    /// players, not recovered automatically (the oracle's documented
    /// residual risk).
    pub fn addTrack(e: *DeviceExport, track: TrackInput) AddTrackError!AddTrackOutcome {
        const state = try e.writerState();
        if (track.file_path.len > 0) {
            if (state.tracks_by_path.get(track.file_path)) |id|
                return .{ .id = id, .is_new = false };
        }
        const track_id = state.next_track_id;

        // The caller's data fails here or never: nothing below this point
        // is rolled back.
        var anlz_files = try e.buildAnlzFiles(track);
        errdefer for (&anlz_files) |*slot| {
            if (slot.*) |*file| file.deinit(e.alloc);
        };
        const row = try e.buildTrackRow(track, track.analysis != null);

        const artist_id = try e.getOrCreateArtist(track.artist);
        const album_id = try e.getOrCreateAlbum(track.album, artist_id);
        const genre_id = try e.getOrCreateGenre(track.genre);
        const key_id = try e.getOrCreateKey(track.key);
        const label_id = try e.getOrCreateLabel(track.label);
        const artwork_id = try e.getOrCreateArtwork(track.artwork_device_path);
        const composer_id =
            if (track.composer.len == 0) 0 else try e.getOrCreateArtist(track.composer);
        const orig_artist_id =
            if (track.orig_artist.len == 0) 0 else try e.getOrCreateArtist(track.orig_artist);
        const remixer_id =
            if (track.remixer.len == 0) 0 else try e.getOrCreateArtist(track.remixer);

        row.id = track_id;
        row.artist_id = artist_id;
        row.album_id = album_id;
        row.genre_id = genre_id;
        row.key_id = key_id;
        row.label_id = label_id;
        row.artwork_id = artwork_id;
        row.composer_id = composer_id;
        row.orig_artist_id = orig_artist_id;
        row.remixer_id = remixer_id;

        // Reserve everything the bookkeeping needs so the steps after the
        // insert cannot fail half-applied.
        try e.pending_anlz.ensureUnusedCapacity(e.alloc, anlz_files.len);
        try state.track_ids.ensureUnusedCapacity(e.alloc, 1);
        var owned_path: ?[]u8 = null;
        errdefer if (owned_path) |path| e.alloc.free(path);
        if (track.file_path.len > 0) {
            owned_path = try e.alloc.dupe(u8, track.file_path);
            try state.tracks_by_path.ensureUnusedCapacity(e.alloc, 1);
        }

        const db = try e.openPdb();
        var row_union = pdb.Row{ .track = row };
        _ = try db.addRow(&row_union);

        state.next_track_id += 1;
        state.track_ids.putAssumeCapacity(track_id, {});
        if (owned_path) |path| state.tracks_by_path.putAssumeCapacity(path, track_id);
        for (anlz_files) |slot| if (slot) |file|
            e.pending_anlz.appendAssumeCapacity(file);

        return .{ .id = track_id, .is_new = true };
    }

    /// Builds the Track row for `track` in the database's arena — every
    /// string encoded, the device-derived constants set, and `comment`
    /// grown past the 221-byte CDJ minimum — allocating no ids and
    /// inserting nothing. `has_analysis` selects whether `analyze_path`
    /// is populated.
    fn buildTrackRow(
        e: *DeviceExport,
        track: TrackInput,
        has_analysis: bool,
    ) AddTrackError!*pdb.Track {
        const a = (try e.openPdb()).arena.allocator();

        // The device path of the track's ANLZ `.DAT`, derived from
        // `file_path` the way players recompute it. Everything stays in
        // the database arena, reclaimed with it.
        const analyze_path = if (has_analysis) blk: {
            const device_path = try anlzDevicePath(a, track.file_path);
            break :blk try pdb.DeviceSQLString.fromUtf8(a, device_path);
        } else pdb.DeviceSQLString.empty();

        // Only `comment` is re-encoded after this, by the padding pass;
        // every other string is encoded exactly once.
        const boxed = try a.create(pdb.Track);
        boxed.* = .{
            .bitmask = track_bitmask,
            .unknown5 = track_unknown5,
            .sample_rate = track.sample_rate,
            .sample_depth = track.sample_depth,
            .bitrate = track.bitrate,
            .duration = track.duration_secs,
            .file_size = track.file_size,
            // The pdb stores centi-BPM: a negative or non-finite tempo
            // encodes as zero, an oversized one saturates.
            .tempo = std.math.lossyCast(u32, @round(track.tempo * 100.0)),
            .file_type = track.file_type,
            .track_number = track.track_number,
            .disc_number = track.disc_number,
            .year = track.year,
            .play_count = track.play_count,
            .rating = track.rating,
            .color = track.color,
            .offsets = .{ .inner = .{
                .isrc = try pdb.DeviceSQLString.fromUtf8(a, track.isrc),
                .lyricist = try pdb.DeviceSQLString.fromUtf8(a, track.lyricist),
                // Rekordbox writes "1" in both on fresh rows.
                .unknown_string2 = try pdb.DeviceSQLString.fromUtf8(a, "1"),
                .unknown_string3 = try pdb.DeviceSQLString.fromUtf8(a, "1"),
                .message = try pdb.DeviceSQLString.fromUtf8(a, track.message),
                .publish_track_information = try pdb.DeviceSQLString.fromUtf8(a, "ON"),
                .autoload_hotcues = if (track.autoload_hotcues)
                    try pdb.DeviceSQLString.fromUtf8(a, "ON")
                else
                    pdb.DeviceSQLString.empty(),
                .date_added = try pdb.DeviceSQLString.fromUtf8(a, track.date_added),
                .release_date = try pdb.DeviceSQLString.fromUtf8(a, track.release_date),
                .mix_name = try pdb.DeviceSQLString.fromUtf8(a, track.mix_name),
                .analyze_path = analyze_path,
                .comment = try pdb.DeviceSQLString.fromUtf8(a, track.comment),
                .title = try pdb.DeviceSQLString.fromUtf8(a, track.title),
                .filename = try pdb.DeviceSQLString.fromUtf8(a, track.filename),
                .file_path = try pdb.DeviceSQLString.fromUtf8(a, track.file_path),
            } },
        };
        try pdb.padTrackCommentToMinimum(boxed, a);
        return boxed;
    }

    /// Serializes the `ANLZ0000` images `track.analysis` asks for, gated
    /// the way the oracle writes the siblings: `.DAT` only when it
    /// carries a section beyond the leading path, `.EXT` when the
    /// extended-cue list is non-empty or any of its optional column
    /// groups is present (present-but-empty writes the file; null skips
    /// it), `.2EX` when either 3-band group is present. Tracks without
    /// analysis queue nothing.
    fn buildAnlzFiles(e: *DeviceExport, track: TrackInput) AddTrackError![3]?PendingAnlz {
        const input = track.analysis orelse return .{ null, null, null };
        const a = e.alloc;

        // Every analysis file starts with a PPTH section naming the
        // audio file; the three siblings share it.
        const path_str = try anlz.LenPrefixedWideString.fromUtf8(a, track.file_path);
        defer a.free(path_str.raw);
        const path_section = anlz.Content{ .path = .{ .path = path_str } };

        var files: [3]?PendingAnlz = .{ null, null, null };
        errdefer for (&files) |*slot| {
            if (slot.*) |*file| file.deinit(a);
        };

        // `.DAT`: beats, plain cues, and the mono previews.
        var dat = std.ArrayList(anlz.Content).empty;
        defer dat.deinit(a);
        try dat.append(a, path_section);
        if (input.beats.len > 0)
            try dat.append(a, .{ .beat_grid = .{ .beats = input.beats } });
        if (input.cues.len > 0)
            try dat.append(a, .{ .cue_list = .{
                .list_type = input.cue_list_type,
                .cues = input.cues,
            } });
        if (input.preview_mono.len > 0)
            try dat.append(a, .{ .waveform_preview = .{ .data = input.preview_mono } });
        if (input.tiny_preview.len > 0)
            try dat.append(a, .{ .tiny_waveform_preview = .{ .data = input.tiny_preview } });
        if (dat.items.len > 1)
            files[0] = try e.serializeAnlz(track.file_path, .dat, dat.items);

        // `.EXT`: extended cues plus the optional column groups.
        const ext_has_data = input.cues_extended.len > 0 or input.detail_mono != null or
            input.color_preview != null or input.color_detail != null;
        if (ext_has_data) {
            var ext = std.ArrayList(anlz.Content).empty;
            defer ext.deinit(a);
            try ext.append(a, path_section);
            if (input.cues_extended.len > 0)
                try ext.append(a, .{ .extended_cue_list = .{
                    .list_type = input.cue_list_type,
                    .cues = input.cues_extended,
                } });
            if (input.detail_mono) |cols|
                try ext.append(a, .{ .waveform_detail = .{ .data = cols } });
            if (input.color_preview) |cols|
                try ext.append(a, .{ .waveform_color_preview = .{ .data = cols } });
            if (input.color_detail) |cols|
                try ext.append(a, .{ .waveform_color_detail = .{ .data = cols } });
            files[1] = try e.serializeAnlz(track.file_path, .ext, ext.items);
        }

        // `.2EX`: the 3-band groups.
        if (input.band3_preview != null or input.band3_detail != null) {
            var two_ex = std.ArrayList(anlz.Content).empty;
            defer two_ex.deinit(a);
            try two_ex.append(a, path_section);
            if (input.band3_preview) |cols|
                try two_ex.append(a, .{ .waveform_3band_preview = .{ .data = cols } });
            if (input.band3_detail) |cols|
                try two_ex.append(a, .{ .waveform_3band_detail = .{ .data = cols } });
            files[2] = try e.serializeAnlz(track.file_path, .two_ex, two_ex.items);
        }

        return files;
    }

    /// Which `ANLZ0000` sibling a serialized image is.
    const AnlzSibling = enum { dat, ext, two_ex };

    /// Serializes `sections` into the image for `sibling` of `file_path`,
    /// paired with the host path it will land at.
    fn serializeAnlz(
        e: *DeviceExport,
        file_path: []const u8,
        sibling: AnlzSibling,
        sections: []const anlz.Content,
    ) AddTrackError!PendingAnlz {
        const image = try anlz.serializeFile(e.alloc, &anlz.file_header_data, sections);
        errdefer e.alloc.free(image);
        const path = switch (sibling) {
            .dat => try e.layout.anlzDatFile(e.alloc, file_path),
            .ext => try e.layout.anlzExtFile(e.alloc, file_path),
            .two_ex => try e.layout.anlz2exFile(e.alloc, file_path),
        };
        return .{ .path = path, .image = image };
    }

    /// Resolves `name` to an Artist row, inserting one when no scanned or
    /// previously created artist carries the name. Empty names resolve to
    /// the null id 0.
    fn getOrCreateArtist(e: *DeviceExport, name: []const u8) AddTrackError!u32 {
        const state = try e.writerState();
        if (name.len == 0) return 0;
        if (state.artists_by_name.get(name)) |id| return id;

        const db = try e.openPdb();
        const id = state.next_artist_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.Artist);
        boxed.* = .{ .id = id, .offsets = .{ .inner = .{
            .name = try pdb.DeviceSQLString.fromUtf8(a, name),
        } } };
        var row = pdb.Row{ .artist = boxed };
        _ = try db.addRow(&row);
        state.next_artist_id += 1;

        try putStringIfAbsent(&state.artists_by_name, e.alloc, try e.alloc.dupe(u8, name), id);
        return id;
    }

    /// Resolves `(artist_id, name)` to an Album row, inserting one when
    /// needed — albums are per-artist. An empty name resolves to the null
    /// id 0.
    fn getOrCreateAlbum(
        e: *DeviceExport,
        name: []const u8,
        artist_id: u32,
    ) AddTrackError!u32 {
        const state = try e.writerState();
        if (name.len == 0) return 0;
        if (state.albums_by_artist_and_name.get(.{ .artist_id = artist_id, .name = name })) |id|
            return id;

        const db = try e.openPdb();
        const id = state.next_album_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.Album);
        boxed.* = .{
            .artist_id = artist_id,
            .id = id,
            .offsets = .{ .inner = .{ .name = try pdb.DeviceSQLString.fromUtf8(a, name) } },
        };
        var row = pdb.Row{ .album = boxed };
        _ = try db.addRow(&row);
        state.next_album_id += 1;

        try putAlbumIfAbsent(
            &state.albums_by_artist_and_name,
            e.alloc,
            .{ .artist_id = artist_id, .name = try e.alloc.dupe(u8, name) },
            id,
        );
        return id;
    }

    /// Resolves `name` to a Genre row, inserting one when needed. Empty
    /// names resolve to the null id 0.
    fn getOrCreateGenre(e: *DeviceExport, name: []const u8) AddTrackError!u32 {
        const state = try e.writerState();
        if (name.len == 0) return 0;
        if (state.genres_by_name.get(name)) |id| return id;

        const db = try e.openPdb();
        const id = state.next_genre_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.Genre);
        boxed.* = .{ .id = id, .name = try pdb.DeviceSQLString.fromUtf8(a, name) };
        var row = pdb.Row{ .genre = boxed };
        _ = try db.addRow(&row);
        state.next_genre_id += 1;

        try putStringIfAbsent(&state.genres_by_name, e.alloc, try e.alloc.dupe(u8, name), id);
        return id;
    }

    /// Resolves `name` — folded through `canonicalKeyName` — to a Key
    /// row, inserting one when no canonical spelling matches. Empty names
    /// resolve to the null id 0.
    fn getOrCreateKey(e: *DeviceExport, name: []const u8) AddTrackError!u32 {
        const state = try e.writerState();
        if (name.len == 0) return 0;
        const canonical = try canonicalKeyName(e.alloc, name);
        defer e.alloc.free(canonical);
        if (state.keys_by_canonical.get(canonical)) |id| return id;

        const db = try e.openPdb();
        const id = state.next_key_id;
        const a = db.arena.allocator();
        // The row stores the canonical spelling so later lookups collide
        // across spellings; a name that folds to nothing (whitespace
        // only) keeps the original.
        const stored = if (canonical.len == 0) name else canonical;
        const boxed = try a.create(pdb.Key);
        boxed.* = .{
            .id = id,
            .id2 = id,
            .name = try pdb.DeviceSQLString.fromUtf8(a, stored),
        };
        var row = pdb.Row{ .key = boxed };
        _ = try db.addRow(&row);
        state.next_key_id += 1;

        try putStringIfAbsent(&state.keys_by_canonical, e.alloc, try e.alloc.dupe(u8, canonical), id);
        return id;
    }

    /// Resolves `name` to a Label row, inserting one when needed. Empty
    /// names resolve to the null id 0.
    fn getOrCreateLabel(e: *DeviceExport, name: []const u8) AddTrackError!u32 {
        const state = try e.writerState();
        if (name.len == 0) return 0;
        if (state.labels_by_name.get(name)) |id| return id;

        const db = try e.openPdb();
        const id = state.next_label_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.Label);
        boxed.* = .{ .id = id, .name = try pdb.DeviceSQLString.fromUtf8(a, name) };
        var row = pdb.Row{ .label = boxed };
        _ = try db.addRow(&row);
        state.next_label_id += 1;

        try putStringIfAbsent(&state.labels_by_name, e.alloc, try e.alloc.dupe(u8, name), id);
        return id;
    }

    /// Resolves `path` to an Artwork row, inserting one when no row
    /// carries the path. The path lands in the row verbatim — the caller
    /// owns placing the image files it names (decision 5; see
    /// `artworkSpec`). An empty path resolves to the null id 0.
    fn getOrCreateArtwork(e: *DeviceExport, path: []const u8) AddTrackError!u32 {
        const state = try e.writerState();
        if (path.len == 0) return 0;
        if (state.artwork_by_path.get(path)) |id| return id;

        const db = try e.openPdb();
        const id = state.next_artwork_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.Artwork);
        boxed.* = .{ .id = id, .path = try pdb.DeviceSQLString.fromUtf8(a, path) };
        var row = pdb.Row{ .artwork = boxed };
        _ = try db.addRow(&row);
        state.next_artwork_id += 1;

        try putStringIfAbsent(&state.artwork_by_path, e.alloc, try e.alloc.dupe(u8, path), id);
        return id;
    }

    /// Creates a playlist folder — a node that groups other folders and
    /// playlists — and returns its id. `parent_id` is 0 (the tree root)
    /// or the id of an existing folder (one this method or a scanned
    /// export created); anything else, including a playlist's id, is
    /// `UnknownForeignKey`.
    pub fn createPlaylistFolder(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
    ) PlaylistError!u32 {
        return e.createPlaylistNode(name, parent_id, true);
    }

    /// Creates a playlist — a leaf node holding tracks through
    /// `addTrackToPlaylist` — under `parent_id` (same rule as
    /// `createPlaylistFolder`) and returns its id.
    pub fn createPlaylist(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
    ) PlaylistError!u32 {
        return e.createPlaylistNode(name, parent_id, false);
    }

    /// Inserts the node row and records it in the writer state. The name
    /// encodes before any id is taken, so a name too long to encode
    /// leaves the export untouched; the id counter bumps only after the
    /// insert, so a failed call cannot mint a duplicate id.
    fn createPlaylistNode(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
        is_folder: bool,
    ) PlaylistError!u32 {
        const state = try e.writerState();
        // The root (id 0) is always a valid parent; any other id must
        // name an existing folder — a playlist cannot hold children.
        if (parent_id != 0) {
            const parent_is_folder = state.playlist_nodes.get(parent_id) orelse false;
            if (!parent_is_folder) return error.UnknownForeignKey;
        }

        const db = try e.openPdb();
        const id = state.next_playlist_node_id;
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.PlaylistTreeNode);
        boxed.* = .{
            .parent_id = parent_id,
            .id = id,
            .node_is_folder = if (is_folder) 1 else 0,
            .name = try pdb.DeviceSQLString.fromUtf8(a, name),
        };
        try state.playlist_nodes.ensureUnusedCapacity(e.alloc, 1);
        var row = pdb.Row{ .playlist_tree_node = boxed };
        _ = try db.addRow(&row);

        state.next_playlist_node_id = id + 1;
        state.playlist_nodes.putAssumeCapacity(id, is_folder);
        return id;
    }

    /// Appends a track to the end of a playlist; the entry position is
    /// assigned automatically, dense from 0 and continuing across save
    /// and reopen. `playlist_id` must name an existing *playlist* (a
    /// folder id is rejected — tracks go into playlists only) and
    /// `track_id` an existing track, else `UnknownForeignKey`.
    pub fn addTrackToPlaylist(
        e: *DeviceExport,
        playlist_id: u32,
        track_id: u32,
    ) PlaylistError!void {
        const state = try e.writerState();
        const node_is_folder = state.playlist_nodes.get(playlist_id) orelse
            return error.UnknownForeignKey;
        if (node_is_folder) return error.UnknownForeignKey;
        if (!state.track_ids.contains(track_id)) return error.UnknownForeignKey;

        const entry_index = state.playlist_entry_counts.get(playlist_id) orelse 0;

        const db = try e.openPdb();
        const a = db.arena.allocator();
        const boxed = try a.create(pdb.PlaylistEntry);
        boxed.* = .{
            .entry_index = entry_index,
            .track_id = track_id,
            .playlist_id = playlist_id,
        };
        try state.playlist_entry_counts.ensureUnusedCapacity(e.alloc, 1);
        var row = pdb.Row{ .playlist_entry = boxed };
        _ = try db.addRow(&row);

        const gop = state.playlist_entry_counts.getOrPutAssumeCapacity(playlist_id);
        gop.value_ptr.* = entry_index + 1;
    }

    /// Creates a top-level tag category (e.g. "My Tags") in the tag
    /// database and returns its id. Leaf tags attach under a category
    /// through `addTagsToTrack`. The tag database is the export's
    /// `exportExt.pdb`, loaded lazily on first use — prior categories,
    /// leaves, and junctions survive, and nothing lands on disk before
    /// `save`.
    pub fn createTagCategory(e: *DeviceExport, name: []const u8) TagError!u32 {
        const state = try e.writerState();
        const db = try e.extDb();
        const id = state.next_tag_id;
        const row_index = state.next_tag_row_index;
        const a = db.arena.allocator();
        const boxed = try buildTagRow(a, .{
            .parent_id = 0,
            .position = state.next_category_position,
            .id = id,
            .is_category = true,
            .row_index = row_index,
        }, name);
        try state.tag_categories.ensureUnusedCapacity(e.alloc, 1);
        var row = pdb.Row{ .tag = boxed };
        _ = try db.addRow(&row);

        state.next_tag_id = id + 1;
        state.next_tag_row_index = row_index + 1;
        state.next_category_position += 1;
        state.tag_categories.putAssumeCapacity(id, {});
        return id;
    }

    /// Associates `labels` with `track_id` under `category_id` in the tag
    /// database. Empty labels are dropped and duplicates — within this
    /// call or already existing under the category — collapse to one leaf
    /// row, so each `(category, label)` pair produces at most one
    /// junction row per track. `track_id` must name an existing track and
    /// `category_id` a category this handle knows (one returned by
    /// `createTagCategory`, or one recovered from the opened
    /// `exportExt.pdb`), else `UnknownForeignKey`. A failure between leaf rows leaves the
    /// earlier ones inserted — unreachable junctions are ignored by
    /// players, not recovered automatically (the same residual risk as
    /// `addTrack`'s dimension rows).
    pub fn addTagsToTrack(
        e: *DeviceExport,
        track_id: u32,
        category_id: u32,
        labels: []const []const u8,
    ) TagError!void {
        const state = try e.writerState();
        // The category check needs the tag state an opened export's
        // `exportExt.pdb` carries, so the tag database loads (from disk
        // only — not created) before either key is validated.
        try e.ensureExtLoaded();
        if (!state.track_ids.contains(track_id)) return error.UnknownForeignKey;
        if (!state.tag_categories.contains(category_id)) return error.UnknownForeignKey;

        var kept = std.ArrayList([]const u8).empty;
        defer kept.deinit(e.alloc);
        for (labels) |label| {
            if (label.len == 0) continue;
            var duplicate = false;
            for (kept.items) |seen| {
                if (std.mem.eql(u8, seen, label)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try kept.append(e.alloc, label);
        }
        if (kept.items.len == 0) return;

        for (kept.items) |label| {
            const tag_id = try e.getOrCreateTag(category_id, label);
            const db = try e.extDb();
            const a = db.arena.allocator();
            const boxed = try a.create(pdb.TrackTag);
            boxed.* = .{ .track_id = track_id, .tag_id = tag_id };
            var row = pdb.Row{ .track_tag = boxed };
            _ = try db.addRow(&row);
        }
    }

    /// Resolves `(category_id, label)` to a leaf tag, inserting one when
    /// no scanned or previously created leaf matches. The id counter and
    /// `index_shift` row counter bump only after the insert.
    fn getOrCreateTag(
        e: *DeviceExport,
        category_id: u32,
        label: []const u8,
    ) TagError!u32 {
        const state = try e.writerState();
        if (state.tags_by_key.get(.{ .category_id = category_id, .label = label })) |id|
            return id;

        const db = try e.extDb();
        const id = state.next_tag_id;
        const row_index = state.next_tag_row_index;
        const position = state.tag_leaf_counts.get(category_id) orelse 0;
        const a = db.arena.allocator();
        const boxed = try buildTagRow(a, .{
            .parent_id = category_id,
            .position = position,
            .id = id,
            .is_category = false,
            .row_index = row_index,
        }, label);

        // The map key outlives the call in the state; reserve both map
        // updates before the insert so the bookkeeping after it cannot
        // fail half-applied.
        const owned_label = try e.alloc.dupe(u8, label);
        errdefer e.alloc.free(owned_label);
        try state.tags_by_key.ensureUnusedCapacity(e.alloc, 1);
        try state.tag_leaf_counts.ensureUnusedCapacity(e.alloc, 1);
        var row = pdb.Row{ .tag = boxed };
        _ = try db.addRow(&row);

        state.next_tag_id = id + 1;
        state.next_tag_row_index = row_index + 1;
        state.tags_by_key.putAssumeCapacity(
            .{ .category_id = category_id, .label = owned_label },
            id,
        );
        const gop = state.tag_leaf_counts.getOrPutAssumeCapacity(category_id);
        gop.value_ptr.* = position + 1;
        return id;
    }

    /// The tag database, loading it first: parsed from disk when the root
    /// carries an `exportExt.pdb` (prior tags preserved through the
    /// `scanExtTags` recovery), else built fresh in memory. Only the
    /// tag-writing methods call this, so an export whose tags were never
    /// touched never gains an `exportExt.pdb` — `save` writes the
    /// database only once it exists here.
    fn extDb(e: *DeviceExport) TagError!*pdb.Database {
        try e.ensureExtLoaded();
        if (e.ext_pdb_state == .absent) {
            e.ext_pdb_state = .{ .loaded = try pdb.Database.create(
                e.alloc,
                .ext,
                &pdb.ext_table_page_types,
            ) };
        }
        return &e.ext_pdb_state.loaded;
    }

    /// Examines `exportExt.pdb` once: present, it parses into the state
    /// and its tag rows extend the writer state, so later tag calls
    /// append instead of colliding; absent, the state is only marked so
    /// the first tag write builds a fresh database in memory. A failure
    /// leaves the state `unloaded` — a retry re-reads the file.
    fn ensureExtLoaded(e: *DeviceExport) WriterStateError!void {
        if (e.ext_pdb_state != .unloaded) return;

        const path = try e.layout.exportExtPdb(e.alloc);
        defer e.alloc.free(path);
        const buf = e.dir.readFileAlloc(e.io, path, e.alloc, pdb_limit) catch |err| switch (err) {
            error.FileNotFound => {
                e.ext_pdb_state = .absent;
                return;
            },
            else => return err,
        };
        defer e.alloc.free(buf);
        var db = try pdb.Database.parse(e.alloc, buf, .ext);
        errdefer db.deinit();
        try scanExtTags(e.alloc, &db, try e.writerState());
        e.ext_pdb_state = .{ .loaded = db };
    }

    /// Writes the buffered export to disk — the handle's only
    /// disk-writing call. Everything that can fail on the in-memory
    /// model — parsing, track-row validation, serialization — happens
    /// before the first write, so a failed `save` leaves the disk
    /// untouched. Crash-safe write order: the default directory tree,
    /// the four setting files, the queued ANLZ files, `exportExt.pdb`
    /// when the tag methods loaded or created one, then `export.pdb` —
    /// the index everything else is reached through — last, so a crash
    /// leaves orphan files players ignore, not rows naming missing data.
    /// Every file lands through `writeFileAtomic`, so readers never
    /// see a torn one.
    pub fn save(e: *DeviceExport) SaveError!void {
        const db = try e.openPdb();
        try db.validateAllTrackRows();
        const image = try db.serialize(e.alloc);
        defer e.alloc.free(image);
        var ext_image: ?[]u8 = null;
        defer if (ext_image) |bytes| e.alloc.free(bytes);
        if (e.ext_pdb_state == .loaded) {
            ext_image = try e.ext_pdb_state.loaded.serialize(e.alloc);
        }

        if (e.pending_settings) |pending| try e.writePendingSettings(pending);
        if (e.pending_anlz.items.len > 0) try e.writePendingAnlz();

        if (ext_image) |bytes| {
            const ext_path = try e.layout.exportExtPdb(e.alloc);
            defer e.alloc.free(ext_path);
            try e.writeFileAtomic(ext_path, bytes);
        }

        const pdb_path = try e.layout.exportPdb(e.alloc);
        defer e.alloc.free(pdb_path);
        try e.writeFileAtomic(pdb_path, image);
    }

    /// Writes every queued ANLZ file — creating its `USBANLZ` folder —
    /// then releases the queue; a failure leaves the not-yet-written
    /// entries queued for the next `save` (the images are fixed bytes,
    /// so a retry rewrites the landed ones identically).
    fn writePendingAnlz(
        e: *DeviceExport,
    ) (std.mem.Allocator.Error || std.Io.Dir.CreateDirPathError || AtomicWriteError)!void {
        for (e.pending_anlz.items) |*file| {
            try e.dir.createDirPath(e.io, std.fs.path.dirname(file.path) orelse ".");
            try e.writeFileAtomic(file.path, file.image);
        }
        for (e.pending_anlz.items) |*file| file.deinit(e.alloc);
        e.pending_anlz.clearRetainingCapacity();
    }

    /// Writes the default directory tree and the four pending setting
    /// images, then releases them; a failure leaves them owned by
    /// `pending_settings`, for `deinit` to reclaim.
    fn writePendingSettings(
        e: *DeviceExport,
        pending: [dat_files.len][]u8,
    ) (std.mem.Allocator.Error || std.Io.Dir.CreateDirPathError || AtomicWriteError)!void {
        // Each path is freed before the next is built, so a failure
        // between the creations leaks nothing.
        const dir_fns = [_]*const fn (
            Layout,
            std.mem.Allocator,
        ) std.mem.Allocator.Error![]u8{
            Layout.rekordboxDir,
            Layout.usbanlzDir,
            Layout.contentsDir,
        };
        for (dir_fns) |dir_fn| {
            const dir = try dir_fn(e.layout, e.alloc);
            defer e.alloc.free(dir);
            try e.dir.createDirPath(e.io, dir);
        }

        inline for (dat_files, 0..) |dat, i| {
            const path = try e.layout.datPath(e.alloc, dat.name);
            defer e.alloc.free(path);
            try e.writeFileAtomic(path, pending[i]);
        }
        for (pending) |bytes| e.alloc.free(bytes);
        e.pending_settings = null;
    }

    /// Writes `bytes` to `path` through a same-directory temp file and an
    /// atomic rename.
    fn writeFileAtomic(e: *DeviceExport, path: []const u8, bytes: []const u8) AtomicWriteError!void {
        var af = try e.dir.createFileAtomic(e.io, path, .{ .replace = true });
        defer af.deinit(e.io);
        try af.file.writeStreamingAll(e.io, bytes);
        try af.replace(e.io);
    }
};

/// A playlist (leaf of the playlist tree).
pub const Playlist = struct {
    id: u32,
    name: []u8,
};

/// A playlist folder, grouping other nodes.
pub const PlaylistFolder = struct {
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
/// (parented to a missing id) do not appear; a folder id
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

// --- writer state ---------------------------------------------------------------

/// Folds a musical key name to a canonical form for deduplication
/// (`C Major`/`Cmaj`/`C MAJOR`/`Cmajor` → `Cmaj`), so different spellings
/// of one key share a single pdb Key row. The note letter keeps its case.
///
/// String-equality only: enharmonic equivalents (`B♭m` ≠ `A#m`), Camelot,
/// and Open Key notation are not resolved — different pitch spellings
/// still create distinct rows.
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
            if (std.ascii.startsWithIgnoreCase(trimmed[i..], f.token)) {
                try out.appendSlice(alloc, f.emit);
                i += f.token.len;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        // Not a recognized token: copy one codepoint through, folding the
        // unicode accidentals and dropping spaces on the way.
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
    /// Shared id space for tag categories and leaf tags.
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
/// still counts toward the id counters, only its map entry is skipped.
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
/// wins. The caller-owned `key` is freed when it duplicates an existing
/// entry, and owned by the map afterwards.
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

/// The writer-chosen fields of a Tag row; see `buildTagRow`.
const TagRowInput = struct {
    parent_id: u32,
    position: u32,
    id: u32,
    is_category: bool,
    row_index: u32,
};

/// Builds a category or leaf Tag row in `a`, the tag database's arena —
/// nothing is inserted and no counter is consumed. Device-derived
/// constants, confirmed against real Rekordbox exports (device-derived —
/// copy exactly): `subtype` `0x0680`, `raw_is_category` `1 << 24` for a
/// category and `0` for a leaf, `index_shift` `row_index * 0x20` (0x20
/// per row, truncated to the field's u16 as the oracle's `as` cast
/// does). Leaf ids are sequential here, not the large random 32-bit
/// values Rekordbox writes — unknown whether players care; revisit if
/// round-trip fidelity is needed (oracle note).
fn buildTagRow(
    a: std.mem.Allocator,
    input: TagRowInput,
    name: []const u8,
) error{ TooLong, InvalidEncoding, OutOfMemory }!*pdb.TagOrCategory {
    const boxed = try a.create(pdb.TagOrCategory);
    boxed.* = .{
        .subtype = 0x0680,
        .index_shift = @truncate(input.row_index *% 0x20),
        .parent_id = input.parent_id,
        .position = input.position,
        .id = input.id,
        .raw_is_category = if (input.is_category) 1 << 24 else 0,
        .offsets = .{ .inner = .{
            .name = try pdb.DeviceSQLString.fromUtf8(a, name),
            .unknown = pdb.DeviceSQLString.empty(),
        } },
    };
    return boxed;
}

/// Scans `tracks`: every id into `track_ids` (playlist-membership FK
/// checks), every non-empty file path into `tracks_by_path`, and the
/// id counter past the highest track id.
fn scanTracks(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
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
}

/// Scans `artists`: names into `artists_by_name`, the id counter past
/// the highest artist id.
fn scanArtists(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .artists);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const artist = row.artist;
            state.next_artist_id = @max(state.next_artist_id, artist.id +| 1);
            if (try decodeOrSkip(artist.offsets.inner.name, alloc)) |name| {
                try putStringIfAbsent(&state.artists_by_name, alloc, name, artist.id);
            }
        }
    }
}

/// Scans `albums`: `(owning artist, name)` pairs into
/// `albums_by_artist_and_name`, the id counter past the highest album
/// id.
fn scanAlbums(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .albums);
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
}

/// Scans `genres`: names into `genres_by_name`, the id counter past the
/// highest genre id.
fn scanGenres(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .genres);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const genre = row.genre;
            state.next_genre_id = @max(state.next_genre_id, genre.id +| 1);
            if (try decodeOrSkip(genre.name, alloc)) |name| {
                try putStringIfAbsent(&state.genres_by_name, alloc, name, genre.id);
            }
        }
    }
}

/// Scans `keys`: names folded through `canonicalKeyName` into
/// `keys_by_canonical`, so later lookups collide across spellings, and
/// the id counter past the highest key id.
fn scanKeys(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .keys);
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
}

/// Scans `labels`: names into `labels_by_name`, the id counter past the
/// highest label id.
fn scanLabels(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .labels);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const label = row.label;
            state.next_label_id = @max(state.next_label_id, label.id +| 1);
            if (try decodeOrSkip(label.name, alloc)) |name| {
                try putStringIfAbsent(&state.labels_by_name, alloc, name, label.id);
            }
        }
    }
}

/// Scans `artwork`: paths into `artwork_by_path`, the id counter past
/// the highest artwork id.
fn scanArtwork(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .artwork);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const artwork = row.artwork;
            state.next_artwork_id = @max(state.next_artwork_id, artwork.id +| 1);
            if (try decodeOrSkip(artwork.path, alloc)) |path| {
                try putStringIfAbsent(&state.artwork_by_path, alloc, path, artwork.id);
            }
        }
    }
}

/// Scans `playlist_tree`: `id -> is_folder` into `playlist_nodes` and
/// the id counter past the highest node id.
fn scanPlaylistTree(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .playlist_tree);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const node = row.playlist_tree_node;
            state.next_playlist_node_id = @max(state.next_playlist_node_id, node.id +| 1);
            try state.playlist_nodes.put(alloc, node.id, node.isFolder());
        }
    }
}

/// Scans `playlist_entries`: per-playlist `entry_index` high-water
/// marks into `playlist_entry_counts`.
fn scanPlaylistEntries(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    var it = try rowsOrEmpty(db, .playlist_entries);
    if (it) |*rows| {
        while (try rows.next()) |row| {
            const entry = row.playlist_entry;
            const gop = try state.playlist_entry_counts.getOrPut(alloc, entry.playlist_id);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* = @max(gop.value_ptr.*, entry.entry_index +| 1);
        }
    }
}

/// Scans a plain database into a fresh `WriterState`: one pass per
/// table, rebuilding the id counters (max id + 1) and the dedup maps the
/// writer consults before inserting. First row wins on duplicate map
/// keys, except `playlist_nodes`, where the last row wins. Rows are
/// walked through the page chain, so deleted-row remnants in page heaps
/// are invisible, exactly as to readers.
pub fn scanWriterState(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
) ScanError!WriterState {
    var state = WriterState{};
    errdefer state.deinit(alloc);

    try scanTracks(alloc, db, &state);
    try scanArtists(alloc, db, &state);
    try scanAlbums(alloc, db, &state);
    try scanGenres(alloc, db, &state);
    try scanKeys(alloc, db, &state);
    try scanLabels(alloc, db, &state);
    try scanArtwork(alloc, db, &state);
    try scanPlaylistTree(alloc, db, &state);
    try scanPlaylistEntries(alloc, db, &state);

    return state;
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
