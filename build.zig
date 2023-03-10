const std = @import("std");
const addBench = @import("zubench/build.zig").addBench;

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    const zubench = b.createModule(.{
        .source_file = std.build.FileSource{ .path = "zubench/src/bench.zig" },
    });

    const zig_args_pkg = b.dependency("zig-args", .{});
    const strided_arrays_pkg = b.dependency("strided-arrays", .{});

    const zig_args = zig_args_pkg.module("args");
    const strided_arrays = strided_arrays_pkg.module("strided-arrays");
    const strided_arrays_dep = std.Build.ModuleDependency{
        .name = "strided-arrays",
        .module = strided_arrays,
    };

    _ = b.addModule("wfc", .{
        .source_file = .{ .path = "src/wfc.zig" },
        .dependencies = &.{strided_arrays_dep},
    });

    const exe = b.addExecutable(.{
        .name = "zig-wfc",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.addModule("zig-args", zig_args);
    exe.addModule(strided_arrays_dep.name, strided_arrays_dep.module);
    exe.install();

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.expected_term = null;
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
    wfc_tests.addModule("zubench", zubench);
    wfc_tests.addModule(strided_arrays_dep.name, strided_arrays_dep.module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&wfc_tests.step);

    const bench_step = b.step("bench", "Run the benchmarks");

    inline for (.{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |b_mode| {
        const bench_exe = addBench(b, "src/core.zig", b_mode, zubench, &.{strided_arrays_dep});
        const cmd = b.addRunArtifact(bench_exe);
        bench_step.dependOn(&cmd.step);
    }
}
