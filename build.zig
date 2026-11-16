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
    const auth = provisioning_auth(b);
    const xcodegen_step = add_app_steps(b, xcframework_step, auth);
    add_testflight_step(b, xcodegen_step, auth);
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

/// xcodebuild arguments that let automatic signing create profiles through an App Store Connect
/// API key, or null when the -Dasc-* options are not all given.
fn provisioning_auth(b: *std.Build) ?[]const []const u8 {
    const key_path = b.option([]const u8, "asc-key-path", "App Store Connect API key (.p8)");
    const key_id = b.option([]const u8, "asc-key-id", "App Store Connect API key ID");
    const issuer_id = b.option([]const u8, "asc-issuer-id", "App Store Connect issuer ID");
    if (key_path == null or key_id == null or issuer_id == null) return null;
    return b.allocator.dupe([]const u8, &.{
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        key_path.?,
        "-authenticationKeyID",
        key_id.?,
        "-authenticationKeyIssuerID",
        issuer_id.?,
    }) catch @panic("OOM");
}

fn add_app_steps(
    b: *std.Build,
    xcframework_step: *std.Build.Step,
    auth: ?[]const []const u8,
) *std.Build.Step {
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
    if (sign) if (auth) |arguments| xcodebuild.addArgs(arguments);
    xcodebuild.addArg("build");
    xcodebuild.setCwd(b.path("."));
    xcodebuild.has_side_effects = true;
    xcodebuild.step.dependOn(&xcodegen.step);
    const app_step = b.step("app", "Build the iOS app with xcodebuild");
    app_step.dependOn(&xcodebuild.step);
    return &xcodegen.step;
}

/// Manual export signing: the App Manager API key has no cloud-signing permission, so the export
/// uses the keychain's Apple Distribution identity and the "Overshoot App Store" profile, which
/// must be installed in ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
const export_options_format =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>method</key><string>app-store-connect</string>
    \\<key>destination</key><string>{s}</string>
    \\<key>teamID</key><string>P5U52CGYGW</string>
    \\<key>signingStyle</key><string>manual</string>
    \\<key>signingCertificate</key><string>Apple Distribution</string>
    \\<key>provisioningProfiles</key><dict>
    \\<key>co.aidanpinard.overshoot</key><string>Overshoot App Store</string>
    \\</dict>
    \\<key>manageAppVersionAndBuildNumber</key><false/>
    \\</dict></plist>
    \\
;

/// Archives with automatic signing through an App Store Connect API key, then exports and (by
/// default) uploads to TestFlight. The archive lands in zig-out/Overshoot.xcarchive.
fn add_testflight_step(
    b: *std.Build,
    xcodegen_step: *std.Build.Step,
    auth: ?[]const []const u8,
) void {
    const step = b.step("testflight", "Archive, sign and upload the app to TestFlight");
    const build_number = b.option([]const u8, "build-number", "CFBundleVersion, grows per upload");
    const upload = b.option(bool, "testflight-upload", "Upload after export (default true)") orelse
        true;
    if (auth == null or build_number == null) {
        const message = "testflight needs -Dasc-key-path, -Dasc-key-id, -Dasc-issuer-id and " ++
            "-Dbuild-number";
        step.dependOn(&b.addFail(message).step);
        return;
    }
    const archive = b.addSystemCommand(&.{
        "xcodebuild",              "archive",      "-project",
        "app/Overshoot.xcodeproj", "-scheme",      "Overshoot",
        "-configuration",          "Release",      "-destination",
        "generic/platform=iOS",    "-archivePath", "zig-out/Overshoot.xcarchive",
    });
    archive.addArgs(auth.?);
    archive.addArg(b.fmt("CURRENT_PROJECT_VERSION={s}", .{build_number.?}));
    archive.setCwd(b.path("."));
    archive.has_side_effects = true;
    archive.step.dependOn(xcodegen_step);

    const destination = if (upload) "upload" else "export";
    const options = b.addWriteFiles().add(
        "ExportOptions.plist",
        b.fmt(export_options_format, .{destination}),
    );
    const export_archive = b.addSystemCommand(&.{
        "xcodebuild",                  "-exportArchive", "-archivePath",
        "zig-out/Overshoot.xcarchive", "-exportPath",    "zig-out/testflight",
        "-exportOptionsPlist",
    });
    export_archive.addFileArg2(options, .{});
    export_archive.addArgs(auth.?);
    export_archive.setCwd(b.path("."));
    export_archive.has_side_effects = true;
    export_archive.step.dependOn(&archive.step);
    step.dependOn(&export_archive.step);
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
