// This Source Code Form is subject to the terms of the Mozilla Public License,
// v. 2.0. If a copy of the MPL was not distributed with this file, You can
// obtain one at https://mozilla.org/MPL/2.0/.

//! Caps the bytes an untrusted decode may allocate, in proportion to its
//! input.
//!
//! The parsers materialize a whole file into memory. A hostile file's
//! declared structure can expand: format-declared counts and offsets can
//! name the same bytes many times, and every copy costs real memory. Such a
//! file could exhaust host memory.
//!
//! A [Budget](#rekordlib.budget.Budget) wraps the arena's child allocator,
//! so every allocation of a decode passes one choke point — including
//! decoder bugs not yet found — instead of per-site accounting. If the
//! running total passes `limit`, allocations fail. `exceeded` then records
//! that the refusal was policy, not host memory, and the caller maps that
//! flag to a typed error.

const std = @import("std");

/// Default proportional-limit policy shared by the format loaders. A decode may allocate up to
/// [multiplier](#rekordlib.budget.multiplier) bytes per input byte, and never less than
/// [min_limit](#rekordlib.budget.min_limit): even a minimal real database still materializes a
/// few hundred kilobytes of pages and rows.
///
/// Sparse real files decode to about their encoded size. Real files with many tiny rows need
/// more: each row carries structs and a duplicated string against ~30 wire bytes, which
/// measures close to 4x the encoded size. So 8x leaves margin over the worst real shape, while
/// catching the hundreds-fold expansion hostile files produce through aliased offsets,
/// presence slots, and generated rows.
pub const multiplier: usize = 8;
pub const min_limit: usize = 1 << 20;

/// The ceiling for a decode of `input_len` input bytes.
pub fn proportionalLimit(input_len: usize) usize {
    return @max(min_limit, input_len *| multiplier);
}

/// Caps the bytes one decode may allocate, proportional to its input.
///
/// The wrapper forwards every operation to `child` unchanged; only the
/// running total and the refusal are added. It is not thread-safe.
pub const Budget = struct {
    /// The allocator every byte is actually drawn from.
    child: std.mem.Allocator,
    /// The cumulative allocation ceiling. Raising it after a successful
    /// parse gives a trusted-for-mutation database writer headroom,
    /// without reopening the parse-time ceiling.
    limit: usize,
    /// Bytes currently allocated through the wrapper.
    used: usize = 0,
    /// Set when an allocation was refused because it would pass `limit`.
    /// This distinguishes the policy refusal from a genuine `OutOfMemory`.
    exceeded: bool = false,

    /// Bytes still available under the ceiling.
    pub fn remaining(b: *const Budget) usize {
        return b.limit -| b.used;
    }

    /// The allocator interface to hand to `ArenaAllocator.init` (or any
    /// decoder whose allocations should count against `limit`).
    pub fn allocator(b: *Budget) std.mem.Allocator {
        return .{ .ptr = b, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn self(ctx: *anyopaque) *Budget {
        return @ptrCast(@alignCast(ctx));
    }

    /// If a growth of `delta` does not fit under the limit, refuse it and
    /// record the refusal in `exceeded`. Shrinks and no-op sizes always
    /// pass the policy check.
    fn allowsGrowth(b: *Budget, delta: usize) bool {
        if (delta > b.remaining()) {
            b.exceeded = true;
            return false;
        }
        return true;
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const b = self(ctx);
        if (!b.allowsGrowth(len)) return null;
        const mem = b.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        b.used += len;
        return mem;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const b = self(ctx);
        const grow = new_len -| memory.len;
        if (!b.allowsGrowth(grow)) return false;
        if (!b.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        b.used +%= grow;
        b.used -|= memory.len -| new_len;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const b = self(ctx);
        const grow = new_len -| memory.len;
        if (!b.allowsGrowth(grow)) return null;
        const mem = b.child.rawRemap(memory, alignment, new_len, ret_addr) orelse
            return null;
        b.used +%= grow;
        b.used -|= memory.len -| new_len;
        return mem;
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const b = self(ctx);
        b.used -|= memory.len;
        b.child.rawFree(memory, alignment, ret_addr);
    }
};
