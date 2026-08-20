const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bin = b.addModule("bin", .{
        .root_source_file = b.path("src/bin.zig"),
        .target = target,
        .optimize = optimize,
    });

    const util = b.addModule("util", .{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const setting = b.addModule("setting", .{
        .root_source_file = b.path("src/setting.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
        },
    });

    const xor = b.addModule("xor", .{
        .root_source_file = b.path("src/xor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const anlz = b.addModule("anlz", .{
        .root_source_file = b.path("src/anlz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "util", .module = util },
            .{ .name = "xor", .module = xor },
        },
    });

    const pdb = b.addModule("pdb", .{
        .root_source_file = b.path("src/pdb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "util", .module = util },
        },
    });

    const lib = b.addLibrary(.{
        .name = "rekordlib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bin", .module = bin },
                .{ .name = "setting", .module = setting },
                .{ .name = "xor", .module = xor },
                .{ .name = "anlz", .module = anlz },
                .{ .name = "pdb", .module = pdb },
                .{ .name = "util", .module = util },
            },
        }),
    });

    b.installArtifact(lib);

    const test_mod = b.addModule("test", .{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "util", .module = util },
            .{ .name = "anlz", .module = anlz },
            .{ .name = "pdb", .module = pdb },
            .{ .name = "setting", .module = setting },
        },
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
