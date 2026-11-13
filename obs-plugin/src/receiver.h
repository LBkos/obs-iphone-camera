#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * TCP server that accepts one iPhone at a time, parses the wire protocol
 * (see protocol.h) and reports messages through callbacks. All callbacks are
 * invoked on the receiver's own thread. No libobs dependency, so it can be
 * tested standalone (tools/receiver-test.c).
 */

typedef void (*obscam_log_fn)(void *ctx, int level, const char *msg);

struct obscam_receiver_callbacks {
	void *ctx;
	void (*connected)(void *ctx, const char *peer_address);
	void (*hello)(void *ctx, const char *device_name);
	void (*config)(void *ctx, const uint8_t *data, size_t size);
	void (*frame)(void *ctx, uint64_t pts_us, bool keyframe, const uint8_t *data, size_t size);
	void (*disconnected)(void *ctx);
	obscam_log_fn log; /* level: 0 = info, 1 = warning, 2 = error */
};

typedef struct obscam_receiver obscam_receiver_t;

/* service_name may be NULL (Bonjour picks the host name). */
obscam_receiver_t *obscam_receiver_start(uint16_t port, const char *service_name,
					 const struct obscam_receiver_callbacks *callbacks);
void obscam_receiver_stop(obscam_receiver_t *receiver);
