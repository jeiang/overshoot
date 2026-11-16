const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

    const core = b.addModule("overshoot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("tools/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "overshoot", .module = core }},
    });
    cli_module.linkFramework("ImageIO", .{});
    cli_module.linkFramework("CoreGraphics", .{});
    cli_module.linkFramework("CoreFoundation", .{});
    const cli = b.addExecutable(.{ .name = "overshoot-cli", .root_module = cli_module });
    b.installArtifact(cli);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_module })).step);

    const xcframework_step = add_xcframework_step(b);
    add_app_steps(b, xcframework_step);
    add_lint_step(b);
}

fn ios_library(b: *std.Build, abi: ?std.Target.Abi) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = abi,
        .os_version_min = .{ .semver = .{ .major = 27, .minor = 0, .patch = 0 } },
    });
    return b.addLibrary(.{
        .name = "overshoot_core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = .safe,
            .link_libc = true,
        }),
    });
}

fn add_xcframework_step(b: *std.Build) *std.Build.Step {
    const device = ios_library(b, null);
    const simulator = ios_library(b, .simulator);
    const create = b.addSystemCommand(&.{ "xcodebuild", "-create-xcframework", "-library" });
    create.addArtifactArg2(device, .{});
    create.addArg("-headers");
    create.addDirectoryArg2(b.path("include"), .{});
    create.addArg("-library");
    create.addArtifactArg2(simulator, .{});
    create.addArg("-headers");
    create.addDirectoryArg2(b.path("include"), .{});
    create.addArg("-output");
    const output = create.addOutputFileArg2("OvershootCore.xcframework", .{});
    const install = b.addInstallDirectory(.{
        .source_dir = output,
        .install_dir = .prefix,
        .install_subdir = "OvershootCore.xcframework",
    });
    const step = b.step("xcframework", "Build zig-out/OvershootCore.xcframework");
    step.dependOn(&install.step);
    return step;
}

fn add_app_steps(b: *std.Build, xcframework_step: *std.Build.Step) void {
    const Destination = enum { device, simulator };
    const destination = b.option(Destination, "app-destination", "device or simulator") orelse
        .device;
    const sign = b.option(bool, "app-sign", "Sign the app (default true)") orelse true;

    const xcodegen = b.addSystemCommand(&.{
        "xcodegen", "generate", "--spec", "app/project.yml", "--project", "app",
    });
    xcodegen.setCwd(b.path("."));
    xcodegen.has_side_effects = true;
    xcodegen.step.dependOn(xcframework_step);
    const xcodeproj_step = b.step("xcodeproj", "Generate app/Overshoot.xcodeproj");
    xcodeproj_step.dependOn(&xcodegen.step);

    const xcodebuild = b.addSystemCommand(&.{
        "xcodebuild", "-project",     "app/Overshoot.xcodeproj",
        "-scheme",    "Overshoot",    "-configuration",
        "Release",    "-destination",
    });
    xcodebuild.addArg(switch (destination) {
        .device => "generic/platform=iOS",
        .simulator => "generic/platform=iOS Simulator",
    });
    if (!sign) xcodebuild.addArg("CODE_SIGNING_ALLOWED=NO");
    xcodebuild.addArg("build");
    xcodebuild.setCwd(b.path("."));
    xcodebuild.has_side_effects = true;
    xcodebuild.step.dependOn(&xcodegen.step);
    const app_step = b.step("app", "Build the iOS app with xcodebuild");
    app_step.dependOn(&xcodebuild.step);
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
