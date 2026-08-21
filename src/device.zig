// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! On-disk layout of a Rekordbox device export: where `export.pdb`,
//! `exportExt.pdb`, the `*SETTING.DAT` files and the `PIONEER`/`USBANLZ`/
//! `Contents` directories live relative to the device root.
//!
//! Ported from rekordcrate's `src/device/layout.rs`.

const std = @import("std");

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
        const h = try pathHash(audio_path);
        const p_folder = try std.fmt.allocPrint(alloc, "P{X:0>3}", .{h.p_value});
        defer alloc.free(p_folder);
        const leaf_folder = try std.fmt.allocPrint(alloc, "{X:0>8}", .{h.hash});
        defer alloc.free(leaf_folder);
        return std.fs.path.join(alloc, &.{ l.root, "PIONEER", "USBANLZ", p_folder, leaf_folder });
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

/// Device-relative path stored in the pdb `analyze_path` column: the `.DAT`
/// the player loads first; sibling `.EXT`/`.2EX` are found by extension
/// substitution on the same stem. The path is keyed by the audio file's
/// device-relative path (with a leading slash), matching what Pioneer
/// hardware recomputes — see `pathHash`.
pub fn anlzDevicePath(alloc: std.mem.Allocator, audio_path: []const u8) PathError![]u8 {
    const h = try pathHash(audio_path);
    return std.fmt.allocPrint(
        alloc,
        "/PIONEER/USBANLZ/P{X:0>3}/{X:0>8}/ANLZ0000.DAT",
        .{ h.p_value, h.hash },
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
