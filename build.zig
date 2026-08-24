const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const DlpMode = enum { off, vendored, system };
    const dlp_mode = b.option(DlpMode, "dlp", "OneLibrary store backend: vendored (prefixed SQLCipher via zig cc), system (consumer-provided), or off") orelse .off;

    const dlp_options = b.addOptions();
    dlp_options.addOption(DlpMode, "dlp", dlp_mode);

    // The vendored build renames every sqlite3_/sqlcipher_ export to rl_*;
    // the system build binds the consumer's own unprefixed SQLCipher.
    const dlp_c_header = switch (dlp_mode) {
        .system => "vendor/sqlcipher/sqlite3.h",
        .off, .vendored => "vendor/sqlcipher/rl_sqlite3.h",
    };
    const dlp_translate = b.addTranslateC(.{
        .root_source_file = b.path(dlp_c_header),
        .target = target,
        .optimize = optimize,
    });

    const dlp = b.addModule("dlp", .{
        .root_source_file = b.path("src/dlp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = dlp_translate.createModule() },
            .{ .name = "options", .module = dlp_options.createModule() },
        },
    });
    switch (dlp_mode) {
        .off => {},
        .vendored => {
            dlp.addCSourceFile(.{
                .file = b.path("vendor/sqlcipher/rl_sqlcipher.c"),
                .flags = &sqlcipher_flags,
            });
            dlp.link_libc = true;
        },
        .system => {
            dlp.link_libc = true;
            dlp.linkSystemLibrary("sqlcipher", .{});
        },
    }

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

    const device = b.addModule("device", .{
        .root_source_file = b.path("src/device.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bin", .module = bin },
            .{ .name = "util", .module = util },
            .{ .name = "anlz", .module = anlz },
            .{ .name = "pdb", .module = pdb },
            .{ .name = "setting", .module = setting },
            .{ .name = "dlp", .module = dlp },
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
                .{ .name = "device", .module = device },
                .{ .name = "util", .module = util },
                .{ .name = "dlp", .module = dlp },
            },
        }),
    });

    b.installArtifact(lib);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

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
            .{ .name = "device", .module = device },
            .{ .name = "dlp", .module = dlp },
        },
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Symbol-prefix verification for the vendored amalgamation: every defined
    // global in the compiled object must be rl_-prefixed (decision 10). Runs
    // as part of `zig build test` on native vendored builds; `zig build
    // dlp-symbols` runs it standalone.
    const dlp_symbols_step = b.step("dlp-symbols", "Verify rl_ symbol prefixing of the vendored SQLCipher object");
    if (dlp_mode == .vendored) {
        const obj_mod = b.createModule(.{
            .target = b.graph.host,
            .root_source_file = b.path("vendor/sqlcipher/check_root.zig"),
        });
        obj_mod.addCSourceFile(.{
            .file = b.path("vendor/sqlcipher/rl_sqlcipher.c"),
            .flags = &sqlcipher_flags,
        });
        obj_mod.link_libc = true;
        const obj = b.addObject(.{
            .name = "rl_sqlcipher",
            .root_module = obj_mod,
        });
        const verify = b.addSystemCommand(&.{ "python3", "tools/gen_prefix.py", "--verify" });
        verify.addFileArg(obj.getEmittedBin());
        dlp_symbols_step.dependOn(&verify.step);
        if (target.query.isNative()) {
            test_step.dependOn(&verify.step);
        }
    }

    const bench_mod = b.addModule("bench", .{
        .root_source_file = b.path("bench/pdb_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pdb", .module = pdb },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "pdb_bench",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run pdb benchmarks (pass -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}

/// Compile flags for the vendored SQLCipher amalgamation (see
/// vendor/sqlcipher/README.md for the rationale of each).
const sqlcipher_flags = [_][]const u8{
    "-DSQLITE_HAS_CODEC",
    "-DSQLCIPHER_CRYPTO_CUSTOM=rl_sqlcipher_zig_provider_setup",
    "-DSQLITE_EXTRA_INIT=sqlcipher_extra_init",
    "-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_TEMP_STORE=2",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLCIPHER_OMIT_DLLMAIN",
    "-DSQLCIPHER_OMIT_LOG_DEVICE",
};
