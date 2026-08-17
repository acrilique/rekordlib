const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bin = b.addModule("bin", .{
        .root_source_file = b.path("src/bin.zig"),
        .target = target,
    });

    const setting = b.addModule("setting", .{
        .root_source_file = b.path("src/setting.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "bin", .module = bin },
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

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_setting_tests = b.addRunArtifact(setting_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_setting_tests.step);
}
