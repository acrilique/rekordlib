const std = @import("std");
const budget = @import("rekordlib").budget;

const testing = std.testing;

test "budget passes allocations under the limit and refuses past it" {
    var b = budget.Budget{ .child = testing.allocator, .limit = 64 };
    const a = b.allocator();

    const first = try a.alloc(u8, 48);
    try testing.expectEqual(@as(usize, 48), b.used);
    try testing.expect(!b.exceeded);

    try testing.expectError(error.OutOfMemory, a.alloc(u8, 48));
    try testing.expect(b.exceeded);

    a.free(first);
    try testing.expectEqual(@as(usize, 0), b.used);
    b.exceeded = false;
    const second = try a.alloc(u8, 64);
    a.free(second);
}

test "budget tracks resize and remap growth and shrink" {
    // The testing allocator refuses every in-place resize, so the child
    // here is a fixed buffer, which resizes its last allocation.
    var backing: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var b = budget.Budget{ .child = fba.allocator(), .limit = 128 };
    const a = b.allocator();

    var mem = try a.alloc(u8, 64);
    // Shrink in place: the freed bytes return to the remaining budget.
    try testing.expect(a.resize(mem, 16));
    mem = mem.ptr[0..16];
    try testing.expectEqual(@as(usize, 16), b.used);

    // Growth past the limit is refused without consulting the child.
    try testing.expect(!a.resize(mem, 256));
    try testing.expect(b.exceeded);
    b.exceeded = false;
    try testing.expectEqual(@as(usize, 16), b.used);

    // Growth within the limit and the child's buffer is forwarded.
    try testing.expect(a.resize(mem, 96));
    mem = mem.ptr[0..96];
    try testing.expectEqual(@as(usize, 96), b.used);

    if (a.remap(mem, 32)) |remapped| {
        try testing.expectEqual(@as(usize, 32), b.used);
        a.free(remapped);
    } else {
        a.free(mem);
    }
    try testing.expectEqual(@as(usize, 0), b.used);
}

test "budget over an arena caps a doubling decoder" {
    var b = budget.Budget{ .child = testing.allocator, .limit = 4 << 10 };
    var arena = std.heap.ArenaAllocator.init(b.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    // A decoder that doubles its demand the way unbounded appends do:
    // each strand is real memory through the child, so the budget sees
    // the arena's true cost.
    var kept: [64][]u8 = undefined;
    var i: usize = 0;
    while (i < kept.len) : (i += 1) {
        kept[i] = a.alloc(u8, 256) catch break;
    }
    try testing.expect(i < kept.len); // the budget refused before host OOM
    try testing.expect(b.exceeded);
    try testing.expect(b.used <= 4 << 10);
}

test "budget frees through deinit bring used back to zero" {
    var b = budget.Budget{ .child = testing.allocator, .limit = 1 << 20 };
    var arena = std.heap.ArenaAllocator.init(b.allocator());
    const a = arena.allocator();
    _ = try a.alloc(u8, 1024);
    arena.deinit();
    try testing.expectEqual(@as(usize, 0), b.used);
    try testing.expect(!b.exceeded);
}
