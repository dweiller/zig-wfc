const std = @import("std");
const addBench = @import("vendor/zubench/build.zig").addBench;

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const pkgs = struct {
        const zig_args = std.build.Pkg{
            .name = "zig-args",
            .source = std.build.FileSource{ .path = "vendor/zig-args/args.zig" },
        };

        const zubench = std.build.Pkg{
            .name = "zubench",
            .source = std.build.FileSource{ .path = "vendor/zubench/src/bench.zig" },
        };

        const strided_arrays = std.build.Pkg{
            .name = "strided-arrays",
            .source = std.build.FileSource{ .path = "vendor/zig-strided-arrays/src/strided_array.zig" },
        };
    };

    const exe = b.addExecutable("zig-wfc", "src/main.zig");
    exe.addPackage(pkgs.zig_args);
    exe.addPackage(pkgs.strided_arrays);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.expected_exit_code = null;
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wfc_tests = b.addTest("src/wfc.zig");
    wfc_tests.addPackage(pkgs.zubench);
    wfc_tests.addPackage(pkgs.strided_arrays);
    wfc_tests.setTarget(target);
    wfc_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&wfc_tests.step);

    const bench_step = b.step("bench", "Run the benchmarks");

    inline for (.{ .ReleaseSafe, .ReleaseFast, .ReleaseSmall }) |b_mode| {
        const bench_exe = addBench(b, "src/core.zig", b_mode, &.{pkgs.strided_arrays});
        bench_step.dependOn(&bench_exe.run().step);
    }
}

fn rootDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn getPackage() std.build.Pkg {
    const wfc = std.build.Pkg{
        .name = "wfc",
        .source = std.build.FileSource{ .path = comptime rootDir() ++ "/src/wfc.zig" },
        .dependencies = &.{
            .{
                .name = "strided-arrays",
                .source = std.build.FileSource{ .path = comptime rootDir() ++ "/vendor/zig-strided-arrays/src/strided_array.zig" },
            },
        },
    };
    return wfc;
}
