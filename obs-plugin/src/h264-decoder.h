#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct AVFrame;

/* Thin FFmpeg (libavcodec) H.264 / HEVC decoder for Annex-B input. Starts as H.264. */
typedef struct obscam_decoder obscam_decoder_t;

typedef void (*obscam_frame_fn)(void *ctx, const struct AVFrame *frame, uint64_t pts_us);

obscam_decoder_t *obscam_decoder_create(obscam_frame_fn on_frame, void *ctx);
void obscam_decoder_destroy(obscam_decoder_t *d);

/* OBSCAM_CODEC_* (protocol.h). A change reopens the decoder; the next frame must be a keyframe. */
bool obscam_decoder_set_codec(obscam_decoder_t *d, uint8_t codec);
/* Parameter sets (Annex-B: SPS/PPS, or VPS/SPS/PPS for HEVC). Prepended to the next keyframe. */
void obscam_decoder_set_config(obscam_decoder_t *d, const uint8_t *data, size_t size);
/* Returns false if the frame could not be decoded. */
bool obscam_decoder_decode(obscam_decoder_t *d, const uint8_t *data, size_t size, bool keyframe, uint64_t pts_us);
/* Drop state; next frame must be a keyframe. */
void obscam_decoder_reset(obscam_decoder_t *d);
