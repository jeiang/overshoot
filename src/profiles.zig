//! Camera facts and look parameters. Spatial values are pixels at the native resolution; the
//! pipeline multiplies them by `output_width / native_width`.

const std = @import("std");
const assert = std.debug.assert;

pub const Camera = enum(u32) { canon_a3400 = 0, nikon_l11 = 1 };

pub const camera_count: u32 = 2;

pub const Profile = struct {
    make: [:0]const u8,
    model: [:0]const u8,
    native_width: u32,
    native_height: u32,
    focal_length_mm_wide: f32,
    focal_length_mm_tele: f32,
    focal_length_35mm_wide: f32,
    focal_length_35mm_tele: f32,
    aperture_wide: f32,
    aperture_tele: f32,
    iso_min: f32,
    iso_auto_max: f32,
    shutter_s_handheld: f32,
    shutter_s_slowest: f32,
    flash_shutter_s: f32,
    flash_iso: f32,
    /// Linear mean luminance that the meter aims for.
    meter_target: f32,
    shake_gain: f32,
    /// Radial distortion; k1 > 0 is barrel.
    distortion_k1_wide: f32,
    distortion_k1_tele: f32,
    chromatic_aberration_wide: f32,
    chromatic_aberration_tele: f32,
    blur_sigma_px_center: f32,
    blur_sigma_px_corner: f32,
    blur_sigma_px_tele_add: f32,
    flare: f32,
    bloom_strength: f32,
    bloom_threshold: f32,
    bloom_sigma_px: f32,
    vignette_strength: f32,
    /// CCD smear: multiplies each column's mean overexposure. RAW highlights reach up to 16x the
    /// clip level after gain, so even small values draw a visible streak through bright lights.
    smear_strength: f32,
    /// Noise model coefficients at ISO 100.
    noise_shot: f32,
    noise_read: f32,
    awb_strength: f32,
    saturation: f32,
    tone_contrast: f32,
    tone_black_lift: f32,
    /// Linear level that maps to black: crushes the rectified sensor-noise floor, which the steep
    /// sRGB curve would otherwise lift to a grey haze in the shadows.
    tone_black_clip: f32,
    /// Noise reduction parameters at ISO 100.
    nr_luma_threshold: f32,
    nr_chroma_sigma_px: f32,
    sharpen_amount: f32,
    sharpen_sigma_px: f32,
    jpeg_quality: f32,
    file_megabytes_average: f32,
    has_date_stamp: bool,
};

pub const canon_a3400: Profile = .{
    .make = "Canon",
    .model = "Canon PowerShot A3400 IS",
    .native_width = 4608,
    .native_height = 3456,
    .focal_length_mm_wide = 5.0,
    .focal_length_mm_tele = 25.0,
    .focal_length_35mm_wide = 28,
    .focal_length_35mm_tele = 140,
    .aperture_wide = 2.8,
    .aperture_tele = 6.9,
    .iso_min = 100,
    .iso_auto_max = 800,
    .shutter_s_handheld = 1.0 / 60.0,
    .shutter_s_slowest = 1.0 / 8.0,
    .flash_shutter_s = 1.0 / 30.0,
    .flash_iso = 400,
    .meter_target = 0.21,
    .shake_gain = 0.6,
    .distortion_k1_wide = 0.030,
    .distortion_k1_tele = -0.005,
    .chromatic_aberration_wide = 0.0006,
    .chromatic_aberration_tele = 0.0012,
    .blur_sigma_px_center = 1.0,
    .blur_sigma_px_corner = 2.0,
    .blur_sigma_px_tele_add = 0.8,
    .flare = 0.01,
    .bloom_strength = 0.08,
    .bloom_threshold = 0.8,
    .bloom_sigma_px = 40,
    .vignette_strength = 0.25,
    .smear_strength = 0.015,
    .noise_shot = 0.0008,
    .noise_read = 0.0020,
    .awb_strength = 0.6,
    .saturation = 1.20,
    .tone_contrast = 0.35,
    .tone_black_lift = 0.01,
    .tone_black_clip = 0.008,
    .nr_luma_threshold = 0.020,
    .nr_chroma_sigma_px = 1.5,
    .sharpen_amount = 1.2,
    .sharpen_sigma_px = 1.2,
    .jpeg_quality = 0.90,
    .file_megabytes_average = 4.5,
    .has_date_stamp = true,
};

pub const nikon_l11: Profile = .{
    .make = "NIKON",
    .model = "COOLPIX L11",
    .native_width = 2816,
    .native_height = 2112,
    .focal_length_mm_wide = 6.2,
    .focal_length_mm_tele = 18.6,
    .focal_length_35mm_wide = 37.5,
    .focal_length_35mm_tele = 112.5,
    .aperture_wide = 2.8,
    .aperture_tele = 5.2,
    .iso_min = 64,
    .iso_auto_max = 400,
    .shutter_s_handheld = 1.0 / 30.0,
    .shutter_s_slowest = 1.0 / 4.0,
    .flash_shutter_s = 1.0 / 30.0,
    .flash_iso = 200,
    .meter_target = 0.45,
    .shake_gain = 3.0,
    .distortion_k1_wide = 0.020,
    .distortion_k1_tele = -0.004,
    .chromatic_aberration_wide = 0.0008,
    .chromatic_aberration_tele = 0.0012,
    .blur_sigma_px_center = 0.7,
    .blur_sigma_px_corner = 1.5,
    .blur_sigma_px_tele_add = 0.5,
    .flare = 0.05,
    .bloom_strength = 0.25,
    .bloom_threshold = 0.7,
    .bloom_sigma_px = 30,
    .vignette_strength = 0.20,
    .smear_strength = 0.05,
    .noise_shot = 0.0006,
    .noise_read = 0.0015,
    .awb_strength = 0.8,
    .saturation = 1.30,
    .tone_contrast = 0.10,
    .tone_black_lift = 0.08,
    .tone_black_clip = 0,
    .nr_luma_threshold = 0.010,
    .nr_chroma_sigma_px = 1.0,
    .sharpen_amount = 0.9,
    .sharpen_sigma_px = 1.0,
    .jpeg_quality = 0.82,
    .file_megabytes_average = 1.6,
    .has_date_stamp = false,
};

comptime {
    for ([_]Profile{ canon_a3400, nikon_l11 }) |profile| {
        // The tone curve stays monotonic only while the contrast term is below 1.
        assert(@abs(profile.tone_contrast) < 1);
        assert(profile.awb_strength >= 0);
        assert(profile.awb_strength <= 1);
        assert(profile.native_width * 3 == profile.native_height * 4);
        // Bloom runs at 1/8 scale, where the blur radius is capped at 32 taps.
        assert(profile.bloom_sigma_px * 3 / 8 <= 32);
        assert(profile.blur_sigma_px_corner > profile.blur_sigma_px_center);
        assert(profile.tone_black_clip >= 0);
        assert(profile.tone_black_clip < 0.1);
        assert(profile.focal_length_35mm_tele > profile.focal_length_35mm_wide);
        assert(profile.focal_length_mm_tele > profile.focal_length_mm_wide);
    }
}

pub fn profile_for(camera: Camera) *const Profile {
    assert(@backingInt(camera) < camera_count);
    const profile: *const Profile = switch (camera) {
        .canon_a3400 => &canon_a3400,
        .nikon_l11 => &nikon_l11,
    };
    assert(profile.native_width > 0);
    return profile;
}
