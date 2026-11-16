//! Hot loops as standalone functions over planes of `f32`. Every function works on a band of
//! rows so the pipeline can split it across workers.

const std = @import("std");
const assert = std.debug.assert;

pub const kernel_radius_max: u32 = 32;
pub const Kernel = [2 * kernel_radius_max + 1]f32;

const lanes = 8;
const V = @Vector(lanes, f32);

/// Fills `kernel` with a normalized Gaussian and returns its radius, `ceil(3 * sigma)` capped at
/// 32. A sigma below 0.3 gives radius 0 and the kernel `{1}`, which is a copy.
pub fn gaussian_kernel(sigma_px: f32, kernel: *Kernel) u32 {
    assert(std.math.isFinite(sigma_px));
    assert(sigma_px >= 0);
    kernel.* = @splat(0);
    if (sigma_px < 0.3) {
        kernel[0] = 1;
        return 0;
    }
    const radius: u32 = @min(kernel_radius_max, @as(u32, @intFromFloat(@ceil(3 * sigma_px))));
    var sum: f32 = 0;
    for (0..2 * radius + 1) |index| {
        const d: f32 = @as(f32, @floatFromInt(index)) - @as(f32, @floatFromInt(radius));
        kernel[index] = @exp(-d * d / (2 * sigma_px * sigma_px));
        sum += kernel[index];
    }
    for (kernel[0 .. 2 * radius + 1]) |*weight| weight.* /= sum;
    assert(radius >= 1);
    assert(sum > 0);
    return radius;
}

pub fn blur_rows_horizontal(
    source: []const f32,
    target: []f32,
    width: u32,
    row_begin: u32,
    row_end: u32,
    kernel: *const Kernel,
    radius: u32,
) void {
    assert(row_begin <= row_end);
    assert(@as(usize, row_end) * width <= source.len);
    assert(@as(usize, row_end) * width <= target.len);
    assert(radius <= kernel_radius_max);
    const w: i64 = width;
    const r: i64 = radius;
    for (row_begin..row_end) |y| {
        const row = source[y * width ..][0..width];
        const out = target[y * width ..][0..width];
        for (0..width) |x| {
            var sum: f32 = 0;
            const xi: i64 = @intCast(x);
            if (xi >= r and xi + r < w) {
                const window = row[x - radius ..][0 .. 2 * radius + 1];
                for (window, kernel[0 .. 2 * radius + 1]) |value, weight| sum += value * weight;
            } else {
                for (0..2 * radius + 1) |k| {
                    const sx = std.math.clamp(xi + @as(i64, @intCast(k)) - r, 0, w - 1);
                    sum += row[@intCast(sx)] * kernel[k];
                }
            }
            out[x] = sum;
        }
    }
}

/// When set, the vertical pass writes `lerp(original[x], blurred, r^2)`, where `r` is the
/// distance to the image centre divided by the half-diagonal: corners get the full blur.
pub const BlendRadial = struct {
    original: []const f32,
};

pub fn blur_rows_vertical(
    source: []const f32,
    target: []f32,
    width: u32,
    height: u32,
    row_begin: u32,
    row_end: u32,
    kernel: *const Kernel,
    radius: u32,
    blend: ?BlendRadial,
) void {
    assert(row_begin <= row_end);
    assert(row_end <= height);
    assert(@as(usize, height) * width <= source.len);
    assert(@as(usize, height) * width <= target.len);
    assert(radius <= kernel_radius_max);
    const h: i64 = height;
    for (row_begin..row_end) |y| {
        const out = target[y * width ..][0..width];
        var x: usize = 0;
        while (x + lanes <= width) : (x += lanes) {
            var sum: V = @splat(0);
            for (0..2 * radius + 1) |k| {
                const sy = std.math.clamp(@as(i64, @intCast(y + k)) - radius, 0, h - 1);
                const offset = @as(usize, @intCast(sy)) * width + x;
                const values: V = source[offset..][0..lanes].*;
                sum += values * @as(V, @splat(kernel[k]));
            }
            out[x..][0..lanes].* = sum;
        }
        while (x < width) : (x += 1) {
            var sum: f32 = 0;
            for (0..2 * radius + 1) |k| {
                const sy = std.math.clamp(@as(i64, @intCast(y + k)) - radius, 0, h - 1);
                sum += source[@as(usize, @intCast(sy)) * width + x] * kernel[k];
            }
            out[x] = sum;
        }
        if (blend) |b| blend_radial_row(b.original, out, width, height, @intCast(y));
    }
}

fn blend_radial_row(original: []const f32, out: []f32, width: u32, height: u32, y: u32) void {
    assert(out.len == width);
    assert(y < height);
    const half_w: f32 = @as(f32, @floatFromInt(width)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(height)) / 2;
    const half_diagonal_squared = half_w * half_w + half_h * half_h;
    const dy = @as(f32, @floatFromInt(y)) + 0.5 - half_h;
    const row = original[@as(usize, y) * width ..][0..width];
    for (out, row, 0..) |*value, base, x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - half_w;
        const weight = (dx * dx + dy * dy) / half_diagonal_squared;
        value.* = base + (value.* - base) * weight;
    }
}

/// Edge-preserving smoothing: the mean of the 5x5 neighbours whose value is within `threshold`
/// of the centre.
pub fn sigma_filter_rows(
    source: []const f32,
    target: []f32,
    width: u32,
    height: u32,
    row_begin: u32,
    row_end: u32,
    threshold: f32,
) void {
    assert(row_end <= height);
    assert(@as(usize, height) * width <= source.len);
    assert(@as(usize, height) * width <= target.len);
    assert(threshold >= 0);
    const w: i64 = width;
    const h: i64 = height;
    for (row_begin..row_end) |y| {
        for (0..width) |x| {
            const centre = source[y * width + x];
            var sum: f32 = 0;
            var count: f32 = 0;
            for (0..5) |dy| {
                const sy = std.math.clamp(@as(i64, @intCast(y + dy)) - 2, 0, h - 1);
                const row = source[@as(usize, @intCast(sy)) * width ..][0..width];
                for (0..5) |dx| {
                    const sx = std.math.clamp(@as(i64, @intCast(x + dx)) - 2, 0, w - 1);
                    const value = row[@intCast(sx)];
                    const near: f32 = @floatFromInt(@intFromBool(@abs(value - centre) <=
                        threshold));
                    sum += value * near;
                    count += near;
                }
            }
            assert(count >= 1);
            target[y * width + x] = sum / count;
        }
    }
}

/// Bilinear sample at continuous coordinates where pixel centres sit at `i + 0.5`.
pub fn sample_bilinear(plane: []const f32, width: u32, height: u32, x: f32, y: f32) f32 {
    assert(width > 0);
    assert(height > 0);
    const fx = std.math.clamp(x - 0.5, 0, @as(f32, @floatFromInt(width - 1)));
    const fy = std.math.clamp(y - 0.5, 0, @as(f32, @floatFromInt(height - 1)));
    const x0: u32 = @intFromFloat(fx);
    const y0: u32 = @intFromFloat(fy);
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    const row0 = plane[@as(usize, y0) * width ..];
    const row1 = plane[@as(usize, y1) * width ..];
    const top = row0[x0] + (row0[x1] - row0[x0]) * tx;
    const bottom = row1[x0] + (row1[x1] - row1[x0]) * tx;
    return top + (bottom - top) * ty;
}

fn mix32(value: u32) u32 {
    var h = value;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

/// Deterministic per-pixel hash, so band layout and thread count cannot change the output.
pub fn noise_hash(seed: u32, x: u32, y: u32, channel: u32) u32 {
    var h = mix32(seed +% 0x9e3779b9);
    h = mix32(h ^ (x *% 0x85ebca6b));
    h = mix32(h ^ (y *% 0xc2b2ae35));
    h = mix32(h ^ (channel *% 0x27d4eb2f));
    return h;
}

/// Approximately standard normal: Irwin-Hall sum of the four hash bytes as uniforms.
pub fn normal_approx(h: u32) f32 {
    var sum: f32 = 0;
    inline for (0..4) |index| {
        const byte: u8 = @truncate(h >> (index * 8));
        sum += (@as(f32, @floatFromInt(byte)) + 0.5) / 256;
    }
    const result = (sum - 2) * std.math.sqrt(3.0);
    assert(result >= -3.47);
    assert(result <= 3.47);
    return result;
}

test "gaussian_kernel: normalized, capped, and a copy below sigma 0.3" {
    // Goal: kernel invariants. Method: check sums and radii at small, normal and huge sigma.
    var kernel: Kernel = undefined;
    try std.testing.expectEqual(@as(u32, 0), gaussian_kernel(0.1, &kernel));
    try std.testing.expectEqual(@as(f32, 1), kernel[0]);
    const radius = gaussian_kernel(2, &kernel);
    try std.testing.expectEqual(@as(u32, 6), radius);
    var sum: f32 = 0;
    for (kernel[0 .. 2 * radius + 1]) |weight| sum += weight;
    try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-5);
    try std.testing.expectEqual(kernel_radius_max, gaussian_kernel(100, &kernel));
}

test "blur: a constant plane stays constant" {
    // Goal: edge clamping keeps the mean. Method: blur a constant 37x11 plane both ways.
    const width = 37;
    const height = 11;
    var source: [width * height]f32 = @splat(0.42);
    var scratch: [width * height]f32 = undefined;
    var target: [width * height]f32 = undefined;
    var kernel: Kernel = undefined;
    const radius = gaussian_kernel(3, &kernel);
    blur_rows_horizontal(&source, &scratch, width, 0, height, &kernel, radius);
    blur_rows_vertical(&scratch, &target, width, height, 0, height, &kernel, radius, .{
        .original = &source,
    });
    for (target) |value| try std.testing.expectApproxEqAbs(@as(f32, 0.42), value, 1e-5);
}
