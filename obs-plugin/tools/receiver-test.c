/*
 * Standalone receiver (no OBS): accepts the iOS app, decodes the stream and
 * prints statistics. Useful to test the app/network before touching OBS.
 *
 *   obscam-receiver-test [--port 47100] [--frames N] [--snapshot out.ppm]
 */
#include "h264-decoder.h"
#include "protocol.h"
#include "receiver.h"

#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>

#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static atomic_bool g_stop;
static obscam_decoder_t *g_decoder;
static atomic_uint g_decoded, g_received;
static unsigned g_frames_limit;
static const char *g_snapshot_path;
static bool g_snapshot_done;
static int g_width, g_height;

static void on_signal(int sig)
{
	(void)sig;
	atomic_store(&g_stop, true);
}

static void on_log(void *ctx, int level, const char *msg)
{
	(void)ctx;
	static const char *names[] = {"info", "warn", "error"};
	fprintf(stderr, "[%s] %s\n", names[level < 0 || level > 2 ? 2 : level], msg);
}

static void on_connected(void *ctx, const char *peer)
{
	(void)ctx;
	(void)peer;
	obscam_decoder_reset(g_decoder);
}

static void on_config(void *ctx, const uint8_t *data, size_t size)
{
	(void)ctx;
	fprintf(stderr, "[info] got SPS/PPS (%zu bytes)\n", size);
	obscam_decoder_set_config(g_decoder, data, size);
}

static void on_frame(void *ctx, uint64_t pts_us, bool keyframe, const uint8_t *data, size_t size)
{
	(void)ctx;
	atomic_fetch_add(&g_received, 1);
	if (!obscam_decoder_decode(g_decoder, data, size, keyframe, pts_us))
		fprintf(stderr, "[warn] decode error\n");
}

static uint8_t clamp8(int v)
{
	return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

/* BT.709 limited-range YUV -> RGB, written as binary PPM. */
static void write_snapshot(const AVFrame *f)
{
	FILE *fp = fopen(g_snapshot_path, "wb");
	if (!fp) {
		perror("snapshot");
		return;
	}
	bool nv12 = f->format == AV_PIX_FMT_NV12;
	fprintf(fp, "P6\n%d %d\n255\n", f->width, f->height);
	uint8_t *row = malloc((size_t)f->width * 3);
	for (int y = 0; y < f->height; y++) {
		for (int x = 0; x < f->width; x++) {
			int Y = f->data[0][y * f->linesize[0] + x];
			int U, V;
			if (nv12) {
				const uint8_t *uv = f->data[1] + (y / 2) * f->linesize[1] + (x / 2) * 2;
				U = uv[0];
				V = uv[1];
			} else {
				U = f->data[1][(y / 2) * f->linesize[1] + x / 2];
				V = f->data[2][(y / 2) * f->linesize[2] + x / 2];
			}
			double c = 1.164 * (Y - 16), d = U - 128, e = V - 128;
			row[x * 3 + 0] = clamp8((int)(c + 1.793 * e));
			row[x * 3 + 1] = clamp8((int)(c - 0.213 * d - 0.533 * e));
			row[x * 3 + 2] = clamp8((int)(c + 2.112 * d));
		}
		fwrite(row, 1, (size_t)f->width * 3, fp);
	}
	free(row);
	fclose(fp);
	fprintf(stderr, "[info] snapshot written to %s\n", g_snapshot_path);
}

static void on_decoded(void *ctx, const AVFrame *f, uint64_t pts_us)
{
	(void)ctx;
	(void)pts_us;
	g_width = f->width;
	g_height = f->height;
	unsigned n = atomic_fetch_add(&g_decoded, 1) + 1;
	/* Skip the first frames so the encoder's rate control has settled. */
	if (g_snapshot_path && !g_snapshot_done && n >= 30) {
		write_snapshot(f);
		g_snapshot_done = true;
	}
	if (g_frames_limit && n >= g_frames_limit)
		atomic_store(&g_stop, true);
}

int main(int argc, char **argv)
{
	int port = OBSCAM_DEFAULT_PORT;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc)
			port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc)
			g_frames_limit = (unsigned)atoi(argv[++i]);
		else if (!strcmp(argv[i], "--snapshot") && i + 1 < argc)
			g_snapshot_path = argv[++i];
		else {
			fprintf(stderr, "usage: %s [--port N] [--frames N] [--snapshot out.ppm]\n", argv[0]);
			return 2;
		}
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	g_decoder = obscam_decoder_create(on_decoded, NULL);
	if (!g_decoder) {
		fprintf(stderr, "FFmpeg H.264 decoder not available\n");
		return 1;
	}

	struct obscam_receiver_callbacks cb = {
		.connected = on_connected,
		.config = on_config,
		.frame = on_frame,
		.log = on_log,
	};
	obscam_receiver_t *r = obscam_receiver_start((uint16_t)port, "OBS Camera receiver test", &cb);
	if (!r)
		return 1;

	unsigned last = 0;
	while (!atomic_load(&g_stop)) {
		sleep(1);
		unsigned now = atomic_load(&g_decoded);
		if (now != last)
			printf("decoded=%u received=%u fps=%u size=%dx%d\n", now, atomic_load(&g_received), now - last,
			       g_width, g_height);
		fflush(stdout);
		last = now;
	}

	obscam_receiver_stop(r);
	obscam_decoder_destroy(g_decoder);
	printf("done: decoded %u frames\n", atomic_load(&g_decoded));
	return atomic_load(&g_decoded) > 0 ? 0 : 1;
}
