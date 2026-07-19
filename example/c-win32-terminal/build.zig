//! Build the #82 Win32 spike host with Zig driving the C compile (`zig cc`).
//!
//! From this directory (after `zig build -Dapp-runtime=none` at repo root):
//!   zig build
//!   zig build run

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Prefer gnu so `zig cc` uses bundled MinGW headers (no vcvars INCLUDE required).
    // Link against the MSVC-built ghostty.dll import lib still works on Windows.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const root = b.pathFromRoot("../..");
    const include = b.pathJoin(&.{ root, "include" });
    const dll_dir = b.pathJoin(&.{ root, "zig-out", "lib" });
    const dll = b.pathJoin(&.{ dll_dir, "ghostty.dll" });
    const import_lib = b.pathJoin(&.{ dll_dir, "ghostty.lib" });

    const exe = b.addExecutable(.{
        .name = "c_win32_terminal",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    // Zig compiles main.c via its C toolchain (same as `zig cc`).
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{"-D_CRT_SECURE_NO_WARNINGS"},
    });
    exe.root_module.addIncludePath(.{ .cwd_relative = include });
    exe.root_module.addLibraryPath(.{ .cwd_relative = dll_dir });
    exe.root_module.linkSystemLibrary("ghostty", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("dwmapi", .{});
    exe.root_module.linkSystemLibrary("imm32", .{});
    exe.root_module.link_libc = true;
    // Ensure the import library is visible to the linker.
    exe.addObjectFile(.{ .cwd_relative = import_lib });

    b.installArtifact(exe);

    // Copy ghostty.dll next to the installed exe for easy run.
    const copy_dll = b.addInstallBinFile(.{ .cwd_relative = dll }, "ghostty.dll");
    b.getInstallStep().dependOn(&copy_dll.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the #82 Win32+DX12 spike host");
    run_step.dependOn(&run.step);
}