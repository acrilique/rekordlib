# Main ideas

  - deal with the pdb and anlz formats manually with zero deps
  - use zig-sqlite plus SQLCipher to deal with the onelibrary format
  - be little opinionated: do not do any media analysis/reencoding/copying, and
  only deal with the aforementioned formats. This means providing info on the
  correct format and/or location of some files like arworks.
  - provide an easy to embed, completely static library that can easily be built
  for any platform
  
## Usage

### Device export

The library provides ways to create and open a Rekordbox USB export. For instance, you could modify a track inside an existing export:

```zig
var ex = rekordlib.device.DeviceExport.open(root, io, alloc);
defer ex.deinit();

var it = try ex.tracks();
defer it.deinit();

var target: ?u32 = null;
while (try it.next()) |t| {
    if (std.mem.eql(u8, t.title, "Some track")) target = t.id;
}
const id = target orelse return error.TrackNotFound;

// TrackPatch fields left null stay untouched; only `title` changes here.
try ex.updateTrack(id, .{ .title = "New title" });

// save() is the only call that writes to disk.
try ex.save();
```

The above code opens a Rekordbox export from `root`, iterates over all tracks to find one by title, and updates its title. Finally, `save` writes the changes back to the export.

You can also create a new export from scratch:

```zig
var ex = try rekordlib.device.DeviceExport.create(root, io, alloc);
defer ex.deinit();

// Waveform columns from decoded PCM: 44.1 kHz stereo f32 in [-1, 1),
// Mono sources must be duplicated to both channels.
var columns = try rekordlib.anlz.buildColumnsFromPcm(alloc, .{ .left = left, .right = right });
defer columns.deinit(alloc);

const period = 60.0 / 126.0 * 44_100.0;
const drop = 5.0 * period;
const beatgrid = [_]rekordlib.anlz.BeatMarker{
    .{ .index = -4, .sample_offset = 0 },
    .{ .index = 1, .sample_offset = drop },
};

var input = try rekordlib.anlz.buildAnlzInput(alloc, .{
    .sample_rate = 44_100,
    .sample_count = sample_count,
    .bpm = 126.0,
    .beatgrid = &beatgrid,
    .main_cue = drop,
}, &columns);
defer input.deinit(alloc);

const track = try ex.addTrack(.{
    .title = "Some track",
    .artist = "Some artist",
    .key = "Am",
    .tempo = 126.0,
    .file_path = "/Contents/Some artist/01 Some track.mp3",
    .filename = "01 Some track.mp3",
    .analysis = &input,
});

const folder = try ex.createPlaylistFolder("Warmup", 0);
const playlist = try ex.createPlaylist("Chill af", folder);
try ex.addTrackToPlaylist(playlist, track.id);

try ex.save();
```

Here we created a new export, used a tool from the library to obtain the anlz waveform data from PCM samples, and added a new track to the export. We also added the track to a playlist.

An alternative to using `buildColumnsFromPcm` is to use the `buildColumnsFromBands` function, which builds the anlz columns from your own 3-band data. This is useful if you have already analyzed the track with another tool and want to use that data instead of passing the PCM samples around. It's an approach closer to what `libdjinterop` does. The input is one `Band` per 150 Hz column of the track:

```zig
const bands = [_]rekordlib.anlz.Band{
    .{ .low = 96, .mid = 160, .high = 20, .peak = 190 },
    .{ .low = 88, .mid = 171, .high = 24, .peak = 195 },
    // ...
};

const columns = try rekordlib.anlz.buildColumnsFromBands(alloc, &bands);
defer columns.deinit(alloc);
```

The result feeds `buildAnlzInput` exactly like `buildColumnsFromPcm`'s does.

### Access to inner formats

You're also able to access and manipulate the inner files of an export directly using lower level APIs. For instance, you can read the `export.pdb` file directly:

```zig
// Layout derives the path of every file in an export from the root.
const layout = rekordlib.device.Layout{ .root = root };
const dir = try std.Io.Dir.cwd().openDir(io, ".", .{});

const pdb_path = try layout.exportPdb(alloc);
defer alloc.free(pdb_path);
const image = try dir.readFileAlloc(io, pdb_path, alloc, .limited(1 << 26));
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
const dat = try dir.readFileAlloc(io, dat_path, alloc, .limited(1 << 24));
defer alloc.free(dat);

var file = try rekordlib.anlz.Anlz.parse(alloc, dat);
defer file.deinit();

if (file.findSection(.beat_grid)) |section| {
    for (section.beat_grid.beats) |beat|
        std.debug.print("{d} ms, {d}.{d:0>2} BPM\n", .{
            beat.time,
            beat.tempo / 100,
            beat.tempo % 100,
        });
}
```

The snippets above only read, but the same tools can be used to write: parse, edit the rows, serialize, then land the image with `rekordlib.device.writeFileAtomic`, so a crash can't leave a half-written database.

Newer exports carry a second database next to the pdb — `exportLibrary.db`, the OneLibrary store — and every `create`d export builds one. `openOL` hands it back, or null when the export carries none. Only compiled in with an sqlcipher backend (see the `-Dol` build option).

```zig
var ex = rekordlib.device.DeviceExport.open(root, io, alloc);
defer ex.deinit();

const lib = (try ex.openOL()) orelse return;

// The join to the pdb side is by device file path: content.path holds
// the same values as the pdb Track rows' file_path.
const content = lib.contentByPath("/Contents/Some artist/01 Some track.mp3") orelse return;

std.debug.print("played {d} times\n", .{content.djPlayCount orelse 0});
```

The `tracks()` iterator already joins these content rows into its views; `openOL` is for the rest of the store — playlists, play histories, hot cue banks, tag trees — and for the columns the pdb lacks (`djPlayCount`, `subtitle`, per-role artist ids, bit depth, ...), with dimension rows reachable through `lib.byId(rekordlib.ol.Artist, id)`.

An export also carries the player's preference files — the four `*SETTING.DAT` under `PIONEER`. `loadSettings` parses them into typed payloads; a missing or unparseable file leaves its field null (old exports genuinely lack some of them):

```zig
var ex = rekordlib.device.DeviceExport.open(root, io, alloc);
defer ex.deinit();

const settings = try ex.loadSettings();

if (settings.my_setting) |s| {
    std.debug.print("quantize {s}, jog mode {s}\n", .{
        @tagName(s.quantize),
        @tagName(s.jog_mode),
    });
}
```

Every preference is a typed enum (`Quantize`, `JogMode`, `Language`, `LcdBrightness`, ...). A `create`d export writes the four defaults at `save()`; there is no handle API to modify them — serialize a payload yourself with `setting.Setting(...)` and write it where `Layout.datPath` points.
