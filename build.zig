const std = @import("std");
const addBench = @import("zubench").addBench;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const zubench = b.dependency("zubench", .{}).module("zubench");
    const strided_arrays_pkg = b.dependency("strided-arrays", .{});

    const strided_arrays = strided_arrays_pkg.module("strided-arrays");
    const strided_arrays_dep = std.Build.Module.Import{
        .name = "strided-arrays",
        .module = strided_arrays,
    };

    _ = b.addModule("wfc", .{
        .root_source_file = .{ .path = "src/wfc.zig" },
        .imports = &.{strided_arrays_dep},
    });

    const exe = b.addExecutable(.{
        .name = "zig-wfc",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.root_module.addImport(strided_arrays_dep.name, strided_arrays_dep.module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wfc_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/wfc.zig" },
        .target = target,
        .optimize = mode,
    });
    wfc_tests.root_module.addImport("zubench", zubench);
    wfc_tests.root_module.addImport(strided_arrays_dep.name, strided_arrays_dep.module);

    const wfc_tests_run = b.addRunArtifact(wfc_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&wfc_tests_run.step);

    const bench_step = b.step("bench", "Run the benchmarks");

    inline for (.{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |b_mode| {
        const bench_exe = addBench(b, "src/core.zig", target, b_mode, &.{strided_arrays_dep});
        const cmd = b.addRunArtifact(bench_exe);
        bench_step.dependOn(&cmd.step);
    }
}
