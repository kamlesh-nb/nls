const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

const lsp_kit = b.dependency("lsp_kit", .{}).module("lsp");

    const llvm_dep = b.dependency("llvm", .{
        .target = target,
        .optimize = optimize,
    });
    const llvm_mod = llvm_dep.module("llvm");

    // nls reuses the Nova COMPILER's parser/analysis (it compiles the compiler's src/root.zig as the
    // `compiler` module). That source lives in the `nova` repo — clone it as a SIBLING and nls builds
    // by default (`../nova/src/root.zig`). A different layout (e.g. a mono-repo where the compiler
    // folder is named `lang`) overrides the path: `zig build -Dnova-src=../lang/src/root.zig`.
    const nova_src = b.option([]const u8, "nova-src", "Path to the Nova compiler's src/root.zig") orelse "../nova/src/root.zig";

    const lang_mod = b.createModule(.{
        .root_source_file = b.path(nova_src),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llvm", .module = llvm_mod },
        },
    });

    const mod = b.addModule("nls", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "compiler", .module = lang_mod },
            .{ .name = "lsp", .module = lsp_kit },
        },
    });
    const exe = b.addExecutable(.{
        .name = "nls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ 
                .{ .name = "nls", .module = mod },
                .{ .name = "lsp", .module = lsp_kit },
                .{ .name = "compiler", .module = lang_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Install the server to `$HOME/.nova/bin/nls` as part of the default build.
    // The VS Code extension launches `~/.nova/bin/nls` (see extension/src/
    // extension.ts), NOT `zig-out/bin/nls` — without this, editing the server
    // has no effect in the editor until it's copied by hand.
    if (b.graph.environ_map.get("HOME") orelse b.graph.environ_map.get("USERPROFILE")) |home| {
        const script = b.fmt(
            \\set -e
            \\mkdir -p "{[home]s}/.nova/bin"
            \\cp zig-out/bin/nls "{[home]s}/.nova/bin/nls"
            \\echo "Installed nls to {[home]s}/.nova/bin/nls"
        , .{ .home = home });
        const install_nls = b.addSystemCommand(&.{ "sh", "-c", script });
        install_nls.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        b.getInstallStep().dependOn(&install_nls.step);
    }

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
