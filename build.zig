const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // stb_truetype needs libc (memcpy, sqrt, ...)
    });
    module.addIncludePath(b.path("vendor"));
    module.addCSourceFile(.{
        .file = b.path("vendor/stb_impl.c"),
        .flags = &.{ "-std=c99", "-O2", "-fno-sanitize=undefined" },
    });

    const exe = b.addExecutable(.{
        .name = "book2png",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run book2png");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
