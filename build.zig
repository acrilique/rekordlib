const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bin = b.addModule("bin", .{
        .root_source_file = b.path("src/bin.zig"),
        .target = target,
        .optimize = optimize,
    });

    const testutil = b.addModule("testutil", .{
        .root_source_file = b.path("src/testutil.zig"),
        .target = target,
        .optimize = optimize,
    });

    const setting = b.addModule("setting", .{
        .root_source_file = b.path("src/setting.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "testutil", .module = testutil },
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
            .{ .name = "xor", .module = xor },
            .{ .name = "testutil", .module = testutil },
        },
    });

    const pdb = b.addModule("pdb", .{
        .root_source_file = b.path("src/pdb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "testutil", .module = testutil },
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
            },
        }),
    });

    b.installArtifact(lib);

    const mod_tests = b.addTest(.{
        .root_module = bin,
    });

    const setting_tests = b.addTest(.{
        .root_module = setting,
    });

    const xor_tests = b.addTest(.{
        .root_module = xor,
    });

    const anlz_tests = b.addTest(.{
        .root_module = anlz,
    });

    const pdb_tests = b.addTest(.{
        .root_module = pdb,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_setting_tests = b.addRunArtifact(setting_tests);
    const run_xor_tests = b.addRunArtifact(xor_tests);
    const run_anlz_tests = b.addRunArtifact(anlz_tests);
    const run_pdb_tests = b.addRunArtifact(pdb_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_setting_tests.step);
    test_step.dependOn(&run_xor_tests.step);
    test_step.dependOn(&run_anlz_tests.step);
    test_step.dependOn(&run_pdb_tests.step);
}
