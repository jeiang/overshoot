//! Image decoding and encoding through Apple's ImageIO, CoreGraphics and CoreFoundation, declared
//! here with `extern` because `@cImport` is gone and the surface is small.

const std = @import("std");
const assert = std.debug.assert;

const CFTypeRef = *const anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFStringRef = *const anyopaque;
const CFURLRef = *const anyopaque;
const CFNumberRef = *const anyopaque;
const CFDictionaryRef = *const anyopaque;
const CGColorSpaceRef = *anyopaque;
const CGContextRef = *anyopaque;
const CGImageRef = *anyopaque;
const CGImageSourceRef = *anyopaque;
const CGImageDestinationRef = *anyopaque;

const CGRect = extern struct { x: f64, y: f64, width: f64, height: f64 };

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberFloat32Type: c_long = 5;
const kCFNumberIntType: c_long = 9;
const kCGImageAlphaPremultipliedLast: u32 = 1;
const kCGImageAlphaNoneSkipLast: u32 = 5;
const kCGBitmapFloatComponents: u32 = 256;
const kCGBitmapByteOrder16Little: u32 = 4096;

extern "c" fn CFURLCreateFromFileSystemRepresentation(
    allocator: CFAllocatorRef,
    buffer: [*]const u8,
    length: c_long,
    is_directory: bool,
) ?CFURLRef;
extern "c" fn CFStringCreateWithCString(
    allocator: CFAllocatorRef,
    string: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;
extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    kind: c_long,
    value: *const anyopaque,
) ?CFNumberRef;
extern "c" fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    count: c_long,
    key_callbacks: *const anyopaque,
    value_callbacks: *const anyopaque,
) ?CFDictionaryRef;
extern "c" fn CFRelease(object: CFTypeRef) void;
extern const kCFTypeDictionaryKeyCallBacks: u8;
extern const kCFTypeDictionaryValueCallBacks: u8;
extern const kCFBooleanTrue: CFTypeRef;

extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) ?CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
extern const kCGColorSpaceSRGB: CFStringRef;
extern const kCGColorSpaceLinearSRGB: CFStringRef;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    space: CGColorSpaceRef,
    bitmap_info: u32,
) ?CGContextRef;
extern "c" fn CGContextDrawImage(context: CGContextRef, rect: CGRect, image: CGImageRef) void;
extern "c" fn CGBitmapContextCreateImage(context: CGContextRef) ?CGImageRef;
extern "c" fn CGContextRelease(context: CGContextRef) void;
extern "c" fn CGImageGetWidth(image: CGImageRef) usize;
extern "c" fn CGImageGetHeight(image: CGImageRef) usize;
extern "c" fn CGImageRelease(image: CGImageRef) void;

extern "c" fn CGImageSourceCreateWithURL(
    url: CFURLRef,
    options: ?CFDictionaryRef,
) ?CGImageSourceRef;
extern "c" fn CGImageSourceCreateImageAtIndex(
    source: CGImageSourceRef,
    index: usize,
    options: ?CFDictionaryRef,
) ?CGImageRef;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(
    source: CGImageSourceRef,
    index: usize,
    options: ?CFDictionaryRef,
) ?CGImageRef;
extern const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
extern const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
extern const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
extern "c" fn CGImageDestinationCreateWithURL(
    url: CFURLRef,
    kind: CFStringRef,
    count: usize,
    options: ?CFDictionaryRef,
) ?CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(
    destination: CGImageDestinationRef,
    image: CGImageRef,
    properties: ?CFDictionaryRef,
) void;
extern "c" fn CGImageDestinationFinalize(destination: CGImageDestinationRef) bool;
extern const kCGImageDestinationLossyCompressionQuality: CFStringRef;

pub const Error = error{ ImageUnreadable, ImageTooLarge, ImageUnwritable, OutOfResources };

pub const Size = struct { width: u32, height: u32 };

fn url_from(path: [:0]const u8) Error!CFURLRef {
    assert(path.len > 0);
    return CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse
        error.OutOfResources;
}

fn dictionary(keys: []const CFStringRef, values: []const CFTypeRef) Error!CFDictionaryRef {
    assert(keys.len == values.len);
    assert(keys.len <= 4);
    var key_buffer: [4]?*const anyopaque = undefined;
    var value_buffer: [4]?*const anyopaque = undefined;
    for (keys, values, 0..) |key, value, index| {
        key_buffer[index] = key;
        value_buffer[index] = value;
    }
    return CFDictionaryCreate(
        null,
        &key_buffer,
        &value_buffer,
        @intCast(keys.len),
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse error.OutOfResources;
}

fn load_image(path: [:0]const u8) Error!CGImageRef {
    const url = try url_from(path);
    defer CFRelease(url);
    const source = CGImageSourceCreateWithURL(url, null) orelse return error.ImageUnreadable;
    defer CFRelease(source);
    return CGImageSourceCreateImageAtIndex(source, 0, null) orelse error.ImageUnreadable;
}

/// Size of the image at `path` without decoding the pixels into a buffer.
pub fn image_size(path: [:0]const u8) Error!Size {
    const image = try load_image(path);
    defer CGImageRelease(image);
    const width = CGImageGetWidth(image);
    const height = CGImageGetHeight(image);
    if (width == 0 or height == 0) return error.ImageUnreadable;
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.ImageTooLarge;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

/// Draws the image at `path` as linear sRGB RGBA `f16` into `pixels`, which must hold
/// `width * height * 4` halves for the size `image_size` returned.
pub fn decode_linear_f16(path: [:0]const u8, size: Size, pixels: []f16) Error!void {
    assert(pixels.len == @as(usize, size.width) * size.height * 4);
    assert(size.width > 0);
    const image = try load_image(path);
    defer CGImageRelease(image);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB) orelse
        return error.OutOfResources;
    defer CGColorSpaceRelease(space);
    const float_info = kCGBitmapFloatComponents | kCGBitmapByteOrder16Little;
    const context = CGBitmapContextCreate(
        pixels.ptr,
        size.width,
        size.height,
        16,
        @as(usize, size.width) * 8,
        space,
        kCGImageAlphaNoneSkipLast | float_info,
    ) orelse CGBitmapContextCreate(
        pixels.ptr,
        size.width,
        size.height,
        16,
        @as(usize, size.width) * 8,
        space,
        // Opaque input, so premultiplied values equal the straight ones.
        kCGImageAlphaPremultipliedLast | float_info,
    ) orelse return error.OutOfResources;
    defer CGContextRelease(context);
    const rect: CGRect = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    };
    CGContextDrawImage(context, rect, image);
}

/// Decodes the image at `path` to sRGB RGBA8; the caller frees the pixels.
pub fn decode_srgb8(gpa: std.mem.Allocator, path: [:0]const u8) !struct { Size, []u8 } {
    const size = try image_size(path);
    const pixels = try gpa.alloc(u8, @as(usize, size.width) * size.height * 4);
    errdefer gpa.free(pixels);
    const image = try load_image(path);
    defer CGImageRelease(image);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.OutOfResources;
    defer CGColorSpaceRelease(space);
    const context = CGBitmapContextCreate(
        pixels.ptr,
        size.width,
        size.height,
        8,
        @as(usize, size.width) * 4,
        space,
        kCGImageAlphaNoneSkipLast,
    ) orelse return error.OutOfResources;
    defer CGContextRelease(context);
    const rect: CGRect = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    };
    CGContextDrawImage(context, rect, image);
    return .{ size, pixels };
}

fn write_jpeg(path: [:0]const u8, image: CGImageRef, quality: f32) Error!void {
    assert(quality > 0);
    assert(quality <= 1);
    const url = try url_from(path);
    defer CFRelease(url);
    const kind = CFStringCreateWithCString(null, "public.jpeg", kCFStringEncodingUTF8) orelse
        return error.OutOfResources;
    defer CFRelease(kind);
    const destination = CGImageDestinationCreateWithURL(url, kind, 1, null) orelse
        return error.ImageUnwritable;
    defer CFRelease(destination);
    const number = CFNumberCreate(null, kCFNumberFloat32Type, &quality) orelse
        return error.OutOfResources;
    defer CFRelease(number);
    const properties = try dictionary(&.{kCGImageDestinationLossyCompressionQuality}, &.{number});
    defer CFRelease(properties);
    CGImageDestinationAddImage(destination, image, properties);
    if (!CGImageDestinationFinalize(destination)) return error.ImageUnwritable;
}

pub fn encode_jpeg_rgba8(
    path: [:0]const u8,
    rgba: []const u8,
    width: u32,
    height: u32,
    quality: f32,
) Error!void {
    assert(rgba.len == @as(usize, width) * height * 4);
    assert(width > 0 and height > 0);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.OutOfResources;
    defer CGColorSpaceRelease(space);
    // CoreGraphics only reads the buffer here; the API takes a mutable pointer.
    const data: *anyopaque = @ptrCast(@constCast(rgba.ptr));
    const row_bytes = @as(usize, width) * 4;
    const info = kCGImageAlphaNoneSkipLast;
    const context = CGBitmapContextCreate(data, width, height, 8, row_bytes, space, info) orelse
        return error.OutOfResources;
    defer CGContextRelease(context);
    const image = CGBitmapContextCreateImage(context) orelse return error.OutOfResources;
    defer CGImageRelease(image);
    try write_jpeg(path, image, quality);
}

/// Reproduces 2010 Facebook resizing: at most 720 px on the long side, JPEG quality 0.85, no
/// metadata.
pub fn write_facebook_copy(source_path: [:0]const u8, target_path: [:0]const u8) Error!void {
    assert(source_path.len > 0);
    assert(target_path.len > 0);
    const url = try url_from(source_path);
    defer CFRelease(url);
    const source = CGImageSourceCreateWithURL(url, null) orelse return error.ImageUnreadable;
    defer CFRelease(source);
    const max_pixels: c_int = 720;
    const number = CFNumberCreate(null, kCFNumberIntType, &max_pixels) orelse
        return error.OutOfResources;
    defer CFRelease(number);
    const options = try dictionary(&.{
        kCGImageSourceThumbnailMaxPixelSize,
        kCGImageSourceCreateThumbnailFromImageAlways,
        kCGImageSourceCreateThumbnailWithTransform,
    }, &.{ number, kCFBooleanTrue, kCFBooleanTrue });
    defer CFRelease(options);
    const thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) orelse
        return error.ImageUnreadable;
    defer CGImageRelease(thumbnail);
    try write_jpeg(target_path, thumbnail, 0.85);
}
