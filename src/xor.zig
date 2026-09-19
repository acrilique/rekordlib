// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Repeating-key XOR cipher used by Rekordbox to obfuscate data (for example
//! the song-structure section of ANLZ files).
//!
//! Ported from rekordcrate's `src/xor.rs`.
//!
//! XOR is self-inverse, so the same [apply](#rekordlib.xor.apply) covers
//! both directions.

const std = @import("std");

/// XOR `buf` in place with `key`, repeating the key from the start. An empty
/// key leaves `buf` unchanged.
pub fn apply(buf: []u8, key: []const u8) void {
    applyAt(buf, key, 0);
}

/// XOR `buf` in place with `key`, repeating it as if `keystream_offset` bytes
/// of the key stream had already been consumed. If you transform consecutive
/// chunks with their matching offsets, the result equals transforming them
/// in one go.
pub fn applyAt(buf: []u8, key: []const u8, keystream_offset: usize) void {
    if (key.len == 0) return;
    for (buf, 0..) |*byte, i| {
        byte.* ^= key[(keystream_offset + i) % key.len];
    }
}

const testing = std.testing;

test "known answer" {
    var buf = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04 };
    apply(&buf, &.{ 0xFF, 0x0F });
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x0E, 0xFD, 0x0C, 0xFB }, &buf);
}

test "self-inverse" {
    const original = "some data to obfuscate";
    var buf: [original.len]u8 = undefined;
    @memcpy(&buf, original);
    apply(&buf, "a repeating key");
    try testing.expect(!std.mem.eql(u8, &buf, original));
    apply(&buf, "a repeating key");
    try testing.expectEqualSlices(u8, original, &buf);
}

test "empty key is identity" {
    var buf = [_]u8{ 1, 2, 3 };
    apply(&buf, &.{});
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &buf);
}

test "key shorter and longer than data" {
    var short = [_]u8{ 0x10, 0x10, 0x10, 0x10, 0x10 };
    apply(&short, &.{0x01});
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x11, 0x11, 0x11, 0x11 }, &short);

    var long = [_]u8{ 0x10, 0x10 };
    apply(&long, &.{ 0x01, 0x02, 0x03, 0x04, 0x05 });
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x12 }, &long);
}

test "chunked apply equals single apply" {
    const key = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01 };
    const data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var whole = data;
    apply(&whole, &key);

    var chunked = data;
    applyAt(chunked[0..3], &key, 0);
    applyAt(chunked[3..7], &key, 3);
    applyAt(chunked[7..], &key, 7);
    try testing.expectEqualSlices(u8, &whole, &chunked);
}
