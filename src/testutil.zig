// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Helpers shared by the module test suites.

const std = @import("std");
const testing = std.testing;

/// Runs `roundtrip` on every `testdata` fixture whose basename starts with
/// `prefix` and checks that it re-serializes byte-identical, with at least
/// `min_count` files found. `roundtrip` parses `input` and returns the
/// serialized bytes; the caller of this function frees them. A fixture that
/// fails to parse is reported with its path and error before the error is
/// returned.
pub fn expectFixturesRoundtrip(
    comptime roundtrip: fn (alloc: std.mem.Allocator, input: []const u8) anyerror![]u8,
    comptime prefix: []const u8,
    min_count: usize,
) !void {
    const alloc = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "testdata", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, prefix)) continue;

        const input = try dir.readFileAlloc(io, entry.path, alloc, std.Io.Limit.limited(1 << 20));
        defer alloc.free(input);
        const output = roundtrip(alloc, input) catch |err| {
            std.debug.print("failing fixture: {s} ({t})\n", .{ entry.path, err });
            return err;
        };
        defer alloc.free(output);
        if (!std.mem.eql(u8, input, output)) std.debug.print("mismatching fixture: {s}\n", .{entry.path});
        try testing.expectEqualSlices(u8, input, output);
        count += 1;
    }
    try testing.expect(count >= min_count);
}
