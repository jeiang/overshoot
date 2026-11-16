//! The emulation pipeline. Every buffer is allocated in `init`; `process_preview` and
//! `process_still` never allocate or fail.
//!
//! Plane layout: one slab holds planes P0-P6 of `output_width_max * output_height_max` floats.
//! Stages alternate between a result set R and a free set F, which are {P0,P1,P2} and
//! {P3,P4,P5} in either order; P6 is scratch. A still pipeline aliases its RGBA `f16` staging
//! buffer onto P3 onward (consumed by the remap into P0-P2), and every pipeline writes its RGBA8
//! output into the bytes of F1 (consumed by noise reduction before the output stage).

const std = @import("std");
const assert = std.debug.assert;
const profiles = @import("profiles.zig");
const exposure = @import("exposure.zig");
const filters = @import("filters.zig");
const workers_module = @import("workers.zig");
const Workers = workers_module.Workers;
const Rows = workers_module.Rows;
const Camera = profiles.Camera;
const Profile = profiles.Profile;

pub const staging_width_max: u32 = 4032;
pub const staging_height_max: u32 = 3024;
pub const still_width_max: u32 = 4608;
pub const still_height_max: u32 = 3456;
const plane_count: u32 = 7;
const bloom_plane_count: u32 = 4;
const band_count_max: u32 = workers_module.thread_count_max + 1;
const tone_lut_size: u32 = 4096;

comptime {
    for ([_]Profile{ profiles.canon_a3400, profiles.nikon_l11 }) |profile| {
        assert(profile.native_width <= still_width_max);
        assert(profile.native_height <= still_height_max);
    }
    // The staging buffer must fit in planes P3-P6.
    const staging_bytes = @as(u64, staging_width_max) * staging_height_max * 4 * 2;
    assert(staging_bytes <= 4 * @as(u64, still_width_max) * still_height_max * 4);
}

pub const Kind = enum { preview, still };

pub const Options = struct {
    kind: Kind,
    output_width_max: u32,
    output_height_max: u32,
    thread_count: u32,
};

pub const Frame = struct {
    camera: Camera,
    zoom: f32,
    capture: exposure.Capture,
    focal_length_35mm_capture: f32,
    temperature_k: f32,
    seed: u32,
};

pub const SourceBgra8 = struct {
    pixels: [*]const u8,
    width: u32,
    height: u32,
    row_bytes: u32,
};

pub const Result = struct {
    virtual: exposure.Virtual,
    output_width: u32,
    output_height: u32,
    /// Valid until the next `process_*` call.
    output_rgba: []const u8,
};

pub const Pipeline = struct {
    gpa: std.mem.Allocator,
    options: Options,
    slab: []f32,
    plane_capacity: usize,
    bloom: []f32,
    bloom_capacity: usize,
    column_excess: []f32,
    band_sums: [band_count_max][3]f64,
    tone_lut: [tone_lut_size]f32,
    tone_lut_camera: ?Camera,
    workers: Workers,
    busy: bool,

    pub fn init(pipeline: *Pipeline, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.output_width_max > 0);
        assert(options.output_height_max > 0);
        assert(options.thread_count <= workers_module.thread_count_max);
        if (options.kind == .still) {
            assert(options.output_width_max >= still_width_max);
            assert(options.output_height_max >= still_height_max);
        }
        const plane_capacity = @as(usize, options.output_width_max) * options.output_height_max;
        const bloom_capacity = @as(usize, @divCeil(options.output_width_max, 8)) *
            @divCeil(options.output_height_max, 8);
        const slab = try gpa.alloc(f32, plane_count * plane_capacity);
        errdefer gpa.free(slab);
        const bloom = try gpa.alloc(f32, bloom_plane_count * bloom_capacity);
        errdefer gpa.free(bloom);
        const column_excess = try gpa.alloc(f32, band_count_max * options.output_width_max);
        errdefer gpa.free(column_excess);
        pipeline.* = .{
            .gpa = gpa,
            .options = options,
            .slab = slab,
            .plane_capacity = plane_capacity,
            .bloom = bloom,
            .bloom_capacity = bloom_capacity,
            .column_excess = column_excess,
            .band_sums = undefined,
            .tone_lut = undefined,
            .tone_lut_camera = null,
            .workers = undefined,
            .busy = false,
        };
        try pipeline.workers.init(options.thread_count);
    }

    pub fn deinit(pipeline: *Pipeline) void {
        assert(!pipeline.busy);
        assert(pipeline.slab.len == plane_count * pipeline.plane_capacity);
        pipeline.workers.deinit();
        pipeline.gpa.free(pipeline.column_excess);
        pipeline.gpa.free(pipeline.bloom);
        pipeline.gpa.free(pipeline.slab);
        pipeline.* = undefined;
    }

    /// The RGBA `f16` linear sRGB buffer that `process_still` reads, aliased onto P3 onward.
    pub fn staging(pipeline: *Pipeline, width: u32, height: u32) []f16 {
        assert(pipeline.options.kind == .still);
        assert(width > 0 and width <= staging_width_max);
        assert(height > 0 and height <= staging_height_max);
        const base: [*]f16 = @ptrCast(pipeline.slab[3 * pipeline.plane_capacity ..].ptr);
        return base[0 .. @as(usize, width) * height * 4];
    }

    fn plane(pipeline: *Pipeline, index: u32, width: u32, height: u32) []f32 {
        assert(index < plane_count);
        assert(@as(usize, width) * height <= pipeline.plane_capacity);
        return pipeline.slab[index * pipeline.plane_capacity ..][0 .. @as(usize, width) * height];
    }

    fn bloom_plane(pipeline: *Pipeline, index: u32, width: u32, height: u32) []f32 {
        assert(index < bloom_plane_count);
        assert(@as(usize, width) * height <= pipeline.bloom_capacity);
        return pipeline.bloom[index * pipeline.bloom_capacity ..][0 .. @as(usize, width) * height];
    }

    pub fn process_preview(
        pipeline: *Pipeline,
        source: SourceBgra8,
        frame: *const Frame,
    ) Result {
        assert(pipeline.options.kind == .preview);
        assert(source.width > 0 and source.height > 0);
        assert(source.row_bytes >= source.width * 4);
        begin(pipeline, frame);
        defer pipeline.busy = false;
        const width = pipeline.options.output_width_max;
        const height = pipeline.options.output_height_max;
        const decoder: SourceSrgb8 = .{
            .pixels = source.pixels,
            .width = source.width,
            .height = source.height,
            .row_bytes = source.row_bytes,
        };
        run_remap(SourceSrgb8, pipeline, decoder, frame, width, height);
        return process_common(pipeline, frame, width, height, false);
    }

    pub fn process_still(
        pipeline: *Pipeline,
        source_width: u32,
        source_height: u32,
        frame: *const Frame,
    ) Result {
        assert(pipeline.options.kind == .still);
        begin(pipeline, frame);
        defer pipeline.busy = false;
        const profile = profiles.profile_for(frame.camera);
        const decoder: SourceF16 = .{
            .pixels = pipeline.staging(source_width, source_height),
            .width = source_width,
            .height = source_height,
        };
        const width = profile.native_width;
        const height = profile.native_height;
        run_remap(SourceF16, pipeline, decoder, frame, width, height);
        return process_common(pipeline, frame, width, height, true);
    }
};

fn begin(pipeline: *Pipeline, frame: *const Frame) void {
    assert(!pipeline.busy);
    assert(@backingInt(frame.camera) < profiles.camera_count);
    assert(std.math.isFinite(frame.zoom));
    assert(frame.zoom >= 0 and frame.zoom <= 1);
    assert(std.math.isFinite(frame.focal_length_35mm_capture));
    assert(frame.focal_length_35mm_capture > 0);
    assert(std.math.isFinite(frame.temperature_k));
    assert(frame.temperature_k >= 0);
    assert(std.math.isFinite(frame.capture.exposure_time_s));
    assert(std.math.isFinite(frame.capture.iso));
    assert(std.math.isFinite(frame.capture.aperture));
    pipeline.busy = true;
    if (pipeline.tone_lut_camera == null or pipeline.tone_lut_camera.? != frame.camera) {
        build_tone_lut(profiles.profile_for(frame.camera), &pipeline.tone_lut);
        pipeline.tone_lut_camera = frame.camera;
    }
}

const PlaneSet = [3][]f32;

fn plane_set(pipeline: *Pipeline, first: u32, width: u32, height: u32) PlaneSet {
    assert(first == 0 or first == 3);
    assert(width > 0 and height > 0);
    return .{
        pipeline.plane(first, width, height),
        pipeline.plane(first + 1, width, height),
        pipeline.plane(first + 2, width, height),
    };
}

fn process_common(
    pipeline: *Pipeline,
    frame: *const Frame,
    width: u32,
    height: u32,
    still: bool,
) Result {
    assert(pipeline.busy);
    assert(width > 0 and height > 0);
    const profile = profiles.profile_for(frame.camera);
    const scale = @as(f32, @floatFromInt(@max(width, height))) /
        @as(f32, @floatFromInt(profile.native_width));
    const p0 = plane_set(pipeline, 0, width, height);
    const p3 = plane_set(pipeline, 3, width, height);
    const scratch = pipeline.plane(6, width, height);

    const mean_luminance = meter(p0, width, height);
    const virtual = exposure.program(profile, frame.zoom, &frame.capture, mean_luminance);
    const shake = exposure.shake_length_px(profile, &virtual, width);
    var r = p0;
    var f = p3;
    if (still and shake >= 1) {
        run_shake(pipeline, p0, p3, width, height, shake, frame.seed);
        r = p3;
        f = p0;
    }
    const sigma_a = (profile.blur_sigma_px_center + profile.blur_sigma_px_tele_add * frame.zoom) *
        scale;
    const corner = profile.blur_sigma_px_corner;
    const center = profile.blur_sigma_px_center;
    const sigma_b = @sqrt(corner * corner - center * center) * scale;
    for (r, f) |r_c, f_c| {
        blur_plane(pipeline, r_c, f_c, scratch, width, height, sigma_a, null);
        blur_plane(pipeline, f_c, r_c, scratch, width, height, sigma_b, .{ .original = f_c });
    }
    const means = run_stats(pipeline, r, width, height, virtual.gain);
    run_bloom(pipeline, r, width, height, virtual.gain, profile, scale);
    run_mega(pipeline, .{ r, f }, width, height, .{
        .frame = frame,
        .virtual = &virtual,
        .means = means,
        .scale = scale,
    });
    finish(pipeline, .{ r, f }, scratch, width, height, profile, &virtual, scale);
    const output = std.mem.sliceAsBytes(f[1]);
    assert(output.len == @as(usize, width) * height * 4);
    return .{
        .virtual = virtual,
        .output_width = width,
        .output_height = height,
        .output_rgba = output,
    };
}

/// Noise reduction, sharpening and RGBA8 output: YCbCr in F becomes RGBA8 in the bytes of F1.
fn finish(
    pipeline: *Pipeline,
    sets: [2]PlaneSet,
    scratch: []f32,
    width: u32,
    height: u32,
    profile: *const Profile,
    virtual: *const exposure.Virtual,
    scale: f32,
) void {
    const r = sets[0];
    const f = sets[1];
    assert(scratch.len == r[0].len);
    assert(virtual.iso > 0);
    const iso_factor = @sqrt(virtual.iso / 100);
    const chroma_sigma = @min(profile.nr_chroma_sigma_px * scale * iso_factor, 10);
    blur_plane(pipeline, f[1], r[1], scratch, width, height, chroma_sigma, null);
    blur_plane(pipeline, f[2], r[2], scratch, width, height, chroma_sigma, null);
    const sigma_pass: SigmaPass = .{
        .source = f[0],
        .target = r[0],
        .width = width,
        .height = height,
        .threshold = profile.nr_luma_threshold * iso_factor,
    };
    run_stage(pipeline, &sigma_pass);
    // Sharpening: F0 holds the blurred luma; the output stage applies the unsharp mask.
    const sharpen_sigma = profile.sharpen_sigma_px * scale;
    blur_plane(pipeline, r[0], f[0], scratch, width, height, sharpen_sigma, null);
    const output_pass: OutputPass = .{
        .luma = r[0],
        .blurred = f[0],
        .cb = r[1],
        .cr = r[2],
        .amount = profile.sharpen_amount,
        .out = std.mem.sliceAsBytes(f[1]),
        .width = width,
        .height = height,
    };
    run_stage(pipeline, &output_pass);
}

fn Stage(comptime Context: type) type {
    return struct {
        fn function(opaque_context: *const anyopaque, band_index: u32, band_count: u32) void {
            const context: *const Context = @ptrCast(@alignCast(opaque_context));
            const rows = workers_module.band_rows(band_index, band_count, context.height);
            context.run(rows, band_index);
        }
    };
}

fn run_stage(pipeline: *Pipeline, context: anytype) void {
    const Context = @TypeOf(context.*);
    assert(context.height > 0);
    assert(pipeline.busy);
    pipeline.workers.run(.{ .function = Stage(Context).function, .context = context });
}

// Remap: lens distortion, chromatic aberration, zoom crop and resampling.

const srgb_to_linear_table: [256]f32 = blk: {
    @setEvalBranchQuota(256 * 1000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*entry, index| {
        const v: f32 = @as(f32, @floatFromInt(index)) / 255;
        entry.* = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    break :blk table;
};

const SourceSrgb8 = struct {
    pixels: [*]const u8,
    width: u32,
    height: u32,
    row_bytes: u32,

    fn texel(source: *const SourceSrgb8, x: u32, y: u32, channel: u32) f32 {
        assert(x < source.width);
        assert(channel < 3);
        // BGRA byte order: red is byte 2, blue is byte 0.
        const byte = source.pixels[@as(usize, y) * source.row_bytes + x * 4 + (2 - channel)];
        return srgb_to_linear_table[byte];
    }
};

const SourceF16 = struct {
    pixels: []const f16,
    width: u32,
    height: u32,

    fn texel(source: *const SourceF16, x: u32, y: u32, channel: u32) f32 {
        assert(x < source.width);
        assert(channel < 3);
        return source.pixels[(@as(usize, y) * source.width + x) * 4 + channel];
    }
};

fn sample_source(comptime Source: type, source: *const Source, x: f32, y: f32, channel: u32) f32 {
    assert(source.width > 0);
    assert(source.height > 0);
    const fx = std.math.clamp(x - 0.5, 0, @as(f32, @floatFromInt(source.width - 1)));
    const fy = std.math.clamp(y - 0.5, 0, @as(f32, @floatFromInt(source.height - 1)));
    const x0: u32 = @intFromFloat(fx);
    const y0: u32 = @intFromFloat(fy);
    const x1 = @min(x0 + 1, source.width - 1);
    const y1 = @min(y0 + 1, source.height - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    const a = source.texel(x0, y0, channel);
    const b = source.texel(x1, y0, channel);
    const c = source.texel(x0, y1, channel);
    const d = source.texel(x1, y1, channel);
    const top = a + (b - a) * tx;
    const bottom = c + (d - c) * tx;
    return top + (bottom - top) * ty;
}

pub const RemapParams = struct {
    k1: f32,
    chromatic_aberration: f32,
    crop: f32,
};

fn remap_params(frame: *const Frame) RemapParams {
    const profile = profiles.profile_for(frame.camera);
    const zoom = frame.zoom;
    const k1 = profile.distortion_k1_wide + (profile.distortion_k1_tele -
        profile.distortion_k1_wide) * zoom;
    const ca = profile.chromatic_aberration_wide + (profile.chromatic_aberration_tele -
        profile.chromatic_aberration_wide) * zoom;
    var crop = frame.focal_length_35mm_capture / exposure.focal_length_35mm_at(profile, zoom);
    // Keep the distorted corners inside the source.
    crop = @min(crop, 1 / ((1 + @max(k1, 0)) * (1 + ca)));
    assert(crop > 0);
    assert(crop <= 1);
    return .{ .k1 = k1, .chromatic_aberration = ca, .crop = crop };
}

fn Remap(comptime Source: type) type {
    return struct {
        source: Source,
        out: PlaneSet,
        width: u32,
        height: u32,
        params: RemapParams,
        supersample: u32,

        const Self = @This();

        fn run(remap: *const Self, rows: Rows, band_index: u32) void {
            assert(band_index < band_count_max);
            assert(rows.end <= remap.height);
            const w: f32 = @floatFromInt(remap.width);
            const h: f32 = @floatFromInt(remap.height);
            const sw: f32 = @floatFromInt(remap.source.width);
            const sh: f32 = @floatFromInt(remap.source.height);
            const half_d = @sqrt(w * w + h * h) / 2;
            const source_scale = @sqrt(sw * sw + sh * sh) / 2 * remap.params.crop;
            const ss = remap.supersample;
            const ss_f: f32 = @floatFromInt(ss);
            const weight = 1 / (ss_f * ss_f);
            const ca = remap.params.chromatic_aberration;
            const channel_factor = [3]f32{ 1 + ca, 1, 1 - ca };
            for (rows.begin..rows.end) |y| {
                for (0..remap.width) |x| {
                    var sum: [3]f32 = .{ 0, 0, 0 };
                    for (0..ss) |sy| {
                        for (0..ss) |sx| {
                            const px = @as(f32, @floatFromInt(x)) +
                                (@as(f32, @floatFromInt(sx)) + 0.5) / ss_f;
                            const py = @as(f32, @floatFromInt(y)) +
                                (@as(f32, @floatFromInt(sy)) + 0.5) / ss_f;
                            const u = (px - w / 2) / half_d;
                            const v = (py - h / 2) / half_d;
                            const radial = 1 + remap.params.k1 * (u * u + v * v);
                            for (0..3) |c| {
                                const factor = radial * channel_factor[c] * source_scale;
                                const sx_c = sw / 2 + u * factor;
                                const sy_c = sh / 2 + v * factor;
                                const channel: u32 = @intCast(c);
                                sum[c] += sample_source(Source, &remap.source, sx_c, sy_c, channel);
                            }
                        }
                    }
                    for (0..3) |c| remap.out[c][y * remap.width + x] = sum[c] * weight;
                }
            }
        }
    };
}

fn run_remap(
    comptime Source: type,
    pipeline: *Pipeline,
    source: Source,
    frame: *const Frame,
    width: u32,
    height: u32,
) void {
    const aspect_source = @as(f32, @floatFromInt(source.width)) /
        @as(f32, @floatFromInt(source.height));
    const aspect_output = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    assert(@abs(aspect_source / aspect_output - 1) < 0.01);
    const params = remap_params(frame);
    const out = plane_set(pipeline, 0, width, height);
    remap_into(Source, pipeline, source, params, out, width, height);
}

fn remap_into(
    comptime Source: type,
    pipeline: *Pipeline,
    source: Source,
    params: RemapParams,
    out: PlaneSet,
    out_w: u32,
    out_h: u32,
) void {
    assert(out[0].len == @as(usize, out_w) * out_h);
    assert(params.crop > 0);
    const sw: f32 = @floatFromInt(source.width);
    const sh: f32 = @floatFromInt(source.height);
    const ow: f32 = @floatFromInt(out_w);
    const oh: f32 = @floatFromInt(out_h);
    const ratio = @sqrt(sw * sw + sh * sh) * params.crop / @sqrt(ow * ow + oh * oh);
    const supersample: u32 = @intFromFloat(std.math.clamp(@ceil(ratio), 1, 4));
    const remap: Remap(Source) = .{
        .source = source,
        .out = out,
        .width = out_w,
        .height = out_h,
        .params = params,
        .supersample = supersample,
    };
    run_stage(pipeline, &remap);
}

// Meter, shake, blur.

fn meter(planes: PlaneSet, width: u32, height: u32) f32 {
    assert(planes[0].len == @as(usize, width) * height);
    assert(width > 0 and height > 0);
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const half_d = @sqrt(w * w + h * h) / 2;
    var sum: f64 = 0;
    var weight_sum: f64 = 0;
    var y: u32 = 0;
    while (y < height) : (y += 8) {
        var x: u32 = 0;
        while (x < width) : (x += 8) {
            const index = @as(usize, y) * width + x;
            // Clipped at white like a sensor's meter: RAW input carries lamps at up to 9x white,
            // which would otherwise pull the exposure down by several stops.
            const luma = @min(0.2126 * planes[0][index] + 0.7152 * planes[1][index] +
                0.0722 * planes[2][index], 1);
            const u = (@as(f32, @floatFromInt(x)) + 0.5 - w / 2) / half_d;
            const v = (@as(f32, @floatFromInt(y)) + 0.5 - h / 2) / half_d;
            const weight = 1 + 2 * @exp(-(u * u + v * v) / (2 * 0.3 * 0.3));
            sum += luma * weight;
            weight_sum += weight;
        }
    }
    assert(weight_sum > 0);
    return @floatCast(sum / weight_sum);
}

const ShakePass = struct {
    source: PlaneSet,
    target: PlaneSet,
    width: u32,
    height: u32,
    dx: f32,
    dy: f32,
    samples: u32,

    fn run(shake: *const ShakePass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(shake.samples >= 2);
        const steps: f32 = @floatFromInt(shake.samples - 1);
        const weight = 1 / @as(f32, @floatFromInt(shake.samples));
        for (rows.begin..rows.end) |y| {
            for (0..shake.width) |x| {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                for (0..3) |c| {
                    var sum: f32 = 0;
                    for (0..shake.samples) |k| {
                        const t = @as(f32, @floatFromInt(k)) / steps - 0.5;
                        const sx = px + t * shake.dx;
                        const sy = py + t * shake.dy;
                        const plane = shake.source[c];
                        sum += filters.sample_bilinear(plane, shake.width, shake.height, sx, sy);
                    }
                    shake.target[c][y * shake.width + x] = sum * weight;
                }
            }
        }
    }
};

fn run_shake(
    pipeline: *Pipeline,
    source: PlaneSet,
    target: PlaneSet,
    width: u32,
    height: u32,
    length: f32,
    seed: u32,
) void {
    assert(length >= 1);
    assert(std.math.isFinite(length));
    const angle = 2 * std.math.pi * (@as(f32, @floatFromInt(filters.noise_hash(seed, 0, 0, 9))) /
        4294967296.0);
    const shake: ShakePass = .{
        .source = source,
        .target = target,
        .width = width,
        .height = height,
        .dx = length * @cos(angle),
        .dy = length * @sin(angle),
        .samples = @min(@as(u32, @intFromFloat(@ceil(length))) + 1, 64),
    };
    run_stage(pipeline, &shake);
}

const BlurPass = struct {
    source: []const f32,
    target: []f32,
    width: u32,
    height: u32,
    kernel: *const filters.Kernel,
    radius: u32,
    horizontal: bool,
    blend: ?filters.BlendRadial,

    fn run(blur: *const BlurPass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(rows.end <= blur.height);
        if (blur.horizontal) {
            filters.blur_rows_horizontal(
                blur.source,
                blur.target,
                blur.width,
                rows.begin,
                rows.end,
                blur.kernel,
                blur.radius,
            );
        } else {
            filters.blur_rows_vertical(
                blur.source,
                blur.target,
                blur.width,
                blur.height,
                rows.begin,
                rows.end,
                blur.kernel,
                blur.radius,
                blur.blend,
            );
        }
    }
};

/// Gaussian blur of `source` into `target` through `scratch`, row-parallel in both passes.
fn blur_plane(
    pipeline: *Pipeline,
    source: []const f32,
    target: []f32,
    scratch: []f32,
    width: u32,
    height: u32,
    sigma_px: f32,
    blend: ?filters.BlendRadial,
) void {
    assert(source.len == @as(usize, width) * height);
    assert(target.len == source.len);
    var kernel: filters.Kernel = undefined;
    const radius = filters.gaussian_kernel(sigma_px, &kernel);
    var pass: BlurPass = .{
        .source = source,
        .target = scratch[0..source.len],
        .width = width,
        .height = height,
        .kernel = &kernel,
        .radius = radius,
        .horizontal = true,
        .blend = null,
    };
    run_stage(pipeline, &pass);
    pass.source = scratch[0..source.len];
    pass.target = target;
    pass.horizontal = false;
    pass.blend = blend;
    run_stage(pipeline, &pass);
}

// Stats and bloom.

const StatsPass = struct {
    planes: PlaneSet,
    width: u32,
    height: u32,
    gain: f32,
    column_excess: []f32,
    band_sums: *[band_count_max][3]f64,

    fn run(stats: *const StatsPass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(rows.end <= stats.height);
        const excess = stats.column_excess[band_index * stats.width ..][0..stats.width];
        @memset(excess, 0);
        var sums: [3]f64 = .{ 0, 0, 0 };
        for (rows.begin..rows.end) |y| {
            const offset = y * stats.width;
            for (0..3) |c| {
                var row_sum: f32 = 0;
                for (stats.planes[c][offset..][0..stats.width]) |value| row_sum += value;
                sums[c] += row_sum;
            }
            for (excess, stats.planes[1][offset..][0..stats.width]) |*e, g| {
                e.* += @max(g * stats.gain - 1, 0);
            }
        }
        stats.band_sums[band_index] = sums;
    }
};

/// Returns the per-channel means and leaves the smear profile in row 0 of `column_excess`.
fn run_stats(pipeline: *Pipeline, planes: PlaneSet, width: u32, height: u32, gain: f32) [3]f32 {
    assert(width <= pipeline.options.output_width_max);
    assert(gain > 0);
    const stats: StatsPass = .{
        .planes = planes,
        .width = width,
        .height = height,
        .gain = gain,
        .column_excess = pipeline.column_excess,
        .band_sums = &pipeline.band_sums,
    };
    run_stage(pipeline, &stats);
    const band_count = pipeline.workers.thread_count + 1;
    var totals: [3]f64 = .{ 0, 0, 0 };
    for (pipeline.band_sums[0..band_count]) |sums| {
        for (&totals, sums) |*total, sum| total.* += sum;
    }
    const excess = pipeline.column_excess;
    const h: f32 = @floatFromInt(height);
    for (0..width) |x| {
        var sum: f32 = 0;
        for (0..band_count) |band| sum += excess[band * width + x];
        excess[x] = sum / h;
    }
    const pixels: f64 = @floatFromInt(@as(u64, width) * height);
    return .{
        @floatCast(totals[0] / pixels),
        @floatCast(totals[1] / pixels),
        @floatCast(totals[2] / pixels),
    };
}

const BloomDownsample = struct {
    planes: PlaneSet,
    width: u32,
    image_height: u32,
    bloom: PlaneSet,
    bloom_width: u32,
    /// Bloom rows, which the bands split.
    height: u32,
    gain: f32,
    threshold: f32,

    fn run(down: *const BloomDownsample, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(rows.end <= down.height);
        for (rows.begin..rows.end) |by| {
            const y_begin = by * 8;
            const y_end = @min(y_begin + 8, down.image_height);
            for (0..down.bloom_width) |bx| {
                const x_begin = bx * 8;
                const x_end = @min(x_begin + 8, down.width);
                const count: f32 = @floatFromInt((y_end - y_begin) * (x_end - x_begin));
                for (0..3) |c| {
                    var sum: f32 = 0;
                    for (y_begin..y_end) |y| {
                        for (down.planes[c][y * down.width ..][x_begin..x_end]) |value| {
                            // Clipped like the sensor: RAW highlights reach up to 16x white after
                            // gain and would spread a haze over the shadows.
                            sum += @max(@min(value * down.gain, 1) - down.threshold, 0);
                        }
                    }
                    down.bloom[c][by * down.bloom_width + bx] = sum / count;
                }
            }
        }
    }
};

fn run_bloom(
    pipeline: *Pipeline,
    planes: PlaneSet,
    width: u32,
    height: u32,
    gain: f32,
    profile: *const Profile,
    scale: f32,
) void {
    assert(gain > 0);
    assert(scale > 0);
    const bloom_width = @divCeil(width, 8);
    const bloom_height = @divCeil(height, 8);
    const bloom: PlaneSet = .{
        pipeline.bloom_plane(0, bloom_width, bloom_height),
        pipeline.bloom_plane(1, bloom_width, bloom_height),
        pipeline.bloom_plane(2, bloom_width, bloom_height),
    };
    const down: BloomDownsample = .{
        .planes = planes,
        .width = width,
        .image_height = height,
        .bloom = bloom,
        .bloom_width = bloom_width,
        .height = bloom_height,
        .gain = gain,
        .threshold = profile.bloom_threshold,
    };
    run_stage(pipeline, &down);
    const scratch = pipeline.bloom_plane(3, bloom_width, bloom_height);
    const sigma = profile.bloom_sigma_px * scale / 8;
    for (bloom) |b| blur_plane(pipeline, b, b, scratch, bloom_width, bloom_height, sigma, null);
}

// The pointwise mega-pass: exposure, flare, bloom, vignette, smear, noise, white balance,
// saturation, tone curve, and conversion to JPEG YCbCr.

const MegaPass = struct {
    source: PlaneSet,
    target: PlaneSet,
    width: u32,
    height: u32,
    gain: f32,
    flare_add: [3]f32,
    bloom: PlaneSet,
    bloom_width: u32,
    bloom_height: u32,
    bloom_strength: f32,
    vignette_strength: f32,
    smear_strength: f32,
    column_excess: []const f32,
    noise_shot: f32,
    noise_read: f32,
    noise_scale: f32,
    seed: u32,
    block: u32,
    white_balance: [3]f32,
    saturation: f32,
    tone_lut: *const [tone_lut_size]f32,

    fn run(mega: *const MegaPass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(rows.end <= mega.height);
        const w: f32 = @floatFromInt(mega.width);
        const h: f32 = @floatFromInt(mega.height);
        const half_d_squared = (w * w + h * h) / 4;
        for (rows.begin..rows.end) |y| {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            for (0..mega.width) |x| {
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const dx = fx - w / 2;
                const dy = fy - h / 2;
                const r2 = (dx * dx + dy * dy) / half_d_squared;
                const index = y * mega.width + x;
                const linear = mega.sensor(index, @intCast(x), @intCast(y), fx, fy, r2);
                const ycc = mega.develop(linear);
                for (0..3) |c| mega.target[c][index] = ycc[c];
            }
        }
    }

    /// Light on the emulated sensor, after the sensor clip.
    fn sensor(
        mega: *const MegaPass,
        index: usize,
        x: u32,
        y: u32,
        fx: f32,
        fy: f32,
        r2: f32,
    ) [3]f32 {
        assert(r2 >= 0);
        assert(x < mega.width);
        const n_luma = filters.normal_approx(filters.noise_hash(mega.seed, x, y, 3));
        const bx = x / mega.block;
        const by = y / mega.block;
        var out: [3]f32 = undefined;
        for (0..3) |c| {
            var v = mega.source[c][index] * mega.gain + mega.flare_add[c];
            const bloom = filters.sample_bilinear(
                mega.bloom[c],
                mega.bloom_width,
                mega.bloom_height,
                fx / 8,
                fy / 8,
            );
            v += mega.bloom_strength * bloom;
            v *= 1 - mega.vignette_strength * r2;
            v += mega.smear_strength * mega.column_excess[x];
            const sigma = @sqrt(@max(v, 0) * mega.noise_shot + mega.noise_read * mega.noise_read) *
                mega.noise_scale;
            const chroma_hash = filters.noise_hash(mega.seed, bx, by, @intCast(c));
            const n_chroma = filters.normal_approx(chroma_hash);
            v += sigma * (0.6 * n_luma + 0.8 * n_chroma);
            out[c] = std.math.clamp(v, 0, 1);
        }
        return out;
    }

    /// White balance, saturation, tone curve, and RGB to JPEG YCbCr.
    fn develop(mega: *const MegaPass, linear: [3]f32) [3]f32 {
        assert(linear[0] >= 0);
        assert(mega.saturation > 0);
        var rgb: [3]f32 = undefined;
        for (&rgb, linear, mega.white_balance) |*out, v, gain| out.* = v * gain;
        const luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        const s = mega.saturation;
        for (&rgb) |*v| {
            const saturated = @max(s * v.* + (1 - s) * luma, 0);
            const lut_position = @round(@min(saturated, 1) * (tone_lut_size - 1));
            const lut_index: usize = @intFromFloat(lut_position);
            v.* = mega.tone_lut[lut_index];
        }
        return .{
            0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2],
            -0.168736 * rgb[0] - 0.331264 * rgb[1] + 0.5 * rgb[2],
            0.5 * rgb[0] - 0.418688 * rgb[1] - 0.081312 * rgb[2],
        };
    }
};

const MegaInputs = struct {
    frame: *const Frame,
    virtual: *const exposure.Virtual,
    means: [3]f32,
    scale: f32,
};

fn run_mega(pipeline: *Pipeline, sets: [2]PlaneSet, width: u32, height: u32, in: MegaInputs) void {
    assert(in.scale > 0);
    assert(in.virtual.gain > 0);
    const profile = profiles.profile_for(in.frame.camera);
    const gain = in.virtual.gain;
    const iso_factor = in.virtual.iso / 100;
    const bloom_width = @divCeil(width, 8);
    const bloom_height = @divCeil(height, 8);
    const mega: MegaPass = .{
        .source = sets[0],
        .target = sets[1],
        .width = width,
        .height = height,
        .gain = gain,
        .flare_add = .{
            profile.flare * in.means[0] * gain,
            profile.flare * in.means[1] * gain,
            profile.flare * in.means[2] * gain,
        },
        .bloom = .{
            pipeline.bloom_plane(0, bloom_width, bloom_height),
            pipeline.bloom_plane(1, bloom_width, bloom_height),
            pipeline.bloom_plane(2, bloom_width, bloom_height),
        },
        .bloom_width = bloom_width,
        .bloom_height = bloom_height,
        .bloom_strength = profile.bloom_strength,
        .vignette_strength = profile.vignette_strength,
        .smear_strength = profile.smear_strength,
        .column_excess = pipeline.column_excess[0..width],
        .noise_shot = profile.noise_shot * iso_factor,
        .noise_read = profile.noise_read * iso_factor,
        .noise_scale = in.scale,
        .seed = in.frame.seed,
        .block = @max(1, @as(u32, @intFromFloat(@round(2 * in.scale)))),
        .white_balance = exposure.white_balance_gains(profile, in.frame.temperature_k),
        .saturation = profile.saturation,
        .tone_lut = &pipeline.tone_lut,
    };
    run_stage(pipeline, &mega);
}

fn srgb_oetf(x: f32) f32 {
    assert(x >= 0);
    assert(x <= 1);
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

/// Linear light to display value: a black clip, sRGB encoding, an S-curve, and a black lift.
fn build_tone_lut(profile: *const Profile, lut: *[tone_lut_size]f32) void {
    assert(@abs(profile.tone_contrast) < 1);
    assert(profile.tone_black_lift >= 0);
    assert(profile.tone_black_clip >= 0);
    assert(profile.tone_black_clip < 1);
    const k = profile.tone_contrast;
    const lift = profile.tone_black_lift;
    const clip = profile.tone_black_clip;
    for (lut, 0..) |*entry, index| {
        const x = @as(f32, @floatFromInt(index)) / (tone_lut_size - 1);
        var v = srgb_oetf(@max(x - clip, 0) / (1 - clip));
        v += k * v * (1 - v) * (2 * v - 1);
        entry.* = lift + (1 - lift) * v;
    }
    lut[0] = lift;
    lut[tone_lut_size - 1] = 1;
}

// Noise reduction and output.

const SigmaPass = struct {
    source: []const f32,
    target: []f32,
    width: u32,
    height: u32,
    threshold: f32,

    fn run(pass: *const SigmaPass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(rows.end <= pass.height);
        filters.sigma_filter_rows(
            pass.source,
            pass.target,
            pass.width,
            pass.height,
            rows.begin,
            rows.end,
            pass.threshold,
        );
    }
};

const OutputPass = struct {
    luma: []const f32,
    blurred: []const f32,
    cb: []const f32,
    cr: []const f32,
    amount: f32,
    out: []u8,
    width: u32,
    height: u32,

    fn run(pass: *const OutputPass, rows: Rows, band_index: u32) void {
        assert(band_index < band_count_max);
        assert(pass.out.len == @as(usize, pass.width) * pass.height * 4);
        for (rows.begin * pass.width..rows.end * pass.width) |index| {
            const luma = pass.luma[index];
            // Unsharp mask without a clamp: the clamp at output makes the overshoot halos.
            const y = luma + pass.amount * (luma - pass.blurred[index]);
            const cb = pass.cb[index];
            const cr = pass.cr[index];
            const rgb = [3]f32{ y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb };
            for (rgb, 0..) |v, c| {
                pass.out[index * 4 + c] = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
            pass.out[index * 4 + 3] = 255;
        }
    }
};

test "tone lut: monotonic from the black lift to 1" {
    // Goal: the tone curve never inverts. Method: build both LUTs and scan them.
    for ([_]*const Profile{ &profiles.canon_a3400, &profiles.nikon_l11 }) |profile| {
        var lut: [tone_lut_size]f32 = undefined;
        build_tone_lut(profile, &lut);
        try std.testing.expectEqual(profile.tone_black_lift, lut[0]);
        try std.testing.expectEqual(@as(f32, 1), lut[tone_lut_size - 1]);
        for (lut[1..], lut[0 .. tone_lut_size - 1]) |next, previous| {
            try std.testing.expect(next >= previous);
        }
    }
}

test "remap: identity settings reproduce the source" {
    // Goal: the resampler adds no shift. Method: remap a gradient with k1 = 0, no aberration,
    // crop 1, at the same size.
    const width = 24;
    const height = 18;
    var pipeline: Pipeline = undefined;
    try pipeline.init(std.testing.allocator, .{
        .kind = .preview,
        .output_width_max = width,
        .output_height_max = height,
        .thread_count = 2,
    });
    defer pipeline.deinit();
    var pixels: [width * height * 4]f16 = undefined;
    for (0..width * height) |index| {
        for (0..4) |c| {
            pixels[index * 4 + c] = @floatCast(@as(f32, @floatFromInt(index * (c + 1))) / 2000);
        }
    }
    const source: SourceF16 = .{ .pixels = &pixels, .width = width, .height = height };
    pipeline.busy = true;
    defer pipeline.busy = false;
    const out = plane_set(&pipeline, 0, width, height);
    const identity: RemapParams = .{ .k1 = 0, .chromatic_aberration = 0, .crop = 1 };
    remap_into(SourceF16, &pipeline, source, identity, out, width, height);
    for (0..width * height) |index| {
        for (0..3) |c| {
            const expected: f32 = pixels[index * 4 + c];
            try std.testing.expectApproxEqAbs(expected, out[c][index], 1e-5);
        }
    }
}

fn render_test_preview(thread_count: u32, seed: u32, output: []u8) !void {
    const width = 64;
    const height = 48;
    var pipeline: Pipeline = undefined;
    try pipeline.init(std.testing.allocator, .{
        .kind = .preview,
        .output_width_max = width,
        .output_height_max = height,
        .thread_count = thread_count,
    });
    defer pipeline.deinit();
    var pixels: [128 * 96 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% index / 512);
    const frame: Frame = .{
        .camera = .nikon_l11,
        .zoom = 0.3,
        .capture = .{
            .metadata_valid = true,
            .exposure_time_s = 1.0 / 60.0,
            .iso = 400,
            .aperture = 1.6,
            .flash_fired = false,
        },
        .focal_length_35mm_capture = 26,
        .temperature_k = 3200,
        .seed = seed,
    };
    const result = pipeline.process_preview(.{
        .pixels = &pixels,
        .width = 128,
        .height = 96,
        .row_bytes = 128 * 4,
    }, &frame);
    try std.testing.expectEqual(@as(u32, width), result.output_width);
    @memcpy(output, result.output_rgba);
}

test "pipeline: deterministic across thread counts, seed-dependent" {
    // Goal: the output depends on the seed only. Method: render with 1 and 3 bands, then with
    // another seed.
    var one: [64 * 48 * 4]u8 = undefined;
    var three: [64 * 48 * 4]u8 = undefined;
    var other: [64 * 48 * 4]u8 = undefined;
    try render_test_preview(0, 1, &one);
    try render_test_preview(2, 1, &three);
    try render_test_preview(2, 2, &other);
    try std.testing.expectEqualSlices(u8, &one, &three);
    try std.testing.expect(!std.mem.eql(u8, &one, &other));
}
