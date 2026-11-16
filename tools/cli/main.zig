//! overshoot-cli: renders photos through the core pipeline and measures tone statistics, for
//! tuning the camera profiles against reference photos.

const std = @import("std");
const assert = std.debug.assert;
const overshoot = @import("overshoot");
const image_io = @import("image_io.zig");
const profiles = overshoot.profiles;
const pipeline_module = overshoot.pipeline;

const usage =
    \\usage:
    \\  overshoot-cli render --camera canon|nikon --input <image> --output <jpg>
    \\      [--facebook <jpg>] [--zoom 0..1] [--exposure-time S --iso N --aperture F]
    \\      [--focal-length-35mm-capture MM] [--temperature K] [--flash] [--seed N]
    \\  --input-f16 <file> --width W --height H replaces --input with a linear RGBA f16
    \\      staging dump from the app (launched with -dumpcapture).
    \\  overshoot-cli stats <image>...
    \\
;

const thread_count: u32 = 5;

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const command = arguments[1];
    if (std.mem.eql(u8, command, "render")) {
        const options = parse_render(arguments[2..]);
        try render(init.gpa, init.io, &options);
    } else if (std.mem.eql(u8, command, "stats")) {
        if (arguments.len < 3) fail("stats needs at least one image", .{});
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        for (arguments[2..]) |path| try stats(init.gpa, path, &writer.interface);
        try writer.interface.flush();
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
}

const RenderOptions = struct {
    camera: ?profiles.Camera = null,
    input: ?[:0]const u8 = null,
    input_f16: ?[:0]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    output: ?[:0]const u8 = null,
    facebook: ?[:0]const u8 = null,
    zoom: f32 = 0,
    exposure_time_s: ?f32 = null,
    iso: ?f32 = null,
    aperture: ?f32 = null,
    focal_length_35mm_capture: f32 = 26,
    temperature_k: f32 = 0,
    flash: bool = false,
    seed: u32 = 0,
};

fn parse_float(flag: []const u8, value: []const u8, min: f32, max: f32) f32 {
    const parsed = std.fmt.parseFloat(f32, value) catch fail("{s}: not a number: {s}", .{
        flag,
        value,
    });
    if (!(parsed >= min and parsed <= max)) {
        fail("{s}: {s} is outside {d}..{d}", .{ flag, value, min, max });
    }
    return parsed;
}

fn parse_render(arguments: []const [:0]const u8) RenderOptions {
    var options: RenderOptions = .{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        if (std.mem.eql(u8, flag, "--flash")) {
            options.flash = true;
            continue;
        }
        index += 1;
        if (index >= arguments.len) fail("{s} needs a value", .{flag});
        const value = arguments[index];
        if (std.mem.eql(u8, flag, "--camera")) {
            if (std.mem.eql(u8, value, "canon")) {
                options.camera = .canon_a3400;
            } else if (std.mem.eql(u8, value, "nikon")) {
                options.camera = .nikon_l11;
            } else fail("--camera must be canon or nikon, not {s}", .{value});
        } else if (std.mem.eql(u8, flag, "--input")) {
            options.input = value;
        } else if (std.mem.eql(u8, flag, "--input-f16")) {
            options.input_f16 = value;
        } else if (std.mem.eql(u8, flag, "--width")) {
            options.width = std.fmt.parseInt(u32, value, 10) catch fail("--width: {s}", .{value});
        } else if (std.mem.eql(u8, flag, "--height")) {
            options.height = std.fmt.parseInt(u32, value, 10) catch fail("--height: {s}", .{value});
        } else if (std.mem.eql(u8, flag, "--output")) {
            options.output = value;
        } else if (std.mem.eql(u8, flag, "--facebook")) {
            options.facebook = value;
        } else if (std.mem.eql(u8, flag, "--zoom")) {
            options.zoom = parse_float(flag, value, 0, 1);
        } else if (std.mem.eql(u8, flag, "--exposure-time")) {
            options.exposure_time_s = parse_float(flag, value, 1e-6, 60);
        } else if (std.mem.eql(u8, flag, "--iso")) {
            options.iso = parse_float(flag, value, 1, 1e6);
        } else if (std.mem.eql(u8, flag, "--aperture")) {
            options.aperture = parse_float(flag, value, 0.5, 64);
        } else if (std.mem.eql(u8, flag, "--focal-length-35mm-capture")) {
            options.focal_length_35mm_capture = parse_float(flag, value, 1, 1000);
        } else if (std.mem.eql(u8, flag, "--temperature")) {
            options.temperature_k = parse_float(flag, value, 0, 100000);
        } else if (std.mem.eql(u8, flag, "--seed")) {
            options.seed = std.fmt.parseInt(u32, value, 10) catch fail("--seed: {s}", .{value});
        } else fail("unknown flag {s}", .{flag});
    }
    if (options.camera == null) fail("--camera is required", .{});
    if ((options.input == null) == (options.input_f16 == null)) {
        fail("give exactly one of --input and --input-f16", .{});
    }
    if (options.input_f16 != null and (options.width == null or options.height == null)) {
        fail("--input-f16 needs --width and --height", .{});
    }
    if (options.output == null) fail("--output is required", .{});
    return options;
}

fn input_size(options: *const RenderOptions) image_io.Size {
    const size: image_io.Size = if (options.input) |input|
        image_io.image_size(input) catch |err| fail("{s}: {t}", .{ input, err })
    else
        .{ .width = options.width.?, .height = options.height.? };
    if (size.width > pipeline_module.staging_width_max or
        size.height > pipeline_module.staging_height_max)
    {
        fail("the input is {d}x{d}; the maximum is {d}x{d}", .{
            size.width,
            size.height,
            pipeline_module.staging_width_max,
            pipeline_module.staging_height_max,
        });
    }
    return size;
}

/// Fills the staging buffer from an image file or from a raw RGBA f16 dump of the same layout.
fn load_input(io: std.Io, options: *const RenderOptions, size: image_io.Size, staging: []f16) void {
    if (options.input) |input| {
        image_io.decode_linear_f16(input, size, staging) catch |err| fail("{s}: {t}", .{
            input,
            err,
        });
        return;
    }
    const path = options.input_f16.?;
    const bytes = std.mem.sliceAsBytes(staging);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| fail("{s}: {t}", .{
        path,
        err,
    });
    defer file.close(io);
    const length = file.length(io) catch |err| fail("{s}: {t}", .{ path, err });
    if (length != bytes.len) fail("{s} has {d} bytes; {d}x{d} RGBA f16 needs {d}", .{
        path,
        length,
        size.width,
        size.height,
        bytes.len,
    });
    const read = file.readPositionalAll(io, bytes, 0) catch |err| fail("{s}: {t}", .{ path, err });
    if (read != bytes.len) fail("{s}: short read", .{path});
}

fn render(gpa: std.mem.Allocator, io: std.Io, options: *const RenderOptions) !void {
    const output = options.output.?;
    const size = input_size(options);
    const pipeline = try gpa.create(overshoot.Pipeline);
    defer gpa.destroy(pipeline);
    try pipeline.init(gpa, .{
        .kind = .still,
        .output_width_max = pipeline_module.still_width_max,
        .output_height_max = pipeline_module.still_height_max,
        .thread_count = thread_count,
    });
    defer pipeline.deinit();
    const staging = pipeline.staging(size.width, size.height);
    load_input(io, options, size, staging);
    const metadata_valid = options.exposure_time_s != null and options.iso != null and
        options.aperture != null;
    const frame: pipeline_module.Frame = .{
        .camera = options.camera.?,
        .zoom = options.zoom,
        .capture = .{
            .metadata_valid = metadata_valid,
            .exposure_time_s = options.exposure_time_s orelse 0,
            .iso = options.iso orelse 0,
            .aperture = options.aperture orelse 0,
            .flash_fired = options.flash,
        },
        .focal_length_35mm_capture = options.focal_length_35mm_capture,
        .temperature_k = options.temperature_k,
        .seed = options.seed,
    };
    const result = pipeline.process_still(size.width, size.height, &frame);
    const profile = profiles.profile_for(frame.camera);
    image_io.encode_jpeg_rgba8(
        output,
        result.output_rgba,
        result.output_width,
        result.output_height,
        profile.jpeg_quality,
    ) catch |err| fail("{s}: {t}", .{ output, err });
    if (options.facebook) |facebook| {
        image_io.write_facebook_copy(output, facebook) catch |err| fail("{s}: {t}", .{
            facebook,
            err,
        });
    }
    std.debug.print("{s}: {d}x{d} ISO {d} {d:.4} s f/{d:.1} gain {d:.3}\n", .{
        output,
        result.output_width,
        result.output_height,
        result.virtual.iso,
        result.virtual.exposure_time_s,
        result.virtual.aperture,
        result.virtual.gain,
    });
}

const luma_bins: u32 = 1024;

const Histograms = struct {
    luma: [luma_bins]u64 = @splat(0),
    channel: [3][256]u64 = @splat(@splat(0)),
    count: u64 = 0,
    clipped: u64 = 0,
    saturation_sum: f64 = 0,
    bright: u64 = 0,
    bright_sum: [3]f64 = .{ 0, 0, 0 },
};

fn percentile(histogram: []const u64, count: u64, fraction: f64) f64 {
    assert(count > 0);
    assert(fraction >= 0 and fraction <= 1);
    const wanted: u64 = @intFromFloat(@ceil(fraction * @as(f64, @floatFromInt(count))));
    var cumulative: u64 = 0;
    for (histogram, 0..) |bin, index| {
        cumulative += bin;
        if (cumulative >= @max(wanted, 1)) {
            return (@as(f64, @floatFromInt(index)) + 0.5) / @as(f64, @floatFromInt(histogram.len));
        }
    }
    return 1;
}

fn accumulate(histograms: *Histograms, pixels: []const u8) void {
    assert(pixels.len % 4 == 0);
    assert(histograms.count == 0);
    var index: usize = 0;
    while (index < pixels.len) : (index += 4) {
        const rgb = pixels[index..][0..3];
        var v: [3]f64 = undefined;
        for (&v, rgb, 0..) |*value, byte, c| {
            value.* = @as(f64, @floatFromInt(byte)) / 255;
            histograms.channel[c][byte] += 1;
        }
        const luma = 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
        const bin: usize = @intFromFloat(@min(luma * luma_bins, luma_bins - 1));
        histograms.luma[bin] += 1;
        const max = @max(v[0], v[1], v[2]);
        const min = @min(v[0], v[1], v[2]);
        if (max >= 0.98) histograms.clipped += 1;
        if (max > 0) histograms.saturation_sum += (max - min) / max;
        if (luma > 0.85) {
            histograms.bright += 1;
            for (&histograms.bright_sum, v) |*sum, value| sum.* += value;
        }
        histograms.count += 1;
    }
}

fn stats(gpa: std.mem.Allocator, path: [:0]const u8, writer: *std.Io.Writer) !void {
    const size, const pixels = image_io.decode_srgb8(gpa, path) catch |err| {
        fail("{s}: {t}", .{ path, err });
    };
    defer gpa.free(pixels);
    var histograms: Histograms = .{};
    accumulate(&histograms, pixels);
    const n = histograms.count;
    assert(n == @as(u64, size.width) * size.height);
    const count: f64 = @floatFromInt(n);
    const bright: f64 = @floatFromInt(@max(histograms.bright, 1));
    try writer.print("{s} {d}x{d} luma", .{ path, size.width, size.height });
    for ([_]f64{ 0.005, 0.05, 0.5, 0.95, 0.995 }) |fraction| {
        try writer.print(" {d:.3}", .{percentile(&histograms.luma, n, fraction)});
    }
    try writer.print(" clipped {d:.1}% saturation {d:.3} bright {d:.1}%", .{
        @as(f64, @floatFromInt(histograms.clipped)) / count * 100,
        histograms.saturation_sum / count,
        @as(f64, @floatFromInt(histograms.bright)) / count * 100,
    });
    try writer.print(" rgb {d:.3} {d:.3} {d:.3}", .{
        histograms.bright_sum[0] / bright,
        histograms.bright_sum[1] / bright,
        histograms.bright_sum[2] / bright,
    });
    try writer.print(" p0.5 rgb {d:.3} {d:.3} {d:.3}\n", .{
        percentile(&histograms.channel[0], n, 0.005),
        percentile(&histograms.channel[1], n, 0.005),
        percentile(&histograms.channel[2], n, 0.005),
    });
}

test "percentile: picks the bin that reaches the fraction" {
    // Goal: histogram percentiles match a sorted list. Method: 100 values in 4 bins.
    const histogram = [_]u64{ 10, 40, 40, 10 };
    try std.testing.expectEqual(@as(f64, 0.125), percentile(&histogram, 100, 0.05));
    try std.testing.expectEqual(@as(f64, 0.375), percentile(&histogram, 100, 0.5));
    try std.testing.expectEqual(@as(f64, 0.875), percentile(&histogram, 100, 0.995));
}
