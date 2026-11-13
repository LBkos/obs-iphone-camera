#include "h264-decoder.h"
#include "protocol.h"

#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <stdlib.h>
#include <string.h>

struct obscam_decoder {
	AVCodecContext *ctx;
	AVPacket *pkt;
	AVFrame *frame;
	uint8_t codec; /* OBSCAM_CODEC_* */
	obscam_frame_fn on_frame;
	void *user;

	uint8_t *config;
	size_t config_size;
	bool config_pending;
	bool waiting_for_keyframe;

	uint8_t *buf;
	size_t buf_cap;
};

static bool open_codec(struct obscam_decoder *d)
{
	const AVCodec *codec = avcodec_find_decoder(d->codec == OBSCAM_CODEC_HEVC ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264);
	if (!codec)
		return false;
	d->ctx = avcodec_alloc_context3(codec);
	if (!d->ctx)
		return false;
	d->ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
	d->ctx->flags2 |= AV_CODEC_FLAG2_FAST;
	/* Slice threading only: frame threading adds a frame of latency per thread. */
	d->ctx->thread_type = FF_THREAD_SLICE;
	d->ctx->thread_count = 0;
	if (avcodec_open2(d->ctx, codec, NULL) < 0) {
		avcodec_free_context(&d->ctx);
		return false;
	}
	return true;
}

obscam_decoder_t *obscam_decoder_create(obscam_frame_fn on_frame, void *ctx)
{
	struct obscam_decoder *d = calloc(1, sizeof(*d));
	if (!d)
		return NULL;
	d->on_frame = on_frame;
	d->user = ctx;
	d->waiting_for_keyframe = true;
	d->codec = OBSCAM_CODEC_H264;
	d->pkt = av_packet_alloc();
	d->frame = av_frame_alloc();
	if (!d->pkt || !d->frame || !open_codec(d)) {
		obscam_decoder_destroy(d);
		return NULL;
	}
	return d;
}

void obscam_decoder_destroy(obscam_decoder_t *d)
{
	if (!d)
		return;
	avcodec_free_context(&d->ctx);
	av_packet_free(&d->pkt);
	av_frame_free(&d->frame);
	free(d->config);
	free(d->buf);
	free(d);
}

bool obscam_decoder_set_codec(obscam_decoder_t *d, uint8_t codec)
{
	if (codec != OBSCAM_CODEC_H264 && codec != OBSCAM_CODEC_HEVC)
		return false;
	if (codec == d->codec && d->ctx)
		return true;
	avcodec_free_context(&d->ctx);
	d->codec = codec;
	/* Parameter sets of the old codec are useless now; new ones follow. */
	free(d->config);
	d->config = NULL;
	d->config_size = 0;
	d->config_pending = false;
	d->waiting_for_keyframe = true;
	return open_codec(d);
}

void obscam_decoder_set_config(obscam_decoder_t *d, const uint8_t *data, size_t size)
{
	uint8_t *copy = malloc(size);
	if (!copy)
		return;
	memcpy(copy, data, size);
	free(d->config);
	d->config = copy;
	d->config_size = size;
	d->config_pending = true;
}

void obscam_decoder_reset(obscam_decoder_t *d)
{
	if (d->ctx)
		avcodec_flush_buffers(d->ctx);
	d->waiting_for_keyframe = true;
	d->config_pending = d->config != NULL;
}

bool obscam_decoder_decode(obscam_decoder_t *d, const uint8_t *data, size_t size, bool keyframe, uint64_t pts_us)
{
	if (!d->ctx)
		return false; /* codec failed to open */
	if (d->waiting_for_keyframe) {
		if (!keyframe)
			return true; /* silently skip until we can start cleanly */
		d->waiting_for_keyframe = false;
	}

	size_t prefix = (keyframe && d->config) ? d->config_size : 0;
	size_t total = prefix + size;
	size_t needed = total + AV_INPUT_BUFFER_PADDING_SIZE;
	if (d->buf_cap < needed) {
		uint8_t *nb = realloc(d->buf, needed);
		if (!nb)
			return false;
		d->buf = nb;
		d->buf_cap = needed;
	}
	if (prefix)
		memcpy(d->buf, d->config, prefix);
	memcpy(d->buf + prefix, data, size);
	memset(d->buf + total, 0, AV_INPUT_BUFFER_PADDING_SIZE);
	d->config_pending = false;

	d->pkt->data = d->buf;
	d->pkt->size = (int)total;
	d->pkt->pts = (int64_t)pts_us;
	d->pkt->flags = keyframe ? AV_PKT_FLAG_KEY : 0;

	int ret = avcodec_send_packet(d->ctx, d->pkt);
	av_packet_unref(d->pkt);
	if (ret < 0) {
		d->waiting_for_keyframe = true;
		return false;
	}

	for (;;) {
		ret = avcodec_receive_frame(d->ctx, d->frame);
		if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
			break;
		if (ret < 0) {
			d->waiting_for_keyframe = true;
			return false;
		}
		uint64_t out_pts = d->frame->pts != AV_NOPTS_VALUE ? (uint64_t)d->frame->pts : pts_us;
		d->on_frame(d->user, d->frame, out_pts);
		av_frame_unref(d->frame);
	}
	return true;
}
