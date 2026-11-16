//! The C ABI declared in `include/overshoot.h`. Arguments from the Swift app are programmer
//! errors and are asserted; allocation failure in `create` is the only operating error.

const std = @import("std");
const assert = std.debug.assert;
const profiles = @import("profiles.zig");
const exposure = @import("exposure.zig");
const pipeline_module = @import("pipeline.zig");
const Pipeline = pipeline_module.Pipeline;

/// The default handler reaches stderr through `std.Io.Threaded`, which references private Darwin
/// symbols (`__ulock_wait2`, `__ulock_wake`) that App Store validation rejects. This handler
/// uses libc only.
pub const panic = std.debug.FullPanic(panic_abort);

fn panic_abort(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = first_trace_address;
    _ = std.c.write(2, message.ptr, message.len);
    _ = std.c.write(2, "\n", 1);
    std.c.abort();
}

const CameraInfo = extern struct {
    make: [*:0]const u8,
    model: [*:0]const u8,
    native_width: u32,
    native_height: u32,
    jpeg_quality: f32,
    file_megabytes_average: f32,
    focal_length_35mm_wide: f32,
    focal_length_35mm_tele: f32,
    has_date_stamp: u32,
};

const FrameC = extern struct {
    camera: u32,
    zoom: f32,
    metadata_valid: u32,
    exposure_time_s: f32,
    iso: f32,
    aperture: f32,
    flash_fired: u32,
    focal_length_35mm_capture: f32,
    temperature_k: f32,
    seed: u32,
};

const SourceBgra8C = extern struct {
    pixels: [*]const u8,
    width: u32,
    height: u32,
    row_bytes: u32,
};

const ResultC = extern struct {
    exposure_time_s: f32,
    iso: f32,
    aperture: f32,
    focal_length_mm: f32,
    focal_length_35mm: f32,
    output_width: u32,
    output_height: u32,
    output_rgba: [*]const u8,
};

const preview_dimension_max: u32 = 4096;

fn camera_from(value: u32) profiles.Camera {
    assert(value < profiles.camera_count);
    const camera: profiles.Camera = @fromBackingInt(value);
    assert(@backingInt(camera) == value);
    return camera;
}

export fn overshoot_camera_info_get(camera: u32) CameraInfo {
    const profile = profiles.profile_for(camera_from(camera));
    assert(profile.make.len > 0);
    return .{
        .make = profile.make.ptr,
        .model = profile.model.ptr,
        .native_width = profile.native_width,
        .native_height = profile.native_height,
        .jpeg_quality = profile.jpeg_quality,
        .file_megabytes_average = profile.file_megabytes_average,
        .focal_length_35mm_wide = profile.focal_length_35mm_wide,
        .focal_length_35mm_tele = profile.focal_length_35mm_tele,
        .has_date_stamp = @intFromBool(profile.has_date_stamp),
    };
}

fn create(options: pipeline_module.Options) ?*Pipeline {
    assert(options.thread_count <= 7);
    assert(options.output_width_max > 0);
    const gpa = std.heap.c_allocator;
    const pipeline = gpa.create(Pipeline) catch return null;
    pipeline.init(gpa, options) catch {
        gpa.destroy(pipeline);
        return null;
    };
    return pipeline;
}

export fn overshoot_preview_create(width: u32, height: u32, thread_count: u32) ?*Pipeline {
    assert(width > 0 and width <= preview_dimension_max);
    assert(height > 0 and height <= preview_dimension_max);
    return create(.{
        .kind = .preview,
        .output_width_max = width,
        .output_height_max = height,
        .thread_count = thread_count,
    });
}

export fn overshoot_still_create(thread_count: u32) ?*Pipeline {
    assert(thread_count <= 7);
    assert(pipeline_module.still_width_max >= pipeline_module.still_height_max);
    return create(.{
        .kind = .still,
        .output_width_max = pipeline_module.still_width_max,
        .output_height_max = pipeline_module.still_height_max,
        .thread_count = thread_count,
    });
}

export fn overshoot_pipeline_destroy(pipeline: ?*Pipeline) void {
    const valid = pipeline.?;
    const gpa = valid.gpa;
    valid.deinit();
    gpa.destroy(valid);
}

fn frame_from(frame: *const FrameC) pipeline_module.Frame {
    assert(frame.metadata_valid <= 1);
    assert(frame.flash_fired <= 1);
    return .{
        .camera = camera_from(frame.camera),
        .zoom = frame.zoom,
        .capture = .{
            .metadata_valid = frame.metadata_valid == 1,
            .exposure_time_s = frame.exposure_time_s,
            .iso = frame.iso,
            .aperture = frame.aperture,
            .flash_fired = frame.flash_fired == 1,
        },
        .focal_length_35mm_capture = frame.focal_length_35mm_capture,
        .temperature_k = frame.temperature_k,
        .seed = frame.seed,
    };
}

fn result_to(result: *const pipeline_module.Result, out: *ResultC) void {
    assert(result.output_rgba.len > 0);
    assert(result.output_width > 0);
    out.* = .{
        .exposure_time_s = result.virtual.exposure_time_s,
        .iso = result.virtual.iso,
        .aperture = result.virtual.aperture,
        .focal_length_mm = result.virtual.focal_length_mm,
        .focal_length_35mm = result.virtual.focal_length_35mm,
        .output_width = result.output_width,
        .output_height = result.output_height,
        .output_rgba = result.output_rgba.ptr,
    };
}

export fn overshoot_preview_process(
    pipeline: ?*Pipeline,
    source: ?*const SourceBgra8C,
    frame: ?*const FrameC,
    result: ?*ResultC,
) void {
    const s = source.?;
    const valid_frame = frame_from(frame.?);
    const processed = pipeline.?.process_preview(.{
        .pixels = s.pixels,
        .width = s.width,
        .height = s.height,
        .row_bytes = s.row_bytes,
    }, &valid_frame);
    result_to(&processed, result.?);
}

export fn overshoot_still_staging(pipeline: ?*Pipeline, width: u32, height: u32) ?*anyopaque {
    const staging = pipeline.?.staging(width, height);
    assert(staging.len == @as(usize, width) * height * 4);
    return staging.ptr;
}

export fn overshoot_still_process(
    pipeline: ?*Pipeline,
    width: u32,
    height: u32,
    frame: ?*const FrameC,
    result: ?*ResultC,
) void {
    assert(width > 0);
    assert(height > 0);
    const valid_frame = frame_from(frame.?);
    const processed = pipeline.?.process_still(width, height, &valid_frame);
    result_to(&processed, result.?);
}

test "c_api: camera info matches the profiles" {
    // Goal: Swift reads camera facts only through this call. Method: compare both cameras.
    const canon = overshoot_camera_info_get(0);
    try std.testing.expectEqualStrings("Canon", std.mem.span(canon.make));
    try std.testing.expectEqual(@as(u32, 1), canon.has_date_stamp);
    const nikon = overshoot_camera_info_get(1);
    try std.testing.expectEqual(@as(u32, 2816), nikon.native_width);
    try std.testing.expectEqual(@as(u32, 0), nikon.has_date_stamp);
}
