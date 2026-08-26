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
const bin = @import("bin.zig");
const anlz = @import("anlz.zig");
const dlp = @import("dlp.zig");
const pdb = @import("pdb.zig");
const setting = @import("setting.zig");
const util = @import("util.zig");

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

/// The `*SETTING.DAT` files in a device export
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

    /// The `PIONEER` directory itself.
    pub fn pioneerDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER" });
    }

    /// Directory holding the pdb files.
    pub fn rekordboxDir(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox" });
    }

    /// Path to `export.pdb`, the main database.
    pub fn exportPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "export.pdb" });
    }

    /// Path to `exportExt.pdb`, the tag database.
    pub fn exportExtPdb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "exportExt.pdb" });
    }

    /// Path to `exportLibrary.db`, the OneLibrary store of newer exports.
    pub fn exportLibraryDb(l: Layout, alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "rekordbox", "exportLibrary.db" });
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
/// JPEG files under the `PIONEER/Artwork` shard folder — the `a*` set the
/// pdb names and the `b*` set the OneLibrary db names. Rekordbox writes
/// both sets (same shard rule, `b` where the pdb set says `a`); the caller
/// writes the files, stores `thumbnail_path` in the pdb Artwork row, and
/// the OneLibrary mirror stores `ol_thumbnail_path`.
pub const ArtworkSpec = struct {
    /// Device-root-absolute path of the 80x80 thumbnail `a{id}.jpg` — the
    /// path stored in the pdb Artwork row.
    thumbnail_path: []u8,
    /// Device-root-absolute path of the 240x240 image `a{id}_m.jpg`.
    medium_path: []u8,
    /// Device-root-absolute path of the 80x80 OneLibrary variant
    /// `b{id}.jpg` — the path stored in the OneLibrary `image` row.
    ol_thumbnail_path: []u8,
    /// Device-root-absolute path of the 240x240 OneLibrary variant
    /// `b{id}_m.jpg`.
    ol_medium_path: []u8,
    codec: ArtworkCodec,
    thumbnail_resolution: Resolution,
    medium_resolution: Resolution,

    pub fn deinit(spec: *ArtworkSpec, alloc: std.mem.Allocator) void {
        alloc.free(spec.thumbnail_path);
        alloc.free(spec.medium_path);
        alloc.free(spec.ol_thumbnail_path);
        alloc.free(spec.ol_medium_path);
    }
};

/// Builds the `ArtworkSpec` for artwork row `id`.
pub fn artworkSpec(alloc: std.mem.Allocator, id: u32) std.mem.Allocator.Error!ArtworkSpec {
    const thumbnail_path = try artworkFilePath(alloc, id, 'a', "");
    errdefer alloc.free(thumbnail_path);
    const medium_path = try artworkFilePath(alloc, id, 'a', "_m");
    errdefer alloc.free(medium_path);
    const ol_thumbnail_path = try artworkFilePath(alloc, id, 'b', "");
    errdefer alloc.free(ol_thumbnail_path);
    const ol_medium_path = try artworkFilePath(alloc, id, 'b', "_m");
    return .{
        .thumbnail_path = thumbnail_path,
        .medium_path = medium_path,
        .ol_thumbnail_path = ol_thumbnail_path,
        .ol_medium_path = ol_medium_path,
        .codec = .jpeg,
        .thumbnail_resolution = .{ .width = 80, .height = 80 },
        .medium_resolution = .{ .width = 240, .height = 240 },
    };
}

/// Device-root-absolute path of one artwork file: variant `a` (pdb) or `b`
/// (OneLibrary) of `id`, with `_m` naming the 240x240 medium resolution.
fn artworkFilePath(
    alloc: std.mem.Allocator,
    id: u32,
    variant: u8,
    suffix: []const u8,
) std.mem.Allocator.Error![]u8 {
    const folder = try artworkFolder(alloc, id);
    defer alloc.free(folder);
    return std.fmt.allocPrint(alloc, "/PIONEER/Artwork/{s}/{c}{d}{s}.jpg", .{ folder, variant, id, suffix });
}

/// Device-root-absolute path of the OneLibrary 80x80 variant `b{id}.jpg`
/// the `image` mirror row stores.
fn olArtworkPath(alloc: std.mem.Allocator, id: u32) std.mem.Allocator.Error![]u8 {
    return artworkFilePath(alloc, id, 'b', "");
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

/// Error of `DeviceExport.loadSettings`: opening the pinned working
/// directory, or a setting file that exists but could not be examined —
/// unreadable, over the read cap, or memory ran out.
pub const LoadSettingsError = std.Io.Dir.ReadFileAllocError || std.Io.Dir.OpenError;

/// Reads and parses one `*SETTING.DAT` file. A missing or unparseable
/// file yields null — old exports genuinely lack files — while errors
/// examining it (permissions, memory, a length over the read cap)
/// propagate.
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

/// Error of `DeviceExport.openPdb`: opening the pinned working directory,
/// reading `export.pdb` off disk, or parsing it.
pub const OpenPdbError =
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.OpenError ||
    pdb.DatabaseDecodeError;

/// Size cap when reading an `export.pdb`; the largest fixture is 2.9 MB.
const pdb_limit = std.Io.Limit.limited(1 << 26);

/// Size cap when opening an `exportLibrary.db`, mirroring `pdb_limit`: a
/// same-schema database larger than this is refused before SQLite reads
/// it, regardless of how cheaply its rows would materialize.
const ol_db_limit: u64 = 1 << 26;

/// Error of `DeviceExport.create`: `ExportAlreadyExists` is the
/// exists-guard refusing a root that already carries a
/// `PIONEER/rekordbox/export.pdb`; the rest is opening the working
/// directory to pin it, the exists-guard's access check, and building the
/// in-memory database and setting images.
pub const CreateError =
    std.Io.Dir.AccessError ||
    std.Io.Dir.OpenError ||
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
    AtomicWriteError ||
    std.Io.Dir.DeleteFileError ||
    dlp.Writer.CreateError ||
    dlp.SqlError ||
    error{CwdUnavailable};

/// Error of `DeviceExport.writerState`: reading or parsing
/// `export.pdb`, or scanning it.
pub const WriterStateError = OpenPdbError || ScanError;

/// Error of `DeviceExport.openOlLibrary`: pinning the working directory,
/// examining or opening `exportLibrary.db` (a file over the read cap is
/// `LibraryTooLarge`), loading its models (a drifted schema is
/// `SchemaMismatch`, a disproportionate decode also `LibraryTooLarge`),
/// or building its path (the process cwd was unreadable when the handle
/// pinned it).
pub const OpenOlLibraryError =
    std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError ||
    dlp.LoadError ||
    error{ CwdUnavailable, OutOfMemory };

/// Error of the OL mirroring helpers: pinning the working directory,
/// examining or loading the existing `exportLibrary.db` (a drifted schema
/// is `SchemaMismatch`), building its path or a device ANLZ path, or
/// allocating.
pub const OlMirrorError =
    std.Io.Dir.OpenError ||
    std.Io.Dir.AccessError ||
    dlp.LoadError ||
    std.mem.Allocator.Error ||
    error{ CwdUnavailable, InvalidUtf8 };

/// `bitmask` value on fresh Rekordbox Track rows (`0x000c0700`); the
/// OneLibrary db mirrors it as `contentLink`. Copy exactly.
const track_bitmask: u32 = 788_224;

/// `unknown5` value on fresh Rekordbox Track rows; the OneLibrary db
/// mirrors it as `analysedBits`. Copy exactly.
const track_unknown5: u16 = 41;

/// A track as a user thinks of it: plain UTF-8 string slices and scalars,
/// no foreign-key ids. Input to `DeviceExport.addTrack`, which resolves
/// artists/albums/genres/keys/labels/artwork into deduplicated rows and
/// handles format quirks (the 221-byte minimum row size, centi-BPM
/// tempo); when the export carries a OneLibrary db, the same facts
/// mirror into it. Every slice is borrowed for the call only. Experts
/// needing fields not exposed here should build a `pdb.Track` row
/// directly through `openPdb`.
pub const TrackInput = struct {
    title: []const u8 = "",
    /// Performing artist name.
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    /// Musical key name (e.g. "Cmaj", "D♭min"); folded to a canonical
    /// form for dedup.
    key: []const u8 = "",
    /// Record label name.
    label: []const u8 = "",
    composer: []const u8 = "",
    remixer: []const u8 = "",
    /// Original performer, distinct from `artist` (covers/reworks).
    orig_artist: []const u8 = "",
    /// Free-text comment; also the auto-pad target when the row falls
    /// under the 221-byte minimum.
    comment: []const u8 = "",
    /// ISRC, in rekordbox's mangled format.
    isrc: []const u8 = "",
    /// Lyricist name. The pdb side keeps it as a plain string (no
    /// foreign key); the OL side resolves it to a real artist row under
    /// a minted id (see `olLyricistId`).
    lyricist: []const u8 = "",
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
    disc_number: u16 = 0,
    year: u16 = 0,
    play_count: u16 = 0,
    /// Star rating, 0-5; stored raw — the pdb byte, not the XML's
    /// `0/51/102/153/204/255` scale.
    rating: u8 = 0,
    color: util.ColorIndex = .none,
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

    // OneLibrary-only data: columns that exist in `exportLibrary.db`
    // and never reach the pdb. Ignored when the export carries no OL db
    // (an opened pdb-only export never gains one), in `-Ddlp=off`
    // builds, and on the dedup path — `addTrack` returning an existing
    // track never updates it (append-only). Every default equals the
    // fixture's convention, so a track authored without them writes the
    // same OL row as before these fields existed.

    /// Track subtitle (OL `subtitle`), empty per the fixture. Not the
    /// pdb `mix_name` string — the correspondence is plausible but no
    /// fixture pins it, so they stay separate fields.
    subtitle: []const u8 = "",
    /// Search-optimized title (OL `titleForSearch`); null writes NULL
    /// (the fixture's convention), an empty slice writes `''`.
    title_for_search: ?[]const u8 = null,
    /// KUVO delivery flag (OL `isKuvoDeliverStatusOn`); on, as the
    /// fixture carries it.
    kuvo_delivery_on: bool = true,
    /// KUVO delivery comment (OL `kuvoDeliveryComment`), empty per the
    /// fixture.
    kuvo_delivery_comment: []const u8 = "",
    /// OL `dateCreated`; null mirrors `date_added` (the fixture writes
    /// the two equal), a value makes them diverge.
    date_created: ?[]const u8 = null,
    /// OL `cueUpdateCount`; null writes NULL (fresh-export shape).
    cue_update_count: ?i64 = null,
    /// OL `analysisDataUpdateCount`; null writes NULL.
    analysis_data_update_count: ?i64 = null,
    /// OL `informationUpdateCount`; null writes NULL.
    information_update_count: ?i64 = null,
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
/// requires it), deriving its ANLZ paths, inserting the rows, or building
/// the OneLibrary mirror's view of the export.
pub const AddTrackError =
    WriterStateError ||
    PathError ||
    error{ TooLong, InvalidEncoding } ||
    pdb.DatabaseModifyError ||
    anlz.WriteError ||
    OlMirrorError;

/// Error of the playlist and tag methods: building the writer state,
/// loading or creating `exportExt.pdb`, encoding a name or label (too
/// long, or invalid UTF-8 where a format string requires it), a foreign
/// key that names no existing row, inserting the rows, or building the
/// OneLibrary mirror's view of the export.
pub const PlaylistError =
    WriterStateError ||
    OpenPdbError ||
    error{ UnknownForeignKey, TooLong, InvalidEncoding } ||
    pdb.DatabaseModifyError ||
    OlMirrorError;

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

/// Reads the process working directory through libc. Only called in
/// `-Ddlp` builds (which link libc) to snapshot the cwd a SQLite path can
/// be made absolute against; a cwd longer than the path buffer, or one
/// that cannot be read at all, reports `OutOfMemory` — callers treat that
/// as "no snapshot" and fail later at path-build time.
fn captureCwd(alloc: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.c.getcwd(&buf, buf.len) orelse return error.OutOfMemory;
    return alloc.dupe(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(p)), 0));
}

/// A handle to a Rekordbox device export on disk: the setting files and
/// the pdb database, located through `Layout`. `open` points the handle
/// at an existing export (reading; the `openPdb` escape hatch edits),
/// `create` builds a fresh one in memory. `save` is the only call that
/// writes; `deinit` discards whatever was never saved. Files the export
/// carries but the handle does not model are ignored by design:
/// `djprofile.nxs` (undocumented). The OneLibrary db
/// (`exportLibrary.db`, newer exports) is read through `openOlLibrary`
/// and mirrored by the writer side of the handle.
pub const DeviceExport = struct {
    layout: Layout,
    io: std.Io,
    alloc: std.mem.Allocator,
    /// Directory every path is resolved against — the process working
    /// directory, opened as a real handle at the first I/O call (in
    /// `create`, right away) so a later cwd change cannot reinterpret a
    /// relative root between calls. Null until then: `open` is infallible
    /// and opening the handle can fail. Closed by `deinit`.
    dir: ?std.Io.Dir,
    /// The process cwd at the moment `dir` was pinned — the absolute
    /// prefix SQLite paths are built on (they resolve against the process
    /// cwd, not the pinned handle). Null in `-Ddlp=off` builds (nothing
    /// needs it), until the pin, or when the cwd was unreadable.
    dir_path: ?[]u8 = null,
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
    /// The OneLibrary db read side (`openOlLibrary`), independent of the
    /// writer side.
    ol_library: OlLibraryState = .unloaded,
    /// The OneLibrary db write side: rows mirrored by the mutating
    /// methods, buffered until `save` materializes them.
    ol_state: OlState = .unloaded,

    const PdbState = union(enum) {
        /// An export opened at `root`; the pdb parses on first touch.
        unloaded,
        /// In memory — parsed from disk or built by `create`.
        loaded: pdb.Database,
    };

    /// Lifecycle of the `exportLibrary.db` models, loaded on first
    /// `openOlLibrary` call and cached for the handle's life.
    const OlLibraryState = union(enum) {
        /// Not examined yet; the first call checks the disk.
        unloaded,
        /// No `exportLibrary.db` under the root (older exports).
        absent,
        /// Loaded and cached; owned by the handle.
        loaded: dlp.Library,
    };

    /// Lifecycle of the OneLibrary write side. Mirroring is a no-op in
    /// the `absent` state: an opened export without an
    /// `exportLibrary.db` never gains one — only `create` builds a fresh
    /// db.
    const OlState = union(enum) {
        /// Not examined yet; the first mirrored mutation checks the disk.
        unloaded,
        /// No `exportLibrary.db` under the root; nothing mirrors.
        absent,
        /// The store: pending rows plus (once mirroring lands) the dedup
        /// state over the existing db and the pending rows.
        store: OlStore,
    };

    /// Lifecycle of the tag database. A created export starts `absent`
    /// (its first tag write starts fresh); an opened one starts
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
    /// containing `PIONEER`). Cheap and infallible: nothing is opened or
    /// read until the first I/O call. The root path is borrowed; keep it
    /// alive until `deinit`.
    pub fn open(root_path: []const u8, io: std.Io, alloc: std.mem.Allocator) DeviceExport {
        return .{
            .layout = .{ .root = root_path },
            .io = io,
            .alloc = alloc,
            .dir = null,
        };
    }

    /// The pinned working directory, opening it on first use. `Dir.cwd()`
    /// is only an `AT_FDCWD` sentinel — every call resolves against the
    /// process cwd as it is *then* — so a real handle is opened once and
    /// reused. `-Ddlp` builds also snapshot the cwd string: SQLite, which
    /// the OneLibrary store goes through, resolves paths against the
    /// process cwd rather than a directory handle.
    fn dirHandle(e: *DeviceExport) (std.Io.Dir.OpenError || std.mem.Allocator.Error)!std.Io.Dir {
        if (e.dir == null) {
            e.dir = try std.Io.Dir.cwd().openDir(e.io, ".", .{});
            if (dlp.mode != .off) {
                // A cwd that cannot be read leaves `dir_path` null; the
                // OneLibrary paths then fail with `CwdUnavailable`.
                e.dir_path = captureCwd(e.alloc) catch null;
            }
        }
        return e.dir.?;
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
        // Pin the working directory now: create is the export's first I/O.
        const dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
        errdefer dir.close(io);
        const dir_path: ?[]u8 = if (dlp.mode != .off)
            captureCwd(alloc) catch null
        else
            null;
        errdefer if (dir_path) |p| alloc.free(p);

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
            .dir_path = dir_path,
            .pdb_state = .{ .loaded = db },
            .pending_settings = pending,
            // Fresh counters and empty maps: the default color/column/menu
            // rows live in tables the writer doesn't track.
            .writer_state = .{ .arena = std.heap.ArenaAllocator.init(alloc) },
            // Absent, not unloaded: create never reads a leftover
            // `exportExt.pdb`.
            .ext_pdb_state = .absent,
            // The OneLibrary db is part of a created export's shape; it
            // exists only in memory until the first `save` builds it.
            .ol_state = .{ .store = .{
                .arena = std.heap.ArenaAllocator.init(alloc),
                .fresh = true,
            } },
        };
    }

    /// Frees everything the handle holds. Unsaved state is discarded —
    /// there is no implicit flush.
    pub fn deinit(e: *DeviceExport) void {
        switch (e.pdb_state) {
            .loaded => |*db| db.deinit(),
            .unloaded => {},
        }
        switch (e.ext_pdb_state) {
            .loaded => |*db| db.deinit(),
            .unloaded, .absent => {},
        }
        switch (e.ol_library) {
            .loaded => |*lib| lib.deinit(),
            .unloaded, .absent => {},
        }
        switch (e.ol_state) {
            .store => |*store| store.deinit(),
            .unloaded, .absent => {},
        }
        if (e.pending_settings) |pending| {
            for (pending) |bytes| e.alloc.free(bytes);
        }
        if (e.writer_state) |*state| state.deinit();
        for (e.pending_anlz.items) |*file| file.deinit(e.alloc);
        e.pending_anlz.deinit(e.alloc);
        if (e.dir_path) |path| e.alloc.free(path);
        if (e.dir) |dir| dir.close(e.io);
    }

    pub fn root(e: *const DeviceExport) []const u8 {
        return e.layout.root;
    }

    /// Loads the four `*SETTING.DAT` files in `dat_files` order. A
    /// missing or invalid file leaves its field null; a file that
    /// cannot be examined is an error.
    pub fn loadSettings(e: *DeviceExport) LoadSettingsError!Settings {
        const dir = try e.dirHandle();
        var settings = Settings{};
        inline for (dat_files) |dat| {
            const payload = try loadSettingFile(
                SettingPayload(dat.kind),
                e.io,
                dir,
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
                const dir = try e.dirHandle();
                const buf = try dir.readFileAlloc(e.io, path, e.alloc, pdb_limit);
                defer e.alloc.free(buf);
                // Load before tagging the union: a `.loaded = try ...`
                // initializer can set the tag before the payload exists,
                // leaving `deinit` a garbage pointer on failure.
                const db = try pdb.Database.parse(e.alloc, buf, .plain);
                e.pdb_state = .{ .loaded = db };
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

    /// The export's OneLibrary db (`exportLibrary.db`, carried by newer
    /// exports), loaded on first call and cached until `deinit`; null when
    /// the export carries none. The join to the pdb side is by path:
    /// `content.path` values are the device-root-absolute file paths the
    /// pdb Track rows store, so `lib.contentByPath(file_path)` hands back
    /// the OL view of a track — including the fields the pdb lacks
    /// (remixer/composer/lyricist/original-artist ids, subtitle, bit
    /// depth, sampling rate, djPlayCount). Only compiled with
    /// `-Ddlp=vendored` (or `=system`).
    pub fn openOlLibrary(e: *DeviceExport) OpenOlLibraryError!?*const dlp.Library {
        if (dlp.mode == .off)
            @compileError("rekordlib was built with -Ddlp=off; rebuild with -Ddlp=vendored (or =system) to read the OneLibrary store");
        switch (e.ol_library) {
            .loaded => |*lib| return lib,
            .absent => return null,
            .unloaded => {
                const dir = try e.dirHandle();
                const rel = try e.layout.exportLibraryDb(e.alloc);
                defer e.alloc.free(rel);
                const stat = dir.statFile(e.io, rel, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        e.ol_library = .absent;
                        return null;
                    },
                    else => return err,
                };
                if (stat.size > ol_db_limit) return error.LibraryTooLarge;

                const path = try e.olDbPath();
                defer e.alloc.free(path);
                var db = try dlp.Db.open(e.io, path);
                errdefer db.close();
                // Same tag-then-payload hazard as `openPdb`: load first.
                const lib = try dlp.Library.load(e.alloc, db);
                db.close();
                e.ol_library = .{ .loaded = lib };
                return &e.ol_library.loaded;
            },
        }
    }

    /// The absolute, NUL-terminated path of `exportLibrary.db`. SQLite
    /// resolves file names against the process cwd, not the pinned
    /// directory handle, so the cwd snapshot taken at pin time prefixes a
    /// relative root; the caller owns the result.
    fn olDbPath(e: *DeviceExport) error{ CwdUnavailable, OutOfMemory }![:0]u8 {
        const prefix = e.dir_path orelse return error.CwdUnavailable;
        if (std.fs.path.isAbsolute(e.layout.root)) {
            return std.fmt.allocPrintSentinel(
                e.alloc,
                "{s}/PIONEER/rekordbox/exportLibrary.db",
                .{e.layout.root},
                0,
            );
        }
        return std.fmt.allocPrintSentinel(
            e.alloc,
            "{s}/{s}/PIONEER/rekordbox/exportLibrary.db",
            .{ prefix, e.layout.root },
            0,
        );
    }

    /// The OneLibrary store, building it on first use: an export that
    /// carries an `exportLibrary.db` gets a store holding its rows' dedup
    /// state (the db is loaded and closed again — pending rows are the
    /// only mutations until `save`); an export without one never gains
    /// one, so mirroring is a no-op there. Null in the absent case — and
    /// always, in `-Ddlp=off` builds, where mirroring is compiled out.
    fn olStore(e: *DeviceExport) OlMirrorError!?*OlStore {
        if (dlp.mode == .off) return null;
        switch (e.ol_state) {
            .store => |*store| return store,
            .absent => return null,
            .unloaded => {
                const dir = try e.dirHandle();
                const rel = try e.layout.exportLibraryDb(e.alloc);
                defer e.alloc.free(rel);
                if (dir.access(e.io, rel, .{})) |_| {} else |err| switch (err) {
                    error.FileNotFound => {
                        e.ol_state = .absent;
                        return null;
                    },
                    else => return err,
                }

                const path = try e.olDbPath();
                defer e.alloc.free(path);
                var db = try dlp.Db.open(e.io, path);
                errdefer db.close();
                var lib = try dlp.Library.load(e.alloc, db);
                defer lib.deinit();
                db.close();

                var store = OlStore{ .arena = std.heap.ArenaAllocator.init(e.alloc) };
                errdefer store.deinit();
                try scanOlStore(&lib, &store);
                e.ol_state = .{ .store = store };
                return &e.ol_state.store;
            },
        }
    }

    /// Builds the OL store before a mutating method touches the pdb, so
    /// an unopenable or schema-drifted `exportLibrary.db` fails the call
    /// with the export untouched. A no-op on exports that carry no db
    /// (and in `-Ddlp=off` builds).
    fn primeOlStore(e: *DeviceExport) OlMirrorError!void {
        _ = try e.olStore();
    }

    /// Mirrors a just-inserted track into the OL store: one `content` row
    /// plus whatever dimension rows its foreign keys need, resolved
    /// against the store's dedup state. The OL-only columns come from
    /// the `TrackInput` fields of the same names; their defaults keep
    /// the fixture's conventions — unset artist roles bind NULL while
    /// the dimension foreign keys (`album_id`, `genre_id`, `label_id`,
    /// `key_id`, `color_id`) bind 0, `artist_id_lyricist` binds 0 with
    /// no lyricist and a minted artist id with one,
    /// `titleForSearch` is NULL but `subtitle`/`isrc`/
    /// `kuvoDeliveryComment` are empty text, `dateCreated` mirrors
    /// `date_added`, `analysedBits`/`contentLink` carry the pdb row's
    /// constants, and no master-db ids are written (writers may leave
    /// them out). A failure after some rows appended leaves those
    /// pending — the same residual risk as `addTrack`'s pdb dimension
    /// rows.
    fn mirrorAddedTrack(
        e: *DeviceExport,
        track: TrackInput,
        row: *const pdb.Track,
    ) OlMirrorError!void {
        const store = (try e.olStore()) orelse return;
        const a = store.arena.allocator();

        const artist_id = try olNamedRow(
            store,
            &store.artists_by_name,
            &store.artists,
            olArtistRow,
            row.artist_id,
            track.artist,
        );
        const remixer_id = try olNamedRow(
            store,
            &store.artists_by_name,
            &store.artists,
            olArtistRow,
            row.remixer_id,
            track.remixer,
        );
        const orig_artist_id = try olNamedRow(
            store,
            &store.artists_by_name,
            &store.artists,
            olArtistRow,
            row.orig_artist_id,
            track.orig_artist,
        );
        const composer_id = try olNamedRow(
            store,
            &store.artists_by_name,
            &store.artists,
            olArtistRow,
            row.composer_id,
            track.composer,
        );
        // No pdb id to bridge — the pdb keeps the lyricist as a plain
        // string — so a new name gets a minted id.
        const lyricist_id = try olLyricistId(store, track.lyricist);
        const genre_id = try olNamedRow(
            store,
            &store.genres_by_name,
            &store.genres,
            olGenreRow,
            row.genre_id,
            track.genre,
        );
        const label_id = try olNamedRow(
            store,
            &store.labels_by_name,
            &store.labels,
            olLabelRow,
            row.label_id,
            track.label,
        );
        const key_id = try olKeyId(store, track.key, row.key_id);
        const album_id = try olAlbumId(store, track.album, row.album_id, artist_id);
        const image_id = try olImageId(store, row.artwork_id);

        const analysis_path: ?[]const u8 = if (track.analysis != null)
            try anlzDevicePath(a, track.file_path)
        else
            null;

        try store.contents.append(a, .{
            .content_id = row.id,
            .title = try a.dupe(u8, track.title),
            .titleForSearch = if (track.title_for_search) |s| try a.dupe(u8, s) else null,
            .subtitle = try a.dupe(u8, track.subtitle),
            .bpmx100 = row.tempo,
            .length = row.duration,
            .trackNo = row.track_number,
            .discNo = row.disc_number,
            .artist_id_artist = artist_id,
            .artist_id_remixer = remixer_id,
            .artist_id_originalArtist = orig_artist_id,
            .artist_id_composer = composer_id,
            .artist_id_lyricist = lyricist_id orelse 0,
            .album_id = album_id orelse 0,
            .genre_id = genre_id orelse 0,
            .label_id = label_id orelse 0,
            .key_id = key_id orelse 0,
            .color_id = @intFromEnum(row.color),
            .image_id = image_id,
            .djComment = try a.dupe(u8, track.comment),
            .rating = row.rating,
            .releaseYear = row.year,
            .releaseDate = try a.dupe(u8, track.release_date),
            .dateCreated = try a.dupe(u8, track.date_created orelse track.date_added),
            .dateAdded = try a.dupe(u8, track.date_added),
            .path = try a.dupe(u8, track.file_path),
            .fileName = try a.dupe(u8, track.filename),
            .fileSize = row.file_size,
            .fileType = @intFromEnum(row.file_type),
            .bitrate = row.bitrate,
            .bitDepth = row.sample_depth,
            .samplingRate = row.sample_rate,
            .isrc = try a.dupe(u8, track.isrc),
            .djPlayCount = row.play_count,
            .isHotCueAutoLoadOn = if (track.autoload_hotcues) 1 else 0,
            .isKuvoDeliverStatusOn = if (track.kuvo_delivery_on) 1 else 0,
            .kuvoDeliveryComment = try a.dupe(u8, track.kuvo_delivery_comment),
            .masterDbId = null,
            .masterContentId = null,
            .analysisDataFilePath = analysis_path,
            .analysedBits = track_unknown5,
            .contentLink = track_bitmask,
            .hasModified = 0,
            .cueUpdateCount = track.cue_update_count,
            .analysisDataUpdateCount = track.analysis_data_update_count,
            .informationUpdateCount = track.information_update_count,
        });
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
    /// inserts a Track row pointing at them by id. When the export
    /// carries a OneLibrary db (`create`d exports, newer opened ones),
    /// the same facts mirror into it: one content row per track, its
    /// dimension rows deduped through the OL side's own view, its ids
    /// bridged from the pdb side.
    ///
    /// Idempotent on a non-empty `file_path`: if a track with that path
    /// was already added (this session, or read back by the writer-state
    /// scan of an opened export), the existing id is returned and nothing
    /// is inserted; `AddTrackOutcome.is_new` tells the cases apart.
    ///
    /// Everything that can fail on the caller's data — string encoding,
    /// ANLZ serialization, the OL store's view of the export — happens
    /// before any id is taken or row inserted, so a bad string leaves the
    /// export untouched. A failure between the dimension-row inserts and
    /// the Track row (allocation failure, or a database counters
    /// inconsistency) can still leave orphaned dimension rows —
    /// unreachable from any track, ignored by players, not recovered
    /// automatically — and a failure in the OL mirroring after the Track
    /// insert leaves the pdb side complete with the OL side partially
    /// pending (same risk class; the next `save` lands what pends).
    pub fn addTrack(e: *DeviceExport, track: TrackInput) AddTrackError!AddTrackOutcome {
        const state = try e.writerState();
        if (track.file_path.len > 0) {
            if (state.tracks_by_path.get(track.file_path)) |id|
                return .{ .id = id, .is_new = false };
        }
        try e.primeOlStore();
        const track_id = state.next_track_id;

        // The caller's data fails here or never: nothing below this point
        // is rolled back.
        var anlz_files = try e.buildAnlzFiles(track);
        errdefer for (&anlz_files) |*slot| {
            if (slot.*) |*file| file.deinit(e.alloc);
        };
        const row = try e.buildTrackRow(track, track.analysis != null);

        const db = try e.openPdb();
        const artist_id = try getOrCreateArtist(state, db, track.artist);
        const album_id = try getOrCreateAlbum(state, db, track.album, artist_id);
        const genre_id = try getOrCreateGenre(state, db, track.genre);
        const key_id = try getOrCreateKey(state, db, track.key);
        const label_id = try getOrCreateLabel(state, db, track.label);
        const artwork_id = try getOrCreateArtwork(state, db, track.artwork_device_path);
        const composer_id =
            if (track.composer.len == 0) 0 else try getOrCreateArtist(state, db, track.composer);
        const orig_artist_id =
            if (track.orig_artist.len == 0) 0 else try getOrCreateArtist(state, db, track.orig_artist);
        const remixer_id =
            if (track.remixer.len == 0) 0 else try getOrCreateArtist(state, db, track.remixer);

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
        // insert cannot fail half-applied. Map keys and capacity come from
        // the state's arena, so a key orphaned by a failure is reclaimed
        // with the state instead of freed here.
        try e.pending_anlz.ensureUnusedCapacity(e.alloc, anlz_files.len);
        const sa = state.arena.allocator();
        try state.track_ids.ensureUnusedCapacity(sa, 1);
        var owned_path: ?[]u8 = null;
        if (track.file_path.len > 0) {
            owned_path = try sa.dupe(u8, track.file_path);
            try state.tracks_by_path.ensureUnusedCapacity(sa, 1);
        }

        var row_union = pdb.Row{ .track = row };
        _ = try db.addRow(&row_union);

        state.next_track_id += 1;
        state.track_ids.putAssumeCapacity(track_id, {});
        if (owned_path) |path| state.tracks_by_path.putAssumeCapacity(path, track_id);
        for (anlz_files) |slot| if (slot) |file|
            e.pending_anlz.appendAssumeCapacity(file);

        try e.mirrorAddedTrack(track, row);

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
        // `file_path` the way players recompute it.
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
            .offsets = .{
                .inner = .{
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
                },
            },
        };
        try pdb.padTrackCommentToMinimum(boxed, a);
        return boxed;
    }

    /// Serializes the `ANLZ0000` images `track.analysis` asks for:
    /// `.DAT` only when it carries a section beyond the leading path,
    /// `.EXT` when the
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
        files[0] = try e.serializeAnlzGroup(track.file_path, .dat, &.{
            path_section,
            if (input.beats.len > 0)
                anlz.Content{ .beat_grid = .{ .beats = input.beats } }
            else
                null,
            if (input.cues.len > 0)
                anlz.Content{ .cue_list = .{
                    .list_type = input.cue_list_type,
                    .cues = input.cues,
                } }
            else
                null,
            if (input.preview_mono.len > 0)
                anlz.Content{ .waveform_preview = .{ .data = input.preview_mono } }
            else
                null,
            if (input.tiny_preview.len > 0)
                anlz.Content{ .tiny_waveform_preview = .{ .data = input.tiny_preview } }
            else
                null,
        });

        // `.EXT`: extended cues plus the optional column groups.
        files[1] = try e.serializeAnlzGroup(track.file_path, .ext, &.{
            path_section,
            if (input.cues_extended.len > 0)
                anlz.Content{ .extended_cue_list = .{
                    .list_type = input.cue_list_type,
                    .cues = input.cues_extended,
                } }
            else
                null,
            if (input.detail_mono) |cols|
                anlz.Content{ .waveform_detail = .{ .data = cols } }
            else
                null,
            if (input.color_preview) |cols|
                anlz.Content{ .waveform_color_preview = .{ .data = cols } }
            else
                null,
            if (input.color_detail) |cols|
                anlz.Content{ .waveform_color_detail = .{ .data = cols } }
            else
                null,
        });

        // `.2EX`: the 3-band groups.
        files[2] = try e.serializeAnlzGroup(track.file_path, .two_ex, &.{
            path_section,
            if (input.band3_preview) |cols|
                anlz.Content{ .waveform_3band_preview = .{ .data = cols } }
            else
                null,
            if (input.band3_detail) |cols|
                anlz.Content{ .waveform_3band_detail = .{ .data = cols } }
            else
                null,
        });

        return files;
    }

    /// Serializes the non-null `sections` into one sibling's image,
    /// paired with the host path it lands at. If only the path section
    /// is present, the sibling carries no data and nothing is queued.
    fn serializeAnlzGroup(
        e: *DeviceExport,
        file_path: []const u8,
        sibling: AnlzSibling,
        sections: []const ?anlz.Content,
    ) AddTrackError!?PendingAnlz {
        var n: usize = 0;
        for (sections) |section| {
            if (section != null) n += 1;
        }
        if (n <= 1) return null;

        var compact: [5]anlz.Content = undefined;
        var i: usize = 0;
        for (sections) |section| {
            if (section) |content| {
                compact[i] = content;
                i += 1;
            }
        }
        return try e.serializeAnlz(file_path, sibling, compact[0..n]);
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

    /// `getOrCreateStringRow` for Artist rows.
    fn getOrCreateArtist(
        state: *WriterState,
        db: *pdb.Database,
        name: []const u8,
    ) AddTrackError!u32 {
        return getOrCreateStringRow(
            state,
            db,
            &state.artists_by_name,
            &state.next_artist_id,
            buildArtistRow,
            name,
        );
    }

    /// `getOrCreateStringRow` for Genre rows.
    fn getOrCreateGenre(state: *WriterState, db: *pdb.Database, name: []const u8) AddTrackError!u32 {
        return getOrCreateStringRow(state, db, &state.genres_by_name, &state.next_genre_id, buildGenreRow, name);
    }

    /// `getOrCreateStringRow` for Label rows.
    fn getOrCreateLabel(state: *WriterState, db: *pdb.Database, name: []const u8) AddTrackError!u32 {
        return getOrCreateStringRow(state, db, &state.labels_by_name, &state.next_label_id, buildLabelRow, name);
    }

    /// `getOrCreateStringRow` for Artwork rows.
    fn getOrCreateArtwork(state: *WriterState, db: *pdb.Database, path: []const u8) AddTrackError!u32 {
        return getOrCreateStringRow(state, db, &state.artwork_by_path, &state.next_artwork_id, buildArtworkRow, path);
    }

    /// Resolves `name` through `map` to a row built by `build_row`,
    /// inserting one under a fresh id when no scanned or previously
    /// created row carries the name; `counter` is the table's id counter.
    /// Empty names resolve to the null id 0. The map key is duped and its
    /// capacity reserved before the insert, so the bookkeeping after it
    /// cannot fail half-applied (the same discipline as `addTrack` and
    /// `getOrCreateTag`: a failure can orphan a row, never leave the map
    /// missing one).
    fn getOrCreateStringRow(
        state: *WriterState,
        db: *pdb.Database,
        map: *std.StringHashMapUnmanaged(u32),
        counter: *u32,
        comptime build_row: fn (
            std.mem.Allocator,
            u32,
            []const u8,
        ) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row,
        name: []const u8,
    ) AddTrackError!u32 {
        if (name.len == 0) return 0;
        if (map.get(name)) |id| return id;

        const id = counter.*;
        const sa = state.arena.allocator();
        const owned = try sa.dupe(u8, name);
        try map.ensureUnusedCapacity(sa, 1);
        var row = try build_row(db.arena.allocator(), id, name);
        _ = try db.addRow(&row);
        counter.* = id + 1;
        map.putAssumeCapacity(owned, id);
        return id;
    }

    /// Resolves `(artist_id, name)` to an Album row, inserting one when
    /// needed — albums are per-artist. An empty name resolves to the null
    /// id 0.
    fn getOrCreateAlbum(
        state: *WriterState,
        db: *pdb.Database,
        name: []const u8,
        artist_id: u32,
    ) AddTrackError!u32 {
        if (name.len == 0) return 0;
        if (state.albums_by_artist_and_name.get(.{ .artist_id = artist_id, .name = name })) |id|
            return id;

        const id = state.next_album_id;
        const sa = state.arena.allocator();
        const owned = try sa.dupe(u8, name);
        try state.albums_by_artist_and_name.ensureUnusedCapacity(sa, 1);
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
        state.albums_by_artist_and_name.putAssumeCapacity(
            AlbumKey{ .artist_id = artist_id, .name = owned },
            id,
        );
        return id;
    }

    /// Resolves `name` — folded through `canonicalKeyName` — to a Key
    /// row, inserting one when no canonical spelling matches. Empty names
    /// resolve to the null id 0.
    fn getOrCreateKey(state: *WriterState, db: *pdb.Database, name: []const u8) AddTrackError!u32 {
        if (name.len == 0) return 0;
        const sa = state.arena.allocator();
        const canonical = try canonicalKeyName(sa, name);
        if (state.keys_by_canonical.get(canonical)) |id| return id;

        const id = state.next_key_id;
        try state.keys_by_canonical.ensureUnusedCapacity(sa, 1);
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
        state.keys_by_canonical.putAssumeCapacity(canonical, id);
        return id;
    }

    /// Creates a playlist folder — a node that groups other folders and
    /// playlists — and returns its id. `parent_id` is 0 (the tree root)
    /// or the id of an existing folder (one this method or a scanned
    /// export created); anything else, including a playlist's id, is
    /// `UnknownForeignKey`. When the export carries a OneLibrary db the
    /// node mirrors into it (`attribute` 1).
    pub fn createPlaylistFolder(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
    ) PlaylistError!u32 {
        return e.createPlaylistNode(name, parent_id, true);
    }

    /// Creates a playlist — a leaf node holding tracks through
    /// `addTrackToPlaylist` — under `parent_id` (same rule as
    /// `createPlaylistFolder`) and returns its id. When the export
    /// carries a OneLibrary db the node mirrors into it (`attribute` 0).
    pub fn createPlaylist(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
    ) PlaylistError!u32 {
        return e.createPlaylistNode(name, parent_id, false);
    }

    /// Inserts the node row and records it in the writer state. The name
    /// encodes before anything is inserted, so a too-long name leaves
    /// the export untouched; the id counter bumps only after the insert,
    /// so a failed call mints no id.
    fn createPlaylistNode(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
        is_folder: bool,
    ) PlaylistError!u32 {
        const state = try e.writerState();
        try e.primeOlStore();
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
        try state.playlist_nodes.ensureUnusedCapacity(state.arena.allocator(), 1);
        var row = pdb.Row{ .playlist_tree_node = boxed };
        _ = try db.addRow(&row);

        state.next_playlist_node_id = id + 1;
        state.playlist_nodes.putAssumeCapacity(id, is_folder);

        if (try e.olStore()) |store|
            try mirrorPlaylistRow(store, name, parent_id, id, is_folder);
        return id;
    }

    /// Appends a track to the end of a playlist; the entry position is
    /// assigned automatically, dense from 0 and continuing across save
    /// and reopen. `playlist_id` must name an existing *playlist* (a
    /// folder id is rejected — tracks go into playlists only) and
    /// `track_id` an existing track, else `UnknownForeignKey`. When the
    /// export carries a OneLibrary db the membership mirrors into it —
    /// with the OL side's own dense 1-based `sequenceNo`, continuing
    /// past the rows already there.
    pub fn addTrackToPlaylist(
        e: *DeviceExport,
        playlist_id: u32,
        track_id: u32,
    ) PlaylistError!void {
        const state = try e.writerState();
        try e.primeOlStore();
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
        try state.playlist_entry_counts.ensureUnusedCapacity(state.arena.allocator(), 1);
        var row = pdb.Row{ .playlist_entry = boxed };
        _ = try db.addRow(&row);

        const gop = state.playlist_entry_counts.getOrPutAssumeCapacity(playlist_id);
        gop.value_ptr.* = entry_index + 1;

        if (try e.olStore()) |store| {
            try store.playlist_pairs.append(store.arena.allocator(), .{
                .playlist_id = playlist_id,
                .content_id = track_id,
            });
        }
    }

    /// Creates a top-level tag category (e.g. "My Tags") in the tag
    /// database and returns its id. Leaf tags attach under a category
    /// through `addTagsToTrack`. The tag database (`exportExt.pdb`) loads
    /// lazily on first use; nothing lands on disk before `save`. When
    /// the export carries a OneLibrary db the category mirrors into its
    /// `myTag` tree under the same id.
    pub fn createTagCategory(e: *DeviceExport, name: []const u8) TagError!u32 {
        const state = try e.writerState();
        try e.primeOlStore();
        const db = try e.extDb();
        const id = state.next_tag_id;
        const row_index = state.next_tag_row_index;
        const position = state.next_category_position;
        const a = db.arena.allocator();
        const boxed = try buildTagRow(a, .{
            .parent_id = 0,
            .position = position,
            .id = id,
            .is_category = true,
            .row_index = row_index,
        }, name);
        try state.tag_categories.ensureUnusedCapacity(state.arena.allocator(), 1);
        var row = pdb.Row{ .tag = boxed };
        _ = try db.addRow(&row);

        state.next_tag_id = id + 1;
        state.next_tag_row_index = row_index + 1;
        state.next_category_position += 1;
        state.tag_categories.putAssumeCapacity(id, {});

        if (try e.olStore()) |store|
            try mirrorMyTagRow(store, name, id, position, true, 0);
        return id;
    }

    /// Associates `labels` with `track_id` under `category_id` in the tag
    /// database. Empty labels are dropped and duplicates — within this
    /// call or already existing under the category — collapse to one leaf
    /// row. The junction rows themselves are not deduplicated: each call
    /// inserts one junction per kept label, so repeating a label in a
    /// later call stacks a duplicate junction (junction rows carry no
    /// writer state, so recovery cannot see them). `track_id` must name
    /// an existing track and `category_id` a category this handle knows
    /// (one returned by `createTagCategory`, or one recovered from the
    /// opened `exportExt.pdb`), else `UnknownForeignKey`. A failure
    /// between leaf rows leaves the earlier ones inserted — unreachable
    /// junctions are ignored by players, not recovered automatically
    /// (the same residual risk as `addTrack`'s dimension rows). When the
    /// export carries a OneLibrary db, new leaf tags mirror into its
    /// `myTag` tree under their ext ids and every junction lands as a
    /// `myTag_content` row.
    pub fn addTagsToTrack(
        e: *DeviceExport,
        track_id: u32,
        category_id: u32,
        labels: []const []const u8,
    ) TagError!void {
        const state = try e.writerState();
        try e.primeOlStore();
        // The category check needs the tag state an opened export's
        // `exportExt.pdb` carries, so the tag database loads (from disk
        // only — not created) before either key is validated.
        try e.ensureExtLoaded();
        if (!state.track_ids.contains(track_id)) return error.UnknownForeignKey;
        if (!state.tag_categories.contains(category_id)) return error.UnknownForeignKey;

        // Order-preserving dedup: `seen` answers membership, `kept`
        // carries the surviving labels in first-seen order.
        var kept = std.ArrayList([]const u8).empty;
        defer kept.deinit(e.alloc);
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(e.alloc);
        for (labels) |label| {
            if (label.len == 0) continue;
            const gop = try seen.getOrPut(e.alloc, label);
            if (!gop.found_existing) try kept.append(e.alloc, label);
        }
        if (kept.items.len == 0) return;

        const ext_db = try e.extDb();
        for (kept.items) |label| {
            const tag_id = try e.getOrCreateTag(state, ext_db, category_id, label);
            const a = ext_db.arena.allocator();
            const boxed = try a.create(pdb.TrackTag);
            boxed.* = .{ .track_id = track_id, .tag_id = tag_id };
            var row = pdb.Row{ .track_tag = boxed };
            _ = try ext_db.addRow(&row);

            if (try e.olStore()) |store|
                try store.my_tag_pairs.append(store.arena.allocator(), .{
                    .myTag_id = tag_id,
                    .content_id = track_id,
                });
        }
    }

    /// Resolves `(category_id, label)` to a leaf tag, inserting one when
    /// no scanned or previously created leaf matches. The id counter and
    /// `index_shift` row counter bump only after the insert.
    fn getOrCreateTag(
        e: *DeviceExport,
        state: *WriterState,
        db: *pdb.Database,
        category_id: u32,
        label: []const u8,
    ) TagError!u32 {
        if (state.tags_by_key.get(.{ .category_id = category_id, .label = label })) |id|
            return id;

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

        // The map key outlives the call in the state's arena; reserve both
        // map updates before the insert so the bookkeeping after it cannot
        // fail half-applied.
        const sa = state.arena.allocator();
        const owned_label = try sa.dupe(u8, label);
        try state.tags_by_key.ensureUnusedCapacity(sa, 1);
        try state.tag_leaf_counts.ensureUnusedCapacity(sa, 1);
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

        if (try e.olStore()) |store|
            try mirrorMyTagRow(store, label, id, position, false, category_id);
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
            // Same tag-then-payload hazard as `openPdb`: create first.
            const db = try pdb.Database.create(
                e.alloc,
                .ext,
                &pdb.ext_table_page_types,
            );
            e.ext_pdb_state = .{ .loaded = db };
        }
        return &e.ext_pdb_state.loaded;
    }

    /// Examines `exportExt.pdb` once: present, it parses into the state
    /// and its tag rows extend the writer state; absent, the state is
    /// only marked. A failure leaves the state `unloaded` — a retry
    /// re-reads the file.
    fn ensureExtLoaded(e: *DeviceExport) WriterStateError!void {
        if (e.ext_pdb_state != .unloaded) return;

        const path = try e.layout.exportExtPdb(e.alloc);
        defer e.alloc.free(path);
        const dir = try e.dirHandle();
        const buf = dir.readFileAlloc(e.io, path, e.alloc, pdb_limit) catch |err| switch (err) {
            error.FileNotFound => {
                e.ext_pdb_state = .absent;
                return;
            },
            else => return err,
        };
        defer e.alloc.free(buf);
        var db = try pdb.Database.parse(e.alloc, buf, .ext);
        errdefer db.deinit();
        const state = try e.writerState();
        try scanExtTags(state.arena.allocator(), &db, state);
        e.ext_pdb_state = .{ .loaded = db };
    }

    /// Writes the buffered export to disk — the handle's only
    /// disk-writing call. Everything that can fail on the in-memory
    /// model — parsing, track-row validation, serialization — happens
    /// before the first write, so a failed `save` leaves the disk
    /// untouched. Crash-safe write order: the default directory tree,
    /// the four setting files, the queued ANLZ files, `exportExt.pdb`
    /// when the tag methods loaded or created one, `exportLibrary.db`
    /// when the OneLibrary side was created or carries pending rows,
    /// then `export.pdb` — the index everything else is reached
    /// through — last, so a crash leaves orphan files players ignore,
    /// not rows naming missing data. Every file lands through
    /// `writeFileAtomic`, so readers never see a torn one.
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

        const dir = try e.dirHandle();
        if (e.pending_settings) |pending| try e.writePendingSettings(dir, pending);
        if (e.pending_anlz.items.len > 0) try e.writePendingAnlz(dir);

        if (ext_image) |bytes| {
            const ext_path = try e.layout.exportExtPdb(e.alloc);
            defer e.alloc.free(ext_path);
            try e.writeFileAtomic(dir, ext_path, bytes);
        }

        try e.writeOl();

        const pdb_path = try e.layout.exportPdb(e.alloc);
        defer e.alloc.free(pdb_path);
        try e.writeFileAtomic(dir, pdb_path, image);
    }

    /// Lands the OneLibrary side on disk — between `exportExt.pdb` and
    /// `export.pdb`, per the crash-safe order (a crash leaves the index
    /// naming the previous consistent state; an OL db ahead of it is
    /// ignored like an export without one). A created export builds a
    /// fresh keyed db on its first `save` even with nothing pending —
    /// newer exports carry one — overwriting a leftover file; the
    /// property's `createdDate` lands empty (the library reads no clock
    /// and `create` takes no date). Later saves touch the file only when
    /// rows are pending. `close` checkpoints, so the landed file is
    /// complete with no `-wal`/`-shm` sidecars, exactly rb's shape.
    /// Skipped entirely in `-Ddlp=off` builds.
    fn writeOl(e: *DeviceExport) SaveError!void {
        if (dlp.mode == .off) return;
        const store = switch (e.ol_state) {
            .store => |*store| store,
            // Nothing mirrored — no db, or an untouched one: never write.
            .unloaded, .absent => return,
        };
        if (!store.fresh and !store.hasPending()) return;

        const rel = try e.layout.exportLibraryDb(e.alloc);
        defer e.alloc.free(rel);
        const path = try e.olDbPath();
        defer e.alloc.free(path);

        var w: dlp.Writer = undefined;
        if (store.fresh) {
            // A created export starts from an empty db even over a
            // leftover file — the same overwrite stance as the ext pdb.
            const dir = try e.dirHandle();
            dir.deleteFile(e.io, rel) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            w = try dlp.Writer.create(e.io, path, .{ .created_date = "" });
        } else {
            w = try dlp.Writer.open(e.io, path);
        }
        errdefer w.db.close();

        // Dimensions before content and junctions — no FK makes it
        // necessary, but the insert order stays deterministic.
        try olDrain(w, &store.artists);
        try olDrain(w, &store.albums);
        try olDrain(w, &store.genres);
        try olDrain(w, &store.labels);
        try olDrain(w, &store.keys);
        try olDrain(w, &store.images);
        try olDrain(w, &store.playlists);
        try olDrain(w, &store.contents);
        try olDrainPlaylistPairs(w, &store.playlist_pairs);
        try olDrain(w, &store.my_tags);
        try olDrain(w, &store.my_tag_pairs);

        try w.close();
        store.fresh = false;
    }

    /// Writes every queued ANLZ file — creating its `USBANLZ` folder —
    /// then releases the queue; a failure leaves the not-yet-written
    /// entries queued for the next `save` (the images are fixed bytes,
    /// so a retry rewrites the landed ones identically).
    fn writePendingAnlz(
        e: *DeviceExport,
        dir: std.Io.Dir,
    ) (std.mem.Allocator.Error || std.Io.Dir.CreateDirPathError || AtomicWriteError)!void {
        for (e.pending_anlz.items) |*file| {
            try dir.createDirPath(e.io, std.fs.path.dirname(file.path) orelse ".");
            try e.writeFileAtomic(dir, file.path, file.image);
        }
        for (e.pending_anlz.items) |*file| file.deinit(e.alloc);
        e.pending_anlz.clearRetainingCapacity();
    }

    /// Writes the default directory tree and the four pending setting
    /// images, then releases them; a failure leaves them owned by
    /// `pending_settings`, for `deinit` to reclaim.
    fn writePendingSettings(
        e: *DeviceExport,
        dir: std.Io.Dir,
        pending: [dat_files.len][]u8,
    ) (std.mem.Allocator.Error || std.Io.Dir.CreateDirPathError || AtomicWriteError)!void {
        // Each path is freed before the next is built, so a failure
        // between the creations leaks nothing.
        inline for (.{
            Layout.rekordboxDir,
            Layout.usbanlzDir,
            Layout.contentsDir,
        }) |dir_fn| {
            const dir_path = try dir_fn(e.layout, e.alloc);
            defer e.alloc.free(dir_path);
            try dir.createDirPath(e.io, dir_path);
        }

        inline for (dat_files, 0..) |dat, i| {
            const path = try e.layout.datPath(e.alloc, dat.name);
            defer e.alloc.free(path);
            try e.writeFileAtomic(dir, path, pending[i]);
        }
        for (pending) |bytes| e.alloc.free(bytes);
        e.pending_settings = null;
    }

    /// Writes `bytes` to `path` through a same-directory temp file and an
    /// atomic rename.
    fn writeFileAtomic(
        e: *DeviceExport,
        dir: std.Io.Dir,
        path: []const u8,
        bytes: []const u8,
    ) AtomicWriteError!void {
        var af = try dir.createFileAtomic(e.io, path, .{ .replace = true });
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

/// Frees the grouping map built by `getPlaylistsDb`.
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
/// (parented to a missing id) do not appear; a folder id is expanded at
/// most once, so parent-id cycles in corrupt data cannot recurse
/// forever.
///
/// The caller owns the returned list; free it by deinitializing every
/// element and then the list itself:
///
///     const device = @import("rekordlib").device;
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

// --- OneLibrary mirror (O4) -----------------------------------------------------

/// A playlist membership waiting for `save`, inserted through
/// `Writer.addAllToPlaylist` — the pair carries no `sequenceNo` because
/// the Writer derives it at insert time (dense, 1-based, continuing past
/// rows already on disk).
const OlPlaylistPair = struct {
    playlist_id: i64,
    content_id: i64,
};

/// The writer's OneLibrary side: rows mirrored from the mutating methods,
/// buffered in memory until `save` materializes them — nothing
/// SQLite-shaped happens before `save`, so a discarded handle leaves no
/// `exportLibrary.db` behind. Every value the store allocates comes from
/// its arena and is reclaimed whole by `deinit`.
const OlStore = struct {
    arena: std.heap.ArenaAllocator,
    /// True until this handle's first `save` lands the db: a created
    /// export builds a fresh `exportLibrary.db` on its first save even
    /// with nothing pending (newer exports carry one), overwriting a
    /// leftover file — the same stance as the ext pdb. An opened export
    /// never sets this: it only ever appends, and only when the export
    /// already carries the db.
    fresh: bool = false,

    /// Rows pending their first insert, in mirroring order.
    artists: std.ArrayListUnmanaged(dlp.Artist) = .empty,
    albums: std.ArrayListUnmanaged(dlp.Album) = .empty,
    genres: std.ArrayListUnmanaged(dlp.Genre) = .empty,
    labels: std.ArrayListUnmanaged(dlp.Label) = .empty,
    keys: std.ArrayListUnmanaged(dlp.Key) = .empty,
    images: std.ArrayListUnmanaged(dlp.Image) = .empty,
    contents: std.ArrayListUnmanaged(dlp.Content) = .empty,
    playlists: std.ArrayListUnmanaged(dlp.Playlist) = .empty,
    playlist_pairs: std.ArrayListUnmanaged(OlPlaylistPair) = .empty,
    my_tags: std.ArrayListUnmanaged(dlp.MyTag) = .empty,
    /// Pending `myTag_content` rows — the row type itself, since the
    /// junction carries nothing the insert derives.
    my_tag_pairs: std.ArrayListUnmanaged(dlp.MyTagContent) = .empty,

    /// Dedup state over the existing db (filled by `scanOlStore`) and the
    /// pending rows; values are OL ids. Name lookups make a reopened db
    /// resolve to its own ids — in lockstep dbs those are exactly the
    /// bridged pdb ids.
    artists_by_name: std.StringHashMapUnmanaged(i64) = .empty,
    albums_by_artist_and_name: OlAlbumsByArtistAndName = .empty,
    genres_by_name: std.StringHashMapUnmanaged(i64) = .empty,
    labels_by_name: std.StringHashMapUnmanaged(i64) = .empty,
    /// Key names indexed under their canonical form, like the pdb side.
    keys_by_canonical: std.StringHashMapUnmanaged(i64) = .empty,
    /// Bridged artwork ids whose `image` row exists or pends.
    image_ids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Bridged pdb node ids whose `playlist` row exists or pends.
    playlist_ids: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Parent id → next per-child `sequenceNo` (dense from 0, max + 1
    /// over existing rows) — the sibling ordinal, like the ext tag
    /// positions.
    playlist_child_counts: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    /// Bridged ext tag ids whose `myTag` row exists or pends.
    my_tag_ids: std.AutoHashMapUnmanaged(i64, void) = .empty,

    /// Next id for a minted artist row — the lyricist resolution, the
    /// one mirrored row with no pdb id to bridge. Seeded at
    /// `first_minted_artist_id` and raised past every artist id an
    /// existing db carries.
    next_minted_artist_id: i64 = first_minted_artist_id,

    fn hasPending(store: *const OlStore) bool {
        return store.artists.items.len > 0 or
            store.albums.items.len > 0 or
            store.genres.items.len > 0 or
            store.labels.items.len > 0 or
            store.keys.items.len > 0 or
            store.images.items.len > 0 or
            store.contents.items.len > 0 or
            store.playlists.items.len > 0 or
            store.playlist_pairs.items.len > 0 or
            store.my_tags.items.len > 0 or
            store.my_tag_pairs.items.len > 0;
    }

    fn deinit(store: *OlStore) void {
        store.arena.deinit();
    }
};

/// Drains `list` through one `Writer.insertAll` batch — one prepared
/// statement and one commit for the whole table instead of a
/// prepare/finalize/commit triple per row — clearing it only after the
/// batch commits. A failure rolls the whole batch back and leaves every
/// row pending for the next `save`, so a retry never duplicates a landed
/// one (nothing landed): the pending lists keep naming exactly the rows
/// the db lacks, all-or-nothing per table rather than per row.
fn olDrain(w: dlp.Writer, list: anytype) dlp.SqlError!void {
    try w.insertAll(list.items);
    list.clearRetainingCapacity();
}

/// Drains `list` through one `Writer.addAllToPlaylist` batch: the dense
/// 1-based `sequenceNo`s are derived inside the transaction, continuing
/// past rows already on disk. The same clear-only-after-commit contract
/// as `olDrain`.
fn olDrainPlaylistPairs(w: dlp.Writer, list: anytype) dlp.SqlError!void {
    try w.addAllToPlaylist(list.items);
    list.clearRetainingCapacity();
}

/// The dedup key of a mirrored album, like `AlbumKey` but over the OL id
/// space.
pub const OlAlbumKey = struct {
    artist_id: i64,
    name: []const u8,
};

const OlAlbumKeyContext = struct {
    pub fn hash(_: OlAlbumKeyContext, key: OlAlbumKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key.artist_id));
        h.update(key.name);
        return h.final();
    }

    pub fn eql(_: OlAlbumKeyContext, a: OlAlbumKey, b: OlAlbumKey) bool {
        return a.artist_id == b.artist_id and std.mem.eql(u8, a.name, b.name);
    }
};

/// Mirrored albums keyed by `(owning OL artist, name)`.
pub const OlAlbumsByArtistAndName = std.HashMapUnmanaged(
    OlAlbumKey,
    i64,
    OlAlbumKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// Extends a store's dedup state with an existing db's rows, so mirrored
/// inserts reuse the db's own ids where they collide by name (a db
/// written in lockstep resolves to the bridged pdb id) and never
/// duplicate a row the db already carries. A NULL album artist keys as 0,
/// the pdb-side null convention.
fn scanOlStore(lib: *const dlp.Library, store: *OlStore) std.mem.Allocator.Error!void {
    const a = store.arena.allocator();
    for (lib.artists) |row| {
        if (row.name) |name|
            try putIfAbsent(&store.artists_by_name, a, try a.dupe(u8, name), row.artist_id);
        store.next_minted_artist_id =
            @max(store.next_minted_artist_id, row.artist_id + 1);
    }
    for (lib.albums) |row| {
        if (row.name) |name| try putIfAbsent(
            &store.albums_by_artist_and_name,
            a,
            OlAlbumKey{ .artist_id = row.artist_id orelse 0, .name = try a.dupe(u8, name) },
            row.album_id,
        );
    }
    for (lib.genres) |row| {
        if (row.name) |name|
            try putIfAbsent(&store.genres_by_name, a, try a.dupe(u8, name), row.genre_id);
    }
    for (lib.labels) |row| {
        if (row.name) |name|
            try putIfAbsent(&store.labels_by_name, a, try a.dupe(u8, name), row.label_id);
    }
    for (lib.keys) |row| {
        if (row.name) |name| try putIfAbsent(
            &store.keys_by_canonical,
            a,
            try canonicalKeyName(a, name),
            row.key_id,
        );
    }
    for (lib.images) |row| try store.image_ids.put(a, row.image_id, {});
    for (lib.playlists) |row| {
        try store.playlist_ids.put(a, row.playlist_id, {});
        const gop = try store.playlist_child_counts.getOrPut(a, row.playlist_id_parent orelse 0);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = @max(gop.value_ptr.*, (row.sequenceNo orelse -1) + 1);
    }
    for (lib.my_tags) |row| try store.my_tag_ids.put(a, row.myTag_id, {});
}

/// One mirrored `artist` row; see `olNamedRow`.
fn olArtistRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!dlp.Artist {
    _ = a;
    return .{ .artist_id = id, .name = name, .nameForSearch = null };
}

/// One mirrored `genre` row; see `olNamedRow`.
fn olGenreRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!dlp.Genre {
    _ = a;
    return .{ .genre_id = id, .name = name };
}

/// One mirrored `label` row; see `olNamedRow`.
fn olLabelRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!dlp.Label {
    _ = a;
    return .{ .label_id = id, .name = name };
}

/// Resolves `name` through `map` to a mirrored row: an existing entry
/// (the db's own id) is returned as-is; a miss appends a pending row
/// built by `build_row` under the bridged `pdb_id` — the fixture shows
/// rb keeps the pdb and OL id spaces aligned (artist 1 ↔ artist 1), so a
/// lockstep db never sees a collision. The map key is duped and its
/// capacity reserved before the append, so the bookkeeping after it
/// cannot fail half-applied (the `getOrCreateStringRow` discipline).
/// Empty names resolve to null: no row, no foreign key.
fn olNamedRow(
    store: *OlStore,
    map: *std.StringHashMapUnmanaged(i64),
    list: anytype,
    comptime build_row: anytype,
    pdb_id: i64,
    name: []const u8,
) std.mem.Allocator.Error!?i64 {
    if (name.len == 0) return null;
    if (map.get(name)) |id| return id;

    const a = store.arena.allocator();
    const owned = try a.dupe(u8, name);
    try map.ensureUnusedCapacity(a, 1);
    try list.append(a, try build_row(a, owned, pdb_id));
    map.putAssumeCapacity(owned, pdb_id);
    return pdb_id;
}

/// Minted artist ids start above every possible bridged id: pdb ids are
/// u32 and the bridge copies them verbatim, so ids from 2^32 upward can
/// never collide with a bridged row — a lockstep db stays collision-free
/// by construction. Unpinnable by the fixture (it carries no lyricist
/// artist rows); recorded in `docs/DIVERGENCES.md`.
const first_minted_artist_id: i64 = 0x1_0000_0000;

/// Resolves the lyricist name to a mirrored artist row. Unlike the
/// other artist roles there is no pdb id to bridge — the pdb keeps the
/// lyricist as a plain string — so a new name is minted an id from
/// `first_minted_artist_id` upward; an existing name (bridged or
/// previously minted) resolves to its own id, exactly like the other
/// roles. The `olNamedRow` bookkeeping discipline applies: the map key
/// is duped and capacity reserved before the append.
fn olLyricistId(
    store: *OlStore,
    name: []const u8,
) std.mem.Allocator.Error!?i64 {
    if (name.len == 0) return null;
    if (store.artists_by_name.get(name)) |id| return id;

    const a = store.arena.allocator();
    const owned = try a.dupe(u8, name);
    try store.artists_by_name.ensureUnusedCapacity(a, 1);
    const id = store.next_minted_artist_id;
    try store.artists.append(a, .{ .artist_id = id, .name = owned, .nameForSearch = null });
    store.artists_by_name.putAssumeCapacity(owned, id);
    store.next_minted_artist_id = id + 1;
    return id;
}

/// Resolves `name` — folded through `canonicalKeyName` — to a mirrored
/// `key` row; the stored spelling is the canonical one, exactly like the
/// pdb Key row this mirrors.
fn olKeyId(
    store: *OlStore,
    name: []const u8,
    pdb_id: i64,
) std.mem.Allocator.Error!?i64 {
    if (name.len == 0) return null;
    const a = store.arena.allocator();
    const canonical = try canonicalKeyName(a, name);
    if (store.keys_by_canonical.get(canonical)) |id| return id;

    // A name that folds to nothing (whitespace only) keeps the original.
    const owned = if (canonical.len == 0) try a.dupe(u8, name) else canonical;
    try store.keys_by_canonical.ensureUnusedCapacity(a, 1);
    try store.keys.append(a, .{ .key_id = pdb_id, .name = owned });
    store.keys_by_canonical.putAssumeCapacity(canonical, pdb_id);
    return pdb_id;
}

/// Resolves `(owning artist, name)` to a mirrored `album` row. The pdb
/// side keys albums per-artist; the OL side keys per-OL-artist, which for
/// lockstep dbs is the same thing. A null artist (the pdb null fk 0)
/// mirrors as the fixture does: `artist_id` NULL.
fn olAlbumId(
    store: *OlStore,
    name: []const u8,
    pdb_id: i64,
    ol_artist_id: ?i64,
) std.mem.Allocator.Error!?i64 {
    if (name.len == 0) return null;
    if (store.albums_by_artist_and_name.get(.{
        .artist_id = ol_artist_id orelse 0,
        .name = name,
    })) |id| return id;

    const a = store.arena.allocator();
    const owned = try a.dupe(u8, name);
    try store.albums_by_artist_and_name.ensureUnusedCapacity(a, 1);
    try store.albums.append(a, .{
        .album_id = pdb_id,
        .name = owned,
        .artist_id = ol_artist_id,
        .image_id = null,
        .isComplation = 0,
        .nameForSearch = null,
    });
    store.albums_by_artist_and_name.putAssumeCapacity(.{
        .artist_id = ol_artist_id orelse 0,
        .name = owned,
    }, pdb_id);
    return pdb_id;
}

/// Resolves an artwork row to its mirrored `image` row: the bridge is the
/// artwork id itself, and the stored path is the OneLibrary `b{id}.jpg`
/// variant derived from it — not the caller's `a*` path, which the spec
/// (`artworkSpec`) tells the caller to place alongside. No artwork (id
/// 0) mirrors nothing.
fn olImageId(store: *OlStore, pdb_artwork_id: u32) std.mem.Allocator.Error!?i64 {
    if (pdb_artwork_id == 0) return null;
    const id: i64 = pdb_artwork_id;
    if (store.image_ids.contains(id)) return id;

    const a = store.arena.allocator();
    try store.image_ids.ensureUnusedCapacity(a, 1);
    try store.images.append(a, .{
        .image_id = id,
        .path = try olArtworkPath(a, pdb_artwork_id),
    });
    store.image_ids.putAssumeCapacity(id, {});
    return id;
}

/// Mirrors a playlist-tree node: the OL `playlist` row carries the pdb
/// node's bridged id, `attribute` 1 for a folder and 0 for a playlist
/// (the myTag column convention; the fixture's single leaf carries 0),
/// the parent bridged, and a per-parent dense `sequenceNo` from 0 — the
/// same ordinal shape the myTag columns number by. A bridged id the db
/// already carries is left alone (a diverged db keeps its own row).
fn mirrorPlaylistRow(
    store: *OlStore,
    name: []const u8,
    parent_id: u32,
    id: u32,
    is_folder: bool,
) std.mem.Allocator.Error!void {
    if (store.playlist_ids.contains(id)) return;

    const a = store.arena.allocator();
    const sequence_no = store.playlist_child_counts.get(parent_id) orelse 0;
    try store.playlist_ids.ensureUnusedCapacity(a, 1);
    try store.playlist_child_counts.ensureUnusedCapacity(a, 1);
    try store.playlists.append(a, .{
        .playlist_id = id,
        .sequenceNo = sequence_no,
        .name = try a.dupe(u8, name),
        .image_id = null,
        .attribute = if (is_folder) 1 else 0,
        .playlist_id_parent = parent_id,
    });
    store.playlist_ids.putAssumeCapacity(id, {});
    const gop = store.playlist_child_counts.getOrPutAssumeCapacity(parent_id);
    gop.value_ptr.* = sequence_no + 1;
}

/// Mirrors a my-tag row: the ext tag id bridges — the fixture's ext Tag
/// ids and OL myTag ids are equal (Genre 1-4, Acid House 4275955888 on
/// both sides) — `attribute` 1 for a category and 0 for a leaf mirrors
/// `raw_is_category`, the parent bridges, and `sequenceNo` reuses the
/// ext row's position (dense from 0 within the parent, as the fixture's
/// columns number 0..3 and their leaves 0..n).
fn mirrorMyTagRow(
    store: *OlStore,
    name: []const u8,
    id: u32,
    sequence_no: u32,
    is_category: bool,
    parent_id: u32,
) std.mem.Allocator.Error!void {
    if (store.my_tag_ids.contains(id)) return;

    const a = store.arena.allocator();
    try store.my_tag_ids.ensureUnusedCapacity(a, 1);
    try store.my_tags.append(a, .{
        .myTag_id = id,
        .sequenceNo = sequence_no,
        .name = try a.dupe(u8, name),
        .attribute = if (is_category) 1 else 0,
        .myTag_id_parent = parent_id,
    });
    store.my_tag_ids.putAssumeCapacity(id, {});
}

// --- writer state ---------------------------------------------------------------

/// Fold tokens for `canonicalKeyName`, longest first so `major` folds as
/// one token instead of matching `maj` and leaking the rest.
const key_name_folds = [_]struct { token: []const u8, emit: []const u8 }{
    .{ .token = "major", .emit = "maj" },
    .{ .token = "minor", .emit = "min" },
    .{ .token = "flat", .emit = "b" },
    .{ .token = "sharp", .emit = "#" },
    .{ .token = "maj", .emit = "maj" },
    .{ .token = "min", .emit = "min" },
};

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
        var matched = false;
        for (key_name_folds) |f| {
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
/// an existing row instead of duplicating it. Everything the state
/// allocates — map entries and string keys alike — comes from its arena
/// and is reclaimed whole by `deinit`; a key that duplicates an existing
/// one simply stays in the arena until then. Rebuilt from a plain
/// database by `scanWriterState` and extended over an ext database's tag
/// rows by `scanExtTags`.
pub const WriterState = struct {
    arena: std.heap.ArenaAllocator,
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
    /// Track ids by device file path (non-empty paths only; `addTrack`
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

    pub fn deinit(state: *WriterState) void {
        state.arena.deinit();
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
/// wins. The key must come from the state's arena; a duplicate's copy is
/// simply left there, reclaimed with the state at `deinit`.
fn putIfAbsent(
    map: anytype,
    a: std.mem.Allocator,
    key: anytype,
    value: anytype,
) std.mem.Allocator.Error!void {
    const gop = try map.getOrPut(a, key);
    if (!gop.found_existing) {
        gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }
}

/// Builds an Artist row in `a` — the caller's id, the name encoded.
/// Nothing is inserted; see `getOrCreateStringRow`.
fn buildArtistRow(
    a: std.mem.Allocator,
    id: u32,
    name: []const u8,
) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row {
    const boxed = try a.create(pdb.Artist);
    boxed.* = .{ .id = id, .offsets = .{ .inner = .{
        .name = try pdb.DeviceSQLString.fromUtf8(a, name),
    } } };
    return .{ .artist = boxed };
}

/// Builds a Genre row in `a`; see `buildArtistRow`.
fn buildGenreRow(
    a: std.mem.Allocator,
    id: u32,
    name: []const u8,
) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row {
    const boxed = try a.create(pdb.Genre);
    boxed.* = .{ .id = id, .name = try pdb.DeviceSQLString.fromUtf8(a, name) };
    return .{ .genre = boxed };
}

/// Builds a Label row in `a`; see `buildArtistRow`.
fn buildLabelRow(
    a: std.mem.Allocator,
    id: u32,
    name: []const u8,
) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row {
    const boxed = try a.create(pdb.Label);
    boxed.* = .{ .id = id, .name = try pdb.DeviceSQLString.fromUtf8(a, name) };
    return .{ .label = boxed };
}

/// Builds an Artwork row in `a`; see `buildArtistRow`.
fn buildArtworkRow(
    a: std.mem.Allocator,
    id: u32,
    path: []const u8,
) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row {
    const boxed = try a.create(pdb.Artwork);
    boxed.* = .{ .id = id, .path = try pdb.DeviceSQLString.fromUtf8(a, path) };
    return .{ .artwork = boxed };
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
/// nothing is inserted and no counter is consumed. Constants observed
/// on real Rekordbox exports, copy exactly: `subtype` `0x0680`,
/// `raw_is_category` `1 << 24` for a category and `0` for a leaf,
/// `index_shift` `row_index * 0x20`, truncated to the field's u16. Leaf
/// ids are sequential here, not the large random 32-bit values Rekordbox
/// writes — unknown whether players care; revisit if round-trip
/// fidelity is needed.
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

/// Walks every row of `db`'s `page_type` table in row order, handing
/// each to `visit(ctx, row)`; a table the database doesn't carry walks
/// nothing (see `rowsOrEmpty`).
fn forEachRow(
    db: *const pdb.Database,
    page_type: pdb.PageType,
    ctx: anytype,
    comptime visit: anytype,
) ScanError!void {
    var it = (try rowsOrEmpty(db, page_type)) orelse return;
    while (try it.next()) |row| try visit(ctx, row);
}

/// Scans `tracks`: every id into `track_ids` (playlist-membership FK
/// checks), every non-empty file path into `tracks_by_path`, and the
/// id counter past the highest track id.
fn scanTracks(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    try forEachRow(db, .tracks, .{ .alloc = alloc, .state = state }, visitTrack);
}

fn visitTrack(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const track = row.track;
    try ctx.state.track_ids.put(ctx.alloc, track.id, {});
    ctx.state.next_track_id = @max(ctx.state.next_track_id, track.id +| 1);
    if (try decodeOrSkip(track.offsets.inner.file_path, ctx.alloc)) |path| {
        if (path.len > 0)
            try putIfAbsent(&ctx.state.tracks_by_path, ctx.alloc, path, track.id);
    }
}

/// Scans a table whose rows are deduplicated by one string field (artists,
/// genres, labels, artwork): the id counter past the highest row id, and
/// every row's id into `map` under its decoded key — an invalid encoding
/// skips the map entry but still advances the counter. `tag` selects the
/// `Row` variant; `field_path` names the `DeviceSQLString` within the row
/// payload, through nested structs (`.{"name"}`,
/// `.{ "offsets", "inner", "name" }`).
fn scanStringKeyed(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    page_type: pdb.PageType,
    comptime tag: []const u8,
    comptime field_path: []const []const u8,
    map: *std.StringHashMapUnmanaged(u32),
    counter: *u32,
) ScanError!void {
    var it = (try rowsOrEmpty(db, page_type)) orelse return;
    while (try it.next()) |row| {
        const payload = @field(row.*, tag);
        counter.* = @max(counter.*, payload.id +| 1);
        if (try decodeOrSkip(stringField(payload, field_path), alloc)) |key| {
            try putIfAbsent(map, alloc, key, payload.id);
        }
    }
}

/// The `DeviceSQLString` at `field_path` within `row`, through nested
/// structs (see `scanStringKeyed`).
fn stringField(value: anytype, comptime field_path: []const []const u8) pdb.DeviceSQLString {
    if (field_path.len == 1) return @field(value, field_path[0]);
    return stringField(@field(value, field_path[0]), field_path[1..]);
}

/// Scans `albums`: `(owning artist, name)` pairs into
/// `albums_by_artist_and_name`, the id counter past the highest album
/// id.
fn scanAlbums(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    try forEachRow(db, .albums, .{ .alloc = alloc, .state = state }, visitAlbum);
}

fn visitAlbum(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const album = row.album;
    ctx.state.next_album_id = @max(ctx.state.next_album_id, album.id +| 1);
    if (try decodeOrSkip(album.offsets.inner.name, ctx.alloc)) |name| {
        try putIfAbsent(
            &ctx.state.albums_by_artist_and_name,
            ctx.alloc,
            AlbumKey{ .artist_id = album.artist_id, .name = name },
            album.id,
        );
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
    try forEachRow(db, .keys, .{ .alloc = alloc, .state = state }, visitKey);
}

fn visitKey(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const key = row.key;
    ctx.state.next_key_id = @max(ctx.state.next_key_id, key.id +| 1);
    if (try decodeOrSkip(key.name, ctx.alloc)) |name| {
        const canonical = try canonicalKeyName(ctx.alloc, name);
        try putIfAbsent(&ctx.state.keys_by_canonical, ctx.alloc, canonical, key.id);
    }
}

/// Scans `playlist_tree`: `id -> is_folder` into `playlist_nodes` and
/// the id counter past the highest node id.
fn scanPlaylistTree(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    try forEachRow(db, .playlist_tree, .{ .alloc = alloc, .state = state }, visitPlaylistTreeNode);
}

fn visitPlaylistTreeNode(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const node = row.playlist_tree_node;
    ctx.state.next_playlist_node_id = @max(ctx.state.next_playlist_node_id, node.id +| 1);
    try ctx.state.playlist_nodes.put(ctx.alloc, node.id, node.isFolder());
}

/// Scans `playlist_entries`: per-playlist `entry_index` high-water
/// marks into `playlist_entry_counts`.
fn scanPlaylistEntries(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
    state: *WriterState,
) ScanError!void {
    try forEachRow(db, .playlist_entries, .{ .alloc = alloc, .state = state }, visitPlaylistEntry);
}

fn visitPlaylistEntry(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const entry = row.playlist_entry;
    const gop = try ctx.state.playlist_entry_counts.getOrPut(ctx.alloc, entry.playlist_id);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* = @max(gop.value_ptr.*, entry.entry_index +| 1);
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
    var state = WriterState{ .arena = std.heap.ArenaAllocator.init(alloc) };
    errdefer state.deinit();

    const a = state.arena.allocator();
    try scanTracks(a, db, &state);
    try scanStringKeyed(a, db, .artists, "artist", &.{ "offsets", "inner", "name" }, &state.artists_by_name, &state.next_artist_id);
    try scanAlbums(a, db, &state);
    try scanStringKeyed(a, db, .genres, "genre", &.{"name"}, &state.genres_by_name, &state.next_genre_id);
    try scanKeys(a, db, &state);
    try scanStringKeyed(a, db, .labels, "label", &.{"name"}, &state.labels_by_name, &state.next_label_id);
    try scanStringKeyed(a, db, .artwork, "artwork", &.{"path"}, &state.artwork_by_path, &state.next_artwork_id);
    try scanPlaylistTree(a, db, &state);
    try scanPlaylistEntries(a, db, &state);

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
    const page_type: pdb.PageType = @enumFromInt(@intFromEnum(pdb.ExtPageType.tag));
    try forEachRow(ext_db, page_type, .{ .alloc = alloc, .state = state }, visitTag);
}

fn visitTag(ctx: anytype, row: *const pdb.Row) ScanError!void {
    const tag = row.tag;
    ctx.state.next_tag_id = @max(ctx.state.next_tag_id, tag.id +| 1);
    ctx.state.next_tag_row_index = @max(
        ctx.state.next_tag_row_index,
        @as(u32, tag.index_shift) / 0x20 +| 1,
    );
    if (tag.raw_is_category != 0) {
        try ctx.state.tag_categories.put(ctx.alloc, tag.id, {});
        ctx.state.next_category_position = @max(ctx.state.next_category_position, tag.position +| 1);
    } else {
        if (try decodeOrSkip(tag.offsets.inner.name, ctx.alloc)) |label| {
            try putIfAbsent(
                &ctx.state.tags_by_key,
                ctx.alloc,
                TagKey{ .category_id = tag.parent_id, .label = label },
                tag.id,
            );
        }
        const gop = try ctx.state.tag_leaf_counts.getOrPut(ctx.alloc, tag.parent_id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* = @max(gop.value_ptr.*, tag.position +| 1);
    }
}
