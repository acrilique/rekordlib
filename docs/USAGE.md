# Usage

All snippets assume `root` (the export's directory, as a host path), `io: std.Io`, and `alloc: std.mem.Allocator` in scope.

## Device export

The library provides ways to create and open a Rekordbox USB export. For instance, you could modify a track inside an existing export:

```zig
var ex = try rekordlib.device_export.DeviceExport.open(root, io, alloc);
defer ex.deinit();

// Titles are not unique (file_path is the dedup key — trackByPath
// resolves it); trackByTitle returns the first one, as a record that
// owns its strings.
var rec = (try ex.trackByTitle("Some track")) orelse return error.TrackNotFound;
defer rec.deinit();

// TrackPatch fields left null stay untouched; only `title` changes here.
try ex.updateTrack(rec.view.id, .{ .title = "New title" });

// save() is the only call that writes to disk.
try ex.save();
```

The above code opens a Rekordbox export from `root`, finds a track by title, and updates its title. Finally, `save` writes the changes back to the export. `tracks()` iterates the same views when you need them all — a view's strings live until the iterator's next `next` call (dupe what must outlive it), and mutating the export invalidates the iterator.

Renaming goes through the same patch: a non-null `file_path` in `updateTrack` renames the track, and `save` carries the analysis along — the ANLZ siblings are re-serialized into the USBANLZ folder the new path hashes to (players recompute the location from the path hash, not from the database) and the old folder is deleted.

`save` lands everything, in an order a crash cannot corrupt: setting files, the default directory tree (created exports), queued ANLZ files, relocated ANLZ, `exportExt.pdb`, the OneLibrary db, and `export.pdb` last — a crash leaves the old index naming a consistent export. A failed save keeps its queues for a retry.

A track can also be removed:

```zig
// The analysis directory is kept by default — another track's path may
// hash onto it; pass .{ .delete_analysis_files = true } to delete it too.
try ex.removeTrack(id, .{});
```

You can also create a new export from scratch:

```zig
var ex = try rekordlib.DeviceExport.create(root, io, alloc);
defer ex.deinit();

// Waveform columns from decoded PCM: f32 in [-1, 1) at 44 100 Hz — the
// only rate Rekordbox's analysis supports. `.mono` is duplicated to both
// channels on the fly; `.interleaved` can also be passed.
var columns = try rekordlib.anlz.buildColumnsFromPcm(
    alloc,
    .{ .planar = .{ .left = left, .right = right } },
);
defer columns.deinit(alloc);

const period = 60.0 / 126.0 * 44_100.0;
const drop = 5.0 * period;
// Beat numbers may go negative — Rekordbox grids start at -4.
const beatgrid = [_]rekordlib.anlz.BeatMarker{
    .{ .index = -4, .sample_offset = 0 },
    .{ .index = 1, .sample_offset = drop },
};

var input = try rekordlib.anlz.buildAnalysis(alloc, .{
    .sample_rate = 44_100,
    .sample_count = sample_count,
    .tempo = 126.0, // null derives the tempo per grid segment
    .beatgrid = &beatgrid,
    .main_cue = drop,
    .cues = &.{.{ .hot_cue = 1, .sample_offset = drop, .label = "Drop" }},
}, &columns);
defer input.deinit(alloc);

const track = try ex.addTrack(.{
    .title = "Some track",
    .artist = "Some artist",
    .key = "Am",
    .tempo = 126.0,
    // filename defaults to the basename of file_path.
    .file_path = "/Contents/Some artist/01 Some track.mp3",
    // Borrowed for the call only: the ANLZ files are serialized right
    // away, so `input` may be freed once addTrack returns.
    .analysis = &input,
});

const folder = try ex.createPlaylistFolder("Warmup", .root);
const playlist = try ex.createPlaylist("Chill af", folder);
try ex.addTrackToPlaylist(playlist, track.id);

try ex.save();
```

Here we created a new export, used `buildColumnsFromPcm` to obtain the anlz waveform data from PCM samples, and added a new track to the export. We also added the track to a playlist. The audio file itself is yours to place — `addTrack` only writes the database rows and the ANLZ files. Adding a `file_path` the export already carries does not duplicate it: the existing track comes back, with `is_new = false` in the outcome.

The `buildColumnsFromPcm` function does give you a very good approximation to what Rekordbox would compute; the DSP pipeline it invokes was implemented through black-box reverse engineering plus a few rounds of AI assisted static analysis of the rekordbox binary using ghidra. It has helped me get a better idea of what the different sections of the ANLZ files actually mean, and I intend to contribute this information to the Pioneer reverse engineering community.

An alternative to using `buildColumnsFromPcm` is to use the `buildColumnsFromBands` function, which builds the anlz columns from your own 3-band data. This is useful if you have already analyzed the track with another tool and want to use that data instead of passing the PCM samples around. It's an approach closer to what `libdjinterop` does. The input is one `Band` per 150 Hz column of the track — low/mid/high band energies plus an optional overall peak, each 0-255:

```zig
const bands = [_]rekordlib.anlz.Band{
    .{ .low = 96, .mid = 160, .high = 20, .peak = 190 },
    .{ .low = 88, .mid = 171, .high = 24, .peak = 195 },
    // ...
};

const columns = try rekordlib.anlz.buildColumnsFromBands(alloc, &bands);
defer columns.deinit(alloc);
```

The result feeds `buildAnalysis` exactly like `buildColumnsFromPcm`'s does. Rolling your own DSP pipeline means filling a `WaveformColumns` (or a whole `Analysis`) yourself.

Tags live in the tag database (`exportExt.pdb`), which loads lazily on first use:

```zig
const category = try ex.createTagCategory("Mood");
try ex.addTagsToTrack(track.id, category, &.{ "Warm-up", "Vocal" });
```

## OneLibrary

Newer exports carry a second database next to the pdb — `exportLibrary.db`, the OneLibrary store — and every `create`d export builds one. `openOneLibrary` hands it back, or null when the export carries none. Only compiled in with an sqlcipher backend (`-Donelibrary=vendored-sqlcipher` or `=system-sqlcipher`; see the README).

```zig
var ex = try rekordlib.device_export.DeviceExport.open(root, io, alloc);
defer ex.deinit();

const lib = (try ex.openOneLibrary()) orelse return;

// The join to the pdb side is by device file path: content.path holds
// the same values as the pdb Track rows' file_path.
const content = lib.contentByPath("/Contents/Some artist/01 Some track.mp3") orelse return;

std.debug.print("played {d} times\n", .{content.djPlayCount orelse 0});
```

The `tracks()` iterator already joins these content rows into its views; `openOneLibrary` is for the rest of the store — playlists, play histories, hot cue banks, tag trees — and for the columns the pdb lacks (`djPlayCount`, `subtitle`, per-role artist ids, bit depth, ...), with dimension rows reachable through `lib.byId(rekordlib.onelibrary.Artist, id)`.

An export with no `export.pdb` at all (an OL-only export) works too: every handle method resolves the database it goes through — the pdb when present, else the OL store (in `-Donelibrary` builds) — so `tracks()` iterates `content` rows and the mutating calls land on them. A root carrying neither database fails with `DatabaseNotFound`. Views say which side they joined through their `source` field (`pdb_only` or `pdb_and_ol`).

## Settings

An export also carries the player's preference files — the four `*SETTING.DAT` under `PIONEER`. `loadSettings` parses them into typed payloads; a missing or unparseable file leaves its field null (old exports genuinely lack some of them):

```zig
var ex = try rekordlib.device_export.DeviceExport.open(root, io, alloc);
defer ex.deinit();

const settings = try ex.loadSettings();

if (settings.my_setting) |s| {
    std.debug.print("quantize {s}, jog mode {s}\n", .{
        @tagName(s.quantize),
        @tagName(s.jog_mode),
    });
}
```

Every preference is a typed enum (`Quantize`, `JogMode`, `Language`, `LcdBrightness`, ...). Writes go through `writeSettings`, the write side of `loadSettings`, with `updateTrack`'s patch shape: a null field leaves that file untouched, and a patch names only the values that change, merged onto the file's current value (a previous patch, the disk copy, or the Rekordbox default). Brand/software/version strings and the checksum are the library's, and the write lands at `save`.

```zig
try ex.writeSettings(.{ .my_setting = .{ .jog_mode = .cdj } });
```

`wholeSetting(payload)` covers the load-modify-write form — every field set, from a payload you built or edited yourself. A `create`d export writes the four defaults at `save()`.

## Low level access to inner formats

You're also able to access and manipulate the inner files of an export directly using lower level APIs. For instance, you can read the `export.pdb` file directly:

```zig
// Layout derives the path of every file in an export from the root.
const layout = rekordlib.device_export.Layout{ .root = root };
const dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
defer dir.close(io);

// pdb_limit / anlz_limit: the writer's own size caps, published for
// this manual path.
const pdb_path = try layout.exportPdb(alloc);
defer alloc.free(pdb_path);
const image = try dir.readFileAlloc(io, pdb_path, alloc, rekordlib.device_export.pdb_limit);
defer alloc.free(image);

var db = try rekordlib.pdb.Database.parse(alloc, image, .plain);
defer db.deinit();

var it = try db.rows(.tracks);
while (try it.next()) |row| {
    const track = row.track; // a raw pdb.Track: foreign-key ids, format strings...
    std.debug.print("#{d}: {d}.{d:0>2} BPM\n", .{
        track.id,
        track.tempo / 100,
        track.tempo % 100,
    });
}
```

The same goes for the per-track analysis files, whose location derives from the audio path (players recompute it from the path hash, not from the database):

```zig
const dat_path = try layout.anlzDatFile(alloc, "/Contents/Some artist/01 Some track.mp3");
defer alloc.free(dat_path);
const dat = try dir.readFileAlloc(io, dat_path, alloc, rekordlib.device_export.anlz_limit);
defer alloc.free(dat);

var file = try rekordlib.anlz.Anlz.parse(alloc, dat);
defer file.deinit();

if (file.findSection(.beat_grid)) |section| {
    for (section.beats) |beat|
        std.debug.print("{d} ms, {d}.{d:0>2} BPM\n", .{
            beat.time,
            beat.tempo / 100,
            beat.tempo % 100,
        });
}
```

The snippets above only read, but the same tools can be used to write: parse, edit the rows, serialize, then land the image with `rekordlib.device_export.writeFileAtomic`, so a crash can't leave a half-written database.
