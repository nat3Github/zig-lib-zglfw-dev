const std = @import("std");
const builtin = @import("builtin");

// Cross-compiling to Linux from a non-Linux host: the host's pkg-config (e.g.
// Homebrew's on macOS) resolves X11 to host-arch libs, and X11/wl_platform.h headers
// aren't found at all. These come from plain absolute -Dsystem_include_path/
// -Dlibrary_path options (NOT --sysroot): a global --sysroot also applies to native
// host-tool compiles elsewhere in the build graph and breaks those (e.g. "unable to
// find libSystem system library"), so headers/libs are supplied directly instead.
// b.option is read once (memoized) since addLinuxSysroot is called multiple times
// per build (glfw lib + zglfw test exe) and b.option panics on re-registration.
var linux_cross_paths_cache: ?struct { include_path: ?std.Build.LazyPath, library_path: ?std.Build.LazyPath } = null;

fn addLinuxSysroot(b: *std.Build, mod: *std.Build.Module) std.Build.Module.SystemLib.UsePkgConfig {
    if (builtin.os.tag == .linux) return .yes;
    if (linux_cross_paths_cache == null) {
        linux_cross_paths_cache = .{
            .include_path = b.option(std.Build.LazyPath, "system_include_path", "Linux sysroot include path (for cross-compiling to Linux)"),
            .library_path = b.option(std.Build.LazyPath, "library_path", "Linux sysroot library path (for cross-compiling to Linux)"),
        };
    }
    const paths = linux_cross_paths_cache.?;
    if (paths.include_path) |p| mod.addSystemIncludePath(p);
    if (paths.library_path) |p| mod.addLibraryPath(p);
    if (paths.include_path == null or paths.library_path == null) {
        std.debug.print("error: cross-compiling to Linux requires -Dsystem_include_path and -Dlibrary_path pointing at a Linux sysroot's usr/include and usr/lib (X11/wayland headers+libs)\n", .{});
        std.process.exit(1);
    }
    return .no;
}

pub fn build(b: *std.Build) void {
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
    linkSystemLibs(b, glfw, target, options);

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
                _ = addLinuxSysroot(b, glfw.root_module);
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
    linkSystemLibs(b, tests, target, options);
    tests.root_module.addImport("zglfw_options", options_module);
    tests.root_module.linkLibrary(glfw);
    b.installArtifact(tests);
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addIncludePaths(b: *std.Build, unit: anytype) void {
    unit.addIncludePath(b.path("libs/glfw/include"));
}

fn linkSystemLibs(b: *std.Build, compile_step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, options: anytype) void {
    compile_step.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .windows => {
            compile_step.root_module.linkSystemLibrary("gdi32", .{});
            compile_step.root_module.linkSystemLibrary("user32", .{});
            compile_step.root_module.linkSystemLibrary("shell32", .{});
        },
        .macos => {
            if (b.sysroot) |sysroot| {
                compile_step.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
                compile_step.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
                // Zig strips the leading "/" off an absolute -L path and rejoins it onto
                // --sysroot itself, so this must be given as if the sysroot were "/".
                compile_step.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            } else if (b.graph.host.result.os.tag != .macos) {
                std.debug.print(
                    "error: cross-compiling to macOS requires --sysroot pointing at a macOS SDK " ++
                        "(e.g. --sysroot /path/to/MacOSX.sdk), otherwise linking frameworks will fail deep " ++
                        "in the linker with an unhelpful 'unable to find framework' error.\n",
                    .{},
                );
                std.process.exit(1);
            }
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
                _ = addLinuxSysroot(b, compile_step.root_module);
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
