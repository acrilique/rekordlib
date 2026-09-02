// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! On-disk layout of a Rekordbox device export: where `export.pdb`,
//! `exportExt.pdb`, the `*SETTING.DAT` files and the `PIONEER`/`USBANLZ`/
//! `Contents` directories live relative to the device root, plus the
//! handle that opens an export's settings and database through that
//! layout, and builds fresh ones.
//!
//! Initially ported from rekordcrate's `src/device/layout.rs` and
//! `src/device/reader.rs`/`writer.rs`.

const std = @import("std");
const bin = @import("bin.zig");
const anlz = @import("anlz.zig");
const ol = @import("ol.zig");
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

/// Error of loading the export's `export.pdb`: opening the pinned working
/// directory, reading it off disk, or parsing it.
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

/// Error of the temp-file-then-rename write `writeFileAtomic` (and every
/// file `save` lands) performs.
pub const AtomicWriteError =
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.Dir.RenameError;

/// Writes `bytes` to `dir`'s `path` through a temp file plus a rename, so
/// a crash mid-write can never leave a torn file behind — the same write
/// every `DeviceExport.save` lands through. The write half of the manual
/// pdb path: `pdb.Database.parse` the image, edit the rows, `serialize`,
/// then land the result with this.
pub fn writeFileAtomic(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    bytes: []const u8,
) AtomicWriteError!void {
    var af = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// Error of `DeviceExport.save`.
pub const SaveError =
    OpenPdbError ||
    pdb.DatabaseEncodeError ||
    pdb.ValidateAllTrackRowsError ||
    std.Io.Dir.CreateDirPathError ||
    AtomicWriteError ||
    std.Io.Dir.DeleteFileError ||
    RelocateError ||
    ol.Writer.CreateError ||
    ol.SqlError ||
    error{CwdUnavailable};

/// Error of `DeviceExport.writerState`: reading or parsing
/// `export.pdb`, or scanning it.
pub const WriterStateError = OpenPdbError || ScanError;

/// Error of `DeviceExport.openOL`: pinning the working directory,
/// examining or opening `exportLibrary.db` (a file over the read cap is
/// `LibraryTooLarge`), loading its models (a drifted schema is
/// `SchemaMismatch`, a disproportionate decode also `LibraryTooLarge`),
/// or building its path (the process cwd was unreadable when the handle
/// pinned it).
pub const OpenOLError =
    std.Io.Dir.OpenError ||
    std.Io.Dir.StatFileError ||
    ol.LoadError ||
    error{ CwdUnavailable, OutOfMemory };

/// Error of the OL mirroring helpers: pinning the working directory,
/// examining or loading the existing `exportLibrary.db` (a drifted schema
/// is `SchemaMismatch`), building its path or a device ANLZ path,
/// allocating, or an OL-side id that exhausts its space.
pub const OlMirrorError =
    std.Io.Dir.OpenError ||
    std.Io.Dir.AccessError ||
    OpenOLError ||
    ol.LoadError ||
    std.mem.Allocator.Error ||
    error{ CwdUnavailable, InvalidUtf8, IdSpaceExhausted };

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
/// needing fields not exposed here should parse `export.pdb` with
/// `pdb.Database.parse`, edit the rows, and write the image back
/// atomically with `writeFileAtomic`.
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
    /// Whether Rekordbox publishes track information; maps to the pdb
    /// string `"ON"` / empty. On, the fresh-export convention.
    publish_track_information: bool = true,
    /// Date the analysis was performed. Free text, commonly `YYYY-MM-DD`
    /// (see `release_date`); empty = none.
    analyze_date: []const u8 = "",
    /// Pre-computed ANLZ content. Borrowed for the call only: the files
    /// are serialized right away, so the input may be freed once
    /// `addTrack` returns. When set, the writer queues the `ANLZ0000`
    /// files for `save` (each sibling only when its section set carries
    /// data) and stores the device `.DAT` path in `analyze_path`. Beats
    /// and cues are always caller-provided — the library does not do
    /// beat detection; see `anlz.buildAnlzInput` for assembling one from
    /// performance data and waveform columns.
    analysis: ?*const anlz.AnlzInput = null,

    // OneLibrary-only data: columns that exist in `exportLibrary.db`
    // and never reach the pdb. Ignored when the export carries no OL db
    // (an opened pdb-only export never gains one), in `-Dol=off`
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

/// Error of the unified track reads (`tracks`, `trackByPath`): opening or
/// parsing the export's databases, scanning them, or the OL join's read
/// of `exportLibrary.db`.
pub const TrackViewError = OpenPdbError || ScanError || OpenOLError;

/// Whether a track view found a OneLibrary counterpart. The pdb row is
/// the spine either way; `pdb_only` means the export carries no OL db,
/// or none of its `content` rows join by path.
pub const TrackSource = enum {
    pdb_only,
    pdb_and_ol,
};

/// A track as a user thinks of it: one pdb Track row — its foreign keys
/// resolved to names — overlaid with the OL `content` row joined by file
/// path, when the export carries one. The field vocabulary is
/// `TrackInput`'s read-side mirror, so what `addTrack` writes is what a
/// view shows. Fields only the OL side carries are empty/null under
/// `pdb_only`.
///
/// A view's strings are borrowed: from an iterator, until its next
/// `next` call (dupe what must survive); from `trackByPath`, until the
/// record's `deinit`.
pub const TrackView = struct {
    /// The pdb track id — the export's stable identity for the track.
    id: u32,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    genre: []const u8,
    /// Musical key, in the spelling the Key row stores.
    key: []const u8,
    label: []const u8,
    composer: []const u8,
    remixer: []const u8,
    orig_artist: []const u8,
    lyricist: []const u8,
    comment: []const u8,
    isrc: []const u8,
    mix_name: []const u8,
    release_date: []const u8,
    date_added: []const u8,
    message: []const u8,
    /// Device-relative file path (`/Contents/...`); empty when the row
    /// carries none.
    file_path: []const u8,
    filename: []const u8,
    /// Device path the Artwork row names; empty = none.
    artwork_device_path: []const u8,
    /// Tempo in BPM, decoded from the pdb's centi-BPM.
    tempo_bpm: f32,
    bitrate: u32,
    sample_rate: u32,
    sample_depth: u16,
    duration_secs: u16,
    file_size: u32,
    track_number: u32,
    disc_number: u16,
    year: u16,
    play_count: u16,
    /// Star rating, 0-5, the pdb byte.
    rating: u8,
    color: util.ColorIndex,
    file_type: pdb.FileType,
    /// Whether stored hotcues auto-load on a CDJ (the pdb `"ON"` string).
    autoload_hotcues: bool,
    /// Whether Rekordbox publishes track information (the pdb `"ON"`
    /// string).
    publish_track_information: bool,
    /// Date the track analysis was performed, empty when the row carries
    /// none.
    analyze_date: []const u8,
    /// Whether the row names an analysis file (`analyze_path` set).
    has_analysis: bool,
    source: TrackSource,

    // OL-only fields; empty/null under `pdb_only`.

    subtitle: []const u8 = "",
    title_for_search: ?[]const u8 = null,
    kuvo_delivery_on: bool = false,
    kuvo_delivery_comment: []const u8 = "",
    date_created: ?[]const u8 = null,
    cue_update_count: ?i64 = null,
    analysis_data_update_count: ?i64 = null,
    information_update_count: ?i64 = null,
};

/// Field patches for `updateTrack`: `null` leaves the field exactly as
/// it is, a value replaces it. An empty string is a value — patching
/// `artist = ""` clears the foreign key, like `addTrack` with no artist.
/// A non-null `file_path` renames the track — `updateTrack` carries the
/// analysis relocation the move implies (see its doc).
pub const TrackPatch = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    key: ?[]const u8 = null,
    label: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    remixer: ?[]const u8 = null,
    orig_artist: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    isrc: ?[]const u8 = null,
    lyricist: ?[]const u8 = null,
    mix_name: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    date_added: ?[]const u8 = null,
    message: ?[]const u8 = null,
    /// Device-absolute file path (`/Contents/...`) to rename to. The
    /// row's `filename` follows (the new basename), so it has no patch
    /// field of its own.
    file_path: ?[]const u8 = null,
    artwork_device_path: ?[]const u8 = null,
    tempo: ?f32 = null,
    bitrate: ?u32 = null,
    sample_rate: ?u32 = null,
    sample_depth: ?u16 = null,
    duration_secs: ?u16 = null,
    file_size: ?u32 = null,
    track_number: ?u32 = null,
    disc_number: ?u16 = null,
    year: ?u16 = null,
    play_count: ?u16 = null,
    rating: ?u8 = null,
    color: ?util.ColorIndex = null,
    file_type: ?pdb.FileType = null,
    autoload_hotcues: ?bool = null,
    publish_track_information: ?bool = null,
    analyze_date: ?[]const u8 = null,

    // OL-only columns, applied when the track joined an OL row. These
    // patch a value; setting a nullable one back to NULL is not
    // expressible (the fresh-export shape writes NULL, an update has no
    // need to).

    subtitle: ?[]const u8 = null,
    title_for_search: ?[]const u8 = null,
    kuvo_delivery_on: ?bool = null,
    kuvo_delivery_comment: ?[]const u8 = null,
    date_created: ?[]const u8 = null,
    cue_update_count: ?i64 = null,
    analysis_data_update_count: ?i64 = null,
    information_update_count: ?i64 = null,
};

/// Error of `updateTrack`: the writer state, the row replace, the
/// dimension resolution, the OL mirror, or — when the patch renames —
/// the path checks and the collision probe; `UnknownTrack` names an id
/// no Track row carries.
pub const UpdateTrackError =
    WriterStateError ||
    OlMirrorError ||
    PathError ||
    anlz.ParseError ||
    anlz.WriteError ||
    pdb.DatabaseModifyError ||
    pdb.Database.RemoveRowError ||
    std.Io.Dir.AccessError ||
    error{
        UnknownTrack,
        TooLong,
        InvalidEncoding,
        DuplicatePath,
        InvalidPath,
        AnalysisPathCollision,
    };

/// Options of `removeTrack`.
pub const RemoveTrackOptions = struct {
    /// Delete the track's analysis directory (`PIONEER/USBANLZ/...`) at
    /// the next save — after `export.pdb`, best effort. Off by default:
    /// the directory is kept when another track's path hashes onto it
    /// (a collision would lose the survivor's analysis).
    delete_analysis_files: bool = false,
};

/// Error of `removeTrack`: the writer state, the row removals, or the OL
/// cascade; `UnknownTrack` names an id no Track row carries.
pub const RemoveTrackError =
    WriterStateError ||
    OlMirrorError ||
    pdb.DatabaseModifyError ||
    pdb.Database.RemoveRowError ||
    PathError ||
    error{UnknownTrack};

/// Error of the ANLZ relocation pass of `save`.
pub const RelocateError =
    std.Io.Dir.ReadFileAllocError ||
    std.Io.Dir.CreateDirPathError ||
    AtomicWriteError ||
    anlz.ParseError ||
    anlz.WriteError ||
    PathError;

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

/// One queued ANLZ relocation, keyed by track id: at the next `save`,
/// every sibling found under `from_dir` is re-serialized — its PPTH path
/// section naming `device_path` — and written into `to_dir`; after
/// `export.pdb` lands, `from_dir` goes away best-effort. `from_dir ==
/// to_dir` (the two paths hash onto one directory) means only the PPTH
/// rewrite, in place.
const AnlzRelocation = struct {
    from_dir: []u8,
    to_dir: []u8,
    device_path: []u8,

    fn deinit(rel: *AnlzRelocation, alloc: std.mem.Allocator) void {
        alloc.free(rel.from_dir);
        alloc.free(rel.to_dir);
        alloc.free(rel.device_path);
    }
};

/// Reads the process working directory through libc. Only called in
/// `-Dol` builds (which link libc) to snapshot the cwd a SQLite path can
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
/// at an existing export, `create` builds a fresh one in memory. `save`
/// is the only call that writes; `deinit` discards whatever was never
/// saved. Files the export
/// carries but the handle does not model are ignored by design:
/// `djprofile.nxs` (undocumented). The OneLibrary db
/// (`exportLibrary.db`, newer exports) is read through `openOL`
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
    /// cwd, not the pinned handle). Null in `-Dol=off` builds (nothing
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
    /// The OneLibrary db read side (`openOL`), independent of the
    /// writer side.
    ol_library: OlLibraryState = .unloaded,
    /// The OneLibrary db write side: rows mirrored by the mutating
    /// methods, buffered until `save` materializes them.
    ol_state: OlState = .unloaded,
    /// ANLZ relocations queued by `updateTrack`'s rename, keyed by track id and
    /// landed by the next `save` (see `AnlzRelocation`).
    relocations: std.AutoHashMapUnmanaged(u32, AnlzRelocation) = .empty,
    /// Analysis directories queued by `removeTrack` for deletion at the
    /// next save, after `export.pdb` lands (best effort).
    pending_dir_deletes: std.ArrayListUnmanaged([]u8) = .empty,

    const PdbState = union(enum) {
        /// An export opened at `root`; the pdb parses on first touch.
        unloaded,
        /// In memory — parsed from disk or built by `create`.
        loaded: pdb.Database,
    };

    /// Lifecycle of the `exportLibrary.db` models, loaded on first
    /// `openOL` call and cached until the next `save` — which drops it,
    /// the snapshot naming the pre-save disk — or `deinit`.
    const OlLibraryState = union(enum) {
        /// Not examined yet; the first call checks the disk.
        unloaded,
        /// No `exportLibrary.db` under the root (older exports).
        absent,
        /// Loaded and cached; owned by the handle.
        loaded: ol.Library,
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
    /// reused. `-Dol` builds also snapshot the cwd string: SQLite, which
    /// the OneLibrary store goes through, resolves paths against the
    /// process cwd rather than a directory handle.
    fn dirHandle(e: *DeviceExport) (std.Io.Dir.OpenError || std.mem.Allocator.Error)!std.Io.Dir {
        if (e.dir == null) {
            e.dir = try std.Io.Dir.cwd().openDir(e.io, ".", .{});
            if (ol.mode != .off) {
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
        const dir_path: ?[]u8 = if (ol.mode != .off)
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
        var rel = e.relocations.iterator();
        while (rel.next()) |entry| entry.value_ptr.deinit(e.alloc);
        e.relocations.deinit(e.alloc);
        for (e.pending_dir_deletes.items) |dir| e.alloc.free(dir);
        e.pending_dir_deletes.deinit(e.alloc);
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

    /// The export's database, parsing it off disk on first call. Private:
    /// handing the handle-owned `Database` out would let edits bypass the
    /// writer's id counters and dedup maps (silently colliding ids on the
    /// next mutating call). Fields the typed methods don't expose belong
    /// on the manual path: parse, edit, `writeFileAtomic`.
    fn openPdb(e: *DeviceExport) OpenPdbError!*pdb.Database {
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
    ) (OpenPdbError || PlaylistTreeError)!PlaylistTree {
        return getPlaylistsDb(e.alloc, try e.openPdb());
    }

    /// Iterates the export's tracks as `TrackView`s — one per pdb Track
    /// row, foreign keys resolved to names, the OL counterpart joined by
    /// file path when the export carries one. A view's strings live
    /// until the iterator's next `next` call; dupe what must outlive it.
    /// Mutating the export invalidates the iterator — finish iterating
    /// first.
    pub fn tracks(e: *DeviceExport) TrackViewError!TrackIter {
        const db = try e.openPdb();
        var dim_arena = std.heap.ArenaAllocator.init(e.alloc);
        errdefer dim_arena.deinit();
        const dims = try TrackDimensions.build(e, dim_arena.allocator());
        return .{
            .e = e,
            .dim_arena = dim_arena,
            .view_arena = std.heap.ArenaAllocator.init(e.alloc),
            .dims = dims,
            .it = try db.rows(.tracks),
        };
    }

    /// The track ids of `playlist_id`'s entries, ordered by `entry_index`
    /// — the order the player shows them in. A folder, or an id the
    /// export does not carry, yields an empty slice. The caller owns the
    /// slice.
    pub fn getPlaylistTrackIds(
        e: *DeviceExport,
        alloc: std.mem.Allocator,
        playlist_id: u32,
    ) WriterStateError![]u32 {
        const db = try e.openPdb();
        const Entry = struct { index: u32, track_id: u32 };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(alloc);
        var it = (try rowsOrEmpty(db, .playlist_entries)) orelse return &.{};
        while (try it.next()) |row| switch (row.*) {
            .playlist_entry => |entry| {
                if (entry.playlist_id == playlist_id)
                    try entries.append(alloc, .{
                        .index = entry.entry_index,
                        .track_id = entry.track_id,
                    });
            },
            else => {},
        };
        std.mem.sort(Entry, entries.items, {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.index < b.index;
            }
        }.before);
        const ids = try alloc.alloc(u32, entries.items.len);
        for (entries.items, ids) |entry, *id| id.* = entry.track_id;
        return ids;
    }

    /// The track view for `path` (device-root-absolute, e.g.
    /// `/Contents/Artist - Title.mp3`), or null when no track carries
    /// it. Unlike an iterator's view, the record owns its strings — call
    /// `deinit` when done.
    pub fn trackByPath(e: *DeviceExport, path: []const u8) TrackViewError!?TrackRecord {
        const db = try e.openPdb();
        const arena = try e.alloc.create(std.heap.ArenaAllocator);
        errdefer e.alloc.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(e.alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const dims = try TrackDimensions.build(e, a);
        var it = try db.rows(.tracks);
        while (try it.next()) |row| {
            const file_path = try decodeOrEmpty(row.track.offsets.inner.file_path, a);
            if (std.mem.eql(u8, file_path, path))
                return .{ .arena = arena, .view = try fillTrackView(e, &dims, a, row.track) };
        }
        arena.deinit();
        e.alloc.destroy(arena);
        return null;
    }

    /// The export's OneLibrary db (`exportLibrary.db`, carried by newer
    /// exports), loaded on first call and cached; null when the export
    /// carries none. `save` drops the cache — it names the pre-save disk —
    /// so the returned pointer is valid until the next `save` or `deinit`,
    /// and a later call reloads from disk. The join to the pdb side is by
    /// path:
    /// `content.path` values are the device-root-absolute file paths the
    /// pdb Track rows store, so `lib.contentByPath(file_path)` hands back
    /// the OL view of a track — including the fields the pdb lacks
    /// (remixer/composer/lyricist/original-artist ids, subtitle, bit
    /// depth, sampling rate, djPlayCount). Only compiled with
    /// `-Dol=vendored-sqlcipher` (or `=system-sqlcipher`).
    pub fn openOL(e: *DeviceExport) OpenOLError!?*const ol.Library {
        if (ol.mode == .off)
            @compileError("rekordlib was built with -Dol=off; rebuild with -Dol=vendored-sqlcipher (or =system-sqlcipher) to read the OneLibrary store");
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
                var db = try ol.Db.open(e.io, path);
                errdefer db.close();
                // Same tag-then-payload hazard as `openPdb`: load first.
                const lib = try ol.Library.load(e.alloc, db);
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
    /// always, in `-Dol=off` builds, where mirroring is compiled out.
    fn olStore(e: *DeviceExport) OlMirrorError!?*OlStore {
        if (ol.mode == .off) return null;
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
                var db = try ol.Db.open(e.io, path);
                errdefer db.close();
                var lib = try ol.Library.load(e.alloc, db);
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
    /// (and in `-Dol=off` builds).
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
        // Adds bridge by construction: the content row carries the pdb
        // track's id (the fixture's lockstep convention).
        try store.content_bridge.put(a, row.id, row.id);
    }

    /// A read-only view of the writer's cached scan of the export —
    /// id counters and dedup maps, for introspection. The view stays
    /// valid for the handle's life; its contents move as the handle
    /// mutates. Mutation deliberately stays with the handle: edits
    /// through a mutable pointer would desync the counters and maps
    /// from the database (colliding ids, broken dedup) with no check
    /// at `save`.
    pub fn writerState(e: *DeviceExport) WriterStateError!*const WriterState {
        return try e.writerStateMut();
    }

    /// The writer's cached scan of the export, built on first use
    /// (loading the pdb first if needed). The mutating methods call
    /// this before they touch the database, so read-only sessions
    /// never pay for it.
    fn writerStateMut(e: *DeviceExport) WriterStateError!*WriterState {
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
        const state = try e.writerStateMut();
        if (track.file_path.len > 0) {
            if (state.tracks_by_path.get(track.file_path)) |id|
                return .{ .id = id, .is_new = false };
        }
        try e.primeOlStore();

        // The caller's data fails here or never: nothing below this point
        // is rolled back.
        var anlz_files = try e.buildAnlzFiles(track);
        errdefer for (&anlz_files) |*slot| {
            if (slot.*) |*file| file.deinit(e.alloc);
        };
        const row = try e.buildTrackRow(track, track.analysis != null);
        const track_id = try state.next_track_id.mint();

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

        state.track_ids.putAssumeCapacity(track_id, {});
        if (owned_path) |path| state.tracks_by_path.putAssumeCapacity(path, track_id);
        for (anlz_files) |slot| if (slot) |file|
            e.pending_anlz.appendAssumeCapacity(file);

        try e.mirrorAddedTrack(track, row);

        return .{ .id = track_id, .is_new = true };
    }

    /// Updates track `id` with the non-null fields of `patch`; null
    /// fields are left exactly as they are — including the row's unknown
    /// constants (`bitmask`, `unknown5`, …), which a patch never touches,
    /// unlike a fresh `addTrack` row. Dimension fields resolve like
    /// `addTrack`'s: a new artist/album/genre/key/label/artwork name
    /// creates its row under a fresh id, and the old dimension row stays
    /// behind (unreferenced, ignored by players). An empty string is a
    /// value — `artist = ""` clears the foreign key.
    ///
    /// A non-null `file_path` renames the track to it — the
    /// device-absolute `/Contents/...` form; a path the row already
    /// carries is a no-op on the path side (the other fields still
    /// patch). The rename moves everything derived from the path (see
    /// `pathHash`): the pdb row's `file_path`, `filename` (the new
    /// basename), and `analyze_path`; the OL row's `path`, `fileName`,
    /// and `analysisDataFilePath`; and the analysis files themselves,
    /// relocated at the next `save` into the directory players compute
    /// from the new path, each sibling's PPTH section rewritten —
    /// players recompute the location from the path hash and ignore
    /// `analyze_path`, so relocation is not optional. Placing the audio
    /// file at the new location is the caller's; the library never
    /// touches `Contents`. The old analysis directory outlives the
    /// relocation until the new `export.pdb` has landed, then goes away
    /// best-effort: a crash mid-save leaves the old index naming a
    /// directory still populated. Renaming onto another track's path is
    /// a `DuplicatePath`, a path without the leading device-root slash
    /// an `InvalidPath`, and a target directory another track's analysis
    /// already occupies an `AnalysisPathCollision` — two paths sharing
    /// one directory is real, per the modulo in `pathHash`, and the
    /// caller must pick another path: clobbering would destroy the
    /// other track's analysis.
    ///
    /// When the export carries a OneLibrary db and the track joined a
    /// `content` row, the mirrored columns move with the patch and the
    /// OL-only fields (`subtitle`, the KUVO pair, the update counts)
    /// patch the OL row directly. A track with no OL row is patched on
    /// the pdb side only.
    ///
    /// Ordering follows `addTrack`'s discipline: caller data that can
    /// fail (string encoding) fails before anything is mutated. The
    /// dimension inserts come before the track row lands, so a failure
    /// between them can orphan dimension rows — the same residual risk,
    /// unrecovered and harmless to players. The replace itself inserts
    /// the new row before removing the old, so a failure cannot lose
    /// the track.
    pub fn updateTrack(e: *DeviceExport, id: u32, patch: TrackPatch) UpdateTrackError!void {
        // The path coordinate is device-absolute.
        if (patch.file_path) |p| {
            if (p.len == 0 or p[0] != '/')
                return error.InvalidPath;
            _ = std.unicode.Utf8View.init(p) catch return error.InvalidPath;
        }

        const state = try e.writerStateMut();
        try e.primeOlStore();
        const old = (try e.findTrackRow(id)) orelse return error.UnknownTrack;
        const old_path = try decodedFilePath(e, old);
        defer if (old_path) |p| e.alloc.free(p);
        const db = try e.openPdb();
        const a = db.arena.allocator();

        // A rename: a new path that differs from the one the row
        // carries. Its checks run while the old path still names the
        // row, before anything is mutated.
        const rename: ?[]const u8 = blk: {
            const np = patch.file_path orelse break :blk null;
            if (old_path) |p| {
                if (std.mem.eql(u8, p, np)) break :blk null;
            }
            break :blk np;
        };
        if (rename) |np| {
            if (state.tracks_by_path.get(np)) |other| {
                if (other != id) return error.DuplicatePath;
            }
        }

        // Where the analysis lives now and where the new path puts it.
        // An undecodable old path has no locatable analysis: the row
        // still renames, the files are left where they are.
        const old_hash: ?PathHash = if (old_path) |p|
            pathHash(p) catch null
        else
            null;
        if (rename != null and old_hash != null) {
            const new_hash = try pathHash(rename.?);
            const dirs_change = old_hash.?.p_value != new_hash.p_value or
                old_hash.?.hash != new_hash.hash;
            if (dirs_change) {
                const dir = try e.dirHandle();
                const target = try e.layout.anlzDatFile(e.alloc, rename.?);
                defer e.alloc.free(target);
                if (dir.access(e.io, target, .{})) |_| {
                    return error.AnalysisPathCollision;
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
            }
        }

        // Caller data fails here or never: every changed string encodes
        // before anything is mutated.
        const ps = try encodePatchedStrings(a, patch);
        const file_path_str: ?pdb.DeviceSQLString = if (rename) |np|
            try pdb.DeviceSQLString.fromUtf8(a, np)
        else
            null;
        const filename_str: ?pdb.DeviceSQLString = if (rename) |np|
            try pdb.DeviceSQLString.fromUtf8(a, std.fs.path.basename(np))
        else
            null;
        const analyze_str: ?pdb.DeviceSQLString =
            if (rename != null and !strEmpty(old.offsets.inner.analyze_path))
                try pdb.DeviceSQLString.fromUtf8(a, try anlzDevicePath(a, rename.?))
            else
                null;

        var ids = PatchDimensionIds{
            .artist = old.artist_id,
            .album = old.album_id,
            .genre = old.genre_id,
            .key = old.key_id,
            .label = old.label_id,
            .composer = old.composer_id,
            .remixer = old.remixer_id,
            .orig_artist = old.orig_artist_id,
            .artwork = old.artwork_id,
        };
        if (patch.artist) |name| ids.artist = try getOrCreateArtist(state, db, name);
        if (patch.album) |name| ids.album = try getOrCreateAlbum(state, db, name, ids.artist);
        if (patch.genre) |name| ids.genre = try getOrCreateGenre(state, db, name);
        if (patch.key) |name| ids.key = try getOrCreateKey(state, db, name);
        if (patch.label) |name| ids.label = try getOrCreateLabel(state, db, name);
        if (patch.composer) |name| ids.composer = try getOrCreateArtist(state, db, name);
        if (patch.remixer) |name| ids.remixer = try getOrCreateArtist(state, db, name);
        if (patch.orig_artist) |name| ids.orig_artist = try getOrCreateArtist(state, db, name);
        if (patch.artwork_device_path) |path| ids.artwork = try getOrCreateArtwork(state, db, path);

        const boxed = try a.create(pdb.Track);
        boxed.* = old.*;
        if (ps.title) |s| boxed.offsets.inner.title = s;
        if (ps.comment) |s| boxed.offsets.inner.comment = s;
        if (ps.isrc) |s| boxed.offsets.inner.isrc = s;
        if (ps.lyricist) |s| boxed.offsets.inner.lyricist = s;
        if (ps.mix_name) |s| boxed.offsets.inner.mix_name = s;
        if (ps.release_date) |s| boxed.offsets.inner.release_date = s;
        if (ps.date_added) |s| boxed.offsets.inner.date_added = s;
        if (ps.message) |s| boxed.offsets.inner.message = s;
        if (ps.autoload_hotcues) |s| boxed.offsets.inner.autoload_hotcues = s;
        if (ps.publish_track_information) |s| boxed.offsets.inner.publish_track_information = s;
        if (ps.analyze_date) |s| boxed.offsets.inner.analyze_date = s;
        if (patch.tempo) |bpm| boxed.tempo = std.math.lossyCast(u32, @round(bpm * 100.0));
        if (patch.bitrate) |v| boxed.bitrate = v;
        if (patch.sample_rate) |v| boxed.sample_rate = v;
        if (patch.sample_depth) |v| boxed.sample_depth = v;
        if (patch.duration_secs) |v| boxed.duration = v;
        if (patch.file_size) |v| boxed.file_size = v;
        if (patch.track_number) |v| boxed.track_number = v;
        if (patch.disc_number) |v| boxed.disc_number = v;
        if (patch.year) |v| boxed.year = v;
        if (patch.play_count) |v| boxed.play_count = v;
        if (patch.rating) |v| boxed.rating = v;
        if (patch.color) |v| boxed.color = v;
        if (patch.file_type) |v| boxed.file_type = v;
        if (file_path_str) |s| boxed.offsets.inner.file_path = s;
        if (filename_str) |s| boxed.offsets.inner.filename = s;
        if (analyze_str) |s| boxed.offsets.inner.analyze_path = s;
        boxed.artist_id = ids.artist;
        boxed.album_id = ids.album;
        boxed.genre_id = ids.genre;
        boxed.key_id = ids.key;
        boxed.label_id = ids.label;
        boxed.composer_id = ids.composer;
        boxed.remixer_id = ids.remixer;
        boxed.orig_artist_id = ids.orig_artist;
        boxed.artwork_id = ids.artwork;
        try pdb.padTrackCommentToMinimum(boxed, a);

        // Add before remove: a failure past the add cannot lose the
        // track, and the id stays taken either way.
        var row_union = pdb.Row{ .track = boxed };
        _ = try db.addRow(&row_union);
        try db.removeRow(.tracks, @ptrCast(old));

        if (rename) |np| {
            // The dedup index follows the coordinate it keys on.
            if (old_path) |p| {
                if (p.len > 0) {
                    if (state.tracks_by_path.get(p)) |mapped| {
                        if (mapped == id) _ = state.tracks_by_path.remove(p);
                    }
                }
            }
            {
                const sa = state.arena.allocator();
                const owned = try sa.dupe(u8, np);
                try state.tracks_by_path.ensureUnusedCapacity(sa, 1);
                state.tracks_by_path.putAssumeCapacity(owned, id);
            }

            // The analysis: queued images retarget in memory, files on
            // disk get a relocation the next `save` lands. Same hash
            // directory means a relocation onto itself — the PPTH
            // rewrite only.
            if (old_path != null and old_hash != null) {
                try e.retargetPendingAnlz(old_path.?, np);
                const from_dir = try e.layout.anlzDir(e.alloc, old_path.?);
                errdefer e.alloc.free(from_dir);
                const to_dir = try e.layout.anlzDir(e.alloc, np);
                errdefer e.alloc.free(to_dir);
                const device_path = try e.alloc.dupe(u8, np);
                errdefer e.alloc.free(device_path);
                if (e.relocations.getPtr(id)) |rel| {
                    e.alloc.free(rel.to_dir);
                    e.alloc.free(rel.device_path);
                    rel.to_dir = to_dir;
                    rel.device_path = device_path;
                    e.alloc.free(from_dir);
                } else {
                    try e.relocations.put(e.alloc, id, .{
                        .from_dir = from_dir,
                        .to_dir = to_dir,
                        .device_path = device_path,
                    });
                }
            }
        }

        if (old_path) |p|
            try e.mirrorTrackUpdate(id, p, boxed, patch, ids, rename);
    }

    /// Removes track `id` from the export: the Track row, its playlist
    /// entries, and its tag junctions go; the OneLibrary side follows —
    /// a pending mirror row is dropped, a disk `content` row is
    /// cascade-deleted (with its junction rows) at the next `save`.
    /// Every reference goes with the cascade, so the id is free again
    /// after a reopen (the writer's scan is max-based, like the format's
    /// own writers); within the session the counters stay past it.
    /// With `delete_analysis_files`, the analysis directory goes too at
    /// the next save — unless another track's path hashes onto it.
    /// Orphaned dimension rows (an artist no remaining track names) stay
    /// behind, like `addTrack`'s failure residue: unreferenced, ignored
    /// by players.
    pub fn removeTrack(
        e: *DeviceExport,
        id: u32,
        options: RemoveTrackOptions,
    ) RemoveTrackError!void {
        const state = try e.writerStateMut();
        try e.primeOlStore();
        if (!state.track_ids.contains(id)) return error.UnknownTrack;
        const old = (try e.findTrackRow(id)) orelse return error.UnknownTrack;
        const db = try e.openPdb();
        const old_path = try decodedFilePath(e, old);
        defer if (old_path) |p| e.alloc.free(p);

        // The OL cascade resolves by the path the track still carries.
        try e.removeOlTrack(id, old_path);

        try e.removeRowsMatching(
            db,
            .playlist_entries,
            TrackIdMatch{ .id = id },
            playlistEntryNamesTrack,
        );
        try e.ensureExtLoaded();
        if (e.ext_pdb_state == .loaded) {
            const track_tag_page: pdb.PageType =
                @enumFromInt(@intFromEnum(pdb.ExtPageType.track_tag));
            try e.removeRowsMatching(
                &e.ext_pdb_state.loaded,
                track_tag_page,
                TrackIdMatch{ .id = id },
                trackTagNamesTrack,
            );
        }
        try db.removeRow(.tracks, @ptrCast(old));

        _ = state.track_ids.remove(id);
        if (old_path) |p| {
            if (state.tracks_by_path.get(p)) |mapped| {
                if (mapped == id) _ = state.tracks_by_path.remove(p);
            }
            try e.dropPendingAnlzFor(p);
        }

        // A rename that never saved leaves a queued relocation behind;
        // its source directory may hold files an earlier save landed.
        if (e.relocations.fetchRemove(id)) |kv| {
            var rel = kv.value;
            if (options.delete_analysis_files)
                try e.queueDirDeleteIfUnused(state, id, rel.from_dir);
            rel.deinit(e.alloc);
        }
        if (options.delete_analysis_files) {
            if (old_path) |p| try e.queueAnlzDirDelete(state, id, p);
        }
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
                    .publish_track_information = if (track.publish_track_information)
                        try pdb.DeviceSQLString.fromUtf8(a, "ON")
                    else
                        pdb.DeviceSQLString.empty(),
                    .autoload_hotcues = if (track.autoload_hotcues)
                        try pdb.DeviceSQLString.fromUtf8(a, "ON")
                    else
                        pdb.DeviceSQLString.empty(),
                    .date_added = try pdb.DeviceSQLString.fromUtf8(a, track.date_added),
                    .release_date = try pdb.DeviceSQLString.fromUtf8(a, track.release_date),
                    .mix_name = try pdb.DeviceSQLString.fromUtf8(a, track.mix_name),
                    .analyze_path = analyze_path,
                    .analyze_date = try pdb.DeviceSQLString.fromUtf8(a, track.analyze_date),
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

    /// The Track row of `id`, or null when the export carries none. The
    /// returned pointer is the row's boxed payload — arena-stable across
    /// row-list shifts, and the identity `pdb.Database.removeRow` wants.
    fn findTrackRow(e: *DeviceExport, id: u32) WriterStateError!?*pdb.Track {
        const db = try e.openPdb();
        var it = try db.rows(.tracks);
        while (try it.next()) |row| {
            if (row.track.id == id) return row.track;
        }
        return null;
    }

    /// The decoded device file path of `row`, or null when it does not
    /// decode — the OL join and the path-keyed state have no key for it.
    /// The caller frees.
    fn decodedFilePath(e: *DeviceExport, row: *const pdb.Track) error{OutOfMemory}!?[]u8 {
        return row.offsets.inner.file_path.utf8(e.alloc) catch |err| switch (err) {
            error.InvalidEncoding => null,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Locates the OL `content` row joined to pdb track `track_id` whose
    /// pdb file path is `path`: the recorded bridge first (a rename has
    /// already moved the path on), then pending inserts and queued
    /// updates by path, then the loaded library by path. Every hit
    /// records the bridge, so the next resolution survives a later path
    /// change. An export without an OL db resolves nothing.
    fn olContentRefForTrack(
        e: *DeviceExport,
        track_id: u32,
        path: []const u8,
    ) OlMirrorError!?OlContentRef {
        const store = (try e.olStore()) orelse return null;

        if (store.content_bridge.get(track_id)) |content_id| {
            if (try contentRefById(e, store, content_id)) |ref| return ref;
        }
        if (path.len == 0) return null;
        for (store.contents.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.path orelse "", path)) {
                try recordBridge(store, track_id, c.content_id);
                return .{ .pending = i };
            }
        }
        for (store.content_updates.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.path orelse "", path)) {
                try recordBridge(store, track_id, c.content_id);
                return .{ .queued_update = i };
            }
        }
        if (ol.mode != .off) {
            const lib = (try e.openOL()) orelse return null;
            if (lib.contentByPath(path)) |c| {
                try recordBridge(store, track_id, c.content_id);
                return .{ .disk = c };
            }
        }
        return null;
    }

    /// The OL content row of `content_id` wherever it lives — pending,
    /// queued for update, or on disk in the cached library.
    fn contentRefById(
        e: *DeviceExport,
        store: *OlStore,
        content_id: i64,
    ) OlMirrorError!?OlContentRef {
        for (store.contents.items, 0..) |*c, i| {
            if (c.content_id == content_id) return .{ .pending = i };
        }
        for (store.content_updates.items, 0..) |*c, i| {
            if (c.content_id == content_id) return .{ .queued_update = i };
        }
        if (ol.mode != .off) {
            const lib = (try e.openOL()) orelse return null;
            if (lib.byId(ol.Content, content_id)) |c| return .{ .disk = c };
        }
        return null;
    }

    /// Lands a `TrackPatch` on the OL side: the joined content row moves
    /// only where the patch says, so a diverged db keeps its own values
    /// elsewhere — and a rename (`rename` non-null) first moves the
    /// row's `path`, `fileName`, and `analysisDataFilePath` to the new
    /// path. A disk row queues a whole-row update (its current values
    /// copied and patched); pending rows and queued updates mutate in
    /// place.
    fn mirrorTrackUpdate(
        e: *DeviceExport,
        track_id: u32,
        old_path: []const u8,
        new_row: *const pdb.Track,
        patch: TrackPatch,
        ids: PatchDimensionIds,
        rename: ?[]const u8,
    ) OlMirrorError!void {
        const store = (try e.olStore()) orelse return;
        const ref = (try e.olContentRefForTrack(track_id, old_path)) orelse return;
        const sa = store.arena.allocator();

        const moveRow = struct {
            fn move(c: *ol.Content, a: std.mem.Allocator, new_path: []const u8, row: *const pdb.Track) OlMirrorError!void {
                c.path = try a.dupe(u8, new_path);
                c.fileName = try a.dupe(u8, std.fs.path.basename(new_path));
                if (!strEmpty(row.offsets.inner.analyze_path))
                    c.analysisDataFilePath = try anlzDevicePath(a, new_path);
            }
        }.move;

        switch (ref) {
            .pending => |i| {
                if (rename) |np| try moveRow(&store.contents.items[i], sa, np, new_row);
                try applyTrackPatchToContent(store, &store.contents.items[i], new_row, patch, ids);
            },
            .queued_update => |i| {
                if (rename) |np| try moveRow(&store.content_updates.items[i], sa, np, new_row);
                try applyTrackPatchToContent(store, &store.content_updates.items[i], new_row, patch, ids);
            },
            .disk => |c| {
                var copy = try dupeContent(sa, c);
                if (rename) |np| try moveRow(&copy, sa, np, new_row);
                try applyTrackPatchToContent(store, &copy, new_row, patch, ids);
                try queueContentUpdate(store, copy);
            },
        }
    }

    /// The OL half of a track removal: the joined content row goes — a
    /// pending insert is dropped, a queued update is unqueued, a disk row
    /// is queued for the cascade delete — and the pending junction rows
    /// naming it never land.
    fn removeOlTrack(
        e: *DeviceExport,
        track_id: u32,
        old_path: ?[]const u8,
    ) OlMirrorError!void {
        const store = (try e.olStore()) orelse return;
        const path = old_path orelse return;
        const ref = (try e.olContentRefForTrack(track_id, path)) orelse return;
        const content_id = switch (ref) {
            .pending => |i| store.contents.items[i].content_id,
            .queued_update => |i| store.content_updates.items[i].content_id,
            .disk => |c| c.content_id,
        };
        _ = store.content_bridge.remove(track_id);

        dropJunctionsForContent(&store.playlist_pairs, content_id);
        dropJunctionsForContent(&store.my_tag_pairs, content_id);

        switch (ref) {
            .pending => |i| _ = store.contents.orderedRemove(i),
            .queued_update => |i| {
                _ = store.content_updates.orderedRemove(i);
                try queueContentDelete(store, content_id);
            },
            .disk => try queueContentDelete(store, content_id),
        }
    }

    /// Removes every row of `page_type`'s table that `matches` selects,
    /// collecting the payload pointers first — removal shifts the row
    /// list, but the boxed payloads are arena-stable (see
    /// `pdb.Database.removeRow`). A table the database does not carry
    /// removes nothing.
    fn removeRowsMatching(
        e: *DeviceExport,
        db: *pdb.Database,
        page_type: pdb.PageType,
        ctx: TrackIdMatch,
        comptime matches: fn (TrackIdMatch, *const pdb.Row) bool,
    ) RemoveTrackError!void {
        var it = (try rowsOrEmpty(db, page_type)) orelse return;
        var payloads = std.ArrayList(*const anyopaque).empty;
        defer payloads.deinit(e.alloc);
        while (try it.next()) |row| {
            if (matches(ctx, row)) try payloads.append(e.alloc, rowPayloadKey(row));
        }
        for (payloads.items) |payload| try db.removeRow(page_type, payload);
    }

    /// Drops every queued ANLZ image of the track at `audio_path` — a
    /// track removed before its first save leaves nothing on disk.
    fn dropPendingAnlzFor(e: *DeviceExport, audio_path: []const u8) PathError!void {
        const siblings = try e.anlzSiblingHostPaths(audio_path);
        defer for (&siblings) |*slot| {
            if (slot.*) |p| e.alloc.free(p);
        };
        var i: usize = 0;
        while (i < e.pending_anlz.items.len) {
            const found = for (siblings) |slot| {
                if (slot) |p| {
                    if (std.mem.eql(u8, e.pending_anlz.items[i].path, p)) break true;
                }
            } else false;
            if (found) {
                var file = e.pending_anlz.orderedRemove(i);
                file.deinit(e.alloc);
            } else i += 1;
        }
    }

    /// Rewrites the PPTH path section of every queued ANLZ image of the
    /// track at `old_path` and retargets its host path to the new hash
    /// directory — a track queued this session has nothing on disk to
    /// move.
    fn retargetPendingAnlz(
        e: *DeviceExport,
        old_path: []const u8,
        new_path: []const u8,
    ) (anlz.ParseError || anlz.WriteError || PathError)!void {
        const siblings = try e.anlzSiblingHostPaths(old_path);
        defer for (&siblings) |*slot| {
            if (slot.*) |p| e.alloc.free(p);
        };
        for (e.pending_anlz.items) |*file| {
            const is_ours = for (siblings) |slot| {
                if (slot) |p| {
                    if (std.mem.eql(u8, file.path, p)) break true;
                }
            } else false;
            if (!is_ours) continue;

            const image = try e.retargetAnlzImage(file.image, new_path);
            e.alloc.free(file.image);
            file.image = image;
            const new_host = try e.anlzHostPathFor(new_path, std.fs.path.basename(file.path));
            e.alloc.free(file.path);
            file.path = new_host;
        }
    }

    /// The host paths of `audio_path`'s three ANLZ siblings; an entry is
    /// null when its path could not be built (an invalid path).
    fn anlzSiblingHostPaths(e: *DeviceExport, audio_path: []const u8) PathError![3]?[]u8 {
        var paths: [3]?[]u8 = undefined;
        paths[0] = e.layout.anlzDatFile(e.alloc, audio_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => null,
        };
        errdefer if (paths[0]) |p| e.alloc.free(p);
        paths[1] = e.layout.anlzExtFile(e.alloc, audio_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => null,
        };
        errdefer if (paths[1]) |p| e.alloc.free(p);
        paths[2] = e.layout.anlz2exFile(e.alloc, audio_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => null,
        };
        return paths;
    }

    /// The host path of `filename` (an ANLZ sibling name) in the analysis
    /// directory `audio_path` hashes onto.
    fn anlzHostPathFor(
        e: *DeviceExport,
        audio_path: []const u8,
        filename: []const u8,
    ) PathError![]u8 {
        const names = anlzFolderNames(try pathHash(audio_path));
        return std.fs.path.join(e.alloc, &.{
            e.layout.root, "PIONEER", "USBANLZ",
            &names.p_folder, &names.leaf_folder,
            filename,
        });
    }

    /// Re-serializes an ANLZ image with every path section naming
    /// `new_device_path` — byte-identical elsewhere, per the round-trip
    /// guarantee. The caller owns the returned image and frees the old.
    fn retargetAnlzImage(
        e: *DeviceExport,
        image: []const u8,
        new_device_path: []const u8,
    ) (anlz.ParseError || anlz.WriteError || PathError)![]u8 {
        var m = try anlz.Anlz.parse(e.alloc, image);
        defer m.deinit();
        for (m.sections) |*section| switch (section.*) {
            .path => |*p| p.path = try anlz.LenPrefixedWideString.fromUtf8(
                m.arena.allocator(),
                new_device_path,
            ),
            else => {},
        };
        return try anlz.serializeFile(e.alloc, m.header_data, m.sections);
    }

    /// Queues the analysis directory of the track at `path` for deletion
    /// at the next save.
    fn queueAnlzDirDelete(
        e: *DeviceExport,
        state: *WriterState,
        except_id: u32,
        path: []const u8,
    ) PathError!void {
        const dir = try e.layout.anlzDir(e.alloc, path);
        defer e.alloc.free(dir);
        try e.queueDirDeleteIfUnused(state, except_id, dir);
    }

    /// Queues `dir` for deletion — unless a surviving track's analysis
    /// lives there too: another track's path may hash onto it, or a
    /// queued write may target it. Sharing means keeping.
    fn queueDirDeleteIfUnused(
        e: *DeviceExport,
        state: *WriterState,
        except_id: u32,
        dir: []const u8,
    ) PathError!void {
        var it = state.tracks_by_path.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == except_id) continue;
            const other = e.layout.anlzDir(e.alloc, entry.key_ptr.*) catch continue;
            defer e.alloc.free(other);
            if (std.mem.eql(u8, other, dir)) return; // shared: keep it
        }
        for (e.pending_anlz.items) |file| {
            if (isUnderDir(file.path, dir)) return;
        }
        var rt = e.relocations.iterator();
        while (rt.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.to_dir, dir)) return;
        }
        try e.pending_dir_deletes.append(e.alloc, try e.alloc.dupe(u8, dir));
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
        counter: *IdMint(u32),
        comptime build_row: fn (
            std.mem.Allocator,
            u32,
            []const u8,
        ) error{ TooLong, InvalidEncoding, OutOfMemory }!pdb.Row,
        name: []const u8,
    ) AddTrackError!u32 {
        if (name.len == 0) return 0;
        if (map.get(name)) |id| return id;

        const id = try counter.mint();
        const sa = state.arena.allocator();
        const owned = try sa.dupe(u8, name);
        try map.ensureUnusedCapacity(sa, 1);
        var row = try build_row(db.arena.allocator(), id, name);
        _ = try db.addRow(&row);
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

        const id = try state.next_album_id.mint();
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

        const id = try state.next_key_id.mint();
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
    /// encodes and the id mints before anything is inserted, so a failed
    /// call leaves the export untouched — a failure past the mint may
    /// burn an id, never mint a duplicate.
    fn createPlaylistNode(
        e: *DeviceExport,
        name: []const u8,
        parent_id: u32,
        is_folder: bool,
    ) PlaylistError!u32 {
        const state = try e.writerStateMut();
        try e.primeOlStore();
        // The root (id 0) is always a valid parent; any other id must
        // name an existing folder — a playlist cannot hold children.
        if (parent_id != 0) {
            const parent_is_folder = state.playlist_nodes.get(parent_id) orelse false;
            if (!parent_is_folder) return error.UnknownForeignKey;
        }

        const db = try e.openPdb();
        const a = db.arena.allocator();
        const name_str = try pdb.DeviceSQLString.fromUtf8(a, name);
        const id = try state.next_playlist_node_id.mint();
        const boxed = try a.create(pdb.PlaylistTreeNode);
        boxed.* = .{
            .parent_id = parent_id,
            .id = id,
            .node_is_folder = if (is_folder) 1 else 0,
            .name = name_str,
        };
        try state.playlist_nodes.ensureUnusedCapacity(state.arena.allocator(), 1);
        var row = pdb.Row{ .playlist_tree_node = boxed };
        _ = try db.addRow(&row);

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
        const state = try e.writerStateMut();
        try e.primeOlStore();
        const node_is_folder = state.playlist_nodes.get(playlist_id) orelse
            return error.UnknownForeignKey;
        if (node_is_folder) return error.UnknownForeignKey;
        if (!state.track_ids.contains(track_id)) return error.UnknownForeignKey;

        var entry_mint: IdMint(u32) =
            state.playlist_entry_counts.get(playlist_id) orelse .{ .next = 0 };
        const entry_index = try entry_mint.mint();

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
        gop.value_ptr.* = entry_mint;

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
        const state = try e.writerStateMut();
        try e.primeOlStore();
        const db = try e.extDb();
        const id = try state.next_tag_id.mint();
        const row_index = try state.next_tag_row_index.mint();
        const position = try state.next_category_position.mint();
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
        const state = try e.writerStateMut();
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
    /// no scanned or previously created leaf matches. The id, row index,
    /// and leaf position mint before the insert.
    fn getOrCreateTag(
        e: *DeviceExport,
        state: *WriterState,
        db: *pdb.Database,
        category_id: u32,
        label: []const u8,
    ) TagError!u32 {
        if (state.tags_by_key.get(.{ .category_id = category_id, .label = label })) |id|
            return id;

        const id = try state.next_tag_id.mint();
        const row_index = try state.next_tag_row_index.mint();
        var leaf_position: IdMint(u32) =
            state.tag_leaf_counts.get(category_id) orelse .{ .next = 0 };
        const position = try leaf_position.mint();
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

        state.tags_by_key.putAssumeCapacity(
            .{ .category_id = category_id, .label = owned_label },
            id,
        );
        const gop = state.tag_leaf_counts.getOrPutAssumeCapacity(category_id);
        gop.value_ptr.* = leaf_position;

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
        const state = try e.writerStateMut();
        try scanExtTags(state.arena.allocator(), &db, state);
        e.ext_pdb_state = .{ .loaded = db };
    }

    /// Writes the buffered export to disk — the handle's only
    /// disk-writing call. Everything that can fail on the in-memory
    /// model — parsing, track-row validation, serialization — happens
    /// before the first write, so a failed `save` leaves the disk
    /// untouched. Crash-safe write order: the default directory tree,
    /// the four setting files, the queued ANLZ files, the relocated
    /// ANLZ files `updateTrack`'s rename queued (their old directories deleted
    /// only after the new index lands), `exportExt.pdb`
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
        try e.writeRelocatedAnlz(dir);

        if (ext_image) |bytes| {
            const ext_path = try e.layout.exportExtPdb(e.alloc);
            defer e.alloc.free(ext_path);
            try writeFileAtomic(e.io, dir, ext_path, bytes);
        }

        try e.writeOl();

        const pdb_path = try e.layout.exportPdb(e.alloc);
        defer e.alloc.free(pdb_path);
        try writeFileAtomic(e.io, dir, pdb_path, image);
        e.cleanupAfterSave(dir);
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
    /// Skipped entirely in `-Dol=off` builds.
    fn writeOl(e: *DeviceExport) SaveError!void {
        if (ol.mode == .off) return;
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

        var w: ol.Writer = undefined;
        if (store.fresh) {
            // A created export starts from an empty db even over a
            // leftover file — the same overwrite stance as the ext pdb.
            const dir = try e.dirHandle();
            dir.deleteFile(e.io, rel) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            w = try ol.Writer.create(e.io, path, .{ .created_date = "" });
        } else {
            w = try ol.Writer.open(e.io, path);
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
        // Updates and deletes name rows already on disk — ids the
        // monotonic counters never re-emit — so their order against the
        // inserts cannot collide.
        try olDrainUpdates(w, &store.content_updates);
        try olDrainContentDeletes(w, &store.content_deletes);

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
            try writeFileAtomic(e.io, dir, file.path, file.image);
        }
        for (e.pending_anlz.items) |*file| file.deinit(e.alloc);
        e.pending_anlz.clearRetainingCapacity();
    }

    /// Size cap when reading one ANLZ sibling for relocation; the
    /// largest analysis files run a few megabytes.
    const anlz_limit = std.Io.Limit.limited(1 << 26);

    /// Lands every queued relocation: each sibling found under its
    /// `from_dir` is re-serialized — its path section naming the track's
    /// new device path — and written, atomically, into `to_dir`. A
    /// sibling with no file on disk skips silently: the track never had
    /// that kind of analysis. Runs before `export.pdb`, so a crash
    /// leaves the old index naming the old directory, still populated;
    /// the old directories go away only after the new index has landed
    /// (`cleanupAfterSave`). A failure leaves the queue intact — the
    /// landed siblings are fixed bytes a retry rewrites identically.
    fn writeRelocatedAnlz(e: *DeviceExport, dir: std.Io.Dir) RelocateError!void {
        const siblings = [_][]const u8{ "ANLZ0000.DAT", "ANLZ0000.EXT", "ANLZ0000.2EX" };
        var it = e.relocations.iterator();
        while (it.next()) |entry| {
            const rel = entry.value_ptr;
            for (siblings) |name| {
                const from_path = try std.fs.path.join(e.alloc, &.{ rel.from_dir, name });
                defer e.alloc.free(from_path);
                const image = dir.readFileAlloc(
                    e.io,
                    from_path,
                    e.alloc,
                    anlz_limit,
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer e.alloc.free(image);
                const patched = try e.retargetAnlzImage(image, rel.device_path);
                defer e.alloc.free(patched);
                try dir.createDirPath(e.io, rel.to_dir);
                const to_path = try std.fs.path.join(e.alloc, &.{ rel.to_dir, name });
                defer e.alloc.free(to_path);
                try writeFileAtomic(e.io, dir, to_path, patched);
            }
        }
    }

    /// Best-effort cleanup once the new `export.pdb` has landed: the
    /// relocation source directories and the directories `removeTrack`
    /// queued. Nothing here can fail the save — a leftover directory is
    /// an orphan no player reaches. A source equal to its own or another
    /// relocation's target stays (that target was just filled from it).
    /// Also drops the cached OL snapshot — it names the pre-save disk —
    /// and releases the relocation and deletion queues.
    fn cleanupAfterSave(e: *DeviceExport, dir: std.Io.Dir) void {
        var it = e.relocations.iterator();
        while (it.next()) |entry| {
            const from_dir = entry.value_ptr.from_dir;
            if (std.mem.eql(u8, from_dir, entry.value_ptr.to_dir)) continue;
            var keep = false;
            var other = e.relocations.iterator();
            while (other.next()) |o| {
                if (std.mem.eql(u8, from_dir, o.value_ptr.to_dir)) {
                    keep = true;
                    break;
                }
            }
            if (!keep) dir.deleteTree(e.io, from_dir) catch {};
        }
        for (e.pending_dir_deletes.items) |del| dir.deleteTree(e.io, del) catch {};

        var rel = e.relocations.iterator();
        while (rel.next()) |entry| entry.value_ptr.deinit(e.alloc);
        e.relocations.clearAndFree(e.alloc);
        for (e.pending_dir_deletes.items) |del| e.alloc.free(del);
        e.pending_dir_deletes.clearAndFree(e.alloc);

        switch (e.ol_library) {
            .loaded => |*lib| {
                lib.deinit();
                e.ol_library = .unloaded;
            },
            .unloaded, .absent => {},
        }
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
            try writeFileAtomic(e.io, dir, path, pending[i]);
        }
        for (pending) |bytes| e.alloc.free(bytes);
        e.pending_settings = null;
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

/// Either a playlist folder or a playlist. Nodes are owned by the
/// `PlaylistTree` they were built into — its arena holds every name and
/// children list — so nothing frees them individually.
pub const PlaylistNode = union(enum) {
    folder: PlaylistFolder,
    playlist: Playlist,
};

/// A playlist tree, whole-owned: every node, name, and children list came
/// from one arena, so `deinit` frees the entire tree — of any nesting
/// depth — without walking it.
pub const PlaylistTree = struct {
    arena: *std.heap.ArenaAllocator,
    /// The top-level nodes, in row order.
    roots: []PlaylistNode,

    pub fn deinit(tree: *PlaylistTree) void {
        const child = tree.arena.child_allocator;
        tree.arena.deinit();
        child.destroy(tree.arena);
    }
};

/// Error of the playlist-tree walk.
pub const PlaylistTreeError = pdb.RowIterError || error{ InvalidEncoding, OutOfMemory };

/// Playlist-tree rows grouped by their parent id.
const PlaylistGroups = std.AutoHashMap(u32, std.ArrayList(*const pdb.PlaylistTreeNode));

/// One level of the iterative tree build: the rows parented to one
/// folder, the next unprocessed row, the nodes collected so far, and —
/// except at the root — the folder they belong to.
const PlaylistLevel = struct {
    rows: []const *const pdb.PlaylistTreeNode,
    next: usize = 0,
    nodes: std.ArrayList(PlaylistNode) = .empty,
    /// The folder whose children this level collects; null at the root.
    folder: ?struct { id: u32, name: []u8 } = null,
};

/// Builds the tree over an explicit level stack instead of recursion: a
/// folder row pushes a level for its children and joins its parent's
/// nodes only when that level drains. The visitation order — rows in
/// order, a folder expanded at first encounter, the `visited` skip — is
/// exactly the recursive walk's, but a folder chain of any depth costs
/// heap, never call-stack frames.
fn buildTree(
    a: std.mem.Allocator,
    groups: *const PlaylistGroups,
    visited: *std.AutoHashMap(u32, void),
) PlaylistTreeError!std.ArrayList(PlaylistNode) {
    const root_rows = if (groups.get(0)) |group| group.items else &.{};
    var levels: std.ArrayList(PlaylistLevel) = .empty;
    try levels.append(a, .{ .rows = root_rows });

    var roots = std.ArrayList(PlaylistNode).empty;
    while (levels.items.len > 0) {
        const top = &levels.items[levels.items.len - 1];
        if (top.next >= top.rows.len) {
            const done = levels.pop().?;
            if (done.folder) |folder| {
                const parent = &levels.items[levels.items.len - 1];
                try parent.nodes.append(a, .{ .folder = .{
                    .id = folder.id,
                    .name = folder.name,
                    .children = done.nodes,
                } });
            } else {
                roots = done.nodes;
            }
            continue;
        }
        const node = top.rows[top.next];
        top.next += 1;
        if (node.isFolder()) {
            if ((try visited.getOrPut(node.id)).found_existing) continue;
            const name = try node.name.utf8(a);
            const child_rows = if (groups.get(node.id)) |group| group.items else &.{};
            // `top` dangles past this append; the loop re-derives it.
            try levels.append(a, .{
                .rows = child_rows,
                .folder = .{ .id = node.id, .name = name },
            });
        } else {
            const name = try node.name.utf8(a);
            try top.nodes.append(a, .{ .playlist = .{ .id = node.id, .name = name } });
        }
    }
    return roots;
}

/// Builds the playlist tree from a database's playlist-tree rows: nodes
/// parented to 0 form the top level, folders expand into their children,
/// and names are decoded to UTF-8. Nodes unreachable from the root
/// (parented to a missing id) do not appear; a folder id is expanded at
/// most once, so parent-id cycles in corrupt data cannot double-include
/// a subtree. The build is iterative and the whole tree lives in one
/// arena, so nesting of any depth builds and tears down without
/// touching the call stack.
///
/// The caller owns the tree; `deinit` frees everything:
///
///     const device = @import("rekordlib").device;
///     var tree = try device.getPlaylistsDb(alloc, &db);
///     defer tree.deinit();
pub fn getPlaylistsDb(
    alloc: std.mem.Allocator,
    db: *const pdb.Database,
) PlaylistTreeError!PlaylistTree {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();

    // The grouping map, visited set, level stack, and node storage all
    // come from the arena: a failed build is reclaimed wholesale.
    var groups = PlaylistGroups.init(a);
    var it = try db.rows(.playlist_tree);
    while (try it.next()) |row| switch (row.*) {
        .playlist_tree_node => |node| {
            const gop = try groups.getOrPut(node.parent_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, node);
        },
        else => {},
    };

    var visited = std.AutoHashMap(u32, void).init(a);
    var roots = try buildTree(a, &groups, &visited);

    return .{ .arena = arena, .roots = try roots.toOwnedSlice(a) };
}

// --- unified track model (read views, patches, OL join) -------------------------

/// Iterator over an export's tracks (see `DeviceExport.tracks`). Two
/// arenas: one holds the dimension maps for the iterator's life, the
/// other the current view's decoded strings, reset at every `next` — a
/// view borrows from it until the next call.
pub const TrackIter = struct {
    e: *DeviceExport,
    /// Holds the dimension maps; freed by `deinit`.
    dim_arena: std.heap.ArenaAllocator,
    /// Holds the current view's decoded strings; reset by every `next`.
    view_arena: std.heap.ArenaAllocator,
    dims: TrackDimensions,
    it: pdb.RowIterator,

    pub fn deinit(it: *TrackIter) void {
        it.dim_arena.deinit();
        it.view_arena.deinit();
    }

    /// The next track view, or null once the table is exhausted. The
    /// previous view's strings die here.
    pub fn next(it: *TrackIter) TrackViewError!?TrackView {
        const row = (try it.it.next()) orelse return null;
        _ = it.view_arena.reset(.retain_capacity);
        return try fillTrackView(it.e, &it.dims, it.view_arena.allocator(), row.track);
    }
};

/// A `TrackView` that owns its strings, from `DeviceExport.trackByPath`.
/// `deinit` frees the view's every slice.
pub const TrackRecord = struct {
    arena: *std.heap.ArenaAllocator,
    view: TrackView,

    pub fn deinit(r: *TrackRecord) void {
        const child = r.arena.child_allocator;
        r.arena.deinit();
        child.destroy(r.arena);
    }
};

/// Where a joined OL content row lives, when one joined at all.
const OlContentRef = union(enum) {
    /// A row pending its first insert — an `OlStore.contents` index.
    pending: usize,
    /// A queued whole-row update — an `OlStore.content_updates` index.
    queued_update: usize,
    /// A row already on disk, borrowed from the cached library.
    disk: *const ol.Content,
};

/// One id-keyed dimension table of a read view: row id -> decoded name.
const DimensionMap = std.AutoHashMapUnmanaged(u32, []const u8);

/// The name lookups a track view resolves its foreign keys through, all
/// in one arena: artists, albums, genres, labels, keys, and the artwork
/// table's device paths.
const TrackDimensions = struct {
    artists: DimensionMap = .empty,
    albums: DimensionMap = .empty,
    genres: DimensionMap = .empty,
    labels: DimensionMap = .empty,
    keys: DimensionMap = .empty,
    /// Artwork row id -> device path of the image.
    artwork: DimensionMap = .empty,

    fn build(e: *DeviceExport, a: std.mem.Allocator) TrackViewError!TrackDimensions {
        var dims = TrackDimensions{};
        const db = try e.openPdb();
        try scanDimension(db, .artists, "artist", &.{ "offsets", "inner", "name" }, a, &dims.artists);
        try scanDimension(db, .albums, "album", &.{ "offsets", "inner", "name" }, a, &dims.albums);
        try scanDimension(db, .genres, "genre", &.{"name"}, a, &dims.genres);
        try scanDimension(db, .labels, "label", &.{"name"}, a, &dims.labels);
        try scanDimension(db, .keys, "key", &.{"name"}, a, &dims.keys);
        try scanDimension(db, .artwork, "artwork", &.{"path"}, a, &dims.artwork);
        return dims;
    }
};

/// Fills `map` with one dimension table's `id -> name`, first row wins
/// on duplicate ids; an invalid encoding leaves the id nameless (the
/// view shows an empty name), matching the writer-state scans.
fn scanDimension(
    db: *const pdb.Database,
    page_type: pdb.PageType,
    comptime tag: []const u8,
    comptime field_path: []const []const u8,
    a: std.mem.Allocator,
    map: *DimensionMap,
) ScanError!void {
    var it = (try rowsOrEmpty(db, page_type)) orelse return;
    while (try it.next()) |row| {
        const payload = @field(row.*, tag);
        const name = decodeOrEmpty(stringField(payload, field_path), a) catch
            return error.OutOfMemory;
        const gop = try map.getOrPut(a, payload.id);
        if (!gop.found_existing) gop.value_ptr.* = name;
    }
}

/// A dimension name, or "" for an id the map does not carry.
fn dimName(map: *const DimensionMap, id: u32) []const u8 {
    return map.get(id) orelse "";
}

/// Decodes a row string for a view, treating an invalid encoding as
/// empty — a track the format cannot spell still counts.
fn decodeOrEmpty(s: pdb.DeviceSQLString, a: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    return s.utf8(a) catch |err| switch (err) {
        error.InvalidEncoding => "",
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Whether a row string is the empty one.
fn strEmpty(s: pdb.DeviceSQLString) bool {
    return switch (s) {
        .short_ascii => |bytes| bytes.len == 0,
        .long => |body| switch (body) {
            .isrc, .ascii => |chars| chars.len == 0,
            .ucs2le => |units| units.len == 0,
        },
    };
}

/// Builds one track's view: every string decoded, foreign keys resolved
/// through `dims`, the OL row joined by file path.
fn fillTrackView(
    e: *DeviceExport,
    dims: *const TrackDimensions,
    a: std.mem.Allocator,
    row: *const pdb.Track,
) TrackViewError!TrackView {
    const s = row.offsets.inner;
    var v: TrackView = .{
        .id = row.id,
        .title = try decodeOrEmpty(s.title, a),
        .artist = dimName(&dims.artists, row.artist_id),
        .album = dimName(&dims.albums, row.album_id),
        .genre = dimName(&dims.genres, row.genre_id),
        .key = dimName(&dims.keys, row.key_id),
        .label = dimName(&dims.labels, row.label_id),
        .composer = dimName(&dims.artists, row.composer_id),
        .remixer = dimName(&dims.artists, row.remixer_id),
        .orig_artist = dimName(&dims.artists, row.orig_artist_id),
        .lyricist = try decodeOrEmpty(s.lyricist, a),
        .comment = try decodeOrEmpty(s.comment, a),
        .isrc = try decodeOrEmpty(s.isrc, a),
        .mix_name = try decodeOrEmpty(s.mix_name, a),
        .release_date = try decodeOrEmpty(s.release_date, a),
        .date_added = try decodeOrEmpty(s.date_added, a),
        .message = try decodeOrEmpty(s.message, a),
        .file_path = try decodeOrEmpty(s.file_path, a),
        .filename = try decodeOrEmpty(s.filename, a),
        .artwork_device_path = dimName(&dims.artwork, row.artwork_id),
        .tempo_bpm = @as(f32, @floatFromInt(row.tempo)) / 100.0,
        .bitrate = row.bitrate,
        .sample_rate = row.sample_rate,
        .sample_depth = row.sample_depth,
        .duration_secs = row.duration,
        .file_size = row.file_size,
        .track_number = row.track_number,
        .disc_number = row.disc_number,
        .year = row.year,
        .play_count = row.play_count,
        .rating = row.rating,
        .color = row.color,
        .file_type = row.file_type,
        .autoload_hotcues = !strEmpty(s.autoload_hotcues),
        .publish_track_information = !strEmpty(s.publish_track_information),
        .analyze_date = try decodeOrEmpty(s.analyze_date, a),
        .has_analysis = !strEmpty(s.analyze_path),
        .source = .pdb_only,
    };

    if (v.file_path.len > 0) {
        if (try olJoinForView(e, v.file_path)) |c| {
            v.source = .pdb_and_ol;
            v.subtitle = c.subtitle orelse "";
            v.title_for_search = c.titleForSearch;
            v.kuvo_delivery_on = (c.isKuvoDeliverStatusOn orelse 0) != 0;
            v.kuvo_delivery_comment = c.kuvoDeliveryComment orelse "";
            v.date_created = c.dateCreated;
            v.cue_update_count = c.cueUpdateCount;
            v.analysis_data_update_count = c.analysisDataUpdateCount;
            v.information_update_count = c.informationUpdateCount;
        }
    }
    return v;
}

/// The OL content row a view joins by `path`, when the export carries an
/// OL db: rows this session queued first (a pending insert, or a queued
/// update — a rename already carries its new path there), then the
/// loaded library's snapshot of the disk. Read-side only — the store is
/// consulted, never loaded, so a session that never mutates never pays
/// for one.
fn olJoinForView(e: *DeviceExport, path: []const u8) TrackViewError!?*const ol.Content {
    if (e.ol_state == .store) {
        const store = &e.ol_state.store;
        for (store.contents.items) |*c| {
            if (std.mem.eql(u8, c.path orelse "", path)) return c;
        }
        for (store.content_updates.items) |*c| {
            if (std.mem.eql(u8, c.path orelse "", path)) return c;
        }
    }
    if (ol.mode == .off) return null;
    const lib = (try e.openOL()) orelse return null;
    return lib.contentByPath(path);
}

/// The resolved dimension ids a `TrackPatch` asked for — seeded from the
/// old row, so an unpatched dimension keeps its id untouched.
const PatchDimensionIds = struct {
    artist: u32 = 0,
    album: u32 = 0,
    genre: u32 = 0,
    key: u32 = 0,
    label: u32 = 0,
    composer: u32 = 0,
    remixer: u32 = 0,
    orig_artist: u32 = 0,
    artwork: u32 = 0,
};

/// The string fields of a `TrackPatch`, encoded up front so a bad one
/// fails the call before anything is mutated.
const PatchedTrackStrings = struct {
    title: ?pdb.DeviceSQLString = null,
    comment: ?pdb.DeviceSQLString = null,
    isrc: ?pdb.DeviceSQLString = null,
    lyricist: ?pdb.DeviceSQLString = null,
    mix_name: ?pdb.DeviceSQLString = null,
    release_date: ?pdb.DeviceSQLString = null,
    date_added: ?pdb.DeviceSQLString = null,
    message: ?pdb.DeviceSQLString = null,
    autoload_hotcues: ?pdb.DeviceSQLString = null,
    publish_track_information: ?pdb.DeviceSQLString = null,
    analyze_date: ?pdb.DeviceSQLString = null,
};

fn encodePatchedStrings(
    a: std.mem.Allocator,
    patch: TrackPatch,
) error{ TooLong, InvalidEncoding, OutOfMemory }!PatchedTrackStrings {
    var ps = PatchedTrackStrings{};
    if (patch.title) |v| ps.title = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.comment) |v| ps.comment = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.isrc) |v| ps.isrc = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.lyricist) |v| ps.lyricist = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.mix_name) |v| ps.mix_name = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.release_date) |v| ps.release_date = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.date_added) |v| ps.date_added = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.message) |v| ps.message = try pdb.DeviceSQLString.fromUtf8(a, v);
    if (patch.autoload_hotcues) |on|
        ps.autoload_hotcues = if (on)
            try pdb.DeviceSQLString.fromUtf8(a, "ON")
        else
            pdb.DeviceSQLString.empty();
    if (patch.publish_track_information) |on|
        ps.publish_track_information = if (on)
            try pdb.DeviceSQLString.fromUtf8(a, "ON")
        else
            pdb.DeviceSQLString.empty();
    if (patch.analyze_date) |v| ps.analyze_date = try pdb.DeviceSQLString.fromUtf8(a, v);
    return ps;
}

/// Applies a `TrackPatch` to one OL content row in place: pdb-mirrored
/// columns move only where the patch says — a diverged db keeps its own
/// values elsewhere — and the OL-only columns patch directly. Dimension
/// patches resolve through the mirror's own dedup state, bridging the
/// pdb ids `ids` carries.
fn applyTrackPatchToContent(
    store: *OlStore,
    c: *ol.Content,
    row: *const pdb.Track,
    patch: TrackPatch,
    ids: PatchDimensionIds,
) OlMirrorError!void {
    const a = store.arena.allocator();
    if (patch.title) |v| c.title = try a.dupe(u8, v);
    if (patch.comment) |v| c.djComment = try a.dupe(u8, v);
    if (patch.tempo != null) c.bpmx100 = row.tempo;
    if (patch.duration_secs) |v| c.length = v;
    if (patch.track_number) |v| c.trackNo = v;
    if (patch.disc_number) |v| c.discNo = v;
    if (patch.year) |v| c.releaseYear = v;
    if (patch.rating) |v| c.rating = v;
    if (patch.play_count) |v| c.djPlayCount = v;
    if (patch.release_date) |v| c.releaseDate = try a.dupe(u8, v);
    if (patch.date_added) |v| c.dateAdded = try a.dupe(u8, v);
    if (patch.isrc) |v| c.isrc = try a.dupe(u8, v);
    if (patch.bitrate) |v| c.bitrate = v;
    if (patch.sample_depth) |v| c.bitDepth = v;
    if (patch.sample_rate) |v| c.samplingRate = v;
    if (patch.file_size) |v| c.fileSize = v;
    if (patch.file_type) |v| c.fileType = @intFromEnum(v);
    if (patch.autoload_hotcues) |v| c.isHotCueAutoLoadOn = if (v) 1 else 0;

    if (patch.artist) |v|
        c.artist_id_artist = try olNamedRow(store, &store.artists_by_name, &store.artists, olArtistRow, ids.artist, v);
    if (patch.remixer) |v|
        c.artist_id_remixer = try olNamedRow(store, &store.artists_by_name, &store.artists, olArtistRow, ids.remixer, v);
    if (patch.orig_artist) |v|
        c.artist_id_originalArtist = try olNamedRow(store, &store.artists_by_name, &store.artists, olArtistRow, ids.orig_artist, v);
    if (patch.composer) |v|
        c.artist_id_composer = try olNamedRow(store, &store.artists_by_name, &store.artists, olArtistRow, ids.composer, v);
    if (patch.genre) |v|
        c.genre_id = try olNamedRow(store, &store.genres_by_name, &store.genres, olGenreRow, ids.genre, v);
    if (patch.label) |v|
        c.label_id = try olNamedRow(store, &store.labels_by_name, &store.labels, olLabelRow, ids.label, v);
    if (patch.key) |v| c.key_id = try olKeyId(store, v, ids.key);
    if (patch.album) |v|
        c.album_id = try olAlbumId(store, v, ids.album, c.artist_id_artist);

    if (patch.subtitle) |v| c.subtitle = try a.dupe(u8, v);
    if (patch.title_for_search) |v| c.titleForSearch = try a.dupe(u8, v);
    if (patch.kuvo_delivery_on) |v| c.isKuvoDeliverStatusOn = if (v) 1 else 0;
    if (patch.kuvo_delivery_comment) |v| c.kuvoDeliveryComment = try a.dupe(u8, v);
    if (patch.date_created) |v| c.dateCreated = try a.dupe(u8, v);
    if (patch.cue_update_count) |v| c.cueUpdateCount = v;
    if (patch.analysis_data_update_count) |v| c.analysisDataUpdateCount = v;
    if (patch.information_update_count) |v| c.informationUpdateCount = v;
}

/// The boxed payload pointer of `row` — a row's identity within its
/// database; every variant boxes its payload in the arena (see
/// `pdb.Database.removeRow`).
fn rowPayloadKey(row: *const pdb.Row) *const anyopaque {
    return switch (row.*) {
        inline else => |p| @ptrCast(p),
    };
}

/// Whether `path` is a file directly inside directory `dir`.
fn isUnderDir(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and
        path.len > dir.len and
        path[dir.len] == '/';
}

/// The removal predicate context: the track id being removed.
const TrackIdMatch = struct {
    id: u32,
};

fn playlistEntryNamesTrack(ctx: TrackIdMatch, row: *const pdb.Row) bool {
    return switch (row.*) {
        .playlist_entry => |entry| entry.track_id == ctx.id,
        else => false,
    };
}

fn trackTagNamesTrack(ctx: TrackIdMatch, row: *const pdb.Row) bool {
    return switch (row.*) {
        .track_tag => |junction| junction.track_id == ctx.id,
        else => false,
    };
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
    artists: std.ArrayListUnmanaged(ol.Artist) = .empty,
    albums: std.ArrayListUnmanaged(ol.Album) = .empty,
    genres: std.ArrayListUnmanaged(ol.Genre) = .empty,
    labels: std.ArrayListUnmanaged(ol.Label) = .empty,
    keys: std.ArrayListUnmanaged(ol.Key) = .empty,
    images: std.ArrayListUnmanaged(ol.Image) = .empty,
    contents: std.ArrayListUnmanaged(ol.Content) = .empty,
    playlists: std.ArrayListUnmanaged(ol.Playlist) = .empty,
    playlist_pairs: std.ArrayListUnmanaged(OlPlaylistPair) = .empty,
    my_tags: std.ArrayListUnmanaged(ol.MyTag) = .empty,
    /// Pending `myTag_content` rows — the row type itself, since the
    /// junction carries nothing the insert derives.
    my_tag_pairs: std.ArrayListUnmanaged(ol.MyTagContent) = .empty,
    /// Complete replacement rows for `content` rows already on disk,
    /// patched by `updateTrack` and rewritten by the next
    /// `save` (see `ol.Writer.updateAllContents`). At most one per
    /// content id.
    content_updates: std.ArrayListUnmanaged(ol.Content) = .empty,
    /// Content ids `removeTrack` cascade-deletes at the next `save`.
    content_deletes: std.ArrayListUnmanaged(i64) = .empty,
    /// pdb track id -> OL content id, recorded wherever the two sides
    /// are first seen joined (by path), so a later resolution — after a
    /// rename has moved the path on — still finds the OL row.
    content_bridge: std.AutoHashMapUnmanaged(u32, i64) = .empty,

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
    playlist_child_counts: std.AutoHashMapUnmanaged(i64, IdMint(i64)) = .empty,
    /// Bridged ext tag ids whose `myTag` row exists or pends.
    my_tag_ids: std.AutoHashMapUnmanaged(i64, void) = .empty,

    /// Next id for a minted artist row — the lyricist resolution, the
    /// one mirrored row with no pdb id to bridge. Seeded at
    /// `first_minted_artist_id` and raised past every artist id an
    /// existing db carries.
    next_minted_artist_id: IdMint(i64) = .{ .next = first_minted_artist_id },

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
            store.my_tag_pairs.items.len > 0 or
            store.content_updates.items.len > 0 or
            store.content_deletes.items.len > 0;
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
fn olDrain(w: ol.Writer, list: anytype) ol.SqlError!void {
    try w.insertAll(list.items);
    list.clearRetainingCapacity();
}

/// Drains `list` through one `Writer.addAllToPlaylist` batch: the dense
/// 1-based `sequenceNo`s are derived inside the transaction, continuing
/// past rows already on disk. The same clear-only-after-commit contract
/// as `olDrain`.
fn olDrainPlaylistPairs(w: ol.Writer, list: anytype) ol.SqlError!void {
    try w.addAllToPlaylist(list.items);
    list.clearRetainingCapacity();
}

/// Drains queued whole-row content updates through one
/// `Writer.updateAllContents` batch — the same clear-only-after-commit
/// contract as `olDrain`.
fn olDrainUpdates(w: ol.Writer, list: anytype) ol.SqlError!void {
    try w.updateAllContents(list.items);
    list.clearRetainingCapacity();
}

/// Drains queued content cascade-deletes through one
/// `Writer.deleteContentCascadeAll` batch — the same
/// clear-only-after-commit contract as `olDrain`.
fn olDrainContentDeletes(w: ol.Writer, list: anytype) ol.SqlError!void {
    try w.deleteContentCascadeAll(list.items);
    list.clearRetainingCapacity();
}

/// Queues `row` as the pending replacement of its content row — at most
/// one update per content id, so consecutive patches of one track
/// compose instead of stacking.
fn queueContentUpdate(store: *OlStore, row: ol.Content) std.mem.Allocator.Error!void {
    for (store.content_updates.items) |*queued| {
        if (queued.content_id == row.content_id) {
            queued.* = row;
            return;
        }
    }
    try store.content_updates.append(store.arena.allocator(), row);
}

/// Queues `content_id` for the cascade delete at the next `save`;
/// double-queuing is a no-op.
fn queueContentDelete(store: *OlStore, content_id: i64) std.mem.Allocator.Error!void {
    for (store.content_deletes.items) |queued| {
        if (queued == content_id) return;
    }
    try store.content_deletes.append(store.arena.allocator(), content_id);
}

/// Records the pdb-track-id to OL-content-id bridge.
fn recordBridge(
    store: *OlStore,
    track_id: u32,
    content_id: i64,
) std.mem.Allocator.Error!void {
    try store.content_bridge.put(store.arena.allocator(), track_id, content_id);
}

/// Drops every junction row naming `content_id`, in place — the pending
/// lists keep naming exactly the rows the db lacks.
fn dropJunctionsForContent(list: anytype, content_id: i64) void {
    var kept: usize = 0;
    for (list.items) |item| {
        const cid = switch (@TypeOf(item.content_id)) {
            i64 => item.content_id,
            ?i64 => item.content_id orelse continue,
            else => @compileError("unexpected junction id column type"),
        };
        if (cid == content_id) continue;
        list.items[kept] = item;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}

/// Copies `src`, duping every text column, so the copy outlives the
/// library snapshot it came from.
fn dupeContent(a: std.mem.Allocator, src: *const ol.Content) std.mem.Allocator.Error!ol.Content {
    var c = src.*;
    inline for (@typeInfo(ol.Content).@"struct".fields) |f| {
        if (f.type == ?[]const u8) {
            if (@field(c, f.name)) |v| @field(c, f.name) = try a.dupe(u8, v);
        }
    }
    return c;
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
/// the pdb-side null convention. An id that exhausts its space fails the
/// scan (see `IdMint`).
fn scanOlStore(
    lib: *const ol.Library,
    store: *OlStore,
) (std.mem.Allocator.Error || error{IdSpaceExhausted})!void {
    const a = store.arena.allocator();
    for (lib.artists) |row| {
        if (row.name) |name|
            try putIfAbsent(&store.artists_by_name, a, try a.dupe(u8, name), row.artist_id);
        try store.next_minted_artist_id.raisePast(row.artist_id);
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
        if (!gop.found_existing) gop.value_ptr.* = .{ .next = 0 };
        // A NULL sequenceNo occupies nothing: the high water stays at 0.
        try gop.value_ptr.raisePast(row.sequenceNo orelse -1);
    }
    for (lib.my_tags) |row| try store.my_tag_ids.put(a, row.myTag_id, {});
}

/// One mirrored `artist` row; see `olNamedRow`.
fn olArtistRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!ol.Artist {
    _ = a;
    return .{ .artist_id = id, .name = name, .nameForSearch = null };
}

/// One mirrored `genre` row; see `olNamedRow`.
fn olGenreRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!ol.Genre {
    _ = a;
    return .{ .genre_id = id, .name = name };
}

/// One mirrored `label` row; see `olNamedRow`.
fn olLabelRow(a: std.mem.Allocator, name: []const u8, id: i64) std.mem.Allocator.Error!ol.Label {
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
/// artist rows).
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
) (std.mem.Allocator.Error || error{IdSpaceExhausted})!?i64 {
    if (name.len == 0) return null;
    if (store.artists_by_name.get(name)) |id| return id;

    const a = store.arena.allocator();
    const owned = try a.dupe(u8, name);
    try store.artists_by_name.ensureUnusedCapacity(a, 1);
    const id = try store.next_minted_artist_id.mint();
    try store.artists.append(a, .{ .artist_id = id, .name = owned, .nameForSearch = null });
    store.artists_by_name.putAssumeCapacity(owned, id);
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
) (std.mem.Allocator.Error || error{IdSpaceExhausted})!void {
    if (store.playlist_ids.contains(id)) return;

    const a = store.arena.allocator();
    var sequence_mint: IdMint(i64) =
        store.playlist_child_counts.get(parent_id) orelse .{ .next = 0 };
    const sequence_no = try sequence_mint.mint();
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
    gop.value_ptr.* = sequence_mint;
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

/// A high-water id counter that cannot overflow: a scan raises it past
/// ids observed in an untrusted database — rejecting an id that exhausts
/// the space instead of saturating past it, which would collide every
/// later mint with the observed row — and the writer mints from it,
/// failing the call when the space runs out instead of wrapping into
/// duplicate or null ids. `maxInt` is the never-minted boundary, so a
/// minted id can never equal one a scan would reject.
pub fn IdMint(comptime Int: type) type {
    return struct {
        /// The next id to mint; every id below it is taken. Ids mint
        /// from 1 (id 0 is the null foreign key) unless the counter
        /// names a 0-based position or sequence instead.
        next: Int = 1,

        const Self = @This();

        /// Raises the high water past `id`, an id observed in an
        /// untrusted database.
        pub fn raisePast(m: *Self, id: Int) error{IdSpaceExhausted}!void {
            if (id == std.math.maxInt(Int)) return error.IdSpaceExhausted;
            m.next = @max(m.next, id + 1);
        }

        /// Returns the next id and advances, or fails when the space is
        /// exhausted. Called before the insert it names: a later failure
        /// may burn an id, never mint a duplicate.
        pub fn mint(m: *Self) error{IdSpaceExhausted}!Int {
            const id = m.next;
            if (id == std.math.maxInt(Int)) return error.IdSpaceExhausted;
            m.next = id + 1;
            return id;
        }
    };
}

/// The writer's cached view of an export: one `IdMint` counter per table
/// it appends to, plus the dedup maps that let later inserts reuse an
/// existing row instead of duplicating it. Everything the state
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
    next_track_id: IdMint(u32) = .{},
    next_artist_id: IdMint(u32) = .{},
    next_album_id: IdMint(u32) = .{},
    next_genre_id: IdMint(u32) = .{},
    next_key_id: IdMint(u32) = .{},
    next_label_id: IdMint(u32) = .{},
    next_artwork_id: IdMint(u32) = .{},
    next_playlist_node_id: IdMint(u32) = .{},
    /// Shared id space for tag categories and leaf tags.
    next_tag_id: IdMint(u32) = .{},
    /// Next `position` for a top-level category (0-based, as on real
    /// exports).
    next_category_position: IdMint(u32) = .{ .next = 0 },
    /// Per-row monotonic counter driving tag `index_shift` (`0x20` per
    /// row, as observed on real exports).
    next_tag_row_index: IdMint(u32) = .{ .next = 0 },

    /// Known track ids, for playlist-membership FK checks.
    track_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// `id -> is_folder`. Root (id 0) is implicit — always a valid
    /// parent, always a folder.
    playlist_nodes: std.AutoHashMapUnmanaged(u32, bool) = .empty,
    /// Next `entry_index` per playlist: `max(entry_index) + 1`, not the
    /// row count, so a reopened export with sparse indices doesn't
    /// collide.
    playlist_entry_counts: std.AutoHashMapUnmanaged(u32, IdMint(u32)) = .empty,
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
    tag_leaf_counts: std.AutoHashMapUnmanaged(u32, IdMint(u32)) = .empty,

    pub fn deinit(state: *WriterState) void {
        state.arena.deinit();
    }
};

/// Error of the writer-state scans: walking a table's page chain hit
/// structural corruption, an allocation failed, or a row carried an id
/// that exhausts its space (see `IdMint`). A table the database doesn't
/// carry is not an error — `rowsOrEmpty` resolves tables up front and
/// scans them as empty; `NoTable` is only in the set because
/// `RowIterator` shares one.
pub const ScanError = error{
    OutOfMemory,
    NoTable,
    PageNotPresent,
    PageOrderViolation,
    UnparsedPage,
    IdSpaceExhausted,
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
    try ctx.state.next_track_id.raisePast(track.id);
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
    counter: *IdMint(u32),
) ScanError!void {
    var it = (try rowsOrEmpty(db, page_type)) orelse return;
    while (try it.next()) |row| {
        const payload = @field(row.*, tag);
        try counter.raisePast(payload.id);
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
    try ctx.state.next_album_id.raisePast(album.id);
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
    try ctx.state.next_key_id.raisePast(key.id);
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
    try ctx.state.next_playlist_node_id.raisePast(node.id);
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
    if (!gop.found_existing) gop.value_ptr.* = .{ .next = 0 };
    try gop.value_ptr.raisePast(entry.entry_index);
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
    try ctx.state.next_tag_id.raisePast(tag.id);
    try ctx.state.next_tag_row_index.raisePast(@as(u32, tag.index_shift) / 0x20);
    if (tag.raw_is_category != 0) {
        try ctx.state.tag_categories.put(ctx.alloc, tag.id, {});
        try ctx.state.next_category_position.raisePast(tag.position);
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
        if (!gop.found_existing) gop.value_ptr.* = .{ .next = 0 };
        try gop.value_ptr.raisePast(tag.position);
    }
}
