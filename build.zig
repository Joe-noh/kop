// zig build                 builds zig-out/bin/kop
// zig build run -- [path]   builds and runs it
// zig build test            runs the tests of src/core and the parts of src/view that need no window
//
// SDL3 and FreeType are built from source (the packages in build.zig.zon)
// and linked in, so the program stands alone. -Dsystem-deps links the
// system's instead, from Homebrew by default; -Ddeps=<prefix> points
// elsewhere (a prefix with include/ and lib/ inside).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system_deps = b.option(bool, "system-deps", "link the system's SDL3 and FreeType rather than building them") orelse false;
    const deps = b.option([]const u8, "deps", "where the system's SDL3 and FreeType are, with -Dsystem-deps") orelse "/opt/homebrew";
    // A macOS other than the one building, such as an older one to run on,
    // needs the SDK named: -Dmacos-sdk="$(xcrun --sdk macosx --show-sdk-path)".
    const macos_sdk = b.option([]const u8, "macos-sdk", "the macOS SDK, to build for a macOS other than this one");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The libraries' headers, translated for the program to import as "c".
    const c_h = b.addTranslateC(.{ .root_source_file = b.path("src/view/c.h"), .target = target, .optimize = optimize });
    if (system_deps) {
        c_h.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ deps, "include" }) });
        c_h.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ deps, "include/freetype2" }) });
        exe_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ deps, "lib" }) });
        exe_mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
        exe_mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
    } else {
        const sdk_path = struct {
            fn f(bb: *std.Build, sdk: ?[]const u8, sub: []const u8) ?std.Build.LazyPath {
                return if (sdk) |p| .{ .cwd_relative = bb.pathJoin(&.{ p, sub }) } else null;
            }
        }.f;
        if (macos_sdk != null) {
            exe_mod.addSystemFrameworkPath(sdk_path(b, macos_sdk, "System/Library/Frameworks").?);
            exe_mod.addSystemIncludePath(sdk_path(b, macos_sdk, "usr/include").?);
            exe_mod.addLibraryPath(sdk_path(b, macos_sdk, "usr/lib").?);
        }
        if (b.lazyDependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_linkage = .static,
            .system_include_path = sdk_path(b, macos_sdk, "usr/include"),
            .system_framework_path = sdk_path(b, macos_sdk, "System/Library/Frameworks"),
            .library_path = sdk_path(b, macos_sdk, "usr/lib"),
        })) |sdl| {
            const lib = sdl.artifact("SDL3");
            exe_mod.linkLibrary(lib);
            c_h.addIncludePath(lib.getEmittedIncludeTree());
        }
        if (b.lazyDependency("freetype", .{ .target = target, .optimize = optimize })) |ft| {
            const lib = ft.artifact("freetype");
            exe_mod.linkLibrary(lib);
            c_h.addIncludePath(lib.getEmittedIncludeTree());
        }
    }
    exe_mod.addImport("c", c_h.createModule());

    const exe = b.addExecutable(.{ .name = "kop", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run kop").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
