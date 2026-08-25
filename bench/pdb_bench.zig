// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Benchmarks for the hot paths of the pdb module, so optimizations can be
//! compared objectively against the unoptimized code (see `docs/BENCH.md`).
//!
//! Run from the package root:
//!
//!     zig build bench -Doptimize=ReleaseFast
//!
//! Pass benchmark names to run a subset (prefix match), `--iters=N` to
//! override every iteration count, `--fixture=PATH` to parse another file:
//!
//!     zig build bench -Doptimize=ReleaseFast -- build_tracks alloc_pages
//!     zig build bench -Doptimize=ReleaseFast -- serialize --iters=100
//!
//! Every iteration is timed separately; the report shows min, median, and
//! mean, plus a throughput figure derived from the per-iteration workload.
//! Compare runs only within the same build mode and machine; the min is the
//! most noise-resistant figure.

const std = @import("std");
const pdb = @import("rekordlib").pdb;

const default_fixture = "testdata/pdb/num_rows/export.pdb";

var iters_override: ?usize = null;
var fixture_path: []const u8 = default_fixture;

/// One benchmark run: per-iteration durations (caller owns the slice) plus
/// the workload size each iteration processes, for the throughput figure,
/// and the peak arena capacity observed, for the memory figure.
const Timing = struct {
    durations: []u64,
    count: usize = 0,
    unit: []const u8 = "",
    arena_bytes: usize = 0,
};

/// Monotonic stopwatch over the project's timing convention
/// (`std.Io.Timestamp.now(io, .awake)`).
const Stopwatch = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn startClock(io: std.Io) Stopwatch {
        return .{ .io = io, .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn read(clock: Stopwatch) u64 {
        const end = std.Io.Timestamp.now(clock.io, .awake);
        return @intCast(clock.start.durationTo(end).nanoseconds);
    }
};

fn fmtDuration(buf: []u8, ns: u64) []const u8 {
    const value: f64 = @floatFromInt(ns);
    return if (ns >= std.time.ns_per_s)
        std.fmt.bufPrint(buf, "{d:.3} s", .{value / std.time.ns_per_s}) catch unreachable
    else if (ns >= std.time.ns_per_ms)
        std.fmt.bufPrint(buf, "{d:.3} ms", .{value / std.time.ns_per_ms}) catch unreachable
    else if (ns >= std.time.ns_per_us)
        std.fmt.bufPrint(buf, "{d:.3} µs", .{value / std.time.ns_per_us}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d} ns", .{value}) catch unreachable;
}

fn fmtThroughput(buf: []u8, t: Timing, ns: u64) []const u8 {
    if (t.count == 0 or ns == 0) return "";
    const rate = @as(f64, @floatFromInt(t.count)) /
        (@as(f64, @floatFromInt(ns)) / std.time.ns_per_s);
    const scaled: struct { f: f64, s: []const u8 } = if (rate >= 1e6)
        .{ .f = rate / 1e6, .s = "M" }
    else if (rate >= 1e3)
        .{ .f = rate / 1e3, .s = "K" }
    else
        .{ .f = rate, .s = "" };
    return std.fmt.bufPrint(buf, "{d:.2} {s}{s}/s", .{ scaled.f, scaled.s, t.unit }) catch unreachable;
}

fn fmtBytes(buf: []u8, bytes: usize) []const u8 {
    const value: f64 = @floatFromInt(bytes);
    return if (bytes >= 1024 * 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.2} GB", .{value / (1024 * 1024 * 1024)}) catch unreachable
    else if (bytes >= 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} MB", .{value / (1024 * 1024)}) catch unreachable
    else if (bytes >= 1024)
        std.fmt.bufPrint(buf, "{d:.1} KB", .{value / 1024}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
}

fn report(name: []const u8, t: Timing) void {
    const ds = t.durations;
    std.mem.sort(u64, ds, {}, std.sort.asc(u64));
    const min = ds[0];
    const med = if (ds.len % 2 == 1)
        ds[ds.len / 2]
    else
        (ds[ds.len / 2 - 1] + ds[ds.len / 2]) / 2;
    var sum: u64 = 0;
    for (ds) |d| sum += d;
    const mean = sum / ds.len;

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    var b4: [48]u8 = undefined;
    var b5: [16]u8 = undefined;
    std.debug.print("{s:<26} {d:>5}  {s:>10}  {s:>10}  {s:>10}  {s:<18}  {s}\n", .{
        name,
        ds.len,
        fmtDuration(b1[0..], min),
        fmtDuration(b2[0..], med),
        fmtDuration(b3[0..], mean),
        if (t.arena_bytes > 0) fmtBytes(b5[0..], t.arena_bytes) else "",
        fmtThroughput(b4[0..], t, med),
    });
}

// --- workload builders -------------------------------------------------------

/// Adds one realistic track row: a dozen populated strings, plausible fixed
/// fields, and the minimum-size padding a device export needs.
fn addTrack(db: *pdb.Database, i: usize) !void {
    const a = db.arena.allocator();
    var title_buf: [32]u8 = undefined;
    var name_buf: [32]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "Benchmark Track {d:0>6}", .{i});
    const filename = try std.fmt.bufPrint(&name_buf, "track{d:0>6}.mp3", .{i});
    const file_path = try std.fmt.bufPrint(&path_buf, "/benchmark/artist{d:0>2}/album{d:0>3}/{s}", .{ i % 64, i % 512, filename });

    var track = pdb.Track{
        .id = @intCast(i + 1),
        .artist_id = @intCast(i % 500 + 1),
        .album_id = @intCast(i % 2000 + 1),
        .genre_id = @intCast(i % 8 + 1),
        .key_id = @intCast(i % 24 + 1),
        .bitrate = 320,
        .sample_rate = 44100,
        .duration = 60 + @as(u16, @intCast(i % 300)),
        .tempo = 12000 + @as(u32, @intCast(i % 4000)),
        .track_number = @intCast(i % 16 + 1),
        .disc_number = 1,
        .year = 2024,
        .rating = @intCast(i % 6),
        .file_type = .mp3,
        .offsets = .{ .inner = .{
            .title = try pdb.DeviceSQLString.fromUtf8(a, title),
            .isrc = try pdb.DeviceSQLString.fromIsrc(a, "GBAYE6700149"),
            .filename = try pdb.DeviceSQLString.fromUtf8(a, filename),
            .file_path = try pdb.DeviceSQLString.fromUtf8(a, file_path),
            .date_added = try pdb.DeviceSQLString.fromUtf8(a, "2024-01-15"),
            .release_date = try pdb.DeviceSQLString.fromUtf8(a, "2024-01-15"),
            .analyze_path = try pdb.DeviceSQLString.fromUtf8(a, "/PIONEER/USBANLZ/bench"),
            .analyze_date = try pdb.DeviceSQLString.fromUtf8(a, "2024-01-15"),
            .comment = pdb.DeviceSQLString.empty(),
        } },
    };
    try pdb.padTrackCommentToMinimum(&track, a);
    const boxed = try a.create(pdb.Track);
    boxed.* = track;
    var row = pdb.Row{ .track = boxed };
    _ = try db.addRow(&row);
}

fn addHistoryEntry(db: *pdb.Database, i: usize) !void {
    const entry = try db.arena.allocator().create(pdb.HistoryEntry);
    entry.* = .{
        .track_id = @intCast(i + 1),
        .playlist_id = 1,
        .entry_index = @intCast(i),
    };
    var row = pdb.Row{ .history_entry = entry };
    _ = try db.addRow(&row);
}

/// Creates a database with the standard tables and default rows.
fn newDatabase(alloc: std.mem.Allocator) !pdb.Database {
    var db = try pdb.Database.create(alloc, .plain, &pdb.standard_table_page_types);
    errdefer db.deinit();
    try pdb.insertDefaultColors(&db);
    try pdb.insertDefaultColumns(&db);
    try pdb.insertDefaultMenus(&db);
    return db;
}

fn readFixture(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, fixture_path, alloc, .limited(256 << 20)) catch |err| {
        std.debug.print("error: cannot read fixture '{s}': {t}\n", .{ fixture_path, err });
        return err;
    };
}

// --- benchmarks ---------------------------------------------------------------

var sink: usize = 0;

/// addRow of `n` tracks: string building, row commit, and fresh page
/// allocation as pages fill up.
fn benchBuildTracks(alloc: std.mem.Allocator, io: std.Io, iters: usize, n: usize) !Timing {
    var durations = std.ArrayList(u64).empty;
    var arena: usize = 0;
    for (0..iters) |_| {
        const clock = Stopwatch.startClock(io);
        var db = try newDatabase(alloc);
        for (0..n) |i| try addTrack(&db, i);
        sink +%= db.pages.len;
        const dur = clock.read();
        arena = @max(arena, db.arena.queryCapacity());
        db.deinit();
        try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = n, .unit = "rows", .arena_bytes = arena };
}

/// addRow of `n` twelve-byte history entries: the many-small-rows-per-page
/// workload.
fn benchBuildEntries(alloc: std.mem.Allocator, io: std.Io, iters: usize, n: usize) !Timing {
    var durations = std.ArrayList(u64).empty;
    var arena: usize = 0;
    for (0..iters) |_| {
        const clock = Stopwatch.startClock(io);
        var db = try newDatabase(alloc);
        for (0..n) |i| try addHistoryEntry(&db, i);
        sink +%= db.pages.len;
        const dur = clock.read();
        arena = @max(arena, db.arena.queryCapacity());
        db.deinit();
        try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = n, .unit = "rows", .arena_bytes = arena };
}

/// `n` consecutive allocDataPage calls, each followed by a small arena
/// allocation: isolates the database page-array growth from row insertion.
/// The interleaved allocation matters — an arena can only extend the pages
/// array in place while it is the most recent allocation, and real workloads
/// (row strings, gap pages) always allocate in between, forcing the copy
/// path this benchmark measures. Stress workload; real databases allocate
/// pages only as tables fill.
fn benchAllocPages(alloc: std.mem.Allocator, io: std.Io, iters: usize, n: usize) !Timing {
    var durations = std.ArrayList(u64).empty;
    var arena: usize = 0;
    for (0..iters) |_| {
        const clock = Stopwatch.startClock(io);
        var db = try newDatabase(alloc);
        for (0..n) |_| {
            sink +%= try db.allocDataPage(.tracks);
            // Leaked into the arena on purpose, like real row strings: a
            // freed-most-recent allocation would rewind the arena and
            // restore the in-place path.
            _ = try db.arena.allocator().alloc(u8, 64);
        }
        const dur = clock.read();
        arena = @max(arena, db.arena.queryCapacity());
        db.deinit();
        try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = n, .unit = "pages", .arena_bytes = arena };
}

/// serialize of a prebuilt n-track database, isolated from construction.
fn benchSerialize(alloc: std.mem.Allocator, io: std.Io, iters: usize, n: usize) !Timing {
    var db = try newDatabase(alloc);
    defer db.deinit();
    for (0..n) |i| try addTrack(&db, i);
    const arena = db.arena.queryCapacity();

    var durations = std.ArrayList(u64).empty;
    var count: usize = 0;
    for (0..iters + 1) |i| { // +1: one untimed warmup
        const clock = Stopwatch.startClock(io);
        const bytes = try db.serialize(alloc);
        const dur = clock.read();
        sink +%= bytes.len;
        if (i > 0) try durations.append(alloc, dur);
        if (count == 0) count = bytes.len;
        alloc.free(bytes);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = count, .unit = "bytes", .arena_bytes = arena };
}

/// Database.parse of the fixture, isolated. Control benchmark: parsing is
/// untouched by the page-growth optimizations.
fn benchParseFixture(alloc: std.mem.Allocator, io: std.Io, iters: usize) !Timing {
    const bytes = try readFixture(io, alloc);
    defer alloc.free(bytes);

    var durations = std.ArrayList(u64).empty;
    var arena: usize = 0;
    for (0..iters + 1) |i| { // +1: one untimed warmup
        const clock = Stopwatch.startClock(io);
        var db = try pdb.Database.parse(alloc, bytes, .plain);
        const dur = clock.read();
        sink +%= db.pages.len;
        arena = @max(arena, db.arena.queryCapacity());
        db.deinit();
        if (i > 0) try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = bytes.len, .unit = "bytes", .arena_bytes = arena };
}

/// parse + serialize of the fixture: the whole-image roundtrip.
fn benchRoundtripFixture(alloc: std.mem.Allocator, io: std.Io, iters: usize) !Timing {
    const bytes = try readFixture(io, alloc);
    defer alloc.free(bytes);

    var durations = std.ArrayList(u64).empty;
    var arena: usize = 0;
    for (0..iters + 1) |i| { // +1: one untimed warmup
        const clock = Stopwatch.startClock(io);
        var db = try pdb.Database.parse(alloc, bytes, .plain);
        const out = try db.serialize(alloc);
        const dur = clock.read();
        sink +%= out.len;
        arena = @max(arena, db.arena.queryCapacity());
        db.deinit();
        alloc.free(out);
        if (i > 0) try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = bytes.len, .unit = "bytes", .arena_bytes = arena };
}

/// eql of two equal fixture databases: compares every page, row, and string.
fn benchEqlFixture(alloc: std.mem.Allocator, io: std.Io, iters: usize) !Timing {
    const bytes = try readFixture(io, alloc);
    defer alloc.free(bytes);
    var db1 = try pdb.Database.parse(alloc, bytes, .plain);
    defer db1.deinit();
    var db2 = try pdb.Database.parse(alloc, bytes, .plain);
    defer db2.deinit();

    var durations = std.ArrayList(u64).empty;
    for (0..iters + 1) |i| { // +1: one untimed warmup
        const clock = Stopwatch.startClock(io);
        const equal = db1.eql(&db2);
        const dur = clock.read();
        sink +%= @intFromBool(equal);
        if (i > 0) try durations.append(alloc, dur);
    }
    return .{ .durations = try durations.toOwnedSlice(alloc), .count = bytes.len, .unit = "bytes", .arena_bytes = db1.arena.queryCapacity() };
}

// --- driver --------------------------------------------------------------------

const Case = struct {
    name: []const u8,
    size: usize = 0,
    iters: usize,
    run: *const fn (alloc: std.mem.Allocator, io: std.Io, iters: usize, size: usize) anyerror!Timing,
};

fn sizedCase(
    comptime f: fn (std.mem.Allocator, std.Io, usize, usize) anyerror!Timing,
) *const fn (std.mem.Allocator, std.Io, usize, usize) anyerror!Timing {
    return struct {
        fn wrapper(alloc: std.mem.Allocator, io: std.Io, iters: usize, size: usize) anyerror!Timing {
            return f(alloc, io, iters, size);
        }
    }.wrapper;
}

fn fixtureOnly(
    comptime f: fn (std.mem.Allocator, std.Io, usize) anyerror!Timing,
) *const fn (std.mem.Allocator, std.Io, usize, usize) anyerror!Timing {
    return struct {
        fn wrapper(alloc: std.mem.Allocator, io: std.Io, iters: usize, size: usize) anyerror!Timing {
            _ = size;
            return f(alloc, io, iters);
        }
    }.wrapper;
}

/// Cases sized so the *unoptimized* code stays within a few GB of peak
/// arena memory: grow-by-one reallocation under an arena abandons the old
/// buffer, so its cost is quadratic in both time and peak memory. Larger
/// sizes belong behind the fixed code.
const cases = [_]Case{
    .{ .name = "build_tracks:500", .size = 500, .iters = 5, .run = sizedCase(benchBuildTracks) },
    .{ .name = "build_tracks:2000", .size = 2000, .iters = 3, .run = sizedCase(benchBuildTracks) },
    .{ .name = "build_tracks:8000", .size = 8000, .iters = 3, .run = sizedCase(benchBuildTracks) },
    .{ .name = "build_tracks:16000", .size = 16000, .iters = 3, .run = sizedCase(benchBuildTracks) },
    .{ .name = "build_entries:1000", .size = 1000, .iters = 5, .run = sizedCase(benchBuildEntries) },
    .{ .name = "build_entries:5000", .size = 5000, .iters = 3, .run = sizedCase(benchBuildEntries) },
    .{ .name = "build_entries:20000", .size = 20000, .iters = 3, .run = sizedCase(benchBuildEntries) },
    .{ .name = "build_entries:40000", .size = 40000, .iters = 3, .run = sizedCase(benchBuildEntries) },
    .{ .name = "alloc_pages:500", .size = 500, .iters = 5, .run = sizedCase(benchAllocPages) },
    .{ .name = "alloc_pages:1000", .size = 1000, .iters = 5, .run = sizedCase(benchAllocPages) },
    .{ .name = "alloc_pages:2000", .size = 2000, .iters = 5, .run = sizedCase(benchAllocPages) },
    .{ .name = "serialize:8000tracks", .size = 8000, .iters = 30, .run = sizedCase(benchSerialize) },
    .{ .name = "serialize:16000tracks", .size = 16000, .iters = 15, .run = sizedCase(benchSerialize) },
    .{ .name = "parse_fixture", .iters = 10, .run = fixtureOnly(benchParseFixture) },
    .{ .name = "roundtrip_fixture", .iters = 5, .run = fixtureOnly(benchRoundtripFixture) },
    .{ .name = "eql_fixture", .iters = 50, .run = fixtureOnly(benchEqlFixture) },
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.skip(); // program name
    var filters = std.ArrayList([]const u8).empty;
    defer filters.deinit(alloc);
    while (args_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--iters=")) {
            iters_override = std.fmt.parseInt(usize, arg["--iters=".len..], 10) catch 1;
        } else if (std.mem.startsWith(u8, arg, "--fixture=")) {
            fixture_path = arg["--fixture=".len..];
        } else try filters.append(alloc, try alloc.dupe(u8, arg));
    }

    if (@import("builtin").mode != .ReleaseFast) {
        std.debug.print(
            "warning: built in {s} mode; use -Doptimize=ReleaseFast for meaningful numbers\n\n",
            .{@tagName(@import("builtin").mode)},
        );
    }
    std.debug.print("pdb benchmarks | mode={s} | sizes: Row={d} Track={d} RowAtOffset={d} Page={d} PageSlot={d}\n\n", .{
        @tagName(@import("builtin").mode),
        @sizeOf(pdb.Row),
        @sizeOf(pdb.Track),
        @sizeOf(pdb.RowAtOffset),
        @sizeOf(pdb.Page),
        @sizeOf(pdb.PageSlot),
    });
    std.debug.print("{s:<26} {s:>5}  {s:>10}  {s:>10}  {s:>10}  {s:<18}  {s}\n", .{
        "benchmark", "iters", "min", "median", "mean", "arena peak", "throughput",
    });
    std.debug.print("{s:-<110}\n", .{""});

    for (cases) |case| {
        const selected = filters.items.len == 0 or blk: {
            for (filters.items) |filter| {
                if (std.mem.startsWith(u8, case.name, filter)) break :blk true;
            }
            break :blk false;
        };
        if (!selected) continue;
        const iters = iters_override orelse case.iters;
        const timing = try case.run(alloc, io, iters, case.size);
        defer alloc.free(timing.durations);
        report(case.name, timing);
    }
    for (filters.items) |filter| alloc.free(filter);
    std.mem.doNotOptimizeAway(sink);
    if (@import("builtin").os.tag == .linux) {
        const status = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/status", alloc, .limited(1 << 16)) catch return;
        defer alloc.free(status);
        const needle = "VmHWM:";
        const line = std.mem.indexOf(u8, status, needle) orelse return;
        const end = std.mem.indexOfPos(u8, status, line, "\n") orelse status.len;
        std.debug.print("\nprocess peak RSS: {s}\n", .{std.mem.trim(u8, status[line + needle.len .. end], " \t")});
    }
}
