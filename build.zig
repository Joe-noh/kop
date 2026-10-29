// zig build                 builds zig-out/bin/kop
// zig build run -- [path]   builds and runs it
// zig build test            runs the tests of src/core and the parts of src/view that need no window
//
// SDL3 and FreeType come from Homebrew by default; -Ddeps=<prefix> points
// elsewhere (a prefix with include/ and lib/ inside).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = b.option([]const u8, "deps", "where SDL3 and FreeType are installed") orelse "/opt/homebrew";

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ deps, "include" }) });
    exe_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ deps, "include/freetype2" }) });
    exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ deps, "lib" }) });
    exe_mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
    exe_mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{ .name = "kop", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run kop").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
