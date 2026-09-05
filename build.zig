const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

const lsp_kit = b.dependency("lsp_kit", .{}).module("lsp");

    // kynalyzer reuses the Kyte COMPILER's parser/analysis (it compiles the compiler's src/root.zig as the
    // `compiler` module). That source lives in the `kyte` repo ,  clone it as a SIBLING and kynalyzer builds
    // by default (`../kyte/src/root.zig`). A different layout (e.g. a mono-repo where the compiler
    // folder is named `lang`) overrides the path: `zig build -Dkyte-src=../lang/src/root.zig`.
    //
    // kynalyzer only ever touches the compiler's parser / formatter / ast / lexer (plus the sema modules it
    // re-exports), NONE of which import `llvm`, only codegen does, and codegen is not reachable from
    // the LSP. So we deliberately do NOT wire the `llvm` binding module in. That keeps kynalyzer a pure-Zig
    // binary with no external link dependency (previously it force-linked Homebrew's libLLVM), which is
    // exactly what lets it cross-compile to every OS/arch below with the bundled Zig toolchain alone.
    const kyte_src = b.option([]const u8, "kyte-src", "Path to the Kyte compiler's src/root.zig") orelse "../lang/src/root.zig";

    // Build the host-native server (installs to zig-out and, below, to ~/.kyte/bin). The reusable module
    // wiring is factored into `buildNls` so the cross-compile step can stamp out one exe per target.
    const host = buildNls(b, target, optimize, kyte_src, lsp_kit);
    const exe = host.exe;
    const mod = host.mod;
    b.installArtifact(exe);

    // `zig build cross` ,  build kynalyzer for every supported OS/arch (macOS, Linux, Windows x86_64/aarch64 for each)
    // and drop each binary under zig-out/cross/<triple>/. Pure Zig, no external libs, so these are real
    // cross-builds from any host. `kynalyzer.exe` is emitted for Windows targets.
    const cross_step = b.step("cross", "Cross-compile kynalyzer for all supported OS/arch targets");
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
        const cross_exe = buildNls(b, rt, .ReleaseSafe, kyte_src, lsp_kit).exe;
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
        });
        cross_step.dependOn(&install.step);
    }

    // Install the server to `$HOME/.kyte/bin/kynalyzer` as part of the default build.
    // The VS Code extension launches `~/.kyte/bin/kynalyzer` (see extension/src/
    // extension.ts), NOT `zig-out/bin/kynalyzer` ,  without this, editing the server
    // has no effect in the editor until it's copied by hand.
    if (b.graph.environ_map.get("HOME") orelse b.graph.environ_map.get("USERPROFILE")) |home| {
        const script = b.fmt(
            \\set -e
            \\mkdir -p "{[home]s}/.kyte/bin"
            \\cp zig-out/bin/kynalyzer "{[home]s}/.kyte/bin/kynalyzer"
            \\echo "Installed kynalyzer to {[home]s}/.kyte/bin/kynalyzer"
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

// Wire the compiler + lsp modules into the kynalyzer library module and executable, for a given resolved
// target. Pure Zig (no `llvm` import), so the same wiring builds natively or cross-compiles unchanged.
fn buildNls(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    kyte_src: []const u8,
    lsp_kit: *std.Build.Module,
) Built {
    const lang_mod = b.createModule(.{
        .root_source_file = b.path(kyte_src),
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
        .name = "kynalyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kynalyzer", .module = mod },
                .{ .name = "lsp", .module = lsp_kit },
                .{ .name = "compiler", .module = lang_mod },
            },
        }),
    });

    return .{ .exe = exe, .mod = mod };
}
