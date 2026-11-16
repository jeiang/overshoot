const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("overshoot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const core_tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    add_lint_step(b);
}

fn add_lint_step(b: *std.Build) void {
    const lint_step = b.step("lint", "Check formatting and TigerStyle rules");
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tools") },
        .check = true,
    });
    lint_step.dependOn(&fmt.step);

    const lint_exe = b.addExecutable(.{
        .name = "lint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lint.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const lint_run = b.addRunArtifact(lint_exe);
    lint_run.has_side_effects = true;
    lint_run.setCwd(b.path("."));
    lint_run.addArgs(&.{ "build.zig", "src", "tools" });
    lint_step.dependOn(&lint_run.step);
}
