#ifndef OVERSHOOT_H
#define OVERSHOOT_H

#include <stdint.h>

typedef struct overshoot_pipeline overshoot_pipeline;

typedef enum { OVERSHOOT_CAMERA_CANON_A3400 = 0, OVERSHOOT_CAMERA_NIKON_L11 = 1 } overshoot_camera;

typedef struct {
    const char *make;
    const char *model;
    uint32_t native_width;
    uint32_t native_height;
    float jpeg_quality;
    float file_megabytes_average;
    float focal_length_35mm_wide;
    float focal_length_35mm_tele;
    uint32_t has_date_stamp;
} overshoot_camera_info;

typedef struct {
    uint32_t camera;
    float zoom;
    uint32_t metadata_valid;
    float exposure_time_s;
    float iso;
    float aperture;
    uint32_t flash_fired;
    float focal_length_35mm_capture;
    float temperature_k;
    uint32_t seed;
} overshoot_frame;

typedef struct {
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t row_bytes;
} overshoot_source_bgra8;

typedef struct {
    float exposure_time_s;
    float iso;
    float aperture;
    float focal_length_mm;
    float focal_length_35mm;
    /* 1 when the emulated camera's auto flash would fire for this frame. */
    uint32_t flash_needed;
    uint32_t output_width;
    uint32_t output_height;
    const uint8_t *output_rgba;
} overshoot_result;

overshoot_camera_info overshoot_camera_info_get(uint32_t camera);
overshoot_pipeline *overshoot_preview_create(uint32_t output_width, uint32_t output_height, uint32_t thread_count);
overshoot_pipeline *overshoot_still_create(uint32_t thread_count);
void overshoot_pipeline_destroy(overshoot_pipeline *pipeline);
void overshoot_preview_process(overshoot_pipeline *pipeline, const overshoot_source_bgra8 *source,
                               const overshoot_frame *frame, overshoot_result *result);
void *overshoot_still_staging(overshoot_pipeline *pipeline, uint32_t width, uint32_t height);
void overshoot_still_process(overshoot_pipeline *pipeline, uint32_t width, uint32_t height,
                             const overshoot_frame *frame, overshoot_result *result);

#endif
