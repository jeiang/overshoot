//! The virtual camera's exposure program: the single source of the ISO, shutter time and aperture
//! used by gain, noise, shake and EXIF.

const std = @import("std");
const assert = std.debug.assert;
const profiles = @import("profiles.zig");
const Profile = profiles.Profile;

/// Exposure of the real (iPhone) capture.
pub const Capture = struct {
    metadata_valid: bool,
    exposure_time_s: f32,
    iso: f32,
    aperture: f32,
    flash_fired: bool,
};

/// Exposure the emulated camera would have chosen.
pub const Virtual = struct {
    exposure_time_s: f32,
    iso: f32,
    aperture: f32,
    focal_length_mm: f32,
    focal_length_35mm: f32,
    /// Linear multiplier applied to the capture.
    gain: f32,
    flash_fired: bool,
};

const shutter_stops_s = [_]f32{
    1.0 / 2000.0, 1.0 / 1600.0, 1.0 / 1250.0, 1.0 / 1000.0, 1.0 / 800.0, 1.0 / 640.0,
    1.0 / 500.0,  1.0 / 400.0,  1.0 / 320.0,  1.0 / 250.0,  1.0 / 200.0, 1.0 / 160.0,
    1.0 / 125.0,  1.0 / 100.0,  1.0 / 80.0,   1.0 / 60.0,   1.0 / 50.0,  1.0 / 40.0,
    1.0 / 30.0,   1.0 / 25.0,   1.0 / 20.0,   1.0 / 15.0,   1.0 / 13.0,  1.0 / 10.0,
    1.0 / 8.0,    1.0 / 6.0,    1.0 / 5.0,    1.0 / 4.0,    0.3,         0.4,
    0.5,          0.6,          0.8,          1.0,
};

const iso_stops = [_]f32{ 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800 };

pub fn focal_length_35mm_at(profile: *const Profile, zoom: f32) f32 {
    assert(zoom >= 0);
    assert(zoom <= 1);
    const wide = profile.focal_length_35mm_wide;
    const tele = profile.focal_length_35mm_tele;
    const result = wide * std.math.pow(f32, tele / wide, zoom);
    assert(result >= wide * 0.999);
    return result;
}

pub fn focal_length_mm_at(profile: *const Profile, zoom: f32) f32 {
    assert(zoom >= 0);
    assert(zoom <= 1);
    const wide = profile.focal_length_mm_wide;
    const tele = profile.focal_length_mm_tele;
    const result = wide * std.math.pow(f32, tele / wide, zoom);
    assert(result >= wide * 0.999);
    return result;
}

pub fn aperture_at(profile: *const Profile, zoom: f32) f32 {
    const f_mm = focal_length_mm_at(profile, zoom);
    const span = profile.focal_length_mm_tele - profile.focal_length_mm_wide;
    assert(span > 0);
    const fraction = (f_mm - profile.focal_length_mm_wide) / span;
    const aperture = profile.aperture_wide + (profile.aperture_tele - profile.aperture_wide) *
        fraction;
    const rounded = @round(aperture * 10) / 10;
    assert(rounded > 0);
    return rounded;
}

fn snap_log(stops: []const f32, value: f32) f32 {
    assert(stops.len > 0);
    assert(value > 0);
    var best = stops[0];
    var best_distance = @abs(@log2(value / best));
    for (stops[1..]) |stop| {
        const distance = @abs(@log2(value / stop));
        if (distance < best_distance) {
            best = stop;
            best_distance = distance;
        }
    }
    return best;
}

pub fn program(
    profile: *const Profile,
    zoom: f32,
    capture: *const Capture,
    mean_luminance: f32,
) Virtual {
    assert(zoom >= 0);
    assert(zoom <= 1);
    assert(std.math.isFinite(mean_luminance));
    const m = @max(mean_luminance, 1e-4);
    const target = profile.meter_target;
    const aperture = aperture_at(profile, zoom);
    var exposure_time_s: f32 = 1.0 / 60.0;
    var iso: f32 = profile.iso_min;
    var underexposure: f32 = 1;
    if (!capture.metadata_valid) {
        // Without capture metadata only the meter is known: keep a neutral exposure.
    } else if (capture.flash_fired) {
        exposure_time_s = profile.flash_shutter_s;
        iso = profile.flash_iso;
    } else {
        assert(capture.exposure_time_s > 0);
        assert(capture.iso > 0);
        assert(capture.aperture > 0);
        const ev_scene = @log2(capture.aperture * capture.aperture / capture.exposure_time_s) -
            @log2(capture.iso / 100);
        const ev_needed = ev_scene - @log2(target / m);
        const n2 = aperture * aperture;
        exposure_time_s = n2 / @exp2(ev_needed + @log2(iso / 100));
        if (exposure_time_s > profile.shutter_s_handheld) {
            iso = @min(
                profile.iso_auto_max,
                profile.iso_min * exposure_time_s / profile.shutter_s_handheld,
            );
            exposure_time_s = n2 / @exp2(ev_needed + @log2(iso / 100));
        }
        if (exposure_time_s > profile.shutter_s_slowest) {
            underexposure = profile.shutter_s_slowest / exposure_time_s;
            exposure_time_s = profile.shutter_s_slowest;
        }
    }
    const virtual: Virtual = .{
        .exposure_time_s = snap_log(&shutter_stops_s, exposure_time_s),
        .iso = snap_log(&iso_stops, iso),
        .aperture = aperture,
        .focal_length_mm = focal_length_mm_at(profile, zoom),
        .focal_length_35mm = focal_length_35mm_at(profile, zoom),
        .gain = std.math.clamp(target / m * underexposure, 1.0 / 16.0, 16.0),
        .flash_fired = capture.metadata_valid and capture.flash_fired,
    };
    assert_virtual_valid(&virtual);
    return virtual;
}

fn assert_virtual_valid(virtual: *const Virtual) void {
    inline for (.{
        virtual.exposure_time_s, virtual.iso,               virtual.aperture,
        virtual.focal_length_mm, virtual.focal_length_35mm, virtual.gain,
    }) |value| {
        assert(std.math.isFinite(value));
        assert(value > 0);
    }
}

/// Length in output pixels of the hand-shake streak; below 1 px there is no shake pass.
pub fn shake_length_px(profile: *const Profile, virtual: *const Virtual, output_width: u32) f32 {
    assert(output_width > 0);
    assert_virtual_valid(virtual);
    if (virtual.flash_fired) return 0;
    const width: f32 = @floatFromInt(output_width);
    const length = width * virtual.exposure_time_s * virtual.focal_length_35mm / 1500 *
        profile.shake_gain;
    assert(length >= 0);
    return length;
}

/// Residual colour cast of a camera whose auto white balance only partly corrects the scene.
/// A temperature of 0 means unknown and gives neutral gains.
pub fn white_balance_gains(profile: *const Profile, temperature_k: f32) [3]f32 {
    assert(std.math.isFinite(temperature_k));
    assert(temperature_k >= 0);
    if (temperature_k == 0) return .{ 1, 1, 1 };
    const kelvin = std.math.clamp(temperature_k, 1500, 15000);
    const residual = (1 - profile.awb_strength) * (1e6 / kelvin - 1e6 / 5500.0);
    const gains: [3]f32 = .{
        @exp2(residual * 0.0035),
        1,
        @exp2(-residual * 0.0035),
    };
    assert(gains[0] > 0);
    assert(gains[2] > 0);
    return gains;
}

test "program: daylight on Canon gives base ISO and the meter gain" {
    // Goal: a bright scene needs no gain-up. Method: a 1/1000 s ISO 50 f/1.6 capture.
    const capture: Capture = .{
        .metadata_valid = true,
        .exposure_time_s = 1.0 / 1000.0,
        .iso = 50,
        .aperture = 1.6,
        .flash_fired = false,
    };
    const virtual = program(&profiles.canon_a3400, 0, &capture, 0.18);
    try std.testing.expectEqual(@as(f32, 100), virtual.iso);
    try std.testing.expect(std.mem.findScalar(f32, &shutter_stops_s, virtual.exposure_time_s) !=
        null);
    const expected_gain = profiles.canon_a3400.meter_target / 0.18;
    try std.testing.expectApproxEqRel(expected_gain, virtual.gain, 1e-5);
}

test "program: dim scene on Nikon hits the ISO and shutter limits" {
    // Goal: a dark scene underexposes at the slowest shutter. Method: 1/15 s ISO 1600 capture.
    const capture: Capture = .{
        .metadata_valid = true,
        .exposure_time_s = 1.0 / 15.0,
        .iso = 1600,
        .aperture = 1.6,
        .flash_fired = false,
    };
    const virtual = program(&profiles.nikon_l11, 0, &capture, 0.18);
    try std.testing.expectEqual(@as(f32, 400), virtual.iso);
    try std.testing.expectEqual(@as(f32, 0.25), virtual.exposure_time_s);
    try std.testing.expect(virtual.gain < profiles.nikon_l11.meter_target / 0.18);
}

test "program: flash, invalid metadata and zero luminance" {
    // Goal: special cases stay defined. Method: flash, missing metadata, and a black frame.
    var capture: Capture = .{
        .metadata_valid = true,
        .exposure_time_s = 1.0 / 30.0,
        .iso = 800,
        .aperture = 1.6,
        .flash_fired = true,
    };
    const flash = program(&profiles.canon_a3400, 0.5, &capture, 0.1);
    try std.testing.expectEqual(profiles.canon_a3400.flash_shutter_s, flash.exposure_time_s);
    capture.metadata_valid = false;
    const invalid = program(&profiles.nikon_l11, 0, &capture, 0.1);
    try std.testing.expectEqual(@as(f32, 1.0 / 60.0), invalid.exposure_time_s);
    try std.testing.expectEqual(profiles.nikon_l11.iso_min, invalid.iso);
    const black = program(&profiles.nikon_l11, 1, &capture, 0);
    try std.testing.expect(std.math.isFinite(black.gain));
}

test "white_balance_gains: tungsten stays warm and unknown is neutral" {
    // Goal: partial AWB leaves a warm cast. Method: 2850 K and 0 K on Canon.
    const warm = white_balance_gains(&profiles.canon_a3400, 2850);
    try std.testing.expect(warm[0] > 1.05);
    try std.testing.expect(warm[2] < 0.95);
    const neutral = white_balance_gains(&profiles.canon_a3400, 0);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, neutral);
}
