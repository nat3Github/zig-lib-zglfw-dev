const std = @import("std");
const builtin = @import("builtin");

// Cross-compile system paths, passed explicitly rather than via --sysroot or
// --search-prefix: both of those are graph-wide, so they also hit native host-tool
// steps in the same build graph (breaking those with e.g. "unable to find libSystem
// system library"), --sysroot additionally re-roots every absolute -L onto itself,
// and --search-prefix never reaches translate-c.
// Options are registered unconditionally in build() (b.option panics on
// re-registration, and a dependent passing -Dsystem_include_path on a target that
// didn't read it would otherwise hit "invalid option").
var cross_paths: struct {
    include_path: ?std.Build.LazyPath,
    framework_path: ?std.Build.LazyPath,
    library_path: ?std.Build.LazyPath,
} = .{ .include_path = null, .framework_path = null, .library_path = null };

/// Returns whether the host's pkg-config may be consulted: cross-compiling to Linux
/// from a non-Linux host, it resolves X11 to host-arch libs, so it must not be.
fn addLinuxCrossPaths(mod: *std.Build.Module) std.Build.Module.SystemLib.UsePkgConfig {
    if (builtin.os.tag == .linux) return .yes;
    if (cross_paths.include_path) |p| mod.addSystemIncludePath(p);
    if (cross_paths.library_path) |p| mod.addLibraryPath(p);
    if (cross_paths.include_path == null or cross_paths.library_path == null) {
        std.debug.print("error: cross-compiling to Linux requires -Dsystem_include_path and -Dlibrary_path pointing at a Linux sysroot's usr/include and usr/lib (X11/wayland headers+libs)\n", .{});
        std.process.exit(1);
    }
    return .no;
}

fn addMacosCrossPaths(mod: *std.Build.Module) void {
    // Native macOS builds need nothing here: clang locates the system SDK itself.
    if (cross_paths.include_path) |p| mod.addSystemIncludePath(p);
    if (cross_paths.framework_path) |p| mod.addSystemFrameworkPath(p);
    if (cross_paths.library_path) |p| mod.addLibraryPath(p);
    if (builtin.os.tag != .macos and
        (cross_paths.include_path == null or cross_paths.framework_path == null or cross_paths.library_path == null))
    {
        std.debug.print(
            "error: cross-compiling to macOS requires -Dsystem_include_path, -Dsystem_framework_path and " ++
                "-Dlibrary_path pointing at a macOS SDK's usr/include, System/Library/Frameworks and usr/lib, " ++
                "otherwise linking frameworks fails deep in the linker with an unhelpful " ++
                "'unable to find framework' error.\n",
            .{},
        );
        std.process.exit(1);
    }
}

pub fn build(b: *std.Build) void {
    cross_paths = .{
        .include_path = b.option(std.Build.LazyPath, "system_include_path", "Target system include path (for cross-compiling)"),
        .framework_path = b.option(std.Build.LazyPath, "system_framework_path", "Target system framework path (for cross-compiling to macOS)"),
        .library_path = b.option(std.Build.LazyPath, "library_path", "Target system library path (for cross-compiling)"),
    };

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .shared = b.option(
            bool,
            "shared",
            "Build GLFW as shared lib",
        ) orelse false,
        .enable_x11 = b.option(
            bool,
            "x11",
            "Whether to build with X11 support (default: true)",
        ) orelse true,
        .enable_wayland = b.option(
            bool,
            "wayland",
            "Whether to build with Wayland support (default: true)",
        ) orelse true,
        .enable_vulkan_import = b.option(
            bool,
            "import_vulkan",
            "Whether to build with external Vulkan dependency (default: false)",
        ) orelse false,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const options_module = options_step.createModule();

    const module = b.addModule("root", .{
        .root_source_file = b.path("src/zglfw.zig"),
        .imports = &.{
            .{ .name = "zglfw_options", .module = options_module },
        },
    });

    if (target.result.os.tag == .emscripten) return;

    const glfw = b.addLibrary(.{
        .name = "glfw",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    if (options.shared and target.result.os.tag == .windows) {
        glfw.root_module.addCMacro("_GLFW_BUILD_DLL", "");
    }

    b.installArtifact(glfw);
    glfw.installHeadersDirectory(b.path("libs/glfw/include"), "", .{});

    addIncludePaths(b, glfw.root_module);
    linkSystemLibs(glfw, target, options);

    const src_dir = "libs/glfw/src/";
    switch (target.result.os.tag) {
        .windows => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "wgl_context.c",
                    src_dir ++ "win32_thread.c",
                    src_dir ++ "win32_init.c",
                    src_dir ++ "win32_monitor.c",
                    src_dir ++ "win32_time.c",
                    src_dir ++ "win32_joystick.c",
                    src_dir ++ "win32_window.c",
                    src_dir ++ "win32_module.c",
                },
                .flags = &.{"-D_GLFW_WIN32"},
            });
        },
        .macos => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "posix_thread.c",
                    src_dir ++ "posix_module.c",
                    src_dir ++ "posix_poll.c",
                    src_dir ++ "nsgl_context.m",
                    src_dir ++ "cocoa_time.c",
                    src_dir ++ "cocoa_joystick.m",
                    src_dir ++ "cocoa_init.m",
                    src_dir ++ "cocoa_window.m",
                    src_dir ++ "cocoa_monitor.m",
                },
                .flags = &.{"-D_GLFW_COCOA"},
            });
        },
        .linux => {
            glfw.root_module.addCSourceFiles(.{
                .files = &.{
                    src_dir ++ "platform.c",
                    src_dir ++ "monitor.c",
                    src_dir ++ "init.c",
                    src_dir ++ "vulkan.c",
                    src_dir ++ "input.c",
                    src_dir ++ "context.c",
                    src_dir ++ "window.c",
                    src_dir ++ "osmesa_context.c",
                    src_dir ++ "egl_context.c",
                    src_dir ++ "null_init.c",
                    src_dir ++ "null_monitor.c",
                    src_dir ++ "null_window.c",
                    src_dir ++ "null_joystick.c",
                    src_dir ++ "posix_time.c",
                    src_dir ++ "posix_thread.c",
                    src_dir ++ "posix_module.c",
                },
                .flags = &.{},
            });
            if (options.enable_x11 or options.enable_wayland) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "xkb_unicode.c",
                        src_dir ++ "linux_joystick.c",
                        src_dir ++ "posix_poll.c",
                    },
                    .flags = &.{},
                });
            }
            if (options.enable_x11 or options.enable_wayland) {
                _ = addLinuxCrossPaths(glfw.root_module);
            }
            if (options.enable_x11) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "x11_init.c",
                        src_dir ++ "x11_monitor.c",
                        src_dir ++ "x11_window.c",
                        src_dir ++ "glx_context.c",
                    },
                    .flags = &.{},
                });
                glfw.root_module.addCMacro("_GLFW_X11", "1");
                glfw.root_module.linkSystemLibrary("X11", .{
                    .use_pkg_config = if (builtin.os.tag == .linux) .yes else .no,
                });
            }
            if (options.enable_wayland) {
                glfw.root_module.addCSourceFiles(.{
                    .files = &.{
                        src_dir ++ "wl_init.c",
                        src_dir ++ "wl_monitor.c",
                        src_dir ++ "wl_window.c",
                    },
                    .flags = &.{},
                });
                glfw.root_module.addIncludePath(b.path(src_dir ++ "wayland"));
                glfw.root_module.addCMacro("_GLFW_WAYLAND", "1");
            }
        },
        else => {},
    }
    addIncludePaths(b, module);

    const test_step = b.step("test", "Run zglfw tests");
    const tests = b.addTest(.{
        .name = "zglfw-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zglfw.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addIncludePaths(b, tests.root_module);
    linkSystemLibs(tests, target, options);
    tests.root_module.addImport("zglfw_options", options_module);
    tests.root_module.linkLibrary(glfw);
    b.installArtifact(tests);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addIncludePaths(b: *std.Build, unit: anytype) void {
    unit.addIncludePath(b.path("libs/glfw/include"));
}

fn linkSystemLibs(compile_step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, options: anytype) void {
    compile_step.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .windows => {
            compile_step.root_module.linkSystemLibrary("gdi32", .{});
            compile_step.root_module.linkSystemLibrary("user32", .{});
            compile_step.root_module.linkSystemLibrary("shell32", .{});
        },
        .macos => {
            addMacosCrossPaths(compile_step.root_module);
            compile_step.root_module.linkSystemLibrary("objc", .{});
            compile_step.root_module.linkFramework("IOKit", .{});
            compile_step.root_module.linkFramework("CoreFoundation", .{});
            compile_step.root_module.linkFramework("Metal", .{});
            compile_step.root_module.linkFramework("AppKit", .{});
            compile_step.root_module.linkFramework("CoreServices", .{});
            compile_step.root_module.linkFramework("CoreGraphics", .{});
            compile_step.root_module.linkFramework("Foundation", .{});
        },
        .linux => {
            if (options.enable_x11 or options.enable_wayland) {
                _ = addLinuxCrossPaths(compile_step.root_module);
            }
            if (options.enable_x11) {
                compile_step.root_module.addCMacro("_GLFW_X11", "1");
                compile_step.root_module.linkSystemLibrary("X11", .{
                    .use_pkg_config = if (builtin.os.tag == .linux) .yes else .no,
                });
            }
            if (options.enable_wayland) {
                compile_step.root_module.addCMacro("_GLFW_WAYLAND", "1");
            }
        },
        else => {},
    }
}
