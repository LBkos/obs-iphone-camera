#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Receives the iPhone stream (see protocol.h) and reports messages through
 * callbacks. All callbacks are invoked on the receiver's own thread. No
 * libobs dependency, so it can be tested standalone (tools/receiver-test.c).
 *
 * Two modes:
 *  - server (Wi-Fi): listens on a TCP port and advertises it via Bonjour;
 *    the iPhone connects to us.
 *  - client (USB):   the iPhone listens; we keep calling a connect function
 *    (usbmuxd) until it returns a socket.
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

/* Why a client-mode connection attempt did not succeed (shown in the UI). */
enum obscam_client_status {
	OBSCAM_CLIENT_CONNECTING = 0,
	OBSCAM_CLIENT_CONNECTED,
	OBSCAM_CLIENT_UNAVAILABLE, /* built without USB support */
	OBSCAM_CLIENT_NO_DAEMON,   /* usbmuxd is not running */
	OBSCAM_CLIENT_NO_DEVICE,   /* no iPhone connected by cable */
	OBSCAM_CLIENT_NO_APP,      /* iPhone found, app not listening (not open / not in USB mode) */
};

/* Returns a connected socket or -1 (and sets *status). peer gets a description. */
typedef int (*obscam_connect_fn)(void *ctx, char *peer, size_t peer_size, enum obscam_client_status *status);

typedef struct obscam_receiver obscam_receiver_t;

/* Server mode. service_name may be NULL (Bonjour picks the host name). */
obscam_receiver_t *obscam_receiver_start(uint16_t port, const char *service_name,
					 const struct obscam_receiver_callbacks *callbacks);

/* Client mode. The receiver owns connect_ctx and releases it with free_ctx. */
obscam_receiver_t *obscam_receiver_start_client(obscam_connect_fn connect_fn, void *connect_ctx,
						void (*free_ctx)(void *), const struct obscam_receiver_callbacks *callbacks);

/* Latest client-mode status (OBSCAM_CLIENT_CONNECTED in server mode while a phone is connected). */
enum obscam_client_status obscam_receiver_client_status(obscam_receiver_t *receiver);

void obscam_receiver_stop(obscam_receiver_t *receiver);
