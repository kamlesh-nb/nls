const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

const lsp_kit = b.dependency("lsp_kit", .{}).module("lsp");

    // nls reuses the Nova COMPILER's parser/analysis (it compiles the compiler's src/root.zig as the
    // `compiler` module). That source lives in the `nova` repo ,  clone it as a SIBLING and nls builds
    // by default (`../nova/src/root.zig`). A different layout (e.g. a mono-repo where the compiler
    // folder is named `lang`) overrides the path: `zig build -Dnova-src=../lang/src/root.zig`.
    //
    // nls only ever touches the compiler's parser / formatter / ast / lexer (plus the sema modules it
    // re-exports), NONE of which import `llvm`, only codegen does, and codegen is not reachable from
    // the LSP. So we deliberately do NOT wire the `llvm` binding module in. That keeps nls a pure-Zig
    // binary with no external link dependency (previously it force-linked Homebrew's libLLVM), which is
    // exactly what lets it cross-compile to every OS/arch below with the bundled Zig toolchain alone.
    const nova_src = b.option([]const u8, "nova-src", "Path to the Nova compiler's src/root.zig") orelse "../nova/src/root.zig";

    // Build the host-native server (installs to zig-out and, below, to ~/.nova/bin). The reusable module
    // wiring is factored into `buildNls` so the cross-compile step can stamp out one exe per target.
    const host = buildNls(b, target, optimize, nova_src, lsp_kit);
    const exe = host.exe;
    const mod = host.mod;
    b.installArtifact(exe);

    // `zig build cross` ,  build nls for every supported OS/arch (macOS, Linux, Windows x86_64/aarch64 for each)
    // and drop each binary under zig-out/cross/<triple>/. Pure Zig, no external libs, so these are real
    // cross-builds from any host. `nls.exe` is emitted for Windows targets.
    const cross_step = b.step("cross", "Cross-compile nls for all supported OS/arch targets");
    const triples = [_][]const u8{
        "aarch64-macos",
        "x86_64-macos",
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-windows",
        "aarch64-windows",
    };
    for (triples) |triple| {
        const q = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch @panic("bad target triple");
        const rt = b.resolveTargetQuery(q);
        const cross_exe = buildNls(b, rt, .ReleaseSafe, nova_src, lsp_kit).exe;
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
        });
        cross_step.dependOn(&install.step);
    }

    // Install the server to `$HOME/.nova/bin/nls` as part of the default build.
    // The VS Code extension launches `~/.nova/bin/nls` (see extension/src/
    // extension.ts), NOT `zig-out/bin/nls` ,  without this, editing the server
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

const Built = struct {
    exe: *std.Build.Step.Compile,
    mod: *std.Build.Module,
};

// Wire the compiler + lsp modules into the nls library module and executable, for a given resolved
// target. Pure Zig (no `llvm` import), so the same wiring builds natively or cross-compiles unchanged.
fn buildNls(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nova_src: []const u8,
    lsp_kit: *std.Build.Module,
) Built {
    const lang_mod = b.createModule(.{
        .root_source_file = b.path(nova_src),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
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

    return .{ .exe = exe, .mod = mod };
}
